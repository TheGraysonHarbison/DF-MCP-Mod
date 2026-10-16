-- Diplomats and the trade agreement (plan section 13, item 17.1). Reads: diplomats on the
-- map, who waits to meet whom, the meeting records, the game's diplomacy screen, and the
-- standing agreement. Writes: next year's import requests, the priorities the Requests
-- screen edits (DFHack's tradeagreement overlay writes the same vector, checked
-- 2026-10-15). The meeting itself, Done, and the land-holder choice stay with the player.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local nobles = reqscript('internal/claude-bridge/nobles')

DEFAULT_LIMIT = 25
MAX_PRIORITY = 4
MEETING_KINDS = {[0] = 'standard', [1] = 'first_contact', [2] = 'active_plot'}

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

local function unit_ref(unit)
    if not unit then return nil end
    return {id = unit.id, name = safe(dfhack.units.getReadableName, unit),
            pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z}}
end

local function histfig_unit(hf_id)
    local fig = hf_id and hf_id >= 0 and df.historical_figure.find(hf_id) or nil
    if not fig then return nil end
    local unit = fig.unit_id >= 0 and df.unit.find(fig.unit_id) or nil
    return unit_ref(unit) or {hist_figure_id = hf_id, name = translate(fig.name, false)}
end

local function civ_ref(id)
    local he = safe(df.historical_entity.find, id)
    if not he then return {id = id} end
    return {id = id, name = translate(he.name, true),
            race = safe(function() return df.creature_raw.find(he.race).name[2] end),
            home = id == df.global.plotinfo.civ_id}
end

----------------------------------------------------------------------------------------------
-- category item names from the civilization's resources (best effort per category)

local function matref_names(ref)
    local out = {}
    pcall(function()
        for i = 0, #ref.mat_type - 1 do
            out[i] = safe(function() return dfhack.matinfo.decode(ref.mat_type[i], ref.mat_index[i]):toString() end)
        end
    end)
    return out
end

local function inorganic_names(vec)
    local out = {}
    pcall(function()
        for i = 0, #vec - 1 do out[i] = safe(function() return dfhack.matinfo.decode(0, vec[i]):toString() end) end
    end)
    return out
end

local function itemdef_names(vec, defs)
    local out = {}
    pcall(function()
        for i = 0, #vec - 1 do
            out[i] = safe(function() return df.global.world.raws.itemdefs[defs][vec[i]].name end)
        end
    end)
    return out
end

local function creature_names(vec)
    local out = {}
    pcall(function()
        for i = 0, #vec - 1 do out[i] = safe(function() return df.global.world.raws.creatures.all[vec[i]].name[0] end) end
    end)
    return out
end

-- Anvils: the civ's metals whose material allows anvils (iron and steel for dwarves).
local function anvil_names(r)
    local out = {}
    pcall(function()
        local n = 0
        for i = 0, #r.metals - 1 do
            local inorg = df.global.world.raws.inorganics.all[r.metals[i]]
            if inorg.material.flags.ITEMS_ANVIL then
                out[n] = (dfhack.matinfo.decode(0, r.metals[i]):toString()) .. ' anvil'
                n = n + 1
            end
        end
    end)
    return out
end

-- Garden vegetables: tree fruit growths then shrub fruit growths, as the game lists them.
local function growth_names(r)
    local out = {}
    pcall(function()
        local n = 0
        local plants = df.global.world.raws.plants.all
        for i = 0, #r.tree_fruit_plants - 1 do
            out[n] = safe(function() return plants[r.tree_fruit_plants[i]].growths[r.tree_fruit_growths[i]].name end)
            n = n + 1
        end
        for i = 0, #r.shrub_fruit_plants - 1 do
            out[n] = safe(function() return plants[r.shrub_fruit_plants[i]].growths[r.shrub_fruit_growths[i]].name end)
            n = n + 1
        end
    end)
    return out
end

-- Miscellaneous: the wood products list (lye, charcoal, potash, pearlash, coke).
local function wood_product_names(r)
    local out = {}
    pcall(function()
        local wp = r.wood_products
        for i = 0, #wp.item_type - 1 do
            local mat = safe(function()
                return dfhack.matinfo.decode(wp.material.mat_type[i], wp.material.mat_index[i]):toString()
            end) or 'unknown'
            local it = enum_name(df.item_type, wp.item_type[i]) or ''
            out[i] = it == 'BAR' and (mat .. ' bar') or mat
        end
    end)
    return out
end

-- entity_sell_category name -> function(resources) -> {[i] = name}. Category names as the
-- game's enum spells them (read live 2026-10-15); categories not listed fall back to "item n".
NAMERS = {
    Leather = function(r) return matref_names(r.organic.leather) end,
    BagsLeather = function(r) return matref_names(r.organic.leather) end,
    FlasksWaterskins = function(r) return matref_names(r.organic.leather) end,
    Quivers = function(r) return matref_names(r.organic.leather) end,
    Backpacks = function(r) return matref_names(r.organic.leather) end,
    ClothPlant = function(r) return matref_names(r.organic.fiber) end,
    BagsPlant = function(r) return matref_names(r.organic.fiber) end,
    ThreadPlant = function(r) return matref_names(r.organic.fiber) end,
    RopesPlant = function(r) return matref_names(r.organic.fiber) end,
    ClothSilk = function(r) return matref_names(r.organic.silk) end,
    BagsSilk = function(r) return matref_names(r.organic.silk) end,
    ThreadSilk = function(r) return matref_names(r.organic.silk) end,
    RopesSilk = function(r) return matref_names(r.organic.silk) end,
    ClothYarn = function(r) return matref_names(r.organic.wool) end,
    BagsYarn = function(r) return matref_names(r.organic.wool) end,
    ThreadYarn = function(r) return matref_names(r.organic.wool) end,
    RopesYarn = function(r) return matref_names(r.organic.wool) end,
    Parchment = function(r) return matref_names(r.organic.parchment) end,
    Crafts = function(r) return matref_names(r.misc_mat.crafts) end,
    CupsMugsGoblets = function(r) return matref_names(r.misc_mat.crafts) end,
    Wood = function(r) return matref_names(r.organic.wood) end,
    Barrels = function(r) return matref_names(r.organic.wood) end,
    Buckets = function(r) return matref_names(r.organic.wood) end,
    Splints = function(r) return matref_names(r.organic.wood) end,
    Crutches = function(r) return matref_names(r.organic.wood) end,
    MetalBars = function(r) return inorganic_names(r.metals) end,
    SmallCutGems = function(r) return inorganic_names(r.gems) end,
    LargeCutGems = function(r) return inorganic_names(r.gems) end,
    StoneBlocks = function(r) return inorganic_names(r.stones) end,
    Stone = function(r) return inorganic_names(r.stones) end,
    Anvils = anvil_names,
    GardenVegetables = growth_names,
    Miscellaneous = wood_product_names,
    Weapons = function(r) return itemdef_names(r.weapon_type, 'weapons') end,
    TrainingWeapons = function(r) return itemdef_names(r.training_weapon_type, 'weapons') end,
    Ammo = function(r) return itemdef_names(r.ammo_type, 'ammo') end,
    TrapComponents = function(r) return itemdef_names(r.trapcomp_type, 'trapcomps') end,
    DiggingImplements = function(r) return itemdef_names(r.digger_type, 'weapons') end,
    Bodywear = function(r) return itemdef_names(r.armor_type, 'armor') end,
    Headwear = function(r) return itemdef_names(r.helm_type, 'helms') end,
    Handwear = function(r) return itemdef_names(r.gloves_type, 'gloves') end,
    Footwear = function(r) return itemdef_names(r.shoes_type, 'shoes') end,
    Legwear = function(r) return itemdef_names(r.pants_type, 'pants') end,
    Shields = function(r) return itemdef_names(r.shield_type, 'shields') end,
    Toys = function(r) return itemdef_names(r.toy_type, 'toys') end,
    Instruments = function(r) return itemdef_names(r.instrument_type, 'instruments') end,
    Tools = function(r) return itemdef_names(r.tool_type, 'tools') end,
    Pets = function(r) return creature_names(r.animals.pet_races) end,
    Drinks = function(r) return matref_names(r.misc_mat.booze) end,
    Cheese = function(r) return matref_names(r.misc_mat.cheese) end,
    Powders = function(r) return matref_names(r.misc_mat.powders) end,
    Extracts = function(r) return matref_names(r.misc_mat.extracts) end,
    Meat = function(r) return matref_names(r.misc_mat.meat) end,
    Fish = function(r) return creature_names(r.fish_races) end,
    Eggs = function(r) return creature_names(r.egg_races) end,
    Plants = function(r) return matref_names(r.plants) end,
    Seeds = function(r) return matref_names(r.seeds) end,
    Cages = function(r) return matref_names(r.misc_mat.cages) end,
    Glass = function(r) return matref_names(r.misc_mat.glass) end,
    Sand = function(r) return matref_names(r.misc_mat.sand) end,
    Clay = function(r) return matref_names(r.misc_mat.clay) end,
}

local function category_names(entity, cat_name)
    local namer = NAMERS[cat_name]
    if not namer then return {} end
    return safe(namer, entity.resources) or {}
end

----------------------------------------------------------------------------------------------
-- meeting records

local function site_leader()
    for _, code in ipairs({'MONARCH', 'DUKE', 'COUNT', 'BARON', 'MAYOR', 'EXPEDITION_LEADER'}) do
        local holder = safe(nobles.position_holder, code)
        if holder and holder.id then
            local unit = df.unit.find(holder.id)
            if unit then return unit, code end
        end
    end
    return nil
end

local function meeting_rows()
    local rows = {}
    pcall(function()
        for i, info in ipairs(df.global.plotinfo.dip_meeting_info) do
            local flags = {}
            for _, f in ipairs({'dynamic_load', 'failure', 'success'}) do
                if safe(function() return info.flags[f] end) then table.insert(flags, f) end
            end
            local requests = 0
            pcall(function()
                for cat = 0, df.entity_sell_category._last_item do
                    local pr = info.sell_requests.priority[cat]
                    for j = 0, #pr - 1 do if pr[j] > 0 then requests = requests + 1 end end
                end
            end)
            table.insert(rows, {
                index = i,
                civ = civ_ref(info.civ_id),
                diplomat = histfig_unit(info.diplomat_id),
                kind = MEETING_KINDS[info.standard_type] or tostring(info.standard_type),
                step = info.cur_step,
                flags = flags,
                has_requests = info.sell_requests ~= nil,
                requests_set = requests,
                events = safe(function() return #info.events end) or 0,
            })
        end
    end)
    return rows
end

-- The meeting whose requests to read or write: the live one on the open diplomacy screen
-- (its environment's dipev, the object the Requests tab edits), else a recorded meeting.
local function find_meeting(args)
    local live = safe(function()
        local d = df.global.game.main_interface.diplomacy
        if d.open then return d.environment.dipev end
        return nil
    end)
    if live and (args.civ_id == nil or live.civ_id == tonumber(args.civ_id)) then return live end
    local infos = safe(function() return df.global.plotinfo.dip_meeting_info end)
    if not infos or #infos == 0 then return nil, 'no diplomat meeting is recorded' end
    if args.civ_id ~= nil then
        for _, info in ipairs(infos) do
            if info.civ_id == tonumber(args.civ_id) then return info end
        end
        return nil, 'no meeting with civilization ' .. tostring(args.civ_id)
    end
    return infos[0]
end

-- The standing agreement with a civilization: the latest export and import events.
-- Agreements are named from the civilization's side: its ExportAgreement event carries the
-- fort's requests (`sell_prices`, what the civ will sell us), its ImportAgreement the price
-- changes on what it buys from the fort (`buy_prices`). The newest event of each type wins.
-- They sit in the meeting's own event list while the diplomat is still on the map, and on
-- the civilization's `meeting_events` after the liaison reports home (verified 2026-10-15).
local function fort_requests(he, ev, limit)
    local asked = {}
    pcall(function()
        for cat = 0, df.entity_sell_category._last_item do
            local pr = ev.sell_prices.items.priority[cat]
            local names = category_names(he, enum_name(df.entity_sell_category, cat) or '')
            for j = 0, #pr - 1 do
                if pr[j] > 0 and #asked < limit then
                    table.insert(asked, {category = enum_name(df.entity_sell_category, cat),
                                         item = names[j] or ('item ' .. j), priority = pr[j],
                                         price_percent = safe(function()
                                             return math.floor(ev.sell_prices.price[cat][j] * 100 / 128)
                                         end)})
                end
            end
        end
    end)
    return asked
end

local function fort_export_prices(ev, limit)
    local wanted = {}
    pcall(function()
        local items = ev.buy_prices.items
        for j = 0, #ev.buy_prices.price - 1 do
            local pct = math.floor(ev.buy_prices.price[j] * 100 / 128)
            if pct ~= 100 and #wanted < limit then
                local name = safe(function()
                    local token = enum_name(df.item_type, items.item_type[j]) or '?'
                    local mat = items.mat_types[j] >= 0
                        and dfhack.matinfo.decode(items.mat_types[j], items.mat_indices[j]):toString() or nil
                    return (mat and (mat .. ' ') or '') .. token:lower()
                end)
                table.insert(wanted, {item = name or ('item ' .. j), price_percent = pct})
            end
        end
    end)
    return wanted
end

local function scan_agreements(he, events, out, limit, where)
    for i = #events - 1, 0, -1 do
        local ev = events[i]
        local kind = enum_name(df.meeting_event_type, ev.type)
        if kind == 'ExportAgreement' and not out.imports then
            out.imports = {year = ev.year, where = where, requested = fort_requests(he, ev, limit),
                           note = 'what the fort asked the next caravan to bring; price_percent is what it will charge'}
        elseif kind == 'ImportAgreement' and not out.exports then
            out.exports = {year = ev.year, where = where, price_changes = fort_export_prices(ev, limit),
                           note = 'what the next caravan pays more or less for from the fort'}
        end
    end
end

local function agreement_summary(civ_id, limit)
    local out = {}
    pcall(function()
        local he = df.historical_entity.find(civ_id)
        for _, info in ipairs(df.global.plotinfo.dip_meeting_info) do
            if info.civ_id == civ_id then scan_agreements(he, info.events, out, limit, 'meeting') end
        end
        scan_agreements(he, he.meeting_events, out, limit, 'civilization')
    end)
    return out
end

local function diplomats(args)
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    local units = {}
    pcall(function()
        for _, unit in ipairs(df.global.world.units.active) do
            if dfhack.units.isDiplomat(unit) and not dfhack.units.isDead(unit) then
                local row = unit_ref(unit)
                row.civ = civ_ref(unit.civ_id)
                local job = safe(function() return unit.job.current_job end)
                row.job = job and enum_name(df.job_type, job.job_type) or nil
                table.insert(units, row)
            end
        end
    end)
    local waiting = {}
    pcall(function()
        for _, id in ipairs(df.global.plotinfo.meeting_requests) do table.insert(waiting, unit_ref(df.unit.find(id)) or {id = id}) end
    end)
    local leader, code = site_leader()
    local leader_row = unit_ref(leader)
    if leader_row then
        leader_row.position = code
        local job = safe(function() return leader.job.current_job end)
        leader_row.job = job and enum_name(df.job_type, job.job_type) or nil
    end
    local screen = {}
    pcall(function()
        local d = df.global.game.main_interface.diplomacy
        screen = {open = d.open, taking_requests = d.taking_requests,
                  choosing_land_holder = d.selecting_land_holder_position,
                  actor = d.actor and unit_ref(d.actor) or nil, target = d.target and unit_ref(d.target) or nil,
                  land_holder_candidates = safe(function() return #d.land_holder_avail_hfid end)}
    end)
    local meetings = meeting_rows()
    local agreements = {}
    for _, m in ipairs(meetings) do
        if #agreements < 3 then
            local a = agreement_summary(m.civ.id, limit)
            a.civ = m.civ
            table.insert(agreements, a)
        end
    end
    if #agreements == 0 then
        local a = agreement_summary(df.global.plotinfo.civ_id, limit)
        a.civ = civ_ref(df.global.plotinfo.civ_id)
        table.insert(agreements, a)
    end
    return {
        diplomats = units, waiting_to_meet = waiting, site_leader = leader_row,
        meetings = meetings, screen = screen, agreements = agreements,
        note = 'the leader meets the diplomat on their own (a Conduct Meeting job) when free; a leader who is also '
            .. 'the broker cannot do both. Requests for next year are set with set_trade_requests; the meeting, '
            .. 'Done, and any land-holder choice are the player\'s',
    }
end

local function request_options(args)
    local info, err = find_meeting(args)
    if not info then return rpc.error_result(rpc.ERR_NOT_FOUND, err) end
    if not info.sell_requests then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            'this meeting carries no request list yet; the game creates it when the liaison meeting reaches its Requests step')
    end
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    local he = df.historical_entity.find(info.civ_id)
    local wanted = args.category ~= nil and tostring(args.category) or nil
    local categories = {}
    pcall(function()
        for cat = 0, df.entity_sell_category._last_item do
            local name = enum_name(df.entity_sell_category, cat)
            local pr = info.sell_requests.priority[cat]
            if name and name ~= 'NONE' and #pr > 0 and (wanted == nil or wanted:lower() == name:lower()) then
                local names = category_names(he, name)
                local items = {}
                for j = 0, #pr - 1 do
                    if #items < limit then
                        table.insert(items, {index = j, item = names[j] or ('item ' .. j), priority = pr[j]})
                    end
                end
                table.insert(categories, {category = name, count = #pr, items = items, truncated = #pr > #items})
            end
        end
    end)
    return {civ = civ_ref(info.civ_id), categories = categories, max_priority = MAX_PRIORITY,
            note = 'priority 0 means not requested, 4 the strongest request; the caravan charges more for requested goods'}
end

local function set_requests(args)
    local info, err = find_meeting(args)
    if not info then return rpc.error_result(rpc.ERR_NOT_FOUND, err) end
    if not info.sell_requests then
        return rpc.error_result(rpc.ERR_NOT_FOUND, 'this meeting carries no request list')
    end
    if type(args.requests) ~= 'table' or #args.requests == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"requests" must be a non-empty list of {category, item, priority}')
    end
    local he = df.historical_entity.find(info.civ_id)
    local applied, problems = {}, {}
    for _, req in ipairs(args.requests) do
        local cat = type(req.category) == 'string' and df.entity_sell_category[req.category] or nil
        if cat == nil then
            pcall(function()
                for c = 0, df.entity_sell_category._last_item do
                    if (enum_name(df.entity_sell_category, c) or ''):lower() == tostring(req.category):lower() then cat = c end
                end
            end)
        end
        local priority = tonumber(req.priority)
        if cat == nil then
            table.insert(problems, 'unknown category ' .. tostring(req.category))
        elseif not priority or priority < 0 or priority > MAX_PRIORITY then
            table.insert(problems, ('priority for %s must be 0-%d'):format(tostring(req.category), MAX_PRIORITY))
        else
            local pr = info.sell_requests.priority[cat]
            local names = category_names(he, enum_name(df.entity_sell_category, cat))
            local index = tonumber(req.item)
            if index == nil and type(req.item) == 'string' then
                local needle = req.item:lower()
                for j = 0, #pr - 1 do
                    if names[j] and names[j]:lower():find(needle, 1, true) then index = j break end
                end
            end
            if req.item == nil or req.item == 'all' then
                for j = 0, #pr - 1 do pr[j] = math.floor(priority) end
                table.insert(applied, {category = enum_name(df.entity_sell_category, cat), item = 'all', priority = math.floor(priority)})
            elseif index == nil or index < 0 or index >= #pr then
                table.insert(problems, ('no item "%s" in %s'):format(tostring(req.item), enum_name(df.entity_sell_category, cat)))
            else
                pr[index] = math.floor(priority)
                table.insert(applied, {category = enum_name(df.entity_sell_category, cat), item = names[index] or ('item ' .. index),
                                       index = index, priority = math.floor(priority)})
            end
        end
    end
    return {civ = civ_ref(info.civ_id), applied = applied, problems = problems,
            note = 'written to the meeting\'s request list; the game takes it when the player finishes the liaison meeting'}
end



function ops()
    return {
        ['trade.diplomats'] = {namespace = 'trade', handler = diplomats, needs_map = true},
        ['trade.request_options'] = {namespace = 'trade', handler = request_options, needs_map = true},
        ['trade.set_requests'] = {namespace = 'trade_write', handler = set_requests, needs_map = true},
    }
end
