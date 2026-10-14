-- Furniture, doors, hatches, grates, bars, and windows (plan section 12, item 7.2). Each
-- building consumes one finished item of its type (DFHack's building_inputs table in
-- hack/lua/dfhack/buildings.lua, checked 2026-10-14), so a missing item is reported with the
-- work order job that makes it. Tile rules follow quickfort's build module: furniture needs a
-- floor-like tile, beds an indoor one, doors a cardinally adjacent wall or fortification,
-- wells an empty tile beside a floor, hatches and floor grates and bars a floor, open air, ramp
-- top, or stair.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')
local build = reqscript('internal/claude-bridge/build')
local construct = reqscript('internal/claude-bridge/construct')
local materials = reqscript('internal/claude-bridge/materials')

local B = dfhack.buildings

LIST_LIMIT = 25
DEFAULT_LIMIT = 25

-- Plain name -> building type token and tile rule.
TYPES = {
    door = {type = 'Door', rule = 'door'},
    floodgate = {type = 'Floodgate', rule = 'generic'},
    hatch = {type = 'Hatch', rule = 'coverable'},
    wall_grate = {type = 'GrateWall', rule = 'generic'},
    floor_grate = {type = 'GrateFloor', rule = 'coverable'},
    vertical_bars = {type = 'BarsVertical', rule = 'generic'},
    floor_bars = {type = 'BarsFloor', rule = 'coverable'},
    glass_window = {type = 'WindowGlass', rule = 'generic'},
    gem_window = {type = 'WindowGem', rule = 'generic'},
    bed = {type = 'Bed', rule = 'inside'},
    table = {type = 'Table', rule = 'generic'},
    chair = {type = 'Chair', rule = 'generic'},
    cabinet = {type = 'Cabinet', rule = 'generic'},
    chest = {type = 'Box', rule = 'generic'},
    armor_stand = {type = 'Armorstand', rule = 'generic'},
    weapon_rack = {type = 'Weaponrack', rule = 'generic'},
    statue = {type = 'Statue', rule = 'generic'},
    slab = {type = 'Slab', rule = 'generic'},
    coffin = {type = 'Coffin', rule = 'generic'},
    cage = {type = 'Cage', rule = 'generic'},
    restraint = {type = 'Chain', rule = 'generic'},
    well = {type = 'Well', rule = 'well'},
    archery_target = {type = 'ArcheryTarget', rule = 'generic'},
    traction_bench = {type = 'TractionBench', rule = 'generic'},
    nest_box = {type = 'NestBox', rule = 'generic'},
    hive = {type = 'Hive', rule = 'generic'},
    bookcase = {type = 'Bookcase', rule = 'generic'},
    display_case = {type = 'DisplayFurniture', rule = 'generic'},
    offering_place = {type = 'OfferingPlace', rule = 'generic'},
    instrument = {type = 'Instrument', rule = 'generic'},
    animal_trap = {type = 'AnimalTrap', rule = 'generic'},
}
ALIASES = {throne = 'chair', seat = 'chair', box = 'chest', coffer = 'chest', armour_stand = 'armor_stand',
           chain = 'restraint', rope = 'restraint', window = 'glass_window', burial_receptacle = 'coffin',
           grate = 'floor_grate', bars = 'floor_bars', display = 'display_case', container = 'chest'}

-- Item type -> the work order job that makes it (buildingplan's planner table, plus the
-- obvious ones), tried in order against df.job_type.
MAKE_WITH = {
    DOOR = {'ConstructDoor'}, BED = {'ConstructBed'}, CHAIR = {'ConstructThrone'},
    TABLE = {'ConstructTable'}, CABINET = {'ConstructCabinet'}, BOX = {'ConstructChest'},
    ARMORSTAND = {'ConstructArmorStand'}, WEAPONRACK = {'ConstructWeaponRack'},
    STATUE = {'ConstructStatue'}, COFFIN = {'ConstructCoffin'}, SLAB = {'ConstructSlab'},
    HATCH_COVER = {'ConstructHatchCover'}, GRATE = {'ConstructGrate'},
    FLOODGATE = {'ConstructFloodgate'}, TRACTION_BENCH = {'ConstructTractionBench'},
    WINDOW = {'MakeWindow', 'ConstructWindow'}, CAGE = {'MakeCage'}, CHAIN = {'MakeChain'},
    ANIMALTRAP = {'MakeAnimalTrap'}, TOOL = {'MakeTool'}, BLOCKS = {'ConstructBlocks'},
    SMALLGEM = {'CutGems'}, BAR = {'SmeltOre'}, INSTRUMENT = {'MakeInstrument'},
}

local FLOOR_SHAPES = {FLOOR = true, BOULDER = true, PEBBLES = true, TWIG = true, SAPLING = true, SHRUB = true}
local COVERABLE = {FLOOR = true, EMPTY = true, RAMP_TOP = true, STAIR_UP = true, STAIR_UPDOWN = true,
                   STAIR_DOWN = true}
local WALLISH = {WALL = true, FORTIFICATION = true}

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

local function shape_at(x, y, z)
    local f = construct.facts({x = x, y = y, z = z})
    return f and f.shape or nil
end

local function is_floor_at(x, y, z)
    local f = construct.facts({x = x, y = y, z = z})
    return f ~= nil and f.basic == 'Floor'
end

-- nil when the tile can take the type, else a reason. Also returns a warning for doors.
local function tile_problem(rule, pos, f)
    local shape = f.shape or ''
    if rule == 'coverable' then
        if not COVERABLE[shape] then return shape:lower() .. ', not floor, open air, ramp top, or stair' end
        return nil
    end
    if rule == 'well' then
        if shape ~= 'EMPTY' and shape ~= 'RAMP_TOP' then return shape:lower() .. ', a well needs open air' end
        if not (is_floor_at(pos.x + 1, pos.y, pos.z) or is_floor_at(pos.x - 1, pos.y, pos.z)
            or is_floor_at(pos.x, pos.y + 1, pos.z) or is_floor_at(pos.x, pos.y - 1, pos.z)) then
            return 'no floor beside the well tile'
        end
        return nil
    end
    if not FLOOR_SHAPES[shape] then return shape:lower() .. ', not a floor' end
    if rule == 'inside' and f.des.outside then return 'outside (beds must be under a roof)' end
    if rule == 'door' then
        local n = WALLISH[shape_at(pos.x, pos.y - 1, pos.z) or ''] == true
        local s = WALLISH[shape_at(pos.x, pos.y + 1, pos.z) or ''] == true
        local w = WALLISH[shape_at(pos.x - 1, pos.y, pos.z) or ''] == true
        local e = WALLISH[shape_at(pos.x + 1, pos.y, pos.z) or ''] == true
        if not (n or s or w or e) then
            return 'no wall or fortification beside it (doors need an adjacent wall; planned walls do not count until built)'
        end
        if not ((n and s) or (w and e)) then
            local open = {}
            if not n then table.insert(open, 'north') end
            if not s then table.insert(open, 'south') end
            if not w then table.insert(open, 'west') end
            if not e then table.insert(open, 'east') end
            return nil, ('door at (%d,%d) is not between two opposite walls; open sides: %s')
                :format(pos.x, pos.y, table.concat(open, ', '))
        end
    end
    return nil
end

local function resolve_type(name)
    if type(name) ~= 'string' then return nil end
    local key = name:lower():gsub('^%s+', ''):gsub('%s+$', ''):gsub('[%s%-]+', '_')
    key = ALIASES[key] or key
    local entry = TYPES[key]
    if not entry then return nil end
    local btype = df.building_type[entry.type]
    if btype == nil then return nil end
    return key, entry, btype
end

local function known_types()
    local out = {}
    for k in pairs(TYPES) do table.insert(out, k) end
    table.sort(out)
    return out
end

local function make_with_for(filter)
    local itype = filter.item_type
    if type(itype) ~= 'number' or itype < 0 then return nil end
    local token = enum_name(df.item_type, itype)
    for _, job in ipairs(MAKE_WITH[token or ''] or {}) do
        if safe(function() return df.job_type[job] end) ~= nil then
            return {job = job, item = token,
                    tool_use = (filter.has_tool_use and filter.has_tool_use >= 0)
                        and enum_name(df.tool_uses, filter.has_tool_use) or nil}
        end
    end
    return {item = token}
end

local function run(args, apply)
    local key, entry, btype = resolve_type(args.type)
    if not key then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            ('unknown furniture "type" %s; known: %s'):format(tostring(args.type),
                table.concat(known_types(), ', ')))
    end
    local box, berr
    if args.x1 ~= nil then
        box, berr = map.parse_box(args)
        if berr then return berr end
        if box.z1 ~= box.z2 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'a furniture box stays on one level (z1 equal to z2)')
        end
    else
        local pos, perr = (function()
            local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
            if not (x and y and z) then
                return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, 'give "x", "y", "z" or a box "x1".."z2"')
            end
            return {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
        end)()
        if perr then return perr end
        box, berr = map.parse_box({x1 = pos.x, y1 = pos.y, z1 = pos.z, x2 = pos.x, y2 = pos.y, z2 = pos.z})
        if berr then return berr end
    end
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    if limit < 1 then limit = DEFAULT_LIMIT end
    local spec, why = materials.resolve(args.material)
    if why then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
    if spec and spec.form then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('"material" %s names an item form; furniture takes a material such as "any wood", '
             .. '"plum wood", or "sandstone"'):format(tostring(args.material)))
    end

    local counts = {placed = 0, skipped_unsuitable = 0, skipped_building = 0, skipped_edge = 0, over_limit = 0}
    local skipped, targets, warnings = {}, {}, {}
    local function skip(pos, bucket, reason)
        counts[bucket] = counts[bucket] + 1
        if #skipped < LIST_LIMIT then table.insert(skipped, {pos = pos, reason = reason}) end
    end
    local z = box.z1
    for y = box.y1, box.y2 do
        for x = box.x1, box.x2 do
            local pos = {x = x, y = y, z = z}
            local f = construct.facts(pos)
            if not f then
                skip(pos, 'skipped_unsuitable', 'no map block')
            elseif construct.is_edge(pos) then
                skip(pos, 'skipped_edge', 'map edge')
            else
                local problem = construct.base_problem(f)
                local warning = nil
                if not problem then problem, warning = tile_problem(entry.rule, pos, f) end
                if problem then
                    skip(pos, problem:find('^building') and 'skipped_building' or 'skipped_unsuitable', problem)
                elseif #targets >= limit then
                    counts.over_limit = counts.over_limit + 1
                else
                    table.insert(targets, pos)
                    if warning and #warnings < LIST_LIMIT then table.insert(warnings, warning) end
                end
            end
        end
    end

    local filters = construct.filters_for(btype, -1, spec)
    local requirements, make_with, shortage = {}, nil, nil
    if filters then
        for i, filter in ipairs(filters) do
            local applies = i == 1 and spec ~= nil
            local need = {
                item_type = (type(filter.item_type) == 'number' and filter.item_type >= 0)
                    and enum_name(df.item_type, filter.item_type) or 'any',
                quantity = (filter.quantity or 1) * math.max(#targets, 1),
                material = applies and spec.label or 'any',
                available = build.count_suitable(filter, applies and spec or nil),
            }
            table.insert(requirements, need)
            if need.available ~= nil and need.available < need.quantity then
                shortage = shortage or need
                make_with = make_with or make_with_for(filter)
            end
        end
        build.free_filters(filters)
    end
    local result = {
        type = key, building_type = entry.type, box = box, dry_run = not apply, applied = false,
        placed = 0, candidates = #targets, skipped_unsuitable = counts.skipped_unsuitable,
        skipped_building = counts.skipped_building, skipped_edge = counts.skipped_edge,
        over_limit = counts.over_limit, limit = limit, skipped = skipped,
        requirements = requirements, warnings = warnings, buildings = {},
    }
    if #targets == 0 then
        result.status = 'nothing_to_place'
        result.note = 'no tile in the box can take a ' .. key
        return result
    end
    if shortage then
        result.status = 'no_materials'
        result.missing = shortage
        result.make_with = make_with
        result.note = ('%d %s(s) need %d %s; %d available%s; nothing placed'):format(
            #targets, key, shortage.quantity, shortage.item_type:lower(), shortage.available or 0,
            make_with and make_with.job and (': queue a work order for job ' .. make_with.job) or '')
        return result
    end
    if not apply then
        result.status = 'plan'
        result.placed = #targets
        result.note = 'nothing was changed; call build.place with the same arguments to place these'
        return result
    end
    for _, pos in ipairs(targets) do
        local fresh = construct.filters_for(btype, -1, spec)
        local bld, err = B.constructBuilding{type = btype, pos = pos, filters = fresh}
        if bld then
            result.placed = result.placed + 1
            if #result.buildings < LIST_LIMIT then table.insert(result.buildings, bld.id) end
        else
            if fresh then build.free_filters(fresh) end
            skip(pos, 'skipped_unsuitable', 'placement failed: ' .. tostring(err))
            result.skipped_unsuitable = counts.skipped_unsuitable
        end
    end
    result.status = result.placed > 0 and 'placed' or 'nothing_to_place'
    result.applied = result.placed > 0
    result.note = 'blueprints placed; a dwarf fetches the item and installs it'
    return result
end

local function plan(args) return run(args, false) end
local function place(args) return run(args, true) end

function ops()
    return {
        ['build.plan_furniture'] = {namespace = 'workshops', handler = plan, needs_map = true},
        ['build.place'] = {namespace = 'build_write', handler = place, needs_map = true},
    }
end
