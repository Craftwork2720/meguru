--[[--
Running a sync without freezing the screen.

`Sync.run` walks a whole series feed in one call. On a Kindle that is tens of
seconds of a dead screen: KOReader's HTTP is synchronous and there is no thread
to walk on, so nothing repaints and no tap is ever delivered. This module drives
the walk itself instead — one page per `UIManager:nextTick`, with the dialog
repainted in between — which is the only reason a Cancel button here can do
anything at all.

A **silent** job paints nothing and cannot be cancelled: `opts.silent` is for a
walk the reader did not ask for and should not be interrupted by, started
because the alternative is a series the catalog only knows one book of. The tick
is not what draws the dialog, so the walk still yields — see `run`.

The work itself is not reimplemented: `Sync.prepare` builds the plan,
`Sync.walker` fetches one page per `step`, `Sync.finish` writes the result. This
file is entirely about the tick — and about the one guard that stops two walks
over the same series, which is here because this is the only module every UI
walker passes through.
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

local logger = require("logger")

local Sync = require("meguru/sync")

--- Series ids with a walk in flight, so one feed is never walked twice at once.
---
--- **Per series, not one flag.** Three callers reach this module — the reader's
--- own-menu neighbour request, the series view's manual row, and the background
--- walk `ui/open.lua` starts after an OPDS add — and a walk for one series has
--- no business refusing a request for another. (The reader used to keep its own
--- scalar guard; it was replaced by this, because two guards for one invariant
--- is how they drift.)
---
--- It is not redundant with `Sync.plan`'s TTL gate: `synced_at` is written when
--- a walk *ends*, so a second request arriving while the first is still running
--- finds the series looking exactly as stale as it did before, and would start a
--- second walk over the same feed.
---
--- Module-level state persists for the session, because plugin modules load once
--- per process.
local active = {}

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
--- Returns `true` when a walk was started, or `nil, "busy"` when one is already
--- running for this series. **A refusal, not a join**: joining would fire the
--- joiner's `on_done`, and on the reader's path that callback opens a document —
--- so the reader would be handed a book it had stopped waiting for. The caller
--- that wanted to know still gets `on_done(false, "busy")`.
---
--- `opts.silent` means **no UI at all**: no dialog, no Cancel, no repaint, no
--- failure popup. A silent walk is therefore uncancellable by construction, and
--- `is_cancelled` is not even passed to `Sync.prepare` — there is nothing that
--- could set the flag, and a flag that cannot be set is a promise this file
--- should not appear to make. The failure is still recorded on the series row
--- and named in the log; `Sync.finish` is where that line is.
---
--- What stops a silent walk is killing KOReader, and that is **safe**: nothing is
--- written until the last page, so an abandoned walk leaves the catalog exactly
--- as it was — no partial rows, no tombstones, no moved `synced_at`. It is also
--- why a silent walk must never be capped at fewer pages: an incomplete walk
--- records a failure and writes nothing, so a short one would repair nothing.
---
--- `opts.timeout` picks a `Net` preset for the walk (see `Sync.prepare`). A
--- silent caller wants the short one, so that a server hanging on every page
--- bounds a walk nobody can stop.
function SyncJob.run(server, series, on_done, opts)
    opts = opts or {}

    local id = series and series.id
    if not id then
        -- No row id means no `recordSyncFailure` and no `recordSyncSuccess`
        -- either, so there is nothing a walk could usefully leave behind. A
        -- separate reason from "busy" because the two need different fixes, and
        -- reporting a missing id as "already syncing" would send a reader
        -- looking for a walk that does not exist.
        logger.warn("Meguru: cannot sync a series with no id")
        if on_done then
            on_done(false, "no series")
        end
        return nil, "no series"
    end
    if active[id] then
        logger.dbg("Meguru: series", id, "is already syncing; request ignored")
        if on_done then
            on_done(false, "busy")
        end
        return nil, "busy"
    end
    active[id] = true

    -- Released before `on_done` on both exits, and that ordering is the point:
    -- `on_done` belongs to the caller, and on the reader's path it replaces the
    -- document. If it throws, the guard must already be down or this series can
    -- never be synced again in this session.
    local function release()
        active[id] = nil
    end

    local cancelled = false
    local dialog, status, button
    if not opts.silent then
        dialog, status, button = buildDialog(function()
            cancelled = true
            -- Say so rather than silently swallowing the tap: the current page's
            -- request still has to come back before the walk notices.
            button:setText(_("Cancelling…"))
            UIManager:setDirty(dialog, "ui")
        end)
    end

    -- Spelled out rather than folded: `cond and fn or nil` reads as if it
    -- guarded something, and is the shape this codebase has been bitten by.
    local is_cancelled = nil
    if not opts.silent then
        is_cancelled = function() return cancelled end
    end
    local plan, reason, summary = Sync.prepare(server, series, {
        is_cancelled = is_cancelled,
        timeout      = opts.timeout,
    })
    if not plan then
        release()
        -- **Logged whatever `opts.silent` says**, because silent suppresses the
        -- popup and not the record. `Sync.prepare`'s three refusals — an unknown
        -- server kind, a server that is not configured, no catalog feed for the
        -- series — write their reason to `series.sync_error` and return nil
        -- without logging anything, so before this line a background walk that
        -- could not start left no trace anywhere at all: not on screen, not in
        -- the log, only in a column nobody reads on a device. A diagnosis that
        -- cannot be made is the whole cost of a silent path, and this is the one
        -- line that pays it.
        logger.warn("Meguru: sync of", series.name, "cannot start (", reason, ")")
        if not opts.silent then
            report(series, false, reason)
        end
        if on_done then
            on_done(false, reason, summary)
        end
        return nil, reason
    end

    if dialog then
        UIManager:show(dialog)
    end
    local walker = Sync.walker(plan.url, plan.walker_opts)

    local function step()
        -- Everything below runs inside a UIManager tick, which pcalls what it
        -- calls and logs an exception rather than propagating it. So a throw
        -- anywhere in here — from the walker's HTTP, or from `Sync.finish`
        -- writing through `Store.transaction` — would end the walk *silently*
        -- and, worse, leave `active[id]` set for the rest of the session: that
        -- series could never be synced again, and nothing would say why.
        --
        -- Caught here rather than trusted, and logged loudly: a walk that dies
        -- without a word is the one outcome worth shouting about, and it is the
        -- likelier one for a job that paints nothing.
        local ok_step, more = pcall(walker.step, walker)
        if not ok_step then
            logger.err("Meguru: sync of", series.name, "stopped:", more)
            if dialog then
                UIManager:close(dialog)
            end
            release()
            if on_done then
                on_done(false, "the walk stopped unexpectedly")
            end
            return
        end

        if not more then
            if dialog then
                UIManager:close(dialog)
            end
            local ok_finish, ok, err, result = pcall(Sync.finish, series, walker, plan)
            if not ok_finish then
                logger.err("Meguru: sync of", series.name, "was not written:", ok)
                ok, err, result = false, "the walk could not be written"
            end
            release()
            if not opts.silent then
                report(series, ok, err)
            end
            if on_done then
                on_done(ok, err, result)
            end
            return
        end
        if dialog then
            status:setText(T(_("Meguru: syncing %1 — page %2"),
                series.name, walker.count))
            UIManager:setDirty(dialog, "ui")
        end
        -- Outside the dialog branch on purpose: the tick is the cooperation
        -- mechanism, not the repaint. A silent walk still yields one page at a
        -- time, so the reader keeps turning pages while it runs.
        UIManager:nextTick(step)
    end

    UIManager:nextTick(step)
    return true
end

return SyncJob
