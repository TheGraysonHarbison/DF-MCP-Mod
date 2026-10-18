-- Constructions (plan section 12, item 7.1): walls, floors, ramps, stairs, and
-- fortifications one building per tile over a box, circle, or line; bridges, roads, and
-- supports as single buildings. Tile rules follow DFHack's quickfort build module
-- (internal/quickfort/build.lua, checked 2026-10-14): a construction goes on open air,
-- floor, boulders, pebbles, ramp tops, brook tops, twigs, saplings, shrubs, or a ramp; not
-- on hidden tiles, buildings, deep water, or magma. Vanilla allows building over a
-- constructed floor; a construction of the same shape on top of an existing one is skipped.
-- Support is not enforced, only reported, as quickfort does.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local map = reqscript('internal/claude-bridge/map')
local dig = reqscript('internal/claude-bridge/dig')
local build = reqscript('internal/claude-bridge/build')
local materials = reqscript('internal/claude-bridge/materials')

local B = dfhack.buildings
local M = dfhack.maps

KINDS = {'wall', 'floor', 'ramp', 'stairs', 'fortification', 'bridge', 'paved_road', 'dirt_road',
         'support'}
TILE_KINDS = {wall = 'Wall', floor = 'Floor', ramp = 'Ramp', stairs = 'UpDownStair',
              fortification = 'Fortification'}
-- Shape the finished construction has, for the same-shape skip.
RESULT_SHAPES = {wall = 'WALL', floor = 'FLOOR', ramp = 'RAMP', fortification = 'FORTIFICATION'}
BUILDING_KINDS = {bridge = 'Bridge', paved_road = 'RoadPaved', dirt_road = 'RoadDirt',
                  support = 'Support'}
DIRECTIONS = {retracting = 'Retracting', raise_north = 'Up', raise_south = 'Down',
              raise_east = 'Right', raise_west = 'Left'}
-- The game's own limit for one bridge or road, not ours: DFHack's buildingplan mirrors the
-- vanilla build-area clamp of 31 by 31 for Bridge, FarmPlot, RoadPaved, and RoadDirt
-- (hack/lua/plugins/buildingplan/planneroverlay.lua get_selection_size_limits, "clamp to
-- building type area limit"), and quickfort defaults extent buildings to 1-31
-- (hack/scripts/internal/quickfort/build.lua), both checked on DFHack 53.16-r2 2026-10-17.
-- Bigger spans are built as several buildings side by side.
MAX_BUILDING_SIDE = 31
LIST_LIMIT = 25

local SPACE_SHAPES = {EMPTY = true, FLOOR = true, BOULDER = true, PEBBLES = true, RAMP_TOP = true,
                      BROOK_TOP = true, TWIG = true, SAPLING = true, SHRUB = true}
local DIRT_MATERIALS = {SOIL = true, GRASS_LIGHT = true, GRASS_DARK = true, GRASS_DRY = true,
                        GRASS_DEAD = true, PLANT = true}

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

function facts(pos)
    local tt = M.getTileType(pos)
    local des, occ = M.getTileFlags(pos)
    if not tt or not des then return nil end
    local attrs = safe(function() return df.tiletype.attrs[tt] end)
    local shape_attrs = attrs and safe(function() return df.tiletype_shape.attrs[attrs.shape] end)
    return {
        des = des, occ = occ,
        shape = attrs and enum_name(df.tiletype_shape, attrs.shape) or nil,
        basic = shape_attrs and enum_name(df.tiletype_shape_basic, shape_attrs.basic_shape) or nil,
        material = attrs and enum_name(df.tiletype_material, attrs.material) or nil,
    }
end

function is_edge(pos)
    local w, h = M.getTileSize()
    return pos.x == 0 or pos.y == 0 or pos.x == w - 1 or pos.y == h - 1
end

-- quickfort is_valid_tile_base: revealed, no building, no deep water, no magma.
function base_problem(f)
    if f.des.hidden then return 'hidden (not yet revealed)' end
    if f.occ.building ~= 0 then
        return 'building (' .. (enum_name(df.tile_building_occ, f.occ.building) or '?'):lower() .. ')'
    end
    local flow = f.des.flow_size or 0
    local magma = f.des.liquid_type == true or f.des.liquid_type == df.tile_liquid.Magma
    if magma and flow >= 1 then return 'magma' end
    if flow > 1 then return ('water depth %d'):format(flow) end
    return nil
end

-- Whether a tile has something to hold a construction up: its own floor, a non-open
-- neighbour on the same level, or solid rock below.
local function supported(pos, f)
    if f.basic ~= 'Open' and f.shape ~= 'RAMP_TOP' and f.shape ~= 'BROOK_TOP' then return true end
    for dy = -1, 1 do
        for dx = -1, 1 do
            if dx ~= 0 or dy ~= 0 then
                local n = facts({x = pos.x + dx, y = pos.y + dy, z = pos.z})
                if n and n.basic ~= 'Open' and n.shape ~= 'RAMP_TOP' and n.shape ~= 'BROOK_TOP' then
                    return true
                end
            end
        end
    end
    local below = pos.z > 0 and facts({x = pos.x, y = pos.y, z = pos.z - 1}) or nil
    return below ~= nil and below.basic == 'Wall'
end

-- The construction subtype a tile takes for a per-tile kind, or nil, bucket, reason.
-- `level` is 'top', 'middle', 'bottom', or 'single' for stairs.
local function subtype_for(kind, f, level)
    local C = df.construction_type
    if kind == 'stairs' then
        if f.shape == 'STAIR_UPDOWN' then return nil, 'skipped_existing', 'already an up/down stair' end
        if level == 'bottom' or level == 'single' then
            if f.shape == 'STAIR_DOWN' then return C.UpDownStair end
            if f.shape == 'STAIR_UP' then return nil, 'skipped_existing', 'already an up stair' end
        elseif level == 'top' then
            if f.shape == 'STAIR_UP' then return C.UpDownStair end
            if f.shape == 'STAIR_DOWN' then return nil, 'skipped_existing', 'already a down stair' end
        else
            if f.shape == 'STAIR_UP' or f.shape == 'STAIR_DOWN' then return C.UpDownStair end
        end
    end
    if not (SPACE_SHAPES[f.shape or ''] or f.shape == 'RAMP') then
        return nil, 'skipped_unsuitable', ('%s, not open space or floor'):format(
            (f.shape or f.basic or 'unknown'):lower())
    end
    if f.material == 'CONSTRUCTION' and RESULT_SHAPES[kind] == f.shape then
        return nil, 'skipped_existing', 'already a constructed ' .. kind
    end
    if kind == 'stairs' then
        if level == 'top' then return C.DownStair end
        if level == 'bottom' then return C.UpStair end
        return C.UpDownStair
    end
    return C[TILE_KINDS[kind]]
end

-- Tiles of a shape on one level, as {x, y} pairs. Boxes and circles may be hollow; lines
-- are Bresenham, thickened at every diagonal step unless `thick` is false.
local function box_tiles(box, hollow)
    local out = {}
    for y = box.y1, box.y2 do
        for x = box.x1, box.x2 do
            if not hollow or x == box.x1 or x == box.x2 or y == box.y1 or y == box.y2 then
                table.insert(out, {x = x, y = y})
            end
        end
    end
    return out
end

local function circle_tiles(box, inside, hollow)
    local out = {}
    for y = box.y1, box.y2 do
        for x = box.x1, box.x2 do
            if inside(x, y) then
                local ring = not hollow or not (inside(x + 1, y) and inside(x - 1, y)
                    and inside(x, y + 1) and inside(x, y - 1))
                if ring then table.insert(out, {x = x, y = y}) end
            end
        end
    end
    return out
end

local function line_tiles(x1, y1, x2, y2, thick)
    local out, seen = {}, {}
    local function add(x, y)
        local key = x .. ',' .. y
        if not seen[key] then
            seen[key] = true
            table.insert(out, {x = x, y = y})
        end
    end
    local dx, dy = math.abs(x2 - x1), -math.abs(y2 - y1)
    local sx, sy = x1 < x2 and 1 or -1, y1 < y2 and 1 or -1
    local err = dx + dy
    local x, y = x1, y1
    while true do
        add(x, y)
        if x == x2 and y == y2 then break end
        local e2 = 2 * err
        local moved_x, moved_y = false, false
        if e2 >= dy then err = err + dy; x = x + sx; moved_x = true end
        if e2 <= dx then err = err + dx; y = y + sy; moved_y = true end
        if thick and moved_x and moved_y then add(x - sx, y) end
    end
    return out
end

local function parse_line(args)
    local l = args.line
    if type(l) ~= 'table' then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"line" must be {x1, y1, x2, y2, z}')
    end
    local box, err = map.parse_box({x1 = l.x1, y1 = l.y1, z1 = l.z, x2 = l.x2, y2 = l.y2, z2 = l.z})
    if err then return nil, err end
    box.line = {x1 = math.floor(tonumber(l.x1)), y1 = math.floor(tonumber(l.y1)),
                x2 = math.floor(tonumber(l.x2)), y2 = math.floor(tonumber(l.y2))}
    return box
end

local function parse_kind(args)
    local kind = args.kind ~= nil and tostring(args.kind):lower() or nil
    for _, k in ipairs(KINDS) do if k == kind then return kind end end
    return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be one of ' .. table.concat(KINDS, ', '))
end

local function list_limit(list) return #list < LIST_LIMIT end

-- Material filter for a construction kind: the game's default slot plus the spec.
function filters_for(btype, subtype, spec)
    local filter_args = {}
    if spec then filter_args.material = materials.job_item_fields(spec) end
    return safe(B.getFiltersByType, filter_args, btype, subtype, -1)
end

local function materials_summary(btype, subtype, spec, needed)
    local filters = filters_for(btype, subtype, spec)
    if not filters or #filters == 0 then
        return {needed = needed, available = nil, filter = spec and spec.label or 'any building material'}
    end
    local available = build.count_suitable(filters[1], spec)
    build.free_filters(filters)
    return {needed = needed, available = available,
            filter = spec and spec.label or 'any building material (closest first)'}
end

-- Per-tile kinds: walls, floors, ramps, stairs, fortifications.
local function run_tiles(args, kind, apply)
    local box, berr, inside, shape_name
    if args.circle ~= nil then
        box, berr, inside = dig.parse_circle(args)
        shape_name = 'circle'
    elseif args.line ~= nil then
        box, berr = parse_line(args)
        shape_name = 'line'
    else
        box, berr = map.parse_box(args)
        shape_name = 'box'
    end
    if berr then return berr end
    local hollow = args.hollow == true
    local thick = args.thick ~= false
    local levels = box.z2 - box.z1 + 1
    if kind == 'stairs' then
        if shape_name ~= 'box' then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                'stairs take a box; a 1 by 1 box across levels makes a stairwell')
        end
        if levels < 2 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                'a stairwell box must span at least two z-levels (z1 and z2 differ)')
        end
    end
    local spec, why = materials.resolve(args.material)
    if why then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end

    local tiles
    if shape_name == 'circle' then
        tiles = circle_tiles(box, inside, hollow)
    elseif shape_name == 'line' then
        -- A line reaching past the map edge keeps only its tiles inside the clipped box.
        tiles = {}
        for _, t in ipairs(line_tiles(box.line.x1, box.line.y1, box.line.x2, box.line.y2, thick)) do
            if t.x >= box.x1 and t.x <= box.x2 and t.y >= box.y1 and t.y <= box.y2 then
                table.insert(tiles, t)
            end
        end
    else
        tiles = box_tiles(box, hollow)
    end

    local counts = {placed = 0, skipped_existing = 0, skipped_unsuitable = 0,
                    skipped_building = 0, skipped_edge = 0, unsupported = 0}
    local skipped, unsupported, targets, by_level = {}, {}, {}, {}
    local function skip(pos, bucket, reason)
        counts[bucket] = counts[bucket] + 1
        if list_limit(skipped) then table.insert(skipped, {pos = pos, reason = reason}) end
    end
    for z = box.z2, box.z1, -1 do
        local level = 'middle'
        if kind == 'stairs' then
            if z == box.z2 then level = 'top' elseif z == box.z1 then level = 'bottom' end
        end
        local level_count = {z = z, placed = 0, skipped = 0}
        for _, t in ipairs(tiles) do
            local pos = {x = t.x, y = t.y, z = z}
            local f = facts(pos)
            if not f then
                skip(pos, 'skipped_unsuitable', 'no map block')
            elseif is_edge(pos) then
                skip(pos, 'skipped_edge', 'map edge')
            else
                local problem = base_problem(f)
                if problem then
                    skip(pos, problem:find('^building') and 'skipped_building' or 'skipped_unsuitable', problem)
                else
                    local subtype, bucket, reason = subtype_for(kind, f, level)
                    if not subtype then
                        skip(pos, bucket, reason)
                    else
                        if not supported(pos, f) then
                            counts.unsupported = counts.unsupported + 1
                            if list_limit(unsupported) then table.insert(unsupported, pos) end
                        end
                        table.insert(targets, {pos = pos, subtype = subtype})
                        level_count.placed = level_count.placed + 1
                    end
                end
            end
        end
        level_count.skipped = #tiles - level_count.placed
        table.insert(by_level, level_count)
    end

    local btype = df.building_type.Construction
    local summary = materials_summary(btype, targets[1] and targets[1].subtype
        or df.construction_type[TILE_KINDS[kind]], spec, #targets)
    local result = {
        kind = kind, shape = shape_name, box = box, hollow = hollow or nil,
        thick = shape_name == 'line' and thick or nil,
        dry_run = not apply, applied = false,
        placed = 0, skipped_existing = counts.skipped_existing,
        skipped_unsuitable = counts.skipped_unsuitable, skipped_building = counts.skipped_building,
        skipped_edge = counts.skipped_edge, unsupported = counts.unsupported,
        unsupported_tiles = unsupported, skipped = skipped,
        skipped_truncated = (counts.skipped_existing + counts.skipped_unsuitable
            + counts.skipped_building + counts.skipped_edge) > #skipped,
        by_level = by_level, materials = summary, buildings = {}, warnings = {},
    }
    if counts.unsupported > 0 then
        table.insert(result.warnings, ('%d tile(s) have no floor, wall, or construction beside or '
            .. 'below them; they are placed anyway and may need a support or a build order first')
            :format(counts.unsupported))
    end
    if #targets == 0 then
        result.status = 'nothing_to_place'
        result.note = 'no tile in the shape can take this construction'
        return result
    end
    if summary.available ~= nil and summary.available < summary.needed then
        result.status = 'no_materials'
        result.note = ('%d tiles need %d building material(s); %d available for "%s"; nothing placed')
            :format(#targets, summary.needed, summary.available, summary.filter)
        return result
    end
    result.status = apply and 'placed' or 'plan'
    if not apply then
        result.placed = #targets
        result.note = 'nothing was changed; call build.construct with the same arguments to place these'
        return result
    end
    for _, t in ipairs(targets) do
        local filters = filters_for(btype, t.subtype, spec)
        local bld, err = B.constructBuilding{type = btype, subtype = t.subtype, pos = t.pos,
                                             filters = filters}
        if bld then
            result.placed = result.placed + 1
            if list_limit(result.buildings) then table.insert(result.buildings, bld.id) end
        else
            build.free_filters(filters)
            skip(t.pos, 'skipped_unsuitable', 'placement failed: ' .. tostring(err))
            result.skipped_unsuitable = counts.skipped_unsuitable
        end
    end
    result.applied = result.placed > 0
    result.buildings_truncated = result.placed > #result.buildings
    result.note = 'blueprints placed; dwarves fetch the closest matching material and build them'
    return result
end

-- Single buildings: bridges, roads, supports.
local function run_building(args, kind, apply)
    local box, berr = map.parse_box(args)
    if berr then return berr end
    if box.z1 ~= box.z2 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, kind .. ' takes a box on one level (z1 equal to z2)')
    end
    local w, h = box.x2 - box.x1 + 1, box.y2 - box.y1 + 1
    if kind == 'support' and (w ~= 1 or h ~= 1) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'a support is one tile (x1 equal to x2, y1 equal to y2)')
    end
    if w > MAX_BUILDING_SIDE or h > MAX_BUILDING_SIDE then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('the game builds a %s at most %d by %d tiles; place several side by side'):format(
                kind, MAX_BUILDING_SIDE, MAX_BUILDING_SIDE))
    end
    local direction = nil
    if kind == 'bridge' then
        local word = args.direction ~= nil and tostring(args.direction):lower() or nil
        if not word or not DIRECTIONS[word] then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"direction" is required for a bridge: retracting, raise_north, raise_south, raise_east, raise_west')
        end
        direction = DIRECTIONS[word]
    end
    local spec, why = materials.resolve(args.material)
    if why then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
    local btype = df.building_type[BUILDING_KINDS[kind]]

    local good, skipped, counts = {}, {}, {skipped_unsuitable = 0, skipped_building = 0, skipped_edge = 0}
    local function skip(pos, bucket, reason)
        counts[bucket] = counts[bucket] + 1
        if list_limit(skipped) then table.insert(skipped, {pos = pos, reason = reason}) end
    end
    local z = box.z1
    for y = box.y1, box.y2 do
        for x = box.x1, box.x2 do
            local pos = {x = x, y = y, z = z}
            local f = facts(pos)
            local problem = nil
            if not f then
                problem = 'no map block'
            elseif is_edge(pos) then
                problem = 'map edge'
            else
                problem = base_problem(f)
                if not problem then
                    local anchor = kind == 'bridge' and (
                        (direction == 'Up' and y == box.y1) or (direction == 'Down' and y == box.y2)
                        or (direction == 'Left' and x == box.x1) or (direction == 'Right' and x == box.x2))
                    local shape = f.shape or ''
                    if kind == 'dirt_road' then
                        if not DIRT_MATERIALS[f.material or ''] or not SPACE_SHAPES[shape]
                            or shape == 'BOULDER' or shape == 'PEBBLES' or shape == 'EMPTY' then
                            problem = 'not soil or grass floor'
                        end
                    elseif anchor then
                        if not SPACE_SHAPES[shape] then problem = 'bridge anchor edge cannot sit on a ' .. shape:lower() end
                    elseif kind == 'bridge' then
                        if not (SPACE_SHAPES[shape] or shape == 'RAMP' or f.basic == 'Stair') then
                            problem = shape:lower() .. ', not open space, floor, ramp, or stair'
                        end
                    else
                        if not (SPACE_SHAPES[shape] or shape == 'RAMP') then
                            problem = shape:lower() .. ', not open space or floor'
                        end
                    end
                end
            end
            if problem then
                local bucket = problem == 'map edge' and 'skipped_edge'
                    or (problem:find('^building') and 'skipped_building') or 'skipped_unsuitable'
                skip(pos, bucket, problem)
            else
                table.insert(good, pos)
            end
        end
    end
    local total = w * h
    local result = {kind = kind, shape = 'box', box = box, width = w, height = h, direction = args.direction,
                    dry_run = not apply, applied = false, tiles = #good,
                    skipped_unsuitable = counts.skipped_unsuitable,
                    skipped_building = counts.skipped_building, skipped_edge = counts.skipped_edge,
                    skipped = skipped, warnings = {}}
    if #good == 0 or ((kind == 'bridge' or kind == 'support') and #good < total) then
        result.status = 'invalid_space'
        result.blocked_at = skipped[1] and skipped[1].pos or nil
        result.reason = skipped[1] and skipped[1].reason or 'no usable tile'
        return result
    end
    local needed = kind == 'dirt_road' and 0 or (kind == 'support' and 1 or math.floor(#good / 4) + 1)
    result.materials = kind == 'dirt_road' and {needed = 0, available = nil, filter = 'none'}
        or materials_summary(btype, -1, spec, needed)
    if kind == 'bridge' then
        result.has_support = safe(B.hasSupport, {x = box.x1, y = box.y1, z = z}, {x = w, y = h})
        if result.has_support == false then
            table.insert(result.warnings, 'no terrain support under the bridge; a retracting bridge there '
                .. 'collapses when retracted')
        end
    end
    local m = result.materials
    if m.available ~= nil and m.available < m.needed then
        result.status = 'no_materials'
        result.note = ('needs %d building material(s), %d available for "%s"; nothing placed')
            :format(m.needed, m.available, m.filter)
        return result
    end
    if not apply then
        result.status = 'plan'
        result.note = 'nothing was changed; call build.construct with the same arguments to place it'
        return result
    end
    local fields = nil
    if #good < total then
        local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', total))
        local ok_tiles = {}
        for _, p in ipairs(good) do ok_tiles[p.x .. ',' .. p.y] = true end
        for i = 0, total - 1 do
            local ex, ey = box.x1 + i % w, box.y1 + math.floor(i / w)
            extents[i] = ok_tiles[ex .. ',' .. ey] and 1 or 0
        end
        fields = {room = {x = box.x1, y = box.y1, width = w, height = h, extents = extents}}
    end
    local call = {type = btype, pos = {x = box.x1, y = box.y1, z = z}, width = w, height = h,
                  fields = fields}
    if direction then call.direction = df.building_bridgest.T_direction[direction] end
    if kind == 'dirt_road' then
        call.filters = {}
    else
        call.filters = filters_for(btype, -1, spec)
    end
    local bld, err = B.constructBuilding(call)
    if not bld then
        if call.filters then build.free_filters(call.filters) end
        result.status = 'invalid_space'
        result.reason = tostring(err)
        return result
    end
    result.status = 'placed'
    result.applied = true
    result.building = {id = bld.id, kind = enum_name(df.building_type, bld:getType()),
                       bounds = {x1 = bld.x1, y1 = bld.y1, x2 = bld.x2, y2 = bld.y2, z = bld.z},
                       material_amount = safe(function() return bld.material_amount end)}
    result.note = 'blueprint placed; dwarves fetch the closest matching material and build it'
    return result
end

local function run(args, apply)
    local kind, err = parse_kind(args)
    if err then return err end
    if BUILDING_KINDS[kind] then return run_building(args, kind, apply) end
    return run_tiles(args, kind, apply)
end

local function plan(args) return run(args, false) end
local function construct(args) return run(args, true) end

function ops()
    return {
        ['build.plan_construction'] = {namespace = 'workshops', handler = plan, needs_map = true},
        ['build.construct'] = {namespace = 'build_write', handler = construct, needs_map = true},
    }
end
