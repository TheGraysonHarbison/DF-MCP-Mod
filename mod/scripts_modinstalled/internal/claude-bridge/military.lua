-- Military squads: list, inspect, create, rename, members, leader, disband (plan section 13,
-- item 11.0). DFHack's military module (Lua API, Military.cpp, checked 2026-10-15) covers
-- makeSquad, addToSquad, removeFromSquad, and getSquadName; it refuses the leader slot and
-- has no disband, so those two mirror what its own code does for the inverse operations:
-- the squad entity link on the historical figure, the position assignment's holder, and the
-- holder's position link (the same link nobles.assign writes).
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

DEFAULT_LIMIT = 25
LIST_LIMIT = 25
KINDS = {'melee', 'crossbow'}
UNIFORM_CATEGORIES = {'body', 'head', 'pants', 'gloves', 'shoes', 'shield', 'weapon'}

-- Preset name fragments tried in order for each kind, against fortress_entity.uniforms.
KIND_PRESETS = {
    melee = {'metal armor', 'armor', 'leather'},
    crossbow = {'archer', 'ranged', 'crossbow'},
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

local function translate(name, in_english)
    return safe(function()
        local text = dfhack.translation.translateName(name, in_english)
        if text == '' then return nil end
        return text
    end)
end

local function fort_entity()
    local entity = safe(function() return df.global.plotinfo.main.fortress_entity end)
    if entity then return entity end
    return safe(function() return df.historical_entity.find(df.global.plotinfo.group_id) end)
end

local function unit_ref(unit_id)
    if unit_id == nil or unit_id < 0 then return nil end
    local unit = df.unit.find(unit_id)
    if not unit then return {id = unit_id} end
    return {id = unit.id, name = safe(dfhack.units.getReadableName, unit)}
end

local function histfig_unit(hf_id)
    if hf_id == nil or hf_id < 0 then return nil end
    local fig = df.historical_figure.find(hf_id)
    if not fig then return nil end
    local ref = unit_ref(fig.unit_id)
    if ref then ref.hist_figure_id = hf_id end
    return ref or {hist_figure_id = hf_id, name = translate(fig.name, false)}
end

----------------------------------------------------------------------------------------------
-- reads

local function routines()
    local out = {}
    pcall(function()
        for i, r in ipairs(df.global.plotinfo.alerts.routines) do
            table.insert(out, {index = i, id = r.id, name = r.name})
        end
    end)
    return out
end

local function routine_name(squad)
    local idx = safe(function() return squad.cur_routine_idx end)
    local list = routines()
    if idx ~= nil and list[idx + 1] then return list[idx + 1].name end
    return nil
end

local function squad_name(squad)
    local name = safe(dfhack.military.getSquadName, squad.id)
    if name == nil or name == '' then name = translate(squad.name, true) end
    if name == nil or name == '' then name = 'Squad ' .. squad.id end
    return name
end

-- Readable uniform spec of one slot entry.
local function spec_row(spec)
    local item_type = enum_name(df.item_type, spec.item_type)
    local subtype = nil
    if spec.item_subtype >= 0 then
        local def = safe(dfhack.items.getSubtypeDef, spec.item_type, spec.item_subtype)
        subtype = def and safe(function() return def.name end) or spec.item_subtype
    end
    local material = nil
    if spec.mattype >= 0 then
        material = safe(function() return dfhack.matinfo.decode(spec.mattype, spec.matindex):toString() end)
    end
    local choice = {}
    for _, f in ipairs({'any', 'melee', 'ranged'}) do
        if safe(function() return spec.indiv_choice[f] end) then table.insert(choice, f) end
    end
    return {
        item_type = item_type, item = subtype,
        material_class = enum_name(df.entity_material_category, spec.material_class),
        material = material,
        individual_choice = #choice > 0 and choice or nil,
        specific_item = spec.item >= 0 and spec.item or nil,
        assigned = safe(function() return #spec.assigned end) or 0,
    }
end

local function uniform_of(position)
    local out = {}
    for i, cat in ipairs(UNIFORM_CATEGORIES) do
        local specs = safe(function() return position.equipment.uniform[i - 1] end)
        local rows = {}
        if specs then
            for _, spec in ipairs(specs) do table.insert(rows, spec_row(spec)) end
        end
        out[cat] = rows
    end
    return out
end

-- A squad is "crossbow" when any weapon slot names a ranged weapon or chooses ranged.
local function kind_of(squad)
    local ranged, melee = false, false
    pcall(function()
        for _, position in ipairs(squad.positions) do
            for _, spec in ipairs(position.equipment.uniform[df.uniform_category.weapon]) do
                if spec.indiv_choice.ranged then ranged = true end
                if spec.indiv_choice.melee then melee = true end
                if spec.item_type == df.item_type.WEAPON and spec.item_subtype >= 0 then
                    local def = dfhack.items.getSubtypeDef(spec.item_type, spec.item_subtype)
                    if def and def.ranged_ammo ~= '' then ranged = true else melee = true end
                end
            end
        end
    end)
    if ranged and not melee then return 'crossbow' end
    if melee then return 'melee' end
    return 'unarmed'
end

local function members_of(squad)
    local out, count = {}, 0
    for i, position in ipairs(squad.positions) do
        local who = histfig_unit(position.occupant)
        if who then
            count = count + 1
            table.insert(out, {slot = i - 1, leader = i == 1, unit = who})
        end
    end
    return out, count
end

local function summary(squad)
    local members, count = members_of(squad)
    local leader = squad.positions[0] and histfig_unit(squad.positions[0].occupant) or nil
    return {
        id = squad.id,
        name = squad_name(squad),
        nickname = squad.alias ~= '' and squad.alias or nil,
        kind = kind_of(squad),
        members = count,
        slots = #squad.positions,
        leader = leader,
        routine = routine_name(squad),
        training = safe(function() return squad.activity end) ~= -1,
        orders = safe(function() return #squad.orders end) or 0,
        symbol = safe(function() return squad.symbol end),
        foreground = safe(function() return {squad.foreground_r, squad.foreground_g, squad.foreground_b} end),
        background = safe(function() return {squad.background_r, squad.background_g, squad.background_b} end),
    }
end

local function ammo_of(squad)
    local out = {}
    pcall(function()
        for _, spec in ipairs(squad.ammo.ammunition) do
            local def = spec.item_subtype >= 0 and safe(dfhack.items.getSubtypeDef, spec.item_type, spec.item_subtype)
            table.insert(out, {
                item = def and safe(function() return def.name_plural end) or enum_name(df.item_type, spec.item_type),
                material_class = enum_name(df.entity_material_category, spec.material_class),
                amount = spec.amount,
                combat = spec.flags.use_combat == true,
                training = spec.flags.use_training == true,
                assigned = #spec.assigned,
            })
        end
    end)
    return out
end

local function rooms_of(squad)
    local out = {}
    pcall(function()
        for _, room in ipairs(squad.rooms) do
            local modes = {}
            for _, f in ipairs({'sleep', 'train', 'indiv_eq', 'squad_eq'}) do
                if room.mode[f] then table.insert(modes, f) end
            end
            table.insert(out, {zone_id = room.building_id, modes = modes})
        end
    end)
    return out
end

-- Fort position assignments that can lead a squad and are not taken by one.
local function vacant_assignments(entity)
    local out = {}
    pcall(function()
        local positions = {}
        for _, p in ipairs(entity.positions.own) do positions[p.id] = p end
        for _, a in ipairs(entity.positions.assignments) do
            local p = positions[a.position_id]
            if p and p.squad_size > 0 and a.squad_id == -1 then
                table.insert(out, {assignment_id = a.id, position = p.code,
                                   name = p.name[0] ~= '' and p.name[0] or p.code,
                                   squad_size = p.squad_size,
                                   holder = histfig_unit(a.histfig),
                                   guard = p.code == 'CAPTAIN_OF_THE_GUARD'})
            end
        end
    end)
    -- Militia seats first; the captain of the guard leads the fortress guard.
    table.sort(out, function(a, b)
        if a.guard ~= b.guard then return not a.guard end
        return a.assignment_id < b.assignment_id
    end)
    return out
end

local function presets(entity)
    local out = {}
    pcall(function()
        for _, u in ipairs(entity.uniforms) do
            local slots = {}
            for i, cat in ipairs(UNIFORM_CATEGORIES) do
                local n = #u.uniform_item_types[i - 1]
                if n > 0 then slots[cat] = n end
            end
            table.insert(out, {id = u.id, name = u.name, type = enum_name(df.entity_uniform_type, u.type),
                               slots = slots})
        end
    end)
    return out
end

local function find_squad(id)
    local squad = safe(df.squad.find, id)
    return squad
end

local function fort_squads(entity)
    local out = {}
    pcall(function()
        for _, id in ipairs(entity.squads) do
            local squad = df.squad.find(id)
            if squad then table.insert(out, squad) end
        end
    end)
    return out
end

local function list(args)
    local entity = fort_entity()
    if not entity then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no fort government entity is loaded') end
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    if limit < 1 then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be positive') end
    local rows, total = {}, 0
    for _, squad in ipairs(fort_squads(entity)) do
        total = total + 1
        if #rows < limit then table.insert(rows, summary(squad)) end
    end
    return {
        count = #rows, total = total, truncated = total > #rows, squads = rows,
        vacant_positions = vacant_assignments(entity),
        routines = routines(),
        presets = presets(entity),
        note = 'a squad needs a vacant military position (militia commander or captain) to be created; '
            .. 'kind follows the weapon slot of the uniform',
    }
end

local function get(args)
    local id = tonumber(args.id)
    if not id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a number') end
    local squad = find_squad(math.floor(id))
    if not squad then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no squad with id ' .. id) end
    local out = summary(squad)
    out.positions = {}
    for i, position in ipairs(squad.positions) do
        table.insert(out.positions, {
            slot = i - 1, leader = i == 1,
            unit = histfig_unit(position.occupant),
            uniform = uniform_of(position),
            exact_matches = safe(function() return position.equipment.flags.exact_matches end) == true,
            replace_clothing = safe(function() return position.equipment.flags.replace_clothing end) == true,
            assigned_items = safe(function() return #position.equipment.assigned_items end) or 0,
        })
    end
    out.ammunition = ammo_of(squad)
    out.orders = orders_of(squad)
    out.rooms = rooms_of(squad)
    out.supplies = {
        carry_food = safe(function() return squad.supplies.carry_food end),
        carry_water = enum_name(df.squad_water_level_type, safe(function() return squad.supplies.carry_water end)),
    }
    return out
end

----------------------------------------------------------------------------------------------
-- writes

local function citizen_for(args)
    local unit_id = tonumber(args.unit_id)
    if not unit_id then return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"unit_id" must be a number') end
    local unit = df.unit.find(math.floor(unit_id))
    if not unit then return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. unit_id) end
    if not safe(dfhack.units.isCitizen, unit, true) then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, 'unit ' .. unit_id .. ' is not a citizen')
    end
    if safe(dfhack.units.isBaby, unit) or safe(dfhack.units.isChild, unit) then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, 'unit ' .. unit_id .. ' is a child')
    end
    if unit.hist_figure_id < 0 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, 'unit ' .. unit_id .. ' has no historical figure')
    end
    return unit
end

local function squad_for(args)
    local id = tonumber(args.id)
    if not id then return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a number') end
    local squad = find_squad(math.floor(id))
    if not squad then return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'no squad with id ' .. id) end
    return squad
end

local function touch_equipment(squad)
    pcall(function()
        for _, f in ipairs({'weapon', 'armor', 'shoes', 'shield', 'helm', 'gloves', 'ammo', 'pants',
                            'backpack', 'quiver', 'flask'}) do
            squad.ammo.update[f] = true
            df.global.plotinfo.equipment.update[f] = true
        end
    end)
end

-- Copy a fortress uniform preset into every position of the squad (clearing what is there).
local function apply_preset(squad, preset)
    for _, position in ipairs(squad.positions) do
        for i = 0, #UNIFORM_CATEGORIES - 1 do
            local specs = position.equipment.uniform[i]
            for j = #specs - 1, 0, -1 do
                local spec = specs[j]
                specs:erase(j)
                pcall(function() spec:delete() end)
            end
            local types = preset.uniform_item_types[i]
            for k = 0, #types - 1 do
                local info = preset.uniform_item_info[i][k]
                specs:insert('#', {
                    new = df.squad_uniform_spec,
                    item = -1,
                    item_type = types[k],
                    item_subtype = preset.uniform_item_subtypes[i][k],
                    material_class = info and info.material_class or df.entity_material_category.None,
                    mattype = info and info.mattype or -1,
                    matindex = info and info.matindex or -1,
                    color = -1,
                })
                -- Bitfields cannot be set through insert's field table.
                specs[#specs - 1].indiv_choice.whole = info and info.indiv_choice.whole or 0
            end
        end
        position.equipment.flags.replace_clothing = preset.flags.replace_clothing
        position.equipment.flags.exact_matches = preset.flags.exact_matches
    end
end

local function find_preset(entity, name)
    local wanted = name:lower()
    local found = nil
    pcall(function()
        for _, u in ipairs(entity.uniforms) do
            if u.name:lower() == wanted then found = u return end
        end
        for _, u in ipairs(entity.uniforms) do
            if u.name:lower():find(wanted, 1, true) then found = u return end
        end
    end)
    return found
end

local function preset_for_kind(entity, kind)
    for _, fragment in ipairs(KIND_PRESETS[kind] or {}) do
        local p = find_preset(entity, fragment)
        if p then return p end
    end
    return nil
end

local function bolt_subtype()
    local found = -1
    pcall(function()
        for _, def in ipairs(df.global.world.raws.itemdefs.ammo) do
            if def.id == 'ITEM_AMMO_BOLTS' then found = def.subtype return end
        end
    end)
    return found
end

local function add_ammo(squad, subtype, amount)
    squad.ammo.ammunition:insert('#', {
        new = df.squad_ammo_spec,
        item_type = df.item_type.AMMO,
        item_subtype = subtype,
        material_class = df.entity_material_category.None,
        mattype = -1, matindex = -1,
        amount = amount,
    })
    local spec = squad.ammo.ammunition[#squad.ammo.ammunition - 1]
    spec.flags.use_combat = true
    spec.flags.use_training = true
end

-- Allocate a militia captain assignment (number -1 positions have no fixed seats; the
-- game creates one for each squad beyond the commander's).
function new_captain_assignment(entity)
    local made = nil
    pcall(function()
        local position, index = nil, nil
        for i, p in ipairs(entity.positions.own) do
            if p.code == 'MILITIA_CAPTAIN' and p.squad_size > 0 then position, index = p, i - 1 end
        end
        if not position then return end
        local id = entity.positions.next_assignment_id
        entity.positions.assignments:insert('#', {
            new = df.entity_position_assignment,
            id = id, histfig = -1, histfig2 = -1,
            position_id = position.id, position_vector_idx = index, squad_id = -1,
        })
        entity.positions.next_assignment_id = id + 1
        made = entity.positions.assignments[#entity.positions.assignments - 1]
    end)
    return made
end

local function create(args)
    local entity = fort_entity()
    if not entity then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no fort government entity is loaded') end
    local kind = args.kind ~= nil and tostring(args.kind):lower() or nil
    if kind ~= nil and kind ~= 'melee' and kind ~= 'crossbow' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be melee or crossbow')
    end
    if args.preset ~= nil and type(args.preset) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"preset" must be a uniform preset name')
    end
    if args.name ~= nil and type(args.name) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a string')
    end
    local vacant = vacant_assignments(entity)
    local wanted = args.position ~= nil and tostring(args.position):upper():gsub('[%s%-]+', '_') or nil
    local militia_vacant = false
    for _, v in ipairs(vacant) do if not v.guard then militia_vacant = true end end
    -- The game adds a militia captain seat per extra squad; do the same when none is free.
    if (not militia_vacant and wanted == nil) or wanted == 'MILITIA_CAPTAIN' then
        local made = new_captain_assignment(entity)
        if made then
            vacant = vacant_assignments(entity)
            if wanted == nil then
                for _, v in ipairs(vacant) do
                    if v.assignment_id == made.id then vacant = {v} end
                end
            end
        end
    end
    if #vacant == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'no vacant military position: every militia commander and captain seat already leads a squad')
    end
    if args.position ~= nil then
        local wanted = tostring(args.position):upper():gsub('[%s%-]+', '_')
        local chosen = nil
        for _, v in ipairs(vacant) do
            if v.position == wanted or tostring(v.assignment_id) == tostring(args.position) then chosen = v end
        end
        if not chosen then
            return rpc.error_result(rpc.ERR_NOT_FOUND, 'no vacant military position ' .. tostring(args.position))
        end
        vacant = {chosen}
    end
    local preset = nil
    if args.preset then
        preset = find_preset(entity, args.preset)
        if not preset then
            local names = {}
            for _, p in ipairs(presets(entity)) do table.insert(names, p.name) end
            return rpc.error_result(rpc.ERR_NOT_FOUND,
                ('no uniform preset "%s"; known: %s'):format(args.preset, table.concat(names, ', ')))
        end
    elseif kind then
        preset = preset_for_kind(entity, kind)
    end
    local squad = dfhack.military.makeSquad(vacant[1].assignment_id)
    if not squad then
        return rpc.error_result(rpc.ERR_INTERNAL, 'dfhack.military.makeSquad refused assignment ' .. vacant[1].assignment_id)
    end
    local warnings = {}
    if args.name and args.name ~= '' then squad.alias = dfhack.utf2df(args.name) end
    if preset then
        apply_preset(squad, preset)
    elseif kind then
        table.insert(warnings, 'no uniform preset matched kind ' .. kind .. '; the squad has no uniform yet')
    end
    if kind == 'crossbow' then
        local bolts = bolt_subtype()
        if bolts >= 0 then
            add_ammo(squad, bolts, 100)
        else
            table.insert(warnings, 'no bolt ammunition definition found; add ammunition by hand')
        end
    end
    -- A seat that already has a holder (the game appointed a militia commander) makes
    -- that dwarf the squad's leader, as the vanilla screen does.
    local holder = vacant[1].holder
    if holder and holder.id then
        local led = set_leader({id = squad.id, unit_id = holder.id})
        if type(led) == 'table' and led.__error then
            table.insert(warnings, 'the seat holder could not be made leader: ' .. tostring(led.message))
        end
    end
    touch_equipment(squad)
    local out = summary(squad)
    out.position = vacant[1]
    out.preset = preset and preset.name or nil
    out.warnings = warnings
    out.note = out.leader and 'squad created; add members with add_to_squad'
        or 'squad created with no members; set a leader with set_squad_leader, then add members'
    return out
end

local function rename(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    if type(args.name) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"name" must be a string (empty clears the nickname)')
    end
    local before = squad.alias
    squad.alias = dfhack.utf2df(args.name)
    local out = summary(squad)
    out.previous = before ~= '' and before or nil
    return out
end

local function parse_rgb(value, field)
    if value == nil then return nil end
    if type(value) ~= 'table' or #value ~= 3 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, ('"%s" must be [r, g, b] with values 0-255'):format(field))
    end
    local out = {}
    for i = 1, 3 do
        local n = tonumber(value[i])
        if not n or n < 0 or n > 255 then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, ('"%s" must be [r, g, b] with values 0-255'):format(field))
        end
        out[i] = math.floor(n)
    end
    return out
end

-- The badge the game draws for the squad: a symbol index on the vanilla squad symbol sheet
-- (0 to 22, row-wise; graphics mode only) and foreground and background colours.
local function set_symbol(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local symbol = nil
    if args.symbol ~= nil then
        symbol = tonumber(args.symbol)
        if not symbol or symbol < 0 or symbol > 22 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"symbol" must be 0-22')
        end
        symbol = math.floor(symbol)
    end
    local fg, ferr = parse_rgb(args.foreground, 'foreground')
    if ferr then return ferr end
    local bg, berr = parse_rgb(args.background, 'background')
    if berr then return berr end
    if symbol == nil and fg == nil and bg == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "symbol" and/or "foreground" and/or "background"')
    end
    local before = {symbol = squad.symbol,
                    foreground = {squad.foreground_r, squad.foreground_g, squad.foreground_b},
                    background = {squad.background_r, squad.background_g, squad.background_b}}
    if symbol ~= nil then squad.symbol = symbol end
    -- Never touch squad.solid_texpos or blended_texpos: resetting them crashed the game on
    -- 2026-10-15 (CLAUDE.md rule 13). The badge redraws when the game next regenerates it.
    if fg then squad.foreground_r, squad.foreground_g, squad.foreground_b = fg[1], fg[2], fg[3] end
    if bg then squad.background_r, squad.background_g, squad.background_b = bg[1], bg[2], bg[3] end
    local out = summary(squad)
    out.previous = before
    out.note = 'the badge on screen may keep its old look until the game redraws it; the texture cache is never touched'
    return out
end

local function add(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local unit, uerr = citizen_for(args)
    if not unit then return uerr end
    if unit.military.squad_id ~= -1 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('unit %d is already in squad %d; remove them first'):format(unit.id, unit.military.squad_id))
    end
    local slot = args.slot ~= nil and tonumber(args.slot) or nil
    if slot ~= nil then
        slot = math.floor(slot)
        if slot < 0 or slot >= #squad.positions then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('"slot" must be 0-%d'):format(#squad.positions - 1))
        end
        if squad.positions[slot].occupant ~= -1 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'slot ' .. slot .. ' is occupied')
        end
    end
    -- DFHack never fills slot 0; an empty squad gets this unit as its leader instead.
    if slot == 0 or (slot == nil and squad.positions[0].occupant == -1) then
        return set_leader(args)
    end
    local ok = dfhack.military.addToSquad(unit.id, squad.id, slot or -1)
    if not ok then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'the squad has no free slot, or the unit could not be added')
    end
    local out = summary(squad)
    out.added = unit_ref(unit.id)
    out.slot = unit.military.squad_position
    return out
end

local function remove(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local unit_id = tonumber(args.unit_id)
    if not unit_id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"unit_id" must be a number') end
    local unit = df.unit.find(math.floor(unit_id))
    if not unit then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. unit_id) end
    if unit.military.squad_id ~= squad.id then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, ('unit %d is not in squad %d'):format(unit.id, squad.id))
    end
    local was_leader = unit.military.squad_position == 0
    local ok = dfhack.military.removeFromSquad(unit.id)
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, 'dfhack.military.removeFromSquad failed') end
    touch_equipment(squad)
    local out = summary(squad)
    out.removed = unit_ref(unit.id)
    out.was_leader = was_leader
    return out
end

-- The leader slot, the way the game's own bookkeeping looks after removeFromSquad undoes
-- it: slot 0 occupant, the unit's military fields, a SQUAD entity link at position 0, the
-- leading assignment's holder, and a POSITION entity link for that assignment.
function set_leader(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local unit, uerr = citizen_for(args)
    if not unit then return uerr end
    local entity = fort_entity()
    if unit.military.squad_id ~= -1 and unit.military.squad_id ~= squad.id then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('unit %d is already in squad %d; remove them first'):format(unit.id, unit.military.squad_id))
    end
    local previous = nil
    local current = squad.positions[0].occupant
    if current ~= -1 then
        local fig = df.historical_figure.find(current)
        if fig and fig.unit_id == unit.id then
            local out = summary(squad)
            out.changed = false
            return out
        end
        previous = histfig_unit(current)
        if fig and fig.unit_id >= 0 then
            dfhack.military.removeFromSquad(fig.unit_id)
        else
            squad.positions[0].occupant = -1
        end
    end
    -- A member moving up to the leader slot leaves their old slot first.
    if unit.military.squad_id == squad.id then
        dfhack.military.removeFromSquad(unit.id)
    end
    local fig = df.historical_figure.find(unit.hist_figure_id)
    squad.positions[0].occupant = fig.id
    unit.military.squad_id = squad.id
    unit.military.squad_position = 0
    fig.entity_links:insert('#', {
        new = df.histfig_entity_link_squadst,
        entity_id = squad.entity_id,
        squad_id = squad.id,
        squad_position = 0,
        start_year = df.global.cur_year,
        link_strength = 100,
    })
    local assignment, index = nil, nil
    pcall(function()
        for i, a in ipairs(entity.positions.assignments) do
            if a.id == squad.leader_assignment then assignment, index = a, i - 1 return end
        end
    end)
    if assignment and assignment.histfig ~= fig.id then
        assignment.histfig2 = assignment.histfig
        assignment.histfig = fig.id
        -- A dwarf the game already appointed to the seat keeps their existing link.
        local linked = false
        for _, link in ipairs(fig.entity_links) do
            if df.histfig_entity_link_positionst:is_instance(link)
                    and link.entity_id == entity.id and link.assignment_id == assignment.id then
                linked = true
            end
        end
        if not linked then
            fig.entity_links:insert('#', {
                new = df.histfig_entity_link_positionst,
                entity_id = entity.id,
                link_strength = 100,
                assignment_id = assignment.id,
                assignment_vector_idx = index,
                start_year = df.global.cur_year,
            })
        end
    end
    touch_equipment(squad)
    local out = summary(squad)
    out.changed = true
    out.previous_leader = previous
    out.assignment_updated = assignment ~= nil and assignment.histfig == fig.id
    return out
end

-- Disband: every member removed through DFHack (the leader's assignment and links with
-- them), rooms detached, the assignment freed, and the squad struck from the fort's and
-- the world's squad lists.
local function disband(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local entity = fort_entity()
    local removed = {}
    for i = #squad.positions - 1, 0, -1 do
        local hf = squad.positions[i].occupant
        if hf ~= -1 then
            local fig = df.historical_figure.find(hf)
            if fig and fig.unit_id >= 0 and dfhack.military.removeFromSquad(fig.unit_id) then
                table.insert(removed, unit_ref(fig.unit_id))
            else
                squad.positions[i].occupant = -1
            end
        end
    end
    local rooms = 0
    pcall(function()
        for i = #squad.rooms - 1, 0, -1 do
            dfhack.military.updateRoomAssignments(squad.id, squad.rooms[i].building_id, {})
            rooms = rooms + 1
        end
    end)
    pcall(function()
        for _, a in ipairs(entity.positions.assignments) do
            -- The leader's removal above already vacated the seat's holder; a seat the
            -- game appointed but that never led (no leader yet) keeps its holder.
            if a.squad_id == squad.id then a.squad_id = -1 end
        end
    end)
    pcall(function()
        local ids = entity.squads
        for i = #ids - 1, 0, -1 do
            if ids[i] == squad.id then ids:erase(i) end
        end
    end)
    local all = df.global.world.squads.all
    local erased = false
    for i = #all - 1, 0, -1 do
        if all[i].id == squad.id then
            all:erase(i)
            erased = true
        end
    end
    local id, name = squad.id, squad_name(squad)
    if erased then pcall(function() squad:delete() end) end
    return {id = id, name = name, disbanded = erased, members_removed = removed, rooms_detached = rooms}
end


----------------------------------------------------------------------------------------------
-- orders, routines, routes (11.1). No DFHack code issues squad orders; these write the
-- order records the game's own squad screen creates: one squad_order_* object appended to
-- squad.orders with the issue date, and nothing else. Verified live before merge.

ORDER_KINDS = {'station', 'kill', 'patrol', 'cancel'}

local function describe_order(o)
    local row = {
        type = enum_name(df.squad_order_type, safe(function() return o:getType() end)),
        year = o.year, year_tick = o.year_tick,
        complete = safe(function() return o.flags.reported_as_complete end) == true,
    }
    if df.squad_order_movest:is_instance(o) then
        row.kind = 'station'
        row.pos = {x = o.pos.x, y = o.pos.y, z = o.pos.z}
    elseif df.squad_order_kill_listst:is_instance(o) then
        row.kind = 'kill'
        row.title = o.title
        row.units = {}
        for _, id in ipairs(o.units) do table.insert(row.units, unit_ref(id)) end
    elseif df.squad_order_patrol_routest:is_instance(o) then
        row.kind = 'patrol'
        row.route_id = o.route_id
    elseif df.squad_order_trainst:is_instance(o) then
        row.kind = 'train'
    elseif df.squad_order_defend_burrowsst:is_instance(o) then
        row.kind = 'defend_burrow'
    else
        row.kind = 'other'
    end
    return row
end

function orders_of(squad)
    local out = {}
    pcall(function()
        for _, o in ipairs(squad.orders) do table.insert(out, describe_order(o)) end
    end)
    return out
end

local function stamp(o)
    o.issuer_hf = -1
    o.recipient_hf = -1
    o.year = df.global.cur_year
    o.year_tick = df.global.cur_year_tick
    o.origin_army_controller = -1
end

local function clear_orders(squad)
    local n = 0
    local function wipe(vec)
        for i = #vec - 1, 0, -1 do
            local o = vec[i]
            vec:erase(i)
            pcall(function() o:delete() end)
            n = n + 1
        end
    end
    wipe(squad.orders)
    for _, position in ipairs(squad.positions) do wipe(position.orders) end
    return n
end

local function find_route(id)
    local found = nil
    pcall(function()
        for _, r in ipairs(df.global.plotinfo.waypoints.routes) do
            if r.id == id then found = r end
        end
    end)
    return found
end

local function order(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local kind = args.kind ~= nil and tostring(args.kind):lower() or nil
    local known = false
    for _, k in ipairs(ORDER_KINDS) do if k == kind then known = true end end
    if not known then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be one of ' .. table.concat(ORDER_KINDS, ', '))
    end
    local _, members = members_of(squad)
    if kind ~= 'cancel' and members == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'squad ' .. squad.id .. ' has no members')
    end
    local new_order = nil
    if kind == 'station' then
        local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
        if not (x and y and z) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'a station order needs "x", "y", "z"')
        end
        local pos = {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
        if not dfhack.maps.isValidTilePos(pos) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the position is outside the map')
        end
        if dfhack.maps.getWalkableGroup(pos) == 0 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the position is not walkable')
        end
        new_order = df.squad_order_movest:new()
        stamp(new_order)
        new_order.pos.x, new_order.pos.y, new_order.pos.z = pos.x, pos.y, pos.z
        new_order.point_id = -1
    elseif kind == 'kill' then
        if type(args.unit_ids) ~= 'table' or #args.unit_ids == 0 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'a kill order needs "unit_ids" (a non-empty list)')
        end
        new_order = df.squad_order_kill_listst:new()
        stamp(new_order)
        local names = {}
        for _, raw in ipairs(args.unit_ids) do
            local id = tonumber(raw)
            local unit = id and df.unit.find(math.floor(id))
            if not unit then
                pcall(function() new_order:delete() end)
                return rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. tostring(raw))
            end
            if safe(dfhack.units.isCitizen, unit, true) then
                pcall(function() new_order:delete() end)
                return rpc.error_result(rpc.ERR_BAD_REQUEST, 'unit ' .. unit.id .. ' is a citizen')
            end
            new_order.units:insert('#', unit.id)
            if unit.hist_figure_id >= 0 then new_order.histfigs:insert('#', unit.hist_figure_id) end
            table.insert(names, safe(dfhack.units.getReadableName, unit) or tostring(unit.id))
        end
        new_order.title = dfhack.utf2df(args.title or ('Kill ' .. table.concat(names, ', ')))
    elseif kind == 'patrol' then
        local route_id = tonumber(args.route_id)
        if not route_id or not find_route(math.floor(route_id)) then
            return rpc.error_result(rpc.ERR_NOT_FOUND, 'no patrol route with id ' .. tostring(args.route_id))
        end
        new_order = df.squad_order_patrol_routest:new()
        stamp(new_order)
        new_order.route_id = math.floor(route_id)
    end
    -- Only a valid order replaces the current ones; a refused request leaves them alone.
    local cleared = clear_orders(squad)
    if new_order then squad.orders:insert('#', new_order) end
    local out = summary(squad)
    out.kind = kind
    out.cancelled = cleared
    out.orders = orders_of(squad)
    out.note = kind == 'cancel' and 'orders cleared; the squad follows its routine again'
        or 'order issued; soldiers follow it when they can (check reason in get_squad if they do not move)'
    return out
end

local function set_routine(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local list = routines()
    local chosen = nil
    if args.routine == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "routine" (a name or index from list_squads)')
    end
    local wanted = tostring(args.routine):lower()
    for _, r in ipairs(list) do
        if r.name:lower() == wanted or tostring(r.index) == wanted then chosen = r end
    end
    if not chosen then
        local names = {}
        for _, r in ipairs(list) do table.insert(names, r.name) end
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            ('no routine "%s"; known: %s'):format(tostring(args.routine), table.concat(names, ', ')))
    end
    local before = routine_name(squad)
    squad.cur_routine_idx = chosen.index
    local out = summary(squad)
    out.previous = before
    return out
end

local function routes(args)
    local out = {}
    pcall(function()
        local points = {}
        for _, pt in ipairs(df.global.plotinfo.waypoints.points) do points[pt.id] = pt end
        for _, r in ipairs(df.global.plotinfo.waypoints.routes) do
            local pts = {}
            for _, id in ipairs(r.points) do
                local pt = points[id]
                table.insert(pts, pt and {id = id, name = pt.name, pos = {x = pt.pos.x, y = pt.pos.y, z = pt.pos.z}}
                    or {id = id})
            end
            table.insert(out, {id = r.id, name = r.name, points = pts})
        end
    end)
    return {count = #out, routes = out}
end

local function create_route(args)
    if type(args.points) ~= 'table' or #args.points < 2 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"points" must be a list of at least two {x, y, z}')
    end
    local parsed = {}
    for i, pt in ipairs(args.points) do
        local x, y, z = tonumber(pt.x), tonumber(pt.y), tonumber(pt.z)
        if not (x and y and z) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('point %d needs x, y, z'):format(i))
        end
        local pos = {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
        if not dfhack.maps.isValidTilePos(pos) or dfhack.maps.getWalkableGroup(pos) == 0 then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('point %d is not a walkable map tile'):format(i))
        end
        table.insert(parsed, pos)
    end
    local wp = df.global.plotinfo.waypoints
    local name = type(args.name) == 'string' and args.name or ('Route ' .. (wp.next_route_id + 1))
    local ids = {}
    for i, pos in ipairs(parsed) do
        local id = wp.next_point_id
        wp.points:insert('#', {
            new = df.pointst, id = id, tile = 88, fg_color = 7, bg_color = 0,
            name = dfhack.utf2df(name .. ' ' .. i), comment = '',
        })
        local pt = wp.points[#wp.points - 1]
        pt.pos.x, pt.pos.y, pt.pos.z = pos.x, pos.y, pos.z
        wp.next_point_id = id + 1
        table.insert(ids, id)
    end
    local route_id = wp.next_route_id
    wp.routes:insert('#', {new = df.routest, id = route_id, name = dfhack.utf2df(name)})
    local route = wp.routes[#wp.routes - 1]
    for _, id in ipairs(ids) do route.points:insert('#', id) end
    wp.next_route_id = route_id + 1
    return {id = route_id, name = name, points = ids, count = #ids}
end


----------------------------------------------------------------------------------------------
-- equipment (11.2): what each slot asks for, what each soldier carries, and ammunition.

-- Item definition vectors per uniform category, and the material class words.
local CATEGORY_DEFS = {
    body = {'armor', 'ARMOR'}, head = {'helms', 'HELM'}, pants = {'pants', 'PANTS'},
    gloves = {'gloves', 'GLOVES'}, shoes = {'shoes', 'SHOES'}, shield = {'shields', 'SHIELD'},
    weapon = {'weapons', 'WEAPON'},
}
MATERIAL_CLASSES = {'any', 'metal', 'leather', 'cloth', 'wood', 'bone', 'shell'}

local function category_index(name)
    for i, cat in ipairs(UNIFORM_CATEGORIES) do
        if cat == name then return i - 1 end
    end
    return nil
end

-- Resolve "breastplate", "iron helm" (material words are not item names), "any armor",
-- "crossbow", "melee", "ranged" for a category into item_type, subtype, choice flags, def.
local function resolve_item(category, name)
    local defs_name, type_token = CATEGORY_DEFS[category][1], CATEGORY_DEFS[category][2]
    local item_type = df.item_type[type_token]
    local wanted = name:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if category == 'weapon' then
        if wanted == 'melee' or wanted == 'individual melee' then return item_type, -1, 'melee', nil end
        if wanted == 'ranged' or wanted == 'individual ranged' then return item_type, -1, 'ranged', nil end
        if wanted == 'any' or wanted == 'individual' or wanted == 'individual choice' then return item_type, -1, 'any', nil end
    end
    if wanted == 'any' or wanted == ('any ' .. category) or wanted == ('any ' .. type_token:lower()) then
        return item_type, -1, nil, nil
    end
    local singular = wanted:gsub('s$', '')
    local found = nil
    pcall(function()
        for _, def in ipairs(df.global.world.raws.itemdefs[defs_name]) do
            local n, np, id = def.name:lower(), def.name_plural:lower(), def.id:lower()
            if n == wanted or np == wanted or n == singular or id == wanted:upper():gsub(' ', '_'):lower() then
                found = def
                return
            end
        end
        for _, def in ipairs(df.global.world.raws.itemdefs[defs_name]) do
            if def.name:lower():find(wanted, 1, true) then found = def return end
        end
    end)
    if not found then return nil end
    return item_type, found.subtype, nil, found
end

local function known_items(category)
    local names, seen = {}, {}
    pcall(function()
        for _, def in ipairs(df.global.world.raws.itemdefs[CATEGORY_DEFS[category][1]]) do
            if not seen[def.name] then
                seen[def.name] = true
                table.insert(names, def.name)
            end
        end
    end)
    table.sort(names)
    return names
end

local function material_class_for(category, word, def)
    local w = word and tostring(word):lower() or 'any'
    if w == 'any' or w == 'none' then return df.entity_material_category.None end
    if w == 'metal' then
        if category == 'weapon' then
            local ranged = def and safe(function() return def.ranged_ammo ~= '' end)
            return ranged and df.entity_material_category.WeaponRanged or df.entity_material_category.WeaponMelee
        end
        return df.entity_material_category.Armor
    end
    if w == 'leather' then return df.entity_material_category.Leather end
    if w == 'cloth' then return df.entity_material_category.Cloth end
    if w == 'wood' then return df.entity_material_category.Wood end
    if w == 'bone' then return df.entity_material_category.Bone end
    if w == 'shell' then return df.entity_material_category.Shell end
    return nil
end

local function item_desc(id)
    local item = df.item.find(id)
    if not item then return {id = id} end
    return {id = id, description = safe(dfhack.items.getReadableDescription, item)}
end

local function soldier_items(unit)
    local out = {carried = {}, missing = {}, mode = nil}
    pcall(function()
        out.mode = enum_name(df.unit_uniform_mode_type, unit.uniform.cur_uniform)
        local mode = unit.uniform.cur_uniform
        if mode >= 0 then
            for _, id in ipairs(unit.uniform.uniforms[mode]) do
                if #out.carried < LIST_LIMIT then table.insert(out.carried, item_desc(id)) end
            end
        end
        for _, id in ipairs(unit.uniform.uniform_pickup) do
            if #out.missing < LIST_LIMIT then table.insert(out.missing, item_desc(id)) end
        end
    end)
    out.worn = {}
    pcall(function()
        for _, entry in ipairs(unit.inventory) do
            local mode = enum_name(df.unit_inventory_item.T_mode, entry.mode)
            if (mode == 'Worn' or mode == 'Weapon') and #out.worn < LIST_LIMIT then
                local d = item_desc(entry.item.id)
                d.mode = mode
                table.insert(out.worn, d)
            end
        end
    end)
    return out
end

local function equipment(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local out = summary(squad)
    out.positions = {}
    for i, position in ipairs(squad.positions) do
        local who = histfig_unit(position.occupant)
        local row = {
            slot = i - 1, leader = i == 1, unit = who, uniform = uniform_of(position),
            exact_matches = safe(function() return position.equipment.flags.exact_matches end) == true,
            replace_clothing = safe(function() return position.equipment.flags.replace_clothing end) == true,
            assigned_items = {},
        }
        pcall(function()
            for _, id in ipairs(position.equipment.assigned_items) do
                if #row.assigned_items < LIST_LIMIT then table.insert(row.assigned_items, item_desc(id)) end
            end
        end)
        if who and who.id then
            local unit = df.unit.find(who.id)
            if unit then row.soldier = soldier_items(unit) end
        end
        table.insert(out.positions, row)
    end
    out.ammunition = ammo_of(squad)
    out.material_classes = MATERIAL_CLASSES
    out.note = 'uniform is what each slot asks for; soldier.carried are the items the game assigned '
        .. 'for the current uniform mode, soldier.missing the ones not yet picked up'
    return out
end

local function set_uniform(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local category = args.category ~= nil and tostring(args.category):lower() or nil
    local cat_index = category and category_index(category)
    if not cat_index then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"category" must be one of ' .. table.concat(UNIFORM_CATEGORIES, ', '))
    end
    local positions = {}
    if args.position ~= nil then
        local slot = tonumber(args.position)
        if not slot or slot < 0 or slot >= #squad.positions then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('"position" must be 0-%d'):format(#squad.positions - 1))
        end
        positions = {squad.positions[math.floor(slot)]}
    else
        for _, position in ipairs(squad.positions) do table.insert(positions, position) end
    end
    local clear = args.clear == true
    local item = args.item
    if item ~= nil and type(item) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"item" must be a string')
    end
    if item == nil and not clear and args.exact_matches == nil and args.replace_clothing == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "item" (with optional "material_class"), "clear", or a flag')
    end
    local spec = nil
    if item then
        local item_type, subtype, choice, def = resolve_item(category, item)
        if not item_type then
            local names = known_items(category)
            local shown = {}
            for i = 1, math.min(#names, 30) do shown[i] = names[i] end
            return rpc.error_result(rpc.ERR_NOT_FOUND,
                ('no %s item called "%s"; try "any", %s'):format(category, item, table.concat(shown, ', ')))
        end
        local mat = material_class_for(category, args.material_class, def)
        if mat == nil then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"material_class" must be one of ' .. table.concat(MATERIAL_CLASSES, ', '))
        end
        spec = {item_type = item_type, subtype = subtype, choice = choice, material_class = mat,
                name = def and def.name or (choice and ('individual ' .. choice) or ('any ' .. category))}
    end
    local written = 0
    for _, position in ipairs(positions) do
        local specs = position.equipment.uniform[cat_index]
        if clear or (spec and args.add ~= true) then
            for j = #specs - 1, 0, -1 do
                local old = specs[j]
                specs:erase(j)
                pcall(function() old:delete() end)
            end
        end
        if spec then
            specs:insert('#', {
                new = df.squad_uniform_spec, item = -1,
                item_type = spec.item_type, item_subtype = spec.subtype,
                material_class = spec.material_class, mattype = -1, matindex = -1, color = -1,
            })
            local s = specs[#specs - 1]
            if spec.choice then s.indiv_choice[spec.choice] = true end
            written = written + 1
        end
        if args.exact_matches ~= nil then position.equipment.flags.exact_matches = args.exact_matches == true end
        if args.replace_clothing ~= nil then position.equipment.flags.replace_clothing = args.replace_clothing == true end
    end
    touch_equipment(squad)
    local out = summary(squad)
    out.category = category
    out.positions_changed = #positions
    out.specs_written = written
    out.spec = spec and {item = spec.name, material_class = enum_name(df.entity_material_category, spec.material_class)} or nil
    out.uniform = uniform_of(positions[1])
    return out
end

local function set_ammo(args)
    local squad, err = squad_for(args)
    if not squad then return err end
    local clear = args.clear == true
    if args.item == nil and not clear then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "item" (bolts, arrows, ...) with "amount", or "clear"')
    end
    local spec = nil
    if args.item ~= nil then
        local wanted = tostring(args.item):lower()
        local def = nil
        pcall(function()
            for _, d in ipairs(df.global.world.raws.itemdefs.ammo) do
                if d.name:lower() == wanted or d.name_plural:lower() == wanted or d.id:lower() == wanted then def = d return end
            end
        end)
        if not def then
            local names, seen = {}, {}
            pcall(function()
                for _, d in ipairs(df.global.world.raws.itemdefs.ammo) do
                    if not seen[d.name_plural] then
                        seen[d.name_plural] = true
                        table.insert(names, d.name_plural)
                    end
                end
            end)
            return rpc.error_result(rpc.ERR_NOT_FOUND, ('no ammunition called "%s"; known: %s'):format(args.item, table.concat(names, ', ')))
        end
        local amount = tonumber(args.amount) or 100
        if amount < 1 then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"amount" must be positive') end
        local mat = df.entity_material_category.None
        local w = args.material_class and tostring(args.material_class):lower() or 'any'
        if w == 'metal' then mat = df.entity_material_category.AmmoMetal
        elseif w == 'bone' then mat = df.entity_material_category.Bone
        elseif w == 'wood' then mat = df.entity_material_category.Wood
        elseif w ~= 'any' and w ~= 'none' then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, '"material_class" for ammunition must be any, metal, wood, or bone')
        end
        spec = {def = def, amount = math.floor(amount), mat = mat,
                combat = args.combat ~= false, training = args.training ~= false}
    end
    if clear or (spec and args.add ~= true) then
        local list = squad.ammo.ammunition
        for j = #list - 1, 0, -1 do
            local old = list[j]
            list:erase(j)
            pcall(function() old:delete() end)
        end
    end
    if spec then
        squad.ammo.ammunition:insert('#', {
            new = df.squad_ammo_spec, item_type = df.item_type.AMMO, item_subtype = spec.def.subtype,
            material_class = spec.mat, mattype = -1, matindex = -1, amount = spec.amount,
        })
        local s = squad.ammo.ammunition[#squad.ammo.ammunition - 1]
        s.flags.use_combat = spec.combat
        s.flags.use_training = spec.training
    end
    touch_equipment(squad)
    local out = summary(squad)
    out.ammunition = ammo_of(squad)
    return out
end

function ops()
    return {
        ['military.list'] = {namespace = 'military', handler = list, needs_map = true},
        ['military.get'] = {namespace = 'military', handler = get, needs_map = true},
        ['military.create'] = {namespace = 'military_write', handler = create, needs_map = true},
        ['military.rename'] = {namespace = 'military_write', handler = rename, needs_map = true},
        ['military.set_symbol'] = {namespace = 'military_write', handler = set_symbol, needs_map = true},
        ['military.add'] = {namespace = 'military_write', handler = add, needs_map = true},
        ['military.remove'] = {namespace = 'military_write', handler = remove, needs_map = true},
        ['military.set_leader'] = {namespace = 'military_write', handler = set_leader, needs_map = true},
        ['military.disband'] = {namespace = 'military_write', handler = disband, needs_map = true},
        ['military.order'] = {namespace = 'military_write', handler = order, needs_map = true},
        ['military.equipment'] = {namespace = 'military', handler = equipment, needs_map = true},
        ['military.set_uniform'] = {namespace = 'military_write', handler = set_uniform, needs_map = true},
        ['military.set_ammo'] = {namespace = 'military_write', handler = set_ammo, needs_map = true},
        ['military.set_routine'] = {namespace = 'military_write', handler = set_routine, needs_map = true},
        ['military.routes'] = {namespace = 'military', handler = routes, needs_map = true},
        ['military.create_route'] = {namespace = 'military_write', handler = create_route, needs_map = true},
    }
end
