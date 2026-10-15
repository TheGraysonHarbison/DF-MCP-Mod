-- Kitchen preferences: which ingredients may be cooked and which brewed. Plan section 13.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

DEFAULT_LIMIT = 25

-- The game's Kitchen tabs. An ingredient's tab follows its item type; everything edible
-- that is not a plant, seed, or drink (meat, fish, eggs, cheese, fat, flour, honey...) is
-- "other".
CATEGORIES = {'plants', 'seeds', 'drinks', 'other'}

local CATEGORY_BY_TYPE = {
    PLANT = 'plants',
    PLANT_GROWTH = 'plants',
    SEEDS = 'seeds',
    DRINK = 'drinks',
}

-- Items that are not usable ingredients, as DFHack's autofarm and seedwatch count them.
local SKIP_FLAGS = {
    'dump', 'forbid', 'garbage_collect', 'hostile', 'on_fire', 'rotten', 'trader',
    'in_building', 'construction', 'artifact', 'removed', 'owned', 'encased', 'spider_web',
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function any_flag(item, names)
    for _, name in ipairs(names) do
        if safe(function() return item.flags[name] end) then return true end
    end
    return false
end

-- Material facts that decide whether the game offers the ingredient for cooking or brewing:
-- EDIBLE_COOKED for the pot, a DRINK_MAT reaction product for the still (ban-cooking.lua).
local function material_facts(material)
    local cookable = safe(function() return material.flags.EDIBLE_COOKED end) == true
    local brewable = false
    local ids = safe(function() return material.reaction_product.id end)
    if ids then
        for i = 0, #ids - 1 do
            if ids[i].value == 'DRINK_MAT' then brewable = true end
        end
    end
    return cookable, brewable
end

local function exclusion(exc, item_type, subtype, mat_type, mat_index)
    local index = safe(dfhack.kitchen.findExclusion, exc, item_type, subtype, mat_type, mat_index)
    return index ~= nil and index >= 0
end

-- One row per (item type, subtype, material). `key` is what kitchen.set takes back.
local function describe(item_type, subtype, mat_type, mat_index, info, caste_name)
    local type_token = df.item_type[item_type] or tostring(item_type)
    local material_token = info and safe(function() return info:getToken() end) or nil
    local material_name = caste_name or (info and safe(function() return info:toString() end)) or nil
    local cookable, brewable = false, false
    if info and info.material then
        cookable, brewable = material_facts(info.material)
    elseif caste_name then
        -- Creature-caste items (fish, eggs): the pot takes them once prepared; never brewed.
        cookable = type_token ~= 'FISH_RAW'
    end
    if type_token == 'DRINK' then brewable = false end
    if type_token == 'SEEDS' then brewable = false end
    local cook_banned = exclusion({Cook = true}, item_type, subtype, mat_type, mat_index)
    local brew_banned = exclusion({Brew = true}, item_type, subtype, mat_type, mat_index)
    local row = {
        key = ('%s:%d:%d:%d'):format(type_token, subtype, mat_type, mat_index),
        item_type = type_token,
        subtype = subtype,
        material = material_token,
        name = material_name,
        category = CATEGORY_BY_TYPE[type_token] or 'other',
        cookable = cookable,
        brewable = brewable,
        cook = cookable and not cook_banned,
        brew = brewable and not brew_banned,
        cook_banned = cook_banned,
        brew_banned = brew_banned,
        count = 0,
        quantity = 0,
    }
    if type_token == 'PLANT_GROWTH' and info and info.plant then
        local growth = safe(function() return info.plant.growths[subtype] end)
        local growth_name = growth and safe(function() return growth.name end)
        if growth_name and growth_name ~= '' then
            row.name = (row.name or '') .. ' ' .. growth_name
        end
    end
    return row
end

-- The ingredient key of an item: creature-caste items key on race and caste, everything
-- else on the decoded material. Growths carry their growth index as the subtype.
local function item_key(item)
    local item_type = item:getType()
    local token = df.item_type[item_type]
    local subtype = -1
    if token == 'PLANT_GROWTH' then
        subtype = safe(function() return item:getSubtype() end) or -1
    end
    if safe(dfhack.items.isCasteMaterial, item_type) then
        local race = safe(function() return item.race end)
        local caste = safe(function() return item.caste end)
        if race == nil then return nil end
        local name = safe(function()
            local creature = df.global.world.raws.creatures.all[race]
            local caste_name = creature.caste[caste].caste_name[0]
            if caste_name == nil or caste_name == '' then caste_name = creature.name[0] end
            return caste_name
        end)
        return item_type, subtype, race, caste or -1, nil, name
    end
    local info = safe(dfhack.matinfo.decode, item)
    if not info then return nil end
    return item_type, subtype, info.type, info.index, info, nil
end

-- Walks IN_PLAY once. An item is an ingredient when its material can be cooked or brewed,
-- or when it is a drink, seed, plant, or growth (those are listed even when inedible so a
-- ban on them is visible).
local function collect(query)
    local rows, index = {}, {}
    local needle = query and query:lower() or nil
    for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
        if not any_flag(item, SKIP_FLAGS) then
            local item_type, subtype, mat_type, mat_index, info, caste_name = item_key(item)
            if item_type then
                local key = ('%d:%d:%d:%d'):format(item_type, subtype, mat_type, mat_index)
                local row = index[key]
                if not row then
                    local candidate = describe(item_type, subtype, mat_type, mat_index, info,
                                               caste_name)
                    local always = CATEGORY_BY_TYPE[candidate.item_type] ~= nil
                    if candidate.cookable or candidate.brewable or always then
                        local matches = true
                        if needle then
                            local text = ((candidate.name or '') .. ' ' .. (candidate.material or '')
                                          .. ' ' .. candidate.item_type):lower()
                            matches = text:find(needle, 1, true) ~= nil
                        end
                        if matches then
                            row = candidate
                            index[key] = row
                            table.insert(rows, row)
                        else
                            index[key] = false
                        end
                    else
                        index[key] = false
                    end
                end
                if row then
                    row.count = row.count + 1
                    row.quantity = row.quantity + (safe(function() return item:getStackSize() end) or 1)
                end
            end
        end
    end
    return rows
end

local function parse_limit(args)
    if args.limit == nil then return DEFAULT_LIMIT end
    local limit = tonumber(args.limit)
    if not limit or limit < 1 then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be a positive number')
    end
    return math.floor(limit)
end

local function list(args)
    local limit, err = parse_limit(args)
    if err then return err end
    if args.query ~= nil and type(args.query) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"query" must be a string')
    end
    local wanted = args.category
    if wanted ~= nil then
        local known = false
        for _, c in ipairs(CATEGORIES) do if c == wanted then known = true end end
        if not known then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"category" must be one of ' .. table.concat(CATEGORIES, ', '))
        end
    end
    local banned_only = args.banned_only == true
    local categories = {}
    for _, c in ipairs(CATEGORIES) do
        categories[c] = {rows = {}, row_count = 0, truncated = false}
    end
    local rows = collect(args.query)
    table.sort(rows, function(a, b)
        if a.quantity ~= b.quantity then return a.quantity > b.quantity end
        return (a.name or '') < (b.name or '')
    end)
    local total = 0
    for _, row in ipairs(rows) do
        if (wanted == nil or row.category == wanted)
                and (not banned_only or row.cook_banned or row.brew_banned) then
            local cat = categories[row.category]
            cat.row_count = cat.row_count + 1
            total = total + 1
            if #cat.rows < limit then
                table.insert(cat.rows, row)
            else
                cat.truncated = true
            end
        end
    end
    local out, truncated = {}, {}
    for _, c in ipairs(CATEGORIES) do
        local cat = categories[c]
        if cat.row_count > 0 then
            out[c] = cat
            if cat.truncated then table.insert(truncated, c) end
        end
    end
    local exclusions = safe(function() return #df.global.plotinfo.kitchen.item_types end) or 0
    return {
        count = total,
        exclusions = exclusions,
        categories = out,
        truncated = truncated,
        note = 'only ingredients in stock are listed, as the game\'s Kitchen screen does; '
            .. 'cook and brew are what the game will do now, cookable and brewable what the '
            .. 'ingredient allows',
    }
end

----------------------------------------------------------------------------------------------
-- set

-- Resolves kitchen.set's target to (item_type, subtype, mat_type, mat_index, info, caste).
-- Accepts a `key` from kitchen.list, or `item_type` plus `material` (a material token such
-- as PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL, or a plant or creature name) and `subtype`.
local function resolve_target(args)
    if type(args.key) == 'string' then
        local type_token, subtype, mat_type, mat_index =
            args.key:match('^([%u_]+):(%-?%d+):(%-?%d+):(%-?%d+)$')
        if not type_token or df.item_type[type_token] == nil then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
                '"key" must look like PLANT:-1:419:0 (an item type token and three numbers)')
        end
        local item_type = df.item_type[type_token]
        local info = nil
        local caste = nil
        if safe(dfhack.items.isCasteMaterial, item_type) then
            caste = safe(function()
                local creature = df.global.world.raws.creatures.all[tonumber(mat_type)]
                return creature.caste[tonumber(mat_index)].caste_name[0]
            end) or 'creature'
        else
            info = safe(dfhack.matinfo.decode, tonumber(mat_type), tonumber(mat_index))
            if not info then
                return nil, rpc.error_result(rpc.ERR_NOT_FOUND,
                    'no material with type ' .. mat_type .. ' and index ' .. mat_index)
            end
        end
        return item_type, tonumber(subtype), tonumber(mat_type), tonumber(mat_index), info, caste
    end
    if type(args.item_type) ~= 'string' or type(args.material) ~= 'string' then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            'pass "key" from list_kitchen, or "item_type" (PLANT, SEEDS, DRINK, PLANT_GROWTH, '
            .. 'MEAT, ...) with "material"')
    end
    local type_token = args.item_type:upper()
    local item_type = df.item_type[type_token]
    if item_type == nil then
        return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, 'unknown item type ' .. args.item_type)
    end
    local subtype = -1
    if args.subtype ~= nil then
        subtype = tonumber(args.subtype)
        if not subtype then
            return nil, rpc.error_result(rpc.ERR_BAD_REQUEST, '"subtype" must be a number')
        end
        subtype = math.floor(subtype)
    end
    local info = safe(dfhack.matinfo.find, args.material)
    if not info then
        -- Plain plant names: "plump helmet" -> the plant's structural material.
        local wanted = args.material:lower()
        for _, plant in ipairs(df.global.world.raws.plants.all) do
            local name = safe(function() return plant.name end)
            if name and name:lower() == wanted then
                info = safe(dfhack.matinfo.decode, plant.material_defs.type.basic_mat,
                            plant.material_defs.idx.basic_mat)
                if type_token == 'SEEDS' then
                    info = safe(dfhack.matinfo.decode, plant.material_defs.type.seed,
                                plant.material_defs.idx.seed) or info
                elseif type_token == 'DRINK' then
                    info = safe(dfhack.matinfo.decode, plant.material_defs.type.drink,
                                plant.material_defs.idx.drink) or info
                end
                break
            end
        end
    end
    if not info then
        return nil, rpc.error_result(rpc.ERR_NOT_FOUND,
            ('no material matches "%s"; use a key from list_kitchen or a token such as '
             .. 'PLANT_MAT:MUSHROOM_HELMET_PLUMP:STRUCTURAL'):format(args.material))
    end
    return item_type, subtype, info.type, info.index, info, nil
end

local function apply(flag, item_type, subtype, mat_type, mat_index, allow)
    local banned = exclusion(flag, item_type, subtype, mat_type, mat_index)
    if allow and banned then
        local ok = dfhack.kitchen.removeExclusion(flag, item_type, subtype, mat_type, mat_index)
        return ok == true
    elseif allow == false and not banned then
        local ok = dfhack.kitchen.addExclusion(flag, item_type, subtype, mat_type, mat_index)
        return ok == true
    end
    return false
end

local function set(args)
    local item_type, subtype, mat_type, mat_index, info, caste = resolve_target(args)
    if item_type == nil then return subtype end
    if args.cook ~= nil and type(args.cook) ~= 'boolean' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"cook" must be true or false')
    end
    if args.brew ~= nil and type(args.brew) ~= 'boolean' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"brew" must be true or false')
    end
    if args.cook == nil and args.brew == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "cook" and/or "brew"')
    end
    local before = describe(item_type, subtype, mat_type, mat_index, info, caste)
    local changed = {}
    if args.cook ~= nil and apply({Cook = true}, item_type, subtype, mat_type, mat_index, args.cook) then
        table.insert(changed, 'cook')
    end
    if args.brew ~= nil and apply({Brew = true}, item_type, subtype, mat_type, mat_index, args.brew) then
        table.insert(changed, 'brew')
    end
    local after = describe(item_type, subtype, mat_type, mat_index, info, caste)
    after.count, after.quantity = nil, nil
    before.count, before.quantity = nil, nil
    local warnings = {}
    if args.cook == true and not after.cookable then
        table.insert(warnings, 'the game never cooks this ingredient, so allowing it changes nothing')
    end
    if args.brew == true and not after.brewable then
        table.insert(warnings, 'the game never brews this ingredient, so allowing it changes nothing')
    end
    return {changed = changed, before = before, after = after, warnings = warnings}
end

function ops()
    return {
        ['kitchen.list'] = {namespace = 'stocks', handler = list, needs_map = true},
        ['kitchen.set'] = {namespace = 'kitchen_write', handler = set, needs_map = true},
    }
end
