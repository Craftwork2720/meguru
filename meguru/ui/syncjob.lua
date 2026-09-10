--[[--
Running a sync without freezing the screen.

`Sync.run` walks a whole series feed in one call. On a Kindle that is tens of
seconds of a dead screen: KOReader's HTTP is synchronous and there is no thread
to walk on, so nothing repaints and no tap is ever delivered. This module drives
the walk itself instead — one page per `UIManager:nextTick`, with the dialog
repainted in between — which is the only reason a Cancel button here can do
anything at all.

The work itself is not reimplemented: `Sync.prepare` builds the plan,
`Sync.walker` fetches one page per `step`, `Sync.finish` writes the result. This
file is entirely about the tick.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Screen = require("device").screen
local _ = require("gettext")
local T = require("ffi/util").template

local Sync = require("meguru/sync")

local SyncJob = {}

--- The progress dialog. Returns `dialog, status, button`.
---
--- The status line is one truncated line, deliberately: `TextWidget:setText`
--- re-measures, and a label that wrapped to two lines on a long series name
--- would resize the frame under the reader's finger every few pages. The walk
--- has no known page total, so there is no progress bar to draw — a percentage
--- here would be invented.
---
--- `face` is not optional and has no default. `TextWidget` defines no `init`,
--- so nothing ever turns a font *name* into a face — it takes a resolved
--- `FontFaceObj` and uses it directly, and `Font:getAdjustedFace(nil)` dies on
--- `face.is_real_bold` the first time the widget is measured. Passing no face
--- therefore crash-loops the whole reader the moment this dialog is painted.
--- `"infofont"` is the size `InfoMessage` uses for body text; the sibling
--- `Button` supplies its own default face, which is why only this one crashed.
local function buildDialog(on_cancel)
    local width = math.floor(Screen:getWidth() * 0.9)
    local status = TextWidget:new{
        text = "",
        face = Font:getFace("infofont"),
        max_width = width - 4 * Size.padding.default,
    }
    local button = Button:new{
        text = _("Cancel"),
        callback = on_cancel,
    }
    local frame = FrameContainer:new{
        padding = Size.padding.default,
        margin = Size.margin.default,
        -- A Blitbuffer colour, not its name. The frame tests
        -- `Blitbuffer.isColor8(self.background)` to choose a painter, so a plain
        -- `"white"` string falls through to the RGB32 painter, which calls
        -- `background:getColorRGB32()` — a method strings do not have.
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            status,
            button,
        },
    }
    -- Sized by the CenterContainer's `dimen`, which is what `WidgetContainer`
    -- actually reads: `InputContainer:new{ width = …, height = … }` looks like it
    -- sizes the dialog and does not, so those two fields are left off rather than
    -- sitting here inviting someone to adjust them.
    local dialog = InputContainer:new{
        CenterContainer:new{
            dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
            frame,
        },
    }
    return dialog, status, button
end

--- Report the outcome. Only failures are announced: a success is visible in the
--- refreshed list behind the dialog, and a popup saying "done" on every series
--- would be a second thing to dismiss.
local function report(series, ok, reason)
    if ok then
        return
    end
    local text
    if reason == "cancelled" then
        text = T(_("Meguru: sync of %1 cancelled."), series.name)
    else
        text = T(_("Meguru: could not sync %1.\n%2"), series.name, tostring(reason))
    end
    UIManager:show(InfoMessage:new{ text = text })
end

--- Sync one series, cooperatively.
---
--- `on_done(ok, reason)` runs on the tick after the walk ends, with the dialog
--- already closed — so a caller that wants to rebuild its list does so against
--- a database that has already been written to.
---
--- `opts.silent` skips the failure popup, for a lazy background sync where the
--- user did not ask and does not want to be interrupted.
function SyncJob.run(server, series, on_done, opts)
    opts = opts or {}
    local cancelled = false

    local dialog, status, button
    dialog, status, button = buildDialog(function()
        cancelled = true
        -- Say so rather than silently swallowing the tap: the current page's
        -- request still has to come back before the walk notices.
        button:setText(_("Cancelling…"))
        UIManager:setDirty(dialog, "ui")
    end)

    local plan, reason, summary = Sync.prepare(server, series, {
        is_cancelled = function() return cancelled end,
    })
    if not plan then
        if not opts.silent then
            report(series, false, reason)
        end
        if on_done then
            on_done(false, reason, summary)
        end
        return
    end

    UIManager:show(dialog)
    local walker = Sync.walker(plan.url, plan.walker_opts)

    local function step()
        if not walker:step() then
            UIManager:close(dialog)
            local ok, err, result = Sync.finish(series, walker, plan)
            if not opts.silent then
                report(series, ok, err)
            end
            if on_done then
                on_done(ok, err, result)
            end
            return
        end
        status:setText(T(_("Meguru: syncing %1 — page %2"),
            series.name, walker.count))
        UIManager:setDirty(dialog, "ui")
        UIManager:nextTick(step)
    end

    UIManager:nextTick(step)
end

return SyncJob
