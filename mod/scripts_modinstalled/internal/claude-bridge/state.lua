-- Settings and permissions for claude-bridge. Global (all worlds), stored as JSON.
--@ module = true

local json = require('json')
local scriptmanager = require('script-manager')

MOD_ID = 'claude-bridge'
MOD_VERSION = '0.1.0'
PROTOCOL_VERSION = 1

-- Permission namespaces. Order is the display order in the settings window.
NAMESPACES = {
    {key = 'time',     label = 'Read date, time and weather',  default = true},
    {key = 'units',    label = 'Read units',                  default = true},
    {key = 'settings', label = 'Read these settings',         default = true},
    {key = 'console',  label = 'Run allowlisted console cmds', default = false},
    {key = 'lua_eval', label = 'Allow "lua" via console',      default = false},
}

-- Namespaces that are always allowed. 'core' carries only ping.
local ALWAYS_ALLOWED = {core = true}

local settings = nil

local function settings_path()
    local dir = scriptmanager.getModStatePath(MOD_ID)
    local last = dir:sub(-1)
    if last ~= '/' and last ~= '\\' then
        dir = dir .. '/'
    end
    pcall(dfhack.filesystem.mkdir_recursive, dir)
    return dir .. 'settings.json'
end

local function defaults()
    local permissions = {}
    for _, ns in ipairs(NAMESPACES) do
        permissions[ns.key] = ns.default
    end
    return {permissions = permissions, console_allow = {}}
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
