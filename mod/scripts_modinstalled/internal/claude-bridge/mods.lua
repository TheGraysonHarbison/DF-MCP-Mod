-- Active Dwarf Fortress mods and loaded DFHack plugins (plan section 13, Phase 18). Reads
-- only: the game's object loader order for mods, DFHack's plugin registry for plugins.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local scriptmanager = require('script-manager')

DEFAULT_LIMIT = 25

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- Where a mod was installed from, by the path prefix the object loader recorded.
local function mod_source(path)
    if not path then return 'unknown' end
    if path:find('^data/vanilla/') then return 'vanilla' end
    if path:find('^data/installed_mods/') then return 'installed' end
    if path:find('^mods/') then return 'workshop' end
    return 'other'
end

local function mod_rows(limit)
    local rows, total = {}, 0
    local mods = safe(scriptmanager.get_active_mods) or {}
    for i, m in ipairs(mods) do
        total = total + 1
        if #rows < limit then
            table.insert(rows, {
                load_order = i,
                id = m.id,
                name = m.name,
                version = m.version,
                numeric_version = m.numeric_version,
                source = mod_source(m.path),
                vanilla = m.vanilla == true,
            })
        end
    end
    return rows, total
end

-- Enabled state: DFHack's own `enable` listing names every plugin with a switch and its
-- state ("name: on"). Plugins with a Lua module also expose isEnabled(), used as a fallback.
local function enable_states()
    local states = {}
    local output = safe(dfhack.run_command_silent, 'enable') or ''
    for name, word in output:gmatch('([%w_%-]+):%s*(%a+)') do
        if word == 'on' then states[name] = true elseif word == 'off' then states[name] = false end
    end
    return states
end

local function plugin_enabled(name, states)
    if states[name] ~= nil then return states[name] end
    local ok, module = pcall(require, 'plugins.' .. name)
    if not ok or type(module) ~= 'table' or type(module.isEnabled) ~= 'function' then
        return nil
    end
    return safe(module.isEnabled)
end

local function plugin_rows(limit, only_enabled)
    local rows, total = {}, 0
    local names = safe(dfhack.internal.listPlugins) or {}
    table.sort(names)
    local states = enable_states()
    for _, name in ipairs(names) do
        local enabled = plugin_enabled(name, states)
        if not only_enabled or enabled == true then
            total = total + 1
            if #rows < limit then
                local commands = safe(dfhack.internal.listCommands, name) or {}
                local row = {name = name, commands = commands}
                if enabled ~= nil then row.enabled = enabled end
                local desc = safe(dfhack.internal.getCommandDescription, name)
                if desc and desc ~= '' then row.description = desc end
                table.insert(rows, row)
            end
        end
    end
    return rows, total
end

local function list(args)
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    local mods, mod_total = mod_rows(limit)
    local plugins, plugin_total = plugin_rows(limit, args.only_enabled == true)
    return {
        world_loaded = dfhack.isWorldLoaded(),
        dfhack_version = safe(dfhack.getDFHackVersion),
        df_version = safe(dfhack.getDFVersion),
        mods = mods,
        mod_count = mod_total,
        mods_truncated = mod_total > #mods,
        plugins = plugins,
        plugin_count = plugin_total,
        plugins_truncated = plugin_total > #plugins,
        note = 'mods come from the world\'s load order and need a loaded world; plugins without an enabled '
            .. 'field have no enable/disable switch and run on demand through their commands',
    }
end

function ops()
    return {
        ['settings.mods'] = {namespace = 'settings', handler = list},
    }
end
