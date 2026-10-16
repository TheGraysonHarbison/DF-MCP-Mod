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
CONFIRM_FOCUS = 'dfhack/lua/confirm'
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
-- it with SELECT (its confirm key; the first live test verifies). Returns true when a
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
