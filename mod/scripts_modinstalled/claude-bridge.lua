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
    claude-bridge perm <namespace> on|off
    claude-bridge allow <command>
    claude-bridge deny <command>
    claude-bridge test <json request>
]====]

local GLOBAL_KEY = 'claude-bridge'
local RPC_MODULE_NAME = 'rpc.claude_bridge'

local state = reqscript('internal/claude-bridge/state')
local rpc = reqscript('internal/claude-bridge/rpc')
local core_ops = reqscript('internal/claude-bridge/core')
local time_ops = reqscript('internal/claude-bridge/time')
local units_ops = reqscript('internal/claude-bridge/units')
local console_ops = reqscript('internal/claude-bridge/console')

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

local function do_enable()
    state.load_settings()
    rpc.reset()
    for _, mod in ipairs({core_ops, time_ops, units_ops, console_ops}) do
        rpc.register_many(mod.ops())
    end
    publish_rpc()
    enabled = true
end

local function do_disable()
    unpublish_rpc()
    enabled = false
end

dfhack.onStateChange[GLOBAL_KEY] = function(sc)
    if sc == SC_MAP_UNLOADED then
        if enabled then
            do_disable()
        end
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
    for _, ns in ipairs(state.NAMESPACES) do
        print(('  %-10s %s'):format(ns.key, s.permissions[ns.key] and 'on' or 'off'))
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
elseif command == 'perm' then
    local ns, value = args[2], args[3]
    if not ns or (value ~= 'on' and value ~= 'off') then
        qerror('usage: claude-bridge perm <namespace> on|off')
    end
    if not state.set_permission(ns, value == 'on') then
        qerror('unknown namespace: ' .. ns)
    end
    print_status()
elseif command == 'allow' then
    if not args[2] then qerror('usage: claude-bridge allow <command>') end
    state.allow_console(args[2])
    print_status()
elseif command == 'deny' then
    if not args[2] then qerror('usage: claude-bridge deny <command>') end
    state.deny_console(args[2])
    print_status()
elseif command == 'test' then
    if not enabled then qerror('claude-bridge is not enabled') end
    local request = table.concat(args, ' ', 2)
    print(rpc.dispatch(request))
else
    qerror('unknown command: ' .. command .. ' (try: claude-bridge help)')
end
