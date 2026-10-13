-- Noble positions of the fort's government: who holds them, and assigning them.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

local U = dfhack.units

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function translate(name, in_english)
    return safe(function()
        local text = dfhack.translation.translateName(name, in_english)
        if text == '' then return nil end
        return text
    end)
end

-- The site government (the entity that owns the fort's positions).
local function fort_entity()
    local entity = safe(function() return df.global.plotinfo.main.fortress_entity end)
    if entity then return entity end
    return safe(function() return df.historical_entity.find(df.global.plotinfo.group_id) end)
end

-- Names of the set entries in a DF flag array or bool array indexed by an enum.
local function set_names(array, enum)
    local out = {}
    for i = 0, enum._last_item do
        local ok, set = pcall(function() return array[i] end)
        if ok and set then
            table.insert(out, enum[i] or tostring(i))
        end
    end
    return out
end

local function gendered_name(position, unit)
    local field = 'name'
    local sex = unit and safe(function() return unit.sex end)
    if sex == 0 then field = 'name_female' elseif sex == 1 then field = 'name_male' end
    local name = safe(function() return position[field][0] end)
    if name == nil or name == '' then
        name = safe(function() return position.name[0] end)
    end
    return name
end

local function holder_of(assignment)
    local hf_id = assignment.histfig
    if hf_id == nil or hf_id < 0 then return nil end
    local hf = df.historical_figure.find(hf_id)
    local unit_id = hf and hf.unit_id or -1
    local unit = unit_id >= 0 and df.unit.find(unit_id) or nil
    return {
        hist_figure_id = hf_id,
        id = unit and unit.id or nil,
        name = unit and safe(U.getReadableName, unit) or (hf and translate(hf.name, false)) or nil,
        on_map = unit ~= nil and safe(U.isActive, unit) == true,
    }
end

-- Assignment slots for a position, in vector order: {assignment=, index=}.
local function slots_of(entity, position)
    local out = {}
    local assignments = entity.positions.assignments
    for i = 0, #assignments - 1 do
        local a = assignments[i]
        if a.position_id == position.id then
            table.insert(out, {assignment = a, index = i})
        end
    end
    return out
end

local function is_military(position, slots)
    if safe(function() return position.squad_size end) or 0 > 0 then return true end
    for _, slot in ipairs(slots) do
        if safe(function() return slot.assignment.squad_id end) or -1 >= 0 then return true end
    end
    return false
end

local function position_codes(entity)
    local codes = {}
    local own = entity.positions.own
    for i = 0, #own - 1 do table.insert(codes, own[i].code) end
    return codes
end

function describe_position(entity, position)
    local slots = slots_of(entity, position)
    local holders, slot_rows, vacant = {}, {}, 0
    for n, slot in ipairs(slots) do
        local holder = holder_of(slot.assignment)
        if holder then
            table.insert(holders, holder)
        else
            vacant = vacant + 1
        end
        table.insert(slot_rows, {
            slot = n,
            assignment_id = slot.assignment.id,
            holder = holder,
            squad_id = safe(function() return slot.assignment.squad_id end),
        })
    end
    local first_unit = holders[1] and holders[1].id and df.unit.find(holders[1].id) or nil
    return {
        id = position.id,
        code = position.code,
        name = gendered_name(position, first_unit),
        precedence = position.precedence,
        number = position.number,
        holders = holders,
        slots = slot_rows,
        vacant = vacant,
        military = is_military(position, slots),
        land_holder = safe(function() return position.land_holder end),
        flags = set_names(position.flags, df.entity_position_flags),
        responsibilities = set_names(position.responsibilities, df.entity_position_responsibility),
        required = safe(function()
            return {
                office = position.required_office,
                bedroom = position.required_bedroom,
                dining = position.required_dining,
                tomb = position.required_tomb,
                boxes = position.required_boxes,
                cabinets = position.required_cabinets,
                racks = position.required_racks,
                stands = position.required_stands,
            }
        end),
        mandate_max = safe(function() return position.mandate_max end),
        demand_max = safe(function() return position.demand_max end),
        replaced_by = safe(function()
            return position.replaced_by >= 0 and position.replaced_by or nil
        end),
    }
end

local function list(args)
    local entity = fort_entity()
    if not entity then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'no fort government entity is loaded')
    end
    local out = {}
    local own = entity.positions.own
    for i = 0, #own - 1 do
        table.insert(out, describe_position(entity, own[i]))
    end
    table.sort(out, function(a, b)
        if a.precedence ~= b.precedence then return a.precedence < b.precedence end
        return a.code < b.code
    end)
    return {
        entity = {id = entity.id, name = translate(entity.name, true)},
        positions = out,
        count = #out,
    }
end

local function find_position(entity, wanted)
    local own = entity.positions.own
    local as_number = tonumber(wanted)
    local as_code = type(wanted) == 'string' and wanted:upper() or nil
    for i = 0, #own - 1 do
        local p = own[i]
        if (as_number and p.id == as_number) or (as_code and p.code == as_code) then
            return p
        end
    end
    return nil
end

local function unlink_holder(entity, assignment)
    local hf_id = assignment.histfig
    if hf_id < 0 then return end
    local fig = df.historical_figure.find(hf_id)
    if not fig then return end
    local links = fig.entity_links
    for i = #links - 1, 0, -1 do
        local link = links[i]
        if df.histfig_entity_link_positionst:is_instance(link)
            and link.entity_id == entity.id and link.assignment_id == assignment.id then
            links:erase(i)
        end
    end
end

local function link_holder(entity, assignment, index, fig)
    fig.entity_links:insert('#', {
        new = df.histfig_entity_link_positionst,
        entity_id = entity.id,
        link_strength = 100,
        assignment_id = assignment.id,
        assignment_vector_idx = index,
        start_year = df.global.cur_year,
    })
end

-- Same bookkeeping DFHack's make-monarch does: swap the assignment's histfig and keep the
-- holder's entity links in step. The previous holder's link is removed, not archived.
local function assign(args)
    local entity = fort_entity()
    if not entity then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'no fort government entity is loaded')
    end
    if args.position == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"position" (code or id) is required')
    end
    local position = find_position(entity, args.position)
    if not position then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            ('no position "%s"; positions: %s'):format(tostring(args.position),
                table.concat(position_codes(entity), ', ')))
    end
    local slots = slots_of(entity, position)
    if #slots == 0 then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            ('position %s has no assignment slot in this fort'):format(position.code))
    end
    if is_military(position, slots) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('%s is a military position; it is assigned through squads, not here'):format(position.code))
    end

    local unit, fig = nil, nil
    if args.id ~= nil then
        local id = tonumber(args.id)
        if not id then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a unit id or null to vacate')
        end
        unit = df.unit.find(id)
        if not unit then
            return rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. id)
        end
        if not U.isCitizen(unit, true) or U.isDead(unit) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'only a living citizen can hold a position')
        end
        if unit.hist_figure_id < 0 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'unit has no historical figure record')
        end
        fig = df.historical_figure.find(unit.hist_figure_id)
        if not fig then
            return rpc.error_result(rpc.ERR_INTERNAL, 'historical figure record is missing')
        end
    end

    -- Pick the slot: explicit, else the one this unit already holds, else first vacant, else first.
    local chosen = nil
    if args.slot ~= nil then
        local n = tonumber(args.slot)
        if not n or not slots[n] then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('"slot" must be between 1 and %d'):format(#slots))
        end
        chosen = slots[n]
    else
        if unit then
            for _, slot in ipairs(slots) do
                if slot.assignment.histfig == unit.hist_figure_id then chosen = slot end
            end
        end
        if not chosen then
            for _, slot in ipairs(slots) do
                if slot.assignment.histfig < 0 then chosen = slot break end
            end
        end
        chosen = chosen or slots[1]
    end

    local assignment = chosen.assignment
    local previous = holder_of(assignment)
    local changed = false
    if unit and assignment.histfig == unit.hist_figure_id then
        -- already holds it
    elseif not unit and assignment.histfig < 0 then
        -- already vacant
    else
        unlink_holder(entity, assignment)
        if assignment.histfig >= 0 then
            pcall(function() assignment.histfig2 = assignment.histfig end)
        end
        assignment.histfig = unit and unit.hist_figure_id or -1
        if unit then
            link_holder(entity, assignment, chosen.index, fig)
        end
        changed = true
    end
    return {
        changed = changed,
        previous = previous,
        position = describe_position(entity, position),
    }
end

function ops()
    return {
        ['nobles.list'] = {namespace = 'nobles', handler = list, needs_map = true},
        ['nobles.assign'] = {namespace = 'nobles_write', handler = assign, needs_map = true},
    }
end
