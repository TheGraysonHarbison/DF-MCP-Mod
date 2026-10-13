-- Manager work orders: read, search job types, create, edit, delete. Plan section 10.
-- The status bitfield (validated, active) is never written here: only the manager approves.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

DEFAULT_LIMIT = 25

FREQUENCIES = {'OneTime', 'Daily', 'Monthly', 'Seasonally', 'Yearly'}

-- Item types whose subtypes come from raws, and the itemdefs vector holding them.
local SUBTYPE_VECTORS = {
    WEAPON = 'weapons', ARMOR = 'armor', HELM = 'helms', GLOVES = 'gloves', SHOES = 'shoes',
    PANTS = 'pants', SHIELD = 'shields', AMMO = 'ammo', TRAPCOMP = 'trapcomps',
    SIEGEAMMO = 'siege_ammo', TOOL = 'tools', INSTRUMENT = 'instruments', TOY = 'toys',
    FOOD = 'food',
}

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

local function true_flags(bitfield)
    local out = {}
    pcall(function()
        for name, value in pairs(bitfield) do
            if value == true then table.insert(out, name) end
        end
    end)
    table.sort(out)
    return out
end

local function orders_vector()
    return df.global.world.manager_orders.all
end

local function job_caption(job_type)
    return safe(function() return df.job_type.attrs[job_type].caption end)
end

local function material_name(mat_type, mat_index)
    if mat_type == nil or mat_type < 0 then return nil end
    return safe(function() return dfhack.matinfo.decode(mat_type, mat_index):toString() end)
end

local function find_reaction(code_or_name)
    local wanted = code_or_name:lower()
    for _, reaction in ipairs(df.global.world.raws.reactions.reactions) do
        if reaction.code:lower() == wanted or reaction.name:lower() == wanted then
            return reaction
        end
    end
    return nil
end

local function reaction_info(code)
    if code == nil or code == '' then return nil end
    local reaction = find_reaction(code)
    return {code = code, name = reaction and reaction.name or nil}
end

local function subtype_info(item_type, subtype)
    if item_type == nil or item_type < 0 or subtype == nil or subtype < 0 then return nil end
    local def = safe(dfhack.items.getSubtypeDef, item_type, subtype)
    if not def then return {index = subtype} end
    return {index = subtype, id = safe(function() return def.id end),
            name = safe(function() return def.name end)}
end

local function item_condition(c)
    local out = {
        compare = enum_name(df.manager_order_condition_item.T_compare_type, c.compare_type)
            or safe(function() return c.compare_type end),
        value = c.compare_val,
        item_type = c.item_type >= 0 and enum_name(df.item_type, c.item_type) or nil,
        item_subtype = subtype_info(c.item_type, c.item_subtype),
        material = material_name(c.mat_type, c.mat_index),
        reaction_class = safe(function() return c.reaction_class ~= '' and c.reaction_class or nil end),
        has_material_reaction_product = safe(function()
            return c.has_material_reaction_product ~= '' and c.has_material_reaction_product or nil
        end),
        metal_ore = safe(function() return c.metal_ore >= 0 and c.metal_ore or nil end),
        min_dimension = safe(function() return c.min_dimension > 0 and c.min_dimension or nil end),
    }
    local flags = {}
    for _, field in ipairs({'flags1', 'flags2', 'flags3', 'flags4', 'flags5'}) do
        for _, name in ipairs(true_flags(safe(function() return c[field] end))) do
            table.insert(flags, name)
        end
    end
    out.flags = flags
    local what = out.item_subtype and out.item_subtype.name or out.item_type or 'items'
    out.text = ('%s %s %s%s'):format(tostring(out.compare), tostring(out.value), what,
        out.material and (' of ' .. out.material) or '')
    return out
end

local function order_condition(c)
    local condition = enum_name(df.workquota_order_condition_type, c.condition)
    return {
        order_id = c.order_id,
        condition = condition,
        flags = true_flags(c.flags),
        text = ('order %d is %s'):format(c.order_id, tostring(condition)),
    }
end

function row(order)
    local items, conditions = {}, {}
    pcall(function()
        for _, c in ipairs(order.item_conditions) do table.insert(items, item_condition(c)) end
    end)
    pcall(function()
        for _, c in ipairs(order.order_conditions) do table.insert(conditions, order_condition(c)) end
    end)
    local validated = safe(function() return order.status.validated end) == true
    local out = {
        id = order.id,
        job = enum_name(df.job_type, order.job_type),
        job_name = job_caption(order.job_type),
        item_type = order.item_type >= 0 and enum_name(df.item_type, order.item_type) or nil,
        item_subtype = subtype_info(order.item_type, order.item_subtype),
        material = material_name(order.mat_type, order.mat_index),
        material_category = true_flags(order.material_category),
        reaction = reaction_info(order.reaction_name),
        amount = {left = order.amount_left, total = order.amount_total,
                  unlimited = order.amount_total == 0},
        frequency = enum_name(df.workquota_frequency_type, order.frequency),
        status = {validated = validated,
                  active = safe(function() return order.status.active end) == true},
        approved = validated,
        max_workshops = order.max_workshops,
        conditions = {items = items, orders = conditions},
    }
    if order.workshop_id >= 0 then out.workshop_id = order.workshop_id end
    if order.finished_year >= 0 then
        out.next_check = {year = order.finished_year, year_tick = order.finished_year_tick}
    end
    return out
end

local function parse_limit(args, default)
    if args.limit == nil then return default end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

local function find_order(id)
    local vec = orders_vector()
    for i = 0, #vec - 1 do
        if vec[i].id == id then return vec[i], i end
    end
    return nil
end

----------------------------------------------------------------------------------------------
-- reads

local function list(args)
    local limit, err = parse_limit(args, DEFAULT_LIMIT)
    if err then return err end
    local offset = tonumber(args.offset) or 0
    local only_approved = args.approved
    local query = type(args.query) == 'string' and args.query:lower() or nil
    local rows, total = {}, 0
    local vec = orders_vector()
    for i = 0, #vec - 1 do
        local r = row(vec[i])
        local keep = true
        if only_approved ~= nil and r.approved ~= (only_approved == true) then keep = false end
        if keep and query then
            local text = ((r.job_name or '') .. ' ' .. (r.job or '') .. ' '
                .. (r.reaction and r.reaction.name or '') .. ' ' .. (r.material or '')
                .. ' ' .. (r.item_subtype and r.item_subtype.name or '')):lower()
            keep = text:find(query, 1, true) ~= nil
        end
        if keep then
            total = total + 1
            if total > offset and #rows < limit then table.insert(rows, r) end
        end
    end
    return {total = total, count = #rows, offset = offset, limit = limit,
            truncated = total > offset + #rows, orders = rows}
end

local function get(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be an order id') end
    local order = find_order(id)
    if not order then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no work order with id ' .. id) end
    return row(order)
end

-- Job types that can be ordered: manufacturing and similar, not designations or moods.
local ORDERABLE_CLASSES = {Manufacture = true, Improvement = true, Misc = true,
                           Hunting = true, Hauling = true, Gathering = true, MedicalJob = true}

local function job_entry(job_type)
    if df.job_type[job_type] == nil then return nil end  -- gap in the enum
    local attrs = df.job_type.attrs[job_type]
    local possible = {}
    pcall(function()
        for _, t in ipairs(attrs.possible_item) do
            table.insert(possible, enum_name(df.item_type, t))
        end
    end)
    local item = enum_name(df.item_type, attrs.item)
    return {
        job = df.job_type[job_type],
        caption = attrs.caption,
        class = enum_name(df.job_type_class, attrs.type),
        item = item ~= 'NONE' and item or nil,
        possible_items = #possible > 0 and possible or nil,
        skill = (function()
            local s = enum_name(df.job_skill, attrs.skill)
            return s ~= 'NONE' and s or nil
        end)(),
    }
end

local function jobs(args)
    if type(args.query) ~= 'string' or args.query:match('^%s*$') then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"query" must be a non-empty string')
    end
    local limit, err = parse_limit(args, DEFAULT_LIMIT)
    if err then return err end
    local query = args.query:lower()
    local job_rows, reaction_rows = {}, {}
    for i = 0, df.job_type._last_item do
        local entry = safe(job_entry, i)
        if entry and entry.caption and ORDERABLE_CLASSES[entry.class or 'Misc']
            and not entry.job:match('^StrangeMood')
            and ((entry.caption:lower():find(query, 1, true))
                 or (entry.job:lower():find(query, 1, true))) then
            table.insert(job_rows, entry)
        end
    end
    pcall(function()
        for _, reaction in ipairs(df.global.world.raws.reactions.reactions) do
            if reaction.name:lower():find(query, 1, true)
                or reaction.code:lower():find(query, 1, true) then
                local buildings = {}
                pcall(function()
                    for _, b in ipairs(reaction.building.str) do
                        table.insert(buildings, b.value)
                    end
                end)
                table.insert(reaction_rows, {reaction = reaction.code, name = reaction.name,
                                             buildings = buildings})
            end
        end
    end)
    local function cap(list)
        local total = #list
        if total > limit then
            local kept = {}
            for i = 1, limit do kept[i] = list[i] end
            return kept, total, true
        end
        return list, total, false
    end
    local jobs_out, jobs_total, jobs_cut = cap(job_rows)
    local reactions_out, reactions_total, reactions_cut = cap(reaction_rows)
    return {
        query = args.query,
        jobs = jobs_out, jobs_total = jobs_total,
        reactions = reactions_out, reactions_total = reactions_total,
        truncated = jobs_cut or reactions_cut,
    }
end

----------------------------------------------------------------------------------------------
-- writes (namespace orders_write)

local function resolve_job(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local direct = safe(function() return df.job_type[name] end)
    if type(direct) == 'number' then return direct end
    local wanted = name:lower()
    for i = 0, df.job_type._last_item do
        local token = df.job_type[i]
        local caption = job_caption(i)
        if (token and token:lower() == wanted) or (caption and caption:lower() == wanted) then
            return i
        end
    end
    return nil
end

local function resolve_item_type(name)
    if name == nil then return nil end
    local value = safe(function() return df.item_type[tostring(name):upper()] end)
    if type(value) == 'number' then return value end
    return nil
end

local function resolve_subtype(item_type, name)
    local field = SUBTYPE_VECTORS[df.item_type[item_type] or '']
    if not field then return nil, 'this item type has no subtypes' end
    local defs = safe(function() return df.global.world.raws.itemdefs[field] end)
    if not defs then return nil, 'no raws for this item type' end
    local wanted = tostring(name):lower()
    for _, def in ipairs(defs) do
        if def.id:lower() == wanted or (def.name and def.name:lower() == wanted) then
            return def.subtype
        end
    end
    return nil, ('no %s subtype named "%s"'):format(df.item_type[item_type]:lower(), name)
end

local function resolve_frequency(name)
    if name == nil then return df.workquota_frequency_type.OneTime end
    for _, f in ipairs(FREQUENCIES) do
        if f:lower() == tostring(name):lower() then return df.workquota_frequency_type[f] end
    end
    return nil
end

local function create(args)
    local job_type = nil
    local reaction = nil
    if args.reaction ~= nil then
        reaction = find_reaction(tostring(args.reaction))
        if not reaction then
            return rpc.error_result(rpc.ERR_NOT_FOUND,
                ('no reaction "%s"; search with orders.jobs'):format(tostring(args.reaction)))
        end
        job_type = df.job_type.CustomReaction
    else
        job_type = resolve_job(args.job)
        if not job_type then
            return rpc.error_result(rpc.ERR_NOT_FOUND,
                ('no job type "%s"; search with orders.jobs'):format(tostring(args.job)))
        end
        local class = enum_name(df.job_type_class, df.job_type.attrs[job_type].type)
        if not ORDERABLE_CLASSES[class or 'Misc'] or df.job_type[job_type]:match('^StrangeMood') then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('%s cannot be a work order'):format(df.job_type[job_type]))
        end
    end

    local amount = args.amount == nil and 1 or tonumber(args.amount)
    if not amount or amount < 0 or amount ~= math.floor(amount) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"amount" must be a whole number (0 = unlimited)')
    end
    local frequency = resolve_frequency(args.frequency)
    if not frequency then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"frequency" must be one of ' .. table.concat(FREQUENCIES, ', '))
    end

    local item_type = resolve_item_type(args.item_type)
    if args.item_type ~= nil and item_type == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'unknown "item_type" ' .. tostring(args.item_type))
    end
    if item_type == nil and job_type ~= df.job_type.CustomReaction then
        local default = df.job_type.attrs[job_type].item
        if default ~= nil and default >= 0 then item_type = default end
    end
    local item_subtype = -1
    if args.item_subtype ~= nil then
        if item_type == nil then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"item_subtype" needs an "item_type"')
        end
        local sub, why = resolve_subtype(item_type, args.item_subtype)
        if not sub then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
        item_subtype = sub
    end

    local mat_type, mat_index = -1, -1
    if args.material ~= nil then
        local info = safe(dfhack.matinfo.find, tostring(args.material))
        if not info then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('unknown "material" %s (use a token such as INORGANIC:IRON or PLANT:PLUMP_HELMET:DRINK)')
                    :format(tostring(args.material)))
        end
        mat_type, mat_index = info.type, info.index
    end
    local categories = {}
    if args.material_category ~= nil then
        local list = type(args.material_category) == 'table' and args.material_category
            or {args.material_category}
        for _, name in ipairs(list) do table.insert(categories, tostring(name)) end
    end
    local max_workshops = tonumber(args.max_workshops) or 0
    local workshop_id = tonumber(args.workshop_id) or -1
    if workshop_id >= 0 and not df.building.find(workshop_id) then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. workshop_id)
    end

    local handler = df.global.world.manager_orders
    local order = df.manager_order:new()
    order.id = handler.manager_order_next_id
    handler.manager_order_next_id = handler.manager_order_next_id + 1
    order.job_type = job_type
    if reaction then order.reaction_name = reaction.code end
    if item_type ~= nil then order.item_type = item_type end
    order.item_subtype = item_subtype
    order.mat_type = mat_type
    order.mat_index = mat_index
    -- Validate category names against the order's own bitfield before it is inserted.
    for _, name in ipairs(categories) do
        local ok = pcall(function() order.material_category[name] = true end)
        if not ok or safe(function() return order.material_category[name] end) ~= true then
            local valid = {}
            pcall(function()
                for flag in pairs(order.material_category) do
                    if type(flag) == 'string' then table.insert(valid, flag) end
                end
            end)
            table.sort(valid)
            handler.manager_order_next_id = handler.manager_order_next_id - 1
            pcall(function() order:delete() end)
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('unknown "material_category" %s; valid: %s'):format(name, table.concat(valid, ', ')))
        end
    end
    order.amount_left = amount
    order.amount_total = amount
    order.frequency = frequency
    order.max_workshops = max_workshops
    order.workshop_id = workshop_id
    handler.all:insert('#', order)
    return {created = true, order = row(order)}
end

local function edit(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be an order id') end
    local order = find_order(id)
    if not order then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no work order with id ' .. id) end
    local changed = {}
    if args.amount ~= nil then
        local amount = tonumber(args.amount)
        if not amount or amount < 0 or amount ~= math.floor(amount) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"amount" must be a whole number (0 = unlimited)')
        end
        local done = order.amount_total - order.amount_left
        order.amount_total = amount
        order.amount_left = amount == 0 and 0 or math.max(amount - done, 0)
        table.insert(changed, 'amount')
    end
    if args.frequency ~= nil then
        local frequency = resolve_frequency(args.frequency)
        if not frequency then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"frequency" must be one of ' .. table.concat(FREQUENCIES, ', '))
        end
        order.frequency = frequency
        table.insert(changed, 'frequency')
    end
    if args.max_workshops ~= nil then
        local n = tonumber(args.max_workshops)
        if not n or n < 0 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"max_workshops" must be 0 or more')
        end
        order.max_workshops = math.floor(n)
        table.insert(changed, 'max_workshops')
    end
    if args.workshop_id ~= nil then
        local wid = tonumber(args.workshop_id)
        if wid == nil then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"workshop_id" must be a building id or -1')
        end
        if wid >= 0 and not df.building.find(wid) then
            return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. wid)
        end
        order.workshop_id = wid
        table.insert(changed, 'workshop_id')
    end
    if #changed == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'nothing to change; pass amount, frequency, max_workshops, or workshop_id')
    end
    return {changed = changed, order = row(order)}
end

local function delete(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be an order id') end
    local order, index = find_order(id)
    if not order then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no work order with id ' .. id) end
    local summary = row(order)
    orders_vector():erase(index)
    pcall(function() order:delete() end)
    return {deleted = true, order = summary}
end

function ops()
    return {
        ['orders.list'] = {namespace = 'orders', handler = list, needs_map = true},
        ['orders.get'] = {namespace = 'orders', handler = get, needs_map = true},
        ['orders.jobs'] = {namespace = 'orders', handler = jobs, needs_world = true},
        ['orders.create'] = {namespace = 'orders_write', handler = create, needs_map = true},
        ['orders.edit'] = {namespace = 'orders_write', handler = edit, needs_map = true},
        ['orders.delete'] = {namespace = 'orders_write', handler = delete, needs_map = true},
    }
end
