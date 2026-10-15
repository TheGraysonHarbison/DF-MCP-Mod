-- Settings window: tabs for permissions (with the console allowlist) and event kinds.
--@ module = true

local gui = require('gui')
local widgets = require('gui.widgets')
local state = reqscript('internal/claude-bridge/state')
local events = reqscript('internal/claude-bridge/events')

local TABS = {'Permissions', 'Console', 'Events'}

----------------------------------------------------------------------------------------------
-- Permissions page

PermissionsPage = defclass(PermissionsPage, widgets.Panel)

function PermissionsPage:init()
    local s = state.get_settings()
    local views = {}
    local y = 0

    table.insert(views, widgets.Label{
        frame = {t = y, l = 0},
        text = 'What Claude is allowed to do:',
    })
    y = y + 1

    for _, group in ipairs(state.GROUPS) do
        table.insert(views, widgets.Label{
            frame = {t = y, l = 1},
            text = {{text = group, pen = COLOR_LIGHTCYAN}},
        })
        y = y + 1
        for _, ns in ipairs(state.namespaces_in(group)) do
            table.insert(views, widgets.ToggleHotkeyLabel{
                view_id = 'perm_' .. ns.key,
                frame = {t = y, l = 3},
                key = ns.hotkey,
                label = ns.label,
                initial_option = s.permissions[ns.key] == true,
                on_change = function(value)
                    state.set_permission(ns.key, value)
                end,
            })
            y = y + 1
        end
    end

    self:addviews(views)
end

----------------------------------------------------------------------------------------------
-- Console page: the allowlist

ConsolePage = defclass(ConsolePage, widgets.Panel)

function ConsolePage:init()
    local views = {}
    local y = 0
    table.insert(views, widgets.Label{
        frame = {t = y, l = 0},
        text = 'Console commands Claude may run:',
    })
    y = y + 1
    table.insert(views, widgets.List{
        view_id = 'allowlist',
        frame = {t = y, l = 1, h = 6},
        choices = self:allow_choices(),
    })
    y = y + 6
    table.insert(views, widgets.EditField{
        view_id = 'new_command',
        frame = {t = y, l = 1},
        key = 'CUSTOM_A',
        label_text = 'Add command: ',
        on_submit = function(text)
            text = text:match('^%s*(%S+)')
            if text then
                state.allow_console(text)
                self:refresh_allowlist()
            end
            self.subviews.new_command:setText('')
        end,
    })
    y = y + 1
    table.insert(views, widgets.HotkeyLabel{
        frame = {t = y, l = 1},
        key = 'CUSTOM_D',
        label = 'Remove selected command',
        on_activate = function()
            local _, choice = self.subviews.allowlist:getSelected()
            if choice and choice.command then
                state.deny_console(choice.command)
                self:refresh_allowlist()
            end
        end,
    })

    self:addviews(views)
end

function ConsolePage:allow_choices()
    local choices = {}
    for _, cmd in ipairs(state.get_settings().console_allow) do
        table.insert(choices, {text = cmd, command = cmd})
    end
    if #choices == 0 then
        table.insert(choices, {text = '(none; console access is denied)'})
    end
    return choices
end

function ConsolePage:refresh_allowlist()
    self.subviews.allowlist:setChoices(self:allow_choices())
end

----------------------------------------------------------------------------------------------
-- Events page: one row per event kind, Enter (or click) toggles it.

EventsPage = defclass(EventsPage, widgets.Panel)

function EventsPage:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = 'Events sent to Claude (Enter toggles):',
        },
        widgets.List{
            view_id = 'kinds',
            frame = {t = 2, l = 1, b = 3},
            choices = self:kind_choices(),
            on_submit = function(_, choice)
                if choice and choice.key then
                    state.set_event_enabled(choice.key, not state.is_event_enabled(choice.key))
                    self:refresh()
                end
            end,
        },
        widgets.Label{
            frame = {b = 1, l = 0},
            text = {{text = 'Events are batched: two quiet seconds or 50 events make one message.',
                     pen = COLOR_GREY}},
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = {{text = 'The "Send in-game events" permission on the first tab must be on.',
                     pen = COLOR_GREY}},
        },
    }
end

function EventsPage:kind_choices()
    local choices = {}
    for _, k in ipairs(events.KINDS) do
        local on = state.is_event_enabled(k.key)
        table.insert(choices, {
            key = k.key,
            text = {
                {text = on and '[x] ' or '[ ] ', pen = on and COLOR_LIGHTGREEN or COLOR_GREY},
                {text = k.label},
            },
        })
    end
    return choices
end

function EventsPage:refresh()
    local list = self.subviews.kinds
    local selected = list:getSelected()
    list:setChoices(self:kind_choices(), selected)
end

----------------------------------------------------------------------------------------------
-- Window and screen

SettingsWindow = defclass(SettingsWindow, widgets.Window)
SettingsWindow.ATTRS{
    frame_title = 'Claude Bridge settings',
    frame = {w = 60, h = 38},
    resizable = true,
    resize_min = {w = 44, h = 20},
}

function SettingsWindow:init()
    self:addviews{
        widgets.TabBar{
            frame = {t = 0, l = 0},
            labels = TABS,
            on_select = function(idx) self.subviews.pages:setSelected(idx) end,
            get_cur_page = function() return self.subviews.pages:getSelected() end,
        },
        widgets.Pages{
            view_id = 'pages',
            frame = {t = 3, l = 0, b = 0, r = 0},
            subviews = {
                PermissionsPage{view_id = 'permissions'},
                ConsolePage{view_id = 'console'},
                EventsPage{view_id = 'events'},
            },
        },
    }
end

SettingsScreen = defclass(SettingsScreen, gui.ZScreen)
SettingsScreen.ATTRS{
    focus_path = 'claude-bridge/settings',
}

function SettingsScreen:init()
    self:addviews{SettingsWindow{}}
end

function SettingsScreen:onDismiss()
    view = nil
end

view = view or nil

function show()
    view = view and view:raise() or SettingsScreen{}:show()
    return view
end
