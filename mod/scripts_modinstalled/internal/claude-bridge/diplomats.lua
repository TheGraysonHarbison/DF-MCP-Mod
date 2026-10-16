-- Diplomats and the trade agreement (plan section 13, item 17.1). Reads: diplomats on the
-- map, who waits to meet whom, the meeting records, the game's diplomacy screen, and the
-- standing agreement. Writes: next year's import requests, the priorities the Requests
-- screen edits (DFHack's tradeagreement overlay writes the same vector, checked
-- 2026-10-15).
--
-- The liaison's diplomacy dialog (plan section 15.2, Patch 1 item P3.0): whether the
-- meeting's left-side alert is up, the open dialog's text, step, script position, and
-- request and land-holder state (trade.dialog); opening it (trade.open_dialog) and stepping
-- it (trade.dialog_step) as state replays. The replays are scaffolds until the owner records
-- the game's field changes on a liaison save (15.4 check 6): every write is a guess marked
-- VERIFY LIVE, saves what it overwrites, and restores it on error. Advancing the dipscript
-- (continue, choose) is refused until that diff is known. Sources (df-structures master,
-- checked 2026-10-16): df.d_interface.xml (diplomacy_interfacest), df.markup_text_box.xml,
-- df.diplomacy.xml (meeting_diplomat_info), df.dipscript.xml, df.script.xml (script_stepst
-- subclasses), df.meetingmoment.xml (dipscript_popup), df.announcement.xml
-- (announcement_handlerst alerts), df.g_src.basics.xml (announcement types); DFHack 53.16-r2
-- scripts/internal/caravan/tradeagreement.lua and lua/plugins/sort/diplomacy.lua (the
-- focus strings dwarfmode/Diplomacy, .../Requests, .../ElevateLandHolder).
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local nobles = reqscript('internal/claude-bridge/nobles')
local screens = reqscript('internal/claude-bridge/screens')

DEFAULT_LIMIT = 25
MAX_PRIORITY = 4
MEETING_KINDS = {[0] = 'standard', [1] = 'first_contact', [2] = 'active_plot'}
DIALOG_MAX_LINES = 200
ALERT_TEXT_CHARS = 120
-- Announcement types whose report is taken for the meeting's alert button.
-- VERIFY LIVE: which announcement the meeting button really is (15.4 check 6); trade.dialog
-- lists every current alert so the liaison session can see it.
MEETING_ANNOUNCEMENTS = {DIPLOMAT_ARRIVAL = true, LIAISON_ARRIVAL = true, TRADE_DIPLOMAT_ARRIVAL = true}
-- Matched by the DIPLOMA substring rule below but not a meeting: the diplomat has left.
NOT_MEETING_ANNOUNCEMENTS = {DIPLOMAT_LEFT_UNHAPPY = true}

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
            .. 'the broker cannot do both. When the meeting dialog is up (a meeting_ready event), read it with '
            .. 'get_meeting_dialog, open it with open_meeting_dialog, set next year\'s requests with '
            .. 'set_trade_requests, and finish it with step_meeting_dialog; steps it cannot replay yet are the player\'s',
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

----------------------------------------------------------------------------------------------
-- the diplomacy dialog (P3.0)
--
-- Strings stay in the game's code page here: rpc.dispatch converts every string of a result
-- to UTF-8 on the way out, so converting in the handler would convert twice.

local function diplomacy()
    return df.global.game.main_interface.diplomacy
end

local function name_of_enum(enum, value)
    if type(value) == 'string' then return value end
    return enum_name(enum, value)
end

-- True when a report belongs to the liaison meeting's alert button. `alert_type` is the
-- announcement_alertst type the report sits under (name or value), or nil to take the
-- report type's own alert attribute. Exported for events.lua (the meeting_ready kind); this
-- module never requires events.lua.
-- VERIFY LIVE: which announcement and alert type the meeting button carries.
function is_meeting_report(report, alert_type)
    if not report then return false end
    local name = enum_name(df.announcement_type, safe(function() return report.type end)) or ''
    if NOT_MEETING_ANNOUNCEMENTS[name] then return false end
    if MEETING_ANNOUNCEMENTS[name] or name:find('MEETING', 1, true) or name:find('DIPLOMA', 1, true) then
        return true
    end
    if alert_type == nil then
        alert_type = safe(function() return df.announcement_type.attrs[report.type].alert_type end)
    end
    return name_of_enum(df.announcement_alert_type, alert_type) == 'AGREEMENT'
end

-- Every report id behind a left-side alert: {[report_id] = alert type name or false}. The ids
-- inside world.status.announcement_alert[] carry their alert's type; ids only in
-- alert_button_announcement_id carry false.
function alert_report_ids()
    local ids = {}
    pcall(function()
        local status = df.global.world.status
        for _, alert in ipairs(status.announcement_alert) do
            local kind = enum_name(df.announcement_alert_type, alert.type) or tostring(alert.type)
            for _, id in ipairs(alert.announcement_id) do ids[id] = kind end
        end
        for _, id in ipairs(status.alert_button_announcement_id) do
            if ids[id] == nil then ids[id] = false end
        end
    end)
    return ids
end

local function clip(text, n)
    if type(text) ~= 'string' then return nil end
    if #text > n then return text:sub(1, n) end
    return text
end

-- All current alerts as {type, report_ids, texts, announcements}, plus the meeting reports
-- among them. Ids only in alert_button_announcement_id form one row of type 'button'.
local function alert_rows(limit)
    local rows, meeting_ids, truncated = {}, {}, false
    local function add_row(kind, ids)
        local row = {type = kind, report_ids = {}, texts = {}, announcements = {}}
        for _, id in ipairs(ids) do
            local report = safe(df.report.find, id)
            if report and is_meeting_report(report, kind ~= 'button' and kind or nil) then
                table.insert(meeting_ids, id)
            end
            if #row.report_ids >= limit then
                row.truncated = true
            else
                table.insert(row.report_ids, id)
                table.insert(row.texts, report and clip(report.text, ALERT_TEXT_CHARS) or '')
                table.insert(row.announcements,
                    report and (enum_name(df.announcement_type, report.type) or tostring(report.type)) or '')
            end
        end
        if #rows >= limit then
            truncated = true
        else
            table.insert(rows, row)
        end
    end
    pcall(function()
        local status = df.global.world.status
        local in_alert = {}
        for _, alert in ipairs(status.announcement_alert) do
            local ids = {}
            for _, id in ipairs(alert.announcement_id) do
                table.insert(ids, id)
                in_alert[id] = true
            end
            add_row(enum_name(df.announcement_alert_type, alert.type) or tostring(alert.type), ids)
        end
        local buttons = {}
        for _, id in ipairs(status.alert_button_announcement_id) do
            if not in_alert[id] then table.insert(buttons, id) end
        end
        if #buttons > 0 then add_row('button', buttons) end
    end)
    return rows, meeting_ids, truncated
end

-- The dialog's words as lines: a new line on NEW_LINE, an empty line on BLANK_LINE, an
-- indent on INDENT, words joined by single spaces.
-- VERIFY LIVE: whether NEW_LINE words carry text or are bare markers, and whether the
-- px/py wrapping should be followed instead.
local function dialog_text(box, max_lines)
    local lines, cur, indent, truncated = {}, nil, false, false
    local function flush()
        if cur ~= nil then table.insert(lines, cur) end
        cur = nil
    end
    pcall(function()
        for _, word in ipairs(box.word) do
            if #lines >= max_lines then
                truncated = true
                cur = nil
                break
            end
            local flags = word.flags
            if flags.NEW_LINE or flags.BLANK_LINE then flush() end
            if flags.BLANK_LINE then table.insert(lines, '') end
            if flags.INDENT then indent = true end
            local str = word.str
            if str ~= '' then
                if cur == nil then
                    cur = (indent and '    ' or '') .. str
                    indent = false
                else
                    cur = cur .. ' ' .. str
                end
            end
        end
    end)
    flush()
    while #lines > max_lines do
        table.remove(lines)
        truncated = true
    end
    return lines, truncated
end

-- Most derived first: the first match names the step.
STEP_CLASSES = {
    'script_step_textviewerst', 'script_step_discussst', 'script_step_conditionalst',
    'script_step_dipeventst', 'script_step_invasionst', 'script_step_eventst',
    'script_step_diphistoryst', 'script_step_topicdiscussionst', 'script_step_constructtopiclistst',
    'script_step_setvarst', 'script_step_simpleactionst',
}

local function step_type(step)
    for _, name in ipairs(STEP_CLASSES) do
        local t = safe(function() return df[name] end)
        if t and safe(function() return t:is_instance(step) end) then return name end
    end
    local raw = safe(function() return tostring(step._type) end)
    return raw and (raw:match('<type: ([%w_]+)>') or raw) or nil
end

local function live_dipev(d)
    return safe(function() return d.dipev end) or safe(function() return d.environment.dipev end)
end

local function script_info(dipev)
    if not dipev then return nil, nil end
    local info, step = {}, nil
    pcall(function()
        info.cur_step = dipev.cur_step
        info.flags = {success = dipev.flags.success, failure = dipev.flags.failure}
        local ds = dipev.dipscript
        if ds then
            info.code = ds.code
            local steps = ds.script.steps
            info.steps = #steps
            if dipev.cur_step >= 0 and dipev.cur_step < #steps then
                step = steps[dipev.cur_step]
                info.step_type = step_type(step)
                info.next_step_idx = step.next_step_idx
            end
        end
    end)
    return info, step
end

local function popup_info(d)
    local mm = safe(function() return d.mm end)
    if not mm then return nil end
    local out = {}
    pcall(function()
        out.actor_unit_id = mm.meeting_holder_actor
        out.noble_unit_id = mm.meeting_holder_noble
        out.flags = {close_screen = mm.flags.close_screen, new_screen = mm.flags.new_screen}
        out.moment_time_left = mm.moment_time_left
    end)
    return out
end

local function hf_name(hf_id)
    local fig = safe(df.historical_figure.find, hf_id)
    if not fig then return nil end
    local unit = fig.unit_id >= 0 and safe(df.unit.find, fig.unit_id) or nil
    return (unit and safe(dfhack.units.getReadableName, unit)) or translate(fig.name, false)
end

local function int_list(vec, limit)
    local out, truncated = {}, false
    pcall(function()
        for i = 0, #vec - 1 do
            if #out >= limit then
                truncated = true
                break
            end
            table.insert(out, vec[i])
        end
    end)
    return out, truncated
end

local function dialog_state(args)
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    if limit < 1 then limit = DEFAULT_LIMIT end
    local d = diplomacy()
    local alerts, meeting_ids, alerts_truncated = alert_rows(limit)
    local out = {
        available = #meeting_ids > 0, meeting_report_ids = meeting_ids,
        alerts = alerts, alerts_truncated = alerts_truncated or nil,
        open = safe(function() return d.open end) == true,
        in_progress = safe(function() return d.flag.in_the_middle_of_stuff end) == true,
        actor = safe(function() return d.actor and unit_ref(d.actor) or nil end),
        target = safe(function() return d.target and unit_ref(d.target) or nil end),
        popup = popup_info(d),
        paused = safe(dfhack.world.ReadPauseState) == true,
    }
    local taking = safe(function() return d.taking_requests end) == true
    local land = safe(function() return d.selecting_land_holder_position end) == true
    if not out.open then
        out.step = 'closed'
    elseif taking then
        out.step = 'requests'
    elseif land then
        out.step = 'land_holder'
    else
        out.step = 'text'
    end
    local lines, text_truncated = dialog_text(d.text, DIALOG_MAX_LINES)
    out.text = lines
    out.text_truncated = text_truncated or nil
    local script, step = script_info(live_dipev(d))
    out.script = script
    -- VERIFY LIVE: where the dialog's reply buttons live; the live diff decides.
    local choices = {links = {}}
    pcall(function()
        for _, link in ipairs(d.text.link) do
            if #choices.links >= limit then
                choices.links_truncated = true
                break
            end
            table.insert(choices.links, {type = enum_name(df.markup_text_link_type, link.type) or link.type,
                                         id = link.id})
        end
    end)
    if step and script and script.step_type == 'script_step_textviewerst' then
        pcall(function()
            choices.filename = step.filename
            choices.outvar_name = step.outvar_name
        end)
    end
    out.choices = choices
    out.choices_note = 'the reply buttons are not mapped yet; the live field diff of a player click decides how a '
        .. 'choice is made, so continue and choose may answer that they are not replayable'
    local tabs = {}
    pcall(function()
        for _, cat in ipairs(d.taking_requests_tablist) do
            table.insert(tabs, enum_name(df.entity_sell_category, cat) or tostring(cat))
        end
    end)
    out.requests = {taking = taking, tabs = tabs,
                    selected_tab = safe(function() return d.taking_requests_selected_tab end)}
    local land_holder = {selecting = land, candidates = {}}
    pcall(function()
        land_holder.positions = int_list(d.land_holder_pos_id, limit)
        land_holder.assigned = int_list(d.land_holder_assigned_hfid, limit)
        land_holder.selected_pos = d.land_holder_selected_pos
        for i = 0, #d.land_holder_avail_hfid - 1 do
            if #land_holder.candidates >= limit then
                land_holder.truncated = true
                break
            end
            local id = d.land_holder_avail_hfid[i]
            table.insert(land_holder.candidates, {hist_figure_id = id, name = hf_name(id)})
        end
    end)
    out.land_holder = land_holder
    if out.open then
        out.note = 'the dialog pauses the game. On the requests step set the requests with set_trade_requests, '
            .. 'then step_meeting_dialog done; choose a land holder when asked; close when finished'
    elseif out.available then
        out.note = 'the meeting dialog is waiting on its alert; open it with open_meeting_dialog'
    else
        out.note = 'no meeting dialog is waiting; a meeting_ready event says when one is'
    end
    return out
end

-- Write `writes` ({target, field, value, label}) in order; on an error put every field
-- back and return nil, message. Returns [{field, before, after}].
local function replay(writes)
    local saved = {}
    local ok, err = pcall(function()
        for _, w in ipairs(writes) do
            local before = w[1][w[2]]
            table.insert(saved, {w[1], w[2], before})
            w[1][w[2]] = w[3]
        end
    end)
    if not ok then
        for i = #saved, 1, -1 do
            local s = saved[i]
            pcall(function() s[1][s[2]] = s[3] end)
        end
        return nil, tostring(err)
    end
    local out = {}
    for i, s in ipairs(saved) do
        table.insert(out, {field = writes[i][4], before = s[3], after = writes[i][3]})
    end
    return out
end

local function open_dialog(args)
    local d = diplomacy()
    -- Checked before the focus: an open dialog has the Diplomacy focus, not the main map.
    if safe(function() return d.open end) then
        return {opened = false, already_open = true, replayed = {}, dialog = dialog_state(args),
                note = 'the meeting dialog is already open'}
    end
    local busy = screens.require_focus({screens.MAIN_FOCUS}, 'open_meeting_dialog')
    if busy then return busy end
    local _, meeting_ids = alert_rows(DEFAULT_LIMIT)
    if #meeting_ids == 0 then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            'no meeting alert is up; wait for a meeting_ready event (get_meeting_dialog lists the current alerts)')
    end
    -- VERIFY LIVE: the opener. The field diff of the player's click on the alert is not
    -- recorded yet; the guess is that the game keeps the meeting (mm, dipev) on the
    -- interface and the click only sets `open`. Nothing else is written.
    local has_state = safe(function() return d.mm ~= nil end) or safe(function() return d.dipev ~= nil end)
    if not has_state then
        return rpc.error_result(rpc.ERR_NOT_FOUND,
            'the game\'s meeting state is not populated; the live diff of a player click on the alert decides how to '
            .. 'open it; run `claude-bridge dialog-snapshot` before and after')
    end
    local replayed, err = replay({{d, 'open', true, 'diplomacy.open'}})
    if not replayed then
        return rpc.error_result(rpc.ERR_INTERNAL, 'opening the dialog failed and was undone: ' .. err)
    end
    return {opened = true, replayed = replayed, meeting_report_ids = meeting_ids, dialog = dialog_state(args),
            note = 'opened by a replay not yet verified against the game; if the dialog does not show, ask the '
                .. 'player to click the meeting alert'}
end

local NOT_REPLAYABLE = 'advancing the conversation is recorded from the player\'s first click-through; not yet replayable'

-- One entry per action: function(d, args) -> {replayed = {...}} or an error result.
-- Every write is a guess marked VERIFY LIVE and is undone on error.
REPLAY = {
    -- Deliberately neither drives script_stepst execute/skip nor writes cur_step: a wrong
    -- step corrupts the meeting. VERIFY LIVE: the diff of a Continue click.
    continue = function(d, args)
        return rpc.error_result(rpc.ERR_BAD_REQUEST, NOT_REPLAYABLE .. '; ask the player to click Continue')
    end,
    -- VERIFY LIVE: the diff of a reply choice.
    choose = function(d, args)
        return rpc.error_result(rpc.ERR_BAD_REQUEST, ('%s; ask the player to click choice %s'):format(
            NOT_REPLAYABLE, tostring(args.choice)))
    end,
    -- VERIFY LIVE: what the game's Done button changes besides taking_requests.
    done = function(d, args)
        if not d.taking_requests then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'done finishes the requests step and the dialog is not on it')
        end
        local replayed, err = replay({{d, 'taking_requests', false, 'diplomacy.taking_requests'}})
        if not replayed then return rpc.error_result(rpc.ERR_INTERNAL, 'done failed and was undone: ' .. err) end
        return {replayed = replayed}
    end,
    -- VERIFY LIVE: the land-holder choice; whether the game confirms it from these fields.
    land_holder = function(d, args)
        if not d.selecting_land_holder_position then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the dialog is not asking for a land holder')
        end
        local hf_id = tonumber(args.hf_id)
        if not hf_id then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"hf_id" is required for land_holder') end
        local found = false
        for _, id in ipairs(d.land_holder_avail_hfid) do
            if id == hf_id then found = true end
        end
        if not found then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('historical figure %d is not a candidate; pick one of '
                .. 'land_holder.candidates from get_meeting_dialog'):format(hf_id))
        end
        local pos = math.floor(tonumber(args.position_index) or 0)
        if pos < 0 or pos >= #d.land_holder_pos_id or pos >= #d.land_holder_assigned_hfid then
            return rpc.error_result(rpc.ERR_BAD_REQUEST,
                ('position_index must be 0-%d'):format(#d.land_holder_pos_id - 1))
        end
        local replayed, err = replay({
            {d, 'land_holder_selected_pos', pos, 'diplomacy.land_holder_selected_pos'},
            {d.land_holder_assigned_hfid, pos, hf_id, 'diplomacy.land_holder_assigned_hfid[' .. pos .. ']'},
        })
        if not replayed then return rpc.error_result(rpc.ERR_INTERNAL, 'land_holder failed and was undone: ' .. err) end
        return {replayed = replayed}
    end,
    -- VERIFY LIVE: whether mm.flags.close_screen must be set instead (not set in the guess).
    close = function(d, args)
        local replayed, err = replay({{d, 'open', false, 'diplomacy.open'}})
        if not replayed then return rpc.error_result(rpc.ERR_INTERNAL, 'close failed and was undone: ' .. err) end
        return {replayed = replayed}
    end,
}

STEP_ACTIONS = {'continue', 'choose', 'done', 'land_holder', 'close'}

local function dialog_step(args)
    local action = args.action
    if type(action) ~= 'string' or not REPLAY[action] then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"action" must be one of ' .. table.concat(STEP_ACTIONS, ', '))
    end
    if action == 'choose' and tonumber(args.choice) == nil then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"choice" (an index) is required for choose')
    end
    local d = diplomacy()
    -- Checked before the focus: a closed dialog has no Diplomacy focus to find.
    if not safe(function() return d.open end) then
        if action == 'close' then
            local out = screens.maybe_unpause(args)
            out.action, out.replayed, out.dialog = action, {}, dialog_state(args)
            out.note = 'the dialog was already closed; nothing was written'
            return out
        end
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the meeting dialog is not open; open it with open_meeting_dialog')
    end
    -- VERIFY LIVE: the focus string of the open dialog (DFHack's overlays use dwarfmode/Diplomacy).
    local busy = screens.require_focus({'dwarfmode/Diplomacy'}, 'step_meeting_dialog')
    if busy then return busy end
    local result = REPLAY[action](d, args)
    if result.__error then return result end
    local out = screens.maybe_unpause(action == 'close' and args or {})
    out.action = action
    out.replayed = result.replayed
    out.dialog = dialog_state(args)
    out.note = 'replayed from a guess not yet verified against the game; check dialog.step and tell the player '
        .. 'if the screen did not follow'
    if args.unpause == true and action ~= 'close' then
        out.pause_note = 'unpause applies to close only; the game stays paused while the dialog is open'
    end
    return out
end

----------------------------------------------------------------------------------------------
-- dev snapshot (claude-bridge dialog-snapshot): every scalar of the diplomacy interface, the
-- meeting moment and meeting, the alerts, focus, interface rect, and mouse, so the owner can
-- diff before and after a click. Read-only. Printed directly, so strings are converted here.

local function utf(value)
    if type(value) == 'string' then return (value:gsub('[^%c]+', dfhack.df2utf)) end
    return value
end

local function describe(value)
    local t = type(value)
    if t == 'boolean' or t == 'number' then return value end
    if t == 'string' then return utf(value) end
    if t ~= 'userdata' then return nil end
    local kind = safe(function() return value._kind end)
    if kind == 'container' then return {length = safe(function() return #value end)} end
    if kind == 'bitfield' then
        local set = {}
        pcall(function()
            for k, v in pairs(value) do
                if v == true then table.insert(set, k) end
            end
        end)
        return {flags = set}
    end
    if kind == 'struct' then
        local id = safe(function() return value.id end)
        return {struct = utf(safe(function() return tostring(value._type) end)),
                id = type(id) == 'number' and id or nil}
    end
    return {ref = utf(tostring(value))}
end

local function scalars(obj, skip)
    local out = {}
    pcall(function()
        for k, v in pairs(obj) do
            if not (skip and skip[k]) then out[k] = describe(v) end
        end
    end)
    return out
end

function dialog_snapshot()
    local d = diplomacy()
    local snap = {fields = scalars(d, {text = true, environment = true})}
    snap.fields.text = {words = safe(function() return #d.text.word end),
                        links = safe(function() return #d.text.link end),
                        max_y = safe(function() return d.text.max_y end)}
    snap.fields.environment = {dipev = safe(function() return d.environment.dipev ~= nil end),
                               mm = safe(function() return d.environment.mm ~= nil end)}
    local mm = safe(function() return d.mm end)
    snap.mm = mm and scalars(mm, {activity = true}) or nil
    local dipev = live_dipev(d)
    if dipev then
        snap.dipev = {
            civ_id = safe(function() return dipev.civ_id end),
            cur_step = safe(function() return dipev.cur_step end),
            standard_type = safe(function() return dipev.standard_type end),
            flags = describe(safe(function() return dipev.flags end)),
            events = safe(function() return #dipev.events end),
            active_script_vars = safe(function() return #dipev.active_script_vars end),
            from = safe(function() return d.dipev ~= nil end) and 'diplomacy.dipev' or 'diplomacy.environment.dipev',
        }
    end
    local alerts = {}
    pcall(function()
        for _, alert in ipairs(df.global.world.status.announcement_alert) do
            local ids = {}
            for _, id in ipairs(alert.announcement_id) do table.insert(ids, id) end
            table.insert(alerts, {type = enum_name(df.announcement_alert_type, alert.type) or alert.type, ids = ids})
        end
    end)
    snap.announcement_alert = alerts
    snap.alert_button_announcement_id = int_list(safe(function()
        return df.global.world.status.alert_button_announcement_id
    end) or {}, 1000)
    snap.focus = screens.focus()
    snap.interface_rect = safe(function()
        local r = require('gui').get_interface_rect()
        return {x1 = r.x1, y1 = r.y1, x2 = r.x2, y2 = r.y2, width = r.width, height = r.height}
    end)
    snap.mouse = {dfhack.screen.getMousePos()}
    snap.paused = safe(dfhack.world.ReadPauseState) == true
    return snap
end

function ops()
    return {
        ['trade.diplomats'] = {namespace = 'trade', handler = diplomats, needs_map = true},
        ['trade.request_options'] = {namespace = 'trade', handler = request_options, needs_map = true},
        ['trade.set_requests'] = {namespace = 'trade_write', handler = set_requests, needs_map = true},
        ['trade.dialog'] = {namespace = 'trade', handler = dialog_state, needs_map = true},
        ['trade.open_dialog'] = {namespace = 'screens_write', handler = open_dialog, needs_map = true},
        ['trade.dialog_step'] = {namespace = 'screens_write', handler = dialog_step, needs_map = true},
    }
end
