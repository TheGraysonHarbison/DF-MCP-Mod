-- Map reads: bounds, the wagon, one tile, an ASCII area map, and a free-space finder.
-- Read-only. Hidden (unrevealed) tiles are reported as hidden and nothing else, so Claude
-- sees what the player sees. Plan section 10, item 4.2.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

local M = dfhack.maps

DEFAULT_LIMIT = 25
MAX_AREA = 64

-- One character per tile in map.area. Order matters: the first match wins.
LEGEND = {
    ['?'] = 'hidden (not yet revealed)',
    ['B'] = 'building',
    ['~'] = 'water',
    ['%'] = 'magma',
    ['T'] = 'tree trunk or branches',
    ['#'] = 'wall (solid rock, soil, or construction)',
    ['^'] = 'ramp',
    ['<'] = 'stair up',
    ['>'] = 'stair down',
    ['X'] = 'stair up and down',
    ['.'] = 'floor (walkable)',
    [' '] = 'open air (no floor)',
    ['*'] = 'other (fortification, brook bed, ...)',
}

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

local function true_flags(bitfield, names)
    local out = {}
    for _, name in ipairs(names) do
        if safe(function() return bitfield[name] end) == true then table.insert(out, name) end
    end
    return out
end

----------------------------------------------------------------------------------------------
-- geometry helpers

local function tile_size()
    local x, y, z = M.getTileSize()
    return x, y, z
end

local function in_bounds(x, y, z)
    local w, h, d = tile_size()
    return x >= 0 and y >= 0 and z >= 0 and x < w and y < h and z < d
end

local function xyz(args, px, py, pz)
    local x, y, z = tonumber(args[px or 'x']), tonumber(args[py or 'y']), tonumber(args[pz or 'z'])
    if not x or not y or not z then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"x", "y", and "z" must be numbers')
    end
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if not in_bounds(x, y, z) then
        local w, h, d = tile_size()
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('(%d,%d,%d) is outside the map: x 0-%d, y 0-%d, z 0-%d'):format(
                x, y, z, w - 1, h - 1, d - 1))
    end
    return {x = x, y = y, z = z}
end

-- Shape and material facts for a tile type.
local function tile_shape(tt)
    local attrs = safe(function() return df.tiletype.attrs[tt] end)
    if not attrs then return nil end
    local shape = attrs.shape
    local shape_attrs = safe(function() return df.tiletype_shape.attrs[shape] end)
    return {
        tiletype = enum_name(df.tiletype, tt),
        caption = safe(function() return attrs.caption end),
        shape = enum_name(df.tiletype_shape, shape),
        basic_shape = shape_attrs and enum_name(df.tiletype_shape_basic, shape_attrs.basic_shape),
        material = enum_name(df.tiletype_material, attrs.material),
        special = (function()
            local s = enum_name(df.tiletype_special, attrs.special)
            return s ~= 'NONE' and s or nil
        end)(),
        walkable = shape_attrs and shape_attrs.walkable == true,
        passable_low = shape_attrs and shape_attrs.passable_low == true,
        passable_high = shape_attrs and shape_attrs.passable_high == true,
    }
end

local function designation_at(pos)
    local des, occ = M.getTileFlags(pos)
    return des, occ
end

-- The highest outdoor floor or ramp in a column, or nil.
function surface_z(x, y)
    local _, _, depth = tile_size()
    for z = depth - 1, 0, -1 do
        local tt = M.getTileType(x, y, z)
        if tt then
            local info = tile_shape(tt)
            local des = designation_at(xyz({x = x, y = y, z = z}))
            if info and (info.basic_shape == 'Floor' or info.basic_shape == 'Ramp')
                and des and des.outside and not des.hidden then
                return z
            end
        end
    end
    return nil
end

local function wagon_building()
    for _, b in ipairs(df.global.world.buildings.all) do
        if df.building_wagonst:is_instance(b) then return b end
    end
    return nil
end

----------------------------------------------------------------------------------------------
-- ops

local function bounds(args)
    local w, h, d = tile_size()
    local cx, cy = math.floor(w / 2), math.floor(h / 2)
    local wagon = wagon_building()
    return {
        x = {min = 0, max = w - 1},
        y = {min = 0, max = h - 1},
        z = {min = 0, max = d - 1},
        width = w, height = h, depth = d,
        center = {x = cx, y = cy},
        surface_z_at_center = surface_z(cx, cy),
        wagon_z = wagon and wagon.z or nil,
        note = 'z counts up; the surface is the highest outdoor floor in a column',
    }
end

local function wagon(args)
    local b = wagon_building()
    if not b then
        local w, h = tile_size()
        local cx, cy = math.floor(w / 2), math.floor(h / 2)
        return {present = false, center = {x = cx, y = cy, z = surface_z(cx, cy)},
                note = 'the wagon has been deconstructed; center is the map centre at surface level'}
    end
    return {
        present = true,
        id = b.id,
        pos = {x = b.centerx, y = b.centery, z = b.z},
        bounds = {x1 = b.x1, y1 = b.y1, x2 = b.x2, y2 = b.y2, z = b.z},
    }
end

local function items_at(pos, limit)
    local out, total = {}, 0
    pcall(function()
        local block = M.getTileBlock(pos)
        for _, id in ipairs(block.items) do
            local item = df.item.find(id)
            if item and item.pos.x == pos.x and item.pos.y == pos.y and item.pos.z == pos.z
                and safe(function() return item.flags.on_ground end) then
                total = total + 1
                if #out < limit then
                    table.insert(out, {id = item.id,
                        description = safe(dfhack.items.getReadableDescription, item),
                        quantity = safe(function() return item:getStackSize() end) or 1})
                end
            end
        end
    end)
    return {entries = out, total = total, truncated = total > #out}
end

local function units_at(pos)
    local out = {}
    pcall(function()
        for _, unit in ipairs(dfhack.units.getUnitsInBox(pos.x, pos.y, pos.z, pos.x, pos.y, pos.z)) do
            table.insert(out, {id = unit.id, name = safe(dfhack.units.getReadableName, unit)})
        end
    end)
    return out
end

function describe_tile(pos, limit)
    local out = {pos = pos}
    local tt = M.getTileType(pos)
    local des, occ = designation_at(pos)
    if not tt or not des then
        out.unknown = true
        out.note = 'no map block here'
        return out
    end
    if des.hidden then
        out.hidden = true
        out.note = 'not yet revealed; the player cannot see this tile either'
        return out
    end
    local info = tile_shape(tt)
    for k, v in pairs(info or {}) do out[k] = v end
    out.hidden = false
    out.outside = des.outside == true
    out.subterranean = des.subterranean == true
    out.light = des.light == true
    out.liquid = des.flow_size > 0 and {
        type = enum_name(df.tile_liquid, des.liquid_type) or tostring(des.liquid_type),
        depth = des.flow_size,
    } or nil
    out.designation = true_flags(des, {'smooth', 'pile'})
    out.dig = (function()
        local d = enum_name(df.tile_dig_designation, des.dig)
        return d ~= 'No' and d or nil
    end)()
    out.traffic = enum_name(df.tile_traffic, des.traffic)
    out.occupancy = {
        building = (function()
            local b = enum_name(df.tile_building_occ, occ.building)
            return b ~= 'None' and b or nil
        end)(),
        unit = occ.unit == true or occ.unit_grounded == true,
        item = occ.item == true,
    }
    local building = safe(dfhack.buildings.findAtTile, pos)
    if building then
        out.building = {id = building.id,
                        type = enum_name(df.building_type, building:getType()),
                        name = safe(function() return building.name ~= '' and building.name or nil end)}
    end
    local zones = safe(dfhack.buildings.findCivzonesAt, pos)
    if zones and #zones > 0 then
        out.zones = {}
        for _, zone in ipairs(zones) do
            table.insert(out.zones, {id = zone.id, type = enum_name(df.civzone_type, zone.type),
                name = safe(function() return zone.name ~= '' and zone.name or nil end)})
        end
    end
    local plant = safe(M.getPlantAtTile, pos)
    if plant then
        out.plant = {id = plant.id, tree = safe(function() return plant.tree_info ~= nil end) == true,
                     name = safe(function()
                         return df.global.world.raws.plants.all[plant.material].name
                     end)}
    end
    out.walkable_group = safe(M.getWalkableGroup, pos) or 0
    out.walkable = out.walkable_group ~= 0
    out.buildable = out.basic_shape == 'Floor' and out.walkable and building == nil
        and des.flow_size == 0 and plant == nil
    out.items = items_at(pos, limit)
    out.units = units_at(pos)
    return out
end

local function tile(args)
    local pos, err = xyz(args)
    if err then return err end
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    return describe_tile(pos, limit)
end

-- Character for one tile in the area map.
local function glyph(pos)
    local tt = M.getTileType(pos)
    local des, occ = designation_at(pos)
    if not tt or not des then return '?' end
    if des.hidden then return '?' end
    if occ.building ~= 0 then return 'B' end
    if des.flow_size > 0 then
        return des.liquid_type == df.tile_liquid.Magma and '%' or '~'
    end
    local info = tile_shape(tt)
    if not info then return '*' end
    local shape = info.shape or ''
    if shape == 'TRUNK_BRANCH' or shape == 'BRANCH' or shape == 'TWIG' then return 'T' end
    local basic = info.basic_shape
    if basic == 'Wall' then return '#' end
    if basic == 'Ramp' then return '^' end
    if basic == 'Stair' then
        if shape == 'STAIR_UP' then return '<' end
        if shape == 'STAIR_DOWN' then return '>' end
        return 'X'
    end
    if basic == 'Floor' then return '.' end
    if basic == 'Open' then return ' ' end
    return '*'
end

local function area(args)
    local pos, err = xyz(args)
    if err then return err end
    local w = math.floor(tonumber(args.width) or 32)
    local h = math.floor(tonumber(args.height) or 32)
    if w < 1 or h < 1 or w > MAX_AREA or h > MAX_AREA then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('"width" and "height" must be 1-%d'):format(MAX_AREA))
    end
    local mw, mh = tile_size()
    local x2 = math.min(pos.x + w - 1, mw - 1)
    local y2 = math.min(pos.y + h - 1, mh - 1)
    local rows, groups, counts = {}, {}, {}
    for y = pos.y, y2 do
        local chars = {}
        for x = pos.x, x2 do
            local p = {x = x, y = y, z = pos.z}
            local g = glyph(p)
            chars[#chars + 1] = g
            counts[g] = (counts[g] or 0) + 1
            if g == '.' or g == '^' then
                local group = safe(M.getWalkableGroup, p) or 0
                if group ~= 0 then
                    local key = tostring(group)  -- string keys so JSON gets an object
                    groups[key] = (groups[key] or 0) + 1
                end
            end
        end
        table.insert(rows, table.concat(chars))
    end
    local legend = {}
    for g in pairs(counts) do legend[g] = LEGEND[g] end
    return {
        origin = {x = pos.x, y = pos.y, z = pos.z},
        width = x2 - pos.x + 1,
        height = y2 - pos.y + 1,
        rows = rows,
        legend = legend,
        counts = counts,
        walkable_groups = groups,
        note = 'rows run north to south (y increasing); each row runs west to east (x increasing)',
    }
end

-- First clear w by h rectangle of walkable floor near a point, by expanding rings.
local function find_space(args)
    local w = math.floor(tonumber(args.width) or 3)
    local h = math.floor(tonumber(args.height) or 3)
    if w < 1 or h < 1 or w > 31 or h > 31 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"width" and "height" must be 1-31')
    end
    local z = tonumber(args.z)
    local nx, ny = tonumber(args.near_x), tonumber(args.near_y)
    local wagon_b = wagon_building()
    if nx == nil or ny == nil then
        if wagon_b then
            nx, ny = wagon_b.centerx, wagon_b.centery
        else
            local mw, mh = tile_size()
            nx, ny = math.floor(mw / 2), math.floor(mh / 2)
        end
    end
    if z == nil then
        z = wagon_b and wagon_b.z or surface_z(nx, ny)
    end
    if z == nil then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'no surface level found; pass "z"')
    end
    local center, err = xyz({x = nx, y = ny, z = z})
    if err then return err end
    local radius = math.floor(tonumber(args.max_radius) or 30)
    local mw, mh = tile_size()
    local checked = 0

    local function clear_at(x1, y1)
        if x1 < 0 or y1 < 0 or x1 + w > mw or y1 + h > mh then return false end
        local group = nil
        for y = y1, y1 + h - 1 do
            for x = x1, x1 + w - 1 do
                local p = {x = x, y = y, z = z}
                local tt = M.getTileType(p)
                local des, occ = designation_at(p)
                if not tt or not des or des.hidden or des.flow_size > 0 or occ.building ~= 0 then
                    return false
                end
                local info = tile_shape(tt)
                if not info or info.basic_shape ~= 'Floor' then return false end
                if safe(M.getPlantAtTile, p) then return false end
                local g = safe(M.getWalkableGroup, p) or 0
                if g == 0 then return false end
                group = group or g
                if g ~= group then return false end
            end
        end
        local ok = safe(dfhack.buildings.checkFreeTiles, {x = x1, y = y1, z = z}, {x = w, y = h})
        if ok == false then return false end
        return true, group
    end

    for r = 0, radius do
        for dy = -r, r do
            for dx = -r, r do
                if math.abs(dx) == r or math.abs(dy) == r then
                    local x1 = center.x + dx - math.floor(w / 2)
                    local y1 = center.y + dy - math.floor(h / 2)
                    checked = checked + 1
                    local ok, group = clear_at(x1, y1)
                    if ok then
                        return {
                            found = true,
                            origin = {x = x1, y = y1, z = z},
                            center = {x = x1 + math.floor(w / 2), y = y1 + math.floor(h / 2), z = z},
                            width = w, height = h,
                            walkable_group = group,
                            distance = r,
                            searched_from = center,
                            checked = checked,
                        }
                    end
                end
            end
        end
    end
    return {found = false, searched_from = center, max_radius = radius, checked = checked,
            note = 'no clear rectangle of walkable floor within the radius; try another z or a larger radius'}
end

function ops()
    return {
        ['map.bounds'] = {namespace = 'map', handler = bounds, needs_map = true},
        ['map.wagon'] = {namespace = 'map', handler = wagon, needs_map = true},
        ['map.tile'] = {namespace = 'map', handler = tile, needs_map = true},
        ['map.area'] = {namespace = 'map', handler = area, needs_map = true},
        ['map.find_space'] = {namespace = 'map', handler = find_space, needs_map = true},
    }
end
