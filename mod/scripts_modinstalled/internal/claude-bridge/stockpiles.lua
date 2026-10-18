-- Stockpiles: list with a category filter, inspect one (bounds, settings, links, contents),
-- and under stockpiles_write: paint a rectangle, configure, rename, delete.
-- Plan section 10, items 4.4 and 4.5.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')
local dig = reqscript('internal/claude-bridge/dig')

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

-- Tiles the pile covers: the non-zero bytes of its room extents when it has them (a circle),
-- else the rectangle.
local function tile_count(sp)
    local from_extents = safe(function()
        local room = sp.room
        if not room.extents then return nil end
        local n = 0
        for i = 0, room.width * room.height - 1 do
            if room.extents[i] ~= 0 then n = n + 1 end
        end
        return n
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

----------------------------------------------------------------------------------------------
-- presets (DFHack stockpiles plugin library)

-- The plugin's library lives in hack/data/stockpiles; getHackPath may or may not end in '/'.
local function presets_dir()
    local candidates = {
        safe(function() return (dfhack.getHackPath():gsub('/?$', '/')) .. 'data/stockpiles' end),
        'hack/data/stockpiles',
    }
    for _, dir in ipairs(candidates) do
        if dir and safe(dfhack.filesystem.isdir, dir) then return dir end
    end
    return nil
end

local function list_presets(query)
    local dir = presets_dir()
    local out = {}
    if not dir then return out end
    local entries = safe(dfhack.filesystem.listdir_recursive, dir, 10, false) or {}
    local needle = query and query:lower() or nil
    for _, entry in ipairs(entries) do
        local path = type(entry) == 'table' and entry.path or entry
        if type(path) == 'string' and not (type(entry) == 'table' and entry.isdir) then
            local name = path:gsub('^' .. dir:gsub('%p', '%%%0') .. '/?', ''):gsub('^/', '')
                :gsub('%.dfstock$', '')
            if name ~= '' and (not needle or name:lower():find(needle, 1, true)) then
                table.insert(out, 'library/' .. name)
            end
        end
    end
    table.sort(out)
    return out
end

local function presets(args)
    local limit, err = parse_limit(args)
    if err then return err end
    local all = list_presets(type(args.query) == 'string' and args.query or nil)
    local rows = {}
    for i = 1, math.min(limit, #all) do rows[i] = all[i] end
    return {total = #all, count = #rows, truncated = #all > #rows, presets = rows,
            note = 'apply with stockpiles.create or stockpiles.configure "preset"; '
                .. 'mode set replaces, enable adds, disable removes'}
end

local function apply_preset(sp, name, mode)
    local ok, plugin = pcall(require, 'plugins.stockpiles')
    if not ok or not plugin or not plugin.import_settings then
        return false, 'the DFHack stockpiles plugin is not available'
    end
    local ok2, err = pcall(plugin.import_settings, name, {id = sp.id, mode = mode or 'set'})
    if not ok2 then return false, tostring(err) end
    return true
end

----------------------------------------------------------------------------------------------
-- category toggles

-- Fill every option under one category by hand. Only a fallback: on a freshly painted pile
-- the per-material vectors are empty, so this cannot enable materials the game has not
-- sized yet; the plugin presets below can.
local function set_category_manually(settings, cat, on)
    local okflag = pcall(function() settings.flags[cat] = on end)
    if not okflag then return false end
    local struct = safe(function() return settings[cat] end)
    if not struct then return true end
    pcall(function()
        for field, value in pairs(struct) do
            if type(field) == 'string' then
                if type(value) == 'boolean' then
                    pcall(function() struct[field] = on end)
                elseif type(value) == 'userdata' then
                    local n = safe(function() return #value end)
                    if n then
                        for i = 0, n - 1 do
                            local set = pcall(function() value[i] = on end)
                            if not set then pcall(function() value[i] = on and 1 or 0 end) end
                        end
                    end
                end
            end
        end
    end)
    return true
end

-- DFHack's library has one preset per category (sheet is "cat_sheets"; ore has none).
local CATEGORY_PRESET = {sheet = 'library/cat_sheets', ore = nil}

local function category_preset(cat)
    if cat == 'ore' then return nil end
    return CATEGORY_PRESET[cat] or ('library/cat_' .. cat)
end

-- Enable or disable a whole category: the plugin preset sizes and fills the material lists
-- the way the game's own toggle does; fall back to the manual pass when it is unavailable.
local function set_category(sp, cat, on)
    local preset = category_preset(cat)
    if preset then
        local ok = apply_preset(sp, preset, on and 'enable' or 'disable')
        if ok then
            pcall(function() sp.settings.flags[cat] = on end)
            return true, 'preset'
        end
    end
    return set_category_manually(sp.settings, cat, on), 'manual'
end

local function check_categories(list)
    if list == nil then return {} end
    if type(list) ~= 'table' then list = {list} end
    local out = {}
    for _, c in ipairs(list) do
        local name = tostring(c):lower()
        local known = false
        for _, k in ipairs(CATEGORIES) do if k == name then known = true end end
        if not known then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('unknown category "%s"; valid: %s'):format(name, table.concat(CATEGORIES, ', ')))
        end
        table.insert(out, name)
    end
    return out
end

local function find_stockpile(args)
    local id = tonumber(args.id)
    if not id then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a stockpile building id')
    end
    local b = df.building.find(id)
    if not b then return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    if not df.building_stockpilest:is_instance(b) then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a %s, not a stockpile'):format(id,
                enum_name(df.building_type, b:getType()) or '?'))
    end
    return b
end

-- Shared by create and configure: categories, preset, name, container limits.
local function apply_config(sp, args)
    local changed = {}
    local enable, err = check_categories(args.categories or args.enable)
    if err then return nil, err end
    local disable, err2 = check_categories(args.disable)
    if err2 then return nil, err2 end
    for _, c in ipairs(enable) do
        local ok, how = set_category(sp, c, true)
        if ok then table.insert(changed, ('enable:%s (%s)'):format(c, how)) end
    end
    for _, c in ipairs(disable) do
        local ok, how = set_category(sp, c, false)
        if ok then table.insert(changed, ('disable:%s (%s)'):format(c, how)) end
    end
    if args.preset ~= nil then
        local mode = args.preset_mode or 'set'
        if mode ~= 'set' and mode ~= 'enable' and mode ~= 'disable' then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"preset_mode" must be set, enable, or disable')
        end
        local ok, why = apply_preset(sp, tostring(args.preset), mode)
        if not ok then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('preset "%s" failed: %s'):format(tostring(args.preset), why))
        end
        table.insert(changed, 'preset:' .. tostring(args.preset))
    end
    if args.name ~= nil then
        if type(args.name) ~= 'string' or #args.name > 64 then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a string of up to 64 characters')
        end
        sp.name = dfhack.utf2df(args.name)
        table.insert(changed, 'name')
    end
    for _, field in ipairs({'max_barrels', 'max_bins', 'max_wheelbarrows'}) do
        if args[field] ~= nil then
            local n = tonumber(args[field])
            if not n or n < 0 then
                return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"' .. field .. '" must be 0 or more')
            end
            local set = pcall(function() sp.storage[field] = math.floor(n) end)
            if not set then set = pcall(function() sp[field] = math.floor(n) end) end
            if set then table.insert(changed, field) end
        end
    end
    return changed
end

----------------------------------------------------------------------------------------------
-- writes

local function create(args)
    local x1, y1, x2, y2, z
    local inside = nil  -- membership test for a circle (plan 11.3, item 6.4)
    local clipped = false
    if args.circle ~= nil then
        local box, cerr, test = dig.parse_circle(args)
        if cerr then return cerr end
        x1, y1, x2, y2, z = box.x1, box.y1, box.x2, box.y2, box.z1
        inside = test
        clipped = box.clipped == true
    else
        x1, y1, x2, y2, z = tonumber(args.x1), tonumber(args.y1), tonumber(args.x2),
                            tonumber(args.y2), tonumber(args.z)
        if not (x1 and y1 and x2 and y2 and z) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"x1", "y1", "x2", "y2", "z" are required (or a "circle")')
        end
        -- No size cap of ours (P2-4.0; quickfort's place module allows any size): the box is
        -- clipped to the map like every other box.
        local box, berr = map.parse_box({x1 = x1, y1 = y1, z1 = z, x2 = x2, y2 = y2, z2 = z})
        if berr then return berr end
        x1, y1, x2, y2, z = box.x1, box.y1, box.x2, box.y2, box.z1
        clipped = box.clipped == true
    end
    local w, h = x2 - x1 + 1, y2 - y1 + 1
    -- Validate the configuration before anything is painted.
    local _, cat_err = check_categories(args.categories or args.enable)
    if cat_err then return cat_err end
    local _, cat_err2 = check_categories(args.disable)
    if cat_err2 then return cat_err2 end
    if args.preset_mode ~= nil and args.preset_mode ~= 'set' and args.preset_mode ~= 'enable'
        and args.preset_mode ~= 'disable' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"preset_mode" must be set, enable, or disable')
    end
    if args.name ~= nil and (type(args.name) ~= 'string' or #args.name > 64) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a string of up to 64 characters')
    end
    local footprint = {x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z, width = w, height = h,
                       shape = inside and 'circle' or 'rectangle', clipped = clipped}
    local tiles = 0
    for y = y1, y2 do
        for x = x1, x2 do
            local pos = {x = x, y = y, z = z}
            if inside and not inside(x, y) then
                goto continue
            end
            tiles = tiles + 1
            if not dfhack.maps.isValidTilePos(pos) then
                return {status = 'invalid_space', footprint = footprint, blocked_at = pos,
                        reason = 'outside the map'}
            end
            local t = map.describe_tile(pos, 1)
            local why = nil
            if t.unknown then why = 'no map block'
            elseif t.hidden then why = 'hidden (not yet revealed)'
            elseif t.building then why = ('occupied by %s %d'):format(t.building.type or 'building', t.building.id)
            elseif t.liquid then why = ('%s depth %d'):format(t.liquid.type, t.liquid.depth)
            elseif t.plant then why = 'tree or plant'
            elseif t.basic_shape ~= 'Floor' then why = ('%s, not floor'):format(t.basic_shape or '?')
            end
            if why then
                return {status = 'invalid_space', footprint = footprint, blocked_at = pos, reason = why}
            end
            ::continue::
        end
    end
    footprint.tiles = tiles
    -- A circle is a stockpile with room extents, built the way quickfort's place module
    -- does it: one byte per tile of the bounding box, 1 inside the shape.
    local fields = nil
    if inside then
        local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', w * h))
        for i = 0, w * h - 1 do
            local ex, ey = x1 + i % w, y1 + math.floor(i / w)
            extents[i] = inside(ex, ey) and 1 or 0
        end
        fields = {room = {x = x1, y = y1, width = w, height = h, extents = extents}}
    end
    local sp, err = B.constructBuilding{
        type = df.building_type.Stockpile, abstract = true,
        pos = {x = x1, y = y1, z = z}, width = w, height = h, fields = fields,
    }
    if not sp then
        return {status = 'invalid_space', footprint = footprint, reason = tostring(err)}
    end
    local changed, cfg_err = apply_config(sp, args)
    if cfg_err then
        -- keep the pile but report the configuration problem
        local row = summary(sp)
        row.settings = settings_summary(sp, false)
        return {status = 'placed_unconfigured', stockpile = row, footprint = footprint,
                error = cfg_err.message}
    end
    local row = summary(sp)
    row.settings = settings_summary(sp, false)
    return {status = 'placed', stockpile = row, changed = changed, footprint = footprint}
end

local function configure(args)
    local sp, err = find_stockpile(args)
    if err then return err end
    local changed, cfg_err = apply_config(sp, args)
    if cfg_err then return cfg_err end
    if #changed == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'nothing to change; pass enable, disable, preset, name, max_barrels, max_bins, or max_wheelbarrows')
    end
    local row = summary(sp)
    row.settings = settings_summary(sp, true)
    return {changed = changed, stockpile = row}
end

local function rename(args)
    local sp, err = find_stockpile(args)
    if err then return err end
    if type(args.name) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a string (empty clears)')
    end
    local changed, cfg_err = apply_config(sp, {name = args.name})
    if cfg_err then return cfg_err end
    return {changed = changed, stockpile = summary(sp)}
end

local function delete(args)
    local sp, err = find_stockpile(args)
    if err then return err end
    local row = summary(sp)
    local ok, why = pcall(B.deconstruct, sp)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'deconstruct failed: ' .. tostring(why)) end
    local gone = df.building.find(row.id) == nil
    return {status = gone and 'deleted' or 'removal_queued', stockpile = row,
            note = 'items stay where they lie'}
end

function ops()
    return {
        ['stockpiles.list'] = {namespace = 'stockpiles', handler = list, needs_map = true},
        ['stockpiles.get'] = {namespace = 'stockpiles', handler = get, needs_map = true},
        ['stockpiles.presets'] = {namespace = 'stockpiles', handler = presets},
        ['stockpiles.create'] = {namespace = 'stockpiles_write', handler = create, needs_map = true},
        ['stockpiles.configure'] = {namespace = 'stockpiles_write', handler = configure, needs_map = true},
        ['stockpiles.rename'] = {namespace = 'stockpiles_write', handler = rename, needs_map = true},
        ['stockpiles.delete'] = {namespace = 'stockpiles_write', handler = delete, needs_map = true},
    }
end
