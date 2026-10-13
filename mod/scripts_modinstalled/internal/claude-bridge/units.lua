-- Unit listing, search, and basic info. Read-only. Design: docs/ProjectPlan.md section 8.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

local U = dfhack.units

-- Older or newer DFHack builds may lack a helper; treat a missing one as "false".
local function helper(name)
    return U[name] or function() return false end
end

local isCitizen = helper('isCitizen')
local isResident = helper('isResident')
local isInvader = helper('isInvader')
local isUndead = helper('isUndead')
local isMerchant = helper('isMerchant')
local isDiplomat = helper('isDiplomat')
local isVisitor = helper('isVisitor')
local isAnimal = helper('isAnimal')
local isTame = helper('isTame')
local isDomesticated = helper('isDomesticated')
local isPet = helper('isPet')
local isOwnCiv = helper('isOwnCiv')
local isWar = helper('isWar')
local isHunter = helper('isHunter')
local isGrazer = helper('isGrazer')
local isMilkable = helper('isMilkable')
local isEggLayer = helper('isEggLayer')
local isWildlife = helper('isWildlife')
local isAgitated = helper('isAgitated')
local isDanger = helper('isDanger')
local isDead = helper('isDead')
local isActive = helper('isActive')

BUCKETS = {'citizen', 'domesticated', 'other'}

KINDS = {
    citizen = {'citizen', 'resident'},
    domesticated = {'pet', 'war_animal', 'hunting_animal', 'livestock', 'stray'},
    other = {'visitor', 'merchant', 'diplomat', 'invader', 'undead', 'wildlife',
             'agitated', 'hostile', 'other'},
}

-- dfhack.units.getStressCategory: 0 is the most stressed, 6 the least. Same names as
-- DFHack's gui/unit-info-viewer overall-mood overlay.
MOOD_NAMES = {
    [0] = 'miserable', 'unhappy', 'displeased', 'content', 'pleased', 'happy', 'ecstatic',
}

local GENDER_NAMES = {[0] = 'female', [1] = 'male', [2] = 'none'}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function has(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

local function domesticated_kind(unit)
    if isPet(unit) then return 'pet' end
    if isWar(unit) then return 'war_animal' end
    if isHunter(unit) then return 'hunting_animal' end
    if isGrazer(unit) or isMilkable(unit) or isEggLayer(unit) then return 'livestock' end
    return 'stray'
end

local function other_kind(unit)
    if isInvader(unit) then return 'invader' end
    if isUndead(unit) then return 'undead' end
    if isMerchant(unit) then return 'merchant' end
    if isDiplomat(unit) then return 'diplomat' end
    if isVisitor(unit) then return 'visitor' end
    if isAgitated(unit) then return 'agitated' end
    if isWildlife(unit) or isAnimal(unit) then return 'wildlife' end
    if isDanger(unit) then return 'hostile' end
    return 'other'
end

-- Returns bucket, kind. Every unit lands in exactly one bucket.
function classify(unit)
    if isCitizen(unit, true) then return 'citizen', 'citizen' end
    if isResident(unit, true) then return 'citizen', 'resident' end
    if isAnimal(unit) and not isInvader(unit) and not isMerchant(unit) and not isUndead(unit)
        and (isPet(unit) or isTame(unit) or isDomesticated(unit) or isOwnCiv(unit)) then
        return 'domesticated', domesticated_kind(unit)
    end
    return 'other', other_kind(unit)
end

local function gender(unit)
    local sex = safe(function() return unit.sex end)
    if sex == nil then return 'none' end
    return GENDER_NAMES[sex] or 'none'
end

function mood(unit)
    local category = safe(U.getStressCategory, unit)
    if category == nil then return 'none' end
    return MOOD_NAMES[category] or 'none'
end

local function owner_name(unit)
    local owner_id = safe(function() return unit.relationship_ids.PetOwner end)
    if not owner_id or owner_id < 0 then return 'None' end
    local owner = df.unit.find(owner_id)
    if not owner then return 'None' end
    return safe(U.getReadableName, owner) or 'None'
end

-- getPosition returns three values, so it cannot go through safe().
local function position(unit)
    local ok, x, y, z = pcall(U.getPosition, unit)
    if not ok or x == nil then return nil end
    return {x = x, y = y, z = z}
end

local function current_job(unit)
    return safe(function()
        local job = unit.job.current_job
        return job and dfhack.job.getName(job) or nil
    end)
end

local function nickname(unit)
    local nick = safe(function() return unit.name.nickname end)
    if nick == nil or nick == '' then return nil end
    return nick
end

local function caste_name(unit)
    return safe(function()
        local caste = U.getCasteRaw(unit)
        return caste and caste.caste_name[0] or nil
    end)
end

local function squad(unit)
    return safe(function()
        local squad_id = unit.military.squad_id
        if squad_id < 0 then return nil end
        local name = dfhack.military and dfhack.military.getSquadName
            and dfhack.military.getSquadName(squad_id) or nil
        return {id = squad_id, name = name, position = unit.military.squad_position}
    end)
end

local function flags(unit)
    local out = {}
    local checks = {
        caged = function() return unit.flags1.caged end,
        chained = function() return unit.flags1.chained end,
        marauder = function() return unit.flags1.marauder end,
        ghost = function() return U.isGhost(unit) end,
        crazed = function() return U.isCrazed(unit) end,
        insane = function() return not U.isSane(unit) end,
        baby = function() return U.isBaby(unit) end,
        child = function() return U.isChild(unit) end,
        adult = function() return U.isAdult(unit) end,
        opposed_to_life = function() return U.isOpposedToLife(unit) end,
        marked_for_slaughter = function() return U.isMarkedForSlaughter(unit) end,
    }
    for key, fn in pairs(checks) do
        if safe(fn) then out[key] = true end
    end
    return out
end

-- One list row. bucket/kind may be passed when the caller already classified the unit.
function row(unit, bucket, kind)
    if not bucket then
        bucket, kind = classify(unit)
    end
    local out = {
        id = unit.id,
        name = safe(U.getReadableName, unit) or ('unit ' .. unit.id),
        unit = bucket,
        kind = kind,
        gender = gender(unit),
        creature = safe(U.getRaceReadableName, unit),
    }
    if bucket == 'domesticated' then
        out.owner = owner_name(unit)
    else
        out.mood = mood(unit)
    end
    return out
end

function detail(unit)
    local out = row(unit)
    out.nickname = nickname(unit)
    out.caste = caste_name(unit)
    out.profession = safe(U.getProfessionName, unit)
    out.custom_profession = safe(function()
        local p = unit.custom_profession
        return p ~= '' and p or nil
    end)
    out.age = safe(U.getAge, unit, true)
    out.pos = position(unit)
    out.job = current_job(unit)
    out.hist_figure_id = unit.hist_figure_id
    out.civ_id = unit.civ_id
    out.squad = squad(unit)
    out.flags = flags(unit)
    out.dead = isDead(unit) and true or false
    if out.unit == 'domesticated' then
        out.mood = mood(unit)
    end
    return out
end

local function visible(include_dead, unit)
    if include_dead then return true end
    return isActive(unit) and not isDead(unit)
end

-- Iterates units the caller may see, calling fn(unit, bucket, kind) for each.
local function each_unit(include_dead, fn)
    for _, unit in ipairs(df.global.world.units.active) do
        if visible(include_dead, unit) then
            local bucket, kind = classify(unit)
            fn(unit, bucket, kind)
        end
    end
end

local function check_bucket(bucket)
    if bucket ~= nil and not has(BUCKETS, bucket) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"bucket" must be one of ' .. table.concat(BUCKETS, ', '))
    end
    return nil
end

local function list(args)
    local err = check_bucket(args.bucket)
    if err then return err end
    local include_dead = args.include_dead == true
    local limit = tonumber(args.limit) or 200
    local offset = tonumber(args.offset) or 0
    local wanted_bucket = args.bucket
    local wanted_kind = args.kind

    local by_bucket = {citizen = 0, domesticated = 0, other = 0}
    local by_kind = {}
    local rows = {}
    local total = 0
    each_unit(include_dead, function(unit, bucket, kind)
        by_bucket[bucket] = by_bucket[bucket] + 1
        by_kind[kind] = (by_kind[kind] or 0) + 1
        if (wanted_bucket == nil or wanted_bucket == bucket)
            and (wanted_kind == nil or wanted_kind == kind) then
            total = total + 1
            if total > offset and #rows < limit then
                table.insert(rows, row(unit, bucket, kind))
            end
        end
    end)
    return {
        total = total,
        count = #rows,
        offset = offset,
        units = rows,
        counts_by_bucket = by_bucket,
        counts_by_kind = by_kind,
    }
end

-- Strings a search query is matched against, all lowercased.
local function search_text(unit)
    local parts = {}
    local function add(value)
        if type(value) == 'string' and value ~= '' then
            table.insert(parts, value:lower())
        end
    end
    add(safe(U.getReadableName, unit))
    add(safe(U.getRaceReadableName, unit))
    add(nickname(unit))
    add(safe(function()
        return dfhack.translation.translateName(U.getVisibleName(unit), false)
    end))
    add(safe(function()
        return dfhack.translation.translateName(U.getVisibleName(unit), true)
    end))
    return table.concat(parts, '\n')
end

local function find(args)
    if type(args.query) ~= 'string' or args.query:match('^%s*$') then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"query" must be a non-empty string')
    end
    local err = check_bucket(args.bucket)
    if err then return err end
    local query = args.query:lower()
    local limit = tonumber(args.limit) or 20
    local include_dead = args.include_dead == true

    local rows = {}
    local total = 0
    each_unit(include_dead, function(unit, bucket, kind)
        if (args.bucket == nil or args.bucket == bucket)
            and search_text(unit):find(query, 1, true) then
            total = total + 1
            if #rows < limit then
                table.insert(rows, row(unit, bucket, kind))
            end
        end
    end)
    return {query = args.query, total = total, count = #rows, units = rows}
end

local function get(args)
    local id = tonumber(args.id)
    if not id then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a unit id')
    end
    local unit = df.unit.find(id)
    if not unit then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'no unit with id ' .. id)
    end
    return detail(unit)
end

function ops()
    return {
        ['units.list'] = {namespace = 'units', handler = list, needs_map = true},
        ['units.find'] = {namespace = 'units', handler = find, needs_map = true},
        ['units.get'] = {namespace = 'units', handler = get, needs_map = true},
    }
end
