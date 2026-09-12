--[[--
The two menu surfaces Meguru adds.

Both carry the same `Settings` submenu, which is every preference the plugin has:
where a *new* book is written (the folder, and whether a per-server subfolder is
added), whether Meguru is the reader for `.cbz`, and — on the reader only —
three reading-behaviour switches. They are preferences, and they used to be a
dialog asked at every single open; a value that changes once does not belong in
the path of a tap.

The **reader** gets a ⋮ "Meguru" submenu, and only while a Meguru book is open.
It holds the series-navigation rows and a `Settings` submenu holding all six
rows. The per-book *rendering* choices — crop, fit, reading direction —
deliberately live in the bottom ConfigDialog instead, where every other stock
per-book option lives; see `ui/reader.lua`.
Panel zoom is the one row that is a *default* rather than a switch of its own:
it is what a Meguru-opened file follows when it has no answer of its own, and
KOReader's own ⋮ row still answers for one book at a time.

The **FileManager** gets the same `Settings` submenu and nothing else, which for
it is the three rows that are not about reading a book that is already open. It
used to hold a library view and a server-administration screen; both are gone,
along with the manual server-kind override the latter existed for.

Two rules are worth stating, because breaking either is silent:

  * `sorting_hint` must name an id that resolves in *that* surface's order
    table. `menusorter` does `findById(...)` and then indexes the result without
    checking, so a hint naming nothing throws out of the whole menu build and
    takes every other plugin's row with it. `showUnderTools` below is the only
    place a hint is chosen.
  * `checked_func` is `TouchMenu`-only, and `mandatory` is plain-`Menu`-only.
    Both surfaces here are `TouchMenu`s on a touch device — the FileManager
    falls back to the plain widget only on a keyboard-only build
    (`filemanagermenu.lua:1043`) — so a row that must work on both carries its
    state in `text`/`text_func` rather than in either field. `separator = true`
    carries the same constraint, and now marks one seam only: the last behaviour
    row inside `Settings`, above the destination rows.
--]]

local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Association = require("meguru/association")
local Base = require("meguru/driver/base")
local Marker = require("meguru/marker")
local Open = require("meguru/ui/open")
local Reader = require("meguru/ui/reader")
local Settings = require("meguru/settings")

-- Registering the drivers is what makes `Base.kinds()` able to answer; it is
-- idempotent (`require` caches), and `ui/open.lua` does the same at its own
-- load, so the order this module is reached in does not matter.
Base.loadDrivers()

local Menu = {}

-- Where the row goes -----------------------------------------------------------

--- Put `meguru` into one surface's `tools` order list, directly below
--- `profiles` — or at the very top on a build with no `profiles` id to sit
--- under, which is where the row used to be.
---
--- By neighbour rather than by index: everything above this row is whatever the
--- user has enabled, so the list grows and shrinks between installations and an
--- index would land somewhere different from one device to the next. A name
--- does not move. An id with no matching item is skipped by the sorter anyway,
--- so a missing `profiles` costs the position and nothing else.
local function insertMeguruAfter(order, neighbour)
    local pos = 1
    for i, id in ipairs(order) do
        if id == neighbour then
            pos = i + 1
            break
        end
    end
    table.insert(order, pos, "meguru")
end

--- Where the plugin's row goes, and what it takes to get it there.
---
--- A hint alone is not enough. `menusorter` appends a hinted item to the *end*
--- of the named page's row list, which for `tools` means below `more_tools` —
--- i.e. below Developer options. Naming the id in that page's own order list is
--- what decides the position, and it is the mechanism core ships for this
--- purpose (`ui/plugin/insert_menu.lua`), though that one targets `more_tools`,
--- the position being avoided here.
---
--- Both order tables are named because they are two different files, and they
--- are the objects the menu builders `require`, so one mutation is seen by every
--- later build. Both edits are safe: an id in an order list with no matching
--- item is skipped by the sorter — which is what happens on the reader surface
--- while a PDF is open — and a duplicate insert is inert, because the first
--- occurrence consumes the item out of `item_table`.
---
--- `tools` resolves unconditionally in both files (it is in `KOMenu:menu_buttons`
--- and has its own list in each), so this guard is against a future build rather
--- than against this one. nil is the honest failure there: an unsorted row beats
--- a crash that takes the rest of the menu with it.
local function showUnderTools()
    local ok_fm, fm_order = pcall(require, "ui/elements/filemanager_menu_order")
    local ok_rd, rd_order = pcall(require, "ui/elements/reader_menu_order")
    if not (ok_fm and ok_rd
        and type(fm_order.tools) == "table" and type(rd_order.tools) == "table") then
        logger.warn("Meguru: no Tools menu in this build; the Meguru row is unsorted")
        return nil
    end
    insertMeguruAfter(fm_order.tools, "profiles")
    insertMeguruAfter(rd_order.tools, "profiles")
    return "tools"
end

local TOOLS_HINT = showUnderTools()

--- The two rows that decide where the next book lands, built fresh per call.
---
--- A factory rather than one table shared between the surfaces: a row table is
--- handed to two different menu widgets in one process, and `menusorter` already
--- writes into the items it is given (`v.id`, `v.new`). Fresh tables cost
--- nothing and remove the question.
---
--- The folder is shown through `text_func` rather than a right-aligned value
--- field, because `mandatory` is plain-`Menu`-only and `checked_func` is
--- `TouchMenu`-only — a `text_func` renders on both (`TouchMenuItem` goes through
--- `Menu.getMenuText`, which honours it), so the row means the same thing on
--- either widget and only loses the checkbox on the keyboard-only fallback.
local function destinationRows()
    return {
        {
            text_func = function()
                -- `Marker.baseDir()` is where a new marker actually lands, so the
                -- row cannot disagree with what the open does.
                return T(_("Main folder for .meguru streams: %1"), Marker.baseDir())
            end,
            -- A choice, not a way out of the menu: the row stays and is rebuilt,
            -- so the reader sees the folder they just picked.
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                Open.chooseMarkerDir(function()
                    if touchmenu_instance
                        and type(touchmenu_instance.updateItems) == "function" then
                        touchmenu_instance:updateItems()
                    end
                end)
            end,
        },
        {
            text = _("Subfolder per server"),
            help_text = _("New streams go in a folder named after the OPDS server (e.g. \"kavita\"), then their series. Streams already saved are not moved."),
            keep_menu_open = true,
            -- Ends the storage group: where a new book is written, above; what
            -- opens it, below.
            separator = true,
            checked_func = function()
                return Settings.get("marker_server_dir")
            end,
            callback = function()
                Settings.toggle("marker_server_dir")
            end,
        },
    }
end

--- One row: hand `.cbz` to Meguru, or give the extension back.
---
--- The mechanism is not here. It is a file-type association KOReader already
--- has a vocabulary for, and it is claimed on its own at first run, so
--- `meguru/association` owns it and both callers share one answer. What is left
--- in this file is a checkbox over it.
local function defaultReaderRow()
    return {
        text = _("Set Meguru as default reader for .cbz"),
        help_text = _("Every .cbz on this device opens in Meguru instead of KOReader's own reader, until you turn this off. A file you set individually with “Open with…” keeps its own choice."),
        keep_menu_open = true,
        checked_func = Association.holds,
        callback = function()
            if Association.holds() then
                Association.release()
            else
                Association.claim()
            end
        end,
    }
end

--- The `Settings` row both surfaces hang their preferences on.
---
--- One level of nesting, and only one. The rows it holds used to sit in the same
--- flat list as everything else, with `separator` lines claiming that some of
--- them belonged together; a line can show that a group exists but not what it
--- is, and `Settings` says it.
---
--- Both surfaces get it, including the FileManager where it holds only three
--- rows. That is a deliberate cost — a level of nesting for three taps — bought
--- so the two menus read the same: the reader who learned one has learned the
--- other.
local function settingsRow(rows)
    return {
        text = _("Settings"),
        sub_item_table = rows,
    }
end

-- FileManager ------------------------------------------------------------------

--- The FileManager's `Meguru` submenu.
---
--- One submenu, where this used to be two flat rows and a folder question asked
--- at every open. The library, the servers, and the two settings that decide
--- where a book lands are one subject: what Meguru does to this installation.
---
--- The key is `meguru`, the same id the reader surface uses, and that is safe
--- because the two `menu_items` tables are per-surface and never shared
--- (`FileManagerMenu.menu_items` vs `ReaderMenu.menu_items`), and only one of
--- them is ever written — `Meguru:addToMainMenu` dispatches on whether there is
--- a document. Reusing the name is better than inventing a second one: a saved
--- menu order in `settings/` then means the same thing on both surfaces.
function Menu.addFileManagerItems(plugin, menu_items)
    local settings = destinationRows()
    settings[#settings + 1] = defaultReaderRow()

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = { settingsRow(settings) },
    }
end

-- Reader -----------------------------------------------------------------------

--- What the book on screen says about its series, or nil.
---
--- Nil is the answer for a marker that names no series at all — a flat book with
--- no catalog ancestry — and for a v1 marker written before the fields existed.
--- Both still read perfectly; they just have nothing to navigate to, and the
--- rows below say "find" rather than naming a book.
---
--- **There is no second return value any more.** It used to be the neighbours the
--- catalog already held, which is what let the rows be *named*. Nothing holds a
--- neighbour list now: one is fetched when the reader asks, so a row that names a
--- book would be a promise the menu cannot keep at the moment it is drawn.
local function seriesOf(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.seriesContext) == "function") then
        return nil
    end
    local context = doc:seriesContext()
    if not (context and context.server_name) then
        return nil
    end
    return context
end

--- One "open the next/previous item in this series" row.
---
--- The row names no book, and that is the honest shape: a neighbour is fetched
--- when the reader asks for one, so a label carrying a title would be a promise
--- made before the walk that would have to keep it. `Reader.openNeighbor`
--- answers the row by walking the series, and the walk is what opens the
--- chapter — so there is nothing here a name could have been read from.
---
--- `context` is the *series* the menu knows about, not a neighbour: a known
--- series always has a possible next, one walk away, so this row is drawn even
--- when nothing has been walked yet. Nil — a flat book, or a v1 marker written
--- before the series fields existed — means no feed to walk at all, and no row.
---
--- No `separator` here any more, and none is needed: with `Settings` a submenu
--- these two rows and it are the whole of the parent list, so the pair *is* the
--- navigation group. The split line moved inside `Settings`, where there are
--- still two kinds of preference to keep apart.
local function addNeighborRow(plugin, rows, context, which)
    if not context then
        return
    end
    rows[#rows + 1] = {
        text = which == "next"
            and _("Open next in series")
            or _("Open previous in series"),
        callback = function()
            -- Deferred: the walk opens the chapter itself, possibly replacing
            -- this document, and this handler belongs to it.
            UIManager:nextTick(function()
                pcall(Reader.openNeighbor, plugin, which)
            end)
        end,
    }
end

function Menu.addReaderItems(plugin, menu_items)
    local ui = plugin.ui
    local doc = ui and ui.document
    if not (doc and doc.provider == "meguru") then
        return
    end

    -- One lookup for the whole submenu: the rows below, and whether the
    -- auto-open toggle has anything to govern.
    local context = seriesOf(ui)

    -- Where to move around the series, and then everything that is a preference.
    -- These were one flat list split by `separator` lines until `Settings` became
    -- a submenu; the lines could show that a group existed, but not name it.
    local rows = {}
    addNeighborRow(plugin, rows, context, "next")
    addNeighborRow(plugin, rows, context, "previous")

    -- The preferences, grouped exactly as the lines used to group them: how
    -- reading behaves, then where a new book lands. The `separator` on the last
    -- behaviour row is what still marks the seam.
    local settings = {}

    -- Only meaningful when there is somewhere to go. A series the marker cannot
    -- name has no feed to walk, so the toggle would govern a behaviour that can
    -- never trigger — but a known series always *has* a possible next, it is
    -- simply one walk away, so the gate is the context and not a neighbour.
    if context then
        settings[#settings + 1] = {
            text = _("Auto-open next in series"),
            help_text = _("Automatically opens the next volume or chapter when you finish this one."),
            keep_menu_open = true,
            checked_func = function()
                return Settings.get("auto_next_item")
            end,
            callback = function()
                local on = Settings.toggle("auto_next_item")
                UIManager:show(Notification:new{
                    text = on and _("auto-open on") or _("auto-open off"),
                    timeout = 2,
                })
            end,
        }
    end

    -- A default for everything Meguru opens, not an override of anything: the
    -- stock ⋮ row still answers per book, and a book that has an answer keeps it.
    --
    -- Absent when Panels+ owns the long-press, and that is not tidiness. That
    -- plugin forces `panel_zoom_enabled` on for every document it takes over, so
    -- the row would flip a preference with no effect on the book in front of the
    -- reader — a control that reads one way while the panels behave another.
    -- That is the same shape of bug the old per-extension version of this row
    -- shipped, and the fix is the same: do not offer a switch that does not
    -- switch anything.
    local hl = plugin.ui and plugin.ui.highlight
    local panels_plus_owns = hl
        and (hl._panels_plus_plugin or hl._panels_plus_original_panel_zoom)
    if not panels_plus_owns then
        settings[#settings + 1] = {
            text = _("Panel zoom in Meguru books"),
            help_text = _("The default for everything Meguru opens, streams and .cbz alike. A book you switch individually with KOReader's own ⋮ → Panel zoom (manga/comic) keeps its own answer; this is what the rest follow."),
            keep_menu_open = true,
            checked_func = Reader.panelZoomEnabled,
            callback = function()
                Reader.setPanelZoom(plugin.ui, not Reader.panelZoomEnabled())
            end,
        }
    end

    settings[#settings + 1] = {
        text = _("Hide status bar"),
        keep_menu_open = true,
        -- Ends the behaviour group: what the reader looks like while reading,
        -- above; where new books land, below.
        separator = true,
        checked_func = function()
            return Settings.get("hide_status_bar")
        end,
        callback = function()
            local on = Settings.toggle("hide_status_bar")
            -- Applies to the book on screen right now, not only the next one.
            plugin:onMeguruHideStatusBar(on)
        end,
    }
    -- The same three rows the FileManager's submenu carries, for the same reason
    -- they are there: they decide where a book lands and what opens it, and a
    -- reader who wants to change that should not have to close the book first.
    for _, row in ipairs(destinationRows()) do
        settings[#settings + 1] = row
    end
    settings[#settings + 1] = defaultReaderRow()

    rows[#rows + 1] = settingsRow(settings)

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = rows,
    }
end

return Menu
