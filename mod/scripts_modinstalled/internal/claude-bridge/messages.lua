-- Messages from Claude to the player as in-game announcements (plan section 13, item
-- 14.2). dfhack.gui.makeAnnouncement with D_DISPLAY puts the text in the announcement log
-- and the left-side alert stack under the badge of the announcement type's category
-- (checked 2026-10-15 against Gui.cpp on master); the icon is the game's own for that
-- category, since nothing on a report can carry a custom one (rule 13 forbids touching the
-- texture side). Light red is the Steam palette's closest colour to orange.
--@ module = true

local rpc = reqscript('internal/claude-bridge/rpc')

MAX_CHARS = 200
DEFAULT_BADGE = 'rumor'

-- Badge name -> an announcement type of that alert category (df.g_src.basics.xml, master).
BADGES = {
    general = 'REACHED_PEAK',
    rumor = 'RUMOR_SPREAD',
    research = 'RESEARCH_BREAKTHROUGH',
    guest = 'GUEST_ARRIVAL',
    masterpiece = 'MASTERPIECE_CRAFTED',
    noble = 'NOBLE_ARRIVAL',
    era = 'ERA_CHANGE',
    holdings = 'NEW_HOLDING',
    deity = 'DEITY_CURSE',
    agreement = 'PARTY_ORGANIZED',
}

local function safe(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

local function badge_names()
    local out = {}
    for k in pairs(BADGES) do table.insert(out, k) end
    table.sort(out)
    return out
end

local function say(args)
    local text = args.text
    if type(text) ~= 'string' then
        return rpc.error_result(rpc.ERR_BAD_REQUEST, '"text" must be a string')
    end
    text = text:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if text == '' then return rpc.error_result(rpc.ERR_BAD_REQUEST, '"text" must not be empty') end
    local length = safe(function() return utf8.len(text) end) or #text
    if length > MAX_CHARS then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            ('messages are capped at %d characters; this one is %d'):format(MAX_CHARS, length))
    end
    local badge = args.badge ~= nil and tostring(args.badge):lower() or DEFAULT_BADGE
    local type_name = BADGES[badge]
    if not type_name then
        return rpc.error_result(rpc.ERR_BAD_REQUEST,
            '"badge" must be one of ' .. table.concat(badge_names(), ', '))
    end
    local announcement = safe(function() return df.announcement_type[type_name] end)
    if type(announcement) ~= 'number' then
        return rpc.error_result(rpc.ERR_INTERNAL, 'this build has no announcement type ' .. type_name)
    end
    local pos = xyz2pos(-30000, -30000, -30000)
    local zoom = nil
    if args.x ~= nil or args.y ~= nil or args.z ~= nil then
        local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
        if not (x and y and z) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'give "x", "y", and "z" together, or none')
        end
        zoom = {x = math.floor(x), y = math.floor(y), z = math.floor(z)}
        if not dfhack.maps.isValidTilePos(zoom) then
            return rpc.error_result(rpc.ERR_BAD_REQUEST, 'the position is outside the map')
        end
        pos = xyz2pos(zoom.x, zoom.y, zoom.z)
    end
    -- makeAnnouncement wants a real announcement_flags object, not a table.
    local flags = df.announcement_flags:new()
    flags.D_DISPLAY = true
    flags.A_DISPLAY = true
    local ok, index = pcall(dfhack.gui.makeAnnouncement, announcement, flags, pos, dfhack.utf2df(text),
                            COLOR_RED, true)
    flags:delete()
    if not ok then return rpc.error_result(rpc.ERR_INTERNAL, tostring(index)) end
    if index == nil or index < 0 then
        return rpc.error_result(rpc.ERR_INTERNAL, 'the game refused the announcement')
    end
    local report_id = nil
    pcall(function()
        local report = df.global.world.status.reports[index]
        report_id = report.id
        if zoom then report.zoom_type = df.report_zoom_type.Generic end
    end)
    return {
        text = text, badge = badge, announcement_type = type_name, pos = zoom,
        report_id = report_id, index = index,
        note = zoom and 'shown in the announcement log and the left-side alerts; clicking the alert zooms to the position'
            or 'shown in the announcement log and the left-side alerts',
    }
end

local function badges(args)
    local out = {}
    for _, name in ipairs(badge_names()) do
        table.insert(out, {badge = name, announcement_type = BADGES[name]})
    end
    return {badges = out, default = DEFAULT_BADGE, max_chars = MAX_CHARS}
end

function ops()
    return {
        ['messages.say'] = {namespace = 'messages', handler = say, needs_map = true},
        ['messages.badges'] = {namespace = 'messages', handler = badges},
    }
end
