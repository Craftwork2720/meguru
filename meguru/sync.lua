--[[--
The half of the old sync that writes: turning a completed walk into catalog
rows, and deciding whether a series is due for one.

**The walking half moved to `meguru/feed.lua`**, which writes nothing and knows
nothing about a catalog. What is left here is the part that cannot exist without
a database — one transaction per series, the generation sweep, the failure
counters — and it is on its way out with the catalog itself. Anything that only
needs to *read* a feed should reach for `Feed`, not for this.

Kept as a separate module meanwhile so the transition is one deletion at a time:
the walk, the ordering and the neighbour selection are already database-free, so
when the catalog goes, `Sync` goes whole and `Feed` stays.
--]]

local logger = require("logger")

local Catalog = require("meguru/catalog")
local Feed = require("meguru/feed")
local Store = require("meguru/store")

local Sync = {}

--- A sync that finds less than this fraction of the last known item count is
--- treated as a truncated response rather than as mass deletion. A real
--- upstream purge of more than half a series in one go is far rarer than an
--- expired session answering 200 with a short body.
Sync.MIN_SHRINK = 0.5

--- Cap on the retry backoff after repeated failures.
Sync.MAX_BACKOFF = 24 * 3600

--- How long a synced series is considered fresh.
Sync.DEFAULT_TTL = 6 * 3600

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
    end)
end

--- Exponential backoff, capped. A server that is down stays down for a while,
--- and retrying it on every library browse helps nobody.
function Sync.backoffSeconds(fail_count)
    local exponent = math.min(fail_count, 10)
    return math.min(2 ^ exponent * 60, Sync.MAX_BACKOFF)
end

--- Whether a series is due for a sync, and why not when it is not.
---
--- Pure: it reads the series row it is given and nothing else — which is why
--- `opts.ttl` is passed *in* rather than read from `settings` here. The
--- preference is the caller's to look up; a function that consulted a global
--- would plan the same row differently in two runs, and a gate that cannot be
--- reasoned about from its arguments is not a gate.
---
--- Named `due` rather than `plan` because `Feed.plan` builds a *walk*, and the
--- two would otherwise be read as the same thing. This one only says whether
--- the walk is worth starting.
---
--- Callers are responsible for the two conditions that are not about the series:
--- that it is worth asking for, and that the network is up. On the background
--- path that second one is load-bearing rather than decorative — a walk that
--- starts and fails because the wifi dropped is recorded as a *server* failure,
--- and pushes the series into backoff for something the server did not do.
---
--- `opts.force` skips the backoff as well as the TTL, so it is not for a caller
--- who merely wants the walk to happen: it is for a caller who has decided the
--- backoff does not apply.
function Sync.due(series, opts)
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

--- `Feed.plan`, with this series' failures recorded on its row.
---
--- Split out from `Feed.plan` because the recording is the one thing the engine
--- cannot do without a catalog: every reason to refuse (an unknown kind, a
--- server that is not configured) is a condition only a re-attempt or a fix can
--- clear, and the backoff should start counting now.
---
--- Returns `plan, nil` or `nil, reason`.
function Sync.prepare(server, series, opts)
    opts = opts or {}
    return Feed.plan(server, {
        remote_id    = series.remote_id,
        lang         = opts.lang,
        max_pages    = opts.max_pages,
        on_page      = opts.on_page,
        is_cancelled = opts.is_cancelled,
        timeout      = opts.timeout,
        on_failure   = function(reason)
            Catalog.recordSyncFailure(series.id, reason)
        end,
    })
end

--- Turn a completed walk into catalog writes.
---
--- `walker` is a finished `Feed.walker` and `plan` the table `Sync.prepare`
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
        -- Said out loud, and not only written into `sync_error`. A walk started
        -- in the background has no popup to report through, so without this line
        -- a failure would leave no trace anywhere the reader or a log reader
        -- could find it.
        logger.warn("Meguru: sync of", series.name, "did not complete -",
            tostring(reason))
        Catalog.recordSyncFailure(series.id, "incomplete walk: " .. tostring(reason))
        return nil, reason, summary
    end

    local items, duplicates = Feed.collect(walker, plan)
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
function Sync.run(server, series, opts)
    local plan, reason = Sync.prepare(server, series, opts)
    if not plan then
        return nil, reason, { pages = 0, items = 0, duplicates = 0 }
    end
    local walker = Feed.walker(plan.url, plan.walker_opts)
    while walker:step() do end
    return Sync.finish(series, walker, plan)
end

return Sync
