-- Dig designations: plan (read), designate (mine, stairs, channel, ramp, remove_stairs,
-- smooth, engrave), and erase, over a box of tiles. Plan section 11, items 6.2 to 6.4. Rules follow DFHack's
-- quickfort dig module (internal/quickfort/dig.lua, checked 2026-10-13): mining, up stairs,
-- and ramps need a wall or fortification that is not a construction; channels and down
-- stairs also take floors, ramps, and stairs; hidden tiles may be designated (that is how
-- exploratory mining works). An existing order or job on a tile is never overwritten.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')

local M = dfhack.maps

KINDS = {'mine', 'stairs', 'channel', 'ramp', 'remove_stairs', 'smooth', 'engrave'}
SMOOTH_KINDS = {smooth = 1, engrave = 2}
-- Tiletype materials that can be smoothed: natural hard rock and ice (quickfort's list).
HARD = {STONE = true, MINERAL = true, LAVA_STONE = true, FEATURE = true, FROZEN_LIQUID = true}
ERASE_KINDS = {'mine', 'up_stair', 'down_stair', 'up_down_stair', 'channel', 'ramp',
               'smooth', 'engrave'}
SKIPPED_LIMIT = 25
MAX_RADIUS = 31

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

local function tile_facts(pos)
    local tt = M.getTileType(pos)
    local des, occ = M.getTileFlags(pos)
    if not tt or not des then return nil end
    local attrs = safe(function() return df.tiletype.attrs[tt] end)
    local shape = attrs and enum_name(df.tiletype_shape, attrs.shape) or nil
    local shape_attrs = safe(function() return df.tiletype_shape.attrs[attrs.shape] end)
    return {
        tt = tt, des = des, occ = occ,
        shape = shape,
        basic = shape_attrs and enum_name(df.tiletype_shape_basic, shape_attrs.basic_shape) or nil,
        material = attrs and enum_name(df.tiletype_material, attrs.material) or nil,
        special = attrs and enum_name(df.tiletype_special, attrs.special) or nil,
    }
end

local function is_edge(pos)
    local w, h = M.getTileSize()
    return pos.x == 0 or pos.y == 0 or pos.x == w - 1 or pos.y == h - 1
end

local function is_construction(f) return f.material == 'CONSTRUCTION' end
local function is_tree(f)
    return f.material == 'TREE' or f.material == 'ROOT' or f.material == 'MUSHROOM'
        or f.shape == 'TRUNK_BRANCH' or f.shape == 'BRANCH' or f.shape == 'TWIG'
end
local function is_wall(f) return f.basic == 'Wall' or f.shape == 'FORTIFICATION' end
local function is_floor_like(f)
    return f.shape == 'FLOOR' or f.shape == 'BOULDER' or f.shape == 'PEBBLES'
end

local function has_engraving(pos)
    local found = false
    pcall(function()
        for _, e in ipairs(df.global.world.engravings) do
            if e.pos.x == pos.x and e.pos.y == pos.y and e.pos.z == pos.z then
                found = true
                return
            end
        end
    end)
    return found
end

-- The smooth value (1 smooth, 2 engrave) a tile can take, or nil, reason. Hidden tiles and
-- anything but natural hard rock walls and floors are refused, as in quickfort.
local function smooth_value_for(kind, f, pos)
    if f.des.hidden then return nil, 'hidden' end
    if is_construction(f) then return nil, 'construction' end
    if not HARD[f.material or ''] then
        return nil, 'not natural rock (' .. tostring(f.material):lower() .. ')'
    end
    if not (f.basic == 'Wall' or f.shape == 'FLOOR') then return nil, 'not a wall or floor' end
    if kind == 'smooth' then
        if f.special == 'SMOOTH' then return nil, 'already smooth' end
        return SMOOTH_KINDS.smooth
    end
    if f.special ~= 'SMOOTH' then return nil, 'not smooth yet (smooth it first)' end
    if has_engraving(pos) then return nil, 'already engraved' end
    return SMOOTH_KINDS.engrave
end

-- What dig value a tile of the given facts can take for a kind, or nil, reason. `level` is
-- 'top', 'middle', 'bottom', or 'single' for stairs.
local function dig_value_for(kind, f, level)
    local D = df.tile_dig_designation
    if f.des.hidden then
        if kind == 'remove_stairs' then return nil, 'hidden' end
        if kind == 'stairs' then
            if level == 'top' then return D.DownStair end
            if level == 'bottom' then return D.UpStair end
            return D.UpDownStair
        end
        if kind == 'mine' then return D.Default end
        if kind == 'channel' then return D.Channel end
        if kind == 'ramp' then return D.Ramp end
    end
    if is_construction(f) then return nil, 'construction' end
    if kind == 'mine' or kind == 'ramp' then
        if is_wall(f) and not is_tree(f) then
            return kind == 'mine' and D.Default or D.Ramp
        end
        return nil, is_tree(f) and 'tree' or 'not a wall'
    end
    if kind == 'channel' then
        if is_tree(f) then return nil, 'tree' end
        if is_wall(f) or is_floor_like(f) or f.basic == 'Ramp' or f.basic == 'Stair'
            or f.shape == 'SHRUB' or f.shape == 'SAPLING' then
            return D.Channel
        end
        return nil, 'open air or liquid'
    end
    if kind == 'remove_stairs' then
        if f.basic == 'Stair' or f.basic == 'Ramp' then return D.Default end
        return nil, 'not a stair or ramp'
    end
    if kind == 'stairs' then
        if is_tree(f) then return nil, 'tree' end
        local up_stair = f.shape == 'STAIR_UP'
        if level == 'top' then
            if up_stair then return D.UpDownStair end
            if is_wall(f) or is_floor_like(f) or f.shape == 'STAIR_DOWN' then return D.DownStair end
            return nil, 'needs a wall or floor for the down stair'
        elseif level == 'bottom' then
            if is_wall(f) then return D.UpStair end
            if f.shape == 'STAIR_DOWN' then return D.UpDownStair end
            return nil, 'needs solid rock for the up stair'
        else
            if is_wall(f) or is_floor_like(f) or up_stair or f.shape == 'STAIR_DOWN' then
                return D.UpDownStair
            end
            return nil, 'needs a wall or floor for an up/down stair'
        end
    end
    return nil, 'unknown kind'
end

local function parse_kind(args, valid)
    local kind = args.kind ~= nil and tostring(args.kind):lower() or nil
    if kind == nil then return nil end
    for _, k in ipairs(valid) do if k == kind then return kind end end
    return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be one of ' .. table.concat(valid, ', '))
end

-- A filled circle: {x, y, z, radius}. A tile is inside when dx*dx + dy*dy <= r*r + r
-- (plan 11.3). Returns the bounding box and a membership test, or nil, err.
function parse_circle(args)
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

-- Shared by dig.plan and dig.designate. apply=false only looks.
local function run_designate(args, apply)
    local kind, err = parse_kind(args, KINDS)
    if err then return err end
    if kind == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be one of ' .. table.concat(KINDS, ', '))
    end
    local box, berr, inside
    if args.circle ~= nil then
        if kind == 'stairs' then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                'staircases take a box, not a circle; a 1 by 1 box across levels makes a stair column')
        end
        box, berr, inside = parse_circle(args)
    else
        box, berr = map.parse_box(args)
    end
    if berr then return berr end
    local levels = box.z2 - box.z1 + 1
    if kind == 'stairs' and levels < 2 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'a staircase box must span at least two z-levels (z1 and z2 differ); '
            .. 'use kind "mine" for a single level')
    end
    local jobs = map.designation_jobs()
    local counts = {designated = 0, skipped_existing = 0, skipped_unsuitable = 0,
                    skipped_building = 0, skipped_edge = 0}
    local by_level, skipped, touched_blocks = {}, {}, {}
    local function skip(pos, bucket, reason)
        counts[bucket] = counts[bucket] + 1
        if #skipped < SKIPPED_LIMIT then
            table.insert(skipped, {pos = pos, reason = reason})
        end
    end
    for z = box.z2, box.z1, -1 do
        local level = 'middle'
        if kind == 'stairs' then
            if z == box.z2 then level = 'top' elseif z == box.z1 then level = 'bottom' end
        end
        local level_count = {z = z, designated = 0, skipped = 0, dig = nil}
        local outside = 0
        for y = box.y1, box.y2 do
            for x = box.x1, box.x2 do
                local pos = {x = x, y = y, z = z}
                local f = (inside == nil or inside(x, y)) and tile_facts(pos) or false
                if f == false then
                    outside = outside + 1
                elseif not f then
                    skip(pos, 'skipped_unsuitable', 'no map block')
                elseif is_edge(pos) then
                    skip(pos, 'skipped_edge', 'map edge')
                elseif map.designation_kind(f.des) or jobs[x .. ',' .. y .. ',' .. z] then
                    skip(pos, 'skipped_existing', 'already designated: '
                        .. (map.designation_kind(f.des) or jobs[x .. ',' .. y .. ',' .. z].kind))
                elseif f.occ.building ~= 0 then
                    skip(pos, 'skipped_building', 'building')
                else
                    local smoothing = SMOOTH_KINDS[kind] ~= nil
                    local value, why
                    if smoothing then
                        value, why = smooth_value_for(kind, f, pos)
                    else
                        value, why = dig_value_for(kind, f, level)
                    end
                    if value == nil then
                        skip(pos, 'skipped_unsuitable', why)
                    else
                        counts.designated = counts.designated + 1
                        level_count.designated = level_count.designated + 1
                        level_count.dig = smoothing and kind
                            or map.DIG_NAMES[enum_name(df.tile_dig_designation, value)]
                        if apply then
                            if smoothing then f.des.smooth = value else f.des.dig = value end
                            local block = M.getTileBlock(pos)
                            if block then
                                block.flags.designated = true
                                touched_blocks[tostring(block.map_pos.x) .. ',' .. block.map_pos.y
                                    .. ',' .. block.map_pos.z] = true
                            end
                        end
                    end
                end
            end
        end
        level_count.skipped = (box.x2 - box.x1 + 1) * (box.y2 - box.y1 + 1) - outside
            - level_count.designated
        table.insert(by_level, level_count)
    end
    if apply and counts.designated > 0 then
        pcall(dfhack.job.checkDesignationsNow)
    end
    local blocks = 0
    for _ in pairs(touched_blocks) do blocks = blocks + 1 end
    return {
        kind = kind, box = box, shape = inside and 'circle' or 'box',
        applied = apply and counts.designated > 0,
        dry_run = not apply,
        designated = counts.designated,
        skipped_existing = counts.skipped_existing,
        skipped_unsuitable = counts.skipped_unsuitable,
        skipped_building = counts.skipped_building,
        skipped_edge = counts.skipped_edge,
        by_level = by_level,
        skipped = skipped,
        skipped_truncated = (counts.skipped_existing + counts.skipped_unsuitable
            + counts.skipped_building + counts.skipped_edge) > #skipped,
        blocks_marked = blocks,
        note = apply and 'orders placed; miners take them when free; existing orders were left alone'
            or 'nothing was changed; call dig.designate with the same arguments to place these orders',
    }
end

local function plan(args) return run_designate(args, false) end
local function designate(args) return run_designate(args, true) end

local function erase(args)
    local kind, err = parse_kind(args, ERASE_KINDS)
    if err then return err end
    local box, berr = map.parse_box(args)
    if berr then return berr end
    local jobs = map.designation_jobs()
    local cleared, jobs_removed, counts = 0, 0, {}
    local touched = {}
    for z = box.z1, box.z2 do
        for y = box.y1, box.y2 do
            for x = box.x1, box.x2 do
                local pos = {x = x, y = y, z = z}
                local des = M.getTileFlags(pos)
                local key = x .. ',' .. y .. ',' .. z
                local flag_kind = des and map.designation_kind(des) or nil
                local job = jobs[key]
                local job_kind = job and job.kind or nil
                local this_kind = flag_kind or job_kind
                if this_kind and (kind == nil or this_kind == kind) then
                    if flag_kind then
                        des.dig = df.tile_dig_designation.No
                        des.smooth = 0
                        local _, occ = M.getTileFlags(pos)
                        if occ then pcall(function() occ.dig_marked = false end) end
                        local block = M.getTileBlock(pos)
                        if block then touched[tostring(block)] = block end
                    end
                    if job then
                        local j = safe(df.job.find, job.id)
                        if j then
                            local ok = pcall(dfhack.job.removeJob, j)
                            if ok then jobs_removed = jobs_removed + 1 end
                        end
                    end
                    cleared = cleared + 1
                    counts[this_kind] = (counts[this_kind] or 0) + 1
                end
            end
        end
    end
    return {box = box, kind = kind, cleared = cleared, jobs_removed = jobs_removed, counts = counts,
            note = 'tile orders cleared and their queued jobs cancelled; dug tiles are not refilled'}
end

function ops()
    return {
        ['dig.plan'] = {namespace = 'map', handler = plan, needs_map = true},
        ['dig.designate'] = {namespace = 'dig_write', handler = designate, needs_map = true},
        ['dig.erase'] = {namespace = 'dig_write', handler = erase, needs_map = true},
    }
end
