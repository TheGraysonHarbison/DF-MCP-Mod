-- Goals window: the player's goals for this fort and the prompt that carries them to
-- Claude. Both are saved on every change; nothing is sent until the Send hotkey.
--@ module = true

local gui = require('gui')
local widgets = require('gui.widgets')
local state = reqscript('internal/claude-bridge/state')
local plan = reqscript('internal/claude-bridge/plan')

GoalsWindow = defclass(GoalsWindow, widgets.Window)
GoalsWindow.ATTRS{
    frame_title = 'Goals for Claude',
    frame = {w = 70, h = 40},
    resizable = true,
    resize_min = {w = 50, h = 24},
}

function GoalsWindow:init()
    self.status = ''
    self:addviews{
        widgets.Label{
            frame = {t = 0, l = 0},
            text = {{text = 'Goals (saved as you type, sent only with the hotkey):', pen = COLOR_LIGHTCYAN}},
        },
        widgets.TextArea{
            view_id = 'goals',
            frame = {t = 1, l = 0, r = 0, h = 16},
            -- The file is UTF-8, the screen is CP437.
            init_text = plan.to_cp437(plan.load_goals()),
            on_text_change = function(text)
                plan.save_goals(plan.to_utf8(text))
            end,
        },
        widgets.Label{
            frame = {t = 18, l = 0},
            text = {{text = 'Prompt sent with the goals ({Put Goals Here} is replaced):', pen = COLOR_LIGHTCYAN}},
        },
        widgets.TextArea{
            view_id = 'prompt',
            frame = {t = 19, l = 0, r = 0, b = 4},
            init_text = plan.to_cp437(state.get_goal_prompt()),
            on_text_change = function(text)
                state.set_goal_prompt(plan.to_utf8(text))
            end,
        },
        widgets.HotkeyLabel{
            frame = {b = 2, l = 0},
            key = 'CUSTOM_CTRL_S',
            label = 'Send goals to Claude',
            on_activate = self:callback('send'),
        },
        widgets.HotkeyLabel{
            frame = {b = 2, l = 32},
            key = 'CUSTOM_CTRL_R',
            label = 'Reset prompt to default',
            on_activate = function()
                state.set_goal_prompt(plan.DEFAULT_GOAL_PROMPT)
                self.subviews.prompt:setText(plan.to_cp437(plan.DEFAULT_GOAL_PROMPT))
                self.status = 'prompt reset'
            end,
        },
        widgets.Label{
            frame = {b = 0, l = 0},
            text = {{text = function() return self.status end, pen = COLOR_GREY}},
        },
    }
end

function GoalsWindow:send()
    local entry = plan.send_goals()
    if entry then
        self.status = ('sent as event %d; Claude reads it when idle'):format(entry.seq)
    else
        self.status = 'could not queue the goals (is the bridge enabled?)'
    end
end

GoalsScreen = defclass(GoalsScreen, gui.ZScreen)
GoalsScreen.ATTRS{
    focus_path = 'claude-bridge/goals',
    pass_pause = false,
}

function GoalsScreen:init()
    self:addviews{GoalsWindow{}}
end

function GoalsScreen:onDismiss()
    view = nil
end

view = view or nil

function show()
    view = view and view:raise() or GoalsScreen{}:show()
    return view
end
