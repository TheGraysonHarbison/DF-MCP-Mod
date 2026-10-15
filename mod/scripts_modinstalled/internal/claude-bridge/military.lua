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
    }
end
