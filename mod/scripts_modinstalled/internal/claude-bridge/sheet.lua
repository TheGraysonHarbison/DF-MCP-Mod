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
-- builders: category -> function(unit, ctx) or {sub -> function(unit, ctx)}

local NEXT_PR = 'planned for the next PR after the in-game struct check'

local builders = {
    overview = overview,
    relations = function(unit, ctx)
        return {kin = kin(unit), others = stub(ctx, 'relations.others', NEXT_PR)}
    end,
    groups = function(unit, ctx) return stub(ctx, 'groups', NEXT_PR) end,
    military = {
        squads = function(unit, ctx)
            local squad = units.detail(unit).squad
            return {squad = squad}
        end,
        uniform = function(unit, ctx) return stub(ctx, 'military.uniform', NEXT_PR) end,
        kills = function(unit, ctx)
            return {count = safe(U.getKillCount, unit),
                    list = stub(ctx, 'military.kills.list', NEXT_PR)}
        end,
    },
    thoughts = {
        recent = function(unit, ctx)
            return capped(ctx, 'thoughts.recent', recent_thoughts(unit))
        end,
        memories = function(unit, ctx) return stub(ctx, 'thoughts.memories', NEXT_PR) end,
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
        treatment = function(unit, ctx) return stub(ctx, 'health.treatment', NEXT_PR) end,
        history = function(unit, ctx) return stub(ctx, 'health.history', NEXT_PR) end,
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
        work_details = function(unit, ctx) return stub(ctx, 'labor.work_details', NEXT_PR) end,
        workshops = function(unit, ctx) return stub(ctx, 'labor.workshops', NEXT_PR) end,
        locations = function(unit, ctx) return stub(ctx, 'labor.locations', NEXT_PR) end,
        work_animals = function(unit, ctx) return stub(ctx, 'labor.work_animals', NEXT_PR) end,
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
