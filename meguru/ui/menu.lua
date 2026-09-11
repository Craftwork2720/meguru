--[[--
The two menu surfaces Meguru adds.

The **FileManager** gets the library and the server administration: the catalog
is a property of the installation, not of any one book, and FileManager is where
a reader expects to find their shelves.

The **reader** gets a ⋮ "Meguru" submenu, and only while a Meguru book is open.
It holds the two plugin-wide reading-behaviour switches (auto-open the next item
at the end, hide the status bar) plus the per-book maintenance actions (cover,
clear cache). The per-book *rendering* choices — crop, fit, reading direction —
deliberately live in the bottom ConfigDialog instead, where every other stock
per-book option lives; see `ui/reader.lua`.

Both surfaces also carry the same two rows deciding where a *new* book is
written — the folder, and whether a per-catalog subfolder is added. They are
preferences, and they used to be a dialog asked at every single open; a value
that changes once does not belong in the path of a tap.

Three rules are worth stating, because breaking any of them is silent:

  * `sorting_hint` must name an id that resolves in *that* surface's order
    table. `menusorter` does `findById(...)` and then indexes the result without
    checking, so a hint naming nothing throws out of the whole menu build and
    takes every other plugin's row with it. `showUnderTools` below is the only
    place a hint is chosen.
  * `separator = true` is supported by `TouchMenu` and *not* by the plain `Menu`
    widget. Both main menus are `TouchMenu`s on a touch device — the reader ⋮
    menu, and the FileManager's, which falls back to the plain widget only on a
    keyboard-only build (`filemanagermenu.lua:1043`). The plain widget is what
    Meguru's *own* library, series and server lists use, so `separator` is safe
    in the rows built here and unsafe in those.
  * `checked_func` is `TouchMenu`-only, and `mandatory` is plain-`Menu`-only.
    Rows that must work on both carry their state in `text`/`text_func` instead.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local MenuWidget = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Screen = require("device").screen
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

-- Cache ------------------------------------------------------------------------

local function humanBytes(n)
    if n >= 1048576 then
        return string.format("%.1f MB", n / 1048576)
    elseif n >= 1024 then
        return string.format("%.0f KB", n / 1024)
    end
    return string.format("%d B", n)
end

--- Drop the on-disk page and cover caches, confirming first.
---
--- Nothing cached is load-bearing, so this cannot break a book — a page of the
--- book open right now simply refetches the next time it is painted from disk.
local function clearCache()
    UIManager:show(ConfirmBox:new{
        text = _("Clear Meguru's cached pages and covers?"),
        ok_text = _("Clear cache"),
        ok_callback = function()
            local removed, freed = Reader.clearCache()
            UIManager:show(InfoMessage:new{
                text = T(_("cache cleared (%1 file(s), %2)."),
                    removed, humanBytes(freed or 0)),
            })
        end,
    })
end

local function showCover(ui)
    local doc = ui and ui.document
    if not (doc and type(doc.getCoverPageImage) == "function") then
        return
    end
    -- A stream book's cover comes off the network on a cold cache, so this can
    -- fail for reasons that are not the reader's fault.
    local ok, cover = pcall(doc.getCoverPageImage, doc)
    if not ok or not cover then
        UIManager:show(InfoMessage:new{ text = _("no cover available.") })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    UIManager:show(ImageViewer:new{ image = cover, with_title_bar = false, fullscreen = true })
end

-- Server kind override ---------------------------------------------------------

--- The kinds a server may be set to: everything actually registered, plus the
--- "not yet sniffed" state.
local function serverKindChoices()
    local choices = { { id = nil, label = _("Detect automatically") } }
    for _, kind in ipairs(Base.kinds()) do
        choices[#choices + 1] = { id = kind, label = kind }
    end
    return choices
end

--- Let the reader say what is behind a server, or hand it back to the sniff.
---
--- This is the escape hatch for a mis-sniffed server. It has to exist: a wrong
--- kind picks the wrong driver, and every subsequent sync then re-keys the
--- series against feeds that do not describe it — a failure that looks like
--- data corruption rather than a misconfiguration, and which no amount of
--- re-syncing repairs on its own.
local function showServerKinds(server)
    local choices = serverKindChoices()
    local current = server.kind
    local items = {}
    for _, choice in ipairs(choices) do
        local id = choice.id
        items[#items + 1] = {
            text = choice.label,
            -- The plain Menu widget has no radio state; `mandatory` is its
            -- right-aligned value slot, which is what marks the live choice.
            mandatory = (id == current) and "✓" or nil,
            callback = function()
                if id == nil then
                    Catalog.clearServerKind(server.id)
                else
                    Catalog.setServerKind(server.id, id)
                end
                UIManager:close(menu)
                UIManager:show(InfoMessage:new{
                    text = T(_("%1 is now %2. Its next sync will be rebuilt."),
                        server.name,
                        id and T(_("driven as %1"), id) or _("detected automatically")),
                })
            end,
        }
    end
    local menu = MenuWidget:new{
        title = T(_("Server type — %1"), server.name),
        item_table = items,
        is_borderless = true,
        width = math.floor(Screen:getWidth() * 0.9),
    }
    UIManager:show(menu)
end

--- The list of known servers, each opening its kind chooser.
---
--- This is the escape hatch for a mis-sniffed server: a wrong kind picks the
--- wrong driver, and every subsequent sync then re-keys the series against
--- feeds that do not describe it — a failure that looks like data corruption
--- rather than a misconfiguration.
function Menu.showServers()
    local servers = Catalog.servers()
    if #servers == 0 then
        UIManager:show(InfoMessage:new{
            text = _("no servers yet. Open a catalog in KOReader's OPDS browser and use “Meguru this series” on a book."),
        })
        return
    end
    local items = {}
    for _, server in ipairs(servers) do
        items[#items + 1] = {
            text = server.name,
            mandatory = server.kind or _("unknown"),
            callback = function()
                UIManager:close(menu)
                showServerKinds(server)
            end,
        }
    end
    local menu = MenuWidget:new{
        title = _("Meguru servers"),
        item_table = items,
        is_borderless = true,
        width = math.floor(Screen:getWidth() * 0.9),
    }
    UIManager:show(menu)
end

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
    local rows = {
        {
            text = _("Library"),
            callback = function()
                local Library = require("meguru/ui/library")
                Library.show(plugin)
            end,
        },
        {
            text = _("Servers"),
            callback = function()
                Menu.showServers()
            end,
        },
    }
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
--- catalogued any other way (the row at the top of a feed, the series view), and
--- on a server with no driver to walk with. `Reader.openNeighbor` answers it by
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
    addNeighborRow(plugin, rows, context, found, "next", function(item)
        return item.display_title
            and T(_("Open next in series: %1"), item.display_title)
            or _("Open next in series")
    end)
    addNeighborRow(plugin, rows, context, found, "previous", function(item)
        return item.display_title
            and T(_("Open previous in series: %1"), item.display_title)
            or _("Open previous in series")
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
    rows[#rows + 1] = {
        text = _("Show book cover"),
        callback = function()
            showCover(ui)
        end,
    }
    rows[#rows + 1] = {
        text = _("Clear cache"),
        callback = clearCache,
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
