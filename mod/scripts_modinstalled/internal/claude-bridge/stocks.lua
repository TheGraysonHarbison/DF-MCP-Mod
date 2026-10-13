-- Stock counts, the stocks list, item search, and artifacts. Read-only. Plan section 9.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local state = reqscript('internal/claude-bridge/state')
local nobles = reqscript('internal/claude-bridge/nobles')

-- Top-bar categories in the game's order, and the plotinfo.tasks.food field behind each.
BAR_CATEGORIES = {
    {key = 'food', field = 'total'},
    {key = 'drink', field = 'drink'},
    {key = 'seed', field = 'seeds'},
    {key = 'meat', field = 'meat'},
    {key = 'fish', field = 'fish'},
    {key = 'plant', field = 'plant'},
    {key = 'other', field = 'other'},
}

-- Rounding step for each achieved precision level. 0 means exact.
PRECISION_STEP = {
    NONE = 10, nearest_10 = 10, nearest_100 = 100, nearest_1000 = 1000,
    nearest_10000 = 10000, all_accurate = 0,
}

DEFAULT_LIMIT = 50

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

local function translate(name, in_english)
    return safe(function()
        local text = dfhack.translation.translateName(name, in_english)
        if text == '' then return nil end
        return text
    end)
end

-- Estimates round UP to the next multiple of the step and carry a "~" (plan 9.2).
function estimate(value, step)
    if step == 0 then
        return {value = value, display = tostring(value), estimated = false}
    end
    local shown = math.ceil(value / step) * step
    return {value = shown, display = '~' .. shown, estimated = true}
end

function bookkeeper_info()
    local n = df.global.plotinfo.nobles
    local achieved = enum_name(df.record_precision_level_type, n.bookkeeper_precision) or 'NONE'
    local goal = enum_name(df.record_precision_level_type, n.bookkeeper_settings)
    local holder = safe(nobles.position_holder, 'BOOKKEEPER')
    return {
        assigned = holder ~= nil,
        bookkeeper = holder,
        precision = achieved,
        goal = goal,
        cooldown = n.bookkeeper_cooldown,
        step = PRECISION_STEP[achieved] or 10,
    }
end

-- The stocks_true toggle (settings window, Items group). Off means bookkeeper view: Claude
-- sees only what the player's screens show, estimates and all.
local function true_view()
    return state.is_allowed('stocks_true')
end

local function mode_name()
    return true_view() and 'true' or 'bookkeeper'
end

----------------------------------------------------------------------------------------------
-- top bar

local function bar_entry(food, spec, step, truthful)
    local value = food[spec.field]
    local shown = estimate(value, step)
    local entry = {display = shown.display, estimated = shown.estimated, shown = shown.value}
    if truthful then entry.value = value end
    return entry
end

local function bar(args)
    local food = df.global.plotinfo.tasks.food
    local info = bookkeeper_info()
    local truthful = true_view()
    local wanted = args.category
    if wanted ~= nil then
        local spec = nil
        for _, s in ipairs(BAR_CATEGORIES) do
            if s.key == wanted then spec = s end
        end
        if not spec then
            local keys = {}
            for _, s in ipairs(BAR_CATEGORIES) do table.insert(keys, s.key) end
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"category" must be one of ' .. table.concat(keys, ', '))
        end
        local entry = bar_entry(food, spec, info.step, truthful)
        entry.category = spec.key
        entry.mode = mode_name()
        entry.bookkeeper = info
        return entry
    end
    local counts = {}
    for _, spec in ipairs(BAR_CATEGORIES) do
        counts[spec.key] = bar_entry(food, spec, info.step, truthful)
    end
    return {
        mode = mode_name(),
        bookkeeper = info,
        counts = counts,
    }
end

----------------------------------------------------------------------------------------------
-- stocks list

-- Items the Stocks screen does not count at all (from DFHack's stocks plugin).
local EXCLUDE_FLAGS = {'trader', 'hostile', 'garbage_collect', 'removed', 'murder', 'construction'}
-- Items it counts but shows as unavailable.
local UNAVAILABLE_FLAGS = {'forbid', 'dump', 'melt', 'in_building', 'in_job'}

local function any_flag(item, names)
    for _, name in ipairs(names) do
        if safe(function() return item.flags[name] end) then return true end
    end
    return false
end

local BAG_MATERIAL_FLAGS = {'LEATHER', 'SILK', 'THREAD_PLANT', 'YARN'}

local function is_bag(item, info)
    if df.item_type[item:getType()] ~= 'BOX' or not info then return false end
    for _, flag in ipairs(BAG_MATERIAL_FLAGS) do
        if safe(function() return info.material.flags[flag] end) then return true end
    end
    return false
end

local function category_of(item, info)
    if is_bag(item, info) then return 'bag', 'bag' end
    local type_id = item:getType()
    local token = df.item_type[type_id] or tostring(type_id)
    local caption = safe(function() return df.item_type.attrs[type_id].caption end)
    return token:lower(), caption or token:lower()
end

local function item_kind(item, caption)
    local def = safe(function() return dfhack.items.getSubtypeDef(item:getType(), item:getSubtype()) end)
    local name = def and safe(function() return def.name end)
    if name and name ~= '' then return name end
    return caption
end

-- Fish, raw fish, eggs, and live vermin carry a creature and caste instead of a material.
local function caste_material(item)
    return safe(function()
        local creature = df.global.world.raws.creatures.all[item.race]
        local caste = creature.caste[item.caste]
        local name = caste.caste_name[0]
        if name == nil or name == '' then name = creature.name[0] end
        return name
    end)
end

local function material_of(item, info)
    if item and safe(dfhack.items.isCasteMaterial, item:getType()) then
        local name = caste_material(item)
        if name then return name end
    end
    if not info then return nil end
    return safe(function() return info:toString() end)
end

-- Walks IN_PLAY once and returns categories keyed by token.
local function collect(query)
    local categories = {}
    local needle = query and query:lower() or nil
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        if not any_flag(item, EXCLUDE_FLAGS) then
            local info = safe(dfhack.matinfo.decode, item)
            local key, caption = category_of(item, info)
            local kind = item_kind(item, caption)
            local material = material_of(item, info)
            local row_key = (kind or '?') .. '|' .. (material or '?')
            local matches = true
            if needle then
                local text = ((kind or '') .. ' ' .. (material or '') .. ' ' .. caption):lower()
                matches = text:find(needle, 1, true) ~= nil
            end
            if matches then
                local cat = categories[key]
                if not cat then
                    cat = {name = caption, total = 0, unavailable = 0, rows = {}, index = {}}
                    categories[key] = cat
                end
                local row = cat.index[row_key]
                if not row then
                    row = {item = kind, material = material, count = 0, quantity = 0, unavailable = 0}
                    cat.index[row_key] = row
                    table.insert(cat.rows, row)
                end
                local stack = safe(function() return item:getStackSize() end) or 1
                row.count = row.count + 1
                row.quantity = row.quantity + stack
                cat.total = cat.total + stack
                if any_flag(item, UNAVAILABLE_FLAGS) then
                    row.unavailable = row.unavailable + stack
                    cat.unavailable = cat.unavailable + stack
                end
            end
        end
    end
    for _, cat in pairs(categories) do
        cat.index = nil
        table.sort(cat.rows, function(a, b)
            if a.quantity ~= b.quantity then return a.quantity > b.quantity end
            return (a.item or '') < (b.item or '')
        end)
    end
    return categories
end

local function cap_rows(cat, limit)
    cat.row_count = #cat.rows
    if #cat.rows > limit then
        local kept = {}
        for i = 1, limit do kept[i] = cat.rows[i] end
        cat.rows = kept
        cat.truncated = true
    else
        cat.truncated = false
    end
end

local function parse_limit(args)
    if args.limit == nil then return DEFAULT_LIMIT end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

-- Bookkeeper view of the stocks: the per-type counts the bookkeeper has recorded
-- (plotinfo.tasks.item_counts), rounded like the top bar, with no item rows.
local function recorded_categories(wanted)
    local info = bookkeeper_info()
    local counts = df.global.plotinfo.tasks.item_counts
    local out, total = {}, 0
    for type_id = 0, df.item_type._last_item do
        local recorded = safe(function() return counts[type_id] end) or 0
        if recorded > 0 then
            local token = (df.item_type[type_id] or tostring(type_id)):lower()
            local caption = safe(function() return df.item_type.attrs[type_id].caption end) or token
            if wanted == nil or wanted == token or wanted == caption:lower() then
                local shown = estimate(recorded, info.step)
                out[token] = {name = caption, total = shown.value, display = shown.display,
                              estimated = shown.estimated}
                total = total + 1
            end
        end
    end
    return out, total, info
end

local function list(args)
    local limit, err = parse_limit(args)
    if err then return err end
    local query = args.query
    if query ~= nil and type(query) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"query" must be a string')
    end
    local wanted = args.category and tostring(args.category):lower() or nil
    if not true_view() and bookkeeper_info().step ~= 0 then
        if query ~= nil then
            return rpc.error_result(rpc.ERR_NOT_ALLOWED,
                'bookkeeper view: item rows are unknown until the bookkeeper reaches full '
                .. 'accuracy, so "query" cannot be used')
        end
        local categories, total, info = recorded_categories(wanted)
        return {mode = 'bookkeeper', bookkeeper = info, categories = categories, count = total,
                truncated = {},
                note = total == 0 and 'the bookkeeper has recorded no stock yet' or nil}
    end
    local categories = collect(query)
    local out, truncated, total = {}, {}, 0
    for key, cat in pairs(categories) do
        if wanted == nil or wanted == key or wanted == cat.name:lower() then
            cap_rows(cat, limit)
            if cat.truncated then table.insert(truncated, key) end
            out[key] = cat
            total = total + 1
        end
    end
    if wanted and total == 0 then
        return {mode = 'true', categories = {}, count = 0, truncated = {},
                note = ('no items in category "%s"'):format(wanted)}
    end
    table.sort(truncated)
    return {mode = mode_name(), categories = out, count = total, truncated = truncated}
end

local function find(args)
    if type(args.query) ~= 'string' or args.query:match('^%s*$') then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"query" must be a non-empty string')
    end
    local limit, err = parse_limit(args)
    if err then return err end
    if not true_view() and bookkeeper_info().step ~= 0 then
        return rpc.error_result(rpc.ERR_NOT_ALLOWED,
            'bookkeeper view: item search needs a bookkeeper at full accuracy')
    end
    local rows = {}
    for key, cat in pairs(collect(args.query)) do
        for _, row in ipairs(cat.rows) do
            row.category = key
            row.category_name = cat.name
            table.insert(rows, row)
        end
    end
    table.sort(rows, function(a, b)
        if a.quantity ~= b.quantity then return a.quantity > b.quantity end
        return (a.item or '') < (b.item or '')
    end)
    local total = #rows
    if total > limit then
        local kept = {}
        for i = 1, limit do kept[i] = rows[i] end
        rows = kept
    end
    return {query = args.query, total = total, count = #rows, truncated = total > limit, rows = rows}
end

----------------------------------------------------------------------------------------------
-- artifacts

-- Only artifacts physically on this map: the world list also holds every artifact the fort
-- has never seen, and those stay hidden from Claude.
local function artifacts(args)
    local out = {}
    local elsewhere = 0
    for _, record in ipairs(df.global.world.artifacts.all) do
        local item = safe(function() return record.item end)
        local entry = nil
        if item then
            local pos = (function()
                local ok, x, y, z = pcall(dfhack.items.getPosition, item)
                if ok and x then return {x = x, y = y, z = z} end
                return nil
            end)()
            local holder = safe(dfhack.items.getHolderUnit, item)
            local building = safe(dfhack.items.getHolderBuilding, item)
            if pos or holder or building then
                entry = {
                    id = record.id,
                    name = translate(record.name, false),
                    name_english = translate(record.name, true),
                    item_id = item.id,
                    description = safe(dfhack.items.getReadableDescription, item),
                    material = material_of(item, safe(dfhack.matinfo.decode, item)),
                    pos = pos,
                }
                if holder then
                    entry.holder = {id = holder.id,
                                    name = safe(dfhack.units.getReadableName, holder)}
                end
                if building then
                    entry.building = {id = building.id,
                                      type = enum_name(df.building_type, building:getType())}
                end
            end
        end
        if entry then
            table.insert(out, entry)
        else
            elsewhere = elsewhere + 1
        end
    end
    return {count = #out, elsewhere = elsewhere, artifacts = out}
end

function ops()
    return {
        ['stocks.bar'] = {namespace = 'stocks', handler = bar, needs_map = true},
        ['stocks.list'] = {namespace = 'stocks', handler = list, needs_map = true},
        ['stocks.find'] = {namespace = 'stocks', handler = find, needs_map = true},
        ['stocks.artifacts'] = {namespace = 'stocks', handler = artifacts, needs_map = true},
    }
end
