-- Stockpiles: list with a category filter, and inspect one (bounds, settings, links,
-- contents). Read-only. Plan section 10, item 4.4.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

local B = dfhack.buildings

DEFAULT_LIMIT = 25

-- Top-level categories: the flag names on stockpile_settings.flags (stockpile_group_set).
-- Used for the filter's error message; enabled_categories reads the live flags generically.
CATEGORIES = {
    'animals', 'food', 'furniture', 'corpses', 'refuse', 'stone', 'ore', 'ammo', 'coins',
    'bars_blocks', 'gems', 'finished_goods', 'leather', 'cloth', 'wood', 'weapons', 'armor',
    'sheet',
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
            if value == true and type(name) == 'string' then table.insert(out, name) end
        end
    end)
    table.sort(out)
    return out
end

function enabled_categories(sp)
    return true_flags(safe(function() return sp.settings.flags end))
end

-- DFHack hands vector<bool> back as booleans and vector<char> as numbers.
local function is_set(value)
    return value == true or (type(value) == 'number' and value ~= 0)
end

-- Generic summary of one category's settings struct: booleans as-is, bool vectors as
-- enabled/total counts, enums by name. Deep enough to tell "all food" from "seeds only".
local function summarize_category(struct)
    local out = {}
    pcall(function()
        for field, value in pairs(struct) do
            if type(field) == 'string' then
                local t = type(value)
                if t == 'boolean' or t == 'number' then
                    out[field] = value
                elseif t == 'userdata' then
                    local n, enabled = safe(function() return #value end), 0
                    if n then
                        for i = 0, n - 1 do
                            if is_set(safe(function() return value[i] end)) then enabled = enabled + 1 end
                        end
                        out[field] = {enabled = enabled, total = n}
                    else
                        local flags = true_flags(value)
                        if #flags > 0 then out[field] = flags end
                    end
                end
            end
        end
    end)
    return out
end

-- First non-nil of several field paths; struct layouts moved between versions.
local function first_of(...)
    for _, fn in ipairs({...}) do
        local value = safe(fn)
        if value ~= nil then return value end
    end
    return nil
end

local function settings_summary(sp, deep)
    local s = sp.settings
    local out = {
        categories = enabled_categories(sp),
        allow_organic = first_of(function() return s.allow_organic end,
                                 function() return s.misc.allow_organic end),
        allow_inorganic = first_of(function() return s.allow_inorganic end,
                                   function() return s.misc.allow_inorganic end),
        max_barrels = first_of(function() return sp.storage.max_barrels end,
                               function() return sp.max_barrels end),
        max_bins = first_of(function() return sp.storage.max_bins end,
                            function() return sp.max_bins end),
        max_wheelbarrows = first_of(function() return sp.storage.max_wheelbarrows end,
                                    function() return sp.max_wheelbarrows end),
        use_links_only = first_of(function() return sp.use_links_only end,
                                  function() return sp.stockpile_flag.use_links_only end) == true,
        flags = true_flags(safe(function() return sp.stockpile_flag end)),
    }
    if deep then
        out.details = {}
        for _, cat in ipairs(out.categories) do
            local struct = safe(function() return s[cat] end)
            if struct then out.details[cat] = summarize_category(struct) end
        end
    end
    return out
end

local function building_ref(b)
    return {
        id = b.id,
        kind = enum_name(df.building_type, b:getType()),
        name = safe(function() return b.name ~= '' and b.name or nil end),
        pos = {x = b.centerx, y = b.centery, z = b.z},
    }
end

local function links(sp)
    local out = {}
    for _, field in ipairs({'give_to_pile', 'take_from_pile', 'give_to_workshop', 'take_from_workshop'}) do
        local refs = {}
        pcall(function()
            for _, b in ipairs(sp.links[field]) do table.insert(refs, building_ref(b)) end
        end)
        out[field] = refs
    end
    return out
end

local function tile_count(sp)
    local from_extents = safe(function()
        if sp.room.extents then return B.countExtentTiles(sp.room, 0) end
        return nil
    end)
    if from_extents then return from_extents end
    return (sp.x2 - sp.x1 + 1) * (sp.y2 - sp.y1 + 1)
end

function summary(sp)
    return {
        id = sp.id,
        number = safe(function() return sp.stockpile_number end),
        name = safe(function() return sp.name ~= '' and sp.name or nil end),
        label = (function()
            local n = safe(function() return sp.stockpile_number end)
            local name = safe(function() return sp.name ~= '' and sp.name or nil end)
            return name or (n and ('Stockpile #' .. n)) or ('stockpile ' .. sp.id)
        end)(),
        bounds = {x1 = sp.x1, y1 = sp.y1, x2 = sp.x2, y2 = sp.y2, z = sp.z},
        pos = {x = sp.centerx, y = sp.centery, z = sp.z},
        tiles = tile_count(sp),
        categories = enabled_categories(sp),
        items = safe(function() return #B.getStockpileContents(sp) end),
    }
end

local function parse_limit(args)
    if args.limit == nil then return DEFAULT_LIMIT end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

local function each_stockpile(fn)
    local vec = safe(function() return df.global.world.buildings.other.STOCKPILE end)
    if not vec then return end
    for _, sp in ipairs(vec) do fn(sp) end
end

local function list(args)
    local limit, err = parse_limit(args)
    if err then return err end
    local offset = tonumber(args.offset) or 0
    local wanted = args.category ~= nil and tostring(args.category):lower() or nil
    if wanted ~= nil then
        local known = false
        for _, c in ipairs(CATEGORIES) do if c == wanted then known = true end end
        if not known then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"category" must be one of ' .. table.concat(CATEGORIES, ', '))
        end
    end
    local rows, total, counts = {}, 0, {}
    each_stockpile(function(sp)
        local row = summary(sp)
        for _, c in ipairs(row.categories) do counts[c] = (counts[c] or 0) + 1 end
        local keep = wanted == nil
        if not keep then
            for _, c in ipairs(row.categories) do if c == wanted then keep = true end end
        end
        if keep then
            total = total + 1
            if total > offset and #rows < limit then table.insert(rows, row) end
        end
    end)
    table.sort(rows, function(a, b) return a.id < b.id end)
    return {total = total, count = #rows, offset = offset, limit = limit,
            truncated = total > offset + #rows, stockpiles = rows, counts_by_category = counts}
end

local function contents(sp, limit)
    local items = safe(B.getStockpileContents, sp) or {}
    local rows, by_type = {}, {}
    for _, item in ipairs(items) do
        local token = (df.item_type[item:getType()] or '?'):lower()
        local qty = safe(function() return item:getStackSize() end) or 1
        by_type[token] = (by_type[token] or 0) + qty
        if #rows < limit then
            table.insert(rows, {
                id = item.id,
                type = token,
                description = safe(dfhack.items.getReadableDescription, item),
                quantity = qty,
            })
        end
    end
    return {entries = rows, total = #items, truncated = #items > #rows, by_type = by_type}
end

local function get(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a building id') end
    local limit, err = parse_limit(args)
    if err then return err end
    local b = df.building.find(id)
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    if not df.building_stockpilest:is_instance(b) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a %s, not a stockpile'):format(id,
                enum_name(df.building_type, b:getType()) or '?'))
    end
    local row = summary(b)
    row.settings = settings_summary(b, true)
    row.links = links(b)
    row.contents = contents(b, limit)
    row.limit = limit
    return row
end

function ops()
    return {
        ['stockpiles.list'] = {namespace = 'stockpiles', handler = list, needs_map = true},
        ['stockpiles.get'] = {namespace = 'stockpiles', handler = get, needs_map = true},
    }
end
