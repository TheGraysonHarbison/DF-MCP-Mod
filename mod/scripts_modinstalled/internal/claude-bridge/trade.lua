-- Trade (plan section 13, Phase 17.0): caravans, the depot, the broker, hauling goods to
-- the depot, and a trade proposal. Reads follow DFHack's caravan script (hack/scripts/
-- internal/caravan, checked 2026-10-15); hauling uses dfhack.items.markForTrade, which
-- creates the BringItemToDepot job the vanilla "move goods" screen creates. The trade
-- itself is a vanilla mouse button with no DFHack path; trade.offer evaluates a proposal
-- and will drive the game's trade screen once that is verified against a real caravan.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local nobles = reqscript('internal/claude-bridge/nobles')

DEFAULT_LIMIT = 25
LIST_LIMIT = 25
TICKS_PER_DAY = 120  -- caravan_state.time_remaining counts in these (caravan.lua)
STATES = {[0] = 'none', 'approaching', 'at_depot', 'leaving', 'stuck'}

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

-- Masses are kilograms plus milligrams (massst). Items carry theirs once the game has
-- computed it (flags.weight_computed); the caravan's total_capacity is what its animals bear.
local function mass_kg(m)
    if not m then return nil end
    return (safe(function() return m.whole end) or 0) + (safe(function() return m.fraction end) or 0) / 1000000
end

local function item_kg(item)
    if safe(function() return item.flags.weight_computed end) then return mass_kg(item.weight) end
    return nil
end

local function caravan_capacity(car)
    return car and mass_kg(safe(function() return car.total_capacity end)) or nil
end

-- What the merchants are already carrying: their goods at the depot.
local function merchant_load(depot)
    local kg, unknown = 0, 0
    pcall(function()
        for _, entry in ipairs(depot.contained_items) do
            if entry.use_mode == df.building_item_role_type.TEMP and entry.item.flags.trader
                    and entry.item.flags.in_building then
                local w = item_kg(entry.item)
                if w then kg = kg + w else unknown = unknown + 1 end
            end
        end
    end)
    return kg, unknown
end

REPLY_MEANING = {
    Greet = 'ready to trade', Trade = 'deal accepted', Offer = 'gift accepted', Seize = 'goods seized',
    Weight = 'too heavy for the animals', Weight1 = 'too heavy for the animals', Weight2 = 'too heavy for the animals',
    WeightMoney = 'too heavy and too little value', WeightMoney1 = 'too heavy and too little value',
    WeightMoney2 = 'too heavy and too little value',
    Money = 'not enough value offered', Money1 = 'not enough value offered', Money2 = 'not enough value offered',
    Haggle = 'haggling', CounterOffer = 'counter-offer made', NoMoreTradeHaggleFailure = 'merchant refuses to trade further',
    AnimalReject = 'refuses animal products', TreeReject = 'refuses wood', AnimalTreeReject = 'refuses animal and wood goods',
    LiveAnimalReject = 'refuses live animals', ICannotAfford = 'merchant cannot afford it',
    YouCannotAfford = 'the fort offered too little', NoGoods = 'nothing selected',
}

local function unit_ref(unit)
    if not unit then return nil end
    return {id = unit.id, name = safe(dfhack.units.getReadableName, unit),
            pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z}}
end

----------------------------------------------------------------------------------------------
-- caravans

local function civ_of(entity_id)
    local he = safe(df.historical_entity.find, entity_id)
    if not he then return {id = entity_id} end
    local race = safe(function() return df.creature_raw.find(he.race).name[2] end)
    return {id = entity_id, name = translate(he.name, true), race = race,
            home = entity_id == df.global.plotinfo.civ_id}
end

local function caravan_row(index, car)
    local flags = {}
    for _, f in ipairs({'casualty', 'hardship', 'seized', 'offended', 'greatly_offended', 'tribute'}) do
        if safe(function() return car.flags[f] end) then table.insert(flags, f) end
    end
    local state = STATES[car.trade_state] or tostring(car.trade_state)
    return {
        index = index,
        civ = civ_of(car.entity),
        state = state,
        active = car.time_remaining > 0 and (state == 'approaching' or state == 'at_depot')
            and not safe(function() return car.flags.tribute end),
        days_remaining = car.time_remaining / TICKS_PER_DAY,
        mood = car.mood,
        haggle_failures = safe(function() return car.haggle_fail_count end),
        animals = safe(function() return #car.animals end) or 0,
        import_value = car.import_value,
        export_value = safe(function() return car.export_value_total end),
        flags = flags,
        depot_notified = safe(function() return car.depot_notified ~= 0 end),
    }
end

-- The caravan to price against: the one at the depot, else the first approaching one.
local function active_caravan()
    local best = nil
    pcall(function()
        for i, car in ipairs(df.global.plotinfo.caravans) do
            local row = caravan_row(i, car)
            if row.active and (best == nil or row.state == 'at_depot') then best = car end
        end
    end)
    return best
end

local function caravans(args)
    local rows = {}
    pcall(function()
        for i, car in ipairs(df.global.plotinfo.caravans) do table.insert(rows, caravan_row(i, car)) end
    end)
    local merchants = 0
    pcall(function()
        for _, unit in ipairs(df.global.world.units.active) do
            if dfhack.units.isMerchant(unit) and not dfhack.units.isDead(unit) then merchants = merchants + 1 end
        end
    end)
    return {count = #rows, caravans = rows, merchants_on_map = merchants,
            season = enum_name(df.season, df.global.cur_season),
            note = 'elves come in spring, humans in summer, dwarves in autumn; a caravan trades once at the depot'}
end

----------------------------------------------------------------------------------------------
-- depot and broker

local function depots()
    local out = {}
    pcall(function()
        for _, b in ipairs(df.global.world.buildings.other.TRADE_DEPOT) do table.insert(out, b) end
    end)
    return out
end

local function find_depot(args)
    local list = depots()
    if args.depot_id ~= nil then
        local id = tonumber(args.depot_id)
        for _, b in ipairs(list) do if b.id == id then return b end end
        return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'no trade depot with id ' .. tostring(args.depot_id))
    end
    if #list == 0 then return nil, rpc.error_result(rpc.ERR_NOT_FOUND, 'the fort has no trade depot') end
    return list[1]
end

local function is_built(b)
    return safe(function() return b:getBuildStage() >= b:getMaxBuildStage() end) == true
end

local function item_row(item, caravan)
    local row = {id = item.id, description = safe(dfhack.items.getReadableDescription, item),
                 value = safe(dfhack.items.getValue, item, caravan), kg = item_kg(item)}
    if caravan then row.requested = safe(dfhack.items.isRequestedTradeGood, item, caravan) == true end
    if safe(function() return item.flags.trader end) then row.merchant_goods = true end
    return row
end

-- Items waiting to be hauled: BringItemToDepot jobs in the world job list.
local function pending_jobs(depot)
    local out = {}
    pcall(function()
        for _, job in utils.listpairs(df.global.world.jobs.list) do
            if job.job_type == df.job_type.BringItemToDepot then
                local item = job.items[0] and job.items[0].item
                if item then
                    local holder = dfhack.job.getHolder and safe(dfhack.job.getHolder, job)
                    if holder == nil or holder == depot then
                        table.insert(out, {item = item, job_id = job.id, worker = safe(dfhack.job.getWorker, job)})
                    end
                end
            end
        end
    end)
    return out
end

local function depot_jobs(depot)
    local out = {trade_job = nil}
    pcall(function()
        for _, job in ipairs(depot.jobs) do
            if job.job_type == df.job_type.TradeAtDepot then
                out.trade_job = {id = job.id, worker = unit_ref(safe(dfhack.job.getWorker, job))}
            end
        end
    end)
    return out
end

local function depot_info(args)
    local depot, err = find_depot(args)
    if not depot then return err end
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    local caravan = active_caravan()
    local fort_goods, merchant_goods = {}, {}
    local fort_total, merchant_total, fort_value, merchant_value = 0, 0, 0, 0
    pcall(function()
        for _, entry in ipairs(depot.contained_items) do
            -- Released goods (in_building cleared) stay in the list until hauled away.
            if entry.use_mode == df.building_item_role_type.TEMP and entry.item.flags.in_building then
                local item = entry.item
                local row = item_row(item, caravan)
                if item.flags.trader then
                    merchant_total = merchant_total + 1
                    merchant_value = merchant_value + (row.value or 0)
                    if #merchant_goods < limit then table.insert(merchant_goods, row) end
                else
                    fort_total = fort_total + 1
                    fort_value = fort_value + (row.value or 0)
                    if #fort_goods < limit then table.insert(fort_goods, row) end
                end
            end
        end
    end)
    local pending = {}
    local jobs = pending_jobs(depot)
    for _, p in ipairs(jobs) do
        if #pending < limit then
            local row = item_row(p.item, caravan)
            row.worker = unit_ref(p.worker)
            table.insert(pending, row)
        end
    end
    local dj = depot_jobs(depot)
    return {
        id = depot.id,
        pos = {x = depot.centerx, y = depot.centery, z = depot.z},
        bounds = {x1 = depot.x1, y1 = depot.y1, x2 = depot.x2, y2 = depot.y2, z = depot.z},
        built = is_built(depot),
        accessible = safe(function() return depot.accessible end),
        broker_requested = safe(function() return depot.trade_flags.trader_requested end) == true,
        anyone_can_trade = safe(function() return depot.trade_flags.anyone_can_trade end) == true,
        trade_job = dj.trade_job or false,
        times_used = safe(function() return depot.times_used end),
        fort_goods = {count = fort_total, value = fort_value, items = fort_goods, truncated = fort_total > #fort_goods},
        merchant_goods = {count = merchant_total, value = merchant_value, items = merchant_goods,
                          truncated = merchant_total > #merchant_goods},
        pending = {count = #jobs, items = pending, truncated = #jobs > #pending},
        caravan = caravan and civ_of(caravan.entity) or nil,
        note = 'values use the active caravan\'s prices when one is on the map; accessible is the game\'s own wagon-access flag',
    }
end

local function broker_unit()
    local unit = safe(dfhack.units.getUnitByNobleRole, 'broker')
    if unit then return unit end
    local holder = safe(nobles.position_holder, 'BROKER')
    if holder and holder.id then return df.unit.find(holder.id) end
    return nil
end

local function broker(args)
    local depot = depots()[1]
    local unit = broker_unit()
    local out = {assigned = unit ~= nil, broker = unit_ref(unit)}
    if unit then
        local job = safe(function() return unit.job.current_job end)
        out.job = job and (enum_name(df.job_type, job.job_type) or tostring(job.job_type)) or nil
        out.trading = job ~= nil and job.job_type == df.job_type.TradeAtDepot
        if depot then
            out.at_depot = unit.pos.z == depot.z and unit.pos.x >= depot.x1 and unit.pos.x <= depot.x2
                and unit.pos.y >= depot.y1 and unit.pos.y <= depot.y2
        end
        out.appraisal = safe(function()
            return dfhack.units.getNominalSkill(unit, df.job_skill.APPRAISAL, true)
        end)
    end
    if depot then
        out.depot_id = depot.id
        out.broker_requested = safe(function() return depot.trade_flags.trader_requested end) == true
        out.anyone_can_trade = safe(function() return depot.trade_flags.anyone_can_trade end) == true
    end
    -- A diplomat waiting for the site leader keeps that dwarf busy; a broker who is also
    -- the leader never comes to the depot (seen live 2026-10-15).
    out.meetings_waiting = safe(function() return #df.global.plotinfo.meeting_requests end) or 0
    if unit then
        local leader = false
        pcall(function()
            for _, np in ipairs(dfhack.units.getNoblePositions(unit) or {}) do
                local code = np.position.code
                if code == 'EXPEDITION_LEADER' or code == 'MAYOR' or code == 'BARON' or code == 'COUNT'
                        or code == 'DUKE' or code == 'MONARCH' then leader = true end
            end
        end)
        out.is_site_leader = leader
        if leader and out.meetings_waiting > 0 then
            out.warning = 'the broker is also the site leader and a diplomat is waiting to meet them, so they will not '
                .. 'come to the depot; appoint another dwarf as BROKER (assign_noble) or finish the meeting first'
        end
    end
    if not unit then out.note = 'no broker appointed; assign one with assign_noble (position BROKER) or allow anyone to trade' end
    return out
end

-- The game's own trade screen state (df.global.game.main_interface.trade), the view the
-- Trade button operates on; only meaningful while the screen is open.
local function screen(args)
    local tr = safe(function() return df.global.game.main_interface.trade end)
    if not tr then return rpc.error_result(rpc.ERR_INTERNAL, 'no trade interface struct on this build') end
    local out = {open = safe(function() return tr.open end) == true}
    pcall(function()
        out.choosing_merchant = tr.choosing_merchant
        out.still_unloading = tr.stillunloading ~= 0
        out.has_talker = tr.havetalker ~= 0
        out.fortress_trader = tr.fortress_trader and unit_ref(tr.fortress_trader) or nil
        out.merchant_trader = tr.merchant_trader and unit_ref(tr.merchant_trader) or nil
        out.depot_id = tr.bld and tr.bld.id or nil
        out.counter_offer = tr.counter_offer
        out.reply = enum_name(df.talk_line_type, tr.talkline)
        out.reply_meaning = REPLY_MEANING[out.reply or '']
        out.capacity_kg = caravan_capacity(tr.mer)
        local sides = {'merchant', 'fort'}
        for side = 0, 1 do
            local goods, selected, value, kg, total_kg = #tr.good[side], 0, 0, 0, 0
            for i = 0, goods - 1 do
                local w = item_kg(tr.good[side][i]) or 0
                total_kg = total_kg + w
                if tr.goodflag[side][i].selected then
                    selected = selected + 1
                    value = value + (safe(dfhack.items.getValue, tr.good[side][i], tr.mer) or 0)
                    kg = kg + w
                end
            end
            out[sides[side + 1] .. '_goods'] = {count = goods, selected = selected, selected_value = value,
                                                selected_kg = kg, total_kg = total_kg}
        end
        if out.capacity_kg and out.merchant_goods and out.fort_goods then
            out.load_after_kg = out.merchant_goods.total_kg - out.merchant_goods.selected_kg + out.fort_goods.selected_kg
            out.fits = out.load_after_kg <= out.capacity_kg
        end
    end)
    return out
end

----------------------------------------------------------------------------------------------
-- writes

local function request_broker(args)
    local depot, err = find_depot(args)
    if not depot then return err end
    local want = args.requested ~= false
    local anyone = args.anyone == true
    local before = {broker_requested = safe(function() return depot.trade_flags.trader_requested end) == true,
                    anyone_can_trade = safe(function() return depot.trade_flags.anyone_can_trade end) == true}
    depot.trade_flags.trader_requested = want
    depot.trade_flags.anyone_can_trade = anyone
    local caravan = active_caravan()
    -- The flag alone did not make the game queue the job (seen live 2026-10-15), so the
    -- TradeAtDepot job is created the way DFHack's lever script creates a PullLever job,
    -- and removed again when the request is withdrawn (caravan.lua's path).
    local existing = depot_jobs(depot).trade_job
    local job_made, job_removed = false, false
    if want and not existing and caravan then
        pcall(function()
            local ref = df.general_ref_building_holderst:new()
            ref.building_id = depot.id
            local job = df.job:new()
            job.job_type = df.job_type.TradeAtDepot
            job.pos.x, job.pos.y, job.pos.z = depot.centerx, depot.centery, depot.z
            job.general_refs:insert('#', ref)
            depot.jobs:insert('#', job)
            dfhack.job.linkIntoWorld(job, true)
            dfhack.job.checkBuildingsNow()
            job_made = true
        end)
    elseif not want and existing then
        pcall(function()
            for _, job in ipairs(depot.jobs) do
                if job.job_type == df.job_type.TradeAtDepot then
                    dfhack.job.removeJob(job)
                    job_removed = true
                    break
                end
            end
        end)
    end
    return {
        depot_id = depot.id, before = before,
        broker_requested = want, anyone_can_trade = anyone,
        caravan_present = caravan ~= nil,
        trade_job = depot_jobs(depot).trade_job or false,
        job_created = job_made, job_removed = job_removed,
        note = want and (caravan and 'the TradeAtDepot job is on the depot; the broker (or anyone, if allowed) takes it'
                         or 'flag set; the job is created once a caravan is at the depot (call again then)')
            or 'request withdrawn',
    }
end

local function is_container(item)
    return safe(function() return item:isContainer() end) == true
end

-- DFHack's move-goods rule: what may be hauled to this depot.
local function tradeable(item, depot)
    local f = item.flags
    for _, name in ipairs({'hostile', 'removed', 'dead_dwarf', 'spider_web', 'construction', 'encased',
                           'murder', 'trader', 'owned', 'garbage_collect', 'on_fire'}) do
        if safe(function() return f[name] end) then return false, name end
    end
    if f.in_inventory then
        local gref = safe(dfhack.items.getGeneralRef, item, df.general_ref_type.CONTAINED_IN_ITEM)
        local holder = gref and safe(function() return gref:getItem() end)
        if not holder or not is_container(holder) or safe(function() return item:isLiquidPowder() end) then
            return false, 'carried or contained'
        end
    end
    if f.in_job then
        local ref = safe(dfhack.items.getSpecificRef, item, df.specific_ref_type.JOB)
        if ref and safe(function() return ref.data.job.job_type end) == df.job_type.BringItemToDepot then
            return false, 'already being brought'
        end
        if ref then return false, 'in use by a job' end
    end
    if f.in_building then
        if safe(dfhack.items.getHolderBuilding, item) ~= depot then return false, 'part of a building' end
        return false, 'already at the depot'
    end
    if f.forbid then return false, 'forbidden' end
    if not safe(dfhack.items.checkMandates, item) then return false, 'a mandate forbids exporting it' end
    local ok, x, y, z = pcall(dfhack.items.getPosition, item)
    if not ok or x == nil then return false, 'no position' end
    if not dfhack.maps.canWalkBetween(xyz2pos(x, y, z), xyz2pos(depot.centerx, depot.centery, depot.z)) then
        return false, 'unreachable from the depot'
    end
    return true
end

local function match_query(item, needle)
    if needle == nil then return true end
    local text = (safe(dfhack.items.getReadableDescription, item) or ''):lower()
    return text:find(needle, 1, true) ~= nil
end

local function bring(args)
    local depot, err = find_depot(args)
    if not depot then return err end
    if not is_built(depot) then return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the depot is not built yet') end
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    local candidates = {}
    if type(args.item_ids) == 'table' and #args.item_ids > 0 then
        for _, raw in ipairs(args.item_ids) do
            local item = df.item.find(math.floor(tonumber(raw) or -1))
            if not item then return rpc.error_result(rpc.ERR_NOT_FOUND, 'no item with id ' .. tostring(raw)) end
            table.insert(candidates, item)
        end
    elseif type(args.query) == 'string' and args.query ~= '' then
        local needle = args.query:lower()
        local wanted_type = args.item_type and df.item_type[tostring(args.item_type):upper()] or nil
        for _, item in ipairs(df.global.world.items.other.IN_PLAY) do
            if (wanted_type == nil or item:getType() == wanted_type) and match_query(item, needle) then
                table.insert(candidates, item)
                if #candidates >= limit * 4 then break end
            end
        end
    else
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'pass "item_ids" or a "query" (with optional "item_type")')
    end
    local caravan = active_caravan()
    local marked, skipped, value = {}, {}, 0
    for _, item in ipairs(candidates) do
        if #marked >= limit then break end
        local ok, why = tradeable(item, depot)
        if ok then
            local done = safe(dfhack.items.markForTrade, item, depot)
            if done then
                local row = item_row(item, caravan)
                value = value + (row.value or 0)
                table.insert(marked, row)
            else
                table.insert(skipped, {id = item.id, reason = 'the game refused to mark it'})
            end
        elseif #skipped < LIST_LIMIT then
            table.insert(skipped, {id = item.id, description = safe(dfhack.items.getReadableDescription, item), reason = why})
        end
    end
    return {depot_id = depot.id, marked = #marked, value = value, items = marked, skipped = skipped,
            note = 'haulers bring marked goods to the depot; cancel with cancel_bring'}
end

local function unbring(args)
    local depot, err = find_depot(args)
    if not depot then return err end
    if type(args.item_ids) ~= 'table' or #args.item_ids == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"item_ids" must be a non-empty list')
    end
    local released, skipped = {}, {}
    for _, raw in ipairs(args.item_ids) do
        local item = df.item.find(math.floor(tonumber(raw) or -1))
        if not item then
            table.insert(skipped, {id = raw, reason = 'no such item'})
        else
            local ref = safe(dfhack.items.getSpecificRef, item, df.specific_ref_type.JOB)
            local job = ref and safe(function() return ref.data.job end)
            if job and job.job_type == df.job_type.BringItemToDepot then
                pcall(dfhack.job.removeJob, job)
                table.insert(released, item.id)
            elseif item.flags.in_building and safe(dfhack.items.getHolderBuilding, item) == depot then
                item.flags.in_building = false
                table.insert(released, item.id)
            else
                table.insert(skipped, {id = item.id, reason = 'not marked for the depot'})
            end
        end
    end
    return {depot_id = depot.id, released = released, skipped = skipped}
end

-- A trade proposal: what the fort gives, what it takes, the merchant's view of it.
local function offer(args)
    local depot, err = find_depot(args)
    if not depot then return err end
    local caravan = active_caravan()
    local give, take = {}, {}
    local give_value, take_value = 0, 0
    local problems = {}
    local function collect(ids, into, want_merchant)
        for _, raw in ipairs(ids or {}) do
            local item = df.item.find(math.floor(tonumber(raw) or -1))
            if not item then
                table.insert(problems, 'no item with id ' .. tostring(raw))
            else
                local at_depot = item.flags.in_building and safe(dfhack.items.getHolderBuilding, item) == depot
                local merchant = safe(function() return item.flags.trader end) == true
                if not at_depot then
                    table.insert(problems, ('item %d is not at the depot'):format(item.id))
                elseif merchant ~= want_merchant then
                    table.insert(problems, ('item %d belongs to the %s'):format(item.id, merchant and 'merchants' or 'fort'))
                else
                    local row = item_row(item, caravan)
                    table.insert(into, row)
                    if want_merchant then take_value = take_value + (row.value or 0)
                    else give_value = give_value + (row.value or 0) end
                end
            end
        end
    end
    collect(args.give, give, false)
    collect(args.take, take, true)
    local profit = give_value - take_value
    local margin = take_value > 0 and profit / take_value or (give_value > 0 and 1 or 0)
    local give_kg, take_kg = 0, 0
    for _, row in ipairs(give) do give_kg = give_kg + (row.kg or 0) end
    for _, row in ipairs(take) do take_kg = take_kg + (row.kg or 0) end
    local load_kg, unknown = merchant_load(depot)
    local capacity = caravan_capacity(caravan)
    local after_kg = load_kg - take_kg + give_kg
    local fits = capacity == nil or after_kg <= capacity
    local weight = {give_kg = give_kg, take_kg = take_kg, merchant_load_kg = load_kg, capacity_kg = capacity,
                    load_after_kg = after_kg, fits = fits, unknown_weights = unknown}
    local verdict
    if caravan == nil then verdict = 'no caravan is at the depot'
    elseif #problems > 0 then verdict = 'invalid'
    elseif not fits then verdict = ('refused: too heavy for the animals (%d kg over capacity)'):format(math.ceil(after_kg - capacity))
    elseif profit < 0 then verdict = 'refused: merchants never accept a loss'
    elseif margin >= 0.5 then verdict = 'accepted: generous (at least 50% profit)'
    elseif margin >= 0.1 then verdict = 'likely accepted'
    else verdict = 'marginal: may be haggled or refused' end
    local state = caravan and caravan_row(0, caravan) or nil
    return {
        depot_id = depot.id,
        caravan = state and {civ = state.civ, state = state.state, mood = state.mood} or nil,
        give = {count = #give, value = give_value, items = give},
        take = {count = #take, value = take_value, items = take},
        profit = profit, margin = margin, weight = weight, verdict = verdict, problems = problems,
        executed = false,
        note = 'this evaluates the deal with the caravan\'s own prices; the trade itself is still the game\'s '
            .. 'Trade button (driving it headlessly is unverified until a caravan is at the depot)',
    }
end

-- Select goods on the open trade screen (what DFHack's trade overlay does: it flips
-- main_interface.trade.goodflag[side][i].selected; side 0 is the merchants' list, 1 the
-- fort's). The Trade button itself stays the player's until the headless press is verified.
local function select_goods(args)
    local tr = safe(function() return df.global.game.main_interface.trade end)
    if not tr or not tr.open then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            'the trade screen is not open; open the depot and press Trade (the broker must be at the depot), then call again')
    end
    local want_give, want_take = {}, {}
    for _, id in ipairs(args.give or {}) do want_give[math.floor(tonumber(id) or -1)] = true end
    for _, id in ipairs(args.take or {}) do want_take[math.floor(tonumber(id) or -1)] = true end
    local clear = args.clear ~= false
    local result = {give = {selected = 0, value = 0, missing = {}}, take = {selected = 0, value = 0, missing = {}}}
    local function apply(side, wanted, bucket)
        local found = {}
        for i = 0, #tr.good[side] - 1 do
            local item = tr.good[side][i]
            local flag = tr.goodflag[side][i]
            if wanted[item.id] then
                flag.selected = true
                found[item.id] = true
                bucket.selected = bucket.selected + 1
                bucket.value = bucket.value + (safe(dfhack.items.getValue, item, tr.mer) or 0)
            elseif clear then
                flag.selected = false
            elseif flag.selected then
                bucket.selected = bucket.selected + 1
                bucket.value = bucket.value + (safe(dfhack.items.getValue, item, tr.mer) or 0)
            end
        end
        for id in pairs(wanted) do
            if not found[id] then table.insert(bucket.missing, id) end
        end
    end
    pcall(apply, 1, want_give, result.give)
    pcall(apply, 0, want_take, result.take)
    result.profit = result.give.value - result.take.value
    result.note = 'goods are selected on the trade screen; the player presses Trade, Offer, or closes it'
    return result
end

function ops()
    return {
        ['trade.caravans'] = {namespace = 'trade', handler = caravans, needs_map = true},
        ['trade.depot'] = {namespace = 'trade', handler = depot_info, needs_map = true},
        ['trade.broker'] = {namespace = 'trade', handler = broker, needs_map = true},
        ['trade.screen'] = {namespace = 'trade', handler = screen, needs_map = true},
        ['trade.request_broker'] = {namespace = 'trade_write', handler = request_broker, needs_map = true},
        ['trade.bring'] = {namespace = 'trade_write', handler = bring, needs_map = true},
        ['trade.unbring'] = {namespace = 'trade_write', handler = unbring, needs_map = true},
        ['trade.offer'] = {namespace = 'trade_write', handler = offer, needs_map = true},
        ['trade.select'] = {namespace = 'trade_write', handler = select_goods, needs_map = true},
    }
end
