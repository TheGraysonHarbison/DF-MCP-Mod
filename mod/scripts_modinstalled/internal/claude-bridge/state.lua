-- Settings and permissions for claude-bridge. Global (all worlds), stored as JSON.
--@ module = true

local json = require('json')
local scriptmanager = require('script-manager')

MOD_ID = 'claude-bridge'
MOD_VERSION = '1.0.1-alpha'
PROTOCOL_VERSION = 35

-- Settings groups, in display order.
GROUPS = {'General', 'Units', 'Items', 'Logistics', 'World', 'Commands'}

-- Permission namespaces and plain toggles. Order within a group is the display order in the
-- settings window; `hotkey` is the toggle's key there. Entries with `toggle = true` are not
-- op namespaces: the dispatcher ignores them and a handler reads them with is_allowed().
NAMESPACES = {
    {key = 'time',     group = 'General',  hotkey = 'CUSTOM_T', default = true,
     label = 'Read date, time and weather'},
    {key = 'settings', group = 'General',  hotkey = 'CUSTOM_S', default = true,
     label = 'Read these settings'},
    {key = 'pause_write', group = 'General', hotkey = 'CUSTOM_H', default = false,
     label = 'Pause and unpause the game'},
    {key = 'screens_write', group = 'General', hotkey = 'CUSTOM_SHIFT_S', default = false,
     label = 'Drive game screens: trade, meetings, popups'},
    {key = 'events',   group = 'General',  hotkey = 'CUSTOM_X', default = true,
     label = 'Send in-game events (per kind, Events tab)'},
    {key = 'plan',     group = 'General',  hotkey = 'CUSTOM_SHIFT_P', default = true,
     label = 'Read and write its plan file, read goals'},
    {key = 'units',    group = 'Units',    hotkey = 'CUSTOM_U', default = true,
     label = 'Read units'},
    {key = 'units_write', group = 'Units', hotkey = 'CUSTOM_N', default = false,
     label = 'Rename units (nickname)'},
    {key = 'labor_write', group = 'Units', hotkey = 'CUSTOM_SHIFT_L', default = false,
     label = 'Assign work details (labors)'},
    {key = 'nobles',   group = 'Units',    hotkey = 'CUSTOM_B', default = true,
     label = 'Read noble positions'},
    {key = 'nobles_write', group = 'Units', hotkey = 'CUSTOM_M', default = false,
     label = 'Assign noble positions'},
    {key = 'military', group = 'Units',    hotkey = 'CUSTOM_Q', default = true,
     label = 'Read squads'},
    {key = 'military_write', group = 'Units', hotkey = 'CUSTOM_V', default = false,
     label = 'Create, edit, disband squads'},
    {key = 'stocks',   group = 'Items',    hotkey = 'CUSTOM_I', default = true,
     label = 'Read stocks and artifacts'},
    {key = 'stocks_true', group = 'Items', hotkey = 'CUSTOM_R', default = true, toggle = true,
     label = 'True stock counts (off: bookkeeper view)'},
    {key = 'kitchen_write', group = 'Items', hotkey = 'CUSTOM_J', default = false,
     label = 'Change kitchen cook and brew settings'},
    {key = 'orders',   group = 'Logistics', hotkey = 'CUSTOM_O', default = true,
     label = 'Read work orders'},
    {key = 'orders_write', group = 'Logistics', hotkey = 'CUSTOM_W', default = false,
     label = 'Work orders and workshop jobs'},
    {key = 'workshops', group = 'Logistics', hotkey = 'CUSTOM_K', default = true,
     label = 'Read workshops'},
    {key = 'build_write', group = 'Logistics', hotkey = 'CUSTOM_D', default = false,
     label = 'Place workshop blueprints'},
    {key = 'trade',    group = 'Logistics', hotkey = 'CUSTOM_CTRL_T', default = true,
     label = 'Read caravans, depot, broker'},
    {key = 'trade_write', group = 'Logistics', hotkey = 'CUSTOM_CTRL_R', default = false,
     label = 'Request the broker, haul goods, offer trades'},
    {key = 'stockpiles', group = 'Logistics', hotkey = 'CUSTOM_E', default = true,
     label = 'Read stockpiles'},
    {key = 'stockpiles_write', group = 'Logistics', hotkey = 'CUSTOM_F', default = false,
     label = 'Paint, configure, delete stockpiles'},
    {key = 'map',      group = 'World',    hotkey = 'CUSTOM_P', default = true,
     label = 'Read map tiles'},
    {key = 'dig_write', group = 'World',   hotkey = 'CUSTOM_G', default = false,
     label = 'Designate digging and smoothing'},
    {key = 'zones',    group = 'World',    hotkey = 'CUSTOM_Z', default = true,
     label = 'Read zones'},
    {key = 'zones_write', group = 'World', hotkey = 'CUSTOM_Y', default = false,
     label = 'Paint, edit, assign, delete zones'},
    {key = 'hotkeys_write', group = 'World', hotkey = 'CUSTOM_SHIFT_K', default = false,
     label = 'Name and place zoom hotkeys (points of interest)'},
    {key = 'console',  group = 'Commands', hotkey = 'CUSTOM_C', default = false,
     label = 'Run allowlisted console cmds'},
    {key = 'lua_eval', group = 'Commands', hotkey = 'CUSTOM_L', default = false,
     label = 'Allow "lua" via console'},
}

-- Entries of one group, in order.
function namespaces_in(group)
    local out = {}
    for _, ns in ipairs(NAMESPACES) do
        if ns.group == group then table.insert(out, ns) end
    end
    return out
end

-- Namespaces that are always allowed. 'core' carries only ping.
local ALWAYS_ALLOWED = {core = true, messages = true}

local settings = nil

-- Same location scriptmanager.getModStatePath() produces. Computed here because DFHack
-- 53.16-r2 ships that helper with a '+' where '..' belongs, so calling it raises
-- "attempt to perform arithmetic on a string value".
local function state_dir()
    if dfhack.getConfigPath then
        return dfhack.getConfigPath() .. '/mods/' .. MOD_ID .. '/'
    end
    local dir = scriptmanager.getModStatePath(MOD_ID)
    local last = dir:sub(-1)
    if last ~= '/' and last ~= '\\' then
        dir = dir .. '/'
    end
    return dir
end

local function settings_path()
    local dir = state_dir()
    local ok, err = pcall(dfhack.filesystem.mkdir_recursive, dir)
    if not ok then
        dfhack.printerr(('claude-bridge: cannot create %s: %s'):format(dir, tostring(err)))
    end
    return dir .. 'settings.json'
end

local function defaults()
    local permissions = {}
    for _, ns in ipairs(NAMESPACES) do
        permissions[ns.key] = ns.default
    end
    return {permissions = permissions, console_allow = {}, events = {}, goal_prompt = nil, timer = nil}
end

local function read_file(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local text = f:read('*a')
    f:close()
    return text
end

local function write_file(path, text)
    local f, err = io.open(path, 'w')
    if not f then
        dfhack.printerr(('claude-bridge: cannot write %s: %s'):format(path, tostring(err)))
        return false
    end
    f:write(text)
    f:close()
    return true
end

function load_settings()
    local loaded = defaults()
    local text = read_file(settings_path())
    if text and #text > 0 then
        local ok, data = pcall(json.decode, text)
        if ok and type(data) == 'table' then
            if type(data.permissions) == 'table' then
                for key, value in pairs(data.permissions) do
                    if loaded.permissions[key] ~= nil then
                        loaded.permissions[key] = value and true or false
                    end
                end
            end
            if type(data.console_allow) == 'table' then
                for _, cmd in ipairs(data.console_allow) do
                    if type(cmd) == 'string' then
                        table.insert(loaded.console_allow, cmd)
                    end
                end
            end
            if type(data.goal_prompt) == 'string' and data.goal_prompt ~= '' then
                loaded.goal_prompt = data.goal_prompt
            end
            if type(data.timer) == 'table' then
                loaded.timer = {
                    enabled = data.timer.enabled == true,
                    mode = type(data.timer.mode) == 'string' and data.timer.mode or nil,
                    interval = tonumber(data.timer.interval),
                    prompt = type(data.timer.prompt) == 'string' and data.timer.prompt or nil,
                }
            end
            if type(data.events) == 'table' then
                for key, value in pairs(data.events) do
                    if type(key) == 'string' then loaded.events[key] = value and true or false end
                end
            end
        else
            dfhack.printerr('claude-bridge: settings.json is not valid JSON, using defaults')
        end
    end
    settings = loaded
    return settings
end

function get_settings()
    if not settings then
        load_settings()
    end
    return settings
end

function save_settings()
    return write_file(settings_path(), json.encode(get_settings()))
end

function is_allowed(namespace)
    if ALWAYS_ALLOWED[namespace] then
        return true
    end
    return get_settings().permissions[namespace] == true
end

function set_permission(namespace, value)
    local s = get_settings()
    if s.permissions[namespace] == nil then
        return false
    end
    s.permissions[namespace] = value and true or false
    save_settings()
    return true
end

-- The prompt the goals window sends; the default lives in the plan module.
function get_goal_prompt()
    local s = get_settings()
    if type(s.goal_prompt) == 'string' and s.goal_prompt ~= '' then return s.goal_prompt end
    return reqscript('internal/claude-bridge/plan').DEFAULT_GOAL_PROMPT
end

function set_goal_prompt(text)
    local s = get_settings()
    s.goal_prompt = text
    save_settings()
end

-- The prompt timer's settings, filled from the timer module's defaults.
function get_timer()
    local s = get_settings()
    local defaults = reqscript('internal/claude-bridge/timer').DEFAULT_SETTINGS
    local t = s.timer or {}
    return {
        enabled = t.enabled == true,
        mode = t.mode or defaults.mode,
        interval = t.interval or defaults.interval,
        prompt = t.prompt or defaults.prompt,
    }
end

function set_timer(values)
    local s = get_settings()
    s.timer = {enabled = values.enabled == true, mode = values.mode, interval = values.interval,
               prompt = values.prompt}
    save_settings()
end

-- Event kinds: enabled per kind, defaulting to the kind's own default (events module).
function is_event_enabled(kind)
    local s = get_settings()
    if s.events[kind] ~= nil then return s.events[kind] == true end
    local events = reqscript('internal/claude-bridge/events')
    local spec = events.kind_spec(kind)
    return spec ~= nil and spec.default == true
end

function set_event_enabled(kind, value)
    local s = get_settings()
    s.events[kind] = value and true or false
    save_settings()
end

function console_allowed(command_name)
    for _, allowed in ipairs(get_settings().console_allow) do
        if allowed == command_name or allowed == '*' then
            return true
        end
    end
    return false
end

function allow_console(command_name)
    local s = get_settings()
    for _, existing in ipairs(s.console_allow) do
        if existing == command_name then
            return
        end
    end
    table.insert(s.console_allow, command_name)
    table.sort(s.console_allow)
    save_settings()
end

function deny_console(command_name)
    local s = get_settings()
    for i = #s.console_allow, 1, -1 do
        if s.console_allow[i] == command_name then
            table.remove(s.console_allow, i)
        end
    end
    save_settings()
end
