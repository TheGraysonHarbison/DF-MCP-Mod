-- Activity zones: list with filters and inspect one (tiles, owner, assigned units, squads,
-- location, per-type settings). Plan section 12, item 8.0. Fields from df-structures
-- building_civzonest (checked 2026-10-14): type, zone_num, spec_sub_flag.active,
-- room.extents, assigned_unit_id (the owner), assigned_units (pens, pits, ponds),
-- assigned_items (vermin), squad_room_info, location_id, contained_buildings, and the
-- zone_settings union (pen, pond, gather, archery, tomb).
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local build = reqscript('internal/claude-bridge/build')

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
    row.room_description = safe(function()
        local d = B.getRoomDescription(zone)
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

function ops()
    return {
        ['zones.list'] = {namespace = 'zones', handler = list, needs_map = true},
        ['zones.get'] = {namespace = 'zones', handler = get, needs_map = true},
    }
end
