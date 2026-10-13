-- Settings window: permission toggles and the console allowlist.
--@ module = true

local gui = require('gui')
local widgets = require('gui.widgets')
local state = reqscript('internal/claude-bridge/state')

SettingsWindow = defclass(SettingsWindow, widgets.Window)
SettingsWindow.ATTRS{
    frame_title = 'Claude Bridge settings',
    frame = {w = 58, h = 41},
    resizable = true,
    resize_min = {w = 44, h = 18},
}

function SettingsWindow:init()
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

    y = y + 1
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

function SettingsWindow:allow_choices()
    local choices = {}
    for _, cmd in ipairs(state.get_settings().console_allow) do
        table.insert(choices, {text = cmd, command = cmd})
    end
    if #choices == 0 then
        table.insert(choices, {text = '(none; console access is denied)'})
    end
    return choices
end

function SettingsWindow:refresh_allowlist()
    self.subviews.allowlist:setChoices(self:allow_choices())
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
