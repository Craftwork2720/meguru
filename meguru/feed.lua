--[[--
Reading a series' canonical feed: walking it, putting it in reading order, and
picking the entry either side of the one being read.

This module is the whole of the engine's network surface for a series, and it
**writes nothing**. It used to be `meguru/sync.lua`, whose job was to walk a
feed and persist the result into a catalog; with the catalog gone the persisting
half has no object, and what is left is a reader. The name follows: "sync"
means keeping two things equal, and nothing here keeps anything equal to
anything.

Three things live here that used to live apart, and they live together because
they answer one question:

  * the `rel=next` walk — the engine's HTTP, with the pagination and the
    completeness rule;
  * reading order (`Feed.ordered` and the selectors over it), which is what
    turns a feed into a sequence;
  * `Feed.neighbor`, which is the one answer callers actually want — the entry
    before or after this one.

Order is shared rather than copied because the same series used to give two
different answers from two different screens: the browser's page is
`number_desc` and the canonical feed is `number_asc`, and whichever function
read the page it happened to hold got the other one's answer. One ordering, one
selector, one neighbour.

Pagination is followed by `rel=next` and never by constructing `?page=N`:
Kavita's next href is a bare query string and Suwayomi's carries `lang`, so a
rebuilt URL would quietly walk a different feed than the one being paged.
--]]

local logger = require("logger")

local Base = require("meguru/driver/base")
local Net = require("meguru/net")
local Sources = require("meguru/sources")

Base.loadDrivers()

local Feed = {}

--- Page cap for one walk. Well past any real series while still bounding a
--- `next` chain that never terminates.
Feed.MAX_PAGES = 25

--- How many pages a walk started by a *tap* may cross.
---
--- A walk is now something a reader waits for — "next chapter" crosses the feed
--- in the gesture that asked for it — and half a minute of frozen e-ink is what
--- a 25-page series costs. Six pages is 600 chapters, well past the point where
--- walking further to find a neighbour is plausible, and it covers Berserk's
--- 403 in five.
Feed.TAP_PAGES = 6

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
--- The engine's HTTP is synchronous and there is no thread to walk on, so the
--- walk has to be able to stop between pages and hand control back to the event
--- loop. `Feed.walk` is this stepper run to completion, which is the right call
--- when the caller is already going to wait; a caller that wants to stay
--- responsive drives the stepper itself.
---
--- `complete` is only ever true when the walk reached the end of the chain.
--- Everything else — a non-200, an unparseable body, the page cap, a `next`
--- pointing back at a page already visited, a cancellation — leaves it false,
--- and `reason` says which.
local Walker = {}
Walker.__index = Walker

function Feed.walker(url, opts)
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
    if self.count >= (opts.max_pages or Feed.MAX_PAGES) then
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
        -- Forwarded so a caller walking on the reader's behalf can ask for the
        -- short preset. `Net.RESUME_*` (4s/8s) instead of `Net.FEED_*` (10s/30s)
        -- is what keeps a slow server from holding the screen through a tap.
        -- Default unchanged: nil here is still `"feed"` inside `Net.fetchFeed`.
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
function Feed.walk(url, opts)
    local walker = Feed.walker(url, opts)
    while walker:step() do end
    return walker.pages, walker.complete, walker.reason, walker.count
end

--- Every item the walk's pages describe, in feed order, deduped.
---
--- Kavita emits some chapters twice, byte for byte. Collapsing them here keeps
--- the count a caller reports honest, and keeps a duplicate from being offered
--- as a neighbour of itself.
---
--- **Deliberately not numbered.** A position used to be assigned here, because
--- the catalog stored one; nothing stores one now, and the order a caller needs
--- is `Feed.ordered`'s, which reads the server's own list position rather than
--- the arrival order of a page that may be descending.
function Feed.collect(walker, plan)
    local seen, unique, duplicates = {}, {}, 0
    for _, page in ipairs(walker.pages or {}) do
        for _, item in ipairs(plan.driver.parseCatalogPage(
                page.feed, page.url, plan.ctx) or {}) do
            if item.item_key and not seen[item.item_key] then
                seen[item.item_key] = true
                unique[#unique + 1] = item
            else
                duplicates = duplicates + 1
            end
        end
    end
    return unique, duplicates
end

-- Reading order ---------------------------------------------------------------

--- A parsed page put into reading order, plus how much of it that order covers.
---
--- **Order from the server's own list position, which is in the path.** A
--- Suwayomi entry links to `/series/{id}/chapter/{n}/metadata`, and `{n}` is the
--- position on the server's list — that is, its reading order. The title is a
--- fallback only, and a poor one: `Prologue 1` carries no chapter token at all,
--- so numbering by title parked it *after* every numbered chapter, when a
--- prologue belongs before them. Kavita has no path to use (its entries link to
--- no metadata feed), and its canonical feed is already in reading order, so
--- there the feed order is the right answer and is what is left.
---
--- Returns the sequence and `positioned`, the length of its ordered prefix.
--- Everything after index `positioned` had no position anywhere and is in feed
--- order. Callers that need "earlier"/"later" must not read past `positioned`
--- without meaning to: feed order is *not* reading order in general, and for
--- Suwayomi it is its exact reverse.
---
--- Extracted from `firstUnread` rather than copied, because the consumer that
--- was missing it is the bug this exists for. `freshResumeTarget` picked the
--- furthest-read chapter by *feed* order, which is right on the canonical feed
--- and backwards on the page the browser holds — the same series, the same
--- question, two opposite answers depending on which screen asked. Sharing the
--- ordering is what keeps them from disagreeing again.
function Feed.ordered(parsed)
    local Naming = require("meguru/naming")
    local ordered, fallback_position = {}, {}
    for index, item in ipairs(parsed or {}) do
        local path_position = type(item.detail_url) == "string"
            and tonumber(item.detail_url:match("/chapter/(%d+)/")) or nil
        local _, _, title_number = Naming.deriveSeries(item.title or "")
        local position = path_position or title_number
        if position then
            ordered[#ordered + 1] = { item = item, position = position }
        else
            fallback_position[#fallback_position + 1] = { item = item, index = index }
        end
    end
    table.sort(ordered, function(a, b) return a.position < b.position end)

    local sequence = {}
    for _, entry in ipairs(ordered) do
        sequence[#sequence + 1] = entry.item
    end
    local positioned = #sequence
    -- No position anywhere: the feed's own order, which is reading order for the
    -- server whose feeds are built that way.
    table.sort(fallback_position, function(a, b) return a.index < b.index end)
    for _, entry in ipairs(fallback_position) do
        sequence[#sequence + 1] = entry.item
    end

    return sequence, positioned
end

--- Has this chapter been read to its own last page?
---
--- The page counter is the only evidence a Kavita-style feed carries, so
--- "finished" can only mean `last_read >= page_count` here.
---
--- **A chapter with no count is unfinished, not finished.** Offering a chapter
--- again is a smaller mistake than skipping past one, and a Suwayomi entry has
--- no count at all until its stream is resolved — so the alternative would
--- silently treat every unopened Suwayomi chapter as done.
function Feed.isFinished(item)
    local total = tonumber(item.page_count) or tonumber(item.progress_total)
    local read = tonumber(item.last_read)
    return (total and read and read >= total) and true or false
end

--- The first entry in reading order the server has not finished, or nil.
---
--- Takes no account of `positioned`, like `firstIn`: this reads *forward*, and
--- the unpositioned tail sits at the *end* of the sequence, so it cannot win
--- from this direction — there is nothing to guard against.
---
--- Returns nil when every entry is finished, and the two callers want opposite
--- things from that: `firstUnread` (the row above a series feed) says so and
--- stops, while `firstUnfinishedOrLast` below treats it as "this reader is at
--- the end" and names the last chapter instead.
function Feed.firstUnfinished(sequence, _positioned)
    for _, item in ipairs(sequence) do
        if not Feed.isFinished(item) then
            return item
        end
    end
    return nil
end

--- The last entry in reading order.
---
--- Two passes, and the order of the passes is the point: the ordered prefix is
--- reading order, so its last entry is the furthest along; the unpositioned tail
--- is *feed* order, and is only consulted when nothing was positioned at all.
--- For Suwayomi that tail is empty — every chapter entry is positioned, by its
--- `rel=subsection` link or by its stream — so the second pass is dead code
--- there, and it exists for Kavita, whose feed order is reading order and where a
--- chapter whose title carries no number is perfectly ordinary.
function Feed.lastIn(sequence, positioned)
    for pass = 1, 2 do
        local first, last
        if pass == 1 then
            first, last = 1, positioned
        else
            first, last = positioned + 1, #sequence
        end
        if last >= first then
            return sequence[last]
        end
    end
    return nil
end

--- Where the reader carries on: the first chapter not finished, or the last one.
---
--- **The second half is not decoration.** A series read to the end has nothing
--- unfinished, and "nowhere to continue" is not the answer this button is for —
--- the reader who finished chapter 177 and taps again is at chapter 177, and a
--- button that vanished would be telling them the series is empty.
---
--- This is the default for `freshResumeTarget`, so it is what Kavita gets on its
--- own feed and what a Suwayomi series gets on the canonical feed when the
--- server reports nothing unread.
function Feed.firstUnfinishedOrLast(sequence, positioned)
    return Feed.firstUnfinished(sequence) or Feed.lastIn(sequence, positioned)
end

--- The earliest entry of a feed that already contains only what we want.
---
--- **The same question as `firstUnfinished` above, answered by the server
--- instead of inferred.** This one is handed a feed the server already filtered
--- to the chapters it flags *unread* (`Suwayomi.unreadFilter`), where every entry
--- qualifies by construction and the answer is simply the earliest one.
---
--- Why not just ask `firstUnfinished` there too: on a filtered feed the two
--- usually agree, and where they disagree the *server* is right. A chapter the
--- server flags unread whose page counter happens to read full — the two axes
--- genuinely do disagree, which is the whole reason `unreadFilter` exists — would
--- be skipped by the page-count predicate and offered by this one. The flag is
--- what the reader sees in the server's own UI, so the flag wins.
function Feed.firstIn(sequence, _positioned)
    return sequence[1]
end

--- The entry before or after `item_key` in a sequence already in reading order.
---
--- Returns nil when the key is not in the sequence at all, which is the honest
--- answer: a caller asking for a neighbour of something this feed does not list
--- has no neighbour to be given, and guessing one from position would offer a
--- chapter the reader did not ask for.
---
--- `which` is `"next"` or `"previous"`. Walking the sequence rather than
--- scanning a stored list is the whole difference from the old design: a feed
--- that has moved on cannot leave a stale neighbour behind.
function Feed.neighbor(sequence, item_key, which)
    if type(item_key) ~= "string" or item_key == "" then
        return nil
    end
    local index
    for i, item in ipairs(sequence or {}) do
        if item.item_key == item_key then
            index = i
            break
        end
    end
    if not index then
        return nil
    end
    return sequence[which == "previous" and (index - 1) or (index + 1)]
end

-- Planning --------------------------------------------------------------------

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

--- Everything a walk needs before it can start: which driver, whose credentials,
--- the canonical feed URL, and the driver's context.
---
--- `opts.on_failure` is called with a message for each way of refusing, and it
--- is **required by the caller rather than done here**: this module writes
--- nothing and knows nothing to write to. A refusal still has to leave a trace —
--- an unknown kind and an unconfigured server fail identically from the reader's
--- side, and each needs a different fix — so the caller decides where the trace
--- goes.
---
--- Returns `plan, nil` or `nil, reason`.
function Feed.plan(server, opts)
    opts = opts or {}
    local function refuse(reason)
        if opts.on_failure then
            opts.on_failure(reason)
        end
        return nil, reason
    end

    local driver = Base.forKind(server and server.kind)
    if not driver then
        return refuse("unknown server kind")
    end

    local conn = Sources.connection(server.name)
    local base = conn and baseURL(conn.url)
    if not base then
        return refuse("server not configured")
    end

    -- `lang` is remembered per server by whatever saw the reader browsing, which
    -- is the only place it can be learned: a walk with no browsing context and a
    -- driver's own default would fetch the wrong translation of a Suwayomi manga
    -- while still keying it to the right series. `opts.lang` is the caller's, and
    -- its absence is the driver's default.
    local ctx = { lang = opts.lang }
    local url = driver.catalogURL(base, opts.remote_id, ctx)
    if type(url) ~= "string" or url == "" then
        return refuse("no catalog feed for this series")
    end

    return {
        driver = driver,
        ctx    = ctx,
        url    = url,
        -- Ready for `Feed.walker`, so no caller rebuilds the credentials (and
        -- cannot pass the wrong server's).
        walker_opts = {
            username     = conn.username,
            password     = conn.password,
            max_pages    = opts.max_pages,
            on_page      = opts.on_page,
            is_cancelled = opts.is_cancelled,
            timeout      = opts.timeout,
        },
    }
end

--- Resolve the page stream for an item, refreshing it from the server when the
--- driver needs to.
---
--- For Suwayomi this is a correctness requirement rather than an optimisation:
--- the stored template carries a chapter position that the server can renumber,
--- and a stale one fetches a *different chapter* while still answering 200. The
--- stored `template` remains the offline fallback, which is why a caller only
--- reaches here with a network to reach it on.
function Feed.resolveStream(item, server, opts)
    opts = opts or {}
    local driver = server and Base.forKind(server.kind)
    if not driver then
        -- Both of the early returns here hand back the stored template, which is
        -- NULL for every lazy item — and those are exactly the items that need
        -- this function. So the failure otherwise surfaces three frames away as
        -- "no page stream", with nothing naming the cause. Kavita items never
        -- notice: their template is stored, so the early return is a success by
        -- accident.
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
    -- Could not refresh: fall back to the stored template rather than failing to
    -- open a book that can still be read.
    return item.template, item.page_count
end

return Feed
