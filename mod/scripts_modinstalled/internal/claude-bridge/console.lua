-- Allowlisted DFHack console execution.
--@ module = true

local state = reqscript('internal/claude-bridge/state')
local rpc = reqscript('internal/claude-bridge/rpc')

-- Commands that evaluate arbitrary Lua need the lua_eval permission as well as an allowlist entry.
local LUA_COMMANDS = {lua = true, [':lua'] = true}

local function command_name(line)
    return line:match('^%s*(%S+)')
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
