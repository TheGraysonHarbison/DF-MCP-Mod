-- Activity zones: list with filters and inspect one (tiles, owner, assigned units, squads,
-- location, per-type settings). Plan section 12, item 8.0. Fields from df-structures
-- building_civzonest (checked 2026-10-14): type, zone_num, spec_sub_flag.active,
-- room.extents, assigned_unit_id (the owner), assigned_units (pens, pits, ponds),
-- assigned_items (vermin), squad_room_info, location_id, contained_buildings, and the
-- zone_settings union (pen, pond, gather, archery, tomb).
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local build = reqscript('internal/claude-bridge/build')
local map = reqscript('internal/claude-bridge/map')
local dig = reqscript('internal/claude-bridge/dig')

local B = dfhack.buildings
local U = dfhack.units

DEFAULT_LIMIT = 25

-- civzone_type token -> plain name. Pond zones are pits unless keep_filled is set.
TYPE_NAMES = {
    MeetingHall = 'meeting_area', Bedroom = 'bedroom', DiningHall = 'dining_hall',
    Dormitory = 'dormitory', Barracks = 'barracks', ArcheryRange = 'archery_range',
    Office = 'office', Tomb = 'tomb', Pen = 'pen', Pond = 'pond', Dump = 'dump',
    WaterSource = 'water_source', FishingArea = 'fishing', SandCollection = 'sand',
    ClayCollection = 'clay', PlantGathering = 'gather', AnimalTraining = 'animal_training',
    Dungeon = 'dungeon',
}
PLAIN_TO_TOKEN = {}
for token, plain in pairs(TYPE_NAMES) do PLAIN_TO_TOKEN[plain] = token end
PLAIN_TO_TOKEN.pit = 'Pond'
PLAIN_TO_TOKEN.pasture = 'Pen'
PLAIN_TO_TOKEN.meeting_hall = 'MeetingHall'
PLAIN_TO_TOKEN.dining_room = 'DiningHall'
PLAIN_TO_TOKEN.garbage_dump = 'Dump'
PLAIN_TO_TOKEN.fishing_area = 'FishingArea'
PLAIN_TO_TOKEN.sand_collection = 'SandCollection'
PLAIN_TO_TOKEN.clay_collection = 'ClayCollection'
PLAIN_TO_TOKEN.plant_gathering = 'PlantGathering'
PLAIN_TO_TOKEN.gather_fruit = 'PlantGathering'

-- Which assignment a zone type carries (plan 12.2).
ASSIGNMENT = {
    Bedroom = 'owner', Office = 'owner', DiningHall = 'owner', Tomb = 'owner',
    Pen = 'units', Pond = 'units', Dungeon = 'units',
    Barracks = 'squads', ArcheryRange = 'squads', MeetingHall = 'location',
}

-- Location (abstract building) class -> plain name.
LOCATION_TYPES = {
    abstract_building_inn_tavernst = 'tavern', abstract_building_templest = 'temple',
    abstract_building_libraryst = 'library', abstract_building_guildhallst = 'guildhall',
    abstract_building_hospitalst = 'hospital',
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

local function unit_ref(unit)
    if not unit then return nil end
    return {id = unit.id, name = safe(U.getReadableName, unit) or ('unit ' .. unit.id)}
end

function type_token(zone) return enum_name(df.civzone_type, zone.type) end

local function is_pit(zone)
    return type_token(zone) == 'Pond'
        and not safe(function() return zone.zone_settings.pond.flag.keep_filled end)
end

function plain_type(zone)
    local token = type_token(zone)
    if token == 'Pond' then return is_pit(zone) and 'pit' or 'pond' end
    return TYPE_NAMES[token or ''] or (token and token:lower()) or '?'
end

-- Tiles inside the zone: the non-zero extents bytes, else the rectangle.
function tile_list(zone, limit)
    local out, total = {}, 0
    local room = zone.room
    local has_extents = safe(function() return room.extents ~= nil end)
    if has_extents then
        for i = 0, room.width * room.height - 1 do
            if room.extents[i] ~= 0 then
                total = total + 1
                if #out < limit then
                    table.insert(out, {x = room.x + i % room.width,
                                       y = room.y + math.floor(i / room.width), z = zone.z})
                end
            end
        end
    else
        for y = zone.y1, zone.y2 do
            for x = zone.x1, zone.x2 do
                total = total + 1
                if #out < limit then table.insert(out, {x = x, y = y, z = zone.z}) end
            end
        end
    end
    return out, total
end

local function location_of(zone)
    local loc_id = safe(function() return zone.location_id end)
    if not loc_id or loc_id < 0 then return nil end
    local found = nil
    pcall(function()
        local site = dfhack.world.getCurrentSite()
        for _, bld in ipairs(site.buildings) do
            if bld.id == loc_id then
                found = {id = loc_id,
                         name = safe(function() return dfhack.translation.translateName(bld.name, true) end)}
                for class, plain in pairs(LOCATION_TYPES) do
                    if safe(function() return df[class]:is_instance(bld) end) then found.type = plain end
                end
                return
            end
        end
    end)
    return found or {id = loc_id}
end

local function shoot_from(dir_x, dir_y)
    if dir_x == 1 and dir_y == 0 then return 'west' end
    if dir_x == -1 and dir_y == 0 then return 'east' end
    if dir_x == 0 and dir_y == 1 then return 'north' end
    if dir_x == 0 and dir_y == -1 then return 'south' end
    return nil
end

-- Per-type settings from the zone_settings union, by plain name.
function settings_of(zone)
    local token = type_token(zone)
    local zs = zone.zone_settings
    if token == 'Pen' then
        return {check_occupants = safe(function() return zs.pen.flags.check_occupants end) == true}
    elseif token == 'Pond' then
        local keep = safe(function() return zs.pond.flag.keep_filled end) == true
        return {pit_or_pond = keep and 'pond' or 'pit', keep_filled = keep,
                check_occupants = safe(function() return zs.pond.flag.check_occupants end) == true}
    elseif token == 'PlantGathering' then
        return {pick_trees = safe(function() return zs.gather.flags.pick_trees end) == true,
                pick_shrubs = safe(function() return zs.gather.flags.pick_shrubs end) == true,
                gather_fallen = safe(function() return zs.gather.flags.gather_fallen end) == true}
    elseif token == 'ArcheryRange' then
        local dx = safe(function() return zs.archery.dir_x end)
        local dy = safe(function() return zs.archery.dir_y end)
        return {dir_x = dx, dir_y = dy, shoot_from = shoot_from(dx, dy)}
    elseif token == 'Tomb' then
        return {allow_pets = safe(function() return zs.tomb.flags.no_pets end) ~= true,
                allow_citizens = safe(function() return zs.tomb.flags.no_citizens end) ~= true}
    end
    return {}
end

function summary(zone)
    local number = safe(function() return zone.zone_num end)
    local name = safe(function() return zone.name ~= '' and zone.name or nil end)
    local token = type_token(zone)
    local _, total = tile_list(zone, 0)
    return {
        id = zone.id, number = number, name = name,
        label = name or (number and ('Zone #' .. number)) or ('zone ' .. zone.id),
        type = plain_type(zone), type_token = token,
        active = safe(function() return zone.spec_sub_flag.active end) == true,
        bounds = {x1 = zone.x1, y1 = zone.y1, x2 = zone.x2, y2 = zone.y2, z = zone.z},
        pos = {x = zone.centerx, y = zone.centery, z = zone.z},
        tiles = total,
        assignment = ASSIGNMENT[token or ''] or 'none',
        owner = unit_ref(safe(B.getOwner, zone)),
        assigned_units = safe(function() return #zone.assigned_units end) or 0,
        squads = safe(function() return #zone.squad_room_info end) or 0,
        location = location_of(zone),
    }
end

function all_zones()
    return safe(function() return df.global.world.buildings.other.ACTIVITY_ZONE end) or {}
end

function find_zone(id)
    local b = df.building.find(id)
    if not b then return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'no building with id ' .. id) end
    if not df.building_civzonest:is_instance(b) then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('building %d is a %s, not a zone'):format(id, enum_name(df.building_type, b:getType()) or '?'))
    end
    return b
end

function parse_limit(args)
    local limit = tonumber(args.limit) or DEFAULT_LIMIT
    if limit < 1 then limit = DEFAULT_LIMIT end
    return math.floor(limit)
end

function resolve_type(name)
    if name == nil then return nil end
    local key = tostring(name):lower():gsub('^%s+', ''):gsub('%s+$', ''):gsub('[%s%-]+', '_')
    if PLAIN_TO_TOKEN[key] then return PLAIN_TO_TOKEN[key], key end
    for token in pairs(TYPE_NAMES) do
        if token:lower() == key then return token, TYPE_NAMES[token] end
    end
    return nil
end

function known_type_names()
    local names = {}
    for p in pairs(PLAIN_TO_TOKEN) do table.insert(names, p) end
    table.sort(names)
    return names
end

local function list(args)
    local token, plain
    if args.type ~= nil then
        token, plain = resolve_type(args.type)
        if not token then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('unknown zone "type" %s; use one of %s'):format(tostring(args.type),
                    table.concat(known_type_names(), ', ')))
        end
    end
    local query = args.query ~= nil and tostring(args.query):lower() or nil
    local active = args.active
    local limit = parse_limit(args)
    local offset = tonumber(args.offset) or 0
    local rows, counts = {}, {}
    for _, zone in ipairs(all_zones()) do
        local row = summary(zone)
        local keep = true
        if token and row.type_token ~= token then keep = false end
        if keep and (plain == 'pit' or plain == 'pond') and row.type ~= plain then keep = false end
        if keep and query and not ((row.name or ''):lower():find(query, 1, true)
            or row.label:lower():find(query, 1, true)) then keep = false end
        if keep and type(active) == 'boolean' and row.active ~= active then keep = false end
        if keep then
            table.insert(rows, row)
            counts[row.type] = (counts[row.type] or 0) + 1
        end
    end
    table.sort(rows, function(a, b2) return a.id < b2.id end)
    local out = {}
    for i = offset + 1, math.min(#rows, offset + limit) do table.insert(out, rows[i]) end
    return {total = #rows, count = #out, offset = offset, limit = limit,
            truncated = offset + #out < #rows, zones = out, counts_by_type = counts,
            filter = {type = plain, query = query, active = active}}
end

function detail(zone, limit)
    local row = summary(zone)
    local tiles, total = tile_list(zone, limit)
    row.extents = tiles
    row.tiles = total
    row.tiles_truncated = total > #tiles
    row.settings = settings_of(zone)
    local units = {}
    pcall(function()
        for i, uid in ipairs(zone.assigned_units) do
            if i > limit then break end
            local u = df.unit.find(uid)
            table.insert(units, u and unit_ref(u) or {id = uid})
        end
    end)
    row.assigned_units = units
    row.assigned_units_total = safe(function() return #zone.assigned_units end) or 0
    row.assigned_items = safe(function() return #zone.assigned_items end) or 0
    local squads = {}
    pcall(function()
        for _, info in ipairs(zone.squad_room_info) do
            local squad = df.squad.find(info.squad_id)
            table.insert(squads, {id = info.squad_id,
                name = squad and safe(function() return dfhack.translation.translateName(squad.name, true) end) or nil,
                alias = squad and safe(function() return squad.alias ~= '' and squad.alias or nil end) or nil})
        end
    end)
    row.squads = squads
    local contained = {}
    pcall(function()
        for i, b in ipairs(zone.contained_buildings) do
            if i > limit then break end
            local s = build.building_summary(b)
            table.insert(contained, {id = s.id, kind = s.kind, type = s.type, pos = s.pos, built = s.built})
        end
    end)
    row.contained_buildings = contained
    row.contained_buildings_total = safe(function() return #zone.contained_buildings end) or 0
    -- The description comes with the owner's eyes when there is one (the quality label
    -- depends on who the room is for).
    row.room_description = safe(function()
        local owner = B.getOwner(zone)
        local d = owner and B.getRoomDescription(zone, owner) or B.getRoomDescription(zone)
        return d ~= '' and d or nil
    end)
    return row
end

local function get(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a zone id') end
    local zone, err = find_zone(id)
    if err then return err end
    return detail(zone, parse_limit(args))
end

-- ---------------------------------------------------------------------------------------
-- Writes (plan 12, item 8.1), under zones_write.

-- No zone size cap of ours (P2-4.0): quickfort's zone module allows any size
-- (hack/scripts/internal/quickfort/zone.lua max_width = math.huge, 53.16-r2); the map's
-- bounds are the limit and shapes are clipped to them.

-- A box {x1, y1, x2, y2, z} or circle for a zone shape. Returns box, membership fn.
local function parse_shape(args)
    if args.circle ~= nil then
        local box, err, inside = dig.parse_circle(args)
        if err then return nil, err end
        return box, inside
    end
    local z = tonumber(args.z)
    if z == nil then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"x1", "y1", "x2", "y2", "z" or a "circle" are required')
    end
    local box, err = map.parse_box({x1 = args.x1, y1 = args.y1, z1 = z, x2 = args.x2, y2 = args.y2, z2 = z})
    if err then return nil, err end
    return box, nil
end

local SHOOT_FROM = {west = {1, 0}, east = {-1, 0}, north = {0, 1}, south = {0, -1}}

-- Apply name, active, and per-type settings from args. Returns the list of changes or
-- nil, error. Only fields given in args are touched.
local function apply_settings(zone, args, token)
    local changed = {}
    if args.name ~= nil then
        if type(args.name) ~= 'string' or #args.name > 64 then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a string of up to 64 characters')
        end
        zone.name = dfhack.utf2df(args.name)
        table.insert(changed, 'name')
    end
    if args.active ~= nil then
        if type(args.active) ~= 'boolean' then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"active" must be true or false')
        end
        zone.spec_sub_flag.active = args.active
        table.insert(changed, 'active')
    end
    local zs = zone.zone_settings
    local function flag(field, value, setter)
        if value == nil then return nil end
        if type(value) ~= 'boolean' then
            return ('"%s" must be true or false'):format(field)
        end
        setter(value)
        table.insert(changed, field)
    end
    local errs = {}
    if token == 'Pen' then
        table.insert(errs, flag('check_occupants', args.check_occupants, function(v) zs.pen.flags.check_occupants = v end))
    elseif token == 'Pond' then
        table.insert(errs, flag('keep_filled', args.keep_filled, function(v) zs.pond.flag.keep_filled = v end))
        table.insert(errs, flag('check_occupants', args.check_occupants, function(v) zs.pond.flag.check_occupants = v end))
    elseif token == 'PlantGathering' then
        table.insert(errs, flag('pick_trees', args.pick_trees, function(v) zs.gather.flags.pick_trees = v end))
        table.insert(errs, flag('pick_shrubs', args.pick_shrubs, function(v) zs.gather.flags.pick_shrubs = v end))
        table.insert(errs, flag('gather_fallen', args.gather_fallen, function(v) zs.gather.flags.gather_fallen = v end))
    elseif token == 'ArcheryRange' then
        if args.shoot_from ~= nil then
            local d = SHOOT_FROM[tostring(args.shoot_from):lower()]
            if not d then
                return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"shoot_from" must be north, south, east, or west')
            end
            zs.archery.dir_x, zs.archery.dir_y = d[1], d[2]
            table.insert(changed, 'shoot_from')
        end
    elseif token == 'Tomb' then
        table.insert(errs, flag('allow_pets', args.allow_pets, function(v) zs.tomb.flags.no_pets = not v end))
        table.insert(errs, flag('allow_citizens', args.allow_citizens, function(v) zs.tomb.flags.no_citizens = not v end))
    end
    for _, e in ipairs(errs) do
        if e then return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, e) end
    end
    -- A setting that does not belong to the type is a mistake worth naming.
    local foreign = {}
    for _, field in ipairs({'check_occupants', 'keep_filled', 'pick_trees', 'pick_shrubs', 'gather_fallen',
                            'shoot_from', 'allow_pets', 'allow_citizens'}) do
        if args[field] ~= nil then
            local used = false
            for _, c in ipairs(changed) do if c == field then used = true end end
            if not used then table.insert(foreign, field) end
        end
    end
    if #foreign > 0 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('%s does not apply to a %s zone'):format(table.concat(foreign, ', '), TYPE_NAMES[token] or token))
    end
    return changed
end

-- Zones of the same type that share a tile with the given tile set, for a warning.
local function overlaps(token, tiles, z, skip_id)
    local hits = {}
    for _, zone in ipairs(all_zones()) do
        if zone.id ~= skip_id and zone.z == z and type_token(zone) == token then
            for _, t in ipairs(tiles) do
                if safe(B.containsTile, zone, t.x, t.y) then
                    table.insert(hits, zone.id)
                    break
                end
            end
        end
    end
    return hits
end

local function create(args)
    local token, plain = resolve_type(args.type)
    if not token then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('unknown zone "type" %s; use one of %s'):format(tostring(args.type), table.concat(known_type_names(), ', ')))
    end
    local box, inside = parse_shape(args)
    if box == nil then return inside end
    local w, h, z = box.x2 - box.x1 + 1, box.y2 - box.y1 + 1, box.z1
    local tiles, hidden = {}, 0
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', w * h))
    for i = 0, w * h - 1 do
        local x, y = box.x1 + i % w, box.y1 + math.floor(i / w)
        local keep = inside == nil or inside(x, y)
        if keep then
            local des = dfhack.maps.getTileFlags({x = x, y = y, z = z})
            if not des or des.hidden then
                keep = false
                hidden = hidden + 1
            end
        end
        extents[i] = keep and 1 or 0
        if keep then table.insert(tiles, {x = x, y = y}) end
    end
    if #tiles == 0 then
        df.delete(extents)
        return {status = 'invalid_space', reason = 'no revealed tile in the shape', hidden = hidden}
    end
    local fields = {assigned_unit_id = -1,
                    room = {x = box.x1, y = box.y1, width = w, height = h, extents = extents}}
    local zone, err = B.constructBuilding{
        type = df.building_type.Civzone, subtype = df.civzone_type[token], abstract = true,
        pos = {x = box.x1, y = box.y1, z = z}, width = w, height = h, fields = fields,
    }
    if not zone then
        return {status = 'invalid_space', reason = tostring(err)}
    end
    -- Pits and ponds share a type; the plain word decides keep_filled.
    if token == 'Pond' then zone.zone_settings.pond.flag.keep_filled = (plain == 'pond') end
    if token == 'Pen' then zone.zone_settings.pen.flags.check_occupants = true end
    if token == 'PlantGathering' then
        local g = zone.zone_settings.gather.flags
        g.pick_trees, g.pick_shrubs, g.gather_fallen = true, true, true
    end
    if token == 'ArcheryRange' then zone.zone_settings.archery.dir_x, zone.zone_settings.archery.dir_y = 1, 0 end
    if args.active == nil then zone.spec_sub_flag.active = true end
    local changed, serr = apply_settings(zone, args, token)
    local warnings = {}
    if serr then
        table.insert(warnings, 'zone created but a setting was refused: ' .. serr.message)
    end
    local hits = overlaps(token, tiles, z, zone.id)
    if #hits > 0 then
        table.insert(warnings, ('overlaps %s zone(s) %s of the same type; the game allows it but shared floor tiles '
            .. 'set a room\'s value to zero'):format(#hits, table.concat(hits, ', ')))
    end
    local row = detail(zone, parse_limit(args))
    return {status = 'created', zone = row, hidden_skipped = hidden, clipped = box.clipped == true,
            changed = changed or {}, warnings = warnings,
            note = 'the zone exists now; assign an owner or animals with zones.assign'}
end

-- Replace a zone's tiles with a new set (map "x,y" -> true), refitting its bounds.
local function set_tiles(zone, set)
    local minx, miny, maxx, maxy, n = math.huge, math.huge, -math.huge, -math.huge, 0
    for key in pairs(set) do
        local x, y = key:match('^(-?%d+),(-?%d+)$')
        x, y = tonumber(x), tonumber(y)
        if x < minx then minx = x end
        if x > maxx then maxx = x end
        if y < miny then miny = y end
        if y > maxy then maxy = y end
        n = n + 1
    end
    if n == 0 then return nil, 'a zone needs at least one tile' end
    local w, h = maxx - minx + 1, maxy - miny + 1
    local extents = df.reinterpret_cast(df.building_extents_type, df.new('uint8_t', w * h))
    for i = 0, w * h - 1 do
        local x, y = minx + i % w, miny + math.floor(i / w)
        extents[i] = set[x .. ',' .. y] and 1 or 0
    end
    local old = zone.room.extents
    zone.room.extents = extents
    zone.room.x, zone.room.y, zone.room.width, zone.room.height = minx, miny, w, h
    zone.x1, zone.y1, zone.x2, zone.y2 = minx, miny, maxx, maxy
    zone.centerx, zone.centery = minx + math.floor(w / 2), miny + math.floor(h / 2)
    if old then pcall(df.delete, old) end
    pcall(B.notifyCivzoneModified, zone)
    return n
end

local function edit(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a zone id') end
    local zone, err = find_zone(id)
    if err then return err end
    local token = type_token(zone)
    if args.type ~= nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'a zone\'s type cannot change; delete it and create a new one')
    end
    local changed, serr = apply_settings(zone, args, token)
    if serr then return serr end
    local added, removed = 0, 0
    if args.add ~= nil or args.remove ~= nil then
        local set = {}
        local tiles = tile_list(zone, math.huge)
        for _, t in ipairs(tiles) do set[t.x .. ',' .. t.y] = true end
        for _, op in ipairs({{'add', args.add}, {'remove', args.remove}}) do
            local kind, shape = op[1], op[2]
            if shape ~= nil then
                if type(shape) ~= 'table' then
                    return rpc.error_result(rpc.ERR_BAD_REQUEST, ('"%s" must be a box {x1, y1, x2, y2} or circle {x, y, radius}'):format(kind))
                end
                shape = {x1 = shape.x1, y1 = shape.y1, x2 = shape.x2, y2 = shape.y2, z = zone.z,
                         circle = shape.circle or (shape.radius and {x = shape.x, y = shape.y, z = zone.z, radius = shape.radius}) or nil}
                local box, inside = parse_shape(shape)
                if box == nil then return inside end
                for y = box.y1, box.y2 do
                    for x = box.x1, box.x2 do
                        if inside == nil or inside(x, y) then
                            local key = x .. ',' .. y
                            if kind == 'add' then
                                local des = dfhack.maps.getTileFlags({x = x, y = y, z = zone.z})
                                if des and not des.hidden and not set[key] then
                                    set[key] = true
                                    added = added + 1
                                end
                            elseif set[key] then
                                set[key] = nil
                                removed = removed + 1
                            end
                        end
                    end
                end
            end
        end
        local n, why = set_tiles(zone, set)
        if not n then return rpc.error_result(rpc.ERR_BAD_REQUEST, why) end
        if added > 0 then table.insert(changed, 'add') end
        if removed > 0 then table.insert(changed, 'remove') end
    end
    return {changed = changed, tiles_added = added, tiles_removed = removed, zone = detail(zone, parse_limit(args))}
end

local OWNER_TYPES = {Bedroom = true, Office = true, DiningHall = true, Tomb = true}
local ANIMAL_TYPES = {Pen = true, Pond = true}

-- Drop a unit's link to whatever zone it was assigned to (the zone plugin's detach).
local function detach_unit(unit)
    local from = {}
    pcall(function()
        for idx = #unit.general_refs - 1, 0, -1 do
            local ref = unit.general_refs[idx]
            if df.general_ref_building_civzone_assignedst:is_instance(ref) then
                local old = df.building.find(ref.building_id)
                if old and df.building_civzonest:is_instance(old) then
                    for i = #old.assigned_units - 1, 0, -1 do
                        if old.assigned_units[i] == unit.id then old.assigned_units:erase(i) end
                    end
                    table.insert(from, old.id)
                end
                unit.general_refs:erase(idx)
                ref:delete()
            end
        end
    end)
    return from
end

local function assign(args)
    local id, unit_id = tonumber(args.id), tonumber(args.unit_id)
    if not id or not unit_id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" (zone) and "unit_id" are required') end
    local zone, err = find_zone(id)
    if err then return err end
    local unit = df.unit.find(unit_id)
    if not unit then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. unit_id) end
    local token = type_token(zone)
    local plain = plain_type(zone)
    if OWNER_TYPES[token] then
        if not safe(U.isCitizen, unit, true) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('a %s is owned by a citizen; unit %d is not one'):format(plain, unit_id))
        end
        local previous = unit_ref(safe(B.getOwner, zone))
        local ok = safe(B.setOwner, zone, unit)
        if ok == false then return rpc.error_result(rpc.ERR_INTERNAL, 'DFHack could not set the owner') end
        return {status = 'assigned', role = 'owner', previous_owner = previous, zone = detail(zone, parse_limit(args))}
    elseif ANIMAL_TYPES[token] then
        local citizen = safe(U.isCitizen, unit, true) == true
        local pet = safe(U.isPet, unit) == true
        local tame = safe(U.isTame, unit) == true
        if token == 'Pen' and (citizen or not tame) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('a pen takes tame animals; unit %d is %s'):format(
                unit_id, citizen and 'a citizen' or 'not tame'))
        end
        if token == 'Pond' and (citizen or pet) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('a %s cannot take %s; citizens and pets are never pitted by the bridge'):format(
                plain, citizen and 'a citizen' or 'a pet'))
        end
        for _, uid in ipairs(zone.assigned_units) do
            if uid == unit_id then return {status = 'already_assigned', role = 'animal', zone = detail(zone, parse_limit(args))} end
        end
        local from = detach_unit(unit)
        zone.assigned_units:insert('#', unit_id)
        local ref = df.general_ref_building_civzone_assignedst:new()
        ref.building_id = zone.id
        unit.general_refs:insert('#', ref)
        return {status = 'assigned', role = 'animal', moved_from = from, zone = detail(zone, parse_limit(args))}
    end
    return rpc.error_result(rpc.ERR_BAD_REQUEST,
        ('a %s zone takes no unit assignment%s'):format(plain,
            (token == 'Barracks' or token == 'ArcheryRange') and ' from the bridge (squads wait for the military phase)'
            or (token == 'Dungeon' and '; prisoners go to chains and cages inside it' or '')))
end

local function unassign(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a zone id') end
    local zone, err = find_zone(id)
    if err then return err end
    local token = type_token(zone)
    if OWNER_TYPES[token] then
        local previous = unit_ref(safe(B.getOwner, zone))
        if not previous then return {status = 'no_owner', zone = detail(zone, parse_limit(args))} end
        safe(B.setOwner, zone, nil)
        return {status = 'unassigned', role = 'owner', previous_owner = previous, zone = detail(zone, parse_limit(args))}
    elseif ANIMAL_TYPES[token] then
        local unit_id = tonumber(args.unit_id)
        if not unit_id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"unit_id" is required for a pen, pit, or pond') end
        local found = false
        for i = #zone.assigned_units - 1, 0, -1 do
            if zone.assigned_units[i] == unit_id then
                zone.assigned_units:erase(i)
                found = true
            end
        end
        local unit = df.unit.find(unit_id)
        if unit then
            pcall(function()
                for idx = #unit.general_refs - 1, 0, -1 do
                    local ref = unit.general_refs[idx]
                    if df.general_ref_building_civzone_assignedst:is_instance(ref) and ref.building_id == zone.id then
                        unit.general_refs:erase(idx)
                        ref:delete()
                    end
                end
            end)
        end
        return {status = found and 'unassigned' or 'not_assigned', role = 'animal', zone = detail(zone, parse_limit(args))}
    end
    return rpc.error_result(rpc.ERR_BAD_REQUEST, ('a %s zone has no unit assignment to remove'):format(plain_type(zone)))
end

local function delete(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a zone id') end
    local zone, err = find_zone(id)
    if err then return err end
    local row = summary(zone)
    local ok, derr = pcall(B.deconstruct, zone)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'deconstruct failed: ' .. tostring(derr)) end
    return {status = df.building.find(id) == nil and 'deleted' or 'removal_queued', zone = row,
            note = 'the zone is gone; buildings and items inside it are untouched'}
end

function ops()
    return {
        ['zones.list'] = {namespace = 'zones', handler = list, needs_map = true},
        ['zones.get'] = {namespace = 'zones', handler = get, needs_map = true},
        ['zones.create'] = {namespace = 'zones_write', handler = create, needs_map = true},
        ['zones.edit'] = {namespace = 'zones_write', handler = edit, needs_map = true},
        ['zones.assign'] = {namespace = 'zones_write', handler = assign, needs_map = true},
        ['zones.unassign'] = {namespace = 'zones_write', handler = unassign, needs_map = true},
        ['zones.delete'] = {namespace = 'zones_write', handler = delete, needs_map = true},
    }
end
