--[[--
Plugin-wide preferences, stored in KOReader's global `G_reader_settings` under
`meguru_`-prefixed keys.

Per-book options are *not* here — they live in each book's DocSettings sidecar,
the way KOReader keeps `kopt_*` for a PDF. Nothing here may ever write a global
`kopt_*`.
--]]

local logger = require("logger")

local Settings = {}

-- Sentinel for "this preference is unset by default". A plain `nil` default
-- would not survive the table literal (Lua drops keys assigned nil), which
-- would make the known-key check below silently wrong.
local UNSET = {}
Settings.UNSET = UNSET

local DEFAULTS = {
    marker_dir        = UNSET,        -- base folder for new markers; unset => home folder

    -- Nest new markers under a folder named after the catalog they came from
    -- (`<base>/<server>/<series>`).
    --
    -- On by default: a library built from more than one server otherwise gets two
    -- `Kavita` folders and two `Suwayomi` ones in the same series name, and the
    -- collision is only visible once both are on disk. It is a rule for where a
    -- marker is *written* and nothing else — a folder already holding markers is
    -- never moved by it, and turning it off does not move one back.
    marker_server_dir = true,

    -- Whether a series folder gets a `.cover.jpg` beside its markers, per server.
    --
    -- One key per kind rather than a table, because everything here is read and
    -- written a scalar at a time and `DEFAULTS` has to name the key it is the
    -- default *for*: `Settings.get` warns and returns nil for a name it does not
    -- know. `meguru/seriescover` owns the list of kinds and asks for these by
    -- name, so a new driver adds a line here and one there.
    --
    -- On by default, all three: writing the file is the feature, and a reader
    -- who does not want it in a given folder says so in the menu. See
    -- `meguru/seriescover` for what the file is and is not.
    folder_cover_suwayomi = true,
    folder_cover_kavita   = true,
    folder_cover_komga    = true,

    -- Whether the position the reader has reached is sent back to the server, per
    -- server. One key per kind, by the same rule as the three above: the module
    -- that owns the list of kinds asks for these by name, so a new driver with a
    -- write path adds a line here and one there.
    --
    -- **On by default, and that is a heavier call than it looks.** Sending the
    -- position *is* the feature — off by default would ship a loop that stays open
    -- — but this is also the only thing the plugin writes to a *server* rather
    -- than to a disk, so for an installation that predates it, it is a behaviour
    -- change nobody asked for. What buys that back is that the switch is read on
    -- every report rather than when a book opens: a reader who objects stops it at
    -- the next page, not at the next volume.
    --
    -- Only servers that accept a write are in `meguru/progress`'s list, and two
    -- are not: Suwayomi is already told by its own page fetches, and Kavita's
    -- write API wants a login this plugin does not make.
    report_progress_komga = true,

    hide_status_bar   = true,
    auto_next_item    = true,
    manga_order       = true,

    -- Which view a long-press opens: the panels cut out of the page and shown one at
    -- a time, the page kept whole with a window moved over it, or the page alone with
    -- no panels at all. `"crop"` | `"window"` | `"zoom"`, and it says nothing about
    -- *whether* there is a panel view — a book has one unless the reader turned it off
    -- for that book, which the crop tab's *Long-press* row and KOReader's own row both
    -- do, and this is only reached when it is on.
    --
    -- **A seed, not the answer.** The view is a per-book value (`kopt_panel_view`),
    -- chosen in the crop tab under *Page Crop* or by the switch inside the panel
    -- viewer, and this is what a book with no value of its own is seeded with
    -- (`meguru/doc/defaults`) — so a long-press on that row is what sets it, as on
    -- every other row. The row's fourth answer, Off, is not a view but KOReader's own
    -- per-book `panel_zoom_enabled`, which has no default of its own by design: a
    -- long-press on it says so instead of writing one. See `Reader.panelViewMode`.
    --
    -- **Window by default, and it is a choice rather than a measurement.** It shows
    -- the page as it is, so a panel the detector merged, or a border it read wrongly,
    -- still shows the reader the artwork that is there — at the price of a strip of
    -- the neighbour at the window's edge, where the cropped view would have cut it
    -- away. Cropped is the view that fills a panel to the screen, and the reader who
    -- wants that presses the switch. See `meguru/viewport` for the geometry of both.
    panel_view        = "window",

    -- How close the window view sits, as **a multiple of the page's width on the screen**:
    -- 1.0 is a page exactly as wide as the screen, 1.7 a page seventy percent wider than it,
    -- and 1.9 the top of the range. It is what decides how many stops a panel takes — see
    -- `meguru/viewport` — and it is one number for everything rather than a per-book answer,
    -- like the two settings above it.
    --
    -- **The width and not "the whole page", because a level has to mean one thing.** The
    -- measure this replaced was "the whole page fits", which made a level mean a different
    -- magnification on every page shape and made *rotating the device* change how close the
    -- view was — a wider screen lowered that fit instead of raising it. A reader who wants the
    -- whole page has the free view, whose own floor is that measure; see `pageFitScale`.
    --
    -- **Set from the viewer's own button row, not from a menu row**, so the reader
    -- sees the page change as they change it. This is only the store: `ui/reader`
    -- reads it and hands the number to the view, and `ui/panelzoom` writes it back —
    -- the value button cycling the three presets, and the `-`/`+` beside it stepping
    -- by a tenth anywhere in 1..1.9. 1.7 is the middle of the three, and the level that
    -- leaves a typical 1600x2400 scan on a 1236x1648 screen at about 1.31 screen pixels
    -- per page pixel — a mild magnification of the file, where 1.9 asks 1.47.
    --
    -- **It is a multiple of the page's *content* width wherever the reader's crop gives
    -- one.** A scan's white border is not part of what a level is a multiple *of*, so the
    -- same level buys the artwork on a page with fat margins. The window itself stays the
    -- page's and is clamped to it, so a margin is somewhere these two views can be moved
    -- onto, not somewhere they refuse to go; where the reader has cropping off the content
    -- is the whole page and this paragraph says nothing. See `contentDims` in
    -- `meguru/ui/panelzoom`.
    panel_zoom_level  = 1.7,

    -- The free view's zoom, and the one preference here stored as a **scale** rather
    -- than a level: screen pixels per page pixel. Levels are magnifications *of* the
    -- fit, and that is what the other two views want — a stop is a stop whatever the
    -- page's size. This view has levels too (1.5x, 1.7x, 2x, 3x) but it also has
    -- *original size*, which is one page pixel to one screen pixel and magnifies
    -- nothing, so it cannot be written as a level at all. A manual pinch leaves the same
    -- kind of number behind, which is what "remembered" means here: the reader's own
    -- zoom, kept for the next open, written back by the view.
    --
    -- `false` is "nothing chosen yet" rather than a scale — the view then starts at
    -- `panel_zoom_level` times fit-to-screen, so there is no second default level to pick
    -- here. See `meguru/ui/panelzoom`.
    free_zoom_scale   = false,

    -- Whether the one-time claim of `.cbz` by `meguru/association` has been made.
    -- A record rather than a preference: it says "the offer was made", not "the
    -- answer is yes", and it is what keeps turning the menu row off from being
    -- undone on the next start. See that module for why the association itself
    -- cannot answer this question.
    cbz_default_claimed = false,

    -- The pixel budget for ONE decoded page — `meguru/doc/image`'s `cappedDim`
    -- reduces a page by area until it fits this. It bounds *retained*
    -- resolution, and with it everything downstream that reads the retained
    -- buffer: the margin scan, the page-number strip, the blank check, and
    -- every tile's crop-and-scale. It does NOT bound the decode peak — MuPDF
    -- decides that, and a lossless page is still decoded at full size inside
    -- the library (see `image.lua`'s DECODE_TOO_LARGE). So this is the knob for
    -- how much work a big page costs, and the price of lowering it is sharpness
    -- only when the reader magnifies past the reduced size.
    --
    -- 4 Mpx is deliberately below what an oversized scan would get: for a page
    -- with a long edge over ~2048 it restores the per-page work of the 2048
    -- long-edge cap this replaced (`db39a93`), while the area rule still treats
    -- a tall strip far better than that cap did. Pages at or under 4 Mpx —
    -- which is every manga page that fits a screen — come back at their natural
    -- size and are unaffected.
    --
    -- No menu writes this, so the only way to move it is by hand: set
    -- `meguru_max_native_pixels` in KOReader's `settings.reader.lua`. A stored
    -- value beats this default (`Settings.get`), which is also why a build that
    -- changes the default does not move a device that already stored one.
    max_native_pixels = 4 * 1024 * 1024,

    -- How the page is fitted to the screen. Semantic rather than KOReader's own
    -- zoom_mode names, because the mapping is what changes when the crop
    -- changes, not the reader's intent.
    fit               = "full",       -- "full" | "width" | "height"

    -- Reading geometry. These are the plugin-wide fallbacks a book with no
    -- value of its own picks up; once written into a book's sidecar the book
    -- keeps its own and is never touched again.
    --
    -- `trim_page` is the whole of the crop: the printed page number and the
    -- blank-page rule are rules of the engine rather than rows of the dialog
    -- (`meguru/doc/document.lua`'s getPageBBox), so there is no preference for
    -- either. A device that carries `page_number_crop` or `no_crop_blank` from an
    -- earlier version simply stops having them read.
    page_scroll       = 0,            -- 0 = page view, 1 = continuous
    trim_page         = 1,            -- 1 = auto crop (margins, number, blank), 3 = none
    rotate_wide       = 1,            -- 0 = off, 1 = right, 2 = left

    -- How many pages are shown at once: "off", "auto" (two only while the screen
    -- is in landscape), "on" (two always).
    --
    -- **"off" is the default, and the reason is that everything above it is a
    -- change to how a book reads.** One page at a time is what this plugin has
    -- always done and what the reader bought; two at a time is a preference a
    -- reader has to state. "auto" is the one worth reaching for — held in
    -- landscape the screen has the room for two pages, held upright it does not,
    -- and the orientation says which without a menu.
    --
    -- A page drawn as one wide image is never half of a pair, whatever this
    -- says; see `meguru/spread` for the imposition and the vertical alignment it
    -- costs.
    spread            = "off",

    -- Whether a pair is shifted one page back, and **from where**: 0 is "as the
    -- pages fall", and any other value is the page the offset is anchored at.
    --
    -- For a book whose spreads read one page out — a cover or a title page that is
    -- its own page — where pairing from the run's first page would put it wrong by
    -- one. The anchor, rather than a flag, is what makes the answer to "is it on?"
    -- depend on the pages in front of the reader: the run the anchor is in is the
    -- offset one, so a wide page ends it by itself and the reader can set it again
    -- past one. See `meguru/spread`, and `spreadOffsetHere` for the live answer.
    -- Read by comparison everywhere it is consulted: 0 is truthy in Lua, so
    -- `if spread_offset then` would read a stored "off" as on. `1` means page 1,
    -- which is both the front of the book and what this row stored when it was a
    -- flag — a book written then keeps exactly the behaviour it had.
    spread_offset     = 0,

    -- Whether a pair keeps the gutter the crop would otherwise have thrown away:
    -- the inner margin of each page, as far as the screen has room for it. 1 is
    -- on, and on is the default — a book whose pages are cropped to their panels
    -- has no white left between them at all, and a spread with its two pages
    -- butted together is the thing this row exists to undo. Turned off, a pair is
    -- drawn exactly as the crop left it.
    --
    -- The rule itself is `meguru/spread`'s; this is only whether it is asked, and
    -- `_pairLayout` is the one place that asks.
    spread_gutter     = 1,
    night_mode        = true,         -- pre-invert pages instead of a stark negative

    -- Page tone, as MuPDF's contrast: 1.0 is the page as it arrived, above it
    -- darkens and hardens, below it lifts and flattens. The row's own presets
    -- live in `ui/reader` (0.8 to 3.0); this is only the value a book with none
    -- of its own starts at, and it is why a global `kopt_contrast` — which
    -- `Configurable:loadDefaults` would otherwise inherit from a stock PDF —
    -- never reaches a Meguru book (`doc/defaults`).
    contrast          = 1.0,

    -- Colour intensity, the other MuPDF tone value: 1.0 is the file's own colour,
    -- below it drains towards grey, above it pushes the channels apart. Meaningless
    -- on a screen that is not decoding colour at all, which is why the document
    -- answers 1.0 there and the row is not offered (`doc/document`'s
    -- `saturation()`, `ui/reader`).
    saturation        = 1.0,

    -- Whether a page is dithered as it is written to the screen, for books that
    -- have no value of their own.
    --
    -- **Deliberately unset, and for a stronger version of the rotation
    -- argument.** There is no one right answer to it: this screen may be one
    -- whose controller dithers an 8-bit framebuffer itself — where a software
    -- dither costs tone rather than adding it — or one that relies on KOReader
    -- to do it. So the plugin does not decide: with nothing stored, the answer
    -- the *document* worked out for this device at open stands (`doc/defaults`
    -- seeds the row from it so the switch shows what the page is really doing),
    -- and the reader's tap is what turns it into a preference. `Settings.get`
    -- returns nil for this.
    dither            = UNSET,

    -- Deliberately unset: a book with no stored rotation keeps KOReader's own
    -- behaviour until the reader actually chooses a rotation, so the plugin
    -- never imposes one nobody asked for. `Settings.get` returns nil for this.
    rotation_mode     = UNSET,
}

-- G_reader_settings is created by KOReader during startup. Reads also happen
-- from the render path and from early plugin init, so every accessor tolerates
-- it being absent instead of erroring.
local function readStore()
    local s = rawget(_G, "G_reader_settings")
    if s and type(s.readSetting) == "function" then
        return s
    end
    return nil
end

function Settings.get(name)
    local default = DEFAULTS[name]
    if default == nil then
        logger.warn("Meguru: unknown setting", name)
        return nil
    end
    if default == UNSET then
        default = nil
    end

    local s = readStore()
    if not s then
        return default
    end
    local value = s:readSetting("meguru_" .. name)
    if value == nil then
        return default
    end
    return value
end

function Settings.set(name, value)
    if DEFAULTS[name] == nil then
        logger.warn("Meguru: unknown setting", name)
        return false
    end
    local s = readStore()
    if not s then
        return false
    end
    s:saveSetting("meguru_" .. name, value)
    s:flush()
    return true
end

function Settings.toggle(name)
    local value = not Settings.get(name)
    Settings.set(name, value)
    return value
end

return Settings
