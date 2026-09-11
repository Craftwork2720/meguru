--[[--
One series: its items in reading order, with what has been read and what is new.

The item list comes from the catalog, so it is the *canonical* order — the one
the series' own feed declares — and not whichever subset the user happened to
browse. That is the second thing the catalog buys: the old plugin could only
offer the neighbours that the captured feed happened to contain.

Opening a row is `ui/open.lua`'s job. That is where a chapter never opened
before gets its marker written, and — for a driver whose stored template is
resolved lazily — its page stream fetched.
--]]

local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Catalog = require("meguru/catalog")
local Open = require("meguru/ui/open")
local Store = require("meguru/store")
local SyncJob = require("meguru/ui/syncjob")

local Series = {}

--- How far into an item the reader is, or nil when it has never been opened.
---
--- Two levels, and the cheap one gates the expensive one. An item with no
--- `marker_path` was never opened, so nothing is looked up and no file is
--- touched; only then is the sidecar searched for, and only one that exists is
--- parsed. A series the reader has barely started costs a handful of stats, not
--- a hundred parses.
---
--- `findSidecarFile` rather than `DocSettings:open`: the latter weighs a dozen
--- candidate locations, dofiles each and deletes the ones it rejects, which is
--- far too much to do for every row of every series.
local function readState(item)
    if type(item.marker_path) ~= "string" or item.marker_path == "" then
        return nil
    end
    local sidecar = DocSettings:findSidecarFile(item.marker_path)
    if not sidecar then
        return nil
    end
    local ok, ds = pcall(DocSettings.openSettingsFile, sidecar)
    if not ok or not ds then
        return nil
    end
    local percent = tonumber(ds:readSetting("percent_finished"))
    if not percent then
        return nil
    end
    if percent >= 0.995 then
        return _("read")
    end
    return string.format("%d%%", math.floor(percent * 100))
end

--- The right-hand text on an item row: what is new, then what is read.
local function rowSubtitle(item, is_new)
    local parts = {}
    if is_new then
        parts[#parts + 1] = _("new")
    end
    local state = readState(item)
    if state then
        parts[#parts + 1] = state
    end
    return table.concat(parts, " · ")
end

--- The whole item table, sync row included.
---
--- `watermark` is the series' `new_since` as it stood when the reader opened
--- this view. Rows are built against it and only afterwards does the watermark
--- move: opening the series is itself the acknowledgement, so if it moved first
--- it would erase the very "new" marks the reader came here to see.
local function buildTable(series, host, server, watermark, on_sync)
    local items = {
        {
            text = _("⟳ Check for new chapters"),
            bold = true,
            callback = on_sync,
        },
    }

    local removed = 0
    for _, item in ipairs(Catalog.orderedItems(series.id)) do
        if item.removed_at then
            -- Tombstoned by a sync: gone from the provider. Its marker file is
            -- still on disk and still opens from History; it is simply not part
            -- of the series any more, so it is not offered here.
            removed = removed + 1
        else
            items[#items + 1] = {
                text = item.display_title or item.title,
                mandatory = rowSubtitle(item, item.first_seen_at > watermark),
                callback = function()
                    -- Reading a stream needs a connection the same way a
                    -- download does, so the manager prompts for one rather than
                    -- letting the first page fail.
                    NetworkMgr:runWhenConnected(function()
                        Open.openCatalogItem(host, server, series, item)
                    end)
                end,
            }
        end
    end

    if removed > 0 then
        logger.dbg("Meguru:", series.name, "has", removed, "removed item(s) hidden")
    end
    return items
end

--- Show one series.
function Series.show(host, server, series)
    Store.ensure()

    -- Forward-declared: the sync row's callback needs the menu, and the menu
    -- needs the item table that the row is part of. A local is only in scope
    -- after its declaration, so the order here is load-bearing.
    local menu

    local function on_sync()
        if not NetworkMgr:isConnected() then
            NetworkMgr:willRerunWhenConnected(on_sync)
            return
        end
        -- Re-read the row: a previous sync may have moved `new_since` or the
        -- item count, and the plan is built from what it finds.
        local current = Catalog.series(series.id) or series
        -- A refusal is a real outcome here and has to be shown, unlike on the
        -- reader's path where it is the state the caller wanted: this is an
        -- explicit tap, and a tap that does nothing at all with no explanation
        -- reads as a broken row. A walk can now be running for this series
        -- without this view having started it — the background walk after an
        -- OPDS add, or the reader's own "Find the next chapter".
        local started, why = SyncJob.run(server, current, function(ok)
            if not ok or not menu then
                return
            end
            local refreshed = Catalog.series(series.id)
            if refreshed then
                -- The watermark is refreshed too: this is a new view of the
                -- list, so what is "new" is new again — and it is acknowledged
                -- as soon as it has been shown.
                menu:switchItemTable(refreshed.name,
                    buildTable(refreshed, host, server, refreshed.new_since or 0, on_sync))
                Catalog.markSeriesSeen(refreshed.id)
            end
        end)
        if not started and why == "busy" then
            UIManager:show(InfoMessage:new{
                text = T(_("%1 is already syncing."), current.name),
            })
        end
    end

    local item_table = buildTable(series, host, server, series.new_since or 0, on_sync)
    Catalog.markSeriesSeen(series.id)

    logger.dbg("Meguru: series view with", #item_table - 1, "items")

    menu = Menu:new{
        title = series.name,
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
    UIManager:show(menu)
end

return Series
