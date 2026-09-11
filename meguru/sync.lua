--[[--
Syncing a series: walking its canonical feed and writing the result.

The split that matters here is between **walking** and **applying**. A walk is
pure network and touches no database; an apply is one transaction and touches no
network. A Kindle walk takes tens of seconds, and WAL serializes writers anyway,
so holding the write lock across it would block every other plugin instance for
no benefit.

Three rules make a partial walk harmless, and all three have to hold together:

  * `complete` is conservative — false for a non-200, an unparseable body, the
    page cap, or a `next` pointing back at a page already visited. A walk that
    is not complete writes nothing at all.
  * The removal sweep compares against the pass's own generation stamp, never
    against "absent from the result". A truncated walk never advances the stamp,
    so it can never tombstone anything.
  * `item_count` is recomputed from the distinct items written, so the
    implausible-shrink gate compares like with like.

This module is deliberately free of UI and of `UIManager`. It reports progress
and takes a cancellation check through `opts`, so the same code drives both a
blocking call from a console session and a repainting widget scheduled one page
per `nextTick`.
--]]

local logger = require("logger")

local Base = require("meguru/driver/base")
local Catalog = require("meguru/catalog")
local Net = require("meguru/net")
local Sources = require("meguru/sources")
local Store = require("meguru/store")

Base.loadDrivers()

local Sync = {}

--- Page cap for one walk. Well past any real series (the reference Kavita
--- instance paginates 20 series per page across 2776 series, so ~139 pages for
--- a whole library) while still bounding a `next` chain that never terminates.
Sync.MAX_PAGES = 25

--- How long a synced series is considered fresh. Opening a series inside this
--- window does not re-sync it, so browsing a library is not a stampede of
--- requests.
Sync.DEFAULT_TTL = 6 * 3600

--- A sync that finds less than this fraction of the last known item count is
--- treated as a truncated response rather than as mass deletion. A real
--- upstream purge of more than half a series in one go is far rarer than an
--- expired session answering 200 with a short body.
Sync.MIN_SHRINK = 0.5

--- Cap on the retry backoff after repeated failures.
Sync.MAX_BACKOFF = 24 * 3600

-- Walking ---------------------------------------------------------------------

local function nextLink(feed, page_url)
    local url = require("socket.url")
    for _, link in ipairs(type(feed.link) == "table" and feed.link or {}) do
        if type(link) == "table" and link.rel == "next"
            and type(link.href) == "string" and link.href ~= "" then
            return url.absolute(page_url, link.href)
        end
    end
    return nil
end

--- A resumable `rel=next` walk, one page per `step()`.
---
--- Pagination is followed by link and never by constructing `?page=N`: Kavita's
--- next href is a bare query string and Suwayomi's carries `lang`, so a rebuilt
--- URL would quietly walk a different feed than the one being paged.
---
--- The engine's HTTP is synchronous and there is no thread to walk on, so the
--- walk has to be able to stop between pages and hand control back to the event
--- loop — half a minute of frozen e-ink is what a blocking walk of a 25-page
--- series costs. `Sync.walk` is this stepper run to completion, and that is the
--- right call from a console session; the UI drives the stepper directly.
---
--- `complete` is only ever true when the walk reached the end of the chain.
--- Everything else — a non-200, an unparseable body, the page cap, a `next`
--- pointing back at a page already visited, a cancellation — leaves it false,
--- and `reason` says which.
local Walker = {}
Walker.__index = Walker

function Sync.walker(url, opts)
    return setmetatable({
        url      = url,
        opts     = opts or {},
        visited  = {},
        pages    = {},
        count    = 0,
        -- The URL of the next page to fetch, or nil at the end of the chain.
        current  = url,
    }, Walker)
end

--- Fetch one page. Returns true while there is more work.
function Walker:step()
    if self.finished then
        return false
    end
    local opts = self.opts

    local function stop(complete, reason)
        self.finished, self.complete, self.reason = true, complete, reason
        return false
    end

    if not self.current then
        return stop(true, nil)
    end
    if self.visited[self.current] then
        -- A `next` chain that loops would otherwise page forever between two
        -- feeds.
        return stop(false, "next-loop")
    end
    if self.count >= (opts.max_pages or Sync.MAX_PAGES) then
        return stop(false, "page-cap")
    end
    if opts.is_cancelled and opts.is_cancelled() then
        return stop(false, "cancelled")
    end
    self.visited[self.current] = true

    local page_url = self.current
    local feed, reason = Net.fetchFeed(page_url, {
        username = opts.username,
        password = opts.password,
        -- Forwarded so a caller walking on the *reader's* behalf rather than on
        -- the sync's can ask for the short preset. A sync is a background job
        -- and may spend the long one; the row at the top of a series feed is a
        -- tap, and `Net.RESUME_*` (4s/8s) instead of `Net.FEED_*` (10s/30s) is
        -- what keeps a slow server from holding the screen. Default unchanged:
        -- nil here is still `"feed"` inside `Net.fetchFeed`.
        timeout = opts.timeout,
    })
    self.count = self.count + 1
    if not feed then
        return stop(false, reason or "network")
    end

    -- The URL is kept alongside the feed because entry hrefs resolve against
    -- *their own* page: a later page need not share the first one's path.
    self.pages[#self.pages + 1] = { feed = feed, url = page_url }
    if opts.on_page then
        opts.on_page(self.count, page_url)
    end

    self.current = nextLink(feed, page_url)
    if not self.current then
        return stop(true, nil)
    end
    return true
end

--- Walk `url` to the end in one call. Returns `pages, complete, reason, count`.
function Sync.walk(url, opts)
    local walker = Sync.walker(url, opts)
    while walker:step() do end
    return walker.pages, walker.complete, walker.reason, walker.count
end

-- Applying --------------------------------------------------------------------

--- Collapse repeated item keys, keeping the first occurrence and numbering the
--- survivors from 1.
---
--- Kavita emits some chapters twice, byte for byte, and the uniqueness
--- constraint would collapse them at insert anyway — but `feed_index` is
--- assigned here, and duplicating a position would leave gaps in the reading
--- order. Doing it explicitly also means the item count and the shrink gate see
--- the same number the database will end up holding.
local function dedupe(items)
    local seen, unique, duplicates = {}, {}, 0
    for _, item in ipairs(items) do
        if item.item_key and not seen[item.item_key] then
            seen[item.item_key] = true
            unique[#unique + 1] = item
        else
            duplicates = duplicates + 1
        end
    end
    -- Numbered after deduping, never before: a duplicated position would leave
    -- a gap in the reading order.
    Catalog.numberPositions(unique)
    return unique, duplicates
end

--- Write a completed walk for one series, in a single transaction.
---
--- `generation` is the pass's stamp: items are written with `last_seen_at`
--- set to it, and the sweep tombstones whatever is still older. That is what
--- makes the write order-independent and a truncated walk inert.
function Sync.apply(series, items, generation)
    Store.transaction(function()
        Catalog.upsertItems(series.id, items, generation)
        Catalog.sweepSeries(series.id, generation)
        -- After the upserts: #items is the number of live rows the sweep leaves
        -- behind, which is exactly what the shrink gate must compare against.
        Catalog.recordSyncSuccess(series.id, #items)
        -- The first sync of a series is an import, not a pile of new chapters.
        Catalog.acknowledgeInitialSync(series.id)
    end)
end

-- Planning --------------------------------------------------------------------

--- Exponential backoff, capped. A server that is down stays down for a while,
--- and retrying it on every library browse helps nobody.
function Sync.backoffSeconds(fail_count)
    local exponent = math.min(fail_count, 10)
    return math.min(2 ^ exponent * 60, Sync.MAX_BACKOFF)
end

--- Whether a series is due for a sync, and why not when it is not.
---
--- Pure: it reads the series row it is given and nothing else. Callers are
--- responsible for the two conditions that are not about the series — that the
--- user asked for it, and that the network is up.
function Sync.plan(series, opts)
    opts = opts or {}
    if opts.force then
        return true
    end
    local now = Store.now()
    local ttl = opts.ttl or Sync.DEFAULT_TTL

    if series.synced_at and (now - series.synced_at) < ttl then
        return false, "fresh"
    end

    local failures = series.sync_fail_count or 0
    if failures > 0 and series.last_sync_attempt_at then
        local wait = Sync.backoffSeconds(failures)
        if (now - series.last_sync_attempt_at) < wait then
            return false, "backoff"
        end
    end
    return true
end

-- Running ---------------------------------------------------------------------

--- The catalog root to build fetch URLs from: the URL the user configured minus
--- any trailing slash, so joining a path never doubles it.
local function baseURL(configured_url)
    if type(configured_url) ~= "string" or configured_url == "" then
        return nil
    end
    return (configured_url:gsub("/+$", ""))
end

--- A `fetch(url) -> feed` closure bound to one server's credentials, for
--- drivers whose streams need an extra request. This is the only I/O a driver
--- ever causes, and it happens through here so credentials, timeouts and log
--- redaction stay in the engine.
local function makeFetch(conn)
    return function(url_str)
        if type(url_str) ~= "string" or url_str == "" then
            return nil
        end
        local feed = Net.fetchFeed(url_str, {
            username = conn.username,
            password = conn.password,
        })
        return feed
    end
end

--- Everything a sync needs before it can start walking: which driver, whose
--- credentials, the canonical feed URL, and the driver's context.
---
--- Split out from `Sync.run` because a synced walk has three separable parts —
--- decide, walk, apply — and only the middle one is long. The UI drives the
--- walk itself, one page per tick, and calls `Sync.finish` at the end; `run` is
--- the three of them back to back for callers that can afford to block.
---
--- Records the failure on the series row before returning nil: every reason to
--- refuse here (an unknown kind, a server that is not configured) is a
--- condition only a re-attempt or a fix can clear, and the backoff should start
--- counting now.
---
--- Returns `plan, nil` or `nil, reason, summary`.
function Sync.prepare(server, series, opts)
    opts = opts or {}
    local summary = { pages = 0, items = 0, duplicates = 0 }

    local driver = Base.forKind(server.kind)
    if not driver then
        Catalog.recordSyncFailure(series.id, "unknown server kind")
        return nil, "unknown server kind", summary
    end

    local conn = Sources.connection(server.name)
    local base = conn and baseURL(conn.url)
    if not base then
        Catalog.recordSyncFailure(series.id, "server not configured")
        return nil, "server not configured", summary
    end

    -- The driver's context. `lang` is remembered per server by ui/open.lua,
    -- which is the only place that sees the user browsing and can therefore
    -- learn it: a sync driven from the library view has no browsing context,
    -- and a driver's own default would catalogue the wrong translation of a
    -- Suwayomi manga while still keying it to the right series.
    local ctx = {
        lang = opts.lang or Catalog.serverLang(server.name),
    }
    local url = driver.catalogURL(base, series.remote_id, ctx)
    if type(url) ~= "string" or url == "" then
        Catalog.recordSyncFailure(series.id, "no catalog feed for this series")
        return nil, "no catalog feed for this series", summary
    end

    return {
        driver = driver,
        ctx    = ctx,
        url    = url,
        -- Ready for `Sync.walker`, so neither caller rebuilds the credentials
        -- (and cannot pass the wrong server's).
        walker_opts = {
            username     = conn.username,
            password     = conn.password,
            max_pages    = opts.max_pages,
            on_page      = opts.on_page,
            is_cancelled = opts.is_cancelled,
        },
    }, nil, summary
end

--- Turn a completed walk into catalog writes.
---
--- `walker` is a finished `Sync.walker` and `plan` the table `Sync.prepare`
--- returned. Nothing is written unless the walk was complete: a walk cut short
--- says nothing about what the series contains, and writing it would tombstone
--- everything it never reached.
function Sync.finish(series, walker, plan)
    local summary = { pages = walker.count, items = 0, duplicates = 0 }
    if not walker.complete then
        local reason = walker.reason
        -- A cancellation is the user's decision, not the server's fault. It
        -- still writes nothing, but it must not count towards the backoff: a
        -- few impatient cancels would otherwise push the next automatic attempt
        -- out by the better part of a day.
        if reason == "cancelled" then
            return nil, reason, summary
        end
        Catalog.recordSyncFailure(series.id, "incomplete walk: " .. tostring(reason))
        return nil, reason, summary
    end

    local collected = {}
    for _, page in ipairs(walker.pages) do
        for _, item in ipairs(plan.driver.parseCatalogPage(
                page.feed, page.url, plan.ctx) or {}) do
            collected[#collected + 1] = item
        end
    end

    local items, duplicates = dedupe(collected)
    summary.items, summary.duplicates = #items, duplicates

    local previous = series.item_count or 0
    if previous > 0 and #items < previous * Sync.MIN_SHRINK then
        local message = string.format("implausible shrink: %d items, had %d",
            #items, previous)
        logger.warn("Meguru:", series.name, "-", message)
        Catalog.recordSyncFailure(series.id, message)
        return nil, "shrink", summary
    end

    Sync.apply(series, items, Catalog.nextTimestamp())
    logger.info("Meguru: synced", series.name, "-", #items, "items in",
        walker.count, "page(s)")
    return true, nil, summary
end

--- Sync one series end to end, blocking.
---
--- Returns `true, summary` on success or `nil, reason, summary` on failure.
--- Failure is recorded on the series row and is never fatal: a sync is a
--- background improvement to a catalog that the user can read without.
function Sync.run(server, series, opts)
    local plan, reason, summary = Sync.prepare(server, series, opts)
    if not plan then
        return nil, reason, summary
    end
    local walker = Sync.walker(plan.url, plan.walker_opts)
    while walker:step() do end
    return Sync.finish(series, walker, plan)
end

--- Resolve the page stream for an item, refreshing it from the server when the
--- driver needs to.
---
--- Called on every open, not once: for Suwayomi this is a correctness
--- requirement, since the stored template carries a chapter position that can
--- change. The stored `template` remains the offline fallback, which is why the
--- engine only calls this when there is a catalog and a network to call it on.
function Sync.resolveStream(item, server, opts)
    opts = opts or {}
    local driver = server and Base.forKind(server.kind)
    if not driver then
        -- Both of these return the stored template *before* any driver runs, and
        -- the stored template is NULL for every lazy item — which is exactly the
        -- items that need this function. So the failure surfaces three frames
        -- away as "no page stream", with nothing naming the cause. Kavita items
        -- never notice: their template is stored, so the early return is a
        -- success by accident.
        logger.warn("Meguru: no driver for server", tostring(server and server.name),
            "(kind=" .. tostring(server and server.kind) .. ")",
            "- cannot resolve the stream for", item.title)
        return item.template, item.page_count
    end
    local conn = Sources.connection(server.name)
    if not conn then
        logger.warn("Meguru: no configured catalog named",
            tostring(server and server.name), "in settings/opds.lua")
        return item.template, item.page_count
    end
    local template, count = driver.resolveStream(item, makeFetch(conn), opts)
    if template then
        return template, count or item.page_count
    end
    -- Could not refresh: fall back to whatever the last sync stored rather than
    -- failing to open a book that can still be read.
    return item.template, item.page_count
end

return Sync
