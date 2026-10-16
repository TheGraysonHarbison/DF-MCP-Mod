-- Helpers for ops that drive the game's own screens (plan section 15: P2.0 trade screen,
-- P3.0 diplomacy dialog, P4.0 popups). The focus check behind the SCREEN_BUSY refusal, a
-- synthesized click through DFHack's input path (gui.simulateInput with the mouse position
-- set; the player's cursor never moves), the answer to a DFHack confirm dialog that catches
-- such a click, and the optional unpause every screen op offers. Identical copies ship on
-- the three branches; change it only through the owner.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local state = reqscript('internal/claude-bridge/state')
local gui = require('gui')

MAIN_FOCUS = 'dwarfmode/Default'
-- DFHack's confirm plugin answers a caught click with a showYesNoPrompt MessageBox (focus
-- dfhack/lua/MessageBox, verified live 2026-10-16 on the Trade button); SELECT accepts it.
CONFIRM_FOCUS = 'dfhack/lua/MessageBox'
-- _MOUSE_L is the click DF's buttons and DFHack's confirm plugin react to. If the first
-- live click does nothing, add _MOUSE_L_DOWN = true here (the owner decides).
CLICK_KEYS = {_MOUSE_L = true}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- Focus strings of the topmost game screen (DFHack's own screens skipped).
function focus()
    return safe(function() return dfhack.gui.getCurFocus(true) end) or {}
end

function focus_string()
    local f = focus()
    if #f == 0 then return 'unknown' end
    return table.concat(f, ', ')
end

-- True when a current focus string starts with `prefix` (case-insensitive).
function has_focus(prefix)
    return safe(function() return dfhack.gui.matchFocusString(prefix) end) == true
end

-- nil when the current focus matches one of `expected` (prefixes), else the SCREEN_BUSY
-- error result. The player's screen is never closed (decision 15.2).
function require_focus(expected, what)
    for _, prefix in ipairs(expected) do
        if has_focus(prefix) then return nil end
    end
    return rpc.error_result(rpc.ERR_SCREEN_BUSY,
        ('%s needs %s on screen but the game shows %s; the player\'s menu is left alone, try again later')
            :format(what or 'this op', table.concat(expected, ' or '), focus_string()))
end

-- The interface tile at the centre of a confirm-plugin style frame ({l, r, t, b, w, h}),
-- resolved the way DFHack's confirm overlay resolves intercept_frame: compute_frame_rect
-- over the interface rect, offset by that rect's top-left corner.
function frame_center(frame)
    local ir = gui.get_interface_rect()
    local rect = gui.compute_frame_rect(ir.width, ir.height, frame, 0, 0)
    return ir.x1 + rect.x1 + math.floor(rect.width / 2), ir.y1 + rect.y1 + math.floor(rect.height / 2)
end

-- Feed one left click at interface tile (x, y) to the topmost game screen and restore the
-- mouse position. Raises on failure.
function click_at(x, y)
    local gps = df.global.gps
    local old_x, old_y = gps.mouse_x, gps.mouse_y
    gps.mouse_x, gps.mouse_y = x, y
    local ok, err = pcall(gui.simulateInput, dfhack.gui.getDFViewscreen(true), CLICK_KEYS)
    gps.mouse_x, gps.mouse_y = old_x, old_y
    if not ok then error(err, 0) end
end

-- Click the centre of a frame; returns the tile clicked.
function click_frame(frame)
    local x, y = frame_center(frame)
    click_at(x, y)
    return {x = x, y = y}
end

-- If DFHack's confirm plugin put its dialog on top of the game screen after a click, answer
-- it with SELECT (gui/dialogs MessageBox: SELECT runs on_accept). Returns true when a
-- dialog was answered. confirm.json is never edited (rule 8).
function answer_confirm()
    if not safe(function() return dfhack.gui.matchFocusString(CONFIRM_FOCUS, dfhack.gui.getCurViewscreen(true)) end) then
        return false
    end
    pcall(gui.simulateInput, dfhack.gui.getCurViewscreen(true), 'SELECT')
    return true
end

-- Honour an `unpause` argument the way decision 15.2 says: only with pause_write. Returns
-- fields to merge into the op's result.
function maybe_unpause(args)
    local out = {unpaused = false, paused = safe(dfhack.world.ReadPauseState) == true}
    if args.unpause ~= true then return out end
    if not state.is_allowed('pause_write') then
        out.pause_note = 'unpause asked but pause_write is off; the game stays paused until the player unpauses'
        return out
    end
    pcall(dfhack.world.SetPauseState, false)
    out.unpaused = true
    out.paused = safe(dfhack.world.ReadPauseState) == true
    return out
end

-- The interface text grid as rows of plain characters (dfhack.screen.readTile over the
-- interface rect; the UI layer keeps its text as characters on this build, verified live
-- 2026-10-16). Returns {rows = {[y] = string}, rect}.
function screen_rows()
    local ir = gui.get_interface_rect()
    local rows = {}
    for y = ir.y1, ir.y2 do
        local chars = {}
        for x = ir.x1, ir.x2 do
            local pen = dfhack.screen.readTile(x, y)
            local ch = pen and pen.ch or 32
            if type(ch) ~= 'number' or ch < 32 or ch > 126 then ch = 32 end
            chars[#chars + 1] = string.char(ch)
        end
        rows[y] = table.concat(chars)
    end
    return rows, ir
end

-- Rows that carry words, trimmed, as {{y, text}} capped at `limit` (for reading a dialog).
function text_rows(limit)
    local rows, ir = screen_rows()
    local out = {}
    for y = ir.y1, ir.y2 do
        local text = rows[y]:gsub('%s+', ' '):match('^%s*(.-)%s*$')
        if text:find('%a%a') then
            if #out >= (limit or 40) then return out, true end
            table.insert(out, {y = y, text = text})
        end
    end
    return out, false
end

-- Interface tile at the centre of the first on-screen occurrence of `label` (plain text,
-- case-sensitive, whole word), or nil. Buttons on the game's dialogs move with the text
-- above them, so they are found by their label rather than by a fixed frame.
function find_label(label)
    local rows, ir = screen_rows()
    local pattern = '%f[%w]' .. label:gsub('%W', '%%%0') .. '%f[%W]'
    for y = ir.y1, ir.y2 do
        local i, j = rows[y]:find(pattern)
        if i then return ir.x1 + i - 1 + math.floor((j - i) / 2), y end
    end
    return nil
end

-- Click the button carrying `label`; returns the tile or nil, reason.
function click_label(label)
    local x, y = find_label(label)
    if not x then return nil, ('no "%s" button is on screen'):format(label) end
    click_at(x, y)
    return {x = x, y = y, label = label}
end

-- Feed one key (for example LEAVESCREEN) to the topmost game screen.
function press_key(key)
    local ok, err = pcall(gui.simulateInput, dfhack.gui.getDFViewscreen(true), key)
    if not ok then error(err, 0) end
end
