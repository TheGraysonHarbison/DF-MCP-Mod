-- Map reads: bounds, the wagon, one tile, an ASCII area map, a free-space finder, wall
-- materials, and the exposed-wall scan. Read-only. Hidden (unrevealed) tiles are reported as
-- hidden and nothing else, so Claude sees what the player sees. Plan sections 10 (4.2) and
-- 11 (6.0).
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

local M = dfhack.maps

DEFAULT_LIMIT = 25
MAX_AREA = 64

VIEWS = {'shape', 'material', 'designations'}

-- Dig and smooth designations drawn over the shape map in the designations view (quickfort's
-- letters) and reported by name elsewhere.
DIG_GLYPHS = {Default = 'd', UpStair = 'u', DownStair = 'j', UpDownStair = 'i',
              Channel = 'h', Ramp = 'r'}
DIG_NAMES = {Default = 'mine', UpStair = 'up_stair', DownStair = 'down_stair',
             UpDownStair = 'up_down_stair', Channel = 'channel', Ramp = 'ramp'}

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
-- materials (plan 11.2): a Lua copy of DFHack's MapExtras::BlockInfo::getBaseMaterial,
-- checked against library/modules/MapCache.cpp on 2026-10-13.

-- tiletype material class to the readable class we report.
local MATERIAL_CLASS = {
    STONE = 'natural_stone', MINERAL = 'mineral_vein', SOIL = 'soil', LAVA_STONE = 'lava_stone',
    FEATURE = 'feature_stone', FROZEN_LIQUID = 'ice', CONSTRUCTION = 'construction',
    TREE = 'tree', ROOT = 'tree', MUSHROOM = 'tree',
}

local function plant_name(pos)
    return safe(function()
        local plant = M.getPlantAtTile(pos)
        return df.global.world.raws.plants.all[plant.material].name
    end)
end

local function inorganic_is_soil(index)
    return safe(function()
        return df.global.world.raws.inorganics.all[index].flags.SOIL_ANY
    end) == true
end

local function inorganic_name(index)
    if index == nil or index < 0 then return nil end
    return safe(function() return dfhack.matinfo.decode(0, index):toString() end)
end

local function matpair_name(mat_type, mat_index)
    if mat_type == nil or mat_type < 0 then return nil end
    return safe(function() return dfhack.matinfo.decode(mat_type, mat_index):toString() end)
end

-- The inorganic of the last mineral vein event covering the tile, as MapCache's SquashVeins.
local function vein_material(block, lx, ly)
    local found = nil
    pcall(function()
        for _, ev in ipairs(block.block_events) do
            if df.block_square_event_mineralst:is_instance(ev)
                and M.getTileAssignment(ev.tile_bitmask, lx, ly) then
                found = ev.inorganic_mat
            end
        end
    end)
    return found
end

-- Geological layers of the tile's biome: 0-based list of inorganic indices plus the biome's
-- default soil (last soil layer) and default stone (first non-soil layer).
local layer_cache = {}
local function geo_layers(pos)
    local rx, ry = M.getTileBiomeRgn(pos)
    if rx == nil then return nil end
    local key = rx .. ',' .. ry
    if layer_cache[key] ~= nil then return layer_cache[key] or nil end
    local out = false
    pcall(function()
        local region = M.getRegionBiome(rx, ry)
        local geo = region and df.world_geo_biome.find(region.geo_index)
        if not geo then return end
        local layers = {n = 0, default_soil = -1, default_stone = -1}
        for i, layer in ipairs(geo.layers) do
            local mat = layer.mat_index
            layers[i] = mat
            layers.n = layers.n + 1
            if inorganic_is_soil(mat) then
                layers.default_soil = mat
            elseif layers.default_stone < 0 then
                layers.default_stone = mat
            end
        end
        out = layers
    end)
    layer_cache[key] = out
    return out or nil
end

local function layer_material(pos, des, want_soil)
    local layers = geo_layers(pos)
    if not layers then return nil end
    local mat = layers[des.geolayer_index]
    if mat == nil then return nil end
    if want_soil and not inorganic_is_soil(mat) and layers.default_soil >= 0 then
        return layers.default_soil
    elseif not want_soil and inorganic_is_soil(mat) and layers.default_stone >= 0 then
        return layers.default_stone
    end
    return mat
end

local function lava_stone(pos)
    local rx, ry = M.getTileBiomeRgn(pos)
    local found = nil
    pcall(function()
        for _, d in ipairs(df.global.world.world_data.region_details) do
            if d.pos.x == rx and d.pos.y == ry then found = d.lava_stone end
        end
    end)
    if found == nil or found < 0 then
        found = safe(function() return dfhack.matinfo.find('OBSIDIAN').index end)
    end
    return found
end

local function feature_material(block, des)
    local feature = nil
    pcall(function()
        if des.feature_local and block.local_feature >= 0 then
            feature = M.getLocalInitFeature(block.region_pos, block.local_feature)
        elseif des.feature_global and block.global_feature >= 0 then
            feature = M.getGlobalInitFeature(block.global_feature)
        end
    end)
    if not feature then return nil end
    local ok, mat_type, mat_index = pcall(function() return feature:getMaterial() end)
    if ok and type(mat_type) == 'number' and mat_type >= 0 then
        return mat_type, mat_index
    end
    return nil
end

-- Engravings indexed by position, built once per call that needs it.
local function engraving_index()
    local index = {}
    pcall(function()
        for _, e in ipairs(df.global.world.engravings) do
            index[e.pos.x .. ',' .. e.pos.y .. ',' .. e.pos.z] = true
        end
    end)
    return index
end

local function is_engraved(pos, index)
    if index then return index[pos.x .. ',' .. pos.y .. ',' .. pos.z] == true end
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

-- Material facts for a revealed tile: {material_name, material_class, construction}.
function tile_material(pos, info, des)
    local out = {material_class = MATERIAL_CLASS[info.material or ''] or 'other'}
    local block = M.getTileBlock(pos)
    if not block then return out end
    local lx, ly = pos.x % 16, pos.y % 16
    local mat = info.material
    if mat == 'MINERAL' then
        local vein = vein_material(block, lx, ly)
        out.material_name = inorganic_name(vein) or inorganic_name(layer_material(pos, des, false))
    elseif mat == 'STONE' then
        out.material_name = inorganic_name(layer_material(pos, des, false))
    elseif mat == 'SOIL' then
        out.material_name = inorganic_name(layer_material(pos, des, true))
    elseif mat == 'LAVA_STONE' then
        out.material_name = inorganic_name(lava_stone(pos))
    elseif mat == 'FEATURE' then
        local mt, mi = feature_material(block, des)
        out.material_name = matpair_name(mt, mi) or 'feature stone'
    elseif mat == 'FROZEN_LIQUID' then
        out.material_name = 'ice'
    elseif mat == 'TREE' or mat == 'MUSHROOM' then
        out.material_name = (plant_name(pos) or 'tree') .. ' trunk'
    elseif mat == 'ROOT' then
        out.material_name = (plant_name(pos) or 'tree') .. ' roots'
    elseif mat == 'CONSTRUCTION' then
        local c = safe(dfhack.constructions.findAtTile, pos)
        if c then
            out.material_name = matpair_name(c.mat_type, c.mat_index)
            out.construction = {
                item_type = enum_name(df.item_type, c.item_type),
                material = out.material_name,
            }
        end
    end
    return out
end

-- natural, smoothed, engraved, constructed, or tree; only for walls. Tree trunk tiletypes
-- carry the SMOOTH special, so trees are decided before the special is looked at.
local function wall_kind(info, material, pos, engraved_index)
    if info.basic_shape ~= 'Wall' then return nil end
    if material.material_class == 'tree' then return 'tree' end
    if material.material_class == 'construction' then return 'constructed' end
    if info.special == 'SMOOTH' then
        if is_engraved(pos, engraved_index) then return 'engraved' end
        return 'smoothed'
    end
    return 'natural'
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
        out.plant = {id = safe(function() return plant.id end),
                     tree = safe(function() return plant.tree_info ~= nil end) == true,
                     name = safe(function()
                         return df.global.world.raws.plants.all[plant.material].name
                     end)}
    end
    out.walkable_group = safe(M.getWalkableGroup, pos) or 0
    out.walkable = out.walkable_group ~= 0
    out.buildable = out.basic_shape == 'Floor' and out.walkable and building == nil
        and des.flow_size == 0 and plant == nil
    local material = tile_material(pos, info or {}, des)
    out.material_name = material.material_name
    out.material_class = material.material_class
    out.construction = material.construction
    out.wall_kind = wall_kind(info or {}, material, pos, nil)
    out.engraved = out.wall_kind == 'engraved'
        or (info and info.special == 'SMOOTH' and is_engraved(pos, nil)) or false
    out.smooth = (function()
        local v = des.smooth
        if v == 1 then return 'smooth' elseif v == 2 then return 'engrave' end
        return nil
    end)()
    out.items = items_at(pos, limit)
    out.units = units_at(pos)
    return out
end

local function tile(args)
    layer_cache = {}
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

-- Letters handed out per distinct wall material in the material view.
local MATERIAL_LETTERS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

local function area(args)
    layer_cache = {}
    local pos, err = xyz(args)
    if err then return err end
    local w = math.floor(tonumber(args.width) or 32)
    local h = math.floor(tonumber(args.height) or 32)
    if w < 1 or h < 1 or w > MAX_AREA or h > MAX_AREA then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('"width" and "height" must be 1-%d'):format(MAX_AREA))
    end
    local view = args.view == nil and 'shape' or tostring(args.view)
    local known = false
    for _, v in ipairs(VIEWS) do if v == view then known = true end end
    if not known then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"view" must be one of ' .. table.concat(VIEWS, ', '))
    end
    local mw, mh = tile_size()
    local x2 = math.min(pos.x + w - 1, mw - 1)
    local y2 = math.min(pos.y + h - 1, mh - 1)
    local rows, groups, counts = {}, {}, {}
    local legend = {}
    local letters, next_letter = {}, 1
    local engraved = view == 'material' and engraving_index() or nil
    for y = pos.y, y2 do
        local chars = {}
        for x = pos.x, x2 do
            local p = {x = x, y = y, z = pos.z}
            local g = glyph(p)
            if g == '#' and view == 'material' then
                local tt = M.getTileType(p)
                local des = designation_at(p)
                local info = tile_shape(tt) or {}
                local material = tile_material(p, info, des)
                local kind = wall_kind(info, material, p, engraved) or 'natural'
                if kind == 'tree' then
                    g = 'T'
                else
                    local name = material.material_name or material.material_class
                    local key = name .. '|' .. kind
                    if not letters[key] then
                        local letter = MATERIAL_LETTERS:sub(next_letter, next_letter)
                        if letter == '' then letter = '#' end
                        next_letter = next_letter + 1
                        letters[key] = letter
                        legend[letter] = name .. ' wall'
                            .. (kind ~= 'natural' and (' (' .. kind .. ')') or '')
                    end
                    g = letters[key]
                end
            elseif view == 'designations' and g ~= '?' then
                local des = designation_at(p)
                local dig = des and enum_name(df.tile_dig_designation, des.dig)
                if dig and DIG_GLYPHS[dig] then
                    g = DIG_GLYPHS[dig]
                    legend[g] = 'designated: ' .. DIG_NAMES[dig]
                elseif des and des.smooth == 1 then
                    g = 's'
                    legend[g] = 'designated: smooth'
                elseif des and des.smooth == 2 then
                    g = 'e'
                    legend[g] = 'designated: engrave'
                end
            end
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
    for g in pairs(counts) do
        if legend[g] == nil then legend[g] = LEGEND[g] end
    end
    return {
        origin = {x = pos.x, y = pos.y, z = pos.z},
        width = x2 - pos.x + 1,
        height = y2 - pos.y + 1,
        view = view,
        rows = rows,
        legend = legend,
        counts = counts,
        walkable_groups = groups,
        note = 'rows run north to south (y increasing); each row runs west to east (x increasing)',
    }
end

-- Exposed walls: wall tiles bordering walkable floor, merged into straight segments.
-- Plan 11.3 and 11.6.
local SIDES = {
    {name = 'north', dx = 0, dy = -1}, {name = 'south', dx = 0, dy = 1},
    {name = 'west', dx = -1, dy = 0}, {name = 'east', dx = 1, dy = 0},
}

local function exposed_walls(args)
    layer_cache = {}
    local z = tonumber(args.z)
    if z == nil then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"z" must be a number') end
    z = math.floor(z)
    local mw, mh, md = tile_size()
    if z < 0 or z >= md then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, ('"z" must be 0-%d'):format(md - 1))
    end
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    if limit < 1 then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be positive') end
    local x1, y1, x2, y2 = 0, 0, mw - 1, mh - 1
    local nx, ny, radius = tonumber(args.near_x), tonumber(args.near_y), tonumber(args.radius)
    if nx ~= nil or ny ~= nil or radius ~= nil then
        if nx == nil or ny == nil then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"near_x" and "near_y" go together')
        end
        radius = math.floor(radius or 20)
        x1, y1 = math.max(0, math.floor(nx) - radius), math.max(0, math.floor(ny) - radius)
        x2, y2 = math.min(mw - 1, math.floor(nx) + radius), math.min(mh - 1, math.floor(ny) + radius)
    end
    local wanted = args.material ~= nil and tostring(args.material):lower() or nil
    local engraved = engraving_index()

    -- pass 1: exposed wall tiles
    local tiles = {}  -- key -> record
    local function key_of(x, y) return x .. ',' .. y end
    local total_tiles = 0
    for y = y1, y2 do
        for x = x1, x2 do
            local p = {x = x, y = y, z = z}
            local tt = M.getTileType(p)
            local des, occ = designation_at(p)
            if tt and des and not des.hidden and occ.building == 0 then
                local info = tile_shape(tt)
                if info and info.basic_shape == 'Wall' then
                    local open, group = {}, nil
                    for _, side in ipairs(SIDES) do
                        local q = {x = x + side.dx, y = y + side.dy, z = z}
                        if in_bounds(q.x, q.y, q.z) then
                            local qdes = designation_at(q)
                            if qdes and not qdes.hidden then
                                local g = safe(M.getWalkableGroup, q) or 0
                                if g ~= 0 then
                                    open[side.name] = true
                                    group = group or g
                                end
                            end
                        end
                    end
                    local material = group and tile_material(p, info, des)
                    if group and material.material_class ~= 'tree'
                        and material.material_class ~= 'other' then
                        local name = material.material_name or material.material_class
                        if wanted == nil or name:lower():find(wanted, 1, true) then
                            total_tiles = total_tiles + 1
                            tiles[key_of(x, y)] = {
                                x = x, y = y, material = name,
                                material_class = material.material_class,
                                kind = wall_kind(info, material, p, engraved) or 'natural',
                                open = open, group = group,
                            }
                        end
                    end
                end
            end
        end
    end

    -- pass 2: merge into runs. A tile joins the axis on which its run is longer.
    local function same(a, b)
        if not a or not b then return false end
        if a.material ~= b.material or a.kind ~= b.kind then return false end
        for _, side in ipairs(SIDES) do
            if (a.open[side.name] == true) ~= (b.open[side.name] == true) then return false end
        end
        return true
    end
    local function run_length(t, dx, dy)
        local n = 1
        local cur = t
        while true do
            local nxt = tiles[key_of(cur.x + dx, cur.y + dy)]
            if not same(cur, nxt) then break end
            n = n + 1
            cur = nxt
        end
        return n
    end
    for _, t in pairs(tiles) do
        local hor = run_length(t, 1, 0) + run_length(t, -1, 0) - 1
        local ver = run_length(t, 0, 1) + run_length(t, 0, -1) - 1
        t.axis = ver > hor and 'y' or 'x'
    end
    local segments = {}
    local seen = {}
    local function sides_list(open)
        local out = {}
        for _, side in ipairs(SIDES) do if open[side.name] then table.insert(out, side.name) end end
        return out
    end
    for y = y1, y2 do
        for x = x1, x2 do
            local t = tiles[key_of(x, y)]
            if t and not seen[key_of(x, y)] then
                local dx, dy = t.axis == 'x' and 1 or 0, t.axis == 'y' and 1 or 0
                local cur, last = t, t
                seen[key_of(x, y)] = true
                while true do
                    local nxt = tiles[key_of(last.x + dx, last.y + dy)]
                    if not nxt or nxt.axis ~= t.axis or seen[key_of(nxt.x, nxt.y)]
                        or not same(last, nxt) then break end
                    seen[key_of(nxt.x, nxt.y)] = true
                    last = nxt
                end
                local length = math.max(last.x - cur.x, last.y - cur.y) + 1
                table.insert(segments, {
                    x1 = cur.x, y1 = cur.y, x2 = last.x, y2 = last.y, z = z,
                    length = length, material = t.material, material_class = t.material_class,
                    kind = t.kind, open_sides = sides_list(t.open), floor_group = t.group,
                })
            end
        end
    end
    table.sort(segments, function(a, b)
        if a.length ~= b.length then return a.length > b.length end
        if a.y1 ~= b.y1 then return a.y1 < b.y1 end
        return a.x1 < b.x1
    end)
    local by_material = {}
    for _, seg in ipairs(segments) do
        by_material[seg.material] = (by_material[seg.material] or 0) + seg.length
    end
    local out = {}
    for i = 1, math.min(limit, #segments) do out[i] = segments[i] end
    return {
        z = z,
        scanned = {x1 = x1, y1 = y1, x2 = x2, y2 = y2},
        total_tiles = total_tiles,
        total_segments = #segments,
        count = #out,
        truncated = #segments > #out,
        segments = out,
        tiles_by_material = by_material,
        note = 'a segment is a straight run of wall tiles with the same material, kind, and open sides; '
            .. 'open_sides says where walkable floor touches it',
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
        ['map.exposed_walls'] = {namespace = 'map', handler = exposed_walls, needs_map = true},
    }
end
