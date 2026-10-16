-- Event capture and batching (plan section 13, Phase 13). Announcements arrive through
-- eventful.onReport and are mapped to kinds by announcement type; deaths, invasions, and
-- fights through the other eventful hooks; what the game never announces (petitions,
-- ghosts, moody dwarves missing an item, artifacts dug up, season changes) is polled every
-- 100 ticks. Events sit in a ring of 200 and events.poll hands them out once the newest is
-- two seconds old or 50 are waiting. Only kinds the player enabled are queued.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local state = reqscript('internal/claude-bridge/state')
local eventful = require('plugins.eventful')
local repeatutil = require('repeat-util')

local HOOK_KEY = 'claude_bridge'
local POLL_JOB = 'claude-bridge-events'
POLL_TICKS = 100
CAPACITY = 200
QUIET_MS = 2000
BATCH_MAX = 50
FIGHT_REPEAT_MS = 10000

-- Kinds in display order. `types` are announcement_type names (df-structures master,
-- checked 2026-10-15); names missing on this build are ignored.
KINDS = {
    {key = 'mineral_discovered', label = 'Mineral discovered', default = true,
     types = {'STRUCK_MINERAL', 'STRUCK_ECONOMIC_MINERAL'}},
    {key = 'cavern_discovered', label = 'Cavern discovered', default = false,
     types = {'FEATURE_DISCOVERY'}},
    {key = 'adamantine_found', label = 'Adamantine found', default = false,
     types = {'STRUCK_DEEP_METAL'}},
    {key = 'artifact_found', label = 'Artifact dug up', default = false, poll = true},
    {key = 'strange_mood', label = 'Dwarf enters strange mood', default = false,
     types = {'STRANGE_MOOD', 'MOOD_BUILDING_CLAIMED', 'ARTIFACT_BEGUN'}},
    {key = 'mood_item_missing', label = 'Moody dwarf cannot find item', default = false, poll = true},
    {key = 'artifact_created', label = 'Moody dwarf creates artifact', default = false,
     types = {'MADE_ARTIFACT', 'NAMED_ARTIFACT'}},
    {key = 'artifact_stolen_or_missing', label = 'Artifact missing or stolen', default = false,
     types = {'CRIME_WITNESS_STOLEN', 'CRIME_WITNESS_ITEM_MISSING', 'CRIME_WITNESS_ITEM_MOVED',
              'CRIME_WITNESS_HANDOFF', 'CREATURE_STEALS_OBJECT'}},
    {key = 'citizen_missing', label = 'Citizen is missing', default = false,
     types = {'CITIZEN_MISSING', 'PET_MISSING'}},
    {key = 'citizen_dead', label = 'Citizen found dead', default = false,
     types = {'CITIZEN_DEATH'}, death = true},
    {key = 'ghost_appeared', label = 'Ghost appeared', default = false, poll = true},
    {key = 'ghost_rested', label = 'Ghost put to rest', default = false, poll = true},
    {key = 'caravan_arrived', label = 'Caravan arrived', default = false,
     types = {'CARAVAN_ARRIVAL', 'FIRST_CARAVAN_ARRIVAL', 'MERCHANTS_UNLOADING',
              'MERCHANTS_NEED_DEPOT', 'MERCHANT_WAGONS_BYPASSED'}},
    {key = 'caravan_leaving', label = 'Caravan leaving', default = false,
     types = {'MERCHANTS_LEAVING_SOON', 'MERCHANTS_EMBARKED'}},
    {key = 'diplomat_arrived', label = 'Diplomat arrived', default = false,
     types = {'DIPLOMAT_ARRIVAL', 'LIAISON_ARRIVAL', 'TRADE_DIPLOMAT_ARRIVAL', 'DIPLOMAT_LEFT_UNHAPPY'}},
    {key = 'monster_arrived', label = 'Hostile monster arrived', default = false,
     types = {'MEGABEAST_ARRIVAL', 'WEREBEAST_ARRIVAL', 'BEAST_AMBUSH', 'AMBUSH_DEFENDER',
              'AMBUSH_RESIDENT', 'UNDEAD_ATTACK', 'NAMED_RESIDENT_CREATURE'}},
    {key = 'invaders_arrived', label = 'Invaders arrived', default = false,
     types = {'AMBUSH_AMBUSHER', 'AMBUSH_AMBUSHER_NATURE', 'AMBUSH_THIEF', 'AMBUSH_SNATCHER'},
     invasion = true},
    {key = 'season_changed', label = 'Season changed', default = false, poll = true},
    {key = 'units_fighting', label = 'Units are fighting', default = true, attack = true},
    {key = 'sparring', label = 'Soldiers sparring', default = false, attack = true},
    {key = 'petition', label = 'Petition', default = true, poll = true},
}

-- Module state survives `claude-bridge reload` (re-read of this file).
queue = queue or {}
next_seq = next_seq or 1
dropped = dropped or 0
running = running or false
baseline = baseline or nil
fight_seen = fight_seen or {}

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

local function now_ms()
    return dfhack.getTickCount()
end

function kind_spec(key)
    for _, k in ipairs(KINDS) do
        if k.key == key then return k end
    end
    return nil
end

local function enabled(key)
    return state.is_event_enabled(key)
end

-- announcement_type value -> kind key, built once per load from the names this build has.
local type_to_kind = nil
local function type_map()
    if type_to_kind then return type_to_kind end
    type_to_kind = {}
    for _, k in ipairs(KINDS) do
        for _, name in ipairs(k.types or {}) do
            local value = safe(function() return df.announcement_type[name] end)
            if type(value) == 'number' then type_to_kind[value] = k.key end
        end
    end
    return type_to_kind
end

----------------------------------------------------------------------------------------------
-- queue

function push(kind, fields)
    if not enabled(kind) then return nil end
    local entry = {
        seq = next_seq,
        kind = kind,
        tick = safe(function() return df.global.world.frame_counter end) or 0,
        ms = now_ms(),
        text = fields.text or kind_spec(kind).label,
        pos = fields.pos,
        unit_ids = fields.unit_ids,
        building_id = fields.building_id,
        item_id = fields.item_id,
        extra = fields.extra,
    }
    next_seq = next_seq + 1
    table.insert(queue, entry)
    while #queue > CAPACITY do
        table.remove(queue, 1)
        dropped = dropped + 1
    end
    return entry
end

-- Special kinds (goals, timer, test) bypass the per-kind toggles.
function push_special(kind, text, extra)
    local entry = {
        seq = next_seq, kind = kind,
        tick = safe(function() return df.global.world.frame_counter end) or 0,
        ms = now_ms(), text = text, extra = extra,
    }
    next_seq = next_seq + 1
    table.insert(queue, entry)
    while #queue > CAPACITY do
        table.remove(queue, 1)
        dropped = dropped + 1
    end
    return entry
end

local function unit_ref(id)
    local unit = id and df.unit.find(id)
    if not unit then return nil end
    return {id = unit.id, name = safe(dfhack.units.getReadableName, unit)}
end

local function pos_of(thing)
    local x, y, z = safe(function() return thing.x end), safe(function() return thing.y end),
                    safe(function() return thing.z end)
    if x == nil or x < 0 then return nil end
    return {x = x, y = y, z = z}
end

----------------------------------------------------------------------------------------------
-- eventful hooks

local function on_report(report_id)
    local report = safe(df.report.find, report_id)
    if not report then return end
    if safe(function() return report.flags.continuation end) then return end
    local kind = type_map()[report.type]
    if not kind then return end
    local pos = pos_of(report.pos)
    local units = {}
    if pos then
        pcall(function()
            for _, unit in ipairs(dfhack.units.getUnitsInBox(pos.x, pos.y, pos.z, pos.x, pos.y, pos.z)) do
                table.insert(units, unit.id)
            end
        end)
    end
    push(kind, {text = report.text, pos = pos, unit_ids = #units > 0 and units or nil,
                extra = {announcement = enum_name(df.announcement_type, report.type)}})
end

local function on_unit_death(unit_id)
    local unit = df.unit.find(unit_id)
    if not unit or not safe(dfhack.units.isCitizen, unit, true) then return end
    local ref = unit_ref(unit_id)
    push('citizen_dead', {text = (ref and ref.name or ('unit ' .. unit_id)) .. ' has died',
                          pos = pos_of(unit.pos), unit_ids = {unit_id}})
end

local function on_invasion(invasion_id)
    local info = nil
    pcall(function()
        for _, inv in ipairs(df.global.plotinfo.invasions.list) do
            if inv.id == invasion_id then info = inv end
        end
    end)
    local civ = info and safe(function()
        return dfhack.translation.translateName(df.historical_entity.find(info.civ_id).name, true)
    end)
    push('invaders_arrived', {text = 'Invaders have arrived' .. (civ and (' from ' .. civ) or ''),
                              extra = {invasion_id = invasion_id, size = info and info.size or nil}})
end

local function fort_controlled(unit)
    return unit and (safe(dfhack.units.isCitizen, unit, true) or safe(dfhack.units.isOwnCiv, unit)
                     or safe(dfhack.units.isPet, unit)) or false
end

local function on_unit_attack(attacker_id, defender_id, wound_id)
    local a, b = math.min(attacker_id, defender_id), math.max(attacker_id, defender_id)
    local key = a .. ':' .. b
    local t = now_ms()
    if fight_seen[key] and t - fight_seen[key] < FIGHT_REPEAT_MS then return end
    fight_seen[key] = t
    local attacker, defender = df.unit.find(attacker_id), df.unit.find(defender_id)
    local kind = (fort_controlled(attacker) and fort_controlled(defender)) and 'sparring' or 'units_fighting'
    local ar, dr = unit_ref(attacker_id), unit_ref(defender_id)
    push(kind, {
        text = ((ar and ar.name) or ('unit ' .. attacker_id)) .. ' attacks '
            .. ((dr and dr.name) or ('unit ' .. defender_id)),
        pos = attacker and pos_of(attacker.pos) or nil,
        unit_ids = {attacker_id, defender_id},
    })
end

----------------------------------------------------------------------------------------------
-- pollers

local function petition_set()
    local set = {}
    pcall(function()
        for _, id in ipairs(df.global.plotinfo.petitions) do set[id] = true end
    end)
    return set
end

local function ghost_set()
    local set = {}
    pcall(function()
        for _, unit in ipairs(df.global.world.units.active) do
            if dfhack.units.isGhost(unit) then set[unit.id] = true end
        end
    end)
    return set
end

-- Citizens in a strange mood whose job stalled waiting for an item (notify's rule).
local function moody_waiting_set()
    local set = {}
    pcall(function()
        for _, unit in ipairs(dfhack.units.getCitizens(true)) do
            local job = unit.job.current_job
            if job and df.job_type_class[df.job_type.attrs[job.job_type].type] == 'StrangeMood'
                    and not (job.flags.fetching or job.flags.bringing or job.flags.working)
                    and dfhack.buildings.getHolderBuilding and unit.path.goal ~= df.unit_path_goal.None then
                set[unit.id] = true
            end
        end
    end)
    return set
end

-- Artifacts whose item is on the map on a revealed tile.
local function revealed_artifact_set()
    local set = {}
    pcall(function()
        for _, record in ipairs(df.global.world.artifacts.all) do
            local item = record.item
            if item then
                local ok, x, y, z = pcall(dfhack.items.getPosition, item)
                if ok and x and x >= 0 then
                    local des = dfhack.maps.getTileFlags({x = x, y = y, z = z})
                    if des and not des.hidden then set[record.id] = {x = x, y = y, z = z, item = item.id} end
                end
            end
        end
    end)
    return set
end

local function describe_petition(id)
    local text = 'A petition awaits an answer'
    pcall(function()
        local agreement = df.agreement.find(id)
        local details = agreement.details[0]
        local kind = df.agreement_details_type[details.type]
        text = ('A %s petition awaits an answer'):format(tostring(kind):lower())
    end)
    return text
end

local function poll()
    if not dfhack.isMapLoaded() then return end
    local current = {
        petitions = petition_set(), ghosts = ghost_set(), moody = moody_waiting_set(),
        artifacts = revealed_artifact_set(),
        season = safe(function() return df.global.cur_season end),
    }
    if not baseline then
        baseline = current
        return
    end
    for id in pairs(current.petitions) do
        if not baseline.petitions[id] then
            push('petition', {text = describe_petition(id), extra = {agreement_id = id}})
        end
    end
    for id in pairs(current.ghosts) do
        if not baseline.ghosts[id] then
            local ref = unit_ref(id)
            local unit = df.unit.find(id)
            push('ghost_appeared', {text = ((ref and ref.name) or ('unit ' .. id)) .. ' has risen as a ghost',
                                    pos = unit and pos_of(unit.pos) or nil, unit_ids = {id}})
        end
    end
    for id in pairs(baseline.ghosts) do
        if not current.ghosts[id] then
            local ref = unit_ref(id)
            push('ghost_rested', {text = ((ref and ref.name) or ('unit ' .. id)) .. ' has been put to rest',
                                  unit_ids = {id}})
        end
    end
    for id in pairs(current.moody) do
        if not baseline.moody[id] then
            local ref = unit_ref(id)
            local unit = df.unit.find(id)
            push('mood_item_missing', {text = ((ref and ref.name) or ('unit ' .. id))
                                       .. ' is in a strange mood and cannot find an item',
                                       pos = unit and pos_of(unit.pos) or nil, unit_ids = {id}})
        end
    end
    for id, where in pairs(current.artifacts) do
        if not baseline.artifacts[id] then
            local name = safe(function()
                return dfhack.translation.translateName(df.artifact_record.find(id).name, true)
            end)
            push('artifact_found', {text = 'An artifact has been uncovered: ' .. (name or ('artifact ' .. id)),
                                    pos = {x = where.x, y = where.y, z = where.z}, item_id = where.item,
                                    extra = {artifact_id = id}})
        end
    end
    if current.season ~= nil and baseline.season ~= nil and current.season ~= baseline.season then
        local name = enum_name(df.season, current.season)
        push('season_changed', {text = (name or 'A new season') .. ' has arrived', extra = {season = name}})
    end
    baseline = current
end

----------------------------------------------------------------------------------------------
-- start and stop (called by the control script)

function start()
    if running then return end
    pcall(function()
        eventful.enableEvent(eventful.eventType.REPORT, 1)
        eventful.enableEvent(eventful.eventType.UNIT_DEATH, 1)
        eventful.enableEvent(eventful.eventType.INVASION, 1)
        eventful.enableEvent(eventful.eventType.UNIT_ATTACK, 5)
    end)
    eventful.onReport[HOOK_KEY] = function(id) pcall(on_report, id) end
    eventful.onUnitDeath[HOOK_KEY] = function(id) pcall(on_unit_death, id) end
    eventful.onInvasion[HOOK_KEY] = function(id) pcall(on_invasion, id) end
    eventful.onUnitAttack[HOOK_KEY] = function(a, d, w) pcall(on_unit_attack, a, d, w) end
    baseline = nil
    repeatutil.scheduleEvery(POLL_JOB, POLL_TICKS, 'ticks', function() pcall(poll) end)
    running = true
end

function stop()
    eventful.onReport[HOOK_KEY] = nil
    eventful.onUnitDeath[HOOK_KEY] = nil
    eventful.onInvasion[HOOK_KEY] = nil
    eventful.onUnitAttack[HOOK_KEY] = nil
    pcall(repeatutil.cancel, POLL_JOB)
    running = false
end

function reset()
    queue = {}
    next_seq = 1
    dropped = 0
    baseline = nil
    fight_seen = {}
end

----------------------------------------------------------------------------------------------
-- ops

local function kinds(args)
    local out = {}
    for _, k in ipairs(KINDS) do
        local source = k.poll and 'poll' or (k.attack and 'attack hook' or (k.types and 'announcement' or 'hook'))
        local missing = {}
        for _, name in ipairs(k.types or {}) do
            if type(safe(function() return df.announcement_type[name] end)) ~= 'number' then
                table.insert(missing, name)
            end
        end
        table.insert(out, {key = k.key, label = k.label, enabled = enabled(k.key), default = k.default,
                           source = source, announcement_types = k.types,
                           missing_types = #missing > 0 and missing or nil})
    end
    return {kinds = out, running = running, queued = #queue, next_seq = next_seq, dropped = dropped}
end

-- after_seq: last sequence the caller has; omit (or pass null) to learn next_seq without
-- taking anything. Returns a batch once the newest waiting event is QUIET_MS old or
-- BATCH_MAX are waiting; otherwise an empty list with `waiting`.
local function poll_op(args)
    local after = tonumber(args.after_seq)
    local limit = math.floor(tonumber(args.limit) or BATCH_MAX)
    if limit < 1 then limit = BATCH_MAX end
    local base = {next_seq = next_seq, dropped = dropped, now_ms = now_ms(), running = running,
                  tick = safe(function() return df.global.world.frame_counter end)}
    if after == nil then
        base.events = {}
        base.waiting = 0
        base.note = 'pass after_seq to receive events; the first call establishes the sequence'
        return base
    end
    -- A reload re-reads this module and restarts the sequence; a caller still holding an
    -- old, higher sequence gets everything queued since.
    if after >= next_seq then after = 0 end
    local pending = {}
    for _, e in ipairs(queue) do
        if e.seq > after then table.insert(pending, e) end
    end
    base.waiting = #pending
    if #pending == 0 then
        base.events = {}
        return base
    end
    local newest = pending[#pending]
    local ready = args.force == true or #pending >= BATCH_MAX or (now_ms() - newest.ms) >= QUIET_MS
    if not ready then
        base.events = {}
        base.quiet_ms_left = QUIET_MS - (now_ms() - newest.ms)
        return base
    end
    local out = {}
    for i = 1, math.min(limit, #pending) do
        local e = pending[i]
        table.insert(out, {seq = e.seq, kind = e.kind, tick = e.tick, text = e.text, pos = e.pos,
                           unit_ids = e.unit_ids, building_id = e.building_id, item_id = e.item_id,
                           extra = e.extra})
    end
    base.events = out
    base.last_seq = out[#out].seq
    base.remaining = #pending - #out
    return base
end

-- For tests and for the goals and timer features: queue an event of any kind.
local function emit(args)
    local kind = args.kind
    if type(kind) ~= 'string' then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"kind" must be a string') end
    local spec = kind_spec(kind)
    if not spec and kind ~= 'test' then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'unknown event kind ' .. kind)
    end
    if spec and not enabled(kind) then
        return {queued = false, note = 'kind ' .. kind .. ' is disabled in settings'}
    end
    local entry
    if spec then
        entry = push(kind, {text = args.text, pos = args.pos})
    else
        entry = push_special('test', args.text or 'test event')
    end
    return {queued = entry ~= nil, seq = entry and entry.seq or nil}
end

function ops()
    return {
        ['events.kinds'] = {namespace = 'events', handler = kinds},
        ['events.poll'] = {namespace = 'events', handler = poll_op},
        ['events.emit'] = {namespace = 'events', handler = emit},
    }
end
