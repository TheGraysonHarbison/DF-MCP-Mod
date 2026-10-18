-- Claude's plan and the player's goals (plan section 13, item 14.0; P2-3.0 in section 16).
-- The texts live in DFHack's per-site persistent data, which DFHack keeps in memory and
-- writes into the save whenever the game saves (autosaves and saves to a new folder
-- included), so they follow the fort wherever the game puts it. <save>/claude-df/plan.md
-- and goals.md are a readable mirror rewritten from the store after every change and on
-- enable; the store is the source of truth. The plan is Claude's own (read, replace,
-- append); the goals are the player's, edited in the goals window and sent to Claude on
-- demand as a `goals` event carrying the goal prompt with the goals substituted.
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

-- Site-data keys per text. Each entry is a table {text = <UTF-8 bytes>}, so "never stored"
-- (no entry: getSiteData returns nil) differs from "stored empty" ({text = ''}) and a plan
-- Claude cleared on purpose is never re-imported from a stale mirror file.
STORE_KEYS = {
    [PLAN_FILE] = 'claude-bridge/plan',
    [GOALS_FILE] = 'claude-bridge/goals',
}

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

-- Persistent site data needs a loaded fort (it is kept per site).
function store_ready()
    if not safe(dfhack.isMapLoaded) then return false end
    if not safe(dfhack.world.isFortressMode) then return false end
    local site = safe(dfhack.world.GetCurrentSiteId)
    return type(site) == 'number' and site >= 0
end

-- The stored text, or nil when nothing was ever stored for this fort. Nothing is cached in
-- Lua: DFHack holds the store in memory and swaps it with the loaded fort, so no state can
-- leak from one save to the next.
local function store_get(name)
    local ok, entry = pcall(dfhack.persistent.getSiteData, STORE_KEYS[name])
    if not ok or type(entry) ~= 'table' or type(entry.text) ~= 'string' then return nil end
    return entry.text
end

local function store_put(name, text)
    local ok, err = pcall(dfhack.persistent.saveSiteData, STORE_KEYS[name], {text = text})
    if not ok then return false, tostring(err) end
    return true
end

-- The text in force ('' when there is none). Migration for saves made before the store
-- existed: when the store has no entry and the CURRENT save's mirror file holds text, that
-- text (the file's UTF-8 bytes, unchanged) moves into the store. Other save folders are
-- never read.
local function load_text(name)
    local text = store_get(name)
    if text then return text end
    local path = path_of(name)
    local from_file = path and read_file(path) or nil
    if from_file and not from_file:match('^%s*$') then
        store_put(name, from_file)
        return from_file
    end
    return ''
end

-- Rewrites both mirror files in the current save's claude-df/ from the store. Never raises:
-- returns true, or false and a note. A never-stored text gets an empty file only when the
-- file is missing; an existing file is never blanked for it (load_text imports any text).
function write_mirror()
    local dir = folder()
    if not dir then return false, 'no save is loaded' end
    local ok, err = pcall(dfhack.filesystem.mkdir_recursive, dir)
    if not ok then return false, 'cannot create ' .. dir .. ': ' .. tostring(err) end
    local notes = {}
    for _, name in ipairs({PLAN_FILE, GOALS_FILE}) do
        local path = dir .. name
        local text = store_get(name)
        if text or not dfhack.filesystem.exists(path) then
            local wok, werr = write_file(path, text or '')
            if not wok then table.insert(notes, ('cannot write %s: %s'):format(path, werr)) end
        end
    end
    if #notes > 0 then return false, table.concat(notes, '; ') end
    return true
end

-- Imports the current save's pre-store files and writes the mirror. Called on enable, which
-- also runs on every fort load; safe to repeat and never overwrites the store with blanks.
function ensure_files()
    if not store_ready() then return false, 'no fort is loaded' end
    load_text(PLAN_FILE)
    load_text(GOALS_FILE)
    return write_mirror()
end

local function no_fort()
    return rpc.error_result(rpc.ERR_NO_WORLD, 'no fort is loaded (the plan and goals live in the fort\'s site data)')
end

-- Writes the mirror after a change; a failure is reported as a note, never as an error.
local function mirror_note()
    local ok, err = write_mirror()
    if ok then return nil end
    return 'saved; the mirror file was not written: ' .. tostring(err)
end

local function text_info(name)
    local text = load_text(name)
    local path = path_of(name)
    local mirror_exists = path ~= nil and dfhack.filesystem.exists(path) or false
    local mirror_text = mirror_exists and read_file(path) or nil
    return {
        name = name,
        stored = store_get(name) ~= nil,
        bytes = #text,
        mirror_exists = mirror_exists,
        mirror_bytes = mirror_text and #mirror_text or 0,
        mirror_current = mirror_text ~= nil and mirror_text == text,
    }
end

local function info(args)
    if not store_ready() then return no_fort() end
    local plan_i = text_info(PLAN_FILE)
    local goals_i = text_info(GOALS_FILE)
    return {
        storage = 'site data',
        folder = folder(),
        save_folder = safe(dfhack.world.ReadWorldFolder),
        plan = plan_i,
        goals = goals_i,
        mirror_current = plan_i.mirror_current and goals_i.mirror_current,
        max_bytes = MAX_BYTES,
        goal_prompt = state.get_goal_prompt(),
    }
end

local function read_named(name)
    if not store_ready() then return no_fort() end
    local text = load_text(name)
    -- The store holds UTF-8, the same bytes the files held; the dispatcher converts every
    -- outgoing string from CP437, so hand it CP437 to get the text back unchanged
    -- (characters outside CP437 are lost).
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
    if not store_ready() then return no_fort() end
    if #args.text > MAX_BYTES then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('the plan is capped at %d bytes; this text is %d'):format(MAX_BYTES, #args.text))
    end
    -- Writes arrive as UTF-8 and are stored as given.
    local ok, werr = store_put(PLAN_FILE, args.text)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'cannot store the plan: ' .. werr) end
    return {file = PLAN_FILE, bytes = #args.text, replaced = true, note = mirror_note()}
end

local function plan_append(args)
    local err = check_text(args.text)
    if err then return err end
    if not store_ready() then return no_fort() end
    local current = load_text(PLAN_FILE)
    local addition = args.text
    if #current > 0 and current:sub(-1) ~= '\n' then addition = '\n' .. addition end
    if #addition > 0 and addition:sub(-1) ~= '\n' then addition = addition .. '\n' end
    if #current + #addition > MAX_BYTES then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('the plan is capped at %d bytes; it holds %d and this adds %d. Rewrite it with write_plan'):format(
                MAX_BYTES, #current, #addition))
    end
    local ok, werr = store_put(PLAN_FILE, current .. addition)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'cannot store the plan: ' .. werr) end
    return {file = PLAN_FILE, bytes = #current + #addition, appended = #addition, note = mirror_note()}
end

-- The goals window saves through here, so the store, the mirror, and the UI share one code
-- path. `text` is UTF-8.
function save_goals(text)
    if not store_ready() then return false end
    if not store_put(GOALS_FILE, text) then return false end
    write_mirror()
    return true
end

function load_goals()
    if not store_ready() then return '' end
    return load_text(GOALS_FILE)
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
