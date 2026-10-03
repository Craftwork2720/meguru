--[[--
The book's own facts, in a popup the bottom menu opens.

The fourth icon in the bottom `ConfigDialog` shows this instead of a panel: what
page the reader is on, how far through the book that is, and what the book says
about itself. It is the one surface here that answers "where am I" — the status
bar can be hidden, and a streamed page carries no printed number to read one off.

**It is handed a plain table and owns presentation only.** `Reader.infoFields`
does the gathering, because the page on screen has exactly one answer in this
plugin — `ui/reader`'s own `currentPage` — and a second reader of `ui.paging`
here would be a second answer that could drift from the first. So this module
requires no `meguru/` module at all, never sees a `ui` or a `doc`, and cannot ask
a question of its own.

**Nothing is written and nothing is fetched.** No sidecar key, no marker field,
no request: this is a view of facts that are already in RAM.

**It closes when tapped beside, and that is `ButtonDialog`'s own behaviour** —
its `TapClose` gesture covers the screen and closes only when the tap falls
outside the movable frame — so there is no dismiss handler here to keep in step
with the widget, and nothing that has to be persisted on the way out. The dialog
is shown *over* the bottom menu rather than after closing it, so dismissing the
popup puts the reader back on the tab they opened it from. The popup consumes
every tap while it is up, which is also why the icon cannot open a second one.
--]]

local ButtonDialog   = require("ui/widget/buttondialog")
local Font           = require("ui/font")
local ProgressWidget = require("ui/widget/progresswidget")
local Screen         = require("device").screen
local Size           = require("ui/size")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local _              = require("gettext")
local T              = require("ffi/util").template

local Info = {}

--- How much of a ComicInfo summary the popup will carry, in bytes.
---
--- A cap rather than a scroller, and the reason is structural: `ButtonDialog`
--- wraps its *button table* in a `ScrollableContainer` when it overflows, never
--- its title group — which is where an added widget lives — so an unbounded body
--- would push the Close button off the bottom of the screen rather than scroll.
--- The summary is the only free text here, and so the only thing that can run
--- long: every other row is a name.
local SUMMARY_LIMIT = 300

--- The `Page N of M` line, or nil when the page is not known.
---
--- A count that is not there is dropped rather than filled in: `Page 12` is true
--- on its own, where `Page 12 of 0` or a total this module made up would not be.
local function pageLine(page, total)
    if not page then
        return nil
    end
    if total then
        return T(_("Page %1 of %2"), page, total)
    end
    return T(_("Page %1"), page)
end

--- A value as one line, or nil when there is nothing to say.
---
--- **Whitespace is what makes this more than a type check**, and the failure it
--- prevents is a row that draws as a label with nothing after it. A series name
--- is a server's own `<title>`, and nothing between that element and here trims
--- one: `Base.stripSuffix` only cuts a suffix off the end, and
--- `Naming.stripSeriesLabel` looks at a *trimmed copy* to decide whether it is
--- looking at a "Label:" prefix and then hands the original back — so a padded
--- title arrives with its padding, and a title that is nothing but padding
--- arrives as a non-empty string that draws as an empty line. Trimming it here
--- is the same judgement `open.lua` makes about a series named `""`, at the one
--- boundary where a name becomes something a reader looks at.
---
--- Runs collapse as well: this block is one `TextBoxWidget` and its line breaks
--- are the ones in the text, so a name carrying a newline would break its row in
--- two.
local function plainText(value)
    if type(value) == "number" then
        value = tostring(value)
    end
    if type(value) ~= "string" then
        return nil
    end
    value = value:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return value ~= "" and value or nil
end

--- One `Label: value` row, or nil when there is nothing to say.
---
--- Nil is the ordinary answer for most of these — a streamed book has no author
--- to show, a local one has no server — and the caller drops the nil rather than
--- printing an empty row or an em dash, so a book shows the rows it can answer
--- and no others.
local function metaLine(label, value)
    local text = plainText(value)
    if not text then
        return nil
    end
    return T(_("%1: %2"), label, text)
end

--- The metadata rows, in the order they are read.
local function metaLines(fields)
    local lines = {}
    local function add(label, value)
        local text = metaLine(label, value)
        if text then
            lines[#lines + 1] = text
        end
    end
    add(_("Series"), fields.series)
    add(_("Volume"), fields.volume)
    add(_("Author"), fields.authors)
    add(_("Language"), fields.language)
    add(_("Server"), fields.server)

    -- The same collapsing as every row above, for the same reason: a ComicInfo
    -- summary is HTML-ish free text with newlines and runs of spaces in it, and
    -- a popup is not the place to honour either.
    local summary = plainText(fields.description)
    if summary then
        if #summary > SUMMARY_LIMIT then
            summary = summary:sub(1, SUMMARY_LIMIT)
            -- Cut on a character boundary: the tail of a UTF-8 sequence is a
            -- byte in 0x80..0xBF, and half a character is what a rasteriser is
            -- entitled to draw as anything at all.
            while #summary > 0 do
                local byte = summary:byte(-1)
                if byte < 128 or byte >= 192 then
                    break
                end
                summary = summary:sub(1, -2)
            end
            summary = summary .. "…"
        end
        lines[#lines + 1] = summary
    end
    return lines
end

--- The popup, or nil when there is nothing to show one for.
function Info.show(fields)
    if type(fields) ~= "table" then
        return nil
    end

    local page, total = tonumber(fields.page), tonumber(fields.total)
    if page then
        page = math.floor(page)
    end
    if total then
        total = math.floor(total)
    end
    -- Both numbers, and a count that is not zero: the bar and the percentage
    -- below have nothing to say without them, and the page line says what it can
    -- on its own.
    local measured = page and total and total > 0
    local percent = measured and math.min(1, math.max(0, page / total)) or 0

    local dialog
    dialog = ButtonDialog:new{
        -- The book's own name. A title the plugin could not derive at all is the
        -- one case where the header says what the popup is rather than what the
        -- book is.
        title = (type(fields.title) == "string" and fields.title ~= "")
            and fields.title or _("Book info"),
        buttons = {
            {
                {
                    text = _("Close"),
                    callback = function() UIManager:close(dialog) end,
                },
            },
        },
    }

    -- Read off the dialog rather than computed here: the width a title-group
    -- widget may use is the dialog's own answer, and it is the same one its
    -- title is wrapped to.
    local width = dialog:getAddedWidgetAvailableWidth()
    local body = VerticalGroup:new{ align = "left" }

    local current_line = pageLine(page, total)
    if current_line then
        table.insert(body, TextBoxWidget:new{
            text = current_line,
            width = width,
            face = Font:getFace("infofont"),
            alignment = "center",
        })
    end

    -- Without both numbers there is no bar at all, rather than an empty one
    -- reading "0 %" — which would be this popup inventing a position for a book
    -- it cannot place. The metadata rows below stand perfectly well without it.
    if measured then
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, ProgressWidget:new{
            width = width,
            height = Screen:scaleBySize(10),
            percentage = percent,
        })
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, TextBoxWidget:new{
            -- The bar is the answer and this is the number under it.
            text = T(_("%1 %"), math.floor(percent * 100 + 0.5)),
            width = width,
            face = Font:getFace("smallinfofont"),
            alignment = "center",
        })
    end

    local lines = metaLines(fields)
    if #lines > 0 then
        table.insert(body, VerticalSpan:new{ width = Size.padding.default })
        table.insert(body, TextBoxWidget:new{
            text = table.concat(lines, "\n"),
            width = width,
            face = Font:getFace("smallinfofont"),
        })
    end

    -- **`parent` is load-bearing and `not_focusable` is not ceremony.**
    -- `addWidget` below re-inits the dialog, and `reinit` protects what was
    -- already added by removing title-group children that carry a `parent` —
    -- which is a field `addWidget` does not set. Without it a second `reinit`
    -- (a `setTitle`, a caller that adds a widget of its own) would free this
    -- group and then re-insert the freed object. `not_focusable` keeps it out of
    -- the dialog's focus layout, which is the buttons' — a group of text is not
    -- something a D-pad should be able to land on.
    body.parent = dialog
    body.not_focusable = true
    dialog:addWidget(body)

    UIManager:show(dialog)
    return dialog
end

return Info
