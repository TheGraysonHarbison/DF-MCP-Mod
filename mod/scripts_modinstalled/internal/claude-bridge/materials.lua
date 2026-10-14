-- Material words shared by work orders and buildings (plan section 12, item 7.0).
-- resolve() turns "granite", "any stone", "wood", "blocks", "granite blocks", "wooden logs",
-- or a token such as INORGANIC:IRON into a spec. Work orders use the material part (the
-- generic inorganic material for stone words, a job material category for wood, bone, ...).
-- Building jobs turn the spec into job_item fields: a specific material sets mat_type and
-- mat_index, a class sets the flags3 bit the v50 build menu uses (stone, wood, metal, gem),
-- a form sets item_type (blocks, boulders, logs, bars). DFHack's isSuitableMaterial ignores
-- the class bits (checked in Materials.cpp, 2026-10-14), so item_matches() judges class
-- from the material flags itself.
--@ module = true

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

-- Item forms a building material can take, by plain word.
FORMS = {
    blocks = 'BLOCKS', block = 'BLOCKS',
    boulders = 'BOULDER', boulder = 'BOULDER', ['rough stone'] = 'BOULDER',
    logs = 'WOOD', log = 'WOOD',
    bars = 'BAR', bar = 'BAR',
}
FORM_WORDS = {BLOCKS = 'blocks', BOULDER = 'boulders', WOOD = 'logs', BAR = 'bars'}

-- Material classes a building filter can ask for (job_item.flags3 bits).
CLASSES = {stone = 'stone', rock = 'stone', stones = 'stone', rocks = 'stone', inorganic = 'stone',
           wood = 'wood', wooden = 'wood', metal = 'metal', metals = 'metal', gem = 'gem', gems = 'gem'}

-- Words that mean the generic inorganic material for a work order ("any stone").
STONE_WORDS = {stone = true, rock = true, stones = true, rocks = true, inorganic = true}
-- Words that mean a work order material category flag.
CATEGORY_WORDS = {wood = 'wood', wooden = 'wood', log = 'wood', logs = 'wood',
                  bone = 'bone', bones = 'bone', shell = 'shell', leather = 'leather',
                  cloth = 'cloth', silk = 'silk', yarn = 'yarn', wool = 'yarn',
                  horn = 'horn', pearl = 'pearl', tooth = 'tooth', ivory = 'tooth',
                  plant = 'plant', ['plant fiber'] = 'cloth', soap = 'soap',
                  strand = 'strand'}

local function normalise(name)
    local word = tostring(name):lower():gsub('^%s+', ''):gsub('%s+$', ''):gsub('%s+', ' ')
    return (word:gsub('^any ', ''))
end

-- Find an inorganic material by id, solid name, or solid adjective. Returns the index or
-- nil plus up to five close names for the error message.
local function find_inorganic(word)
    local near, seen, found = {}, {}, nil
    pcall(function()
        for index, inorganic in ipairs(df.global.world.raws.inorganics.all) do
            local display = safe(function() return inorganic.material.state_name.Solid end)
            local names = {
                safe(function() return inorganic.id end),
                display,
                safe(function() return inorganic.material.state_adj.Solid end),
            }
            for _, candidate in ipairs(names) do
                local lowered = type(candidate) == 'string' and candidate:lower() or nil
                if lowered == word then
                    found = index
                    return
                end
                local shown = type(display) == 'string' and display:lower() or lowered
                if lowered and shown and #near < 5 and not seen[shown]
                    and lowered:find(word, 1, true) then
                    seen[shown] = true
                    table.insert(near, shown)
                end
            end
        end
    end)
    return found, near
end

-- Find a plant material ("plum wood", "ash", "plum") by its solid name or adjective, or by
-- the plant's name for its wood. Returns a matinfo or nil plus close names.
local function find_plant_material(word)
    local near, seen, found = {}, {}, nil
    pcall(function()
        for _, plant in ipairs(df.global.world.raws.plants.all) do
            local plant_name = safe(function() return plant.name end)
            local plant_lower = type(plant_name) == 'string' and plant_name:lower() or nil
            -- Trees are named "plum tree": accept "plum" and "plum wood" for their wood.
            if plant_lower then plant_lower = plant_lower:gsub(' tree$', '') end
            for _, mat in ipairs(plant.material) do
                local display = safe(function() return mat.state_name.Solid end)
                local names = {
                    display,
                    safe(function() return mat.state_adj.Solid end),
                    (mat.id == 'WOOD' and plant_lower) and (plant_lower .. ' wood') or nil,
                    mat.id == 'WOOD' and plant_lower or nil,
                }
                for _, candidate in ipairs(names) do
                    local lowered = type(candidate) == 'string' and candidate:lower() or nil
                    if lowered == word then
                        found = safe(dfhack.matinfo.find, 'PLANT:' .. plant.id .. ':' .. mat.id)
                        if found then return end
                    end
                    local shown = type(display) == 'string' and display:lower() or lowered
                    if lowered and shown and #near < 5 and not seen[shown]
                        and lowered:find(word, 1, true) then
                        seen[shown] = true
                        table.insert(near, shown)
                    end
                end
            end
            if found then return end
        end
    end)
    return found, near
end

-- Resolve a material word. Returns a spec or nil, error message. The spec has `label` and
-- any of: `generic_inorganic` (stone words), `category` (work order flag), `class`
-- (building filter bit), `form` (item_type token), `mat_type` and `mat_index`.
function resolve(name)
    if name == nil then return nil end
    local raw = tostring(name)
    local word = normalise(raw)
    if word == '' or word == 'any' or word == 'none' then return nil end
    local spec = {label = word}
    -- A trailing form word: "granite blocks", "wooden logs", "logs".
    local head, tail = word:match('^(.-)%s*(%S+)$')
    if FORMS[word] then
        spec.form = FORMS[word]
        word = ''
    elseif tail and FORMS[tail] and head ~= '' then
        spec.form = FORMS[tail]
        word = normalise(head)
    end
    if word == '' then
        if spec.form == 'WOOD' then spec.class = 'wood' end
        if spec.form == 'BAR' then spec.class = 'metal' end
        return spec
    end
    if STONE_WORDS[word] then
        spec.generic_inorganic = true
        spec.class = 'stone'
        return spec
    end
    if CLASSES[word] then spec.class = CLASSES[word] end
    if CATEGORY_WORDS[word] then spec.category = CATEGORY_WORDS[word] end
    if spec.class or spec.category then return spec end
    local function from_info(info)
        spec.mat_type, spec.mat_index = info.type, info.index
        spec.label = safe(function() return info:toString() end) or spec.label
        return spec
    end
    -- An explicit token (INORGANIC:IRON, PLANT:PLUM:WOOD) wins outright.
    if raw:find(':', 1, true) then
        local info = safe(dfhack.matinfo.find, raw) or safe(dfhack.matinfo.find, raw:upper():gsub('%s+', '_'))
        if info then return from_info(info) end
    end
    -- Plain words: a stone, metal, gem, or glass by name, then a plant's wood ("plum",
    -- "plum wood", "ash"), then any other inorganic (ash the powder, coal), then a bare
    -- token such as GRANITE. This keeps "ash" on the tree when the ashery's ash exists too.
    local index, near = find_inorganic(word)
    local inorganic = index and safe(dfhack.matinfo.decode, 0, index) or nil
    if inorganic and class_of(inorganic) ~= 'other' then return from_info(inorganic) end
    local plant, plant_near = find_plant_material(word)
    if plant then return from_info(plant) end
    if inorganic then return from_info(inorganic) end
    for _, name in ipairs(plant_near) do
        if #near < 5 then table.insert(near, name) end
    end
    for _, candidate in ipairs({raw, raw:upper():gsub('%s+', '_')}) do
        local info = safe(dfhack.matinfo.find, candidate)
        if info then return from_info(info) end
    end
    local hint = #near > 0 and ('; close matches: ' .. table.concat(near, ', ')) or ''
    return nil, ('unknown "material" %s; use "any stone", "any wood", "any metal", a form such as '
        .. '"blocks", "boulders", "logs", or "bars" (also "granite blocks"), a stone, metal, or wood '
        .. 'name such as "granite", "silver", or "plum wood", or a token such as INORGANIC:IRON%s'):format(raw, hint)
end

-- Fields to merge into a building job_item filter for the spec (getFiltersByType's
-- `material` argument). A specific material clears non_economic, as DFHack does.
function job_item_fields(spec)
    local fields = {}
    if spec.mat_type ~= nil then
        fields.mat_type, fields.mat_index = spec.mat_type, spec.mat_index
    end
    if spec.form then fields.item_type = df.item_type[spec.form] end
    if spec.class then fields.flags3 = {[spec.class] = true} end
    return fields
end

-- Material class of a matinfo: stone, wood, metal, gem, glass, or other.
function class_of(info)
    local flags = safe(function() return info.material.flags end)
    if not flags then return 'other' end
    local function has(flag) return safe(function() return flags[flag] end) == true end
    if has('IS_METAL') then return 'metal' end
    if has('IS_GEM') then return 'gem' end
    if has('IS_GLASS') then return 'glass' end
    if has('IS_STONE') then return 'stone' end
    if has('WOOD') then return 'wood' end
    return 'other'
end

-- DFHack's thresholds (Materials.cpp getMatchBits, checked 2026-10-14).
local function heat_safe(info, limit)
    local heat = safe(function() return info.material.heat end)
    if not heat then return false end
    return heat.melting_point > limit and heat.boiling_point > limit
        and heat.ignite_point > limit and heat.heatdam_point > limit
        and (heat.colddam_point == 60001 or heat.colddam_point < limit)
end
function fire_safe(info) return heat_safe(info, 11000) end
function magma_safe(info) return heat_safe(info, 12000) end

function is_economic(info)
    if not info or info.type ~= 0 then return false end
    return safe(function() return df.global.plotinfo.economic_stone[info.index] ~= 0 end) == true
end

-- Whether an item's material and form satisfy the spec's class, form, and material. The
-- job_item flags DFHack checks (building_material, fire_safe, ...) are judged separately
-- by isSuitableMaterial; this covers what it ignores.
function item_matches(item, spec, info)
    if spec.form and df.item_type[item:getType()] ~= spec.form then return false end
    info = info or safe(dfhack.matinfo.decode, item)
    if not info then return false end
    if spec.mat_type ~= nil and (info.type ~= spec.mat_type
        or (spec.mat_index ~= nil and spec.mat_index >= 0 and info.index ~= spec.mat_index)) then
        return false
    end
    if spec.class and class_of(info) ~= spec.class then return false end
    return true
end

-- Item flags that take an item out of play for building (as build.workshop uses).
EXCLUDE_ITEM_FLAGS = {'forbid', 'in_job', 'in_building', 'trader', 'hostile',
                      'garbage_collect', 'removed', 'construction', 'dump', 'melt'}

function item_usable(item)
    for _, flag in ipairs(EXCLUDE_ITEM_FLAGS) do
        if safe(function() return item.flags[flag] end) then return false end
    end
    return true
end

local SCAN_TYPES = {BLOCKS = true, BOULDER = true, WOOD = true, BAR = true}

-- Usable building materials in play grouped by material and form. Bars count only when
-- metal, as the game's building material filter treats them. opts: form, material (a spec
-- from resolve or nil), fire_safe, magma_safe, limit.
function scan(opts)
    opts = opts or {}
    local groups, order = {}, {}
    local total = 0
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        local form = df.item_type[item:getType()]
        if SCAN_TYPES[form] and item_usable(item) then
            local info = safe(dfhack.matinfo.decode, item)
            local class = info and class_of(info) or 'other'
            local ok = info ~= nil and (form ~= 'BAR' or class == 'metal')
            if ok and opts.form and form ~= opts.form then ok = false end
            if ok and opts.material and not item_matches(item, opts.material, info) then ok = false end
            if ok and opts.fire_safe and not fire_safe(info) then ok = false end
            if ok and opts.magma_safe and not magma_safe(info) then ok = false end
            if ok then
                local name = safe(function() return info:toString() end) or '?'
                local key = name .. '|' .. form
                local group = groups[key]
                if not group then
                    group = {material = name, form = FORM_WORDS[form], class = class,
                             count = 0, fire_safe = fire_safe(info), magma_safe = magma_safe(info),
                             economic = form == 'BOULDER' and is_economic(info) or nil,
                             token = safe(function() return info:getToken() end)}
                    groups[key] = group
                    table.insert(order, group)
                end
                local n = safe(function() return item:getStackSize() end) or 1
                group.count = group.count + n
                total = total + n
            end
        end
    end
    table.sort(order, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.material < b.material
    end)
    return order, total
end
