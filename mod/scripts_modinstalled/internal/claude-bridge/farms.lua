-- Farm plots: soil report, crops per season, placement (plan section 13, item 10.1).
-- Placement follows quickfort's rule (hack/scripts/internal/quickfort/build.lua, checked
-- 2026-10-15): a floor whose tiletype material is soil, grass, or plant, or any floor with a
-- mud spatter. The plantable list follows DFHack autofarm (plugins/autofarm.cpp): the plant
-- has the SEED flag, not TREE, carries the season flag for every season the crop spans, and
-- a biome flag matching the plot's biome (surface) or BIOME_SUBTERRANEAN_WATER (below
-- ground). The game's own rule is inside the binary, so this is an approximation.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')
local construct = reqscript('internal/claude-bridge/construct')

local B = dfhack.buildings
local M = dfhack.maps

DEFAULT_LIMIT = 25
LIST_LIMIT = 25
MAX_SIDE = 31

SEASONS = {'spring', 'summer', 'autumn', 'winter'}
SEASON_FLAGS = {'SPRING', 'SUMMER', 'AUTUMN', 'WINTER'}
SEASON_ALIASES = {fall = 'autumn'}

local SOIL_MATERIALS = {SOIL = true, GRASS_LIGHT = true, GRASS_DARK = true, GRASS_DRY = true,
                        GRASS_DEAD = true, PLANT = true}
local DIRT_SHAPES = {FLOOR = true, TWIG = true, SAPLING = true, SHRUB = true}
local SEED_SKIP_FLAGS = {'dump', 'forbid', 'garbage_collect', 'hostile', 'on_fire', 'rotten',
                         'trader', 'in_building', 'construction', 'artifact', 'removed'}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function enum_name(enum, value)
    local name = safe(function() return enum[value] end)
    if type(name) == 'string' then return name end
    return nil
end

local function season_index(name)
    if type(name) ~= 'string' then return nil end
    local key = SEASON_ALIASES[name:lower()] or name:lower()
    for i, s in ipairs(SEASONS) do
        if s == key then return i - 1 end
    end
    return nil
end

----------------------------------------------------------------------------------------------
-- tiles

-- Mud on the tile: a solid MUD spatter event covering it with a non-zero amount.
local function has_mud(pos)
    local block = M.getTileBlock(pos)
    if not block then return false end
    local lx, ly = pos.x % 16, pos.y % 16
    local found = false
    pcall(function()
        for _, ev in ipairs(block.block_events) do
            if df.block_square_event_material_spatterst:is_instance(ev)
                and ev.mat_type == df.builtin_mats.MUD
                and ev.mat_state == df.matter_state.Solid
                and ev.amount[lx][ly] > 0 then
                found = true
            end
        end
    end)
    return found
end

-- nil when the tile can take a farm plot, else the reason. Also returns facts for reports.
local function tile_check(pos)
    local f = construct.facts(pos)
    if not f then return 'no map block', nil end
    if construct.is_edge(pos) then return 'map edge', f end
    local problem = construct.base_problem(f)
    if problem then return problem, f end
    local shape = f.shape or ''
    local mud = has_mud(pos)
    if SOIL_MATERIALS[f.material or ''] and DIRT_SHAPES[shape] then return nil, f, mud end
    if f.basic == 'Floor' and mud then return nil, f, true end
    if f.basic ~= 'Floor' then return shape:lower() .. ', not a floor', f, mud end
    return (f.material or 'unknown'):lower() .. ' floor without mud (farm plots need soil or mud)', f, mud
end

local function biome_of(pos)
    return safe(function()
        local rx, ry = M.getTileBiomeRgn(pos)
        if rx == nil then return nil end
        local biome = M.getBiomeType(rx, ry)
        return enum_name(df.biome_type, biome)
    end)
end

-- Soil facts for one tile: material name, mud, above or below ground, cavern.
local function tile_soil(pos, f, mud)
    -- Grass and surface plants sit on the biome's soil layer; name that soil, not the grass.
    local tiletype_material = f.material or ''
    local lookup = SOIL_MATERIALS[tiletype_material] and 'SOIL' or tiletype_material
    local material = safe(map.tile_material, pos, {material = lookup}, f.des)
    local name = material and material.material_name or tiletype_material:lower()
    if tiletype_material:find('^GRASS') then name = name .. ' (grass)' end
    return {
        material = name,
        mud = mud == true,
        subterranean = f.des.subterranean == true,
        outside = f.des.outside == true,
        cavern = f.des.subterranean == true and f.des.feature_local == true,
    }
end

----------------------------------------------------------------------------------------------
-- crops

local function plant_flag(plant, name)
    return safe(function() return plant.flags[name] end) == true
end

local function seasons_spanned(plant)
    local growdur = safe(function() return plant.growdur end) or 0
    -- growdur is in tens of ticks; a season is 100800 ticks (autofarm.cpp).
    return math.max(1, math.ceil(growdur * 10 / 100800))
end

local function season_ok(plant, season)
    for k = 0, seasons_spanned(plant) - 1 do
        if not plant_flag(plant, SEASON_FLAGS[(season + k) % 4 + 1]) then return false end
    end
    return true
end

local function biome_flag_for(subterranean, biome)
    if subterranean then return 'BIOME_SUBTERRANEAN_WATER' end
    if biome then return 'BIOME_' .. biome end
    return nil
end

-- Seeds in stock per plant index, skipping unusable items.
local function seed_counts()
    local counts = {}
    for _, item in ipairs(df.global.world.items.other.SEEDS) do
        local skip = false
        for _, name in ipairs(SEED_SKIP_FLAGS) do
            if safe(function() return item.flags[name] end) then skip = true end
        end
        if not skip then
            local idx = safe(function() return item.mat_index end)
            if idx then
                counts[idx] = (counts[idx] or 0) + (safe(function() return item:getStackSize() end) or 1)
            end
        end
    end
    return counts
end

-- Plants the plot could grow in each season, with seeds in stock.
local function plantable(subterranean, biome, seeds)
    local flag = biome_flag_for(subterranean, biome)
    local out = {}
    for _, s in ipairs(SEASONS) do out[s] = {} end
    for idx, plant in ipairs(df.global.world.raws.plants.all) do
        if plant_flag(plant, 'SEED') and not plant_flag(plant, 'TREE')
                and (flag == nil or plant_flag(plant, flag)) then
            for season = 0, 3 do
                if season_ok(plant, season) then
                    table.insert(out[SEASONS[season + 1]], {
                        plant = plant.name, id = plant.id, index = idx,
                        seeds = seeds[idx] or 0,
                        seasons_to_grow = seasons_spanned(plant),
                    })
                end
            end
        end
    end
    for _, s in ipairs(SEASONS) do
        table.sort(out[s], function(a, b)
            if a.seeds ~= b.seeds then return a.seeds > b.seeds end
            return a.plant < b.plant
        end)
    end
    return out
end

local function resolve_plant(name)
    if type(name) ~= 'string' then return nil end
    local wanted = name:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if wanted == '' or wanted == 'none' or wanted == 'fallow' or wanted == 'nothing' then return -1 end
    for idx, plant in ipairs(df.global.world.raws.plants.all) do
        local pname = safe(function() return plant.name end)
        local pid = safe(function() return plant.id end)
        if (pname and pname:lower() == wanted) or (pid and pid:lower() == wanted)
                or (pname and (pname .. ' plant'):lower() == wanted) then
            return idx, plant
        end
    end
    return nil
end

----------------------------------------------------------------------------------------------
-- plots

local function all_plots()
    local plots = safe(function() return df.global.world.buildings.other.FARM_PLOT end)
    if plots then return plots end
    local out = {}
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_farmplotst:is_instance(b) then table.insert(out, b) end
    end
    return out
end

local function find_plot(id)
    local b = safe(df.building.find, id)
    if not b or not df.building_farmplotst:is_instance(b) then return nil end
    return b
end

local function plot_tiles(b)
    local tiles = {}
    local has_extents = safe(function() return b.room.extents ~= nil end)
    for y = b.y1, b.y2 do
        for x = b.x1, b.x2 do
            local inside = true
            if has_extents then
                inside = safe(function()
                    return b.room.extents[(y - b.room.y) * b.room.width + (x - b.room.x)] ~= 0
                end) ~= false
            end
            if inside then table.insert(tiles, {x = x, y = y, z = b.z}) end
        end
    end
    return tiles
end

local function crops_of(b)
    local crops = {}
    for season = 0, 3 do
        local idx = safe(function() return b.plant_id[season] end)
        local name = 'none'
        if idx and idx >= 0 then
            name = safe(function() return df.global.world.raws.plants.all[idx].name end) or ('plant ' .. idx)
        end
        crops[SEASONS[season + 1]] = name
    end
    return crops
end

local function is_built(b)
    return safe(function() return b:getBuildStage() >= b:getMaxBuildStage() end) == true
end

-- The soil report: per-tile facts summarised, plus the majority verdicts used for crops.
local function soil_report(tiles)
    local materials, mud, below, cavern, outside = {}, 0, 0, 0, 0
    local biome = nil
    for _, pos in ipairs(tiles) do
        local f = construct.facts(pos)
        if f then
            local soil = tile_soil(pos, f, has_mud(pos))
            materials[soil.material] = (materials[soil.material] or 0) + 1
            if soil.mud then mud = mud + 1 end
            if soil.subterranean then below = below + 1 end
            if soil.cavern then cavern = cavern + 1 end
            if soil.outside then outside = outside + 1 end
            biome = biome or biome_of(pos)
        end
    end
    local list = {}
    for name, count in pairs(materials) do table.insert(list, {material = name, tiles = count}) end
    table.sort(list, function(a, b) return a.tiles > b.tiles end)
    local n = #tiles
    local subterranean = below * 2 > n
    local report = {
        tiles = n,
        materials = list,
        mud_tiles = mud,
        subterranean = subterranean,
        subterranean_tiles = below,
        outside_tiles = outside,
        cavern_tiles = cavern,
        biome = biome,
    }
    if subterranean and cavern == 0 then
        report.note = 'underground soil outside a cavern: the wiki says such plots yield less; '
            .. 'cavern crops still grow'
    elseif not subterranean then
        report.note = 'surface plot: grows the biome\'s surface crops'
    else
        report.note = 'cavern plot: grows underground crops at full yield'
    end
    return report
end

local function summary(b)
    local tiles = plot_tiles(b)
    return {
        id = b.id,
        pos = {x = b.centerx, y = b.centery, z = b.z},
        bounds = {x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z},
        tiles = #tiles,
        built = is_built(b),
        crops = crops_of(b),
        fertilize_every_season = safe(function() return b.farm_flags.seasonal_fertilize end) == true,
        fertilization = {
            current = safe(function() return b.current_fertilization end),
            max = safe(function() return b.max_fertilization end),
        },
    }, tiles
end

local function list(args)
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    if limit < 1 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    local rows, total = {}, 0
    for _, b in ipairs(all_plots()) do
        total = total + 1
        if #rows < limit then
            local row, tiles = summary(b)
            local soil = soil_report(tiles)
            row.soil = soil.materials[1] and soil.materials[1].material or nil
            row.subterranean = soil.subterranean
            table.insert(rows, row)
        end
    end
    return {count = #rows, total = total, truncated = total > #rows, plots = rows}
end

local function get(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a number') end
    local b = find_plot(math.floor(id))
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no farm plot with id ' .. id) end
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    local out, tiles = summary(b)
    local soil = soil_report(tiles)
    out.soil = soil
    local seeds = seed_counts()
    local plantable_by_season = plantable(soil.subterranean, soil.biome, seeds)
    local truncated = {}
    for _, s in ipairs(SEASONS) do
        local rows = plantable_by_season[s]
        if #rows > limit then
            local kept = {}
            for i = 1, limit do kept[i] = rows[i] end
            plantable_by_season[s] = kept
            table.insert(truncated, s)
        end
    end
    out.plantable = plantable_by_season
    out.plantable_truncated = truncated
    out.plantable_note = 'DFHack autofarm\'s rule (seed-bearing plant, season flags, biome or '
        .. 'cavern flag); the game may differ at the edges. Crops with 0 seeds need seeds first.'
    return out
end

local function set_crops(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a number') end
    local b = find_plot(math.floor(id))
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no farm plot with id ' .. id) end
    if args.crops ~= nil and type(args.crops) ~= 'table' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"crops" must be an object keyed by season (spring, summer, autumn, winter)')
    end
    if args.fertilize ~= nil and type(args.fertilize) ~= 'boolean' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"fertilize" must be true or false')
    end
    if args.crops == nil and args.fertilize == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "crops" and/or "fertilize"')
    end
    -- Verified 2026-10-15: the game clears plant_id when the planter finishes the plot, so a
    -- crop written to a blueprint is lost. The fertilize flag survives.
    if args.crops ~= nil and not is_built(b) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('farm plot %d is not built yet; the game clears crops when construction finishes, '
             .. 'so set them once list_farms shows built: true (fertilize can be set now)'):format(b.id))
    end
    local _, tiles = summary(b)
    local soil = soil_report(tiles)
    local allowed = plantable(soil.subterranean, soil.biome, seed_counts())
    local writes = {}
    for season_name, plant_name in pairs(args.crops or {}) do
        local season = season_index(season_name)
        if not season then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('unknown season "%s"; use spring, summer, autumn, winter'):format(tostring(season_name)))
        end
        local idx = resolve_plant(plant_name)
        if idx == nil then
            return rpc.error_result(rpc.ERR_NOT_FOUND,
                ('no plant called "%s"; use a name from get_farm plantable, or "none"'):format(tostring(plant_name)))
        end
        if idx >= 0 then
            local ok = false
            for _, row in ipairs(allowed[SEASONS[season + 1]]) do
                if row.index == idx then ok = true end
            end
            if not ok then
                local names = {}
                for i, row in ipairs(allowed[SEASONS[season + 1]]) do
                    if i <= LIST_LIMIT then table.insert(names, row.plant) end
                end
                return rpc.error_result(rpc.ERR_BAD_REQUEST,
                    ('%s cannot be planted here in %s; plantable: %s'):format(
                        tostring(plant_name), SEASONS[season + 1],
                        #names > 0 and table.concat(names, ', ') or 'nothing'))
            end
        end
        table.insert(writes, {season = season, index = idx})
    end
    local changed = {}
    for _, w in ipairs(writes) do
        local before = safe(function() return b.plant_id[w.season] end)
        if before ~= w.index then
            b.plant_id[w.season] = w.index
            table.insert(changed, SEASONS[w.season + 1])
        end
    end
    if args.fertilize ~= nil then
        local before = safe(function() return b.farm_flags.seasonal_fertilize end) == true
        if before ~= args.fertilize then
            b.farm_flags.seasonal_fertilize = args.fertilize
            table.insert(changed, 'fertilize')
        end
    end
    local out = summary(b)
    out.changed = changed
    out.warnings = {}
    return out
end

----------------------------------------------------------------------------------------------
-- placement (build.place with type farm_plot delegates here)

function place(args, apply)
    local box, berr = map.parse_box(args)
    if berr then return berr end
    if box.z1 ~= box.z2 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'a farm plot stays on one level (z1 equal to z2)')
    end
    local w, h = box.x2 - box.x1 + 1, box.y2 - box.y1 + 1
    if w > MAX_SIDE or h > MAX_SIDE then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, ('a farm plot is at most %d by %d'):format(MAX_SIDE, MAX_SIDE))
    end
    local fertilize = args.fertilize == true
    local counts = {skipped_unsuitable = 0, skipped_building = 0, skipped_edge = 0}
    local skipped, good, mud_tiles = {}, {}, 0
    local materials = {}
    for y = box.y1, box.y2 do
        for x = box.x1, box.x2 do
            local pos = {x = x, y = y, z = box.z1}
            local problem, f, mud = tile_check(pos)
            if problem then
                local bucket = problem == 'map edge' and 'skipped_edge'
                    or (problem:find('^building') and 'skipped_building' or 'skipped_unsuitable')
                counts[bucket] = counts[bucket] + 1
                if #skipped < LIST_LIMIT then table.insert(skipped, {pos = pos, reason = problem}) end
            else
                good[x .. ',' .. y] = true
                if mud then mud_tiles = mud_tiles + 1 end
                local soil = tile_soil(pos, f, mud)
                materials[soil.material] = (materials[soil.material] or 0) + 1
            end
        end
    end
    local total = w * h
    local placed_tiles = 0
    for _ in pairs(good) do placed_tiles = placed_tiles + 1 end
    local mats = {}
    for name, count in pairs(materials) do table.insert(mats, {material = name, tiles = count}) end
    table.sort(mats, function(a, b) return a.tiles > b.tiles end)
    local result = {
        type = 'farm_plot', building_type = 'FarmPlot', box = box, dry_run = not apply, applied = false,
        placed = 0, candidates = placed_tiles, tiles = total,
        skipped_unsuitable = counts.skipped_unsuitable, skipped_building = counts.skipped_building,
        skipped_edge = counts.skipped_edge, skipped = skipped, soil = mats, mud_tiles = mud_tiles,
        fertilize_every_season = fertilize, requirements = {}, warnings = {}, buildings = {},
    }
    if placed_tiles == 0 then
        result.status = 'nothing_to_place'
        result.note = 'no tile in the box can take a farm plot (soil or mud floors only)'
        return result
    end
    if placed_tiles < total then
        table.insert(result.warnings, ('%d of %d tiles are cut out of the plot'):format(total - placed_tiles, total))
    end
    if not apply then
        result.status = 'plan'
        result.placed = 1
        result.note = 'nothing was changed; call build.place with the same arguments to place the plot'
        return result
    end
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', total))
    local i = 0
    for ey = box.y1, box.y2 do
        for ex = box.x1, box.x2 do
            extents[i] = good[ex .. ',' .. ey] and 1 or 0
            i = i + 1
        end
    end
    local bld, err = B.constructBuilding{
        type = df.building_type.FarmPlot, pos = {x = box.x1, y = box.y1, z = box.z1},
        width = w, height = h,
        fields = {
            room = {x = box.x1, y = box.y1, width = w, height = h, extents = extents},
            farm_flags = {seasonal_fertilize = fertilize},
        },
    }
    if not bld then
        result.status = 'nothing_to_place'
        result.note = 'placement failed: ' .. tostring(err)
        return result
    end
    result.status = 'placed'
    result.applied = true
    result.placed = 1
    result.buildings = {bld.id}
    result.note = 'blueprint placed; a dwarf with the planter labor prepares the plot, then set its crops with set_farm_crops'
    return result
end

function ops()
    return {
        ['farms.list'] = {namespace = 'workshops', handler = list, needs_map = true},
        ['farms.get'] = {namespace = 'workshops', handler = get, needs_map = true},
        ['farms.set_crops'] = {namespace = 'build_write', handler = set_crops, needs_map = true},
    }
end
