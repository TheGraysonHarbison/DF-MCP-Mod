-- Petitions (plan section 16, Patch 2 item P2-6.0; replaces 13.1). petitions.list reads the
-- pending petitions (plotinfo.petitions), optionally the fort's answered ones, the petition
-- standing orders, and the fort's temples and guildhalls. petitions.answer accepts or denies
-- one pending petition by driving the game's own petitions screen: the PETITIONS button on
-- the main screen is clicked, the petition is selected, the Approve or Deny button is
-- pressed by its on-screen label, the result is checked against plotinfo.petitions and the
-- agreement flags, and the screen is closed.
--
-- Why the screen and not raw writes: accepting a residency, citizenship, or location
-- petition makes the game do its own bookkeeping (an AGREEMENT_FORMED history event,
-- DFHack list-waves.lua reads it; the resident's links; the location obligation in
-- plotinfo.continuing_agreement_id). Flipping agreement.flags.petition_not_accepted and the
-- id vectors would hide the row without resolving it, which the multi-dwarf project
-- (SourceAirbender/multi-dwarf src/fort_admin.cpp, checked 2026-10-17) also concluded. So
-- the only writes here are mouse clicks fed to the game screen, Escape to close it, and
-- main_interface.petitions.selected_agreement_id (the screen's selection, set to an id
-- taken from the screen's own agreement_id list) when several petitions are pending.
--
-- NOT VERIFIED LIVE (no petition save; owner's decision 2026-10-17). The labels come from
-- the DF3D project (UncertainCat/DF3D bridge/plugin/petition_button.h, checked 2026-10-17):
-- the main screen shows "PETITIONS" while one waits, the petition text ends in "Do you
-- approve this request?", and "Approve" and "Deny" sit on one row below it.
-- Sources (df-structures master, checked 2026-10-17): df.agreement.xml (agreement,
-- agreement_details and its data union, agreement_flag: petition_not_accepted "unset by
-- accepting a petition", convicted_accepted "concluded"), df.plotinfo.xml (petitions =
-- unapproved_agreement_id, continuing_agreement_id), df.d_interface.xml
-- (petitions_interfacest: open, have_responsible_person, agreement_id, selected_agreement_id,
-- scroll_position), df.game_v.xml (standing_orders_petition_* globals),
-- df.abstract_building.xml (temples, guildhalls, religious_practice_data); DFHack develop
-- Gui.cpp (focus dwarfmode/Petitions while main_interface.petitions.open); DFHack 53.16-r2
-- scripts list-agreements.lua and gui/petitions.lua (status words, tier names, one-year
-- expiry rule, deity lookup).
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local state = reqscript('internal/claude-bridge/state')
local screens = reqscript('internal/claude-bridge/screens')

DEFAULT_LIMIT = 25
TICKS_PER_DAY = 1200
TICKS_PER_YEAR = 403200
DAYS_PER_YEAR = 336
PETITIONS_FOCUS = 'dwarfmode/Petitions'
-- The main-screen button that opens the petitions screen (DF3D petitionLauncher).
LAUNCHER_LABEL = 'PETITIONS'
ACCEPT_LABEL = 'Approve'
DENY_LABEL = 'Deny'
QUESTION_TEXT = 'Do you approve this request?'
-- The decision buttons share a row; Deny starts 8 to 20 columns right of Approve (DF3D).
DENY_MIN_GAP, DENY_MAX_GAP = 8, 20
-- answer() runs in stages across calls because the screen text is read from the last
-- rendered frame: the server calls again until `done`. A stage waits at least this long
-- for the game to draw, and gives up after MAX_WAITS calls without progress.
FRAME_WAIT_MS = 150
MAX_WAITS = 12
-- A session older than this is abandoned: its screen counts as the player's again.
SESSION_MAX_AGE_MS = 60000

-- Standing orders the game keeps for future petitions (patch 53.12 added automatic
-- accept or reject). Values 0 ask, 1 accept, 2 reject per multi-dwarf's reading; the
-- meaning is not verified here, so the raw value is returned beside it.
STANDING_ORDERS = {
    monster_hunter = 'standing_orders_petition_resident_monster_hunter',
    performer = 'standing_orders_petition_resident_performer',
    mercenary = 'standing_orders_petition_resident_mercenary',
    scholar = 'standing_orders_petition_resident_scholar',
    sanctuary = 'standing_orders_petition_resident_sanctuary',
    citizenship = 'standing_orders_petition_citizenship',
}
STANDING_ORDER_VALUES = {[0] = 'ask', [1] = 'accept', [2] = 'reject'}
-- Residency reason -> standing order group (multi-dwarf's mapping).
REASON_GROUP = {
    entertain_people = 'performer', hire_on_as_performer = 'performer',
    eradicate_beasts = 'monster_hunter',
    make_a_living_as_a_warrior = 'mercenary', hire_on_as_mercenary = 'mercenary',
    study = 'scholar', scholarship = 'scholar', hire_on_as_scholar = 'scholar',
    seek_sanctuary = 'sanctuary',
}

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

local function now_ms()
    return dfhack.getTickCount()
end

local function id_list(vec)
    local out = {}
    pcall(function()
        for _, id in ipairs(vec) do table.insert(out, id) end
    end)
    return out
end

local function contains(list, value)
    for _, v in ipairs(list) do
        if v == value then return true end
    end
    return false
end

function pending_ids()
    return id_list(safe(function() return df.global.plotinfo.petitions end) or {})
end

function continuing_ids()
    return id_list(safe(function() return df.global.plotinfo.continuing_agreement_id end) or {})
end

local function ui()
    return safe(function() return df.global.game.main_interface.petitions end)
end

local function ui_open()
    local pi = ui()
    return pi ~= nil and safe(function() return pi.open end) == true
end

----------------------------------------------------------------------------------------------
-- reading one agreement

local function first_details(agreement)
    return safe(function()
        if #agreement.details == 0 then return nil end
        return agreement.details[0]
    end)
end

-- The union member that matches the details' type, or nil (reading the wrong member of the
-- data union reinterprets the pointer, so the type is always checked first).
local function details_data(details)
    local kind = enum_name(df.agreement_details_type, details.type)
    if not kind then return nil, nil end
    return kind, safe(function() return details.data[kind] end)
end

local function find_party(agreement, party_id)
    if not party_id or party_id < 0 then return nil end
    return safe(function()
        for _, party in ipairs(agreement.parties) do
            if party.id == party_id then return party end
        end
        return nil
    end)
end

local function hf_info(hf_id)
    local fig = hf_id and hf_id >= 0 and safe(df.historical_figure.find, hf_id) or nil
    if not fig then return {hist_figure_id = hf_id} end
    local out = {hist_figure_id = hf_id, name = translate(fig.name, false),
                 name_english = translate(fig.name, true),
                 race = safe(function() return dfhack.units.getRaceNameById(fig.race) end),
                 profession = enum_name(df.profession, fig.profession)}
    local unit = safe(function() return fig.unit_id >= 0 and df.unit.find(fig.unit_id) or nil end)
    if unit then
        out.unit_id = unit.id
        out.name = safe(dfhack.units.getReadableName, unit) or out.name
        out.profession = safe(dfhack.units.getProfessionName, unit) or out.profession
        out.on_map = safe(dfhack.units.isActive, unit) == true
        out.pos = {x = unit.pos.x, y = unit.pos.y, z = unit.pos.z}
    else
        out.on_map = false
    end
    return out
end

local function entity_info(entity_id)
    local ent = entity_id and safe(df.historical_entity.find, entity_id) or nil
    if not ent then return {entity_id = entity_id} end
    return {entity_id = entity_id, name = translate(ent.name, true), name_native = translate(ent.name, false),
            type = enum_name(df.historical_entity_type, ent.type),
            members = safe(function() return #ent.histfig_ids end)}
end

-- {party_id, figures = [hf_info], entities = [entity_info], name} capped at `cap` each.
local function party_info(agreement, party_id, cap)
    local party = find_party(agreement, party_id)
    if not party then return {party_id = party_id} end
    local out = {party_id = party_id, figures = {}, entities = {}}
    pcall(function()
        for i, hf_id in ipairs(party.histfig_ids) do
            if i >= cap then out.figures_truncated = true break end
            table.insert(out.figures, hf_info(hf_id))
        end
        for i, en_id in ipairs(party.entity_ids) do
            if i >= cap then out.entities_truncated = true break end
            table.insert(out.entities, entity_info(en_id))
        end
    end)
    local lead = out.figures[1] or out.entities[1]
    out.name = lead and lead.name or nil
    return out
end

local function deity_info(practice_type, practice_id)
    local kind = enum_name(df.religious_practice_type, practice_type)
    local out = {practice = kind, practice_id = practice_id}
    if kind == 'WORSHIP_HFID' then
        local fig = safe(df.historical_figure.find, practice_id)
        out.name = fig and translate(fig.name, true) or nil
        out.hist_figure_id = practice_id
    elseif kind == 'RELIGION_ENID' then
        local ent = safe(df.historical_entity.find, practice_id)
        if ent then
            out.religion = translate(ent.name, true)
            out.entity_id = practice_id
            local deity_id = safe(function() return ent.relations.deities[0] end)
            local fig = deity_id and safe(df.historical_figure.find, deity_id) or nil
            out.name = fig and translate(fig.name, true) or out.religion
        end
    end
    return out
end

local function profession_info(prof)
    local token = enum_name(df.profession, prof)
    if not token then return nil end
    return {token = token, caption = safe(function() return df.profession.attrs[prof].caption end)}
end

-- Tier names as list-agreements.lua prints them.
local function location_name(kind, tier)
    if kind == 'TEMPLE' then return tier == 2 and 'Temple Complex' or 'Temple' end
    if kind == 'GUILDHALL' then return tier == 2 and 'Grand Guildhall' or 'Guildhall' end
    return kind and kind:lower() or 'location'
end

local function age_days(year, tick)
    local delta = (df.global.cur_year - year) * TICKS_PER_YEAR + (df.global.cur_year_tick - tick)
    if delta < 0 then delta = 0 end
    return math.floor(delta / TICKS_PER_DAY)
end

local function standing_order(group)
    local global_name = group and STANDING_ORDERS[group]
    if not global_name then return nil end
    local value = safe(function() return df.global[global_name] end)
    if value == nil then return {group = group, available = false} end
    return {group = group, value = value, meaning = STANDING_ORDER_VALUES[value]}
end

-- The row for one agreement; `pending` and `continuing` are the plotinfo lists.
function describe(id, pending, continuing, cap)
    cap = cap or DEFAULT_LIMIT
    local agreement = safe(df.agreement.find, id)
    local row = {id = id, pending = contains(pending, id), continuing = contains(continuing, id)}
    if not agreement then
        row.status = row.pending and 'pending' or 'missing'
        row.note = 'the agreement record is gone'
        return row
    end
    local details = first_details(agreement)
    row.flags = {petition_not_accepted = safe(function() return agreement.flags.petition_not_accepted end) == true,
                 concluded = safe(function() return agreement.flags.convicted_accepted end) == true}
    row.detail_types = {}
    pcall(function()
        for _, d in ipairs(agreement.details) do
            table.insert(row.detail_types, enum_name(df.agreement_details_type, d.type) or tostring(d.type))
        end
    end)
    if not details then
        row.status = row.pending and 'pending' or 'unknown'
        return row
    end
    local kind, data = details_data(details)
    row.kind = kind and kind:lower() or 'unknown'
    row.made = {year = details.year, tick = details.year_tick}
    row.age_days = safe(age_days, details.year, details.year_tick)
    if data then
        local applicant_id = safe(function() return data.applicant end)
        local government_id = safe(function() return data.government end)
        if applicant_id then row.applicant = party_info(agreement, applicant_id, cap) end
        if government_id then row.government = party_info(agreement, government_id, 3) end
        row.site_id = safe(function() return data.site end)
    end
    if kind == 'Residency' and data then
        row.reason = enum_name(df.history_event_reason, data.reason)
        row.standing_order = standing_order(REASON_GROUP[row.reason or ''])
        local end_year = safe(function() return data.end_year end)
        if end_year and end_year >= 0 then
            row.term_end = {year = end_year, tick = safe(function() return data.end_season_tick end)}
        end
    elseif kind == 'Citizenship' and data then
        row.standing_order = standing_order('citizenship')
    elseif kind == 'Location' and data then
        local loc_type = enum_name(df.abstract_building_type, data.type)
        local tier = safe(function() return data.tier end)
        row.location = {type = loc_type and loc_type:lower() or nil, tier = tier,
                        name = location_name(loc_type, tier),
                        warned_is_ready = safe(function() return data.flags.warned_is_ready end) == true}
        if loc_type == 'TEMPLE' then
            row.location.deity = deity_info(data.deity_type, safe(function() return data.deity_data.practice_id end))
        elseif loc_type == 'GUILDHALL' then
            row.location.profession = profession_info(data.profession)
        end
    end
    -- Status words as list-agreements.lua uses them, plus pending and accepted.
    if row.pending then
        row.status = 'pending'
        if row.age_days then
            row.days_left_estimate = math.max(0, DAYS_PER_YEAR - row.age_days)
        end
    elseif row.flags.concluded then
        row.status = 'satisfied'
    elseif row.flags.petition_not_accepted then
        row.status = 'denied'
    elseif row.age_days and row.age_days >= DAYS_PER_YEAR and kind == 'Location' then
        row.status = 'expired'
    else
        row.status = 'accepted'
    end
    row.summary = summary_text(row)
    return row
end

-- One line for a row: "Residency petition from Urist (eradicate beasts)".
function summary_text(row)
    local who = row.applicant and row.applicant.name or 'an unknown party'
    if row.kind == 'location' and row.location then
        local what = row.location.name or 'location'
        local extra = ''
        if row.location.deity and row.location.deity.name then
            extra = ' worshipping ' .. row.location.deity.name
        elseif row.location.profession then
            extra = ' for ' .. tostring(row.location.profession.caption or row.location.profession.token):lower()
        end
        return ('%s request from %s%s'):format(what, who, extra)
    end
    local reason = row.reason and (' (' .. row.reason:gsub('_', ' ') .. ')') or ''
    return ('%s petition from %s%s'):format((row.kind or 'unknown'):gsub('^%l', string.upper), who, reason)
end

-- The text the petition event uses (events.lua).
function event_text(id)
    local row = describe(id, pending_ids(), continuing_ids(), 3)
    return row.summary and (row.summary .. ' awaits an answer') or nil
end

-- What the game is expected to do on each answer (wiki Petition, Resident, Guildhall pages,
-- checked 2026-10-15; the game's own handler applies it, nothing here writes it).
local function effects(row, accept)
    if not accept then
        return 'the petition is refused and leaves the pending list; the petitioner is not admitted or the location is not promised'
    end
    if row.kind == 'residency' then
        return 'the petitioner stays as a resident (lives at the tavern, does the work of their purpose, is not a citizen)'
    elseif row.kind == 'citizenship' then
        return 'the petitioner becomes a citizen of the fort'
    elseif row.kind == 'location' then
        return ('the fort promises to establish a %s; it joins the accepted agreements until built'):format(
            row.location and row.location.name or 'location')
    end
    return 'the game applies its own effects for this agreement type'
end

----------------------------------------------------------------------------------------------
-- the fort's locations (temples and guildhalls)

local function fort_locations(limit)
    local out, count, truncated = {}, 0, false
    pcall(function()
        local site = dfhack.world.getCurrentSite()
        for _, bld in ipairs(site.buildings) do
            local kind = enum_name(df.abstract_building_type, bld:getType())
            if kind == 'TEMPLE' or kind == 'GUILDHALL' then
                count = count + 1
                if #out >= limit then
                    truncated = true
                else
                    local row = {id = bld.id, type = kind:lower(), name = translate(bld.name, true),
                                 tier = safe(function() return bld.contents.location_tier end),
                                 zones = safe(function() return #bld.contents.building_ids end)}
                    if kind == 'TEMPLE' then
                        row.deity = deity_info(bld.deity_type, safe(function() return bld.deity_data.practice_id end))
                    else
                        row.profession = profession_info(safe(function() return bld.contents.profession end))
                    end
                    table.insert(out, row)
                end
            end
        end
    end)
    return out, count, truncated
end

----------------------------------------------------------------------------------------------
-- petitions.list

local function fort_agreement_ids(pending, continuing)
    local seen, ids = {}, {}
    local function add(id)
        if not seen[id] then seen[id] = true table.insert(ids, id) end
    end
    for _, id in ipairs(continuing) do add(id) end
    local site_id = safe(function() return df.global.plotinfo.site_id end)
    pcall(function()
        for _, agreement in ipairs(df.global.world.agreements.all) do
            local details = first_details(agreement)
            if details then
                local kind, data = details_data(details)
                if (kind == 'Residency' or kind == 'Citizenship' or kind == 'Location') and data
                        and safe(function() return data.site end) == site_id then
                    add(agreement.id)
                end
            end
        end
    end)
    local out = {}
    for _, id in ipairs(ids) do
        if not contains(pending, id) then table.insert(out, id) end
    end
    table.sort(out, function(a, b) return a > b end)
    return out
end

local function list(args)
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    if limit < 1 then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be at least 1') end
    local pending, continuing = pending_ids(), continuing_ids()
    local rows, truncated = {}, false
    for _, id in ipairs(pending) do
        if #rows >= limit then truncated = true break end
        table.insert(rows, describe(id, pending, continuing, limit))
    end
    local out = {count = #pending, petitions = rows, truncated = truncated}
    if args.include_resolved == true then
        local ids = fort_agreement_ids(pending, continuing)
        local resolved = {}
        for _, id in ipairs(ids) do
            if #resolved >= limit then out.resolved_truncated = true break end
            table.insert(resolved, describe(id, pending, continuing, limit))
        end
        out.resolved = resolved
        out.resolved_count = #ids
        out.resolved_truncated = out.resolved_truncated or false
    end
    local orders = {}
    for group in pairs(STANDING_ORDERS) do orders[group] = standing_order(group) end
    out.standing_orders = orders
    local locations, loc_count, loc_truncated = fort_locations(limit)
    out.locations = locations
    out.locations_count = loc_count
    out.locations_truncated = loc_truncated
    out.screen_open = ui_open()
    out.note = 'answer a pending petition with answer_petition (units_write and screens_write); days_left_estimate '
        .. 'uses the one-year rule of DFHack list-agreements, the game\'s own timeout for an unanswered petition '
        .. 'is not verified; standing order meanings are not verified'
    return out
end

----------------------------------------------------------------------------------------------
-- petitions.answer: staged screen driving

local function session()
    local s = rawget(_G, 'claude_bridge_petition_session')
    if s and now_ms() - (s.started or 0) > SESSION_MAX_AGE_MS then
        _G.claude_bridge_petition_session = nil
        return nil
    end
    return s
end

local function set_session(s)
    _G.claude_bridge_petition_session = s
end

-- Every on-screen occurrence of `label` as whole-word, case-sensitive text: {{x, y}}.
local function label_positions(rows, ir, label)
    local out = {}
    local pattern = '%f[%w]' .. label:gsub('%W', '%%%0') .. '%f[%W]'
    for y = ir.y1, ir.y2 do
        local start = 1
        while true do
            local i, j = rows[y]:find(pattern, start)
            if not i then break end
            table.insert(out, {x = ir.x1 + i - 1, y = y, width = j - i + 1})
            start = j + 1
        end
    end
    return out
end

-- The Approve and Deny buttons: exactly one of each, on one row, Deny to the right
-- (DF3D petitionDecisionButton). Returns {approve, deny, question_seen} or nil, reason.
local function decision_buttons()
    local rows, ir = screens.screen_rows()
    local approve = label_positions(rows, ir, ACCEPT_LABEL)
    local deny = label_positions(rows, ir, DENY_LABEL)
    local question_seen = false
    for y = ir.y1, ir.y2 do
        if rows[y]:find(QUESTION_TEXT, 1, true) then question_seen = true end
    end
    if #approve ~= 1 or #deny ~= 1 then
        return nil, ('expected one "%s" and one "%s" on screen, found %d and %d'):format(
            ACCEPT_LABEL, DENY_LABEL, #approve, #deny)
    end
    local a, d = approve[1], deny[1]
    local gap = d.x - a.x
    if a.y ~= d.y or gap < DENY_MIN_GAP or gap > DENY_MAX_GAP then
        return nil, 'the Approve and Deny labels are not side by side on one row'
    end
    return {approve = {x = a.x + math.floor((a.width - 1) / 2), y = a.y},
            deny = {x = d.x + math.floor((d.width - 1) / 2), y = d.y},
            question_seen = question_seen}
end

local function name_on_screen(row)
    local names = {}
    local app = row.applicant or {}
    for _, f in ipairs(app.figures or {}) do
        if f.name then table.insert(names, f.name) end
    end
    for _, e in ipairs(app.entities or {}) do
        if e.name_native then table.insert(names, e.name_native) end
        if e.name then table.insert(names, e.name) end
    end
    if #names == 0 then return nil end
    local rows, ir = screens.screen_rows()
    for y = ir.y1, ir.y2 do
        for _, name in ipairs(names) do
            if rows[y]:find(name, 1, true) then return true end
        end
    end
    return false
end

-- Close the petitions screen with Escape; returns whether it is closed afterwards.
local function close_screen()
    if not ui_open() then return true end
    pcall(screens.press_key, 'LEAVESCREEN')
    return not ui_open()
end

-- What changed for `id` since `before` ({pending}). outcome: pending, accepted, denied, gone.
local function outcome_of(id, before)
    local pending = pending_ids()
    local out = {still_pending = contains(pending, id), in_continuing = contains(continuing_ids(), id),
                 others_removed = {}}
    for _, other in ipairs(before.pending or {}) do
        if other ~= id and not contains(pending, other) then table.insert(out.others_removed, other) end
    end
    local agreement = safe(df.agreement.find, id)
    if out.still_pending then
        out.outcome = 'pending'
    elseif not agreement then
        out.outcome = 'gone'
    elseif safe(function() return agreement.flags.petition_not_accepted end) == true then
        out.outcome = 'denied'
    else
        out.outcome = 'accepted'
    end
    return out
end

local function verified_for(accept, result)
    if accept then return result.outcome == 'accepted' end
    return result.outcome == 'denied' or result.outcome == 'gone'
end

-- Final result: closes the screen, clears the session, optional unpause.
local function finish(s, args, fields)
    local closed = close_screen()
    set_session(nil)
    local out = screens.maybe_unpause(args)
    for k, v in pairs(fields) do out[k] = v end
    out.done = true
    out.id = s and s.id or args.id
    out.accept = s and s.accept
    out.screen_closed = closed
    if not closed then
        out.close_note = 'the petitions screen did not close on Escape; ask the player to close it'
    end
    return out
end

-- Refuse part-way: close the bridge's screen, end the session, no unpause.
local function abort(s, message, code)
    local closed = close_screen()
    set_session(nil)
    if not closed then message = message .. '; the petitions screen did not close, ask the player to close it' end
    return rpc.error_result(code or rpc.ERR_NOT_FOUND, message)
end

local function waiting(s, stage, note)
    s.stage = stage
    return {done = false, stage = stage, id = s.id, waits = s.waits, note = note}
end

-- One more call without progress; gives up after MAX_WAITS.
local function wait_or_fail(s, args, reason)
    s.waits = (s.waits or 0) + 1
    if s.waits <= MAX_WAITS then return waiting(s, s.stage, reason) end
    local rows = screens.text_rows(40)
    return finish(s, args, {answered = s.pressed == true, verified = false, reason = reason,
                            screen_rows = rows,
                            note = 'gave up waiting on the petitions screen; the screen was closed. Report screen_rows '
                                .. 'to the owner if the labels differ from Approve and Deny'})
end

local STAGES = {}

-- Click PETITIONS on the main screen; the game opens and fills the petitions screen.
STAGES.start = function(s, args)
    if ui_open() then
        return rpc.error_result(rpc.ERR_SCREEN_BUSY,
            'the petitions screen is already open (the player may be answering); the player\'s screen is left alone')
    end
    local busy = screens.require_focus({screens.MAIN_FOCUS}, 'answer_petition')
    if busy then return busy end
    local clicked, why = screens.click_label(LAUNCHER_LABEL)
    if not clicked then
        set_session(nil)
        return rpc.error_result(rpc.ERR_NOT_FOUND, why .. ' (the game shows it on the main screen while a petition '
            .. 'waits); ask the player to open the petitions screen and answer, or try again')
    end
    s.opened_by_bridge = true
    s.launcher = clicked
    s.t = now_ms()
    s.waits = 0
    return waiting(s, 'opening', 'clicked PETITIONS; waiting for the screen')
end

STAGES.opening = function(s, args)
    if not ui_open() then return wait_or_fail(s, args, 'the PETITIONS click did not open the petitions screen') end
    local busy = screens.require_focus({PETITIONS_FOCUS}, 'answer_petition')
    if busy then
        return wait_or_fail(s, args, 'the petitions screen is open but another screen is on top')
    end
    local pi = ui()
    if not pi.have_responsible_person then
        return abort(s, 'the petitions screen says no one can hear petitions (have_responsible_person is false: '
            .. 'appoint the noble who hears them, usually the mayor or expedition leader); nothing was answered')
    end
    local listed = id_list(pi.agreement_id)
    if not contains(listed, s.id) then
        return abort(s, ('petition %d is not on the petitions screen (it lists %s); nothing was answered')
            :format(s.id, #listed > 0 and table.concat(listed, ', ') or 'none'))
    end
    s.listed = listed
    if pi.selected_agreement_id ~= s.id then
        -- VERIFY LIVE: the selection field is assumed to be what a click on the list sets.
        s.selected_before = pi.selected_agreement_id
        pi.selected_agreement_id = s.id
        s.selected_by_bridge = true
    end
    s.t = now_ms()
    s.waits = 0
    return waiting(s, 'ready', 'petition selected; waiting for the screen to draw it')
end

STAGES.ready = function(s, args)
    if not ui_open() then
        set_session(nil)
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the petitions screen closed before the answer; nothing was pressed')
    end
    local busy = screens.require_focus({PETITIONS_FOCUS}, 'answer_petition')
    if busy then return wait_or_fail(s, args, 'another screen is on top of the petitions screen') end
    if now_ms() - (s.t or 0) < FRAME_WAIT_MS then return waiting(s, 'ready', 'waiting for a frame') end
    local pi = ui()
    if pi.selected_agreement_id ~= s.id then
        return abort(s, ('the screen selection moved to %d; nothing was pressed'):format(pi.selected_agreement_id),
            rpc.ERR_BAD_REQUEST)
    end
    local buttons, why = decision_buttons()
    if not buttons then return wait_or_fail(s, args, why) end
    local row = describe(s.id, pending_ids(), continuing_ids(), 5)
    local target = s.accept and buttons.approve or buttons.deny
    if args.dry_run == true then
        return finish(s, args, {answered = false, verified = false, dry_run = true,
                                would_press = {label = s.accept and ACCEPT_LABEL or DENY_LABEL, x = target.x, y = target.y},
                                question_seen = buttons.question_seen, applicant_on_screen = name_on_screen(row),
                                petition = row, effects = effects(row, s.accept),
                                note = 'dry run: the screen was opened, the button found, and the screen closed without pressing'})
    end
    s.before = {pending = pending_ids()}
    s.applicant_on_screen = name_on_screen(row)
    s.question_seen = buttons.question_seen
    s.petition = row
    local ok, err = pcall(screens.click_at, target.x, target.y)
    if not ok then
        return finish(s, args, {answered = false, verified = false, reason = 'the click failed: ' .. tostring(err)})
    end
    s.pressed = true
    s.clicked = {label = s.accept and ACCEPT_LABEL or DENY_LABEL, x = target.x, y = target.y}
    s.t = now_ms()
    s.waits = 0
    s.stage = 'pressed'
    return STAGES.pressed(s, args)
end

STAGES.pressed = function(s, args)
    local result = outcome_of(s.id, s.before or {})
    if result.outcome == 'pending' then
        return wait_or_fail(s, args, ('pressed %s but petition %d is still pending'):format(s.clicked.label, s.id))
    end
    local verified = verified_for(s.accept, result)
    local fields = {answered = true, verified = verified, outcome = result.outcome,
                    in_continuing = result.in_continuing, clicked = s.clicked,
                    question_seen = s.question_seen, applicant_on_screen = s.applicant_on_screen,
                    petition = s.petition, effects = effects(s.petition or {}, s.accept)}
    if not verified then
        fields.reason = ('asked to %s but the agreement now reads %s'):format(s.accept and 'accept' or 'deny',
            result.outcome)
    end
    if #result.others_removed > 0 then
        fields.verified = false
        fields.others_removed = result.others_removed
        fields.warning = 'other petitions also left the pending list; check them with list_petitions'
    end
    fields.note = fields.verified and 'answered through the game\'s petitions screen and checked against the agreement'
        or 'the answer could not be verified; check list_petitions(include_resolved=true) and tell the player'
    return finish(s, args, fields)
end

local function cancel(args)
    local s = session()
    if not s then
        return {done = true, cancelled = false, note = 'no petition answer was in progress; nothing was touched'}
    end
    local out = finish(s, args, {cancelled = true, answered = s.pressed == true, verified = false})
    out.note = 'the bridge\'s petition session was ended and its screen closed'
    return out
end

-- Preview without touching any screen.
local function preview(id, accept, args)
    local pending, continuing = pending_ids(), continuing_ids()
    local row = describe(id, pending, continuing, 5)
    local launcher = not ui_open() and screens.find_label(LAUNCHER_LABEL) ~= nil
    local blockers = {}
    if not state.is_allowed('screens_write') then table.insert(blockers, 'screens_write is off') end
    if ui_open() then table.insert(blockers, 'the petitions screen is already open') end
    if not ui_open() and not screens.has_focus(screens.MAIN_FOCUS) then
        table.insert(blockers, 'the game shows ' .. screens.focus_string() .. ', not the main screen')
    end
    if not ui_open() and not launcher then table.insert(blockers, 'no PETITIONS button is on the main screen') end
    return {done = true, dry_run = true, id = id, accept = accept, answered = false, petition = row,
            would_press = accept and ACCEPT_LABEL or DENY_LABEL, effects = effects(row, accept),
            launcher_visible = launcher, can_answer_now = #blockers == 0, blockers = blockers,
            note = 'nothing was opened or pressed; whether someone can hear petitions is only known once the '
                .. 'screen is open (pass screen=true with dry_run to open it, find the button, and close it)'}
end

local function answer(args)
    if args.cancel == true then return cancel(args) end
    local id = tonumber(args.id)
    if not id or id ~= math.floor(id) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"id" must be a petition (agreement) id from list_petitions')
    end
    if type(args.accept) ~= 'boolean' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"accept" must be true or false')
    end
    local s = session()
    if args.continue == true then
        if not s or s.id ~= id or s.accept ~= args.accept then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'no petition answer is in progress for this id; start again')
        end
        local stage = STAGES[s.stage]
        if not stage then
            return finish(s, args, {answered = false, verified = false, reason = 'unknown stage ' .. tostring(s.stage)})
        end
        return stage(s, args)
    end
    if args.dry_run == true and args.screen ~= true then return preview(id, args.accept, args) end
    if not state.is_allowed('screens_write') then
        return rpc.error_result(rpc.ERR_NOT_ALLOWED,
            'answering a petition drives the game\'s petitions screen and needs "screens_write" as well as "units_write"')
    end
    if not contains(pending_ids(), id) then
        local agreement = safe(df.agreement.find, id)
        if agreement then
            local row = describe(id, pending_ids(), continuing_ids(), 3)
            return rpc.error_result(rpc.ERR_BAD_REQUEST, ('agreement %d is not a pending petition (status %s)')
                :format(id, tostring(row.status)))
        end
        return rpc.error_result(rpc.ERR_NOT_FOUND, ('no pending petition has id %d; see list_petitions'):format(id))
    end
    if s then
        -- An earlier answer of ours was left part-way: close its screen first.
        local closed = s.opened_by_bridge and close_screen() or true
        set_session(nil)
        if not closed then
            return rpc.error_result(rpc.ERR_SCREEN_BUSY, 'an earlier petition screen of the bridge did not close; ask the player')
        end
        if s.opened_by_bridge then
            set_session({id = id, accept = args.accept, stage = 'start', started = now_ms(), t = now_ms(), waits = 0})
            return {done = false, stage = 'start', id = id, note = 'closed the screen an earlier answer left open'}
        end
    end
    s = {id = id, accept = args.accept, stage = 'start', started = now_ms(), t = now_ms(), waits = 0}
    set_session(s)
    local result = STAGES.start(s, args)
    if result.__error then set_session(nil) end
    return result
end

function ops()
    return {
        ['petitions.list'] = {namespace = 'units', handler = list, needs_map = true},
        ['petitions.answer'] = {namespace = 'units_write', handler = answer, needs_map = true},
    }
end
