-- Always-available ops: ping and settings.
--@ module = true

local state = reqscript('internal/claude-bridge/state')
local rpc = reqscript('internal/claude-bridge/rpc')

local function ping(args)
    local paused = nil
    if dfhack.isMapLoaded() then
        paused = dfhack.world.ReadPauseState()
    end
    return {
        mod_version = state.MOD_VERSION,
        protocol_version = state.PROTOCOL_VERSION,
        dfhack_version = dfhack.getDFHackVersion(),
        df_version = dfhack.getDFVersion(),
        world_loaded = dfhack.isWorldLoaded(),
        map_loaded = dfhack.isMapLoaded(),
        fortress_mode = dfhack.isWorldLoaded() and dfhack.world.isFortressMode() or false,
        paused = paused,
        frame = df.global.world.frame_counter,
    }
end

local function settings_get(args)
    local s = state.get_settings()
    local permissions = {}
    for _, ns in ipairs(state.NAMESPACES) do
        permissions[ns.key] = {
            allowed = s.permissions[ns.key] == true,
            label = ns.label,
            group = ns.group,
            toggle = ns.toggle == true,
        }
    end
    local events = {}
    for _, k in ipairs(reqscript('internal/claude-bridge/events').KINDS) do
        events[k.key] = state.is_event_enabled(k.key)
    end
    return {
        groups = state.GROUPS,
        permissions = permissions,
        console_allow = s.console_allow,
        events = events,
        ops = rpc.list_ops(),
    }
end

function ops()
    return {
        ['core.ping'] = {namespace = 'core', handler = ping},
        ['settings.get'] = {namespace = 'settings', handler = settings_get},
    }
end
