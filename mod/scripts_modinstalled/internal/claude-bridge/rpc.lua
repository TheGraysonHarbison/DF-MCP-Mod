-- JSON request dispatcher. Every call from the MCP server lands here. See docs/protocol.md.
--@ module = true

local json = require('json')
local state = reqscript('internal/claude-bridge/state')

ERR_BAD_REQUEST = 'BAD_REQUEST'
ERR_NOT_ALLOWED = 'NOT_ALLOWED'
ERR_NO_WORLD = 'NO_WORLD'
ERR_NO_MAP = 'NO_MAP'
ERR_NOT_FOUND = 'NOT_FOUND'
ERR_INTERNAL = 'INTERNAL'

local ops = {}

function reset()
    ops = {}
end

-- spec: {namespace=string, handler=function(args), needs_world=bool, needs_map=bool}
function register(name, spec)
    ops[name] = spec
end

function register_many(specs)
    for name, spec in pairs(specs) do
        register(name, spec)
    end
end

function list_ops()
    local names = {}
    for name, spec in pairs(ops) do
        table.insert(names, {op = name, namespace = spec.namespace})
    end
    table.sort(names, function(a, b) return a.op < b.op end)
    return names
end

-- Handlers return this to report a domain error instead of a result.
function error_result(code, message)
    return {__error = true, code = code, message = message}
end

local function fail(code, message)
    return {ok = false, error = {code = code, message = message}}
end

function handle(request)
    if type(request) ~= 'table' or type(request.op) ~= 'string' then
        return fail(ERR_BAD_REQUEST, 'request must be an object with a string "op"')
    end
    local spec = ops[request.op]
    if not spec then
        return fail(ERR_NOT_FOUND, 'unknown op: ' .. request.op)
    end
    if not state.is_allowed(spec.namespace) then
        return fail(ERR_NOT_ALLOWED,
            ('the player has not allowed "%s" (op %s)'):format(spec.namespace, request.op))
    end
    if (spec.needs_world or spec.needs_map) and not dfhack.isWorldLoaded() then
        return fail(ERR_NO_WORLD, 'no world is loaded')
    end
    if spec.needs_map and not dfhack.isMapLoaded() then
        return fail(ERR_NO_MAP, 'no map is loaded')
    end
    local args = request.args
    if args == nil then
        args = {}
    elseif type(args) ~= 'table' then
        return fail(ERR_BAD_REQUEST, '"args" must be an object')
    end
    local ok, result = pcall(spec.handler, args)
    if not ok then
        return fail(ERR_INTERNAL, tostring(result))
    end
    if type(result) == 'table' and result.__error then
        return fail(result.code or ERR_INTERNAL, result.message or 'unknown error')
    end
    return {ok = true, result = result}
end

-- DF strings are code page 437. Convert every string in a response to UTF-8 so names with
-- accented letters survive the trip to the JSON client.
local function to_utf8(value)
    local t = type(value)
    if t == 'string' then
        return dfhack.df2utf(value)
    elseif t == 'table' then
        local out = {}
        for k, v in pairs(value) do
            out[k] = to_utf8(v)
        end
        return out
    end
    return value
end

function dispatch(request_json)
    local ok, request = pcall(json.decode, request_json)
    local response
    if not ok then
        response = fail(ERR_BAD_REQUEST, 'invalid JSON: ' .. tostring(request))
    else
        response = handle(request)
        if type(request) == 'table' and request.id ~= nil then
            response.id = request.id
        end
    end
    local encoded_ok, encoded = pcall(function() return json.encode(to_utf8(response)) end)
    if not encoded_ok then
        return json.encode(fail(ERR_INTERNAL, 'could not encode response: ' .. tostring(encoded)))
    end
    return encoded
end
