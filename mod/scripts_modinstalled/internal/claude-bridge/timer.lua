-- Prompt timer (plan section 13, Phase 15): after a set span, a player-written prompt is
-- queued as a `timer` event and reaches Claude through the channel like everything else.
-- Modes: every N in-game days, every change of the in-game month, or every N real minutes
-- (counted only while the game runs). Any event batch the mod hands out re-arms the timer,
-- the game being paused freezes it, and a pending timer prompt is never doubled.
--@ module = true

local state = reqscript('internal/claude-bridge/state')
local repeatutil = require('repeat-util')

local JOB = 'claude-bridge-timer'
CHECK_FRAMES = 30
TICKS_PER_DAY = 1200
TICKS_PER_MONTH = 33600
MODES = {'days', 'month', 'minutes'}
DEFAULT_PROMPT = '# Update\nTime has passed so please check the status of your fortress. '
    .. 'Check your plans and update accordingly to further your goals.\n'
DEFAULT_SETTINGS = {enabled = false, mode = 'days', interval = 7, prompt = DEFAULT_PROMPT}

-- Module state survives a reload only until the file is re-read; the control script
-- restarts the timer then, which re-arms it.
running = running or false
armed = armed or nil
fired = fired or 0
last_fired_tick = last_fired_tick or nil

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

function settings()
    return state.get_timer()
end

local function frame_counter()
    return safe(function() return df.global.world.frame_counter end) or 0
end

local function month_index()
    local tick = safe(function() return df.global.cur_year_tick end) or 0
    local year = safe(function() return df.global.cur_year end) or 0
    return year * 12 + math.floor(tick / TICKS_PER_MONTH)
end

-- Re-arm from now. Called at start, after every fire, and whenever events go out.
function reset(reason)
    armed = {
        tick = frame_counter(),
        month = month_index(),
        real_ms = 0,
        last_ms = dfhack.getTickCount(),
        reason = reason or 'armed',
    }
end

-- How far along the timer is, for timer.status and the settings window.
function progress()
    local s = settings()
    if not armed then return {armed = false} end
    local out = {armed = true, mode = s.mode, interval = s.interval, since = armed.reason}
    if s.mode == 'days' then
        local elapsed = frame_counter() - armed.tick
        out.elapsed_days = elapsed / TICKS_PER_DAY
        out.remaining_days = math.max(0, s.interval - out.elapsed_days)
    elseif s.mode == 'month' then
        out.months_passed = month_index() - armed.month
    else
        out.elapsed_minutes = armed.real_ms / 60000
        out.remaining_minutes = math.max(0, s.interval - out.elapsed_minutes)
    end
    return out
end

local function due()
    local s = settings()
    if not armed then return false end
    if s.mode == 'days' then
        return frame_counter() - armed.tick >= s.interval * TICKS_PER_DAY
    elseif s.mode == 'month' then
        return month_index() ~= armed.month
    else
        return armed.real_ms >= s.interval * 60000
    end
end

local function pending_prompt()
    local events = reqscript('internal/claude-bridge/events')
    return events.has_pending('timer')
end

local function fire()
    local events = reqscript('internal/claude-bridge/events')
    local text = settings().prompt
    if type(text) ~= 'string' or text == '' then text = DEFAULT_PROMPT end
    -- The prompt is UTF-8 in settings; queue CP437 so the dispatcher's conversion restores it.
    events.push_special('timer', (text:gsub('[^%c]+', dfhack.utf2df)), {fired = fired + 1})
    fired = fired + 1
    last_fired_tick = frame_counter()
    reset('fired')
end

local function check()
    if not dfhack.isMapLoaded() then return end
    local s = settings()
    if not s.enabled then return end
    if not armed then reset('enabled') end
    local now = dfhack.getTickCount()
    if s.mode == 'minutes' then
        -- Real time counts only while the game runs.
        if not dfhack.world.ReadPauseState() then
            armed.real_ms = armed.real_ms + math.max(0, now - armed.last_ms)
        end
    end
    armed.last_ms = now
    if due() then
        if pending_prompt() then
            -- Claude has not taken the last prompt yet; wait rather than stack another.
            return
        end
        fire()
    end
end

function start()
    if running then return end
    reset('started')
    repeatutil.scheduleEvery(JOB, CHECK_FRAMES, 'frames', function() pcall(check) end)
    running = true
end

function stop()
    pcall(repeatutil.cancel, JOB)
    running = false
end

-- Settings changes from the window: validate and re-arm.
function configure(changes)
    local s = settings()
    if changes.enabled ~= nil then s.enabled = changes.enabled == true end
    if changes.mode ~= nil then
        local ok = false
        for _, m in ipairs(MODES) do if m == changes.mode then ok = true end end
        if not ok then return false, 'mode must be days, month, or minutes' end
        s.mode = changes.mode
    end
    if changes.interval ~= nil then
        local n = tonumber(changes.interval)
        if not n or n < 1 or n > 10000 then return false, 'interval must be 1-10000' end
        s.interval = math.floor(n)
    end
    if changes.prompt ~= nil then
        if type(changes.prompt) ~= 'string' then return false, 'prompt must be text' end
        s.prompt = changes.prompt
    end
    state.set_timer(s)
    reset('configured')
    return true
end

local function status_op(args)
    local s = settings()
    return {
        enabled = s.enabled, mode = s.mode, interval = s.interval, prompt = s.prompt,
        running = running, fired = fired, last_fired_tick = last_fired_tick,
        progress = progress(), paused = safe(dfhack.world.ReadPauseState),
        modes = MODES,
        note = 'the timer re-arms whenever the mod sends Claude an event batch, freezes while the game is paused, '
            .. 'and never queues a second prompt while one is waiting',
    }
end

function ops()
    return {
        ['timer.status'] = {namespace = 'events', handler = status_op},
    }
end
