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

Two rules from the reader menu are worth stating because breaking either is
silent:

  * `sorting_hint` must be the id of an item that already exists in the reader
    menu. The sorter resolves it and indexes the result without checking, so a
    hint naming nothing crashes the whole menu build. It is set only when the
    id is actually present.
  * `separator = true` is supported by `TouchMenu`, which is what the reader ⋮
    menu is — but *not* by the plain `Menu` widget the library and series views
    use. It is used here and nowhere else.
--]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local MenuWidget = require("ui/widget/menu")
local Notification = require("ui/widget/notification")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("meguru/driver/base")
local Catalog = require("meguru/catalog")
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
                text = T(_("Meguru: cache cleared (%1 file(s), %2)."),
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
        UIManager:show(InfoMessage:new{ text = _("Meguru: no cover available.") })
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
                    text = T(_("Meguru: %1 is now %2. Its next sync will be rebuilt."),
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
            text = _("Meguru: no servers yet. Open a catalog in KOReader's OPDS browser and use “Meguru this series” on a book."),
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

-- FileManager ------------------------------------------------------------------

function Menu.addFileManagerItems(plugin, menu_items)
    menu_items.meguru_library = {
        text = _("Meguru library"),
        -- The FileManager menu tolerates an unknown hint by dropping the item
        -- into its "more" bucket, so this is presentational, not load-bearing.
        sorting_hint = "search",
        callback = function()
            local Library = require("meguru/ui/library")
            Library.show(plugin)
        end,
    }
    menu_items.meguru_servers = {
        text = _("Meguru servers"),
        sorting_hint = "search",
        callback = function()
            Menu.showServers()
        end,
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
--- an open: opening a book from the OPDS browser records that book alone, so a
--- series starts out with exactly one item in it and no neighbours at all. This
--- row is then the only way to ask for the next chapter, which is what
--- `Reader.openNeighbor` answers by syncing the series first.
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
                    text = on and _("Meguru: auto-open on") or _("Meguru: auto-open off"),
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

    menu_items.meguru = {
        text = _("Meguru"),
        -- Must name an item that exists in the reader menu, or the build
        -- crashes; omitted entirely when it does not.
        sorting_hint = menu_items.typeset and "typeset" or nil,
        sub_item_table = rows,
    }
end

return Menu
