-- Box popups (plan section 15.2, "Popups (P4.0)", "Menu clash", "Unpause"). The game keeps
-- open boxes in world.status.popups, a vector of popup_message (text CP437, color, bright,
-- portrait_hfid, -1 when none) and pauses while one is up; world.status.mega_text is the
-- rendered box and is left alone, as are the left-side alert buttons
-- (world.status.announcement_alert). popups.list reads the open boxes; popups.close removes
-- the front one the way the Close button does and unpauses only on request with pause_write.
-- The `popup` event kind is polled by events.lua on a frames timer so it fires while paused.
-- Sources: df-structures master df.announcement.xml (popup_message, world.status), checked
-- 2026-10-16; DFHack 53.16-r2 hack/lua/repeat-util.lua and Lua API (getCurFocus,
-- ReadPauseState), https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local screens = reqscript('internal/claude-bridge/screens')

DEFAULT_LIMIT = 25
TEXT_MAX = 4000
CLOSED_TEXT_MAX = 400
PAUSE_NOTE = 'the game stays paused while a popup is up; read it, act, then close it with close_popup'

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- The open popup_message vector, or nil when the struct cannot be read.
function popup_vector()
    return safe(function() return df.global.world.status.popups end)
end

function popup_count()
    local v = popup_vector()
    return v and (safe(function() return #v end) or 0) or 0
end

-- Text clipped to `max` characters (CP437 is one byte per character; the dispatcher
-- converts to UTF-8 on the way out). Returns text, truncated.
function clip(text, max)
    text = text or ''
    if #text > max then return text:sub(1, max), true end
    return text, false
end

-- {hist_figure_id, name} for a popup's portrait, nil when it has none.
function portrait_of(p)
    local hfid = safe(function() return p.portrait_hfid end)
    if type(hfid) ~= 'number' or hfid < 0 then return nil end
    local name = safe(function()
        local hf = df.historical_figure.find(hfid)
        return hf and dfhack.translation.translateName(hf.name, false) or nil
    end)
    if name == '' then name = nil end
    return {hist_figure_id = hfid, name = name}
end

local function parse_limit(args)
    if args.limit == nil then return DEFAULT_LIMIT end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

local function list(args)
    local limit, err = parse_limit(args)
    if err then return err end
    local rows, count = {}, 0
    local v = popup_vector()
    if v then
        count = safe(function() return #v end) or 0
        for i = 0, math.min(count, limit) - 1 do
            local p = safe(function() return v[i] end)
            if p then
                local text, cut = clip(safe(function() return p.text end), TEXT_MAX)
                table.insert(rows, {
                    index = i + 1,
                    text = text,
                    text_truncated = cut or nil,
                    color = safe(function() return p.color end),
                    bright = safe(function() return p.bright end) == true,
                    portrait = portrait_of(p),
                })
            end
        end
    end
    return {
        count = count,
        popups = rows,
        paused = safe(dfhack.world.ReadPauseState) == true,
        truncated = count > limit,
        note = count > 0 and PAUSE_NOTE or 'no popup is open',
    }
end

local function close(args)
    if args.unpause ~= nil and type(args.unpause) ~= 'boolean' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"unpause" must be true or false')
    end
    -- VERIFY LIVE: the focus string while a box is up. If it is not dwarfmode/Default (for
    -- example a dwarfmode/Announcement... string), add it to this list.
    local busy = screens.require_focus({screens.MAIN_FOCUS}, 'close_popup')
    if busy then return busy end
    local st = df.global.world.status
    if popup_count() == 0 then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            'no popup is open; nothing to close (list_popups shows open boxes)')
    end
    local front = st.popups[0]
    local text = clip(safe(function() return front.text end), CLOSED_TEXT_MAX)
    local closed = {
        text = text,
        color = safe(function() return front.color end),
        portrait = portrait_of(front),
    }
    -- The Close button's effect, as far as the structures show: the front entry leaves the
    -- vector and is freed. VERIFY LIVE: on the first live box record what the button changes
    -- besides this: whether mega_text is cleared or rebuilt for the next box, whether
    -- mega_portrait_hfid resets to -1, and whether the pause state changes (the design says
    -- the player or Claude unpauses, so this op does not).
    local ok, err = pcall(function()
        local p = st.popups[0]
        st.popups:erase(0)
        p:delete()
    end)
    if not ok then
        return rpc.error_result(rpc.ERR_INTERNAL, 'could not close the popup: ' .. tostring(err))
    end
    local result = {closed = closed, remaining = popup_count()}
    for k, v in pairs(screens.maybe_unpause(args)) do result[k] = v end
    local notes = {}
    if result.remaining > 0 then
        table.insert(notes, ('%d more popup(s) open; read them with list_popups and close each'):format(result.remaining))
    end
    if result.paused then
        table.insert(notes, 'the game is still paused; unpause with set_paused or close_popup(unpause=true) when pause_write is on, or tell the player')
    end
    if #notes > 0 then result.note = table.concat(notes, '; ') end
    return result
end

function ops()
    return {
        ['popups.list'] = {namespace = 'events', handler = list, needs_map = true},
        ['popups.close'] = {namespace = 'screens_write', handler = close, needs_map = true},
    }
end
