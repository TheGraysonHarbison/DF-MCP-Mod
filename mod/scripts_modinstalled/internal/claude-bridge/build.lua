-- Placing workshop blueprints. The building is queued for construction with the game's
-- default material filters; dwarves fetch the closest suitable material. Nothing is ever
-- completed instantly. Plan section 10, item 4.3. Material words and the usable material
-- list (build.materials) are plan section 12, item 7.0.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')
local materials = reqscript('internal/claude-bridge/materials')

DEFAULT_LIMIT = 25

local B = dfhack.buildings
local M = dfhack.maps

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

-- Resolve a type name to building_type, subtype, custom index, and a display name.
local function resolve_type(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local wanted = name:lower()
    for i = 0, df.workshop_type._last_item do
        local token = df.workshop_type[i]
        if token and token ~= 'Custom' and token:lower() == wanted then
            return df.building_type.Workshop, i, -1, token
        end
    end
    for i = 0, df.furnace_type._last_item do
        local token = df.furnace_type[i]
        if token and token ~= 'Custom' and token:lower() == wanted then
            return df.building_type.Furnace, i, -1, token
        end
    end
    local defs = safe(function() return df.global.world.raws.buildings.all end) or {}
    for index, def in ipairs(defs) do
        local code = safe(function() return def.code end)
        local label = safe(function() return def.name end)
        if (code and code:lower() == wanted) or (label and label:lower() == wanted) then
            local is_furnace = df.building_def_furnacest:is_instance(def)
            return is_furnace and df.building_type.Furnace or df.building_type.Workshop,
                   is_furnace and df.furnace_type.Custom or df.workshop_type.Custom,
                   index, label or code
        end
    end
    return nil
end

local function known_types()
    local out = {}
    for i = 0, df.workshop_type._last_item do
        local t = df.workshop_type[i]
        if t and t ~= 'Custom' then table.insert(out, t) end
    end
    for i = 0, df.furnace_type._last_item do
        local t = df.furnace_type[i]
        if t and t ~= 'Custom' then table.insert(out, t) end
    end
    pcall(function()
        for _, def in ipairs(df.global.world.raws.buildings.all) do
            table.insert(out, def.code)
        end
    end)
    return out
end

-- First tile in the footprint that cannot host a building, with the reason.
local function first_blocker(x1, y1, z, w, h)
    for y = y1, y1 + h - 1 do
        for x = x1, x1 + w - 1 do
            local pos = {x = x, y = y, z = z}
            if not dfhack.maps.isValidTilePos(pos) then
                return pos, 'outside the map'
            end
            local t = map.describe_tile(pos, 1)
            if t.unknown then return pos, 'no map block' end
            if t.hidden then return pos, 'hidden (not yet revealed)' end
            if t.building then
                return pos, ('occupied by %s %d'):format(t.building.type or 'building', t.building.id)
            end
            if t.liquid then return pos, ('%s depth %d'):format(t.liquid.type, t.liquid.depth) end
            if t.plant then return pos, 'tree or plant' end
            if t.basic_shape ~= 'Floor' then
                return pos, ('%s, not floor'):format(t.basic_shape or t.shape or 'unknown')
            end
            if not t.walkable then return pos, 'not walkable' end
        end
    end
    return nil
end

-- Count items in play that satisfy one job item filter, and the material spec's class and
-- form (which DFHack's check ignores). nil when DFHack cannot judge.
-- The item vector a filter restricts itself to (job_item_vector_id names match
-- items_other_id names: ANY_SPIKE, ANY_WEAPON, DOOR, ...), else IN_PLAY.
function filter_vector(filter)
    local vid = safe(function() return filter.vector_id end)
    local name = type(vid) == 'number' and vid >= 0 and enum_name(df.job_item_vector_id, vid) or nil
    if name and name ~= 'ANY_FREE' and name ~= 'IN_PLAY' then
        local vec = safe(function() return df.global.world.items.other[name] end)
        if vec then return vec, name end
    end
    return df.global.world.items.other.IN_PLAY, nil
end

-- A readable item label for a filter: its item type, else its vector ("spike", "weapon").
function filter_label(filter)
    local itype = filter.item_type
    if type(itype) == 'number' and itype >= 0 then return enum_name(df.item_type, itype) or 'any' end
    local _, vector = filter_vector(filter)
    if vector == 'ANY_SPIKE' then return 'spike (trap component)' end
    if vector == 'ANY_WEAPON' then return 'weapon or trap component' end
    if vector then return vector:lower():gsub('^any_', '') end
    return 'any'
end

function count_suitable(filter, spec)
    if not dfhack.job.isSuitableItem or not dfhack.job.isSuitableMaterial then return nil end
    local count = 0
    local vector = filter_vector(filter)
    for _, item in ipairs(vector) do
        if materials.item_usable(item) then
            local itype, isub = item:getType(), item:getSubtype()
            local ok_item = safe(dfhack.job.isSuitableItem, filter, itype, isub)
            if ok_item then
                local ok_mat = safe(dfhack.job.isSuitableMaterial, filter,
                    item:getMaterial(), item:getMaterialIndex(), itype)
                if ok_mat and (spec == nil or materials.item_matches(item, spec)) then
                    count = count + (safe(function() return item:getStackSize() end) or 1)
                end
            end
        end
    end
    return count
end

-- getFiltersByType returns plain Lua tables (item_type, mat_type, quantity, flagsN maps),
-- which constructBuilding turns into job items. Absent fields mean "any" or 1.
local function describe_filter(filter)
    local itype = filter.item_type
    local out = {
        item_type = (type(itype) == 'number' and itype >= 0) and enum_name(df.item_type, itype)
            or 'any',
        quantity = filter.quantity or 1,
        material = (function()
            local mt, mi = filter.mat_type, filter.mat_index
            if type(mt) ~= 'number' or mt < 0 then return 'any' end
            return safe(function() return dfhack.matinfo.decode(mt, mi or -1):toString() end)
                or ('%d:%d'):format(mt, mi or -1)
        end)(),
    }
    local flags = {}
    for _, field in ipairs({'flags1', 'flags2', 'flags3'}) do
        pcall(function()
            for name, value in pairs(filter[field]) do
                if value == true then table.insert(flags, name) end
            end
        end)
    end
    table.sort(flags)
    out.flags = flags
    return out
end

function free_filters(filters)
    for _, f in ipairs(filters or {}) do pcall(function() f:delete() end) end
end

local function workshop(args)
    local btype, subtype, custom, label = resolve_type(args.type)
    if not btype then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            ('unknown workshop type "%s"; known: %s'):format(tostring(args.type),
                table.concat(known_types(), ', ')))
    end
    local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
    if not x or not y or not z then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"x", "y", "z" (top-left corner, as find_space returns in origin) are required')
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    -- getCorrectSize returns: is_fixed, width, height, centre_x, centre_y (checked 2026-10-12).
    local _, w, h = B.getCorrectSize(nil, nil, btype, subtype, custom, 0)
    local footprint = {origin = {x = x, y = y, z = z}, width = w, height = h}

    local pos, why = first_blocker(x, y, z, w, h)
    if pos then
        return {status = 'invalid_space', type = label, footprint = footprint,
                blocked_at = pos, reason = why}
    end
    local free = safe(B.checkFreeTiles, {x = x, y = y, z = z}, {x = w, y = h})
    if free == false then
        return {status = 'invalid_space', type = label, footprint = footprint,
                reason = 'DFHack reports the footprint is not free (unsupported or occupied)'}
    end

    local filter_args = {}
    local spec, why = materials.resolve(args.material)
    if why then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
    if spec then filter_args.material = materials.job_item_fields(spec) end
    local filters = safe(B.getFiltersByType, filter_args, btype, subtype, custom)
    if not filters then
        return rpc.error_result(rpc.ERR_INTERNAL, 'DFHack has no material filters for this type')
    end
    local requirements, shortage = {}, nil
    for _, filter in ipairs(filters) do
        local need = describe_filter(filter)
        -- The spec applies to the "material" slot only: the one with no fixed item type,
        -- or the one whose item type the form names.
        local applies = spec ~= nil and (need.item_type == 'any'
            or (spec.form ~= nil and need.item_type == spec.form))
        if applies then need.material = spec.label end
        need.available = count_suitable(filter, applies and spec or nil)
        table.insert(requirements, need)
        if need.available ~= nil and need.available < (need.quantity or 1) then
            shortage = need
        end
    end
    if shortage then
        free_filters(filters)
        return {status = 'no_materials', type = label, footprint = footprint,
                requirements = requirements, missing = shortage}
    end

    local building, err = B.constructBuilding{
        type = btype, subtype = subtype, custom = custom,
        pos = {x = x, y = y, z = z},
        filters = filters,
    }
    if not building then
        free_filters(filters)
        return {status = 'invalid_space', type = label, footprint = footprint,
                reason = tostring(err)}
    end
    return {
        status = 'placed',
        type = label,
        building = {
            id = building.id,
            kind = enum_name(df.building_type, building:getType()),
            pos = {x = building.centerx, y = building.centery, z = building.z},
            bounds = {x1 = building.x1, y1 = building.y1, x2 = building.x2, y2 = building.y2,
                      z = building.z},
        },
        requirements = requirements,
        note = 'blueprint placed; dwarves will haul the closest suitable material and build it',
    }
end

-- Plain names for building types, the reverse of furniture.TYPES plus the rest.
PLAIN_KINDS = {
    Workshop = 'workshop', Furnace = 'furnace', Construction = 'construction', Door = 'door',
    Floodgate = 'floodgate', Hatch = 'hatch', GrateWall = 'wall_grate', GrateFloor = 'floor_grate',
    BarsVertical = 'vertical_bars', BarsFloor = 'floor_bars', WindowGlass = 'glass_window',
    WindowGem = 'gem_window', Bed = 'bed', Table = 'table', Chair = 'chair', Cabinet = 'cabinet',
    Box = 'chest', Armorstand = 'armor_stand', Weaponrack = 'weapon_rack', Statue = 'statue',
    Slab = 'slab', Coffin = 'coffin', Cage = 'cage', Chain = 'restraint', Well = 'well',
    ArcheryTarget = 'archery_target', TractionBench = 'traction_bench', NestBox = 'nest_box',
    Hive = 'hive', Bookcase = 'bookcase', DisplayFurniture = 'display_case',
    OfferingPlace = 'offering_place', Instrument = 'instrument', AnimalTrap = 'animal_trap',
    Bridge = 'bridge', RoadPaved = 'paved_road', RoadDirt = 'dirt_road', Support = 'support',
    Trap = 'trap', Weapon = 'spike', SiegeEngine = 'siege_engine', TradeDepot = 'trade_depot',
    FarmPlot = 'farm_plot', ScrewPump = 'screw_pump', WaterWheel = 'water_wheel',
    Windmill = 'windmill', GearAssembly = 'gear_assembly', AxleHorizontal = 'horizontal_axle',
    AxleVertical = 'vertical_axle', Rollers = 'rollers', Wagon = 'wagon', Stockpile = 'stockpile',
    Civzone = 'zone',
}

local function subtype_name(b)
    if df.building_workshopst:is_instance(b) then return enum_name(df.workshop_type, b.type) end
    if df.building_furnacest:is_instance(b) then return enum_name(df.furnace_type, b.type) end
    if df.building_constructionst:is_instance(b) then return enum_name(df.construction_type, b.type) end
    if df.building_trapst:is_instance(b) then return enum_name(df.trap_type, b.trap_type) end
    if df.building_siegeenginest:is_instance(b) then return enum_name(df.siegeengine_type, b.type) end
    if df.building_civzonest:is_instance(b) then return enum_name(df.civzone_type, b.type) end
    return nil
end

local function has_mood(b)
    local mood = false
    pcall(function()
        for _, job in ipairs(b.jobs) do
            if df.job_type_class[df.job_type.attrs[job.job_type].type] == 'StrangeMood' then
                mood = true
            end
        end
    end)
    return mood
end

-- One row for any building: identity, place, build state, the construction job, and
-- how many of its items are attached.
function building_summary(b)
    local token = enum_name(df.building_type, b:getType())
    local stage = safe(function() return b:getBuildStage() end)
    local max_stage = safe(function() return b:getMaxBuildStage() end)
    local row = {
        id = b.id,
        kind = PLAIN_KINDS[token or ''] or (token and token:lower()) or '?',
        building_type = token,
        type = subtype_name(b),
        name = safe(function() return b.name ~= '' and b.name or nil end),
        pos = {x = b.centerx, y = b.centery, z = b.z},
        bounds = {x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z},
        stage = stage, max_stage = max_stage,
        built = stage ~= nil and max_stage ~= nil and stage >= max_stage,
        planned = stage == 0,
        marked_for_removal = safe(B.markedForRemoval, b) == true,
        strange_mood = has_mood(b),
    }
    pcall(function()
        local job = b.jobs[0]
        if not job then return end
        local worker = safe(dfhack.job.getWorker, job)
        row.job = {
            id = job.id, type = enum_name(df.job_type, job.job_type),
            suspended = job.flags.suspend == true, do_now = job.flags.do_now == true,
            worker = worker and {id = worker.id, name = dfhack.units.getReadableName(worker)} or nil,
        }
        row.suspended = job.flags.suspend == true
        local needed = 0
        for _, ji in ipairs(job.job_items.elements) do needed = needed + math.max(ji.quantity, 0) end
        row.materials = {attached = #job.items, still_needed = needed}
    end)
    return row
end

-- Every building in play but stockpiles and zones (they have their own ops), with filters.
local function list(args)
    local kind = args.kind ~= nil and tostring(args.kind):lower() or nil
    local planned_only = args.planned_only == true
    local z = tonumber(args.z)
    local box = nil
    if args.x1 ~= nil then
        local parsed, err = map.parse_box(args)
        if err then return err end
        box = parsed
    end
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    if limit < 1 then limit = DEFAULT_LIMIT end
    local offset = tonumber(args.offset) or 0
    local rows, counts = {}, {}
    for _, b in ipairs(df.global.world.buildings.all) do
        local btype = b:getType()
        if btype ~= df.building_type.Stockpile and btype ~= df.building_type.Civzone then
            local row = building_summary(b)
            local keep = true
            if kind and row.kind ~= kind and (row.building_type or ''):lower() ~= kind
                and (row.type or ''):lower() ~= kind then keep = false end
            if keep and planned_only and row.built then keep = false end
            if keep and z and b.z ~= z then keep = false end
            if keep and box and (b.z < box.z1 or b.z > box.z2 or b.x2 < box.x1 or b.x1 > box.x2
                or b.y2 < box.y1 or b.y1 > box.y2) then keep = false end
            if keep then
                table.insert(rows, row)
                counts[row.kind] = (counts[row.kind] or 0) + 1
            end
        end
    end
    table.sort(rows, function(a, c) return a.id < c.id end)
    local out = {}
    for i = offset + 1, math.min(#rows, offset + limit) do table.insert(out, rows[i]) end
    return {total = #rows, count = #out, offset = offset, limit = limit, truncated = offset + #out < #rows,
            buildings = out, counts_by_kind = counts,
            filter = {kind = kind, planned_only = planned_only or nil, z = z, box = box}}
end

-- Ask for a building to be removed. A finished building gets a deconstruction job for the
-- dwarves; an unfinished blueprint is cancelled on the spot. Stockpiles and zones have
-- their own ops; a strange mood claim refuses.
local function remove(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a building id') end
    local b = df.building.find(id)
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    local btype = b:getType()
    if btype == df.building_type.Stockpile then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a stockpile; use stockpiles.delete'):format(id))
    end
    if btype == df.building_type.Civzone then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a zone; use zones.delete'):format(id))
    end
    if has_mood(b) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is claimed by a strange mood; removing it would ruin the mood'):format(id))
    end
    if safe(B.markedForRemoval, b) then
        return {status = 'already_queued', building = building_summary(b)}
    end
    local summary = building_summary(b)
    -- deconstruct returns true when it destroyed the building on the spot and false when it
    -- queued a DestroyBuilding job for a finished one (checked against Buildings.cpp,
    -- 2026-10-12), so the return value is a mode, not a failure.
    local ok, err = pcall(B.deconstruct, b)
    if not ok then
        return rpc.error_result(rpc.ERR_INTERNAL, 'deconstruct failed: ' .. tostring(err))
    end
    local remaining = df.building.find(id)
    if remaining == nil then
        return {status = summary.built and 'removed' or 'blueprint_cancelled', building = summary,
                note = summary.built and 'the building is gone' or 'the blueprint is cancelled; nothing was built'}
    end
    if safe(B.markedForRemoval, remaining) then
        return {status = 'removal_queued', building = summary,
                note = 'a dwarf will take it apart; its items drop on the ground'}
    end
    return rpc.error_result(rpc.ERR_INTERNAL, 'DFHack neither removed nor queued the building')
end

-- Suspend or resume the construction job of an unbuilt building.
local function suspend(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a building id') end
    if type(args.suspended) ~= 'boolean' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"suspended" must be true or false')
    end
    local b = df.building.find(id)
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    local summary = building_summary(b)
    if summary.built or not summary.job then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d has no construction job to suspend (it is %s)'):format(
                id, summary.built and 'built' or 'without a job'))
    end
    local before = summary.suspended
    local ok, err = pcall(function() b.jobs[0].flags.suspend = args.suspended end)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, tostring(err)) end
    pcall(dfhack.job.checkBuildingsNow)
    return {changed = before ~= args.suspended, suspended = args.suspended, building = building_summary(b)}
end

-- Remove constructions in a box or circle: planned ones are cancelled at once, finished
-- ones are designated for removal by a miner (dfhack.constructions.designateRemove).
local function remove_constructions(args)
    local dig = reqscript('internal/claude-bridge/dig')
    local box, berr, inside
    if args.circle ~= nil then
        box, berr, inside = dig.parse_circle(args)
    else
        box, berr = map.parse_box(args)
    end
    if berr then return berr end
    local apply = args.dry_run ~= true
    local counts = {cancelled = 0, designated = 0, already_designated = 0, skipped = 0}
    local tiles, skipped = {}, {}
    for z = box.z1, box.z2 do
        for y = box.y1, box.y2 do
            for x = box.x1, box.x2 do
                if inside == nil or inside(x, y) then
                    local pos = {x = x, y = y, z = z}
                    local built = safe(dfhack.constructions.findAtTile, pos)
                    -- The tile above a constructed wall carries a construction record of its
                    -- own (top_of_wall); it goes with the wall, not on its own.
                    if built and safe(function() return built.flags.top_of_wall end) then built = nil end
                    local planned = nil
                    if not built then
                        local bld = safe(B.findAtTile, pos)
                        if bld and bld:getType() == df.building_type.Construction then planned = bld end
                    end
                    if built then
                        local des = M.getTileFlags(pos)
                        if des and des.dig ~= df.tile_dig_designation.No then
                            counts.already_designated = counts.already_designated + 1
                        else
                            counts.designated = counts.designated + 1
                            if #tiles < DEFAULT_LIMIT then
                                table.insert(tiles, {pos = pos, action = 'designated',
                                    material = safe(function()
                                        return dfhack.matinfo.decode(built.mat_type, built.mat_index):toString()
                                    end)})
                            end
                            if apply then pcall(dfhack.constructions.designateRemove, pos) end
                        end
                    elseif planned then
                        counts.cancelled = counts.cancelled + 1
                        if #tiles < DEFAULT_LIMIT then
                            table.insert(tiles, {pos = pos, action = 'cancelled', building = planned.id})
                        end
                        if apply and not has_mood(planned) then pcall(B.deconstruct, planned) end
                    else
                        counts.skipped = counts.skipped + 1
                        if #skipped < DEFAULT_LIMIT then table.insert(skipped, pos) end
                    end
                end
            end
        end
    end
    if apply and counts.designated > 0 then pcall(dfhack.job.checkDesignationsNow) end
    return {box = box, shape = inside and 'circle' or 'box', dry_run = not apply,
            applied = apply and (counts.cancelled + counts.designated) > 0,
            cancelled = counts.cancelled, designated = counts.designated,
            already_designated = counts.already_designated, skipped = counts.skipped,
            tiles = tiles, skipped_tiles = skipped,
            note = apply and 'planned constructions cancelled; built ones wait for a miner to remove them, '
                .. 'which leaves the material on the ground'
                or 'nothing was changed; call build.remove_constructions with dry_run=false to do it'}
end

-- Usable building materials in play, grouped by material and form (plan 12, item 7.0).
local function list_materials(args)
    local form = nil
    if args.form ~= nil then
        form = materials.FORMS[tostring(args.form):lower()]
        if not form then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"form" must be one of blocks, boulders, logs, bars')
        end
    end
    local spec, why = materials.resolve(args.material)
    if why then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    if limit < 1 then limit = DEFAULT_LIMIT end
    local rows, total = materials.scan({form = form, material = spec,
                                        fire_safe = args.fire_safe == true,
                                        magma_safe = args.magma_safe == true})
    local out, by_class, by_form = {}, {}, {}
    for i, row in ipairs(rows) do
        if i <= limit then table.insert(out, row) end
        by_class[row.class] = (by_class[row.class] or 0) + row.count
        by_form[row.form] = (by_form[row.form] or 0) + row.count
    end
    return {
        total_items = total, groups = #rows, count = #out, limit = limit,
        truncated = #rows > #out, materials = out, by_class = by_class, by_form = by_form,
        filter = {form = form and materials.FORM_WORDS[form] or nil,
                  material = spec and spec.label or nil,
                  fire_safe = args.fire_safe == true, magma_safe = args.magma_safe == true},
        note = 'counts exclude forbidden, dumped, melting, in-use, built, and trader items; '
            .. 'economic boulders (ore, flux) are not used for building unless the player allows it',
    }
end

function ops()
    return {
        ['build.workshop'] = {namespace = 'build_write', handler = workshop, needs_map = true},
        ['build.remove'] = {namespace = 'build_write', handler = remove, needs_map = true},
        ['build.materials'] = {namespace = 'stocks', handler = list_materials, needs_map = true},
        ['build.list'] = {namespace = 'workshops', handler = list, needs_map = true},
        ['build.suspend'] = {namespace = 'build_write', handler = suspend, needs_map = true},
        ['build.remove_constructions'] = {namespace = 'build_write', handler = remove_constructions,
                                          needs_map = true},
    }
end
