-- Built workshops and furnaces: list, filter by type, and inspect one. Read-only.
-- Plan section 10, item 4.1.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

DEFAULT_LIMIT = 25

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function enum_name(enum, value)
    local name = safe(function() return enum[value] end)
    if type(name) == 'string' then return name end
    return nil
end

local function true_flags(bitfield)
    local out = {}
    pcall(function()
        for name, value in pairs(bitfield) do
            if value == true then table.insert(out, name) end
        end
    end)
    table.sort(out)
    return out
end

-- kind ('workshop' or 'furnace'), type token, and display name for a building.
local function kind_of(b)
    local kind, token, name
    if df.building_workshopst:is_instance(b) then
        kind = 'workshop'
        token = enum_name(df.workshop_type, b.type)
    elseif df.building_furnacest:is_instance(b) then
        kind = 'furnace'
        token = enum_name(df.furnace_type, b.type)
    else
        return nil
    end
    name = token
    if token == 'Custom' then
        local def = safe(function() return df.global.world.raws.buildings.all[b.custom_type] end)
        if def then
            token = safe(function() return def.code end) or token
            name = safe(function() return def.name end) or token
        end
    end
    return kind, token, name
end

local function is_mood_job(job)
    return safe(function()
        return df.job_type_class[df.job_type.attrs[job.job_type].type] == 'StrangeMood'
    end) == true
end

local function job_row(job)
    local worker = safe(dfhack.job.getWorker, job)
    return {
        id = job.id,
        name = safe(dfhack.job.getName, job),
        job = enum_name(df.job_type, job.job_type),
        order_id = safe(function() return job.order_id >= 0 and job.order_id or nil end),
        flags = true_flags(job.flags),
        worker = worker and {id = worker.id, name = safe(dfhack.units.getReadableName, worker)}
            or nil,
        strange_mood = is_mood_job(job),
    }
end

local function profile(b)
    return safe(function()
        local p = b.profile
        local workers = {}
        for _, id in ipairs(p.permitted_workers) do
            local unit = df.unit.find(id)
            table.insert(workers, {id = id,
                name = unit and safe(dfhack.units.getReadableName, unit) or nil})
        end
        return {
            permitted_workers = workers,
            min_level = p.min_level,
            max_level = p.max_level,
            flags = true_flags(p.flags),
        }
    end)
end

local function summary(b)
    local kind, token, name = kind_of(b)
    if not kind then return nil end
    local jobs, mood = 0, false
    pcall(function()
        for _, job in ipairs(b.jobs) do
            jobs = jobs + 1
            if is_mood_job(job) then mood = true end
        end
    end)
    local stage, max_stage = safe(function() return b:getBuildStage() end),
                             safe(function() return b:getMaxBuildStage() end)
    return {
        id = b.id,
        kind = kind,
        type = token,
        name = name,
        custom_name = safe(function() return b.name ~= '' and b.name or nil end),
        pos = {x = b.centerx, y = b.centery, z = b.z},
        bounds = {x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z},
        built = stage ~= nil and max_stage ~= nil and stage >= max_stage,
        jobs = jobs,
        strange_mood = mood,
        items = safe(function() return #b.contained_items end) or 0,
    }
end

local function each_workshop(fn)
    local other = df.global.world.buildings.other
    for _, key in ipairs({'WORKSHOP_ANY', 'FURNACE_ANY'}) do
        local vec = safe(function() return other[key] end)
        if vec then
            for _, b in ipairs(vec) do fn(b) end
        end
    end
end

local function type_matches(row, wanted)
    if wanted == nil then return true end
    local w = wanted:lower()
    return (row.type and row.type:lower() == w) or (row.name and row.name:lower() == w)
        or row.kind == w
end

local function parse_limit(args)
    if args.limit == nil then return DEFAULT_LIMIT end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

local function known_types()
    local out = {}
    for i = 0, df.workshop_type._last_item do
        local t = df.workshop_type[i]
        if t and t ~= 'Custom' then table.insert(out, t) end
    end
    for i = 0, df.furnace_type._last_item do
        local t = df.furnace_type[i]
        if t and t ~= 'Custom' then table.insert(out, t) end
    end
    return out
end

local function list(args)
    local limit, err = parse_limit(args)
    if err then return err end
    local offset = tonumber(args.offset) or 0
    local wanted = args.type ~= nil and tostring(args.type) or nil
    local rows, total, counts = {}, 0, {}
    each_workshop(function(b)
        local row = summary(b)
        if row then
            counts[row.type] = (counts[row.type] or 0) + 1
            if type_matches(row, wanted) then
                total = total + 1
                if total > offset and #rows < limit then table.insert(rows, row) end
            end
        end
    end)
    table.sort(rows, function(a, c)
        if a.type ~= c.type then return a.type < c.type end
        return a.id < c.id
    end)
    local out = {total = total, count = #rows, offset = offset, limit = limit,
                 truncated = total > offset + #rows, workshops = rows, counts_by_type = counts}
    if wanted and total == 0 then
        out.note = ('no workshops of type "%s"; types on this map: %s; known types: %s'):format(
            wanted, next(counts) and table.concat((function()
                local keys = {}
                for k in pairs(counts) do table.insert(keys, k) end
                table.sort(keys)
                return keys
            end)(), ', ') or 'none', table.concat(known_types(), ', '))
    end
    return out
end

local function inventory(b, limit)
    local stored, materials = {}, {}
    pcall(function()
        for _, entry in ipairs(b.contained_items) do
            local item = entry.item
            local row = {
                id = item.id,
                description = safe(dfhack.items.getReadableDescription, item),
                quantity = safe(function() return item:getStackSize() end) or 1,
                flags = (function()
                    local f = {}
                    for _, name in ipairs({'forbid', 'dump', 'melt', 'in_job'}) do
                        if safe(function() return item.flags[name] end) then table.insert(f, name) end
                    end
                    return f
                end)(),
            }
            -- use_mode 0: an item sitting in the workshop; anything else (2): part of the
            -- building itself. Checked in-game 2026-10-12 against a carpenter's log.
            if entry.use_mode == 0 then
                table.insert(stored, row)
            else
                table.insert(materials, row)
            end
        end
    end)
    local function cap(list)
        local total = #list
        if total > limit then
            local kept = {}
            for i = 1, limit do kept[i] = list[i] end
            return {entries = kept, total = total, truncated = true}
        end
        return {entries = list, total = total, truncated = false}
    end
    return cap(stored), cap(materials)
end

local function get(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a building id') end
    local limit, err = parse_limit(args)
    if err then return err end
    local b = df.building.find(id)
    if not b then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    local row = summary(b)
    if not row then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a %s, not a workshop or furnace'):format(id,
                enum_name(df.building_type, b:getType()) or '?'))
    end
    local jobs = {}
    pcall(function()
        for _, job in ipairs(b.jobs) do table.insert(jobs, job_row(job)) end
    end)
    local stored, materials = inventory(b, limit)
    row.jobs = jobs
    row.inventory = stored
    row.materials = materials
    row.profile = profile(b)
    row.limit = limit
    row.truncated = (function()
        local t = {}
        if stored.truncated then table.insert(t, 'inventory') end
        if materials.truncated then table.insert(t, 'materials') end
        return t
    end)()
    return row
end

function ops()
    return {
        ['workshops.list'] = {namespace = 'workshops', handler = list, needs_map = true},
        ['workshops.get'] = {namespace = 'workshops', handler = get, needs_map = true},
    }
end
