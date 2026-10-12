-- Unit listing and detail. Read-only.
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
local isOwnCiv = helper('isOwnCiv')
local isWildlife = helper('isWildlife')
local isDanger = helper('isDanger')
local isDead = helper('isDead')
local isActive = helper('isActive')

CATEGORIES = {
    'citizen', 'resident', 'visitor', 'merchant', 'diplomat',
    'animal', 'wildlife', 'invader', 'undead', 'hostile', 'other',
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

function categorize(unit)
    if isCitizen(unit, true) then return 'citizen' end
    if isResident(unit, true) then return 'resident' end
    if isInvader(unit) then return 'invader' end
    if isUndead(unit) then return 'undead' end
    if isMerchant(unit) then return 'merchant' end
    if isDiplomat(unit) then return 'diplomat' end
    if isVisitor(unit) then return 'visitor' end
    if isAnimal(unit) then
        if isTame(unit) or isOwnCiv(unit) then return 'animal' end
        return 'wildlife'
    end
    if isWildlife(unit) then return 'wildlife' end
    if isDanger(unit) then return 'hostile' end
    return 'other'
end

local SEX_NAMES = {[0] = 'female', [1] = 'male', [2] = 'none'}

local function sex_name(unit)
    local sex = safe(function() return unit.sex end)
    if sex == nil then return nil end
    return SEX_NAMES[sex] or 'unknown'
end

local function position(unit)
    local x, y, z = safe(U.getPosition, unit)
    if x == nil then
        return nil
    end
    return {x = x, y = y, z = z}
end

local function current_job(unit)
    return safe(function()
        local job = unit.job.current_job
        return job and dfhack.job.getName(job) or nil
    end)
end

function summary(unit, category)
    return {
        id = unit.id,
        name = safe(U.getReadableName, unit),
        category = category or categorize(unit),
        race = safe(U.getRaceReadableName, unit),
        profession = safe(U.getProfessionName, unit),
        age = safe(U.getAge, unit, true),
        sex = sex_name(unit),
        pos = position(unit),
        job = current_job(unit),
        dead = isDead(unit) and true or false,
    }
end

local function skills(unit)
    local out = {}
    local soul = safe(function() return unit.status.current_soul end)
    if not soul then return out end
    for _, skill in ipairs(soul.skills) do
        if skill.rating > 0 then
            table.insert(out, {
                skill = df.job_skill[skill.id] or tostring(skill.id),
                rating = skill.rating,
                level = df.skill_rating[math.min(skill.rating, df.skill_rating._last_item)] or nil,
                experience = skill.experience,
            })
        end
    end
    table.sort(out, function(a, b) return a.rating > b.rating end)
    return out
end

local function labors(unit)
    local out = {}
    local ok = pcall(function()
        for i = 0, df.unit_labor._last_item do
            if unit.status.labors[i] then
                table.insert(out, df.unit_labor[i] or tostring(i))
            end
        end
    end)
    if not ok then return nil end
    return out
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
        crazed = function() return U.isCrazed(unit) end,
        baby = function() return U.isBaby(unit) end,
        child = function() return U.isChild(unit) end,
        adult = function() return U.isAdult(unit) end,
        opposed_to_life = function() return U.isOpposedToLife(unit) end,
    }
    for key, fn in pairs(checks) do
        local value = safe(fn)
        if value then out[key] = true end
    end
    return out
end

function detail(unit)
    local row = summary(unit)
    row.mood = safe(function() return df.mood_type[unit.mood] end)
    row.stress = safe(function() return unit.status.current_soul.personality.stress end)
    row.stress_category = safe(U.getStressCategory, unit)
    row.skills = skills(unit)
    row.labors = labors(unit)
    row.wounds = safe(function() return #unit.body.wounds end)
    row.blood = safe(function() return unit.body.blood_count end)
    row.squad = squad(unit)
    row.flags = flags(unit)
    row.civ_id = unit.civ_id
    return row
end

local function matches(wanted, category)
    if wanted == nil then return true end
    if type(wanted) == 'string' then return wanted == category end
    for _, c in ipairs(wanted) do
        if c == category then return true end
    end
    return false
end

local function list(args)
    local include_dead = args.include_dead == true
    local limit = tonumber(args.limit) or 200
    local offset = tonumber(args.offset) or 0
    local wanted = args.category

    local counts = {}
    local rows = {}
    local total = 0
    for _, unit in ipairs(df.global.world.units.active) do
        if (include_dead or not isDead(unit)) and (isActive(unit) or include_dead) then
            local category = categorize(unit)
            counts[category] = (counts[category] or 0) + 1
            if matches(wanted, category) then
                total = total + 1
                if total > offset and #rows < limit then
                    table.insert(rows, summary(unit, category))
                end
            end
        end
    end
    return {
        total = total,
        count = #rows,
        offset = offset,
        units = rows,
        counts_by_category = counts,
    }
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
        ['units.get'] = {namespace = 'units', handler = get, needs_map = true},
    }
end
