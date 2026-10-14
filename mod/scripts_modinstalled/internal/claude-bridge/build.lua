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
function count_suitable(filter, spec)
    if not dfhack.job.isSuitableItem or not dfhack.job.isSuitableMaterial then return nil end
    local count = 0
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
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

local function free_filters(filters)
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

local function building_summary(b)
    return {
        id = b.id,
        kind = enum_name(df.building_type, b:getType()),
        type = (function()
            if df.building_workshopst:is_instance(b) then return enum_name(df.workshop_type, b.type) end
            if df.building_furnacest:is_instance(b) then return enum_name(df.furnace_type, b.type) end
            return nil
        end)(),
        name = safe(function() return b.name ~= '' and b.name or nil end),
        pos = {x = b.centerx, y = b.centery, z = b.z},
    }
end

-- Ask for a building to be removed. A finished building gets a deconstruction job for the
-- dwarves; an unfinished blueprint is cancelled on the spot. Workshops and furnaces only.
local function remove(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a building id') end
    local b = df.building.find(id)
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    if not df.building_workshopst:is_instance(b) and not df.building_furnacest:is_instance(b) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a %s; only workshops and furnaces can be removed here'):format(
                id, enum_name(df.building_type, b:getType()) or '?'))
    end
    local mood = false
    pcall(function()
        for _, job in ipairs(b.jobs) do
            if df.job_type_class[df.job_type.attrs[job.job_type].type] == 'StrangeMood' then
                mood = true
            end
        end
    end)
    if mood then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is claimed by a strange mood; removing it would ruin the mood'):format(id))
    end
    if safe(B.markedForRemoval, b) then
        return {status = 'already_queued', building = building_summary(b)}
    end
    local stage = safe(function() return b:getBuildStage() end)
    local max_stage = safe(function() return b:getMaxBuildStage() end)
    local finished = stage ~= nil and max_stage ~= nil and stage >= max_stage
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
        return {status = finished and 'removed' or 'blueprint_cancelled', building = summary,
                note = 'the building is gone'}
    end
    if safe(B.markedForRemoval, remaining) then
        return {status = 'removal_queued', building = summary,
                note = 'a dwarf will deconstruct it; materials are returned to the ground'}
    end
    return rpc.error_result(rpc.ERR_INTERNAL, 'DFHack neither removed nor queued the building')
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
    }
end
