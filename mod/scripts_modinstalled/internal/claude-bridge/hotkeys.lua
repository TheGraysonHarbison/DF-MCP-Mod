-- Zoom hotkeys as named points of interest: the 16 slots of the game's Hotkeys window (the
-- player's F-keys), read in full and written as Zoom hotkeys. Plan section 15.2 "Hotkeys
-- (P5.0)". Sources: df-structures `df.plotinfo.xml` (`ui_hotkey`, `hotkey_type`,
-- `plotinfo.main.hotkeys`), `df.d_interface.xml` (`hotkeys_interfacest`, the window state at
-- `game.main_interface.hotkey`), DFHack 53.16-r2 `hack/scripts/hotkey-notes.lua` (key labels),
-- Lua API `dfhack.maps.isValidTilePos`
-- (https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html, checked against 53.16-r2).
-- Only the name, cmd, x, y, z, and unit/item union of a slot are written; nothing else in
-- `plotinfo.main`, and no texture or render field anywhere (CLAUDE.md rule 13).
-- VERIFY LIVE: the game's Hotkeys window shows a slot written here (name and zoom target)
-- without any redraw help.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

SLOT_COUNT = 16
-- VERIFY LIVE: the longest name the game's hotkey rename field accepts; adjust to match.
NAME_MAX = 40

KIND_NAMES = {[-1] = 'none', [0] = 'zoom', [1] = 'follow_unit', [2] = 'follow_item'}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- Slot n (1-based) to the struct at index n - 1.
local function slot_struct(n)
    return df.global.plotinfo.main.hotkeys[n - 1]
end

-- Same label DFHack's hotkey-notes prints.
-- VERIFY LIVE: the 16 labels match the keys the game's Hotkeys window shows.
local function key_label(n)
    local label = safe(function()
        return dfhack.screen.getKeyDisplay(df.interface_key.D_HOTKEY1 + n - 1)
    end)
    if type(label) ~= 'string' or label == '' then return 'slot ' .. n end
    return label
end

local function cmd_of(hk)
    local cmd = safe(function() return hk.cmd end)
    if type(cmd) == 'string' then cmd = df.hotkey_type[cmd] end
    return tonumber(cmd) or -1
end

local function kind_of(cmd)
    return KIND_NAMES[cmd] or tostring(cmd)
end

local function name_of(hk)
    return safe(function() return hk.name end) or ''
end

local function is_empty(hk)
    return cmd_of(hk) == df.hotkey_type.None and name_of(hk) == ''
end

local function zoom_pos(hk)
    return safe(function() return {x = hk.x, y = hk.y, z = hk.z} end)
end

-- Names stay CP437 here: rpc.dispatch converts every outgoing string to UTF-8 (df2utf), so
-- converting again would double-encode.
local function describe(hk, n)
    local cmd = cmd_of(hk)
    local row = {
        slot = n,
        key = key_label(n),
        kind = kind_of(cmd),
        name = name_of(hk),
        empty = is_empty(hk),
    }
    if cmd == df.hotkey_type.Zoom then
        row.pos = zoom_pos(hk)
    elseif cmd == df.hotkey_type.FollowUnit then
        row.unit_id = safe(function() return hk.unit_id end)
    elseif cmd == df.hotkey_type.FollowItem then
        row.item_id = safe(function() return hk.item_id end)
    end
    return row
end

-- The short form used for `overwrote` and `previous`.
local function summary(hk)
    local cmd = cmd_of(hk)
    local out = {name = name_of(hk), kind = kind_of(cmd)}
    if cmd == df.hotkey_type.Zoom then out.pos = zoom_pos(hk) end
    return out
end

local function refuse_if_window_open()
    if safe(function() return df.global.game.main_interface.hotkey.open end) == true then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'the player has the hotkeys window open; try again after they close it')
    end
    return nil
end

local function as_integer(value)
    local n = tonumber(value)
    if n == nil or n ~= math.floor(n) then return nil end
    return math.floor(n)
end

local function parse_slot(value, required)
    if value == nil then
        if required then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('"slot" is required (1 to %d; see list_hotkeys)'):format(SLOT_COUNT))
        end
        return nil, nil
    end
    local n = as_integer(value)
    if not n or n < 1 or n > SLOT_COUNT then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('"slot" must be an integer from 1 to %d'):format(SLOT_COUNT))
    end
    return n, nil
end

-- UTF-8 in, CP437 out, control characters removed, trimmed, clipped to NAME_MAX bytes
-- (CP437 is one byte per character).
local function clean_name(text)
    local encoded = dfhack.utf2df(text):gsub('%c', '')
    encoded = encoded:match('^%s*(.-)%s*$')
    local clipped = false
    if #encoded > NAME_MAX then
        encoded = encoded:sub(1, NAME_MAX):match('^(.-)%s*$')
        clipped = true
    end
    return encoded, clipped
end

local function list(args)
    local rows, free = {}, {}
    for n = 1, SLOT_COUNT do
        local hk = slot_struct(n)
        table.insert(rows, describe(hk, n))
        if cmd_of(hk) == df.hotkey_type.None then table.insert(free, n) end
    end
    return {
        count = SLOT_COUNT,
        hotkeys = rows,
        free_slots = free,
        note = 'Hotkeys are the player\'s F-key zoom slots in the game\'s Hotkeys window. Slot 1 '
            .. 'is the game\'s default "Wagon arrival location"; ask before replacing it or any '
            .. 'slot the player named.',
    }
end

local function set(args)
    local refused = refuse_if_window_open()
    if refused then return refused end

    if type(args.name) ~= 'string' or args.name:match('^%s*$') then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a non-empty string')
    end
    local x, y, z = as_integer(args.x), as_integer(args.y), as_integer(args.z)
    if not x or not y or not z then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"x", "y", and "z" must be integers')
    end
    if not dfhack.maps.isValidTilePos(x, y, z) then
        local w, h, d = dfhack.maps.getTileSize()
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('(%d, %d, %d) is outside the map; x 0-%d, y 0-%d, z 0-%d (see get_map_bounds)')
                :format(x, y, z, w - 1, h - 1, d - 1))
    end
    local slot, err = parse_slot(args.slot, false)
    if err then return err end
    local overwrite = args.overwrite == true

    if slot == nil then
        for n = 1, SLOT_COUNT do
            if cmd_of(slot_struct(n)) == df.hotkey_type.None then
                slot = n
                break
            end
        end
        if slot == nil then
            return rpc.error_result(rpc.ERR_NOT_FOUND,
                'all 16 hotkey slots are in use; clear one with clear_hotkey, or pass "slot" '
                .. 'with "overwrite" true (and tell the player which slot you replaced)')
        end
    end

    local hk = slot_struct(slot)
    local overwrote = nil
    if not is_empty(hk) then
        local current = summary(hk)
        if not overwrite then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('slot %d already holds "%s" (%s); pass "overwrite" true to replace it, or pick '
                    .. 'a free slot from list_hotkeys'):format(slot, current.name, current.kind))
        end
        overwrote = current
    end

    local name, clipped = clean_name(args.name)
    if name == '' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"name" has no characters the game can show; use plain letters')
    end

    hk.name = name
    hk.cmd = df.hotkey_type.Zoom
    hk.x = x
    hk.y = y
    hk.z = z
    -- VERIFY LIVE: the union member is named unit_id on this build (item_id shares it).
    pcall(function() hk.unit_id = -1 end)

    local note = 'The player can jump there with ' .. key_label(slot) .. ' or from the Hotkeys window.'
    if clipped then
        note = note .. (' The name was clipped to %d characters.'):format(NAME_MAX)
    end
    if overwrote then
        note = note .. ' This replaced an existing slot; tell the player with send_message.'
    end
    return {
        slot = slot,
        key = key_label(slot),
        name = name,
        pos = {x = x, y = y, z = z},
        overwrote = overwrote,
        note = note,
    }
end

local function clear(args)
    local refused = refuse_if_window_open()
    if refused then return refused end

    local slot, err = parse_slot(args.slot, true)
    if err then return err end
    local hk = slot_struct(slot)
    if is_empty(hk) then
        return {slot = slot, cleared = false}
    end
    local previous = summary(hk)
    hk.cmd = df.hotkey_type.None
    hk.name = ''
    hk.x = 0
    hk.y = 0
    hk.z = 0
    pcall(function() hk.unit_id = -1 end)
    return {slot = slot, cleared = true, previous = previous}
end

function ops()
    return {
        ['hotkeys.list'] = {namespace = 'map', handler = list, needs_map = true},
        ['hotkeys.set'] = {namespace = 'hotkeys_write', handler = set, needs_map = true},
        ['hotkeys.clear'] = {namespace = 'hotkeys_write', handler = clear, needs_map = true},
    }
end
