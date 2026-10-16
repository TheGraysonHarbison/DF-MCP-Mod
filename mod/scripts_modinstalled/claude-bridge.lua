-- Bridge between Claude Code and Dwarf Fortress. See mod/README.md.
--@ module = true
--@ enable = true
--[====[
claude-bridge
=============
Exposes a permission-gated JSON RPC surface that the df-mcp server calls through
DFHack's remote API, so Claude can observe (and later play) your fort.

Usage::

    enable claude-bridge
    disable claude-bridge
    claude-bridge [status]
    claude-bridge settings
    claude-bridge goals
    claude-bridge perm <namespace> on|off
    claude-bridge event <kind> on|off
    claude-bridge send <text>
    claude-bridge timer [on|off|days N|month|minutes N|reset]
    claude-bridge allow <command>
    claude-bridge deny <command>
    claude-bridge reload
    claude-bridge test <json request>

``send`` queues a test event carrying the text, which reaches Claude through the
channel like any other event (a way to check the push path from the game). ``reload``
re-reads the mod's Lua modules from disk and re-registers the ops without
disabling the bridge. For development.
]====]

local GLOBAL_KEY = 'claude-bridge'
local RPC_MODULE_NAME = 'rpc.claude_bridge'

local json = require('json')
local state = reqscript('internal/claude-bridge/state')
local rpc = reqscript('internal/claude-bridge/rpc')


enabled = enabled or false

function isEnabled()
    return enabled
end

local function persist_enabled()
    if dfhack.isWorldLoaded() then
        dfhack.persistent.saveSiteData(GLOBAL_KEY, {enabled = enabled})
    end
end

-- DFHack's RunLua only accepts modules named rpc.*, loaded with require(). Mod scripts load
-- with reqscript(), so we publish the dispatcher into package.loaded under that name.
local function publish_rpc()
    package.loaded[RPC_MODULE_NAME] = {
        dispatch = function(request)
            return rpc.dispatch(request)
        end,
    }
end

local function unpublish_rpc()
    package.loaded[RPC_MODULE_NAME] = nil
end

-- Drop every cached internal module so a reload re-runs helpers (materials, map) that
-- op modules captured as locals, not only the files that changed since the last load.
local function forget_internal_modules()
    pcall(function()
        for path in pairs(dfhack.internal.scripts) do
            if path:find('internal/claude%-bridge/') then
                dfhack.internal.scripts[path] = nil
            end
        end
    end)
end

local function register_ops()
    forget_internal_modules()
    state = reqscript('internal/claude-bridge/state')
    rpc = reqscript('internal/claude-bridge/rpc')
    rpc.reset()
    for _, name in ipairs(rpc.OP_MODULES) do
        rpc.register_many(reqscript('internal/claude-bridge/' .. name).ops())
    end
end

local function events_module()
    return reqscript('internal/claude-bridge/events')
end

local function timer_module()
    return reqscript('internal/claude-bridge/timer')
end

local function do_enable()
    state.load_settings()
    register_ops()
    publish_rpc()
    pcall(function() events_module().start() end)
    pcall(function() timer_module().start() end)
    pcall(function() reqscript('internal/claude-bridge/plan').ensure_files() end)
    enabled = true
end

local function do_disable()
    pcall(function() timer_module().stop() end)
    pcall(function() events_module().stop() end)
    unpublish_rpc()
    enabled = false
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        if enabled then
            do_disable()
        end
        pcall(function() events_module().reset() end)
        return
    end
    if sc ~= SC_MAP_LOADED or not dfhack.world.isFortressMode() then
        return
    end
    local saved = dfhack.persistent.getSiteData(GLOBAL_KEY, {enabled = false})
    if saved.enabled then
        do_enable()
    end
end

local function print_status()
    local s = state.get_settings()
    print(('claude-bridge is %s'):format(enabled and 'enabled' or 'disabled'))
    print('permissions:')
    for _, group in ipairs(state.GROUPS) do
        print('  ' .. group)
        for _, ns in ipairs(state.namespaces_in(group)) do
            print(('    %-12s %s'):format(ns.key, s.permissions[ns.key] and 'on' or 'off'))
        end
    end
    print('console allowlist: ' .. (#s.console_allow > 0 and table.concat(s.console_allow, ', ') or '(empty)'))
end

local function print_help()
    print(dfhack.script_help())
end

if dfhack_flags.module then
    return
end

if dfhack_flags.enable then
    if dfhack_flags.enable_state then
        do_enable()
    else
        do_disable()
    end
    persist_enabled()
    return
end

local args = {...}
local command = args[1]

if not command or command == 'status' then
    print_status()
elseif command == 'help' or command == '-h' or command == '--help' then
    print_help()
elseif command == 'settings' then
    reqscript('internal/claude-bridge/ui/settings').show()
elseif command == 'goals' then
    if not enabled then qerror('claude-bridge is not enabled') end
    reqscript('internal/claude-bridge/ui/goals').show()
elseif command == 'perm' then
    local ns, value = args[2], args[3]
    if not ns or (value ~= 'on' and value ~= 'off') then
        qerror('usage: claude-bridge perm <namespace> on|off')
    end
    if not state.set_permission(ns, value == 'on') then
        qerror('unknown namespace: ' .. ns)
    end
    print_status()
elseif command == 'event' then
    local kind, value = args[2], args[3]
    if not kind or (value ~= 'on' and value ~= 'off') then
        qerror('usage: claude-bridge event <kind> on|off')
    end
    if not events_module().kind_spec(kind) then qerror('unknown event kind: ' .. kind) end
    state.set_event_enabled(kind, value == 'on')
    print(('event %s is %s'):format(kind, value))
elseif command == 'timer' then
    local timer = timer_module()
    local what, n = args[2], tonumber(args[3])
    if what == 'on' or what == 'off' then
        assert(timer.configure({enabled = what == 'on'}))
    elseif what == 'days' or what == 'minutes' then
        local ok, err = timer.configure({mode = what, interval = n or timer.settings().interval})
        if not ok then qerror(err) end
    elseif what == 'month' then
        assert(timer.configure({mode = 'month'}))
    elseif what == 'reset' then
        assert(timer.configure({prompt = timer.DEFAULT_PROMPT}))
        print('timer prompt reset to the default')
    elseif what ~= nil then
        qerror('usage: claude-bridge timer [on|off|days N|month|minutes N|reset]')
    end
    local s = timer.settings()
    print(('timer %s: every %s%s'):format(s.enabled and 'on' or 'off',
        s.mode == 'month' and 'month change' or (s.interval .. ' ' .. s.mode), ''))
    print(json.encode(timer.progress()))
elseif command == 'send' then
    if not enabled then qerror('claude-bridge is not enabled') end
    local text = table.concat(args, ' ', 2)
    if text == '' then text = 'test message from the DFHack console' end
    local result = rpc.dispatch(json.encode({op = 'events.emit', args = {kind = 'test', text = text}}))
    print('queued: ' .. result)
elseif command == 'allow' then
    if not args[2] then qerror('usage: claude-bridge allow <command>') end
    state.allow_console(args[2])
    print_status()
elseif command == 'deny' then
    if not args[2] then qerror('usage: claude-bridge deny <command>') end
    state.deny_console(args[2])
    print_status()
elseif command == 'reload' then
    if not enabled then qerror('claude-bridge is not enabled') end
    pcall(function() timer_module().stop() end)
    pcall(function() events_module().stop() end)
    register_ops()
    publish_rpc()
    pcall(function() events_module().start() end)
    pcall(function() timer_module().start() end)
    print(('claude-bridge reloaded, %d ops'):format(#rpc.list_ops()))
elseif command == 'test' then
    if not enabled then qerror('claude-bridge is not enabled') end
    local request = table.concat(args, ' ', 2)
    print(rpc.dispatch(request))
else
    qerror('unknown command: ' .. command .. ' (try: claude-bridge help)')
end
