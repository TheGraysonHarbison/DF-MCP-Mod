-- Unit sheet: the in-game profile tabs as JSON. Read-only. Design: docs/ProjectPlan.md 8.5.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local units = reqscript('internal/claude-bridge/units')

local U = dfhack.units

-- Tabs and sub-tabs of the 53.16 unit profile, in the game's order.
CATEGORIES = {
    {name = 'overview'},
    {name = 'relations'},
    {name = 'groups'},
    {name = 'military', subs = {'squads', 'uniform', 'kills'}},
    {name = 'thoughts', subs = {'recent', 'memories'}},
    {name = 'personality', subs = {'traits', 'values', 'preferences', 'needs'}},
    {name = 'items'},
    {name = 'health', subs = {'status', 'wounds', 'treatment', 'history', 'description'}},
    {name = 'skills', subs = {'labor', 'combat', 'social', 'other', 'knowledge'}},
    {name = 'rooms'},
    {name = 'labor', subs = {'work_details', 'workshops', 'locations', 'work_animals'}},
}

DEFAULT_LIMIT = 50

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function category_spec(name)
    for _, spec in ipairs(CATEGORIES) do
        if spec.name == name then return spec end
    end
    return nil
end

local function category_names()
    local out = {}
    for _, spec in ipairs(CATEGORIES) do table.insert(out, spec.name) end
    return out
end

-- ctx: {limit, truncated = {paths}, best_effort = {paths}}
local function new_ctx(limit)
    return {limit = limit, truncated = {}, best_effort = {}}
end

-- Wrap a list section, cutting it at ctx.limit and recording the path when it was cut.
local function capped(ctx, path, list)
    local total = #list
    local entries = list
    local truncated = false
    if ctx.limit and total > ctx.limit then
        entries = {}
        for i = 1, ctx.limit do entries[i] = list[i] end
        truncated = true
        table.insert(ctx.truncated, path)
    end
    return {entries = entries, total = total, truncated = truncated}
end

local function stub(ctx, path, note)
    table.insert(ctx.best_effort, path)
    return {best_effort = true, note = note}
end

local function enum_name(enum, value)
    if value == nil then return nil end
    local name = safe(function() return enum[value] end)
    if name == nil then return tostring(value) end
    return name
end

-- Names of the set bits of a DFHack bitfield, sorted.
local function true_flags(bitfield)
    local out = {}
    local ok = pcall(function()
        for name, value in pairs(bitfield) do
            if value == true or (type(value) == 'number' and value ~= 0) then
                table.insert(out, name)
            end
        end
    end)
    if not ok then return nil end
    table.sort(out)
    return out
end

local function translate(name, in_english)
    return safe(function()
        local text = dfhack.translation.translateName(name, in_english)
        if text == '' then return nil end
        return text
    end)
end

local function soul_of(unit)
    return safe(function() return unit.status.current_soul end)
end

local function unit_name(id)
    if id == nil or id < 0 then return nil end
    local other = df.unit.find(id)
    if not other then return nil end
    return safe(U.getReadableName, other)
end

local function item_description(item)
    return safe(dfhack.items.getReadableDescription, item)
        or safe(function() return dfhack.items.getDescription(item, 0) end)
end

----------------------------------------------------------------------------------------------
-- skills

local SKILL_GROUPS = {
    Normal = 'labor', Medical = 'labor',
    MilitaryWeapon = 'combat', MilitaryAttack = 'combat', MilitaryDefense = 'combat',
    MilitaryUnarmed = 'combat', MilitaryMisc = 'combat',
    Social = 'social',
    Personal = 'other', Cultural = 'other',
}

-- DFHack classes these as ordinary skills; the in-game sheet lists them under Other.
local OTHER_SKILLS = {
    DANCE = true, SING_MUSIC = true, MAKE_MUSIC = true,
    PLAY_KEYBOARD_INSTRUMENT = true, PLAY_STRINGED_INSTRUMENT = true,
    PLAY_WIND_INSTRUMENT = true, PLAY_PERCUSSION_INSTRUMENT = true,
}

local function skill_group(skill_id)
    if OTHER_SKILLS[enum_name(df.job_skill, skill_id)] then return 'other' end
    local class = safe(function() return df.job_skill.attrs[skill_id].type end)
    if type(class) == 'number' then
        class = enum_name(df.job_skill_class, class)
    end
    return SKILL_GROUPS[class] or 'other'
end

local function skill_entry(unit, skill)
    local id = skill.id
    local rating = skill.rating
    local entry = {
        skill = enum_name(df.job_skill, id),
        caption = safe(function() return df.job_skill.attrs[id].caption end),
        rating = rating,
        level = enum_name(df.skill_rating, math.min(rating, df.skill_rating._last_item)),
        experience = skill.experience,
    }
    local effective = safe(U.getEffectiveSkill, unit, id)
    if effective ~= nil and effective ~= rating then
        entry.effective_rating = effective
    end
    local nominal = safe(U.getNominalSkill, unit, id, true)
    if nominal ~= nil and nominal < rating then
        entry.rusty = true
    end
    return entry
end

-- All skills with any experience, grouped by sheet sub-tab, each sorted by rating.
local function skills_by_group(unit)
    local groups = {labor = {}, combat = {}, social = {}, other = {}}
    local soul = soul_of(unit)
    if not soul then return groups end
    pcall(function()
        for _, skill in ipairs(soul.skills) do
            if skill.rating > 0 or skill.experience > 0 then
                table.insert(groups[skill_group(skill.id)], skill_entry(unit, skill))
            end
        end
    end)
    for _, list in pairs(groups) do
        table.sort(list, function(a, b)
            if a.rating ~= b.rating then return a.rating > b.rating end
            return a.experience > b.experience
        end)
    end
    return groups
end

local function form_name(finder, id)
    return safe(function()
        local form = finder(id)
        return form and translate(form.name, true) or nil
    end)
end

local function knowledge(unit)
    local out = {}
    local soul = soul_of(unit)
    local perf = soul and safe(function() return soul.performance_skills end)
    if not perf then return out end
    local sources = {
        {'poetic_form', 'poetic_forms', function(id) return df.poetic_form.find(id) end},
        {'musical_form', 'musical_forms', function(id) return df.musical_form.find(id) end},
        {'dance_form', 'dance_forms', function(id) return df.dance_form.find(id) end},
    }
    for _, source in ipairs(sources) do
        local kind, field, finder = source[1], source[2], source[3]
        pcall(function()
            for _, entry in ipairs(perf[field]) do
                table.insert(out, {
                    kind = kind,
                    id = entry.id,
                    name = form_name(finder, entry.id),
                    rating = entry.rating,
                    level = enum_name(df.skill_rating, entry.rating),
                    experience = entry.experience,
                })
            end
        end)
    end
    pcall(function()
        for _, entry in ipairs(perf.musical_instruments) do
            table.insert(out, {
                kind = 'instrument',
                id = entry.id,
                name = safe(function()
                    return df.global.world.raws.itemdefs.instruments[entry.id].name
                end),
                rating = entry.rating,
                level = enum_name(df.skill_rating, entry.rating),
                experience = entry.experience,
            })
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------
-- personality

local function attribute_list(enum, getter)
    local out = {}
    pcall(function()
        for i = 0, enum._last_item do
            local value = safe(getter, i)
            if value ~= nil then
                table.insert(out, {attribute = enum[i], value = value})
            end
        end
    end)
    return out
end

local function traits(unit)
    local out = {}
    local soul = soul_of(unit)
    if soul then
        pcall(function()
            for i = 0, df.personality_facet_type._last_item do
                table.insert(out, {
                    trait = df.personality_facet_type[i],
                    value = soul.personality.traits[i],
                })
            end
        end)
    end
    return out
end

local function mental_attributes(unit)
    return attribute_list(df.mental_attribute_type, function(i)
        return U.getMentalAttrValue(unit, i)
    end)
end

local function physical_attributes(unit)
    return attribute_list(df.physical_attribute_type, function(i)
        return U.getPhysicalAttrValue(unit, i)
    end)
end

local function values(unit)
    local out = {}
    local soul = soul_of(unit)
    if not soul then return out end
    pcall(function()
        for _, v in ipairs(soul.personality.values) do
            table.insert(out, {value = enum_name(df.value_type, v.type), strength = v.strength})
        end
    end)
    return out
end

local function needs(unit)
    local out = {}
    local soul = soul_of(unit)
    if not soul then return out end
    pcall(function()
        for _, n in ipairs(soul.personality.needs) do
            local entry = {
                need = enum_name(df.need_type, n.id),
                focus_level = n.focus_level,
                need_level = n.need_level,
            }
            if n.deity_id and n.deity_id >= 0 then
                entry.deity_id = n.deity_id
                entry.deity = safe(function()
                    return translate(df.historical_figure.find(n.deity_id).name, true)
                end)
            end
            table.insert(out, entry)
        end
    end)
    return out
end

local function raw_name(list, id, field)
    return safe(function()
        local raw = list[id]
        local name = raw[field or 'name']
        if type(name) == 'string' then return name end
        return name[0]
    end)
end

-- Describe what a preference points at. Field names from df.unit.xml; each access is guarded.
local function preference_target(p)
    local raws = df.global.world.raws
    local item = safe(function()
        local type_name = enum_name(df.item_type, p.item_type)
        local def = p.item_subtype >= 0 and dfhack.items.getSubtypeDef(p.item_type, p.item_subtype)
        return def and def.name or (type_name and type_name:lower()) or nil
    end)
    local material = safe(function()
        if p.mattype < 0 then return nil end
        local info = dfhack.matinfo.decode(p.mattype, p.matindex)
        return info and info:toString() or nil
    end)
    local creature = safe(function()
        if p.creature_id < 0 then return nil end
        return raws.creatures.all[p.creature_id].name[0]
    end)
    local plant = safe(function()
        if p.plant_id < 0 then return nil end
        return raws.plants.all[p.plant_id].name
    end)
    local color = safe(function()
        if p.color_id < 0 then return nil end
        return raws.descriptors.colors[p.color_id].name
    end)
    local shape = safe(function()
        if p.shape_id < 0 then return nil end
        return raws.descriptors.shapes[p.shape_id].name
    end)
    local poetic = safe(function()
        if p.poetic_form_id < 0 then return nil end
        return form_name(function(id) return df.poetic_form.find(id) end, p.poetic_form_id)
    end)
    local musical = safe(function()
        if p.musical_form_id < 0 then return nil end
        return form_name(function(id) return df.musical_form.find(id) end, p.musical_form_id)
    end)
    local dance = safe(function()
        if p.dance_form_id < 0 then return nil end
        return form_name(function(id) return df.dance_form.find(id) end, p.dance_form_id)
    end)
    return {
        item = item, material = material, creature = creature, plant = plant,
        color = color, shape = shape, poetic_form = poetic, musical_form = musical,
        dance_form = dance,
    }
end

local PREFERENCE_TARGET_FIELD = {
    LikeMaterial = 'material', LikeCreature = 'creature', LikeFood = 'material',
    HateCreature = 'creature', LikeItem = 'item', LikePlant = 'plant', LikeTree = 'plant',
    LikeColor = 'color', LikeShape = 'shape', LikePoeticForm = 'poetic_form',
    LikeMusicalForm = 'musical_form', LikeDanceForm = 'dance_form',
}

local function preferences(unit)
    local out = {}
    local soul = soul_of(unit)
    if not soul then return out end
    pcall(function()
        for _, p in ipairs(soul.preferences) do
            local kind = enum_name(df.unitpref_type, p.type)
            local targets = preference_target(p)
            local field = PREFERENCE_TARGET_FIELD[kind]
            local target = field and targets[field]
            if target == nil then
                -- fall back to whichever target resolved
                for _, key in ipairs({'material', 'creature', 'item', 'plant', 'color',
                                      'shape', 'poetic_form', 'musical_form', 'dance_form'}) do
                    if targets[key] ~= nil then
                        target = targets[key]
                        break
                    end
                end
            end
            local entry = {kind = kind, target = target}
            if kind == 'LikeFood' or kind == 'LikeItem' then
                entry.material = targets.material
                entry.item = targets.item
            end
            table.insert(out, entry)
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------
-- thoughts

local function recent_thoughts(unit)
    local out = {}
    local soul = soul_of(unit)
    if not soul then return out end
    pcall(function()
        for _, e in ipairs(soul.personality.emotions) do
            table.insert(out, {
                emotion = enum_name(df.emotion_type, e.type),
                thought = enum_name(df.unit_thought_type, e.thought),
                caption = safe(function() return df.unit_thought_type.attrs[e.thought].caption end),
                subthought = e.subthought,
                strength = e.strength,
                severity = e.severity,
                year = e.year,
                year_tick = e.year_tick,
            })
        end
    end)
    table.sort(out, function(a, b)
        if a.year ~= b.year then return a.year > b.year end
        return a.year_tick > b.year_tick
    end)
    return out
end

----------------------------------------------------------------------------------------------
-- items, rooms, health

-- The inventory mode enum moved to the top level in 53.x; older builds nest it.
local function inventory_mode(mode)
    local lookups = {
        function() return df.inv_item_role_type[mode] end,
        function() return df.unit_inventory_item.T_mode[mode] end,
    }
    for _, lookup in ipairs(lookups) do
        local name = safe(lookup)
        if type(name) == 'string' then return name end
    end
    return tostring(mode)
end

local function inventory(unit)
    local out = {}
    pcall(function()
        for _, entry in ipairs(unit.inventory) do
            local item = entry.item
            table.insert(out, {
                id = item.id,
                description = item_description(item),
                mode = inventory_mode(entry.mode),
                body_part = entry.body_part_id,
            })
        end
    end)
    return out
end

local function owned_items(unit)
    local out = {}
    pcall(function()
        for _, id in ipairs(unit.owned_items) do
            local item = df.item.find(id)
            if item then
                table.insert(out, {id = id, description = item_description(item)})
            end
        end
    end)
    return out
end

local function rooms(unit)
    local out = {}
    pcall(function()
        for _, b in ipairs(unit.owned_buildings) do
            table.insert(out, {
                id = b.id,
                type = enum_name(df.building_type, b:getType()),
                zone_type = safe(function() return enum_name(df.civzone_type, b.type) end),
                description = safe(dfhack.buildings.getRoomDescription, b, unit),
                name = safe(function() return b.name ~= '' and b.name or nil end),
                pos = {x = b.centerx, y = b.centery, z = b.z},
            })
        end
    end)
    return out
end

local function body_part_name(unit, bp_id)
    return safe(function()
        local bp = U.getCasteRaw(unit).body_info.body_parts[bp_id]
        local name = bp.name_singular[0]
        if type(name) == 'string' then return name end
        return name.value
    end)
end

local function wounds(unit)
    local out = {}
    pcall(function()
        for _, w in ipairs(unit.body.wounds) do
            local parts = {}
            pcall(function()
                for _, part in ipairs(w.parts) do
                    table.insert(parts, {
                        body_part = body_part_name(unit, part.body_part_id),
                        body_part_id = part.body_part_id,
                        flags = true_flags(part.flags1),
                        flags2 = true_flags(part.flags2),
                        bleeding = part.bleeding,
                        pain = part.pain,
                    })
                end
            end)
            table.insert(out, {
                id = w.id,
                age = w.age,
                attacker_unit_id = safe(function() return w.attacker_unit_id end),
                flags = true_flags(w.flags),
                parts = parts,
            })
        end
    end)
    return out
end

local function health_status(unit)
    local health = safe(function() return unit.health end)
    if not health then
        return {flags = {}, note = 'no health record; the unit has never needed care'}
    end
    return {flags = true_flags(health.flags) or {}}
end

local function description(unit)
    local caste = safe(U.getCasteRaw, unit)
    return {
        caste = safe(function() return caste.caste_name[0] end),
        caste_description = safe(function() return caste.description end),
        size = safe(function() return unit.body.size_info.size_cur end),
        blood = safe(function() return unit.body.blood_count end),
        blood_max = safe(function() return unit.body.blood_max end),
        physical_attributes = physical_attributes(unit),
        appearance = stub(new_ctx(nil), 'health.description.appearance',
            'appearance text is not reconstructed yet'),
    }
end

----------------------------------------------------------------------------------------------
-- overview

local function kin(unit)
    local out = {}
    for _, relation in ipairs({'Spouse', 'Mother', 'Father', 'Lover', 'PetOwner'}) do
        local id = safe(function() return unit.relationship_ids[relation] end)
        if id and id >= 0 then
            out[relation:lower()] = {id = id, name = unit_name(id)}
        end
    end
    return out
end

local function noble_positions(unit)
    local out = {}
    pcall(function()
        for _, entry in ipairs(U.getNoblePositions(unit) or {}) do
            table.insert(out, {
                position = safe(function() return entry.position.name[0] end)
                    or safe(function() return entry.position.code end),
                entity = safe(function() return translate(entry.entity.name, true) end),
                entity_id = safe(function() return entry.entity.id end),
            })
        end
    end)
    return out
end

local function top_skills(unit, n)
    local all = {}
    for _, list in pairs(skills_by_group(unit)) do
        for _, s in ipairs(list) do table.insert(all, s) end
    end
    table.sort(all, function(a, b) return a.rating > b.rating end)
    local out = {}
    for i = 1, math.min(n, #all) do out[i] = all[i] end
    return out
end

local function hauled(unit)
    local out = {}
    for _, entry in ipairs(inventory(unit)) do
        if entry.mode == 'Hauled' then table.insert(out, entry) end
    end
    return out
end

local function overview(unit, ctx)
    local out = units.detail(unit)
    local soul = soul_of(unit)
    out.stress = safe(function() return soul.personality.stress end)
    out.long_term_mood = safe(function()
        return units.MOOD_NAMES[U.getStressCategoryRaw(soul.personality.longterm_stress)]
    end)
    out.focus = safe(function()
        return {current = soul.personality.current_focus,
                undistracted = soul.personality.undistracted_focus}
    end)
    out.dream = safe(function()
        local name = U.getGoalName(unit)
        if not name or name == '' then return nil end
        return {goal = name, achieved = U.isGoalAchieved(unit) and true or false}
    end)
    out.kills = safe(U.getKillCount, unit)
    out.kin = kin(unit)
    out.positions = noble_positions(unit)
    out.top_skills = top_skills(unit, 5)
    out.hauling = hauled(unit)
    out.recent_thoughts = capped(ctx, 'overview.recent_thoughts', (function()
        local all = recent_thoughts(unit)
        local few = {}
        for i = 1, math.min(5, #all) do few[i] = all[i] end
        return few
    end)())
    return out
end

----------------------------------------------------------------------------------------------
-- historical figure, relations, groups

local function histfig_of(unit)
    return safe(function()
        if unit.hist_figure_id < 0 then return nil end
        return df.historical_figure.find(unit.hist_figure_id)
    end)
end

local function histfig_name(id)
    return safe(function()
        local hf = df.historical_figure.find(id)
        if not hf then return nil end
        local native = translate(hf.name, false)
        local surname = safe(function()
            return dfhack.translation.translateName(hf.name, true, true)
        end)
        if native and surname and surname ~= '' then
            return ('%s "%s"'):format(native, surname)
        end
        return native or translate(hf.name, true)
    end)
end

local function histfig_unit_id(id)
    local unit_id = safe(function() return df.historical_figure.find(id).unit_id end)
    if unit_id and unit_id >= 0 then return unit_id end
    return nil
end

-- Type name of a polymorphic link object: the getType enum when available, else the class.
local function link_type(link, enum)
    local name = safe(function() return enum[link:getType()] end)
    if type(name) == 'string' then return name end
    local class = tostring(safe(function() return link._type end))
    return class:match('link_(%w+)st') or class
end

local function pets_of(unit)
    local out = {}
    pcall(function()
        for _, other in ipairs(df.global.world.units.active) do
            local owner = safe(function() return other.relationship_ids.PetOwner end)
            if owner == unit.id then
                local training = 'none'
                if safe(U.isWar, other) then training = 'war'
                elseif safe(U.isHunter, other) then training = 'hunting' end
                table.insert(out, {
                    id = other.id,
                    name = safe(U.getReadableName, other),
                    creature = safe(U.getRaceReadableName, other),
                    training = training,
                    dead = safe(U.isDead, other) and true or false,
                })
            end
        end
    end)
    return out
end

local function relations(unit, ctx)
    local family, deities, others = {}, {}, {}
    local hf = histfig_of(unit)
    if hf then
        pcall(function()
            for _, link in ipairs(hf.histfig_links) do
                local kind = link_type(link, df.histfig_hf_link_type)
                local entry = {
                    relation = kind,
                    hist_figure_id = link.target_hf,
                    name = histfig_name(link.target_hf),
                    id = histfig_unit_id(link.target_hf),
                    strength = link.link_strength,
                }
                if kind == 'DEITY' then
                    table.insert(deities, entry)
                else
                    table.insert(family, entry)
                end
            end
        end)
        -- Non-kin relationships. DF keeps raw feeling scores per known figure and derives
        -- labels like "friend" from them in the UI; the scores are exposed as they are.
        pcall(function()
            for _, entry in ipairs(hf.info.relationships.hf_visual) do
                local attitudes = {}
                pcall(function()
                    for _, a in ipairs(entry.attitude) do
                        table.insert(attitudes, enum_name(df.reputation_type, a))
                    end
                end)
                table.insert(others, {
                    hist_figure_id = entry.histfig_id,
                    name = histfig_name(entry.histfig_id),
                    id = histfig_unit_id(entry.histfig_id),
                    meet_count = safe(function() return entry.meet_count end),
                    first_year = safe(function() return entry.first_year end),
                    last_meet_year = safe(function() return entry.last_meet_year end),
                    feelings = safe(function()
                        local core = entry.core
                        return {love = core.love, trust = core.trust, loyalty = core.loyalty,
                                fear = core.fear, respect = core.respect}
                    end),
                    attitudes = attitudes,
                    flags = true_flags(safe(function() return entry.flags end)),
                })
            end
        end)
        table.sort(others, function(a, b)
            return (a.meet_count or 0) > (b.meet_count or 0)
        end)
    end
    return {
        kin = kin(unit),
        family = capped(ctx, 'relations.family', family),
        deities = capped(ctx, 'relations.deities', deities),
        pets = capped(ctx, 'relations.pets', pets_of(unit)),
        others = capped(ctx, 'relations.others', others),
    }
end

local function groups(unit, ctx)
    local out = {}
    local hf = histfig_of(unit)
    if hf then
        pcall(function()
            for _, link in ipairs(hf.entity_links) do
                local entity = df.historical_entity.find(link.entity_id)
                local entry = {
                    link = link_type(link, df.histfig_entity_link_type),
                    entity_id = link.entity_id,
                    entity = entity and translate(entity.name, true) or nil,
                    entity_type = entity and enum_name(df.historical_entity_type, entity.type) or nil,
                    strength = link.link_strength,
                }
                pcall(function() entry.start_year = link.start_year end)
                pcall(function() entry.end_year = link.end_year end)
                pcall(function() entry.assignment_id = link.assignment_id end)
                pcall(function() entry.squad_id = link.squad_id end)
                pcall(function() entry.occupation_id = link.occupation_id end)
                table.insert(out, entry)
            end
        end)
    end
    return {
        memberships = capped(ctx, 'groups.memberships', out),
        positions = noble_positions(unit),
    }
end

----------------------------------------------------------------------------------------------
-- military

local function squad_of(unit)
    return safe(function()
        local id = unit.military.squad_id
        if id < 0 then return nil end
        return df.squad.find(id)
    end)
end

local function squads(unit, ctx)
    local squad = squad_of(unit)
    if not squad then return {} end
    local orders = {}
    pcall(function()
        for _, order in ipairs(squad.orders) do
            table.insert(orders, safe(function() return order:getDescription() end)
                or tostring(safe(function() return order._type end)))
        end
    end)
    local position = unit.military.squad_position
    return {
        squad = {
            id = squad.id,
            name = safe(dfhack.military.getSquadName, squad.id),
            alias = safe(function() return squad.alias ~= '' and squad.alias or nil end),
            position = position,
            leader = position == 0,
            entity_id = squad.entity_id,
            orders = orders,
        },
    }
end

local function uniform(unit, ctx)
    local squad = squad_of(unit)
    if not squad then return capped(ctx, 'military.uniform', {}) end
    local out = {}
    pcall(function()
        local pos = squad.positions[unit.military.squad_position]
        local specs = pos.equipment.uniform
        for cat = 0, df.uniform_category._last_item do
            for _, spec in ipairs(specs[cat]) do
                local entry = {
                    category = enum_name(df.uniform_category, cat),
                    item_type = enum_name(df.item_type, spec.item_type),
                    item = safe(function()
                        local def = dfhack.items.getSubtypeDef(spec.item_type, spec.item_subtype)
                        return def and def.name or nil
                    end),
                    material = safe(function()
                        if spec.mattype < 0 then return nil end
                        return dfhack.matinfo.decode(spec.mattype, spec.matindex):toString()
                    end),
                    material_class = safe(function()
                        return enum_name(df.entity_material_category, spec.material_class)
                    end),
                    indiv_choice = true_flags(spec.indiv_choice),
                }
                pcall(function()
                    local assigned = {}
                    for _, item_id in ipairs(spec.assigned) do
                        local item = df.item.find(item_id)
                        table.insert(assigned, {id = item_id,
                            description = item and item_description(item) or nil})
                    end
                    entry.assigned = assigned
                end)
                table.insert(out, entry)
            end
        end
    end)
    return capped(ctx, 'military.uniform', out)
end

local function kills(unit, ctx)
    local notable, other = {}, {}
    local hf = histfig_of(unit)
    if hf then
        pcall(function()
            local k = hf.info.kills
            for _, event_id in ipairs(k.events) do
                local event = df.history_event.find(event_id)
                local entry = {event_id = event_id}
                pcall(function() entry.year = event.year end)
                pcall(function()
                    entry.victim_hist_figure_id = event.victim_hf
                    entry.victim = histfig_name(event.victim_hf)
                end)
                pcall(function()
                    entry.cause = enum_name(df.death_type, event.death_cause)
                end)
                table.insert(notable, entry)
            end
            for i = 0, #k.killed_race - 1 do
                local race = k.killed_race[i]
                table.insert(other, {
                    creature = safe(function()
                        return df.global.world.raws.creatures.all[race].name[0]
                    end),
                    race = safe(function()
                        return df.global.world.raws.creatures.all[race].creature_id
                    end),
                    count = safe(function() return k.killed_count[i] end),
                    undead = safe(function() return k.killed_undead[i] end) and true or false,
                })
            end
        end)
    end
    return {
        count = safe(U.getKillCount, unit),
        notable = capped(ctx, 'military.kills.notable', notable),
        other = capped(ctx, 'military.kills.other', other),
    }
end

----------------------------------------------------------------------------------------------
-- memories

local function memory_entry(m)
    return {
        emotion = enum_name(df.emotion_type, m.type),
        thought = enum_name(df.unit_thought_type, m.thought),
        caption = safe(function() return df.unit_thought_type.attrs[m.thought].caption end),
        subthought = m.subthought,
        strength = m.strength,
        relative_strength = safe(function() return m.relative_strength end),
        severity = m.severity,
        year = m.year,
        year_tick = m.year_tick,
        created_year = safe(function() return m.created_year end),
        created_tick = safe(function() return m.created_tick end),
        flags = true_flags(m.flags),
    }
end

local function memory_slots(array)
    local out = {}
    pcall(function()
        for i = 0, #array - 1 do
            local m = array[i]
            if m.thought >= 0 or m.type >= 0 then
                table.insert(out, memory_entry(m))
            end
        end
    end)
    return out
end

local function memories(unit, ctx)
    local soul = soul_of(unit)
    local mem = soul and safe(function() return soul.personality.memories end)
    if not mem then
        return {
            short_term = capped(ctx, 'thoughts.memories.short_term', {}),
            long_term = capped(ctx, 'thoughts.memories.long_term', {}),
            core = capped(ctx, 'thoughts.memories.core', {}),
        }
    end
    local core = {}
    pcall(function()
        for _, c in ipairs(mem.core_memories) do
            local entry = {memory = memory_entry(c.memory)}
            pcall(function()
                if c.changed_facet >= 0 then
                    entry.changed_facet = enum_name(df.personality_facet_type, c.changed_facet)
                    entry.facet_old, entry.facet_new = c.facet_old, c.facet_new
                end
            end)
            pcall(function()
                if c.changed_value >= 0 then
                    entry.changed_value = enum_name(df.value_type, c.changed_value)
                    entry.value_old, entry.value_new = c.value_old, c.value_new
                end
            end)
            table.insert(core, entry)
        end
    end)
    return {
        short_term = capped(ctx, 'thoughts.memories.short_term', memory_slots(mem.shortterm)),
        long_term = capped(ctx, 'thoughts.memories.long_term', memory_slots(mem.longterm)),
        core = capped(ctx, 'thoughts.memories.core', core),
    }
end

----------------------------------------------------------------------------------------------
-- health treatment and history

local function treatment(unit, ctx)
    local health = safe(function() return unit.health end)
    if not health then
        return {flags = {}, body_parts = capped(ctx, 'health.treatment.body_parts', {}),
                note = 'no health record; the unit has never needed care'}
    end
    local body_parts = {}
    pcall(function()
        for i = 0, #health.body_part_flags - 1 do
            local flags = true_flags(health.body_part_flags[i])
            if flags and #flags > 0 then
                table.insert(body_parts, {
                    body_part = body_part_name(unit, i),
                    body_part_id = i,
                    flags = flags,
                })
            end
        end
    end)
    local countdowns = {}
    for _, field in ipairs({'try_for_cast_cntdn', 'immobilize_cntdn', 'dressing_cntdn',
                            'suture_cntdn', 'crutch_cntdn'}) do
        local value = safe(function() return health[field] end)
        if value and value > 0 then countdowns[field:gsub('_cntdn$', '')] = value end
    end
    return {
        flags = true_flags(health.flags) or {},
        body_parts = capped(ctx, 'health.treatment.body_parts', body_parts),
        countdowns = countdowns,
    }
end

local function history(unit, ctx)
    local health = safe(function() return unit.health end)
    local ops, diagnoses = {}, {}
    if health then
        pcall(function()
            for _, e in ipairs(health.op_history) do
                table.insert(ops, {
                    job = enum_name(df.job_type, e.job_type),
                    year = e.year,
                    year_time = safe(function() return e.year_time end),
                    doctor_id = safe(function() return e.doctor_id end),
                    doctor = safe(function() return unit_name(e.doctor_id) end),
                })
            end
        end)
        pcall(function()
            for _, d in ipairs(health.syndrome_diagnosis) do
                table.insert(diagnoses, {
                    syndrome_index = d.syndrome_ind,
                    year = d.year,
                    season_count = safe(function() return d.season_count end),
                    worker_id = safe(function() return d.worker_unid end),
                })
            end
        end)
    end
    return {
        operations = capped(ctx, 'health.history.operations', ops),
        diagnoses = capped(ctx, 'health.history.diagnoses', diagnoses),
    }
end

----------------------------------------------------------------------------------------------
-- labor

local function enabled_labors(unit)
    local out = {}
    pcall(function()
        for i = 0, df.unit_labor._last_item do
            if unit.status.labors[i] then
                table.insert(out, df.unit_labor[i] or tostring(i))
            end
        end
    end)
    return out
end

local function work_details(unit, ctx)
    local out = {}
    pcall(function()
        for _, wd in ipairs(df.global.plotinfo.labor_info.work_details) do
            local assigned = false
            for _, id in ipairs(wd.assigned_units) do
                if id == unit.id then assigned = true end
            end
            if assigned then
                local labors = {}
                pcall(function()
                    for i = 0, df.unit_labor._last_item do
                        if wd.allowed_labors[i] then
                            table.insert(labors, df.unit_labor[i] or tostring(i))
                        end
                    end
                end)
                table.insert(out, {
                    name = wd.name,
                    icon = enum_name(df.work_detail_icon_type, wd.icon),
                    mode = safe(function() return enum_name(df.work_detail_mode, wd.flags.mode) end),
                    labors = labors,
                })
            end
        end
    end)
    return {
        details = capped(ctx, 'labor.work_details.details', out),
        enabled_labors = capped(ctx, 'labor.work_details.enabled_labors', enabled_labors(unit)),
    }
end

local function workshops(unit, ctx)
    local out = {}
    pcall(function()
        local other = df.global.world.buildings.other
        for _, key in ipairs({'WORKSHOP_ANY', 'FURNACE_ANY'}) do
            for _, b in ipairs(other[key]) do
                local workers = safe(function() return b.profile.permitted_workers end)
                if workers then
                    for _, w in ipairs(workers) do
                        if w == unit.id then
                            table.insert(out, {
                                id = b.id,
                                type = enum_name(df.building_type, b:getType()),
                                subtype = safe(function()
                                    local enum = key == 'WORKSHOP_ANY' and df.workshop_type
                                        or df.furnace_type
                                    return enum_name(enum, b.type)
                                end),
                                name = safe(function() return b.name ~= '' and b.name or nil end),
                                pos = {x = b.centerx, y = b.centery, z = b.z},
                            })
                        end
                    end
                end
            end
        end
    end)
    return capped(ctx, 'labor.workshops', out)
end

local function location_name(site_id, location_id)
    return safe(function()
        local site = df.world_site.find(site_id)
        for _, ab in ipairs(site.buildings) do
            if ab.id == location_id then
                return translate(ab.name, true) or enum_name(df.abstract_building_type, ab:getType())
            end
        end
        return nil
    end)
end

local function locations(unit, ctx)
    local out = {}
    pcall(function()
        for _, occ in ipairs(df.global.world.occupations.all) do
            if occ.unit_id == unit.id then
                table.insert(out, {
                    id = occ.id,
                    occupation = enum_name(df.occupation_type, occ.type),
                    location_id = occ.location_id,
                    site_id = occ.site_id,
                    location = location_name(occ.site_id, occ.location_id),
                })
            end
        end
    end)
    return capped(ctx, 'labor.locations', out)
end

local function work_animals(unit, ctx)
    local out = {}
    for _, pet in ipairs(pets_of(unit)) do
        if pet.training ~= 'none' then table.insert(out, pet) end
    end
    return capped(ctx, 'labor.work_animals', out)
end

----------------------------------------------------------------------------------------------
-- builders: category -> function(unit, ctx) or {sub -> function(unit, ctx)}

local builders = {
    overview = overview,
    relations = relations,
    groups = groups,
    military = {
        squads = squads,
        uniform = uniform,
        kills = kills,
    },
    thoughts = {
        recent = function(unit, ctx)
            return capped(ctx, 'thoughts.recent', recent_thoughts(unit))
        end,
        memories = memories,
    },
    personality = {
        traits = function(unit, ctx)
            return {
                facets = capped(ctx, 'personality.traits.facets', traits(unit)),
                mental_attributes = capped(ctx, 'personality.traits.mental_attributes',
                    mental_attributes(unit)),
            }
        end,
        values = function(unit, ctx)
            return capped(ctx, 'personality.values', values(unit))
        end,
        preferences = function(unit, ctx)
            return capped(ctx, 'personality.preferences', preferences(unit))
        end,
        needs = function(unit, ctx)
            return capped(ctx, 'personality.needs', needs(unit))
        end,
    },
    items = function(unit, ctx)
        return {
            inventory = capped(ctx, 'items.inventory', inventory(unit)),
            owned = capped(ctx, 'items.owned', owned_items(unit)),
        }
    end,
    health = {
        status = function(unit, ctx) return health_status(unit) end,
        wounds = function(unit, ctx) return capped(ctx, 'health.wounds', wounds(unit)) end,
        treatment = treatment,
        history = history,
        description = function(unit, ctx)
            local out = description(unit)
            table.insert(ctx.best_effort, 'health.description.appearance')
            return out
        end,
    },
    skills = {
        labor = function(unit, ctx)
            return capped(ctx, 'skills.labor', skills_by_group(unit).labor)
        end,
        combat = function(unit, ctx)
            return capped(ctx, 'skills.combat', skills_by_group(unit).combat)
        end,
        social = function(unit, ctx)
            return capped(ctx, 'skills.social', skills_by_group(unit).social)
        end,
        other = function(unit, ctx)
            return capped(ctx, 'skills.other', skills_by_group(unit).other)
        end,
        knowledge = function(unit, ctx)
            return capped(ctx, 'skills.knowledge', knowledge(unit))
        end,
    },
    rooms = function(unit, ctx) return capped(ctx, 'rooms', rooms(unit)) end,
    labor = {
        work_details = work_details,
        workshops = workshops,
        locations = locations,
        work_animals = work_animals,
    },
}

local function build_category(unit, ctx, spec, subcategory)
    local builder = builders[spec.name]
    if not spec.subs then
        return builder(unit, ctx)
    end
    if subcategory then
        return builder[subcategory](unit, ctx)
    end
    local out = {}
    for _, sub in ipairs(spec.subs) do
        out[sub] = builder[sub](unit, ctx)
    end
    return out
end

local function find_unit(args)
    local id = tonumber(args.id)
    if not id then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a unit id')
    end
    local unit = df.unit.find(id)
    if not unit then
        return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. id)
    end
    return unit, nil
end

local function parse_limit(args)
    if args.limit == nil then return DEFAULT_LIMIT end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

local function sheet(args)
    local unit, err = find_unit(args)
    if err then return err end
    local limit, limit_err = parse_limit(args)
    if limit_err then return limit_err end
    local spec = category_spec(args.category)
    if not spec then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"category" must be one of ' .. table.concat(category_names(), ', '))
    end
    local sub = args.subcategory
    if sub ~= nil then
        if not spec.subs then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('category "%s" has no sub-categories'):format(spec.name))
        end
        local known = false
        for _, s in ipairs(spec.subs) do
            if s == sub then known = true end
        end
        if not known then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('"subcategory" for %s must be one of %s'):format(
                    spec.name, table.concat(spec.subs, ', ')))
        end
    end
    local ctx = new_ctx(limit)
    local data = build_category(unit, ctx, spec, sub)
    return {
        id = unit.id,
        name = safe(U.getReadableName, unit),
        category = spec.name,
        subcategory = sub,
        limit = limit,
        data = data,
        truncated = ctx.truncated,
        best_effort = ctx.best_effort,
    }
end

local function full_sheet(args)
    local unit, err = find_unit(args)
    if err then return err end
    local limit, limit_err = parse_limit(args)
    if limit_err then return limit_err end
    local ctx = new_ctx(limit)
    local out = {}
    for _, spec in ipairs(CATEGORIES) do
        local ok, data = pcall(build_category, unit, ctx, spec, nil)
        if ok then
            out[spec.name] = data
        else
            out[spec.name] = {best_effort = true, error = tostring(data)}
            table.insert(ctx.best_effort, spec.name)
        end
    end
    return {
        id = unit.id,
        name = safe(U.getReadableName, unit),
        limit = limit,
        sheet = out,
        truncated = ctx.truncated,
        best_effort = ctx.best_effort,
    }
end

function ops()
    return {
        ['units.sheet'] = {namespace = 'units', handler = sheet, needs_map = true},
        ['units.full_sheet'] = {namespace = 'units', handler = full_sheet, needs_map = true},
    }
end
