--[[--
The two menu surfaces Meguru adds.

Both carry the same two rows deciding where a *new* book is written — the
folder, and whether a per-catalog subfolder is added. They are preferences, and
they used to be a dialog asked at every single open; a value that changes once
does not belong in the path of a tap.

The **reader** gets a ⋮ "Meguru" submenu, and only while a Meguru book is open.
It holds the series-navigation rows, the two plugin-wide reading-behaviour
switches (auto-open the next item at the end, hide the status bar) and the
destination rows. The per-book *rendering* choices — crop, fit, reading
direction — deliberately live in the bottom ConfigDialog instead, where every
other stock per-book option lives; see `ui/reader.lua`.

The **FileManager** gets the destination rows and nothing else. It used to hold
a library view and a server-administration screen; both are gone, along with the
manual server-kind override the latter existed for.

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
    carries the same constraint and is used by the reader's auto-open row.
--]]

local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("meguru/driver/base")
local Catalog = require("meguru/catalog")
local Marker = require("meguru/marker")
local Open = require("meguru/ui/open")
local Reader = require("meguru/ui/reader")
local Settings = require("meguru/settings")

-- Registering the drivers is what makes `Base.kinds()` able to answer; it is
-- idempotent (`require` caches), and `sync.lua` and `ui/open.lua` do the same
-- at their own load, so the order this module is reached in does not matter.
Base.loadDrivers()

local Menu = {}

-- Where the row goes -----------------------------------------------------------

--- Where the plugin's row goes, and what it takes to get it there.
---
--- A hint alone is not enough. `menusorter` appends a hinted item to the *end*
--- of the named page's row list, which for `tools` means below `more_tools` —
--- i.e. below Developer options. Naming the id in that page's own order list is
--- what puts it at the top, and it is the mechanism core ships for this purpose
--- (`ui/plugin/insert_menu.lua`), though that one targets `more_tools`, the
--- position we are trying to avoid.
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
    table.insert(fm_order.tools, 1, "meguru")
    table.insert(rd_order.tools, 1, "meguru")
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
                return T(_("Save books in: %1"), Marker.baseDir())
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
            text = _("Subfolder per catalog"),
            help_text = _("New books go in a folder named after their catalog, then their series. Books already saved are not moved."),
            keep_menu_open = true,
            checked_func = function()
                return Settings.get("marker_server_dir")
            end,
            callback = function()
                Settings.toggle("marker_server_dir")
            end,
        },
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
    local rows = {}
    for _, row in ipairs(destinationRows()) do
        rows[#rows + 1] = row
    end

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = rows,
    }
end

-- Reader -----------------------------------------------------------------------

--- `context, neighbours` for the book on screen. Both are nil for a marker with
--- no database behind it, which still reads — it just has no next or previous.
--- The context alone is what tells "this series is unknown" (nothing can be
--- done) apart from "this series is known but not synced" (its neighbours are
--- one walk away).
local function neighbors(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.catalogContext) == "function") then
        return nil, nil
    end
    local context = doc:catalogContext()
    if not (context and context.server) then
        return nil, nil
    end
    return context, Catalog.neighbors(context.series.id, context.item.item_key)
end

--- One "open the next/previous item in this series" row.
---
--- With no neighbour to name the row still belongs here, as a search rather than
--- an open. Opening a book from the OPDS browser records that book alone, so the
--- series starts with one item and no neighbours — but that is now a **passing**
--- state rather than the resting one: `ui/open.lua`'s `startBackgroundSync`
--- walks the series right after the handoff, and the row becomes
--- "Open next in series: <title>" once it lands. So this row is what a reader
--- sees while that walk is running, after it failed or was refused, on a series
--- catalogued any other way (the row at the top of a feed), and on a server with
--- no driver to walk with. `Reader.openNeighbor` answers it by
--- syncing the series first.
local function addNeighborRow(plugin, rows, context, found, which, title_of)
    local item = found and found[which]
    if not item then
        if not context then
            return
        end
        rows[#rows + 1] = {
            text = which == "next"
                and _("Find the next chapter")
                or _("Find the previous chapter"),
            callback = function()
                -- Deferred: the sync opens the chapter itself, possibly
                -- replacing this document, and this handler belongs to it.
                UIManager:nextTick(function()
                    pcall(Reader.openNeighbor, plugin, which)
                end)
            end,
        }
        return
    end
    rows[#rows + 1] = {
        text = title_of(item),
        callback = function()
            -- Deferred: opening the neighbour replaces the document, which
            -- tears down the reader this menu handler belongs to. The call
            -- opens the book itself, so nothing switches a second time here.
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

    -- One query for the whole submenu: the rows below, and whether the
    -- auto-open toggle has anything to govern.
    local context, found = neighbors(ui)

    local rows = {}
    -- The book on the row is `bookLabel`'s short form, for the reason the resume
    -- dialog's buttons already use it: the series is the one *already open*, so
    -- the volume token is the whole of what the row has to say, and the full
    -- entry title overflows it. It never returns nil, so there is no bare
    -- "Open next in series" to fall back to.
    addNeighborRow(plugin, rows, context, found, "next", function(item)
        return T(_("Open next in series: %1"), Open.bookLabel(item))
    end)
    addNeighborRow(plugin, rows, context, found, "previous", function(item)
        return T(_("Open previous in series: %1"), Open.bookLabel(item))
    end)

    -- Only meaningful when there is somewhere to go; without a next item the
    -- toggle would govern a behaviour that can never trigger.
    if found and found.next then
        rows[#rows + 1] = {
            text = _("Auto-open next at the end"),
            keep_menu_open = true,
            -- Draws the split line under this row, separating the series
            -- navigation group from the maintenance group below.
            separator = true,
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

    rows[#rows + 1] = {
        text = _("Hide status bar"),
        keep_menu_open = true,
        checked_func = function()
            return Settings.get("hide_status_bar")
        end,
        callback = function()
            local on = Settings.toggle("hide_status_bar")
            -- Applies to the book on screen right now, not only the next one.
            plugin:onMeguruHideStatusBar(on)
        end,
    }
    -- The same two settings the FileManager's submenu carries, for the same
    -- reason they are there: they decide where the *next* book lands, and a
    -- reader who wants to change that should not have to close the book first.
    for _, row in ipairs(destinationRows()) do
        rows[#rows + 1] = row
    end

    menu_items.meguru = {
        text = _("Meguru"),
        sorting_hint = TOOLS_HINT,
        sub_item_table = rows,
    }
end

return Menu
