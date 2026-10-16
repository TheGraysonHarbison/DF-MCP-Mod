-- Claude's plan and the player's goals, kept as files in the save (plan section 13, item
-- 14.0): <save>/claude-df/plan.md is Claude's own (read, replace, append) and goals.md is
-- the player's, edited in the goals window and sent to Claude on demand as a `goals`
-- event carrying the goal prompt with the goals substituted.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local state = reqscript('internal/claude-bridge/state')

FOLDER = 'claude-df'
PLAN_FILE = 'plan.md'
GOALS_FILE = 'goals.md'
MAX_BYTES = 65536
GOALS_PLACEHOLDER = '{Put Goals Here}'
DEFAULT_GOAL_PROMPT = 'Here is the updated list of goals for you to achieve in this map:\n'
    .. GOALS_PLACEHOLDER .. '\n\n---\n\n'
    .. 'Update the plan accordingly and send a ping to Dwarf Fortress when the plan is made.\n'

-- CP437 conversions that leave newlines and other control characters alone (the plain
-- converters turn them into glyphs).
function to_cp437(text)
    return (text:gsub('[^%c]+', dfhack.utf2df))
end

function to_utf8(text)
    return (text:gsub('[^%c]+', dfhack.df2utf))
end

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- The current save's folder, or nil when no save is loaded.
function save_dir()
    local dir = safe(dfhack.getSavePath)
    if not dir or dir == '' then return nil end
    local last = dir:sub(-1)
    if last ~= '/' and last ~= '\\' then dir = dir .. '/' end
    return dir
end

function folder()
    local dir = save_dir()
    if not dir then return nil end
    return dir .. FOLDER .. '/'
end

local function path_of(name)
    local dir = folder()
    if not dir then return nil end
    return dir .. name
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

local function write_file(path, text)
    local f, err = io.open(path, 'wb')
    if not f then return false, tostring(err) end
    f:write(text)
    f:close()
    return true
end

-- Creates the folder and both files when missing. Called on enable; safe to repeat.
function ensure_files()
    local dir = folder()
    if not dir then return false, 'no save is loaded' end
    local ok, err = pcall(dfhack.filesystem.mkdir_recursive, dir)
    if not ok then return false, tostring(err) end
    for _, name in ipairs({PLAN_FILE, GOALS_FILE}) do
        local path = dir .. name
        if not dfhack.filesystem.exists(path) then
            write_file(path, '')
        end
    end
    return true
end

local function file_info(name)
    local path = path_of(name)
    if not path then return nil end
    local exists = dfhack.filesystem.exists(path)
    return {
        name = name,
        exists = exists,
        bytes = exists and (safe(function() return #read_file(path) end) or 0) or 0,
    }
end

local function info(args)
    local dir = folder()
    if not dir then return rpc.error_result(rpc.ERR_NO_WORLD, 'no save is loaded') end
    return {
        folder = dir,
        save_folder = safe(dfhack.world.ReadWorldFolder),
        plan = file_info(PLAN_FILE),
        goals = file_info(GOALS_FILE),
        max_bytes = MAX_BYTES,
        goal_prompt = state.get_goal_prompt(),
    }
end

local function read_named(name)
    local path = path_of(name)
    if not path then return rpc.error_result(rpc.ERR_NO_WORLD, 'no save is loaded') end
    ensure_files()
    local text = read_file(path) or ''
    -- Files are UTF-8; the dispatcher converts every outgoing string from CP437, so hand
    -- it CP437 to get the file's text back unchanged (characters outside CP437 are lost).
    return {file = name, text = to_cp437(text), bytes = #text}
end

local function plan_read(args) return read_named(PLAN_FILE) end
local function goals_read(args) return read_named(GOALS_FILE) end

local function check_text(text)
    if type(text) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"text" must be a string')
    end
    return nil
end

local function plan_write(args)
    local err = check_text(args.text)
    if err then return err end
    local path = path_of(PLAN_FILE)
    if not path then return rpc.error_result(rpc.ERR_NO_WORLD, 'no save is loaded') end
    ensure_files()
    if #args.text > MAX_BYTES then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('the plan is capped at %d bytes; this text is %d'):format(MAX_BYTES, #args.text))
    end
    local ok, werr = write_file(path, args.text)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'cannot write the plan: ' .. werr) end
    return {file = PLAN_FILE, bytes = #args.text, replaced = true}
end

local function plan_append(args)
    local err = check_text(args.text)
    if err then return err end
    local path = path_of(PLAN_FILE)
    if not path then return rpc.error_result(rpc.ERR_NO_WORLD, 'no save is loaded') end
    ensure_files()
    local current = read_file(path) or ''
    local addition = args.text
    if #current > 0 and current:sub(-1) ~= '\n' then addition = '\n' .. addition end
    if #addition > 0 and addition:sub(-1) ~= '\n' then addition = addition .. '\n' end
    if #current + #addition > MAX_BYTES then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('the plan is capped at %d bytes; it holds %d and this adds %d. Rewrite it with write_plan'):format(
                MAX_BYTES, #current, #addition))
    end
    local ok, werr = write_file(path, current .. addition)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'cannot write the plan: ' .. werr) end
    return {file = PLAN_FILE, bytes = #current + #addition, appended = #addition}
end

-- The goals window writes goals.md; this keeps the file and the UI on one code path.
function save_goals(text)
    local path = path_of(GOALS_FILE)
    if not path then return false end
    ensure_files()
    return write_file(path, text)
end

function load_goals()
    local path = path_of(GOALS_FILE)
    if not path then return '' end
    ensure_files()
    return read_file(path) or ''
end

-- The goal prompt with the goals substituted; what the Send button delivers.
function render_goals_message()
    local goals = load_goals()
    if goals:match('^%s*$') then goals = '(no goals written yet)' end
    local template = state.get_goal_prompt()
    local message, n = template:gsub(GOALS_PLACEHOLDER:gsub('%p', '%%%0'), function() return goals end)
    if n == 0 then message = template .. '\n' .. goals end
    return message
end

-- Queues the goals message as a `goals` event (always allowed; not a toggled kind).
function send_goals()
    local events = reqscript('internal/claude-bridge/events')
    -- Queued as CP437 like every other event; the dispatcher turns it back into UTF-8.
    local entry = events.push_special('goals', to_cp437(render_goals_message()))
    return entry
end

function ops()
    return {
        ['plan.info'] = {namespace = 'plan', handler = info, needs_world = true},
        ['plan.read'] = {namespace = 'plan', handler = plan_read, needs_world = true},
        ['plan.write'] = {namespace = 'plan', handler = plan_write, needs_world = true},
        ['plan.append'] = {namespace = 'plan', handler = plan_append, needs_world = true},
        ['goals.read'] = {namespace = 'plan', handler = goals_read, needs_world = true},
    }
end
