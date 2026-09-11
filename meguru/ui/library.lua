--[[--
The library view: every series the catalog knows, with its new-chapter count.

This is the thing the catalog exists for. The old plugin could not answer "does
this series have new chapters?" without walking every marker file, because each
one held its own copy of the series state. Here it is two correlated subqueries
in one statement — `Catalog.listSeries` — for the whole list at once.

Reading progress is deliberately *not* on these rows. It would be a sidecar
lookup per series, and the count that matters at this level is chapters, not
pages. Per-item progress belongs to the series view, where the items are.
--]]

local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Catalog = require("meguru/catalog")
local Paths = require("meguru/paths")
local Store = require("meguru/store")

local Library = {}

--- Every series, from every server, in one list sorted by display name.
---
--- `name_sort` is the catalog's own case-folded key, so the order does not
--- change with the device locale; the id breaks ties, which keeps the list
--- stable between builds.
local function collectSeries()
    local rows = {}
    for _, server in ipairs(Catalog.servers()) do
        for _, series in ipairs(Catalog.listSeries(server.id)) do
            rows[#rows + 1] = { server = server, series = series }
        end
    end
    table.sort(rows, function(a, b)
        local ak, bk = a.series.name_sort, b.series.name_sort
        if ak ~= bk then
            return (ak or a.series.name) < (bk or b.series.name)
        end
        return a.series.id < b.series.id
    end)
    return rows
end

--- The right-hand text on a series row: how many chapters are new, then the
--- total. The server's name is prefixed only when there is more than one, since
--- on a single-server setup it would be the same word on every row.
local function rowSubtitle(row, multi_server)
    local parts = {}
    if multi_server then
        parts[#parts + 1] = row.server.name
    end
    local new_count = tonumber(row.series.new_count) or 0
    if new_count > 0 then
        parts[#parts + 1] = T(_("%1 new"), new_count)
    end
    parts[#parts + 1] = tostring(row.series.item_total or 0)
    return table.concat(parts, " · ")
end

--- Open the library view. `host` is the plugin instance whose `.ui` is the
--- application it was opened from.
function Library.show(host)
    Store.ensure()
    local rows = collectSeries()

    if #rows == 0 then
        -- The schema version and the database path are reported here rather
        -- than behind a separate "catalog status" menu row: an empty library is
        -- the only moment either is worth knowing, and a row nobody opens is a
        -- worse home for the answer than the screen that raised the question.
        UIManager:show(InfoMessage:new{
            text = T(_("the catalog is empty.\n\nOpen a series from an OPDS catalog with “Meguru this series” to start filling it.\n\nschema v%1\n%2"),
                Store.schemaVersion(), Paths.dbFile()),
        })
        return
    end

    local servers = Catalog.servers()
    local multi_server = #servers > 1

    local item_table = {}
    for _, row in ipairs(rows) do
        local series = row.series
        item_table[#item_table + 1] = {
            text = series.name,
            mandatory = rowSubtitle(row, multi_server),
            mandatory_dim = (tonumber(series.new_count) or 0) == 0,
            callback = function()
                -- Required late: the series view requires this module, and a
                -- load-time cycle would hand one of them a half-built table.
                local Series = require("meguru/ui/series")
                Series.show(host, row.server, Catalog.series(series.id) or series)
            end,
        }
    end

    logger.dbg("Meguru: library view with", #rows, "series")

    UIManager:show(Menu:new{
        title = _("Meguru library"),
        item_table = item_table,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    })
end

return Library
