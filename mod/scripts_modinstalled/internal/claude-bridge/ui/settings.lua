-- Settings window: tabs for permissions, the console allowlist, event kinds, and the
-- prompt timer. Lists scroll and toggle with Enter or a click; no per-row hotkeys.
--@ module = true

local gui = require('gui')
local widgets = require('gui.widgets')
local state = reqscript('internal/claude-bridge/state')
local events = reqscript('internal/claude-bridge/events')
local timer = reqscript('internal/claude-bridge/timer')

local TABS = {'Permissions', 'Console', 'Events', 'Timer'}

local function to_cp437(text)
    return (text:gsub('[^%c]+', dfhack.utf2df))
end

local function to_utf8(text)
    return (text:gsub('[^%c]+', dfhack.df2utf))
end

local function checkbox(on)
    return {text = on and '[x] ' or '[ ] ', pen = on and COLOR_LIGHTGREEN or COLOR_GREY}
end

----------------------------------------------------------------------------------------------
-- Permissions page: a scrolling list of every namespace, grouped.

PermissionsPage = defclass(PermissionsPage, widgets.Panel)

function PermissionsPage:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = 'What Claude is allowed to do (Enter or click toggles):',
        },
        widgets.List{
            view_id = 'perms',
            frame = {t = 2, l = 1, r = 0, b = 1},
            choices = self:choices(),
            on_submit = function(_, choice)
                if choice and choice.key then
                    state.set_permission(choice.key, not state.is_allowed(choice.key))
                    self:refresh()
                end
            end,
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = {{text = 'Off-by-default rows are writes; reads are on by default.', pen = COLOR_GREY}},
        },
    }
end

function PermissionsPage:choices()
    local choices = {}
    for _, group in ipairs(state.GROUPS) do
        table.insert(choices, {text = {{text = group, pen = COLOR_LIGHTCYAN}}})
        for _, ns in ipairs(state.namespaces_in(group)) do
            table.insert(choices, {
                key = ns.key,
                text = {{text = '  '}, checkbox(state.is_allowed(ns.key)), {text = ns.label}},
            })
        end
    end
    return choices
end

function PermissionsPage:refresh()
    local list = self.subviews.perms
    local selected = list:getSelected()
    list:setChoices(self:choices(), selected)
end

----------------------------------------------------------------------------------------------
-- Console page: the allowlist

ConsolePage = defclass(ConsolePage, widgets.Panel)

function ConsolePage:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = 'Console commands Claude may run:',
        },
        widgets.List{
            view_id = 'allowlist',
            frame = {t = 2, l = 1, r = 0, b = 4},
            choices = self:allow_choices(),
        },
        widgets.EditField{
            view_id = 'new_command',
            frame = {b = 2, l = 1},
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
        },
        widgets.HotkeyLabel{
            frame = {b = 0, l = 1},
            key = 'CUSTOM_D',
            label = 'Remove selected command',
            on_activate = function()
                local _, choice = self.subviews.allowlist:getSelected()
                if choice and choice.command then
                    state.deny_console(choice.command)
                    self:refresh_allowlist()
                end
            end,
        },
    }
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
-- Events page: one row per event kind

EventsPage = defclass(EventsPage, widgets.Panel)

function EventsPage:init()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = 'Events sent to Claude (Enter or click toggles):',
        },
        widgets.List{
            view_id = 'kinds',
            frame = {t = 2, l = 1, r = 0, b = 3},
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
            text = {{text = 'Goals and the goal prompt: claude-bridge goals. Events permission: first tab.',
                     pen = COLOR_GREY}},
        },
    }
end

function EventsPage:kind_choices()
    local choices = {}
    for _, k in ipairs(events.KINDS) do
        table.insert(choices, {key = k.key, text = {checkbox(state.is_event_enabled(k.key)), {text = k.label}}})
    end
    return choices
end

function EventsPage:refresh()
    local list = self.subviews.kinds
    local selected = list:getSelected()
    list:setChoices(self:kind_choices(), selected)
end

----------------------------------------------------------------------------------------------
-- Timer page: the prompt timer (Phase 15). Controls follow the live settings, so a change
-- made from the console shows here and a stale field never writes an old value back.

TimerPage = defclass(TimerPage, widgets.Panel)

function TimerPage:init()
    local s = timer.settings()
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = {{text = 'Prompt timer: Claude is prompted on its own after a span of time.',
                     pen = COLOR_LIGHTCYAN}},
        },
        widgets.ToggleHotkeyLabel{
            view_id = 'enabled',
            frame = {t = 2, l = 1},
            key = 'CUSTOM_E',
            label = 'Timer',
            initial_option = s.enabled,
            on_change = function(value) timer.configure({enabled = value}) end,
        },
        widgets.CycleHotkeyLabel{
            view_id = 'mode',
            frame = {t = 3, l = 1},
            key = 'CUSTOM_M',
            label = 'Fire every',
            options = {
                {label = 'N in-game days', value = 'days'},
                {label = 'change of month', value = 'month'},
                {label = 'N real minutes (while unpaused)', value = 'minutes'},
            },
            initial_option = s.mode,
            on_change = function(value) timer.configure({mode = value}) end,
        },
        widgets.EditField{
            view_id = 'interval',
            frame = {t = 4, l = 1, w = 30},
            key = 'CUSTOM_I',
            label_text = 'N = ',
            text = tostring(s.interval),
            on_char = function(ch) return ch:match('%d') ~= nil end,
            on_change = function(text)
                local n = tonumber(text)
                if n and n >= 1 then timer.configure({interval = n}) end
            end,
        },
        widgets.Label{
            frame = {t = 4, l = 32},
            text = {{text = function()
                local cur = timer.settings()
                return cur.mode == 'month' and '(N is not used for month)' or ('current: ' .. cur.interval)
            end, pen = COLOR_GREY}},
        },
        widgets.Label{
            frame = {t = 6, l = 0},
            text = {{text = 'Prompt sent when the timer fires:', pen = COLOR_LIGHTCYAN}},
        },
        widgets.TextArea{
            view_id = 'prompt',
            frame = {t = 7, l = 0, r = 0, b = 4},
            init_text = to_cp437(s.prompt),
            on_text_change = function(text)
                timer.configure({prompt = to_utf8(text)})
            end,
        },
        widgets.HotkeyLabel{
            frame = {b = 2, l = 1},
            key = 'CUSTOM_R',
            label = 'Reset prompt to default',
            on_activate = function()
                timer.configure({prompt = timer.DEFAULT_PROMPT})
                self.subviews.prompt:setText(to_cp437(timer.DEFAULT_PROMPT))
            end,
        },
        widgets.Label{
            frame = {b = 1, l = 0},
            text = {{text = function()
                local p = timer.progress()
                if not p.armed then return 'timer not armed' end
                if p.mode == 'days' then return ('%.1f of %d days passed'):format(p.elapsed_days, p.interval) end
                if p.mode == 'month' then return 'waiting for the month to change' end
                return ('%.1f of %d minutes passed'):format(p.elapsed_minutes, p.interval)
            end, pen = COLOR_GREY}},
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = {{text = 'Resets whenever events go to Claude; frozen while paused; never stacks.',
                     pen = COLOR_GREY}},
        },
    }
end

-- Keep the controls in step with settings changed elsewhere (console, another window).
function TimerPage:onRenderBody(dc)
    local s = timer.settings()
    local enabled = self.subviews.enabled
    if enabled:getOptionValue() ~= s.enabled then enabled:setOption(s.enabled) end
    local mode = self.subviews.mode
    if mode:getOptionValue() ~= s.mode then mode:setOption(s.mode) end
    local field = self.subviews.interval
    if not field.focus and field.text ~= tostring(s.interval) then
        field:setText(tostring(s.interval))
    end
    TimerPage.super.onRenderBody(self, dc)
end

----------------------------------------------------------------------------------------------
-- Window and screen

SettingsWindow = defclass(SettingsWindow, widgets.Window)
SettingsWindow.ATTRS{
    frame_title = 'Claude Bridge settings',
    frame = {w = 64, h = 34},
    resizable = true,
    resize_min = {w = 44, h = 18},
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
                TimerPage{view_id = 'timer'},
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
