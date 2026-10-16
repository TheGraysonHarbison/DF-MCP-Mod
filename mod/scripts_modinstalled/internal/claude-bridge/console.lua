-- Allowlisted DFHack console execution.
--@ module = true

local state = reqscript('internal/claude-bridge/state')
local rpc = reqscript('internal/claude-bridge/rpc')

-- Commands that evaluate arbitrary Lua need the lua_eval permission as well as an allowlist entry.
local LUA_COMMANDS = {lua = true, [':lua'] = true}

-- Subcommands of this mod that change its own settings. Never runnable through the bridge,
-- whatever the allowlist says, so the settings panel stays the only trust boundary.
-- Anything that is not a plain word (quotes, separators, `-` flags) is refused too.
local MOD_COMMAND = 'claude-bridge'
local MOD_SAFE_SUBCOMMANDS = {status = true, help = true, reload = true, test = true, send = true,
                              ['trade-snapshot'] = true,
                              ['dialog-snapshot'] = true}
-- `timer` changes settings and stays player-only like perm, allow, deny, event, goals.

local function command_name(line)
    return line:match('^%s*(%S+)')
end

local function mod_subcommand(line)
    return line:match('^%s*%S+%s+(%S+)')
end

-- Returns an error message when the line must not run, else nil.
local function guard_mod_command(line)
    if line:find(';', 1, true) then
        return 'command separators are not allowed in a ' .. MOD_COMMAND .. ' line'
    end
    local sub = mod_subcommand(line)
    if sub == nil or MOD_SAFE_SUBCOMMANDS[sub] then
        return nil
    end
    return ('"%s %s" cannot be run through the bridge; only the player may change these settings')
        :format(MOD_COMMAND, sub)
end

local function run(args)
    local line = args.command
    if type(line) ~= 'string' or not command_name(line) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"command" must be a non-empty string')
    end
    local name = command_name(line)
    if not state.console_allowed(name) then
        return rpc.error_result(rpc.ERR_NOT_ALLOWED,
            ('"%s" is not on the console allowlist; the player can add it with: claude-bridge allow %s')
                :format(name, name))
    end
    if name == MOD_COMMAND then
        local why = guard_mod_command(line)
        if why then
            return rpc.error_result(rpc.ERR_NOT_ALLOWED, why)
        end
    end
    if LUA_COMMANDS[name] and not state.is_allowed('lua_eval') then
        return rpc.error_result(rpc.ERR_NOT_ALLOWED,
            'running Lua needs the lua_eval permission; the player can enable it in claude-bridge settings')
    end
    local output, result = dfhack.run_command_silent(line)
    return {
        command = line,
        ok = result == CR_OK,
        result = result,
        output = output or '',
    }
end

function ops()
    return {
        ['console.run'] = {namespace = 'console', handler = run},
    }
end
