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

    hide_status_bar   = true,
    auto_next_item    = true,
    manga_order       = true,

    -- The default answer to "does a long-press zoom into a panel" for everything
    -- Meguru opens — markers, and the `.cbz` files this engine also reads.
    --
    -- It is only the *default*: a file that answered for itself, which is what
    -- KOReader's own ⋮ row makes it do, keeps its own answer and this one never
    -- overrides it. `true` because that is KOReader's own default for `cbz`/`cbt`
    -- and was this plugin's for markers.
    panel_zoom        = true,

    -- Which of the two views a long-press opens: the panels cut out of the page
    -- and shown one at a time, or the page kept whole with a window moved over it.
    -- `"crop"` | `"window"`, and it says nothing about *whether* there is a panel
    -- view — that is `panel_zoom` above, and this is only reached when it is on.
    --
    -- Cropped by default, because it is what this plugin has always done and what
    -- its panel geometry was measured for. See `meguru/viewport` for the other one.
    panel_view        = "crop",

    -- How close the window view sits: a magnification over fit-to-screen, so 1 is a
    -- whole page on the screen and 2 is half of one. It is what decides how many
    -- stops a panel takes — see `meguru/viewport` — and it is one number for
    -- everything rather than a per-book answer, like the two settings above it.
    --
    -- **Set from the viewer's own button row, not from a menu row**, so the reader
    -- sees the page change as they change it. This is only the store: `ui/reader`
    -- reads it and hands the number to the view, and `ui/panelzoom` writes it back
    -- when the button cycles. 1.7 is the middle of the three levels, and the level
    -- that leaves a typical 1600x2400 scan rendering at about 1.16 screen pixels per
    -- page pixel — a mild magnification of the file rather than 1.9's 1.30.
    panel_zoom_level  = 1.7,

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
    page_scroll       = 0,            -- 0 = page view, 1 = continuous
    trim_page         = 1,            -- 1 = auto margin crop, 3 = none
    page_number_crop  = 1,            -- cut a printed page number from the gutter
    no_crop_blank     = 1,            -- leave blank pages uncropped
    rotate_wide       = 1,            -- 0 = off, 1 = right, 2 = left
    night_mode        = true,         -- pre-invert pages instead of a stark negative

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
