--[[--
The bottom menu's tab icons, from the plugin's own artwork.

KOReader's config dialog draws its tab bar from `icon` **names** —
`appbar.rotation` and its three siblings — which `IconWidget` resolves against
the icon directories in `resources/` (`ui/widget/iconwidget.lua`). Those are the
*stock* names, and a PDF's dialog asks for them too: a plugin that replaced the
files, or shadowed the names, would have changed every book's menu.

**So this plugin's tabs carry names of their own, and only those names resolve to
files.** Nothing else in KOReader asks for `meguru.rotation`, which is the whole
of how the two menus are kept apart — the wrap below can be installed once for
the whole process and still touch no book but a Meguru one.

The artwork is the SVGs in `assets/icons/`, shipped beside the plugin's other asset
and **optional in the same way** (`meguru/rowcover`): `Icons.tab` answers the stock
name when a file is not there, so a hand-copied install that missed them draws
KOReader's own icons and says nothing.

Each file is named for the **tab** it belongs to — `reading`, `page`, `rotation` —
and `FALLBACK` beside them says which stock icon each tab wears when its file is
missing. That table is not ceremony: our names and KOReader's are not
interchangeable, and asking for `meguru.reading` with nothing behind it answers
KOReader's *not-found* glyph rather than a sensible icon. A tab that is ours has to
name its own fallback, and there is nowhere else it could.

*What was rejected:* writing the icons into the icon directory KOReader searches
(`<data dir>/icons`, which comes first in `ICONS_DIRS`). It is the drop-in way and
it is wrong twice over — it replaces those four icons for every document, MuPDF
included, and it makes a plugin that writes to the user's storage at startup for
something it already ships.

A note on the artwork itself, because it is a constraint rather than a preference,
and one that is invisible until it is on a device.

These are **outline** icons — `fill="none"` with a `stroke` — and so are most of
KOReader's own: 61 of the 102 in `resources/icons/mdlight` are drawn with nothing
but strokes, the two this plugin replaces among them. An outline is therefore a
shape the rasteriser is known to draw.

**Where the paint is declared is not interchangeable.** Every one of KOReader's
icons puts `fill`/`stroke` on its own drawing elements, and so do these. They
arrived as Lucide exports with the stroke on the root `<svg>`, which is valid SVG
and inherits in a compliant renderer — but inheritance is the part of the format a
small rasteriser is least obliged to implement, and a file that renders in every
browser and blank in KOReader is exactly the kind of failure this plugin has been
bitten by before. So the attributes were moved down onto each `path`, which is
both the form every shipped icon uses and the one form that cannot depend on
inheritance at all. **An editor that re-exports these from the same source will
put them back on the root**, and nothing on the development machine can tell the
difference; if an icon ever comes up empty on a device, that is the first thing to
look at.
--]]

local FS = require("meguru/fs")
local Paths = require("meguru/paths")

local Icons = {}

--- The stock icon each of this plugin's tabs wears when its own artwork is not
--- shipped. Keyed by the tab's kind, which is the name of its file as well.
local FALLBACK = {
    reading  = "appbar.pageview",
    page     = "appbar.crop",
    rotation = "appbar.rotation",
}

--- The shipped artwork for a tab kind, or nil when it is not there.
---
--- Nil is an ordinary answer — the plugin can be running before `Meguru:init` has
--- handed over the directory it lives in (`Paths.pluginDir`), and the artwork is
--- optional besides — so every caller treats it as "no artwork" rather than as a
--- problem.
function Icons.file(kind)
    if type(kind) ~= "string" then
        return nil
    end
    local path = Paths.asset("icons/" .. kind .. ".svg")
    if path and FS.exists(path) then
        return path
    end
    return nil
end

--- The icon name to give the tab of this kind: the plugin's own when its artwork
--- shipped, KOReader's own when it did not.
---
--- The two are interchangeable at the call site and that is the point — the
--- dialog is handed a name either way, and which name it is decides whether the
--- wrap below has anything to say about it.
function Icons.tab(kind)
    if Icons.file(kind) then
        return "meguru." .. kind
    end
    return FALLBACK[kind] or "appbar.pageview"
end

local installed = false

--- Teach `IconWidget` what the plugin's own icon names mean. Once per process.
---
--- It is a wrap on the class, because there is no instance to hang it on: the
--- dialog makes one `IconWidget` per tab, from nothing but the name, inside
--- `IconButton:init`. Installed from `main.lua`, before any book can be opened.
function Icons.install()
    if installed then
        return
    end
    local ok, IconWidget = pcall(require, "ui/widget/iconwidget")
    if not ok or type(IconWidget) ~= "table" or type(IconWidget.init) ~= "function" then
        return
    end
    installed = true
    local orig_init = IconWidget.init
    IconWidget.init = function(self)
        local kind = type(self.icon) == "string"
            and self.icon:match("^meguru%.(%a+)$")
        if kind then
            local path = Icons.file(kind)
            if path then
                -- **`IconWidget` answers a caller that has already found the
                -- file**: it returns before its own name lookup, which is the
                -- documented way for anything outside `resources/` to show an
                -- icon, and the reason this needs no icon directory of its own.
                self.file = path
                return
            end
            -- The artwork went away between the tab being named and the icon being
            -- made (an install replaced under a running reader). Answer with the
            -- stock name rather than KOReader's not-found glyph.
            self.icon = FALLBACK[kind] or "appbar.pageview"
        end
        return orig_init(self)
    end
end

return Icons
