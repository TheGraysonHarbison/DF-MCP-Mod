-- Labor: the fort's work details (the game's Labor screen), their members and their mode
-- (plan section 15.2 "Labor scope", item P1.0). Since v50 the game derives each unit's labors
-- from the work details, so the mod only edits detail membership and mode and then asks the
-- game to recompute. The technique is DFHack's own gui/manipulator (53.16-r2,
-- hack/scripts/gui/manipulator.lua, toggle_sorted_vec and the work-details column):
-- utils.insert_sorted / utils.erase_sorted on `assigned_units`, then
-- dfhack.units.setAutomaticProfessions(unit) ("Set appropriate labors on a unit based on
-- current work detail settings", Lua API units section,
-- https://docs.dfhack.org/en/stable/docs/dev/Lua%20API.html, checked 2026-10-16 against
-- 53.16-r2). Struct fields from df-structures master df.plotinfo.xml (work_detail,
-- work_detail_flags, work_detail_mode, labor_infost) and df.unit.xml (status.labors), checked
-- 2026-10-16. Never writes unit.status.labors, never creates, deletes, renames or re-icons a
-- detail, and never changes a detail's allowed_labors.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')
local utils = require('utils')

local U = dfhack.units

DEFAULT_LIMIT = 25
LABORS_AFTER_LIMIT = 25

-- work_detail_mode enum names to the words the protocol uses, and back.
local MODE_WORDS = {
    Default = 'default',
    EverybodyDoesThis = 'everybody',
    NobodyDoesThis = 'nobody',
    OnlySelectedDoesThis = 'only_selected',
}
local SETTABLE_MODES = {
    everybody = 'EverybodyDoesThis',
    nobody = 'NobodyDoesThis',
    only_selected = 'OnlySelectedDoesThis',
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function enum_name(enum, value)
    if value == nil then return nil end
    local name = safe(function() return enum[value] end)
    if type(name) == 'string' then return name end
    return nil
end

local function work_details()
    return safe(function() return df.global.plotinfo.labor_info.work_details end)
end

-- Strings stay CP437 inside this module: rpc.dispatch converts every outgoing string with
-- df2utf (to_utf8), so converting here too would garble accented names.
local function detail_name(wd)
    return safe(function() return wd.name end) or ''
end

local function mode_word(wd)
    local value = safe(function() return wd.flags.mode end)
    local name = enum_name(df.work_detail_mode, value)
    return name and MODE_WORDS[name] or tostring(value)
end

-- Names of the set entries of a bool array indexed by df.unit_labor.
local function labor_names(array_of)
    local out = {}
    for i = 0, df.unit_labor._last_item do
        if safe(function() return array_of()[i] end) then
            table.insert(out, enum_name(df.unit_labor, i) or tostring(i))
        end
    end
    return out
end

local function unit_name(unit)
    return safe(U.getReadableName, unit)
end

local function profession_name(unit)
    return safe(U.getProfessionName, unit)
end

local function is_member(wd, id)
    return safe(function() return utils.binsearch(wd.assigned_units, id) ~= nil end) == true
end

local function not_readable()
    return rpc.error_result(rpc.ERR_INTERNAL, 'work details are not readable on this build')
end

-- Resolve `detail`: 1-based index, exact name (case-insensitive), or a unique
-- case-insensitive substring. Returns wd, index, or nil, nil, error_result.
local function resolve_detail(wanted)
    local details = work_details()
    if not details then return nil, nil, not_readable() end
    if wanted == nil or (type(wanted) == 'string' and wanted:match('^%s*$')) then
        return nil, nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"detail" (1-based index or name from list_work_details) is required')
    end
    local names = {}
    for i = 0, #details - 1 do names[i + 1] = detail_name(details[i]) end
    local as_number = tonumber(wanted)
    if as_number then
        as_number = math.floor(as_number)
        if as_number < 1 or as_number > #details then
            return nil, nil, rpc.error_result(rpc.ERR_NOT_FOUND,
                ('no work detail %d; there are %d: %s'):format(as_number, #details,
                    table.concat(names, ', ')))
        end
        return details[as_number - 1], as_number
    end
    -- `wanted` arrives as UTF-8; the names are CP437, and so are the messages below.
    local wanted_df = safe(dfhack.utf2df, tostring(wanted)) or tostring(wanted)
    local needle = wanted_df:lower():match('^%s*(.-)%s*$')
    for i, name in ipairs(names) do
        if name:lower() == needle then return details[i - 1], i end
    end
    local hits = {}
    for i, name in ipairs(names) do
        if name:lower():find(needle, 1, true) then table.insert(hits, i) end
    end
    if #hits == 1 then return details[hits[1] - 1], hits[1] end
    if #hits == 0 then
        return nil, nil, rpc.error_result(rpc.ERR_NOT_FOUND,
            ('no work detail matches "%s"; details: %s'):format(wanted_df,
                table.concat(names, ', ')))
    end
    local candidates = {}
    for _, i in ipairs(hits) do table.insert(candidates, names[i]) end
    return nil, nil, rpc.error_result(rpc.ERR_BAD_REQUEST,
        ('"%s" matches several work details: %s; give the full name or the index')
            :format(wanted_df, table.concat(candidates, ', ')))
end

local function describe(wd, index, limit)
    local members, total = {}, 0
    local ids = safe(function() return wd.assigned_units end)
    if ids then
        for i = 0, #ids - 1 do
            total = total + 1
            if #members < limit then
                local id = ids[i]
                local unit = df.unit.find(id)
                table.insert(members, {
                    id = id,
                    name = unit and unit_name(unit) or nil,
                    profession = unit and profession_name(unit) or nil,
                })
            end
        end
    end
    return {
        index = index,
        name = detail_name(wd),
        mode = mode_word(wd),
        locked = safe(function() return wd.flags.no_modify end) == true,
        cannot_be_everybody = safe(function() return wd.flags.cannot_be_everybody end) == true,
        icon = enum_name(df.work_detail_icon_type, safe(function() return wd.icon end)),
        labors = labor_names(function() return wd.allowed_labors end),
        members = members,
        member_count = total,
        members_truncated = total > #members,
    }
end

local function details(args)
    local limit = math.floor(tonumber(args.limit) or DEFAULT_LIMIT)
    if limit < 1 then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"limit" must be positive') end
    local rows = {}
    if args.detail ~= nil then
        local wd, index, err = resolve_detail(args.detail)
        if err then return err end
        table.insert(rows, describe(wd, index, limit))
    else
        local list = work_details()
        if not list then return not_readable() end
        for i = 0, #list - 1 do table.insert(rows, describe(list[i], i + 1, limit)) end
    end
    return {
        count = #rows,
        details = rows,
        children_do_chores = safe(function()
            return df.global.plotinfo.labor_info.flags.children_do_chores
        end) == true,
        note = 'Membership only matters when a detail\'s mode is only_selected: everybody '
            .. 'means every adult citizen does its labors, nobody means no one does. '
            .. 'member_count is the full number when members_truncated is true.',
    }
end

-- Why this unit cannot be put on or taken off a detail, or nil.
local function refusal(unit)
    if not unit then return 'no unit with this id' end
    if safe(U.isDead, unit) then return 'dead' end
    if not safe(U.isCitizen, unit, true) then return 'not a citizen' end
    if safe(U.isBaby, unit) then return 'baby; children cannot take work details' end
    if safe(U.isChild, unit) then return 'child; children cannot take work details' end
    return nil
end

local function id_list(value, field)
    if value == nil then return {} end
    local message = ('"%s" must be a list of unit ids'):format(field)
    if type(value) ~= 'table' then return nil, message end
    local out = {}
    for _, raw in ipairs(value) do
        local id = tonumber(raw)
        if not id then return nil, message end
        table.insert(out, math.floor(id))
    end
    return out
end

local function can_recompute()
    return type(U.setAutomaticProfessions) == 'function'
end

local function recompute(unit)
    return pcall(U.setAutomaticProfessions, unit) == true
end

local function assign(args)
    local wd, index, err = resolve_detail(args.detail)
    if err then return err end
    local add, add_err = id_list(args.add, 'add')
    if not add then return rpc.error_result(rpc.ERR_BAD_REQUEST, add_err) end
    local remove, remove_err = id_list(args.remove, 'remove')
    if not remove then return rpc.error_result(rpc.ERR_BAD_REQUEST, remove_err) end
    if #add == 0 and #remove == 0 then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, 'give unit ids in "add", "remove", or both')
    end

    local added, removed, skipped = {}, {}, {}
    local touched, touched_order = {}, {}
    local function touch(unit)
        if not touched[unit.id] then
            touched[unit.id] = true
            table.insert(touched_order, unit)
        end
    end

    for _, id in ipairs(add) do
        local unit = df.unit.find(id)
        local reason = refusal(unit)
        if not reason and is_member(wd, id) then reason = 'already a member' end
        if reason then
            table.insert(skipped, {id = id, reason = reason})
        else
            utils.insert_sorted(wd.assigned_units, id)
            table.insert(added, {id = id, name = unit_name(unit)})
            touch(unit)
        end
    end
    -- Removal checks membership only: dead, departed, missing, and child units must be
    -- removable, since that is when a stale entry needs cleaning. A unit that no longer
    -- exists is just erased; one that exists is recomputed below.
    for _, id in ipairs(remove) do
        if not is_member(wd, id) then
            table.insert(skipped, {id = id, reason = 'not a member'})
        else
            local unit = df.unit.find(id)
            utils.erase_sorted(wd.assigned_units, id)
            table.insert(removed, {id = id, name = unit and unit_name(unit) or nil})
            if unit then touch(unit) end
        end
    end

    local recomputed = can_recompute()
    if recomputed then
        for _, unit in ipairs(touched_order) do
            if not recompute(unit) then recomputed = false end
        end
    end

    local labors_after = {}
    for n, unit in ipairs(touched_order) do
        if n > LABORS_AFTER_LIMIT then break end
        labors_after[tostring(unit.id)] = labor_names(function() return unit.status.labors end)
    end

    local mode = mode_word(wd)
    local notes = {}
    if mode == 'everybody' then
        table.insert(notes, 'This detail\'s mode is everybody, so every citizen does its labors '
            .. 'whatever the membership; set the mode to only_selected for membership to matter.')
    elseif mode == 'nobody' then
        table.insert(notes, 'This detail\'s mode is nobody, so no one does its labors, members '
            .. 'included; set the mode to only_selected for membership to matter.')
    end
    if not recomputed and #touched_order > 0 then
        table.insert(notes, 'Labors were not recomputed (setAutomaticProfessions is missing or '
            .. 'failed); the game applies the change when it next updates labors.')
    end
    if #touched_order > LABORS_AFTER_LIMIT then
        table.insert(notes, ('labors_after lists the first %d touched units only.')
            :format(LABORS_AFTER_LIMIT))
    end
    return {
        detail = {index = index, name = detail_name(wd), mode = mode},
        added = added,
        removed = removed,
        skipped = skipped,
        recomputed = recomputed,
        labors_after = labors_after,
        note = #notes > 0 and table.concat(notes, ' ') or nil,
    }
end

local function set_mode(args)
    local wd, index, err = resolve_detail(args.detail)
    if err then return err end
    local word = type(args.mode) == 'string' and args.mode:lower() or nil
    local enum_key = word and SETTABLE_MODES[word]
    if not enum_key then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"mode" must be one of everybody, nobody, only_selected')
    end
    if word == 'everybody' and safe(function() return wd.flags.cannot_be_everybody end) then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('%s cannot be everybody: its labor needs a tool (pick, axe, or crossbow) and the '
                .. 'game forbids giving it to every citizen; add the members you want with '
                .. 'assign_work_detail instead'):format(detail_name(wd)))
    end
    local before = mode_word(wd)
    wd.flags.mode = df.work_detail_mode[enum_key]
    -- VERIFY LIVE: the game's own Labor screen shows the new mode, and the citizens' labors
    -- follow it, after this write and the recompute below, with no further writes.
    local count, recomputed = 0, can_recompute()
    if recomputed then
        local citizens = safe(U.getCitizens, true) or {}
        for _, unit in ipairs(citizens) do
            if recompute(unit) then count = count + 1 else recomputed = false end
        end
    end
    local note
    if not recomputed then
        note = 'Not every citizen\'s labors were recomputed (setAutomaticProfessions is missing '
            .. 'or failed); the game applies the change when it next updates labors.'
    elseif word == 'only_selected' then
        note = 'Only the detail\'s members do its labors now; check them with '
            .. 'list_work_details.'
    end
    return {
        detail = {index = index, name = detail_name(wd), mode = mode_word(wd)},
        before = before,
        after = mode_word(wd),
        recomputed_citizens = count,
        note = note,
    }
end

function ops()
    return {
        ['labor.details'] = {namespace = 'units', handler = details, needs_map = true},
        ['labor.assign'] = {namespace = 'labor_write', handler = assign, needs_map = true},
        ['labor.set_mode'] = {namespace = 'labor_write', handler = set_mode, needs_map = true},
    }
end
