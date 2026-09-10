--[[--
Every SQL statement the plugin runs, in one place.

Callers never build SQL. They pass tables and get tables back, with int64
cdata already normalized to Lua numbers. When adding a query here, keep the
identity rules intact: items are matched by `(series_id, item_key)` and nothing
else, and a re-sync may never move an item backwards in reading order.
--]]

local Naming = require("meguru/naming")
local Store = require("meguru/store")

local Catalog = {}

--- Reading order, used everywhere an item list is produced. Items with a
--- provider-reported ordinal come first (in that order), then the rest in
--- canonical feed position. `item_key` only breaks exact ties, so the order is
--- total and stable across syncs.
local ITEM_ORDER = "(ordinal IS NULL), ordinal, feed_index, item_key"

--- Ordinal sources, ranked. `chapter` beats `volume` beats feed position, so a
--- sync that only knows feed order cannot flatten a real one.
local function rank(column)
    return string.format(
        "(CASE %s WHEN 'chapter' THEN 3 WHEN 'volume' THEN 2 ELSE 1 END)", column)
end

--- True when this upsert's ordinal may replace the stored one: it exists, and
--- its source is at least as good as the stored one's.
---
--- `>=`, not `>`: a same-rank report is a *correction* (the provider renumbered
--- the chapter) and must land. With `>` a stored ordinal could never be fixed
--- and would sit permanently disagreeing with the server, which is the drift
--- this whole catalog exists to prevent. Equal rank can never be a degradation,
--- and a coarser source still cannot overwrite a finer one.
local ADVANCE_ORDINAL = string.format(
    "excluded.ordinal IS NOT NULL AND %s >= %s",
    rank("excluded.ordinal_source"), rank("items.ordinal_source"))

-- Servers ---------------------------------------------------------------------

local UPSERT_SERVER = [[
INSERT INTO servers (name, kind, kind_source, host, root_url, last_seen_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(name) DO UPDATE SET
    -- A user override in the menu is final: the author sniff must never
    -- silently take it back on the next encounter.
    kind = CASE
        WHEN servers.kind_source = 'manual' THEN servers.kind
        WHEN excluded.kind IS NULL THEN servers.kind
        ELSE excluded.kind
    END,
    kind_source = CASE
        WHEN servers.kind_source = 'manual' THEN 'manual'
        ELSE COALESCE(excluded.kind_source, servers.kind_source)
    END,
    host = COALESCE(excluded.host, servers.host),
    root_url = COALESCE(excluded.root_url, servers.root_url),
    last_seen_at = excluded.last_seen_at
RETURNING id, kind, kind_source
]]

--- Insert or refresh the server row for `name`, returning it.
--- `name` is the catalog title from KOReader's OPDS settings — the key both for
--- identity here and for credential lookup in `sources.lua`.
function Catalog.upsertServer(server)
    return Store.first(UPSERT_SERVER,
        server.name, server.kind, server.kind_source,
        server.host, server.root_url, Store.now())
end

function Catalog.serverByName(name)
    return Store.first("SELECT * FROM servers WHERE name = ?;", name)
end

function Catalog.server(id)
    return Store.first("SELECT * FROM servers WHERE id = ?;", id)
end

function Catalog.servers()
    return Store.query("SELECT * FROM servers ORDER BY name;")
end

--- Record a user's explicit choice of server kind, which outranks the sniff.
function Catalog.setServerKind(id, kind)
    Store.exec(
        "UPDATE servers SET kind = ?, kind_source = 'manual' WHERE id = ?;",
        kind, id)
end

--- Undo a manual override, handing the server back to the author sniff.
---
--- `kind_source` has to be cleared along with the kind: `upsertServer` treats
--- 'manual' as final precisely so a browsing session cannot silently undo the
--- user's choice, which means writing only `kind = NULL` would leave a server
--- that is neither overridden nor snifffable.
function Catalog.clearServerKind(id)
    Store.exec(
        "UPDATE servers SET kind = NULL, kind_source = NULL WHERE id = ?;",
        id)
end

--- The language segment to catalogue this server in, or nil if never observed.
---
--- Kept in `meta` rather than as a `servers` column because it is discovered
--- rather than configured, and a column would need a migration for a value that
--- may legitimately never be written. The key is built here so both the writer
--- (ui/open.lua, which sees the user browsing) and the reader (sync.lua, which
--- has no browsing context at all) necessarily agree on it.
---
--- This matters more than it looks: Suwayomi serves several translations under
--- one manga id and selects between them by `lang`. A library-driven sync that
--- defaulted the language would silently catalogue the wrong translation, keyed
--- to the right series.
function Catalog.serverLang(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return Catalog.meta("server:lang:" .. name)
end

function Catalog.setServerLang(name, lang)
    if type(name) ~= "string" or name == "" then
        return false
    end
    if type(lang) ~= "string" or lang == "" then
        return false
    end
    Catalog.setMeta("server:lang:" .. name, lang)
    return true
end

-- Series ----------------------------------------------------------------------

local UPSERT_SERIES = [[
INSERT INTO series (server_id, remote_id, name, name_sort, cover_url, created_at)
VALUES (?, ?, ?, ?, ?, ?)
ON CONFLICT(server_id, remote_id) DO UPDATE SET
    name = excluded.name,
    name_sort = excluded.name_sort,
    cover_url = COALESCE(excluded.cover_url, series.cover_url)
RETURNING id, new_since
]]

--- Returns `{ id, new_since }` and **nothing else** — `RETURNING` names those
--- two columns deliberately, so callers get the identity and the watermark that
--- an upsert cannot recompute, without a second read of a row they usually do
--- not need. Anything else off this table (`remote_id`, `name`, the counters)
--- comes from `series(id)`.
---
--- Not merely a convention: reading `series.remote_id` off this return is a nil
--- concatenation, and it has already cost one device round-trip when a status
--- line did exactly that.
function Catalog.upsertSeries(server_id, series)
    return Store.first(UPSERT_SERIES,
        server_id, series.remote_id, series.name, series.name_sort,
        series.cover_url, Store.now())
end

function Catalog.series(id)
    return Store.first("SELECT * FROM series WHERE id = ?;", id)
end

function Catalog.seriesByRemoteId(server_id, remote_id)
    return Store.first(
        "SELECT * FROM series WHERE server_id = ? AND remote_id = ?;",
        server_id, remote_id)
end

--- Every series on a server, each with the number of unacknowledged items.
--- One query for the whole library view: the alternative is a count per row.
function Catalog.listSeries(server_id)
    return Store.query([[
SELECT s.*,
       (SELECT COUNT(*) FROM items i
         WHERE i.series_id = s.id
           AND i.removed_at IS NULL
           AND i.first_seen_at > COALESCE(s.new_since, 0)) AS new_count,
       (SELECT COUNT(*) FROM items i
         WHERE i.series_id = s.id AND i.removed_at IS NULL) AS item_total
  FROM series s
 WHERE s.server_id = ?
 ORDER BY s.name_sort, s.name;]], server_id)
end

function Catalog.itemCount(series_id)
    return Store.scalar(
        "SELECT COUNT(*) FROM items WHERE series_id = ? AND removed_at IS NULL;",
        series_id) or 0
end

--- Number of items discovered since the user last looked at this series.
function Catalog.newCount(series_id)
    return Store.scalar([[
SELECT COUNT(*) FROM items i
  JOIN series s ON s.id = i.series_id
 WHERE i.series_id = ? AND i.removed_at IS NULL
   AND i.first_seen_at > COALESCE(s.new_since, 0);]], series_id) or 0
end

--- Push the "new" watermark to now. Called when the user actually looks at the
--- series, not when a sync happens to finish.
function Catalog.markSeriesSeen(series_id)
    Store.exec("UPDATE series SET new_since = ? WHERE id = ?;",
        Store.now(), series_id)
end

--- Seed the watermark so the initial import of a series is not one great pile
--- of "new chapters". Called by sync after the *first* successful sync.
function Catalog.acknowledgeInitialSync(series_id)
    Store.exec([[
UPDATE series
   SET new_since = (SELECT COALESCE(MAX(first_seen_at), 0) FROM items WHERE series_id = ?)
 WHERE id = ? AND new_since IS NULL;]], series_id, series_id)
end

function Catalog.deleteSeries(id)
    -- ON DELETE CASCADE takes the items with it (foreign_keys is ON).
    Store.exec("DELETE FROM series WHERE id = ?;", id)
end

--- Whether a *different* series on this server already owns the folder that
--- `series_name` would sanitize to. Feeds `Marker.dirFor`'s
--- `series_folder_claimed`, which only suffixes the book being saved now.
---
--- The test is "has markers", not "has the same name". Two series whose names
--- sanitize alike but neither of which has ever been opened have no folder
--- between them, so claiming on the name alone would suffix *both* — each
--- seeing the other as the claimant — and the collision that was supposed to be
--- avoided would be created instead. Requiring the other series to own files
--- makes the outcome depend on save order, which is the documented rule: the
--- first series to be written keeps the plain name, later ones are suffixed.
---
--- Sanitization happens here rather than at the call site so the comparison is
--- necessarily the same one `dirFor` will make, and with the same cap.
---
--- Removed items count: their marker files are not deleted, so the folder they
--- created is still on disk and still taken.
function Catalog.folderClaimedByOther(server_id, series_name, series_id)
    if not server_id or type(series_name) ~= "string" or series_name == "" then
        return false
    end
    local component = Naming.sanitizeComponent(series_name)
    if component == "stream" then
        return false
    end

    -- `IS NOT` rather than `<>`: it is null-safe, so a nil `series_id` (no
    -- series row yet) degenerates to "id IS NOT NULL" and matches every row.
    local rows = Store.query([[
SELECT s.name
  FROM series s
 WHERE s.server_id = ? AND s.id IS NOT ?
   AND EXISTS (SELECT 1 FROM items i
                WHERE i.series_id = s.id AND i.marker_path IS NOT NULL);]],
        server_id, series_id)

    for _, row in ipairs(rows) do
        if Naming.sanitizeComponent(row.name) == component then
            return true
        end
    end
    return false
end

--- Record a completed sync.
---
--- `item_count` must be the number of **distinct** items, never the number of
--- feed entries walked. Kavita repeats some entries verbatim (151 of 2776 series
--- on the reference instance), so a duplicate-inflated count would make the next,
--- de-duplicated sync trip the implausible-shrink gate in sync.lua and refuse a
--- perfectly healthy result.
function Catalog.recordSyncSuccess(series_id, item_count)
    local now = Store.now()
    Store.exec([[
UPDATE series
   SET item_count = ?, synced_at = ?, last_sync_attempt_at = ?,
       sync_fail_count = 0, sync_error = NULL
 WHERE id = ?;]], item_count, now, now, series_id)
end

--- Record a failed sync. Leaves `item_count` and `synced_at` alone: they
--- describe the last state we actually trusted, and a failure says nothing
--- about the current one.
function Catalog.recordSyncFailure(series_id, message)
    Store.exec([[
UPDATE series
   SET last_sync_attempt_at = ?, sync_fail_count = sync_fail_count + 1, sync_error = ?
 WHERE id = ?;]], Store.now(), message, series_id)
end

-- Items -----------------------------------------------------------------------

local UPSERT_ITEM = string.format([[
INSERT INTO items (series_id, item_key, item_key_source, feed_index,
                   ordinal, ordinal_source, title, display_title, volume_label,
                   template, detail_url, page_count, last_read,
                   first_seen_at, last_seen_at, removed_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
ON CONFLICT(series_id, item_key) DO UPDATE SET
    feed_index      = excluded.feed_index,
    ordinal         = CASE WHEN %s THEN excluded.ordinal ELSE items.ordinal END,
    ordinal_source  = CASE WHEN %s THEN excluded.ordinal_source ELSE items.ordinal_source END,
    title           = excluded.title,
    display_title   = excluded.display_title,
    -- Everything below is only ever overwritten by a value we actually have.
    -- A sync that could not resolve a template must not blank the one stored
    -- from a previous, better-informed sync.
    volume_label    = COALESCE(excluded.volume_label, items.volume_label),
    template        = COALESCE(excluded.template, items.template),
    detail_url      = COALESCE(excluded.detail_url, items.detail_url),
    page_count      = COALESCE(excluded.page_count, items.page_count),
    last_read       = COALESCE(excluded.last_read, items.last_read),
    last_seen_at    = excluded.last_seen_at,
    removed_at      = NULL;]], ADVANCE_ORDINAL, ADVANCE_ORDINAL)

--- Number a list of items 1..N in place, so each carries its position.
---
--- `feed_index` is NOT NULL and drivers deliberately never set it — the engine
--- numbers items, because only the engine knows what the whole of a series is.
--- That makes this the one place the rule can live. It used to live in the
--- sync's `dedupe` alone, and the open path — which builds an item by calling
--- the driver directly and so never passes through `dedupe` — inserted a nil
--- and died on the constraint, after the series row had already been written.
--- Two implementations of one rule is how that happens; there is now one.
---
--- The caller owns what a position means. A sync numbers the deduped walk, so
--- the reading order has no gaps; an open numbers the page it was opened from,
--- which the next sync overwrites unconditionally.
function Catalog.numberPositions(items)
    for index, item in ipairs(items) do
        item.feed_index = index
    end
    return items
end

--- Insert or update a batch of items discovered by a sync, compiling the
--- upsert once. A long series runs to hundreds of chapters, so the difference
--- between this and a prepare per row is a real one on a Kindle.
---
--- `now` is the sync's generation stamp, used verbatim for both timestamps so
--- the sweep can tell "not seen this pass" from "not seen at all".
---
--- Only ever called inside the sync's transaction: a half-applied batch would
--- leave the series with items stamped for a generation that never committed.
function Catalog.upsertItems(series_id, items, now)
    local stmt = Store.prepare(UPSERT_ITEM)
    for _, item in ipairs(items) do
        stmt:bind(series_id, item.item_key, item.item_key_source, item.feed_index,
            item.ordinal, item.ordinal_source, item.title, item.display_title,
            item.volume_label, item.template, item.detail_url, item.page_count,
            item.last_read, now, now)
        stmt:step()
        stmt:clearbind():reset()
    end
    stmt:close()
end

function Catalog.upsertItem(series_id, item, now)
    Catalog.upsertItems(series_id, { item }, now)
end

--- Tombstone everything in the series this sync pass did not touch.
---
--- The comparison is against the pass's own generation stamp, never against
--- "absent from the result set": a truncated walk simply never advances the
--- stamp, so it tombstones nothing.
function Catalog.sweepSeries(series_id, generation)
    -- Counted up front rather than read back from `changes()`: the counter is
    -- connection state that any intervening statement would silently reset,
    -- and this runs inside a transaction, so the two statements cannot drift.
    local doomed = Store.scalar([[
SELECT COUNT(*) FROM items
 WHERE series_id = ? AND removed_at IS NULL AND last_seen_at < ?;]],
        series_id, generation) or 0

    Store.exec([[
UPDATE items SET removed_at = ?
 WHERE series_id = ? AND removed_at IS NULL AND last_seen_at < ?;]],
        Store.now(), series_id, generation)

    return doomed
end

function Catalog.item(id)
    return Store.first("SELECT * FROM items WHERE id = ?;", id)
end

function Catalog.itemByKey(series_id, item_key)
    return Store.first(
        "SELECT * FROM items WHERE series_id = ? AND item_key = ?;",
        series_id, item_key)
end

--- All items of a series in reading order, removed ones included so callers
--- can still work out where a tombstoned item used to sit.
function Catalog.orderedItems(series_id)
    return Store.query(string.format(
        "SELECT * FROM items WHERE series_id = ? ORDER BY %s;", ITEM_ORDER),
        series_id)
end

function Catalog.setMarkerPath(item_id, path)
    Store.exec("UPDATE items SET marker_path = ? WHERE id = ?;", path, item_id)
end

--- Resolve an open book to its catalog row: `server_name` (as stored in the
--- marker) → series → item.
---
--- The natural key is the only authority. `item_id` from the marker is checked
--- against it purely to detect that the database was rebuilt underneath the
--- marker — a rebuilt database can hand a stale rowid to a *different*
--- chapter, so it is never allowed to decide what opens.
---
--- Returns nil when the marker's series was never synced, which is expected and
--- not an error: the marker carries enough to open and read on its own.
function Catalog.resolveMarker(server_name, series_remote_id, item_key, item_id_hint)
    local server = Catalog.serverByName(server_name)
    if not server then
        return nil
    end
    local series = Catalog.seriesByRemoteId(server.id, series_remote_id)
    if not series then
        return nil
    end
    local item = Catalog.itemByKey(series.id, item_key)
    if not item then
        return nil
    end
    if item_id_hint and tonumber(item_id_hint) ~= item.id then
        item.hint_mismatch = true
    end
    return item, series
end

--- Where an item sits in its series, and what to read either side of it.
---
--- `position` counts only readable items, so the series view can say "12 / 240"
--- without post-processing. Neighbours skip tombstones: if the item after this
--- one was deleted upstream, "next" means the next one that still exists.
function Catalog.neighbors(series_id, item_key)
    local items = Catalog.orderedItems(series_id)

    local index
    for i, item in ipairs(items) do
        if item.item_key == item_key then
            index = i
            break
        end
    end
    if not index then
        return nil
    end

    local function step(from, direction)
        for i = from, (direction > 0 and #items or 1), direction do
            if not items[i].removed_at then
                return items[i]
            end
        end
    end

    local position = 0
    for i = 1, #items do
        if not items[i].removed_at then
            position = position + 1
        end
        if i == index then
            break
        end
    end

    return {
        item      = items[index],
        position  = position,
        total     = Catalog.itemCount(series_id),
        previous  = step(index - 1, -1),
        next      = step(index + 1, 1),
    }
end

-- Timestamps ------------------------------------------------------------------

--- A strictly increasing wall-clock stamp.
---
--- `os.time()` has one-second resolution, and several catalog fields are
--- compared with `>` (the "new items" watermark, the removal sweep). Two syncs
--- inside the same second would otherwise compare equal and silently swallow
--- the second one's items.
function Catalog.nextTimestamp()
    local last = tonumber(Store.scalar("SELECT value FROM meta WHERE key = 'last_timestamp';")) or 0
    local stamp = math.max(os.time(), last + 1)
    Store.exec([[
INSERT INTO meta (key, value) VALUES ('last_timestamp', ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;]], tostring(stamp))
    return stamp
end

function Catalog.meta(key)
    return Store.scalar("SELECT value FROM meta WHERE key = ?;", key)
end

function Catalog.setMeta(key, value)
    Store.exec([[
INSERT INTO meta (key, value) VALUES (?, ?)
ON CONFLICT(key) DO UPDATE SET value = excluded.value;]], key, value)
end

return Catalog
