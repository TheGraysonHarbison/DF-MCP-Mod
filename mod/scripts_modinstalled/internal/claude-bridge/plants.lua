-- Trees and shrubs: list them in a box, chop and gather designations (plan section 13,
-- item 10.2). One designation value serves digging, felling, and gathering
-- (tile_dig_designation.Default); the game decides by what is on the tile. Trees are marked
-- the way quickfort does (dfhack.designations.markPlant on the plant, which flags the base
-- trunk tile), shrubs by the same call on their tile. Saplings are neither chopped nor
-- gathered, and dead shrubs cannot be gathered.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')

local M = dfhack.maps

DEFAULT_LIMIT = 25
LIST_LIMIT = 25
MAX_RADIUS = 31
KINDS = {'tree', 'shrub', 'sapling'}

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

-- The undocumented dfhack.designations module (LuaApi.cpp, checked 2026-10-15) exists on
-- 53.16-r2; every use is guarded so a missing function reports instead of raising.
local function api()
    return safe(function() return dfhack.designations end)
end

function api_available()
    local d = api()
    return d ~= nil and type(d.markPlant) == 'function'
end

----------------------------------------------------------------------------------------------
-- rows

local function species(plant)
    return safe(function() return df.global.world.raws.plants.all[plant.material].name end)
end

local function shape_at(pos)
    local tt = M.getTileType(pos)
    local attrs = tt and safe(function() return df.tiletype.attrs[tt] end)
    return attrs and enum_name(df.tiletype_shape, attrs.shape) or nil
end

-- A tree species without a tree body is a sapling whatever its tile shape says.
local function kind_of(plant)
    local tree = safe(function() return plant.tree_info ~= nil end) == true
    if tree then return 'tree' end
    local tree_species = safe(function()
        return df.global.world.raws.plants.all[plant.material].flags.TREE
    end) == true
    if tree_species or shape_at(plant.pos) == 'SAPLING' then return 'sapling' end
    return 'shrub'
end

local function is_dead(plant)
    return safe(function() return plant.damage_flags.dead end) == true
end

local function designation_tile(plant)
    local d = api()
    if d and d.getPlantDesignationTile then
        local ok, x, y, z = pcall(d.getPlantDesignationTile, plant)
        if ok and x then return {x = x, y = y, z = z} end
    end
    return {x = plant.pos.x, y = plant.pos.y, z = plant.pos.z}
end

local function is_marked(plant)
    local d = api()
    if d and d.isPlantMarked then
        local marked = safe(d.isPlantMarked, plant)
        if marked ~= nil then return marked == true end
    end
    local pos = designation_tile(plant)
    local des = M.getTileFlags(pos)
    return des ~= nil and des.dig == df.tile_dig_designation.Default
end

local function row(plant)
    local kind = kind_of(plant)
    local out = {
        pos = {x = plant.pos.x, y = plant.pos.y, z = plant.pos.z},
        kind = kind,
        species = species(plant) or 'unknown plant',
        dead = is_dead(plant),
        marked = is_marked(plant),
    }
    if kind == 'tree' then
        out.size = safe(function()
            local t = plant.tree_info
            return {width = t.dim_x, depth = t.dim_y, height = t.body_height}
        end)
        out.designation_tile = designation_tile(plant)
    end
    return out
end

-- Plants whose base position is inside the box (and the circle when given).
local function plants_in(box, inside)
    local out = {}
    for _, plant in ipairs(df.global.world.plants.all) do
        local p = plant.pos
        if p.x >= box.x1 and p.x <= box.x2 and p.y >= box.y1 and p.y <= box.y2
                and p.z >= box.z1 and p.z <= box.z2 and (inside == nil or inside(p.x, p.y)) then
            table.insert(out, plant)
        end
    end
    return out
end

-- A filled circle {x, y, z, radius}, as dig.parse_circle (kept separate to avoid a module cycle).
local function parse_circle(args)
    local c = args.circle
    if type(c) ~= 'table' then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"circle" must be {x, y, z, radius}')
    end
    local cx, cy, cz, r = tonumber(c.x), tonumber(c.y), tonumber(c.z), tonumber(c.radius)
    if not (cx and cy and cz and r) then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"circle" needs numbers x, y, z, radius')
    end
    cx, cy, cz, r = math.floor(cx), math.floor(cy), math.floor(cz), math.floor(r)
    if r < 1 or r > MAX_RADIUS then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, ('"radius" must be 1-%d'):format(MAX_RADIUS))
    end
    local w, h, d = M.getTileSize()
    if cx - r < 0 or cy - r < 0 or cx + r >= w or cy + r >= h or cz < 0 or cz >= d then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('the circle reaches outside the map: x 0-%d, y 0-%d, z 0-%d'):format(w - 1, h - 1, d - 1))
    end
    local box = {x1 = cx - r, x2 = cx + r, y1 = cy - r, y2 = cy + r, z1 = cz, z2 = cz,
                 center = {x = cx, y = cy, z = cz}, radius = r}
    local limit = r * r + r
    return box, nil, function(x, y)
        local dx, dy = x - cx, y - cy
        return dx * dx + dy * dy <= limit
    end
end

local function list(args)
    local box, berr, inside
    if args.circle ~= nil then
        box, berr, inside = parse_circle(args)
    else
        box, berr = map.parse_box(args)
    end
    if berr then return berr end
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    if limit < 1 then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be positive') end
    local wanted = args.kind ~= nil and tostring(args.kind):lower() or nil
    if wanted ~= nil then
        local known = false
        for _, k in ipairs(KINDS) do if k == wanted then known = true end end
        if not known then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be one of ' .. table.concat(KINDS, ', '))
        end
    end
    local needle = args.query ~= nil and tostring(args.query):lower() or nil
    local marked_only = args.marked_only == true
    local rows, total, counts, by_species = {}, 0, {}, {}
    for _, plant in ipairs(plants_in(box, inside)) do
        local r = row(plant)
        if (wanted == nil or r.kind == wanted)
                and (needle == nil or r.species:lower():find(needle, 1, true))
                and (not marked_only or r.marked) then
            total = total + 1
            counts[r.kind] = (counts[r.kind] or 0) + 1
            by_species[r.species] = (by_species[r.species] or 0) + 1
            if #rows < limit then table.insert(rows, r) end
        end
    end
    return {
        box = box, shape = inside and 'circle' or 'box', total = total, count = #rows,
        truncated = total > #rows, counts = counts, species = by_species, plants = rows,
        note = 'positions are each plant\'s base tile; chop and gather orders go through '
            .. 'designate_dig with kind chop or gather',
    }
end

----------------------------------------------------------------------------------------------
-- designate and erase (called from dig.lua with the parsed box)

local function mark(plant)
    local d = api()
    if d and d.markPlant then
        local ok, result = pcall(d.markPlant, plant)
        if ok and result then return true end
        if ok then return false, 'the game refused to mark it' end
        return false, tostring(result)
    end
    -- Fallback without the designations module: flag the base tile directly.
    local pos = designation_tile(plant)
    local des = M.getTileFlags(pos)
    if not des then return false, 'no map block' end
    des.dig = df.tile_dig_designation.Default
    local block = M.getTileBlock(pos)
    if block then block.flags.designated = true end
    return true
end

local function unmark(plant)
    local d = api()
    if d and d.unmarkPlant then
        local ok, result = pcall(d.unmarkPlant, plant)
        return ok and result == true
    end
    local pos = designation_tile(plant)
    local des = M.getTileFlags(pos)
    if not des then return false end
    des.dig = df.tile_dig_designation.No
    local jobs = map.designation_jobs()
    local job = jobs[pos.x .. ',' .. pos.y .. ',' .. pos.z]
    if job then
        local j = safe(df.job.find, job.id)
        if j then pcall(dfhack.job.removeJob, j) end
    end
    return true
end

-- kind is 'chop' (trees) or 'gather' (shrubs). Shape of the result follows dig.designate.
function designate(box, inside, kind, apply)
    local want = kind == 'chop' and 'tree' or 'shrub'
    local counts = {designated = 0, skipped_existing = 0, skipped_unsuitable = 0}
    local skipped, marked = {}, {}
    local function skip(plant, bucket, reason)
        counts[bucket] = counts[bucket] + 1
        if #skipped < LIST_LIMIT then
            table.insert(skipped, {pos = {x = plant.pos.x, y = plant.pos.y, z = plant.pos.z},
                                   species = species(plant), reason = reason})
        end
    end
    local blocks = {}
    for _, plant in ipairs(plants_in(box, inside)) do
        local k = kind_of(plant)
        if k ~= want then
            -- Other plant kinds in the box are simply not candidates; saplings are reported.
            if k == 'sapling' then skip(plant, 'skipped_unsuitable', 'sapling (too young)') end
        elseif kind == 'gather' and is_dead(plant) then
            skip(plant, 'skipped_unsuitable', 'dead shrub')
        elseif is_marked(plant) then
            skip(plant, 'skipped_existing', 'already marked')
        else
            local d = api()
            local can = true
            if d and d.canMarkPlant then
                local ok, value = pcall(d.canMarkPlant, plant)
                if ok and value == false then can = false end
            end
            if not can then
                skip(plant, 'skipped_unsuitable', 'the game will not take an order on it (hidden or blocked)')
            else
                counts.designated = counts.designated + 1
                if #marked < LIST_LIMIT then
                    table.insert(marked, {pos = designation_tile(plant), species = species(plant), kind = k})
                end
                if apply then
                    local ok, why = mark(plant)
                    if not ok then
                        counts.designated = counts.designated - 1
                        skip(plant, 'skipped_unsuitable', why or 'marking failed')
                        table.remove(marked)
                    else
                        local block = M.getTileBlock(designation_tile(plant))
                        if block then blocks[tostring(block)] = true end
                    end
                end
            end
        end
    end
    if apply and counts.designated > 0 then pcall(dfhack.job.checkDesignationsNow) end
    local n = 0
    for _ in pairs(blocks) do n = n + 1 end
    return {
        kind = kind, box = box, shape = inside and 'circle' or 'box',
        applied = apply and counts.designated > 0, dry_run = not apply,
        designated = counts.designated, skipped_existing = counts.skipped_existing,
        skipped_unsuitable = counts.skipped_unsuitable, skipped_building = 0, skipped_edge = 0,
        by_level = {}, skipped = skipped,
        skipped_truncated = (counts.skipped_existing + counts.skipped_unsuitable) > #skipped,
        blocks_marked = n, plants = marked, designations_api = api_available(),
        note = apply and (kind == 'chop' and 'trees marked for felling; woodcutters take them when free'
                          or 'shrubs marked for gathering; herbalists take them when free')
            or 'nothing was changed; call dig.designate with the same arguments to place these orders',
    }
end

function erase(box, kind)
    local want = kind == 'chop' and 'tree' or 'shrub'
    local cleared = 0
    for _, plant in ipairs(plants_in(box, nil)) do
        if kind_of(plant) == want and is_marked(plant) and unmark(plant) then
            cleared = cleared + 1
        end
    end
    return cleared
end

function ops()
    return {
        ['map.plants'] = {namespace = 'map', handler = list, needs_map = true},
    }
end
