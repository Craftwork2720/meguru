--[[--
The two menu surfaces Meguru adds.

Both carry the same `Settings` submenu, which is every preference the plugin has:
where a *new* book is written (the folder, and whether a per-server subfolder is
added), whether Meguru is the reader for `.cbz`, and — on the reader only —
three reading-behaviour switches. They are preferences, and they used to be a
dialog asked at every single open; a value that changes once does not belong in
the path of a tap. The one row that is not a preference is the last one, *Check
for updates*: it stores nothing and answers with a question, and it is here
rather than at the top of the submenu because it is a thing you do once rather
than a thing you reach for while reading.

The **reader** gets a ⋮ "Meguru" submenu, and only while a Meguru book is open.
It holds the series-navigation rows and a `Settings` submenu holding all seven
rows. The per-book *rendering* choices — crop, fit, reading direction —
deliberately live in the bottom ConfigDialog instead, where every other stock
per-book option lives; see `ui/reader.lua`.
Panel zoom is the one row that is a *default* rather than a switch of its own:
it is what a Meguru-opened file follows when it has no answer of its own, and
KOReader's own ⋮ row still answers for one book at a time.

The **FileManager** gets the same `Settings` submenu and nothing else, which for
it is the four rows that are not about reading a book that is already open. It
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
    carries the same constraint, and marks two seams inside `Settings`: the last
    behaviour row, above the destination rows, and the last *preference*, above
    the one row that is an action.
--]]

local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Association = require("meguru/association")
local Base = require("meguru/driver/base")
local SeriesCover = require("meguru/seriescover")
local Marker = require("meguru/marker")
local Open = require("meguru/ui/open")
local Reader = require("meguru/ui/reader")
local Settings = require("meguru/settings")
local Updater = require("meguru/updater")

-- Registering the drivers is what makes `Base.kinds()` able to answer; it is
-- idempotent (`require` caches), and `ui/open.lua` does the same at its own
-- load, so the order this module is reached in does not matter.
Base.loadDrivers()

local Menu = {}

-- Where the row goes -----------------------------------------------------------

--- Put `meguru` into one surface's `tools` order list, directly above
--- `read_timer` — the first entry of the stock list on both surfaces, so "above
--- it" is the head of the page. A build with no `read_timer` costs the position
--- and nothing else: the row then goes to index 1, which is where `read_timer`
--- would have been.
---
--- By neighbour rather than by index on purpose: everything above this row is
--- whatever the user has enabled, so the list grows and shrinks between
--- installations and an index would land somewhere different on the next device.
--- A name does not move.
local function insertMeguruBefore(order, neighbour)
    local pos = 1
    for i, id in ipairs(order) do
        if id == neighbour then
            pos = i
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
    insertMeguruBefore(fm_order.tools, "read_timer")
    insertMeguruBefore(rd_order.tools, "read_timer")
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
        -- Ends the preference group. What is below is not a preference at all
        -- but an action, and it is the only row here that can be *done* rather
        -- than set.
        separator = true,
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

--- One row: ask GitHub whether there is a newer Meguru, and offer to install it.
---
--- The only row under `Settings` that is not a preference — nothing is stored,
--- and tapping it twice in a row answers from the same cache rather than asking
--- GitHub again. It is here rather than at the top of the `Meguru` submenu
--- because it is a thing you do once, not a thing you do while reading.
---
--- Deferred through `nextTick` and wrapped in `pcall`, like the neighbour rows
--- below: the check reaches into the filesystem and the network, and a thrown
--- one must cost the reader a dialog rather than the whole menu.
local function updateRow()
    return {
        text = _("Check for updates"),
        keep_menu_open = true,
        callback = function()
            UIManager:nextTick(function()
                pcall(Updater.checkForUpdates)
            end)
        end,
    }
end

--- One row: which servers get a `.cover.jpg` in their series folders.
---
--- A submenu rather than one row per server, and it is the only place below
--- `Settings` that nests — see `settingsRow` for what that costs and why it is
--- paid here. Three flat rows would take `Settings` from six entries to nine for
--- a single feature, and a reader looking for "covers" would find three rows
--- that each name a server instead of one that names the thing.
---
--- The rows come from `SeriesCover.KINDS`, so the list of servers lives in the
--- module that has to know it anyway. A driver added there gets a row here and a
--- default in `meguru/settings`, and nothing in this file changes.
local function coverRow()
    local rows = {}
    for _, kind in ipairs(SeriesCover.KINDS) do
        local key = SeriesCover.settingFor(kind)
        rows[#rows + 1] = {
            -- The name of a server, shown as it spells itself. Not wrapped for
            -- translation: it is a proper noun, and a translated one would name
            -- a different product.
            text = kind:sub(1, 1):upper() .. kind:sub(2),
            keep_menu_open = true,
            checked_func = function() return Settings.get(key) end,
            callback = function() Settings.toggle(key) end,
        }
    end
    return {
        text = _("Covers for folders"),
        help_text = _("Leaves a .cover.jpg in a series folder, once, for programs other than KOReader — a file browser, a backup, another reader. KOReader itself does not draw folder covers. Turning a server off stops new files and leaves the ones already written."),
        sub_item_table = rows,
    }
end

--- The `Settings` row both surfaces hang their preferences on.
---
--- One level of nesting, and only one — with a single exception, `Covers for
--- folders`, whose three switches would otherwise be three rows in a list that
--- is about preferences in general rather than about covers. The rule is what
--- keeps the menu navigable; the exception is a group of its own with a name
--- that says so, which is the thing the rule is protecting.
---
--- The rows it holds used to sit in the same flat list as everything else, with
--- `separator` lines claiming that some of them belonged together; a line can
--- show that a group exists but not what it is, and `Settings` says it.
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
    settings[#settings + 1] = coverRow()
    settings[#settings + 1] = defaultReaderRow()
    settings[#settings + 1] = updateRow()

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
--- chapter — so there is nothing here a name could have been read from. That
--- holds for a local `.cbz` too, even though its neighbour is a folder listing
--- away: one row that reads the same on both is worth more than a label the
--- other path cannot have.
---
--- The row is drawn from the *series* the menu knows about, not from a
--- neighbour: a markered series always has a possible next, one walk away, so it
--- is drawn even when nothing has been walked yet — and for a local `.cbz` the
--- folder is listed at build time instead, which is why a lone book in a folder
--- gets no row at all rather than two that answer "no next chapter".
---
--- That listing is as current as the menu, and no more: the reader's item table
--- is built once per document and nothing rebuilds it (`open.lua:569-593` is the
--- comment of a refresh function that no longer exists), so a second volume added
--- to the folder while the book is open appears on the next open of the book and
--- not before. The alternative — draw the rows always and answer at the tap —
--- costs a row that can only ever say there is no next.
---
--- No `separator` here any more, and none is needed: with `Settings` a submenu
--- these two rows and it are the whole of the parent list, so the pair *is* the
--- navigation group. The split line moved inside `Settings`, where there are
--- still two kinds of preference to keep apart.
local function addNeighborRow(plugin, rows, which)
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
    -- auto-open toggle has anything to govern. Two sources, because a book's
    -- series is either a feed's or a folder's and never both — `Reader`'s own
    -- lookup answers nil for a marker and `seriesOf` for a local `.cbz` — so the
    -- pair cannot disagree about which rows should be drawn.
    local context = seriesOf(ui) or Reader.localSeriesOf(ui)

    -- Where to move around the series, and then everything that is a preference.
    -- These were one flat list split by `separator` lines until `Settings` became
    -- a submenu; the lines could show that a group existed, but not name it.
    local rows = {}
    if context then
        addNeighborRow(plugin, rows, "next")
        addNeighborRow(plugin, rows, "previous")
    end

    -- The preferences, grouped exactly as the lines used to group them: how
    -- reading behaves, then where a new book lands. The `separator` on the last
    -- behaviour row is what still marks the seam.
    local settings = {}

    -- Only meaningful when there is somewhere to go. A series the marker cannot
    -- name has no feed to walk, so the toggle would govern a behaviour that can
    -- never trigger — but a known series always *has* a possible next, it is
    -- simply one walk away, so the gate is the context and not a neighbour.
    -- `context` here is either kind: a local `.cbz` whose name carries a series
    -- is one the end-of-book hook can advance, so the toggle governs it too.
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

    -- **There is no row for any of the panel choices, and that is a decision rather than an
    -- omission.** All three live in the viewer's own button row, where the reader can see what
    -- they do while looking at the page they do it to: the switch at the front of it names and
    -- changes the view, and the value button beside it the zoom. The two preferences are still
    -- the store — `ui/reader` reads them and hands the numbers in, and `ui/panelzoom` writes them
    -- back — so nothing here is needed to reach either.
    --
    -- The view row that used to sit here was also the one control on this surface that a reader
    -- with another panel plugin installed could not use: that plugin answers the long-press, so
    -- Meguru's viewer — and with it the only other way to change the view — never opens. A row
    -- that reads one way while the panels behave another is the failure this file has removed a
    -- row for twice already.
    --
    -- What is *not* reachable from the viewer is whether there is a panel zoom at all, and that
    -- belongs to the per-book answer KOReader's own row gives — the reader looking at the page.

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
    settings[#settings + 1] = coverRow()
    settings[#settings + 1] = defaultReaderRow()
    settings[#settings + 1] = updateRow()

    rows[#rows + 1] = settingsRow(settings)

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = rows,
    }
end

return Menu
