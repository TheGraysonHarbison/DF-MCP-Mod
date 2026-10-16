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
local farms = reqscript('internal/claude-bridge/farms')

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
    -- Phase 16: traps and military buildings (placement only; linking is an open issue).
    lever = {type = 'Trap', subtype = 'Lever', rule = 'generic'},
    pressure_plate = {type = 'Trap', subtype = 'PressurePlate', rule = 'generic'},
    cage_trap = {type = 'Trap', subtype = 'CageTrap', rule = 'generic'},
    stone_fall_trap = {type = 'Trap', subtype = 'StoneFallTrap', rule = 'generic'},
    weapon_trap = {type = 'Trap', subtype = 'WeaponTrap', rule = 'generic'},
    upright_spike = {type = 'Weapon', rule = 'generic'},
    catapult = {type = 'SiegeEngine', subtype = 'Catapult', rule = 'generic', big = true},
    ballista = {type = 'SiegeEngine', subtype = 'Ballista', rule = 'generic', big = true},
    trade_depot = {type = 'TradeDepot', rule = 'generic', big = true},
}
SUBTYPE_ENUMS = {Trap = 'trap_type', SiegeEngine = 'siegeengine_type'}
PLATE_TRIGGERS = {'units', 'water', 'magma', 'track'}
ALIASES = {spike = 'upright_spike', spear_trap = 'upright_spike', stonefall_trap = 'stone_fall_trap',
           depot = 'trade_depot', plate = 'pressure_plate', throne = 'chair', seat = 'chair', box = 'chest', coffer = 'chest', armour_stand = 'armor_stand',
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
    TRAPPARTS = {'ConstructMechanisms'}, TRAPCOMP = {'MakeTrapComponent'}, WEAPON = {'MakeWeapon'},
    CATAPULTPARTS = {'ConstructCatapultParts'}, BALLISTAPARTS = {'ConstructBallistaParts'},
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
    local subtype = -1
    if entry.subtype then
        local enum = df[SUBTYPE_ENUMS[entry.type]]
        subtype = enum and enum[entry.subtype]
        if subtype == nil then return nil end
    end
    return key, entry, btype, subtype
end

-- Pressure plate settings from the request: which triggers, who trips it, whether it
-- resets, and the depth or size windows (building_trapst.plate_info).
local function parse_plate(args)
    local plate = args.plate
    if plate == nil then return nil end
    if type(plate) ~= 'table' then return nil, '"plate" must be an object' end
    local out = {triggers = {}, citizens = plate.citizens == true, resets = plate.resets ~= false}
    for _, trig in ipairs(plate.triggers or {'units'}) do
        local ok = false
        for _, t in ipairs(PLATE_TRIGGERS) do if t == trig then ok = true end end
        if not ok then return nil, '"plate.triggers" entries must be units, water, magma, or track' end
        out.triggers[trig] = true
    end
    local function range(name, lo, hi, default_min, default_max)
        local vmin = tonumber(plate[name .. '_min']) or default_min
        local vmax = tonumber(plate[name .. '_max']) or default_max
        if vmin < lo or vmax > hi or vmin > vmax then
            return nil, ('"plate.%s_min/max" must be %d-%d with min <= max'):format(name, lo, hi)
        end
        return {math.floor(vmin), math.floor(vmax)}
    end
    local err
    out.unit, err = range('unit', 1, 10000000, 50000, 200000)
    if not out.unit then return nil, err end
    out.water, err = range('water', 1, 7, 1, 7)
    if not out.water then return nil, err end
    out.magma, err = range('magma', 1, 7, 1, 7)
    if not out.magma then return nil, err end
    out.track, err = range('track', 1, 2000, 1, 2000)
    if not out.track then return nil, err end
    return out
end

local function apply_plate(bld, plate)
    pcall(function()
        local info = bld.plate_info
        for _, t in ipairs(PLATE_TRIGGERS) do info.flags[t] = plate.triggers[t] == true end
        info.flags.citizens = plate.citizens
        info.flags.resets = plate.resets
        info.unit_min, info.unit_max = plate.unit[1], plate.unit[2]
        info.water_min, info.water_max = plate.water[1], plate.water[2]
        info.magma_min, info.magma_max = plate.magma[1], plate.magma[2]
        info.track_min, info.track_max = plate.track[1], plate.track[2]
    end)
end

local function is_farm_plot(name)
    return type(name) == 'string' and name:lower():gsub('[%s%-]+', '_') == 'farm_plot'
end

local function known_types()
    local out = {}
    for k in pairs(TYPES) do table.insert(out, k) end
    table.sort(out)
    return out
end

local function make_with_for(filter)
    local itype = filter.item_type
    local token = (type(itype) == 'number' and itype >= 0) and enum_name(df.item_type, itype) or nil
    if not token then
        local _, vector = build.filter_vector(filter)
        if vector == 'ANY_SPIKE' then token = 'TRAPCOMP' elseif vector == 'ANY_WEAPON' then token = 'WEAPON' end
    end
    if not token then return nil end
    for _, job in ipairs(MAKE_WITH[token or ''] or {}) do
        if safe(function() return df.job_type[job] end) ~= nil then
            return {job = job, item = token,
                    tool_use = (filter.has_tool_use and filter.has_tool_use >= 0)
                        and enum_name(df.tool_uses, filter.has_tool_use) or nil}
        end
    end
    return {item = token}
end

-- One multi-tile building (siege engine, trade depot) at a top-left corner.
local function run_big(args, key, entry, btype, subtype, apply)
    local x, y, z = tonumber(args.x or args.x1), tonumber(args.y or args.y1), tonumber(args.z or args.z1)
    if not (x and y and z) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, ('a %s takes one position: its top-left corner x, y, z'):format(key))
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    local _, w, h = B.getCorrectSize(nil, nil, btype, subtype, -1, 0)
    local footprint = {origin = {x = x, y = y, z = z}, width = w, height = h}
    local spec, why = materials.resolve(args.material)
    if why then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
    local skipped = {}
    for ty = y, y + h - 1 do
        for tx = x, x + w - 1 do
            local pos = {x = tx, y = ty, z = z}
            local f = construct.facts(pos)
            local problem = (not f) and 'no map block' or (construct.is_edge(pos) and 'map edge')
                or construct.base_problem(f) or (not FLOOR_SHAPES[f.shape or ''] and (tostring(f.shape):lower() .. ', not a floor'))
            if problem then table.insert(skipped, {pos = pos, reason = problem}) end
        end
    end
    local result = {type = key, building_type = entry.type, footprint = footprint, dry_run = not apply,
                    applied = false, placed = 0, candidates = #skipped == 0 and 1 or 0,
                    skipped = skipped, skipped_unsuitable = #skipped, requirements = {}, warnings = {}, buildings = {}}
    if #skipped > 0 then
        result.status = 'nothing_to_place'
        result.note = ('%d of %d footprint tiles cannot take a %s'):format(#skipped, w * h, key)
        return result
    end
    local filters = construct.filters_for(btype, subtype, spec)
    local shortage, make_with = nil, nil
    if filters then
        for i, filter in ipairs(filters) do
            local applies = i == 1 and spec ~= nil
            local need = {
                item_type = build.filter_label(filter),
                quantity = filter.quantity or 1,
                material = applies and spec.label or 'any',
                available = build.count_suitable(filter, applies and spec or nil),
            }
            table.insert(result.requirements, need)
            if need.available ~= nil and need.available < need.quantity then
                shortage = shortage or need
                make_with = make_with or make_with_for(filter)
            end
        end
        build.free_filters(filters)
    end
    if shortage then
        result.status, result.missing, result.make_with = 'no_materials', shortage, make_with
        result.note = ('a %s needs %d %s; %d available%s; nothing placed'):format(key, shortage.quantity,
            shortage.item_type:lower(), shortage.available or 0,
            make_with and make_with.job and (': queue a work order for job ' .. make_with.job) or '')
        return result
    end
    if not apply then
        result.status, result.placed = 'plan', 1
        result.note = 'nothing was changed; call build.place with the same arguments to place it'
        return result
    end
    local fresh = construct.filters_for(btype, subtype, spec)
    local bld, err = B.constructBuilding{type = btype, subtype = subtype, pos = {x = x, y = y, z = z}, filters = fresh}
    if not bld then
        if fresh then build.free_filters(fresh) end
        result.status = 'nothing_to_place'
        result.note = 'placement failed: ' .. tostring(err)
        return result
    end
    result.status, result.applied, result.placed, result.buildings = 'placed', true, 1, {bld.id}
    result.note = 'blueprint placed; dwarves haul the parts and build it'
    return result
end

local function run(args, apply)
    local key0, entry0, btype0, subtype0 = resolve_type(args.type)
    if key0 and entry0.big then
        return run_big(args, key0, entry0, btype0, subtype0, apply)
    end
    if is_farm_plot(args.type) then
        -- One building over the box (or the single tile); the farms module owns the rules.
        if args.x1 == nil then
            local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
            if not (x and y and z) then
                return rpc.error_result(rpc.ERR_BAD_REQUEST, 'give "x", "y", "z" or a box "x1".."z2"')
            end
            args = {x1 = x, y1 = y, z1 = z, x2 = x, y2 = y, z2 = z, fertilize = args.fertilize}
        end
        return farms.place(args, apply)
    end
    local key, entry, btype, subtype = resolve_type(args.type)
    if not key then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            ('unknown furniture "type" %s; known: %s'):format(tostring(args.type),
                table.concat(known_types(), ', ')))
    end
    local plate, perr = parse_plate(args)
    if perr then return rpc.error_result(rpc.ERR_BAD_REQUEST, perr) end
    if plate and entry.subtype ~= 'PressurePlate' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"plate" settings only apply to a pressure_plate')
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

    local filters = construct.filters_for(btype, subtype, spec)
    local requirements, make_with, shortage = {}, nil, nil
    if filters then
        for i, filter in ipairs(filters) do
            local applies = i == 1 and spec ~= nil
            local need = {
                item_type = build.filter_label(filter),
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
        local fresh = construct.filters_for(btype, subtype, spec)
        local bld, err = B.constructBuilding{type = btype, subtype = subtype, pos = pos, filters = fresh}
        if bld then
            if plate then apply_plate(bld, plate) end
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
    result.plate = plate and {triggers = plate.triggers, citizens = plate.citizens, resets = plate.resets} or nil
    result.note = 'blueprints placed; a dwarf fetches the item and installs it'
    if entry.subtype == 'CageTrap' or entry.subtype == 'StoneFallTrap' then
        result.note = result.note .. '; the game loads a cage or boulder into it after it is built'
    end
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
