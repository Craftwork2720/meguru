--[[--
The "Meguru this series" flow: a browsed OPDS entry becomes a marker file and a
catalog row.

The old plugin captured the whole series context here — a sibling list, this
volume's index, per-entry labels — and froze it into the marker, because the
displayed feed was the only place that information existed. That is what the
catalog replaces, and it is why this module is now small: the series context
comes from the series' own canonical feed, not from whatever page the user
happened to be on.

Two jobs, then:

  * register the book — server, series and item — so a later sync has something
    to attach to and the book has neighbours;
  * write a marker thin enough to open the stream with no database at all.

Registering a book does not walk the series feed — that is `sync.lua`, it costs
tens of seconds, and it must never sit between a tap and a book opening. It does
**not** walk before opening; `openAsBook` starts one *after* the handoff, in the
background and silently, which is the difference between a delay and a
consequence. See `startBackgroundSync` for why it is worth starting at all.
Two walks do happen here, both deliberate and both bounded rather than
oversights. **`seriesItems` below** runs on a tap, because the row at the top of
a series feed cannot answer "first unread chapter" from the page on screen; it is
bounded by a small page cap and the short `Net.RESUME_*` timeouts, and its
comment is where the bound is argued. **`startBackgroundSync`** runs after the
handoff, because the alternative is a series the catalog knows one book of — and
that is not a walk *here* so much as a walk `SyncJob` runs on a tick while the
reader reads.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local Base = require("meguru/driver/base")
local Catalog = require("meguru/catalog")
local FS = require("meguru/fs")
local Marker = require("meguru/marker")
local Naming = require("meguru/naming")
local Net = require("meguru/net")
local PSE = require("meguru/pse")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")
local Sync = require("meguru/sync")
local SyncJob = require("meguru/ui/syncjob")

Base.loadDrivers()

local Open = {}

--- The last feed each catalog displayed, keyed by catalog title:
--- `{ url = ..., feed = <raw parsed Atom> }`.
---
--- Not a cache for speed. `OPDSBrowser` reduces every entry to a title, an
--- author and a list of acquisitions, discarding the entry `<id>` and its
--- `<link>` array — and a driver needs both to say which series and which item a
--- book is. Kavita's stream URL happens to carry its own `seriesId` and
--- `chapterId`, but Suwayomi's chapter URN exists nowhere else, so without this
--- the book could never be matched to its catalog row.
---
--- One feed per catalog, replaced as the user navigates, so it cannot grow.
local last_feed = {}

--- Server kinds sniffed from the feed-level `<author>` this session, keyed by
--- catalog title. Never persisted — `servers.kind` is the durable record, and
--- this only covers a server no book has been opened from yet.
local sniffed = {}

--- A FileManager plugin instance to fall back on when the built-in browser's
--- own open path is unreachable (set by main.lua).
local fallback_host = nil

function Open.setFallbackHost(widget)
    if widget and widget.ui and not widget.ui.document then
        fallback_host = widget
    end
end

--- The marker path this module last handed to a reader, or nil.
---
--- **A one-shot keyed on the file, and it is the whole fix for the dialog that
--- asks twice.** Handing a marker over runs `ReaderUI:showReader`, which
--- `hook.lua` wraps, and the wrap's job is to ask where to start — for an open
--- that had no other moment to ask in. An open that came through `offerResume`
--- has already had that moment: the dialog was answered, or was deliberately not
--- built, a few statements earlier. Without this the reader gets the same dialog
--- again, and again, because `openCatalogItem` -> `handToReader` ->
--- `switchDocument` -> `showReader` -> `offerResumeForFile` rebuilds it. The
--- `once` guard inside `offerResume` cannot stop that, because `once` makes one
--- dialog act once, and this is a *second* dialog.
---
--- The shape is a one-shot keyed on the path, and both halves are load-bearing:
---
---   * **One-shot, not a set and not a time window.** The re-entry being
---     suppressed is synchronous — `switchDocument` calls `showReader` in the
---     same statement — and a per-session set of "files we have opened" cannot
---     tell it apart from reopening the same book from History ten minutes
---     later, which *must* ask: the reader may have read on, and the server may
---     have moved. A timestamp cannot either, since the reopen that has to be
---     asked about is exactly the one that happens seconds after a close.
---   * **Keyed on the path, so it can only suppress the open it was armed for.**
---     The wrap receives a file and compares; a bare "we are opening something"
---     flag would swallow an unrelated open.
local handed_off = nil

--- Arm the one-shot for `file`, immediately before handing it to a reader.
function Open.noteHandoff(file)
    handed_off = file
end

--- Read the one-shot and clear it, in that order. Returns the path armed, or nil.
---
--- Read-and-clear rather than read is what bounds the leak: one record can
--- suppress at most one open, and any later call to the wrap clears it whatever
--- that open turns out to be.
function Open.takeHandoff()
    local file = handed_off
    handed_off = nil
    return file
end

-- What the browser saw --------------------------------------------------------

local function catalogTitle(browser)
    local name = browser and browser.root_catalog_title
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return name
end

--- The URL of the page the user is looking at. `paths[#]` is the displayed
--- feed: the entry being acted on came from it.
--- Keep the raw Atom of the feed the browser just parsed.
---
--- Called from the `parseFeed` wrap, which the browser runs on every navigation,
--- so this is the feed `showDownloads` will later be acting on.
---
--- **The search descriptor is the case that is easy to get wrong.** The browser
--- does not only parse browsable feeds through this method:
--- `OPDSBrowser:genItemTableFromCatalog` parses the catalog's OpenSearch
--- descriptor through it too, on the same navigation, immediately *after* the
--- real feed. So a rule of "record it if it has entries, clear it otherwise"
--- recorded the series feed and then cleared it again microseconds later — which
--- is why the record was empty for every catalog, every time, and why every book
--- came out with no catalog identity. The failure is silent by construction: the
--- book opens and reads either way, so the only symptom is a next chapter that
--- never appears.
---
--- A navigable feed that genuinely has no entries still clears, which is what the
--- original rule was reaching for: an entry matched against the wrong feed is
--- worse than no match.
function Open.noteFeed(browser, feed_url, catalog)
    local name = catalogTitle(browser)
    -- The parser hands back the document wrapped under its own root element, so
    -- the entries are on `.feed.entry` and the feed-level `.author` on
    -- `.feed.author`. Reading the raw result finds neither — which is what this
    -- spent a while doing, to the effect that no feed was ever retained and every
    -- book came out uncatalogued, with the author sniff silently failing too.
    local feed = Net.feedFrom(catalog)
    logger.dbg("Meguru: feed parsed", feed_url, "(catalog=" .. tostring(name)
        .. ", entries=" .. tostring(feed and #(feed.entry or {}) or "not a table") .. ")")
    if not name then
        return
    end
    if type(feed) ~= "table" then
        last_feed[name] = nil
    elseif type(feed.OpenSearchDescription) == "table" then
        -- A search descriptor, not a feed of entries; leave whatever the
        -- navigation just retained. The browser parses one through the same
        -- method on every navigation, immediately after the real feed.
        return
    elseif type(feed.entry) == "table" then
        last_feed[name] = { url = feed_url, feed = feed }
    else
        last_feed[name] = nil
    end
end

--- Record the server software of a just-parsed feed, from the name it signs
--- itself with. Best-effort: an unrecognised author simply leaves the kind
--- unknown, which is survivable (the marker still opens).
---
--- Read off the *unwrapped* feed, like the entries: `<author>` is a child of
--- `<feed>`, so on the raw parse result this found nil every time and the sniff
--- never once succeeded — which is the opposite of best-effort.
function Open.noteCatalogAuthor(browser, catalog)
    local name = catalogTitle(browser)
    if not name or sniffed[name] then
        return
    end
    local feed = Net.feedFrom(catalog)
    local kind = Base.kindFromAuthor(feed and feed.author)
    if kind then
        sniffed[name] = kind
        logger.dbg("Meguru: catalog", name, "looks like", kind)
    end
end

--- Which driver serves this catalog: what was sniffed this session, else what
--- the catalog recorded when a book was last opened from it, else nothing.
---
--- The sniff outranks the stored kind because it is current: the stored one may
--- have been written by a build that guessed differently.
---
--- There used to be a third, strongest source above both — a manual override set
--- from the server-administration screen. That screen is gone, so `kind_source`
--- can no longer be `'manual'`; a mis-sniffed server is now corrected only by
--- clearing its row. The ordering below is the guard the override used to be.
function Open.serverKindFor(browser)
    local name = catalogTitle(browser)
    if not name then
        return nil
    end
    local server = Catalog.serverByName(name)
    if sniffed[name] then
        return sniffed[name], "author"
    end
    return server and server.kind, server and server.kind_source
end

--- The language the user is browsing this server in.
---
--- Read off the URLs actually navigated, newest first, because Suwayomi selects
--- between translations of one manga by `lang` and publishes no default — so
--- this is the only honest source, and a guess would catalogue the wrong
--- translation while still keying it to the right series.
local function langFromBrowser(browser)
    local paths = browser and browser.paths
    if type(paths) ~= "table" then
        return nil
    end
    for i = #paths, 1, -1 do
        local entry = paths[i]
        local url = type(entry) == "table" and entry.url or entry
        if type(url) == "string" then
            local lang = url:match("[?&]lang=([%w%-]+)")
            if lang then
                return lang
            end
        end
    end
    return nil
end

--- The raw Atom entry behind a browsed item.
---
--- Matched by resolved stream, since that is the one thing both representations
--- carry: the browser's acquisitions hold the href and the raw entry holds the
--- link. A feed that offers exactly one item needs no matching — Suwayomi's
--- per-chapter metadata feed is always that shape — and that single-item case is
--- the one where the `item_key` is otherwise unreachable.
local function rawEntryFor(browser, stream)
    local name = catalogTitle(browser)
    local record = name and last_feed[name]
    local feed = record and record.feed
    if type(feed) ~= "table" or type(feed.entry) ~= "table" then
        return nil
    end
    local wanted = stream and stream.href
    for _, entry in ipairs(feed.entry) do
        local template = PSE.streamFromEntry(entry, record.url or "")
        if template and template == wanted then
            return entry
        end
    end
    if #feed.entry == 1 then
        return feed.entry[1]
    end
    return nil
end

-- Registering the book --------------------------------------------------------

--- Build the item the driver would build for this stream during a sync.
---
--- Deliberately routed through the driver's own `parseCatalogPage`: the item
--- registered at open time is then produced by the same function the next sync
--- will use, so its `item_key` is necessarily the one that sync will match
--- against. Deriving the key any other way here would be a second
--- implementation of identity, which is exactly how a sync silently duplicates
--- a library.
local function driverItemFor(driver, feed, feed_url, stream, ctx)
    local items = driver.parseCatalogPage(feed, feed_url, ctx)
    if type(items) ~= "table" then
        return nil
    end
    -- Drivers leave `feed_index` to the engine, and the column is NOT NULL, so
    -- a page that never went through a sync once died at the insert on the
    -- constraint — after the series row had already been written. That is now
    -- `Catalog.upsertItem`'s business, and it is the right place for it: a
    -- metadata-feed page is one entry deep, so numbering it here would say the
    -- chapter is the first of its series. See `Catalog.upsertItem` for why an
    -- open may not number anything.
    local wanted = stream and stream.href
    for _, item in ipairs(items) do
        if wanted and item.template == wanted then
            return item
        end
    end
    return #items == 1 and items[1] or nil
end

--- Log why registration bailed, then return nil.
---
--- Every bail below is a supported outcome, not a failure — the marker alone
--- opens and reads — so none of them used to say anything, and the only trace
--- was the generic "no catalog identity" at the call site, which names no
--- cause. That is not enough to work from: a failed author sniff, an
--- unconfigured catalog title and a driver that cannot name the series are all
--- indistinguishable from the marker afterwards, and each needs a different
--- fix. One line each costs less than the device round-trip it saves.
local function why(reason, detail)
    logger.info("Meguru: not catalogued:", reason,
        detail ~= nil and ("(" .. tostring(detail) .. ")") or "")
    return nil
end

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
local function readingOrder(parsed)
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
--- again is a smaller mistake than skipping past one, and a Suwayomi catalogue
--- row has no count at all until its stream is resolved — so the alternative
--- would silently treat every unopened Suwayomi chapter as done.
local function isFinished(item)
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
local function firstUnfinished(sequence, _positioned)
    for _, item in ipairs(sequence) do
        if not isFinished(item) then
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
local function lastIn(sequence, positioned)
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
--- button that vanished would be telling them the series is empty. It replaced a
--- fall back to the catalogue, which is the snapshot from the last sync and
--- answered with whatever the catalogue happened to know (chapter 78, the last
--- row it had) rather than with where the reader is.
---
--- This is the default for `freshResumeTarget`, so it is what Kavita gets on its
--- own feed and what a Suwayomi series gets on the canonical feed when the
--- server reports nothing unread.
local function firstUnfinishedOrLast(sequence, positioned)
    return firstUnfinished(sequence) or lastIn(sequence, positioned)
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
local function firstIn(sequence, _positioned)
    return sequence[1]
end

--- The chapter the server's own position points at, read from the feed the
--- browser just fetched.
---
--- **In reading order, not feed order.** An earlier version took the last entry
--- of the parsed page with any progress, which is the answer only while the page
--- is ascending: `currentResumeTarget` fetches `driver.catalogURL`, which asks
--- Suwayomi for `sort=number_asc`, so there it was right — while the browser's
--- own page is `number_desc`, newest first, so there the same line picked the
--- *lowest*-numbered chapter in the newest hundred. One series, one function,
--- two opposite answers, and the symptom was "▶ Meguru this series opens volume 1
--- although a lot more has been read" against "opening the same book from the
--- file gets it right". `readingOrder` above is what makes the two agree.
---
--- **And what it selects is the first *unfinished* entry — see `firstUnfinished`,
--- which is also what the row above a series feed opens.** Two rules used to live
--- on the two paths: the browser answered "first unfinished" and the file
--- answered "furthest with any progress at all", so a reader who had read volume
--- 1-2 today and dipped two pages into volume 3-4 yesterday was told volume 3-4
--- by one screen and volume 1-2 by the other. One rule, one function, one answer.
---
--- The catalog cannot answer this question. `items.last_read` is a snapshot from
--- the last sync, and the only thing that refreshes a row in between is opening
--- that very chapter — so the catalog is fresh exactly where the reader has
--- clicked and stale everywhere else, and the chapter it *knows* about is
--- routinely not the one the reader has got to. Asking the feed the reader is
--- already looking at costs nothing: `OPDSBrowser` fetched it to draw the list on
--- screen.
---
--- **Entries that do not claim this series are dropped, not fatal.** An entry
--- opened from `on-deck` or `recently-added` comes from a feed listing other
--- series too, and parsing that as if it were a series feed would file their
--- items under this series — the "never silently sync the wrong series" failure
--- arriving by a side door. `driver.discover` is the existing answer to "which
--- series is this entry", and it is what separates them.
---
--- Rejecting the whole feed when *any* entry fails that test was the first
--- version of this function, and it was wrong: a Kavita series feed also carries
--- entries with no stream link at all — a special, a cover-only row — which
--- `discover` cannot place, so a single one of them meant the fresh path never
--- ran and the stale catalog always won. That is this function's own bug wearing
--- a different hat, and it is why opening volume 1 offered volume 4 (the last one
--- *meguru* had opened, the only rows the catalog refreshes) instead of volume 7
--- (the one the server says is read). Filtering is also the stronger guard:
--- foreign entries never reach the parser at all.
---
--- `select(sequence, positioned)` chooses which entry is the target, and the
--- default is not the only right answer. A feed the *server* already filtered to
--- the chapters it flags **unread** wants `firstIn` — the earliest entry, with no
--- reference to page progress at all — because there "which chapter is next" has
--- already been answered by the server and the page counter only contradicts it.
--- The two disagree in both directions: a chapter flagged read keeps whatever
--- progress it had, and a chapter merely started carries progress while being
--- flagged unread like its neighbours. See `Suwayomi.unreadFilter`.
---
--- Returns a catalog row, because the caller opens it as one. The target is
--- upserted on the way, which is the same write `registerBook` makes for the
--- book actually being opened, from the same feed, for the same series.
local function freshResumeTarget(driver, feed, feed_url, ctx, series, select)
    select = select or firstUnfinishedOrLast
    local mine = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local found = driver.discover(entry, nil, ctx)
        if found and found.series_remote_id == series.remote_id then
            mine[#mine + 1] = entry
        end
    end
    if #mine == 0 then
        logger.info("Meguru: no entry in this feed belongs to series",
            series.remote_id, "- resume point falls back to the catalog")
        return nil
    end

    -- Handed on as a feed in its own right: `parseCatalogPage` reads
    -- `feed.entry` and nothing else, so a one-field table is all it needs.
    local parsed = driver.parseCatalogPage({ entry = mine }, feed_url, ctx)
    local sequence, positioned = readingOrder(parsed)
    local best = select(sequence, positioned)
    if not best then
        -- Nothing to choose from: the feed carried no entry of this series, or
        -- carried entries the driver could not build an item out of (a Kavita
        -- special with no stream link). Both mean the same thing here — this
        -- feed has no answer — and the caller decides what that is worth:
        -- `currentResumeTarget` asks the canonical feed next, rather than
        -- falling back to the catalogue's snapshot.
        logger.info("Meguru: no entry of series", series.remote_id,
            "in this feed - no resume point from it")
        return nil
    end

    logger.info("Meguru: the feed says", best.display_title or best.title,
        "is the resume point in series", series.remote_id)

    -- `readingOrder` above is what decides *which* entry this is, and it stays:
    -- the browser's page is newest-first, so picking the resume point by feed
    -- order answered with the lowest-numbered chapter of the page instead of the
    -- furthest read. What does **not** happen here any more is numbering. This
    -- page is one page of the series and not necessarily its first, so a
    -- position taken from it is a place in the page rather than in the series;
    -- `Catalog.upsertItem` keeps the stored position for a row the catalog
    -- knows, which is the only one that means anything.
    Catalog.upsertItem(series.id, best, Catalog.nextTimestamp())
    return Catalog.itemByKey(series.id, best.item_key)
end

--- Register the server, series and item of an opened book, returning the item's
--- catalog row.
---
--- Returns nil when the series cannot be identified or the item cannot be built.
--- That is a supported outcome, not a failure: the marker alone opens and reads,
--- and the book merely has no neighbours until something else brings its series
--- into the catalog.
---
--- Note the order: the server row is written before the driver is resolved. That
--- ordering used to matter more than it does now — while the kind had a manual
--- override in a menu, a server with no row could not be corrected, so a failed
--- author sniff stranded a server permanently. There is no override any more, so
--- the row is simply a record: it is written on the strength of the configured
--- catalog alone, which is enough to describe a server, since name, host and
--- redacted root all come from `settings/opds.lua`.
local function registerBook(browser, server_name, kind, kind_source, raw_entry, stream, ctx)
    local conn = Sources.connection(server_name)
    if not conn then
        return why("no catalog entry with this title",
            "in settings/opds.lua: " .. tostring(server_name))
    end

    local server = Catalog.upsertServer({
        name         = server_name,
        kind         = kind,
        kind_source  = kind and (kind_source or "author") or nil,
        host         = Sources.host(conn.url),
        root_url     = Sources.redactedRoot(conn.url),
    })
    if not server then
        return why("could not record the server row")
    end

    local driver = kind and Base.forKind(kind)
    if not driver then
        -- There is no screen to correct this on any more: the kind can only come
        -- from the sniff, from the inference below, or from what this server was
        -- last recorded with. Naming the server is the most the message can do.
        return why("no driver for this server's kind", "kind=" .. tostring(kind))
    end

    local found = driver.discover(raw_entry, stream.href, ctx)
    if not found or not found.series_remote_id then
        return why("driver could not identify the series",
            tostring(raw_entry and raw_entry.title))
    end

    local record = last_feed[server_name]
    local feed, feed_url = record and record.feed, record and record.url
    if type(feed) ~= "table" then
        return why("no feed retained for this catalog",
            "nothing was parsed since the hook was installed")
    end

    local series_name = driver.seriesName(feed, raw_entry, ctx)
    if type(series_name) ~= "string" or series_name == "" then
        return why("driver could not name the series",
            tostring(raw_entry and raw_entry.title))
    end
    local series = Catalog.upsertSeries(server.id, {
        remote_id  = found.series_remote_id,
        name       = series_name,
        name_sort  = Naming.sortKey(series_name),
        -- Captured here rather than in the marker: the cover belongs to the
        -- series, so it has one home instead of a copy in every book file.
        -- `upsertSeries` keeps whatever is already stored when this is nil, so
        -- a feed that offered no image never erases one.
        cover_url  = Base.coverFromFeed(feed, raw_entry, feed_url or stream.href),
    })
    if not series then
        return why("could not record the series row", series_name)
    end

    local item = driverItemFor(driver, feed, feed_url, stream, ctx)
    if not item then
        return why("driver could not build the item from the retained feed",
            tostring(#(feed.entry or {})) .. " entry(ies) in it")
    end
    Catalog.upsertItem(series.id, item, Catalog.nextTimestamp())

    local registered = {
        server = server,
        -- `upsertSeries` returns the whole row, so this needs no second read.
        series = series,
        item   = Catalog.itemByKey(series.id, item.item_key),
        -- Where the reader actually is in this series, asked of the feed the
        -- browser just fetched rather than of the catalog, which only knows what
        -- the last sync saw. Nil when nothing in that feed has been read, or when
        -- no entry of it belongs to this series — `offerResume` then falls back
        -- to the catalog, which is the honest answer for a series never read.
        --
        -- **Not asked at all on a server that flags chapters read.** The page on
        -- screen cannot answer it: browsing with `filter=unread` removes exactly
        -- the chapters the question is about, and with `filter=all` the flag is
        -- still not in the entries. Left unanswered and fetched by `openAsBook`,
        -- which sits below `currentResumeTarget` and can call it — a call from
        -- here would resolve as a global, the failure `tools/check.py`'s fourth
        -- pass exists to catch.
        resume        = driver.unreadFilter and nil
            or freshResumeTarget(driver, feed, feed_url, ctx, series),
        server_target = driver.unreadFilter and true or nil,
    }
    -- Said out loud because every way this can fail says so, and the success was
    -- the only silent outcome — which makes "is it catalogued?" unanswerable from
    -- the log. Note what it counts: **one** item. The siblings arrive from a sync,
    -- never from this function — `startBackgroundSync` below is what starts one,
    -- and `openAsBook` calls it only after the book has been handed over.
    --
    -- Every field goes through `tostring`: a status line must never be able to
    -- take down the operation it exists to report on, which it once did here.
    logger.info("Meguru: catalogued", item.display_title or item.title,
        "(series " .. tostring(series.remote_id)
        .. ", kind " .. tostring(kind)
        .. ", key " .. tostring(item.item_key) .. ")")
    return registered
end

--- Ask an open reader to rebuild its menu, if it is showing a Meguru book.
---
--- **The reader menu is built once per document, and ours is derived from the
--- catalog.** `ReaderMenu:onShowMenu` calls `setUpdateItemTable` only while
--- `tab_item_table` is nil, and nothing clears it but a new document or a
--- keyboard reconnection — so every plugin's rows are frozen at the state of
--- the world when the reader first opened ⋮. That is fine for a setting that
--- does not change under it, and wrong for the neighbour rows: they are built
--- from `Catalog.neighbors`, and the walk below is *about to change exactly
--- that*. Without this the reader is offered "Find the next chapter" for a
--- series whose next chapter is already in the catalog, and never sees the
--- "auto-open next at the end" row — which exists only when there is somewhere
--- to go, and so was decided once, when there was not.
---
--- Reached through `ReaderUI.instance` rather than through `meguru/ui/reader`:
--- that module requires this one, so requiring it back would be a cycle, and
--- `registerModule("menu", …)` is what makes the instance reachable anyway.
--- The same runtime-poke technique `hook.lua` uses on `OPDSBrowser`, and pcall'd
--- for the same reason: a menu that will not rebuild must cost the reader
--- nothing.
---
--- Rebuilding while the menu is on screen does not update what is displayed —
--- the shown widget holds its own snapshot — but the table it is rebuilt from
--- is what the next `onShowMenu` reads, so closing and reopening it is enough.
local function refreshReaderMenu()
    local ok_req, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok_req and ReaderUI and ReaderUI.instance
    local doc, menu = ui and ui.document, ui and ui.menu
    if not (doc and doc.provider == "meguru" and menu
        and type(menu.setUpdateItemTable) == "function") then
        return
    end
    local ok, err = pcall(menu.setUpdateItemTable, menu)
    if not ok then
        logger.warn("Meguru: could not rebuild the reader menu:", err)
    end
end

--- Start the walk that fills in a series this path has just created.
---
--- **A registered book is what makes this necessary, and a missing neighbour is
--- what makes it worth doing.** `registerBook` writes one item — deliberately,
--- because a walk must never sit between a tap and a book opening. But the
--- catalog is then the only thing that knows where the reader is in the series,
--- and with one item in it there is no *next*: the reader's menu offers
--- "Find the next chapter" instead of the chapter itself, the "auto-open next at
--- the end" toggle is not even built (it is gated on there being somewhere to
--- go), and finishing the volume silently falls back to KOReader's own
--- end-of-book dialog. Every one of those is downstream of the same single row.
---
--- So the walk happens *after* the handoff, in the background, and neither the
--- tap nor the book pays for it.
---
--- **Gated by `Sync.plan`, and never with `force`.** The gate is what stops a
--- reader adding three volumes of one series from paying for three walks —
--- and it costs nothing on the first, because a series with no `synced_at` is
--- never "fresh". `force` would skip the *backoff* half too, and that half is
--- the one that matters here: a server whose walk just failed would be walked
--- again on the very next book added from it, for as long as it kept failing.
---
--- **The connection is checked here, not only at the tap.** A walk that starts
--- and fails because the wifi dropped is recorded as a *server* failure, which
--- pushes the series into backoff for a reason the server had no part in.
local function startBackgroundSync(registered)
    local server = registered and registered.server
    local series = registered and registered.series
    if not (server and series and series.id) then
        -- Said out loud, though the caller logged its own reason too: "the walk
        -- was not due" and "the trigger never ran" look identical in a log that
        -- only records the successes, and they need opposite fixes.
        logger.info("Meguru: nothing to sync in the background"
            .. " (no catalog row for this book's series)")
        return
    end
    if not NetworkMgr:isConnected() then
        logger.info("Meguru: no connection - not syncing", series.name,
            "in the background")
        return
    end
    -- The TTL comes from the caller rather than from inside `Sync.plan`, whose
    -- whole claim is that it reads the series row it is given and nothing else.
    local due, reason = Sync.plan(series, { ttl = Settings.get("sync_ttl_seconds") })
    if not due then
        logger.info("Meguru: background sync of", series.name, "not due (", reason, ")")
        return
    end
    logger.info("Meguru: background sync started for", series.name,
        "(series " .. tostring(series.remote_id) .. ")")
    -- `silent`: no dialog, no Cancel, no repaint. `timeout = "resume"` is the
    -- only bound available on a walk nobody can stop — see `SyncJob.run`.
    -- `opts.lang` is deliberately not passed: `openAsBook` already recorded the
    -- browsing language through `Catalog.setServerLang`, and a second way to
    -- name it is how the two would come to disagree.
    SyncJob.run(server, series, function(ok)
        -- Only on success: a failed walk left the catalog as it was, so the
        -- menu is already right about it.
        if ok then
            refreshReaderMenu()
        end
    end, { silent = true, timeout = "resume" })
end

-- Opening from the catalog ------------------------------------------------------

--- Hand `file` to `opener` with the one-shot armed for it, and disarm again if
--- the open throws.
---
--- The ordering is the point. Armed immediately before the handoff, so nothing
--- above it — a cancelled dialog, a marker that could not be prepared, a host
--- that cannot open anything — can leave the record behind; and disarmed on a
--- throw, so an open that *failed* cannot suppress the dialog for the next open
--- of the same file, which is someone retrying the book that just failed.
local function handOff(file, opener)
    Open.noteHandoff(file)
    local ok, err = pcall(opener)
    if not ok then
        Open.takeHandoff()
        logger.warn("Meguru: the reader refused to open", file, ":", err)
        return false
    end
    return true
end

--- Open a marker in whichever UI host we have: a reader swaps documents, the
--- file browser opens a file. `host` is a plugin instance, whose `.ui` is the
--- actual application.
---
--- Above every caller, and it has to be. `local function` brings the name into
--- scope only from its own statement onwards, so the same function placed after
--- its callers resolves to a *global* there — which is nil, and which fails at
--- the call with "attempt to call global 'handToReader' (a nil value)" rather
--- than at load. This file already had the comment saying so and the function
--- below its callers anyway; the comment was right and the position was not.
local function handToReader(host, file)
    if not (host and host.ui) then
        return false
    end
    -- The question has already been asked above this point, by `offerResume`, or
    -- was never needed. Arming here — the one place every catalog open hands a
    -- file over — is what tells the `showReader` wrap not to ask it again.
    if host.ui.document then
        return handOff(file, function() host.ui:switchDocument(file) end)
    end
    return handOff(file, function() host.ui:openFile(file) end)
end

--- Hand a prepared marker over, reporting the one failure that matters.
---
--- Shared by both catalog open paths so the message and the arming cannot drift
--- apart: the same file reaching the reader with two different failure texts is
--- how a bug in one of them becomes invisible.
local function openPrepared(host, file)
    if handToReader(host, file) then
        return file
    end
    logger.err("Meguru: no opener available for", file)
    UIManager:show(InfoMessage:new{
        text = T(_("could not open the book.\nMarker written to:\n%1"), file),
    })
    return nil
end

--- True when this book has never been opened on this device.
---
--- Must be asked *before* any `DocSettings:open`, because that call creates the
--- sidecar this looks for — ask afterwards and every open looks like the first.
--- `hasSidecarFile` is the cheap test core itself uses (`docsettings.lua:151`):
--- it walks the location candidates and stats, and parses nothing.
local function neverOpened(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or type(DocSettings.hasSidecarFile) ~= "function" then
        return false
    end
    local ok_has, has = pcall(DocSettings.hasSidecarFile, DocSettings, file)
    return ok_has and not has
end

--- Write a starting page into a marker's sidecar, before the reader opens it.
---
--- `ReaderUI:showReader` takes no page, and both of its post-open callbacks fire
--- *after* `ReaderReady` and the first render — so a page seeded any later would
--- show page 1 and then jump. The one value that lands on the first paint is the
--- one the paging module reads out of `DocSettings` in its own `onReadSettings`
--- (`readerpaging.lua:154`), and that is what this writes. The old plugin seeded
--- the same setting the same way (`meguru_hook.lua:258`), and there is no other
--- way to do it.
---
--- `last_page` is right because our provider is a paging document. A rolling
--- (CREngine) one would need `last_xpointer`, which is a string — a different
--- problem, and not one this plugin has.
function Open.seedLastPage(file, page)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then
        return false
    end
    local ok_open, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok_open or not ds then
        logger.warn("Meguru: could not open the sidecar to seed a page")
        return false
    end
    ds.data.last_page = math.floor(page)
    local ok_flush, err = pcall(function() ds:flush() end)
    if not ok_flush then
        logger.warn("Meguru: could not seed the reader page:", err)
        return false
    end
    logger.info("Meguru: starting", file, "at page", page)
    return true
end

--- A book's *short* name, for putting on a button.
---
--- `volume_label` is the token `Naming.deriveSeries` pulled out on its own —
--- "Volume 5", "Chapter 30" — while `display_title` is the whole cleaned entry
--- title, which for Kavita is "Now That We Draw - Volume 2". A button carrying
--- the series name as well as the volume and a page number overflows, which is
--- how this was found; buttons get the token, never the full title.
---
--- The marker descriptor has no `volume_label`, and it is what the file path
--- falls back to when the catalog is unreadable, so the token is derived from its
--- title — by the same function that produced `volume_label` in the first place.
---
--- Exported because the reader menu names a *neighbour* the same way: its series
--- is the one already open, so "Volume 2" is the whole of what the row has to
--- say and the full title only makes it overflow. One definition, so a row and
--- the button that opens the same book cannot come to disagree.
function Open.bookLabel(subject)
    if type(subject) ~= "table" then
        return _("this book")
    end
    if subject.volume_label then
        return subject.volume_label
    end
    local _, token = Naming.deriveSeries(subject.title or "")
    return token or subject.display_title or subject.title or _("this book")
end

--- A recorded page, when it is a position *inside* a book rather than its first
--- page — past page 1 and within the count. The old plugin's guard, unchanged
--- (`meguru_hook.lua:996`). Page 1 is not a position anybody is at, which is why
--- a page-1 answer is reported as "no page" rather than as "page 1".
---
--- Module-level rather than the closure it used to be inside `offerResume`: the
--- jump button needs the same test against the *other* book's count, not against
--- the count of the book being opened.
local function usablePage(page, count)
    page = tonumber(page)
    if page and page > 1 and count and page <= count then
        return page
    end
    return nil
end

--- The dialog's title: the series when we know it, the book otherwise.
---
--- The series, not the volume, because the question is where in the *series* to
--- carry on. The volume used to be here, and it was the one thing both buttons
--- could name — but they are allowed to point at different books, and a title
--- naming one of them makes the other read as a detour.
---
--- `series` is nil for a marker whose catalog row is gone — opened from History
--- after a database rebuild, or a book whose series was never catalogued. There
--- the book is all there is to name, which is what the title used to say
--- unconditionally.
local function dialogTitle(series, item)
    local name = series and series.name
    if type(name) == "string" and name:find("%S") then
        return T(_("Meguru: %1"), name)
    end
    return T(_("Meguru: %1"), Open.bookLabel(item))
end

--- One button: the verb, the book it opens, and the page it opens at.
---
--- **Every button names its own book**, because the buttons point at *different*
--- books — the one the reader clicked, and whichever one the server last saw
--- them in. Two buttons reading "Continue" while opening different volumes was
--- the first version of this dialog, and it is worse than not asking at all:
--- `(Server)` says whose answer it is, not where it lands. The book is
--- `bookLabel`'s short form ("Volume 2", "Chapter 30"), never the whole entry
--- title, which overflows the button once a page number joins it.
---
--- `page` is nil when there is no page worth naming; then only the book is named.
--- `from_server` marks the answers that are not the reader's own doing: the
--- glyph, which this plugin's own OPDS row already proves renders, and the
--- parenthetical that says why.
---
--- Four whole templates rather than a suffix glued on, so a translator can move
--- the parts around within one string.
local function buttonLabel(verb, subject, page, from_server)
    local name = Open.bookLabel(subject)
    if from_server and page then
        return "\u{25B6} " .. T(_("%1 — %2, page %3 (Server)"), verb, name, page)
    elseif from_server then
        return "\u{25B6} " .. T(_("%1 — %2 (Server)"), verb, name)
    elseif page then
        return T(_("%1 — %2, page %3"), verb, name, page)
    end
    return T(_("%1 — %2"), verb, name)
end

--- The page to name on the "open the other book" button, or nil.
---
--- The count is the *target's* own, not the count of the book being opened, and
--- the page is named only when it is the page that book will actually open at. A
--- book already read on this device resumes where KOReader left the reader —
--- `offerResume`'s own rule, one button up — so naming the server's page for it
--- would promise a page the tap does not deliver. A book with no sidecar is
--- seeded silently from `desc.last_read` by `MeguruDocument:init`, and that is
--- the page `planMarker` writes into the marker, so there the promise holds.
---
--- That coupling is the thing to keep in step: if the silent seed ever changes,
--- this test has to change with it, or the button starts lying.
local function jumpPage(target, series)
    local row = series and Catalog.itemByKey(series.id, target.item_key) or nil
    local marker = (row and row.marker_path) or target.marker_path
    if type(marker) == "string" and marker ~= "" and FS.exists(marker)
        and not neverOpened(marker) then
        return nil
    end
    local count = tonumber(target.page_count or (row and row.page_count))
    return usablePage(target.last_read, count)
end

--- The page a book was left on, read out of its sidecar, or nil.
---
--- Only for a book that already has a sidecar: `DocSettings:open` creates the
--- file it opens, so calling this for a book never read here would invent the
--- very thing that tells us whether it has been. `last_page` is what
--- `readerpaging` writes and restores from, so it is the same number the reader
--- is about to use — not an approximation of it.
local function localLastPage(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok then
        return nil
    end
    local ok_open, ds = pcall(DocSettings.open, DocSettings, file)
    if not ok_open or not ds then
        return nil
    end
    local ok_read, page = pcall(function()
        return tonumber(ds:readSetting("last_page"))
    end)
    if not ok_read or not page or page < 1 then
        return nil
    end
    return page
end

--- The series a feed describes, when the whole feed describes exactly one.
---
--- The same test `freshResumeTarget` applies, and for the same reason: an
--- aggregate lists several series, and a row offering "this series" over one of
--- those would be a lie about which. Returns a table of what the row and the
--- action both need, or nil.
local function feedSeries(browser)
    local name = catalogTitle(browser)
    local kind, kind_source = Open.serverKindFor(browser)
    local driver = kind and Base.forKind(kind)
    if not name or not driver then
        return nil
    end
    local record = last_feed[name]
    local feed = record and record.feed
    if type(feed) ~= "table" or type(feed.entry) ~= "table" or #feed.entry == 0 then
        return nil
    end

    local ctx = { lang = langFromBrowser(browser) }
    local remote_id
    for _, entry in ipairs(feed.entry) do
        local found = driver.discover(entry, nil, ctx)
        if not found or not found.series_remote_id then
            return nil
        end
        if remote_id and found.series_remote_id ~= remote_id then
            return nil -- more than one series here, so "this series" names nothing
        end
        remote_id = found.series_remote_id
    end
    if not remote_id then
        return nil
    end

    return {
        server_name  = name,
        kind         = kind,
        kind_source  = kind_source,
        driver       = driver,
        remote_id    = remote_id,
        ctx          = ctx,
        feed         = feed,
        feed_url     = record.url,
        first_entry  = feed.entry[1],
    }
end

--- The row that goes at the top of a series feed, or nil when this is not one.
---
--- `item_url` is the list being built, and it must be the feed we are actually
--- holding. That single comparison is what keeps the row off every other list the
--- browser draws through the same path: a search result is a different URL, the
--- next page of a paginated series is `hrefs.next`, and the root list does not
--- come through here at all. Without it the row appeared on search results — the
--- retained feed is still the last series browsed, so "this series" would have
--- been true of a feed that was no longer on screen.
function Open.seriesRow(browser, item_url)
    local info = feedSeries(browser)
    if not info or item_url ~= info.feed_url then
        return nil
    end
    return {
        text      = "\u{25B6} " .. _("Meguru this series"),
        mandatory = tostring(#info.feed.entry),
        -- What the `onMenuSelect` wrap keys on. Without a marker of our own the
        -- row would be read as a catalog link — `onMenuSelect` treats every row
        -- with no acquisitions that way — and tapping it would try to navigate
        -- to a URL it does not have.
        meguru    = info,
    }
end

--- The first item in reading order the server says has not been read.
---
--- The ordering is `readingOrder`'s, not the feed's: Suwayomi browses
--- newest-first by default, so "the first unread" read straight off feed order
--- would be the *newest* chapter.
---
--- **"Unread" means two different things depending on the server, and `filtered`
--- says which.** A server that flags chapters itself (Suwayomi) has already
--- answered it, so a feed asked for those chapters needs no test at all and the
--- earliest entry is the answer. A server that does not (Kavita) has only the
--- page counter, and there "unread" has to mean *not finished* — see below.
---
--- Passing `filtered` rather than re-deriving it from the item is deliberate:
--- the flag is a property of the *feed* that was fetched, not of any entry in it.
---
--- Returns nil when nothing is unread, and **that is not the same as "offer the
--- last one"**. An earlier version did offer it, reasoning that the newest chapter
--- is where a reader of a finished series would carry on — and the effect was a
--- row that promises the first unread chapter and silently opens the last one, at
--- its last page. A row that cannot do what it says says nothing instead.
local function firstUnread(parsed, filtered)
    -- The ordering, the predicate and the selection all live elsewhere now, and
    -- that is the point: `freshResumeTarget`'s default selector is
    -- `firstUnfinished` and this is the same call, so the row above a series
    -- feed and the `▶` button in the dialog cannot answer differently. They did
    -- — four separate times, from four separate copies of one rule.
    --
    -- `readingOrder` is still shared with `freshResumeTarget` for the same
    -- reason: "where does this reader actually stand?" is one question asked
    -- from two screens.
    local sequence = readingOrder(parsed)
    if filtered then
        -- The server already answered it: every entry of this feed is one it
        -- flags unread, so the earliest is the answer and the page counter is
        -- not consulted. See `firstIn`.
        return firstIn(sequence)
    end
    return firstUnfinished(sequence)
end

--- How many pages of the canonical feed the row will walk.
---
--- The cap exists because the walk is synchronous on a tap: this engine's HTTP
--- blocks and there is no thread under the UI, so an unbounded chain would hold
--- the screen for as long as the server felt like taking. Six pages is 600
--- chapters — well past the point where walking further to find the first
--- *unread* chapter is plausible — and it covers Berserk's 403 in five.
local FIRST_UNREAD_PAGES = 6

--- The items of a series, in reading order, from the server's own canonical feed.
---
--- **The page on screen is not the series, and that is the whole reason this
--- exists.** The feed the browser holds is one page of one ordering, and it
--- browses newest-first: for Berserk, whose 403 chapters are numbered up to 386,
--- that retained page is `Chapter 386` down to `Chapter 288` (`number_desc`, the
--- sort its own facets are built around). The row therefore used to offer the
--- first unread chapter *of the newest hundred* — for a reader who has not
--- started the series that is `Chapter 288`, not `Chapter 1`, which is what it
--- looked like and what this fixes.
---
--- `driver.catalogURL` is the fix, and it is the same URL a sync walks:
--- `sort=number_asc`, so the series starts at the beginning of its first page.
---
--- **Every page up to the cap is walked, with no early exit, and that is
--- deliberate.** Stopping at the first unfinished chapter would be a request or
--- two for the common case, but it would be correct only if the server honoured
--- `sort=number_asc`. If it did not, the walk would stop on whatever the *first*
--- page happened to hold — which is precisely the bug being repaired, made
--- silent. Walking the chain and choosing from all of it needs no such
--- assumption: `firstUnread` orders by the number in each title and each entry's
--- own path position, so it finds the true earliest unfinished chapter whichever
--- way the pages arrived. The cost is a handful of requests on a deliberate tap,
--- bounded by `FIRST_UNREAD_PAGES` and by `Net.RESUME_*` per page.
---
--- Falls back to the page on screen when the canonical feed cannot be walked at
--- all — offline, or a server with no saved catalog. That is degradation rather
--- than failure: the row keeps doing exactly what it did before, over the
--- hundred entries the browser had already fetched.
local function seriesItems(info, conn)
    local driver, remote_id, ctx = info.driver, info.remote_id, info.ctx
    local feed, feed_url = info.feed, info.feed_url

    -- **Returns `items, basis`, and the second value is the whole difference
    -- between two answers.** `firstUnread` uses it to decide whether the page
    -- counter may be consulted at all, and the fallback below hands it a page
    -- the server did *not* filter by read status — the browser's own list, which
    -- for Suwayomi is the newest hundred chapters. Deriving it from the driver
    -- made `firstUnread` take `sequence[1]` of that page, i.e. the newest chapter
    -- of the page on screen: the exact "opens volume 1 although a lot more has
    -- been read" confusion the whole ordering apparatus exists to remove.
    local function fallback(reason)
        logger.info("Meguru: series walk unusable (", reason,
            ") - the row falls back to the page on screen")
        return driver.parseCatalogPage(feed, feed_url, ctx), "counters"
    end

    if not conn then
        return fallback("no saved catalog for this server")
    end
    if not NetworkMgr:isConnected() then
        return fallback("no connection")
    end

    local function walk(which, walk_ctx)
        local url = driver.catalogURL(conn.url, remote_id, walk_ctx, which)
        local pages, complete, reason = Sync.walk(url, {
            username  = conn.username,
            password  = conn.password,
            timeout   = "resume",
            max_pages = FIRST_UNREAD_PAGES,
        })
        return pages, complete, reason
    end

    -- The chapters the server flags unread, when it has such a flag. Asking for
    -- them makes `firstUnread`'s answer exact rather than inferred — see its
    -- comment — and the walk below still runs over the whole chain, because a
    -- filtered feed is only as ordered as the server's `sort` was honoured.
    -- **What the answer may be based on**, not merely which feed was asked for.
    -- `"flag"` — the server filtered by read status and listed chapters, so its
    -- flag is the truth and page counters are not consulted. `"empty"` — the
    -- server filtered and listed *nothing*: nothing is unread, which is an
    -- answer about where the reader is, not an absence of one. `"counters"` —
    -- no flag in play (Kavita, or a filtered walk that failed), so the page
    -- counts are the only evidence there is.
    local basis = driver.unreadFilter and "flag" or "counters"
    local pages, complete, reason = walk(driver.unreadFilter, ctx)

    -- **The filtered feed is an optimisation, and this row cannot stand on it
    -- alone — in either of the two ways it comes up short.**
    --
    -- It can *fail*: a series read to the end has nothing to list under
    -- `filter=unread`, and that answer used to arrive here as `"http"`, an HTTP
    -- failure with no status code to find. Falling straight through to the page
    -- on screen then answered from the newest hundred chapters, so the row
    -- offered "Chapter 78" — the first unfinished *of that page* — for a reader
    -- whose series starts at chapter 1.
    --
    -- Or it can be *empty*, which is the server answering: nothing is unread.
    -- That reads as "nothing to show" and is not — it says *where* the reader
    -- is, at the end of the series, and the row wants that chapter, which only
    -- the canonical feed can name. So both routes fetch it, and the answer comes
    -- from page counters, with the basis saying so — nothing downstream may
    -- consult a read flag that the feed it holds never carried.
    --
    -- The retry asks for exactly what a sync asks for — no filter, and the
    -- language the *server* was last recorded with rather than the browser's —
    -- so it fails only if the sync would fail too.
    -- One branch, not one per reason: both routes need the canonical feed, and
    -- the reason only decides how the line reads. `( empty )` is the server
    -- saying nothing is unread; anything else is the walk failing.
    if #pages == 0 and driver.unreadFilter and reason == "empty" then
        -- The server filtered by read status and listed nothing: nothing is
        -- unread. That is the row's answer — there is no chapter to open — and
        -- fetching the canonical feed to look for one anyway would be a walk
        -- per tap to answer a question that has already been answered.
        logger.info("Meguru: the server lists nothing unread in series", remote_id)
        return {}, "empty"
    end
    if #pages == 0 and driver.unreadFilter then
        logger.info("Meguru: filtered series walk yielded nothing (", tostring(reason),
            ") - asking the canonical feed")
        pages, complete, reason = walk(nil, { lang = Catalog.serverLang(info.server_name) })
        -- The canonical feed carries no read flag, so its page counters are all
        -- this answer can rest on.
        basis = "counters"
    end

    local items = {}
    for _, page in ipairs(pages) do
        -- Each page against *its own* URL: entry hrefs are relative, and a page
        -- need not share the path of the one before it.
        for _, item in ipairs(driver.parseCatalogPage(page.feed, page.url, ctx) or {}) do
            items[#items + 1] = item
        end
    end
    if #items == 0 then
        -- A walk that returned nothing is not an answer, so it does not get to
        -- suppress the page on screen.
        return fallback(reason or "the feed carried no entry")
    end

    logger.info("Meguru: walked", #pages, "page(s) for series", remote_id, "-",
        #items, "items,", complete and "complete" or ("stopped: " .. tostring(reason)),
        basis)
    return items, basis
end

--- Open the first unread volume of the series the row was offered for.
---
--- Writes exactly one item — the one it is about to open — and leaves the
--- siblings to the background walk it starts at the end, which is the same walk
--- `openAsBook` starts and is gated the same way. It is deliberately *not*
--- started from `openCatalogItem`: that funnel is also reached from the file
--- manager and History, where there is no browser feed to walk from.
---
--- Mirrors the server and series half of `registerBook` rather than calling it:
--- that function is built around a book that was tapped, and there is no book
--- here. The two must agree on how a series row is found and named, so if the
--- resolution below is ever changed, `registerBook` is where to change it too.
--- The resolution of the *resume point* is the other half of that agreement, and
--- it is not mirrored but shared: both end at `offerResume`, and both have to
--- arrive with the fresh answer in hand rather than letting it ask the catalog.
function Open.openFirstUnread(browser, info)
    local conn = Sources.connection(info.server_name)
    if not conn then
        UIManager:show(InfoMessage:new{
            text = T(_("no catalog entry with this title in settings/opds.lua: %1"),
                tostring(info.server_name)),
        })
        return
    end

    local server = Catalog.upsertServer({
        name         = info.server_name,
        kind         = info.kind,
        kind_source  = info.kind and (info.kind_source or "author") or nil,
        host         = Sources.host(conn.url),
        root_url     = Sources.redactedRoot(conn.url),
    })
    if not server then
        return
    end

    local series_name = info.driver.seriesName(info.feed, info.first_entry, info.ctx)
    if type(series_name) ~= "string" or series_name == "" then
        logger.warn("Meguru: could not name the series behind this feed")
        return
    end
    local series = Catalog.upsertSeries(server.id, {
        remote_id = info.remote_id,
        name      = series_name,
        name_sort = Naming.sortKey(series_name),
        cover_url = Base.coverFromFeed(info.feed, info.first_entry, info.feed_url),
    })
    if not series then
        return
    end

    -- The series from its canonical feed, not from the page on screen — see
    -- `seriesItems`. `conn` is the connection resolved at the top of this
    -- function, which is what the walk authenticates with.
    -- The second value is `seriesItems`' judgement of what its answer may rest
    -- on, not the driver's idea of it: the fallback is the browser's own
    -- unfiltered page, and asking the driver would claim a filter that page
    -- never had. See `seriesItems`.
    -- `basis` is *what the answer may rest on*, and it decides the rule — see
    -- `seriesItems`. The row and the `▶` button now read the same three states
    -- the same way, which is the whole point: they gave different chapters for
    -- the same series for as long as they answered from different evidence.
    local parsed, basis = seriesItems(info, conn)

    -- **A finished series has no chapter to open, and the row says so.** Taking
    -- the reader to the end of it was tried and read as nonsense — the last
    -- chapter is not somewhere they asked to go. `"empty"` collapses into "no
    -- target" deliberately: both mean the row has nothing to offer.
    local target
    if basis ~= "empty" then
        target = firstUnread(parsed, basis == "flag")
    end
    if not target then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 has nothing unread."), series_name),
        })
        return
    end

    -- The row is written so it has an id — the opener writes the marker path
    -- against it — and read back for the same reason.
    --
    -- **Its position is not taken from this page.** `parsed` is an *unread*
    -- walk, so its first entry is the first unread chapter, not the first
    -- chapter: numbering it here gave a reader at chapter 41 the position
    -- chapter 1 holds, and `orderedItems` sorts on exactly that column. The
    -- chapter then sat next to chapter 1 in reading order and `neighbors`
    -- answered "next" with chapter 2. `Catalog.upsertItem` now keeps the stored
    -- position for a row it knows and appends one it does not; see its comment
    -- for the whole of why an open may not number anything.
    Catalog.upsertItem(series.id, target, Catalog.nextTimestamp())
    local row = Catalog.itemByKey(series.id, target.item_key)
    if not row then
        return
    end

    local manager = browser and browser._manager
    local host = (manager and manager.ui) and manager or fallback_host
    -- `row` twice, and the second one is load-bearing: it is the book to open
    -- *and* the answer to "where is this reader in the series". Without it the
    -- dialog asks the catalog instead, whose rule is "furthest with any
    -- progress" rather than "first unfinished" — so on a series read to volume 6
    -- with 7 and 8 started, this row opened volume 7 while the only "Continue"
    -- button on the dialog pointed at volume 8. See `openCatalogItem`.
    Open.openCatalogItem(host, server, series, row, row)

    -- The same series-filling walk the download-dialog button starts, for the
    -- same reason and with the same gate. This row used to be left out — the
    -- argument was that it would be a *second* walk, over the same feed
    -- `seriesItems` has just read, and that its sibling entry point can afford
    -- one while this one cannot.
    --
    -- That argument is true about the cost and wrong about the reader: tapping
    -- "▶ Meguru this series" *here* means the same thing it means there — add
    -- this series — and a reader who used this row got a one-item series, no
    -- neighbour row and no auto-open, with "Find the next chapter" as the only
    -- way out. Two walks on the first tap per TTL, and one from then on, is the
    -- cheaper of the two prices.
    --
    -- Not spawned from `openCatalogItem`, deliberately: that funnel is also
    -- reached from the file manager and History, where there is no feed to walk.
    UIManager:nextTick(function()
        local ok, err = pcall(startBackgroundSync, { server = server, series = series })
        if not ok then
            logger.warn("Meguru: the background sync could not be started:", err)
        end
    end)
end

--- Offer a starting point, then open. Calls `opts.open()` either way.
---
--- **Asked whenever there is a choice, and only then** — a book whose series has
--- something further along in it, or a book never opened here whose server page
--- is worth resuming at. Whether the book has been read here decides the
--- *wording*, not whether to ask: "continue where I left off" and "continue here
--- (page N)" are the same button doing what each situation means, and a reader
--- who has read volume 3 here and got to volume 5 elsewhere gets asked about
--- precisely that.
---
--- The flows that come through here silently do so by *decision*, not by accident
--- of the data: a neighbour reached from the reader's own menu — "find the next
--- chapter", the automatic advance at the end of a volume — does not come through
--- here at all. It goes through `Open.openItemSilently`, because a tap on a
--- specific chapter is an instruction, not a question, and the dialog answering
--- it would be the dialog overriding what the reader asked for.
---
--- The caller passes the open step rather than being called back into because the
--- two entry points hand the marker on differently — the browser goes through the
--- built-in plugin's own opener.
---
--- `opts.target` is the caller's fresh answer when it has one, and the catalog's
--- is the fallback when it does not. They are not equivalent and the difference
--- is deliberate: see `freshResumeTarget`.
---
--- **The server's position is one button with two readings, not two buttons.**
--- Where it lands decides which: inside this book it is a page, and outside it is
--- a book to open. Both cannot be said at once — naming a page is not a thing to
--- say about a book you are being pointed *past* — so the label follows.
---
--- The reader's own page and the server's are therefore *both* offered when they
--- differ, which is the point: a book read to page 30 here and left at page 60
--- elsewhere has two honest answers and only the reader knows which they want.
--- Suppressing the server's page for a book read locally — the first version of
--- this — silently threw one of them away.
---
--- **Every button names the book it opens**, which is what makes two "continue"
--- buttons safe: they are allowed to point at different books, and before they
--- named them the reader had to infer which was which from feed order. See
--- `buttonLabel`.
---
--- `opts.open_item(target)` is how the leaving button opens the chosen book. The
--- two entry points reach a marker differently — the browser opens a stream,
--- the file manager has whoever is opening this file — so the default is the
--- browser's, and the file path supplies its own. Both are *silent*: this dialog
--- has just asked the question, so neither re-asks it.
---
--- @param opts { count, file, target, open, open_item }
function Open.offerResume(host, server, series, item, opts)
    local file, open = opts.file, opts.open

    -- Has this book been read here before? It decides what "continue" means and
    -- where a page number can come from — never whether to ask.
    local opened_before = not neverOpened(file)

    -- The reader's own place in this book, or nil. Read from the sidecar, which
    -- is where KOReader keeps it and what it is about to restore from anyway.
    local local_page = opened_before and localLastPage(file) or nil

    -- The *server's* position in this series, and the one thing that decides how
    -- the third button reads: whether that position is inside this book or in
    -- another one. It is a genuine either/or, not a preference — "sync to page
    -- 60" cannot be said about a book the server last saw you at page 60 of,
    -- while pointing at volume 5.
    local position = opts.target
    if not position and server and series then
        local found = Catalog.resumeTarget(series.id)
        position = found and found.item or nil
    end

    local server_page, jump
    if position and item and position.item_key == item.item_key then
        -- The server is *in this book*: not somewhere to go, just a page — and
        -- only when it is genuinely a different page from the reader's own. A
        -- lead inside `PSE.samePlace`'s tolerance is the prefetch artefact, and
        -- the page itself is used exactly as recorded: subtracting the artefact
        -- would walk back pages a position recorded by *another* reader never had.
        if not PSE.samePlace(position.last_read, local_page) then
            server_page = usablePage(position.last_read, opts.count)
        end
    else
        jump = position
    end

    -- Asked when the *server* has an opinion, and only then. What the reader
    -- asked for needs no question: it opens where it was left, or at its start.
    -- The question exists because the server may disagree, so no server answer
    -- means no question.
    --
    -- Gating on the server rather than on "is there anything to show" is also
    -- what keeps the dialog from ever having a single button: the reader's own
    -- button is always built below, so a server answer makes it two, and its
    -- absence means the dialog is never built at all.
    if not server_page and not jump then
        open()
        return
    end

    -- Where the book the reader clicked would open. Always offered, and that is
    -- not decoration: with the server's answer on the table this is the only way
    -- back to it, and removing it once made a clicked volume *unreachable* —
    -- clicking an unread volume 11 while the server said volume 5 left one
    -- button that went to volume 5, and a tap past the dialog cancels.
    --
    -- A book never read here starts at its beginning, which is page 1. That also
    -- has to be *written*: `MeguruDocument:init` seeds the server's page into a
    -- book with no sidecar, so leaving it unsaid would open at the server's page
    -- after all — the server's answer winning a question the reader answered.
    --
    -- A book read here but with no page recorded keeps nil, and its button drops
    -- the number rather than claiming page 1.
    local here_page
    if opened_before then
        here_page = local_page
    else
        here_page = 1
    end

    -- `\u{25B6}` marks the server's answers, and is the same glyph this plugin's
    -- own row uses in the OPDS dialog — so it is known to render, which is why it
    -- is the only one used here.
    --
    -- A tap past the dialog **cancels**: nothing opens. That is the whole meaning
    -- of a dismissal here, and it is why this sets no `tap_close_callback` — an
    -- earlier version did, on the reasoning that a dismissal had to land
    -- somewhere, and opened the book. Tapping past a question is not a way of
    -- answering it.
    --
    -- At most one action per dialog all the same, so a double tap cannot open
    -- two books. **This is not what stops the dialog reopening after the open** —
    -- that is `Open.noteHandoff`, which spans the `showReader` wrap, and it has
    -- to, because this guard dies with the dialog it belongs to.
    local acted = false
    local function once(action)
        if acted then
            return
        end
        acted = true
        action()
    end

    -- The verb follows the situation, because one verb cannot be true of both:
    -- `Continue — Volume 1, page 1` reads as a contradiction for a book nobody
    -- has started, so an unread book starts. A book that *has* been read
    -- continues, and one read without a recorded page continues too and drops the
    -- number rather than claiming one — it resumes wherever KOReader left it,
    -- which is not a page this code knows.
    --
    -- A book never opened here therefore shows no page either, though `here_page`
    -- is 1 and is still written below.
    local here_verb = opened_before and _("Continue") or _("Start reading")
    local here_shown_page = opened_before and here_page or nil

    local dialog
    local buttons = {}
    buttons[#buttons + 1] = {
        {
            -- No glyph: `▶` marks the server's answers, which are the ones here
            -- that are not the reader's own doing.
            text = buttonLabel(here_verb, item, here_shown_page, false),
            callback = function()
                UIManager:close(dialog)
                if opened_before then
                    -- KOReader restores their own position unaided, so this
                    -- button's whole job is to *not* get in the way.
                    once(open)
                else
                    -- A book never opened here has no position to restore, and
                    -- `MeguruDocument:init` would seed the server's page into it.
                    -- Saying page 1 is what makes this button mean what it says.
                    once(function()
                        Open.seedLastPage(file, here_page)
                        open()
                    end)
                end
            end,
        },
    }
    if server_page then
        buttons[#buttons + 1] = {
            {
                -- Textually parallel with the local button above: the same verb,
                -- the same book — it is this one, since the server is inside it —
                -- and the server's page instead of the reader's.
                text = buttonLabel(_("Continue"), item, server_page, true),
                callback = function()
                    UIManager:close(dialog)
                    once(function()
                        Open.seedLastPage(file, server_page)
                        open()
                    end)
                end,
            },
        }
    end
    if jump then
        buttons[#buttons + 1] = {
            {
                -- The book and the page, so it cannot be confused with the page
                -- button above: `page 60` and `Volume 2, page 2` are two numbers
                -- in two different books, and it is the book name that says so.
                -- The page is `jumpPage`, which refuses to name one for a book
                -- this device has already read.
                text = buttonLabel(_("Continue"), jump, jumpPage(jump, series), true),
                callback = function()
                    UIManager:close(dialog)
                    -- Opening the marker this was called for as well would leave
                    -- a book nobody asked for sitting next to the one they did.
                    --
                    -- Silent on purpose, and that is the fix for the dialog that
                    -- asked twice: the reader has just named this book, so
                    -- `openCatalogItem` — which would plan the marker and then
                    -- put the same question again about the book they chose — is
                    -- exactly the wrong call here.
                    local open_target = opts.open_item or function(chosen)
                        Open.openItemSilently(host, server, series, chosen)
                    end
                    once(function() open_target(jump) end)
                end,
            },
        }
    end

    dialog = ButtonDialog:new{
        -- The series, named once. Every button names its own book and page, so
        -- the title does not have to choose between them.
        title = dialogTitle(series, item),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Everything a marker needs, worked out but **not written**.
---
--- The write happens in `commitMarker`, when the reader has actually chosen
--- something. That split exists because the resume dialog needs the marker's
--- *path* before the file exists — `neverOpened`, `localLastPage` and
--- `seedLastPage` are all keyed on the sidecar a path implies — so everything
--- the dialog decides is known without touching the disk, and the one thing that
--- needs the file itself is the handoff to the reader.
---
--- What that buys: a dismissed dialog leaves no book behind. Tapping "▶ Meguru
--- this series" and then tapping past the question used to write a marker for a
--- book nobody asked for, and the marker is what makes the book appear in the
--- library and in History — so the cost was not a stray file, it was a phantom
--- shelf entry with no progress in it.
---
--- Nothing is left behind at all. `Marker.dirFor` is pure and `Marker.saveAt`
--- is what creates the folder, so a dismissed dialog costs no file *and* no
--- folder — an empty series folder is indistinguishable from a series whose
--- books were all deleted, and no "Clear cache" takes it away.
---
--- `existing` marks a plan for a marker already on disk — the item that has been
--- opened before — where there is nothing to write and the count has to be read
--- back out of the marker rather than resolved from the network.
---
--- Returns the plan, or nil after reporting why.
local function planMarker(server, series, item)
    if type(item.marker_path) == "string" and item.marker_path ~= ""
        and FS.exists(item.marker_path) then
        -- `count` is read back rather than resolved: `Sync.resolveStream` costs a
        -- request for a Suwayomi chapter, and the marker already knows. It used
        -- to be dropped here entirely, which is why the server's page button
        -- appeared for a freshly made marker and vanished on the second open of
        -- the same book — the same question answered differently by the second
        -- and third opens, with `offerResume`'s `usablePage` refusing a page it
        -- had no count to bound.
        local existing = Marker.load(item.marker_path)
        return {
            item     = item,
            server   = server,
            path     = item.marker_path,
            existing = true,
            count    = existing and tonumber(existing.count) or nil,
        }
    end

    local template, count = Sync.resolveStream(item, server)
    if type(template) ~= "string" or template == "" then
        logger.warn("Meguru: no page stream for", item.title)
        UIManager:show(InfoMessage:new{
            text = T(_("could not find a page stream for “%1”."),
                item.display_title or item.title),
        })
        return nil
    end

    local desc = Marker.new{
        server_name      = server.name,
        series_remote_id = series.remote_id,
        item_key         = item.item_key,
        item_id          = item.id,
        title            = item.title,
        template         = template,
        count            = count,
        last_read        = item.last_read,
    }
    local dir = Marker.dirFor(desc, series, {
        base_dir              = Marker.baseDir(),
        server_folder         = Settings.get("marker_server_dir") and true or false,
        series_folder_claimed = Catalog.folderClaimedByOther(
            server.id, series.name, series.id),
    })
    return {
        item     = item,
        server   = server,
        desc     = desc,
        path     = Marker.pathFor(dir, desc),
        existing = false,
        count    = count,
    }
end

--- Write the marker a plan describes, and return its path.
---
--- Idempotent for a plan whose marker is already on disk: nothing is written and
--- the path it was planned with comes back, so a caller that reaches here twice
--- cannot make two files.
function commitMarker(plan)
    if plan.existing then
        return plan.path
    end
    local file = Marker.saveAt(plan.path, plan.desc)
    if not file then
        return nil
    end
    Catalog.setMarkerPath(plan.item.id, file)

    -- Same credentials this book will be fetched with, kept in memory only so
    -- the very first page does not race the built-in plugin's own settings
    -- flush. Never written into the marker.
    local conn = Sources.connection(plan.server.name)
    if conn then
        Sources.remember(file, conn.username, conn.password)
    end
    return file
end

--- Commit, then hand over. The tail every dialog answer and every silent open
--- shares, so the write cannot be forgotten on one of them.
local function openPlanned(host, plan)
    local file = commitMarker(plan)
    if not file then
        return nil
    end
    return openPrepared(host, file)
end

--- The marker for a catalog item, handed to the reader without a word.
---
--- The asking has already happened above this: `offerResume`'s dialog when the
--- reader chose this book, or nothing at all when the book *is* what they asked
--- for — a neighbour tap, the end of a book, the server's own "continue" button
--- pointing at another volume.
---
--- **This is what the jump button used to get wrong.** It called
--- `openCatalogItem`, which prepares the marker for the chosen item and then runs
--- `offerResume` for it with no `target` of its own — so the position was
--- re-resolved from `Catalog.resumeTarget` and a fresh dialog was built for a
--- book the reader had just named.
---
--- Exported rather than local, even though nothing outside this file's lower
--- half calls it: the jump button's default reaches it from inside `offerResume`,
--- which is *above* `planMarker`, and a `local function` down here would
--- resolve to a global at that call site — the failure `tools/check.py`'s fourth
--- pass exists to catch. Going through the module table costs one lookup and
--- sidesteps the ordering entirely.
---
--- Returns the marker path, or nil after reporting why.
function Open.openItemSilently(host, server, series, item)
    local plan = planMarker(server, series, item)
    if not plan then
        return nil
    end
    return openPlanned(host, plan)
end

--- The series' furthest-read item, fetched rather than skimmed from the catalog.
---
--- **The single answer both entry points end at**, which is why the filter lives
--- here rather than in either caller: the browser path reaches it through
--- `openAsBook` when its own feed cannot answer (see `registerBook`), and the
--- file path calls it directly. One URL, one selection, one answer.
---
--- The file-manager path has no browser feed in hand, so `freshResumeTarget` has
--- nothing to read — and the catalog is exactly the snapshot that made "opening
--- volume 3 offered volume 5" happen. One request buys a current answer.
---
--- Only when the network is up, only with `Net.RESUME_*` limits, and **never
--- without the stored language**: Suwayomi serves one library's translations from
--- one URL and selects between them by `?lang=`, so a defaulted language would
--- confidently report the progress of a translation the reader is not reading —
--- the trap `Catalog.serverLang` already carries a warning about.
---
--- **Two fetches, not one, when the server reports nothing unread.** A series
--- read to the end returns an empty `filter=unread` feed, and an empty feed is
--- not an answer — so the canonical feed is asked the other question, "where does
--- this series end". Without that second fetch the answer came from
--- `Catalog.resumeTarget`, whose knowledge ends at the last sync, and the same
--- tap gave two different chapters a moment apart: the first before the
--- background walk landed, the second after. The extra request costs one
--- `Net.RESUME_*`-bounded fetch, and only for a fully read series — which is
--- exactly where the catalogue's answer was worst.
---
--- Falls back to the catalog on any failure. A slightly stale answer beats a
--- dialog that never opens.
--- **Fetched on every open, and not memoised.** An earlier version cached the
--- answer per series for 45 seconds, to stop a reader tapping through several
--- volumes paying for a fetch each time. That window is longer than reading a few
--- pages: close a book, read on, reopen it inside 45s, and the dialog offered the
--- position from before — the server's button a good ten pages behind the truth,
--- which is the one thing asking the server was supposed to prevent. The cost
--- this trades back is one feed fetch per open, `Net.RESUME_*`-bounded and only
--- when the network is up.
local function currentResumeTarget(server, series)
    local driver = server and server.kind and Base.forKind(server.kind)
    local conn = server and Sources.connection(server.name)
    local why = "no driver for this server's kind"
    if not conn then
        why = "no saved catalog for this server"
    elseif not NetworkMgr:isConnected() then
        why = "no connection"
    elseif driver then
        why = "the feed could not be fetched"
        local ctx = { lang = Catalog.serverLang(server.name) }
        -- The server's own read flag, when it has one. Asked for as a *filter*
        -- rather than read off the full feed, because the flag is not in the
        -- feed's own data: a chapter the server flags read keeps whatever page
        -- counter it had, and the two disagree. Only the filtered feed answers
        -- "which chapters are done" without inference.
        local filter = driver.unreadFilter

        local function fetch(which)
            local url = driver.catalogURL(conn.url, series.remote_id, ctx, which)
            local ok, feed = pcall(Net.fetchFeed, url, {
                username = conn.username,
                password = conn.password,
                timeout = "resume",
            })
            return ok and feed or nil, url
        end

        -- **The filtered feed is an optimisation, and its failure must not lose
        -- the answer.** It answers "which chapter is next" directly where the
        -- server publishes a read flag, and that is all it is for; the canonical
        -- feed answers the same question from page counters, one request later.
        --
        -- **"Empty" and "failed" are different answers, and reading them as one
        -- is what made `▶` name chapter 1 for a series the server calls fully
        -- read.**
        --
        --   * the feed is *empty* — `"empty"`, its own reason since `fetchFeed`
        --     stopped calling it a parse failure: **the server has answered.**
        --     Nothing is unread, and that is a read *flag*, which outranks the
        --     page counter everywhere else in this file. So the canonical feed is
        --     asked only for where the series *ends*, and `lastIn` takes it —
        --     asking `firstUnfinishedOrLast` there let a single chapter with four
        --     pages of progress outvote the flag and pull the answer back to
        --     chapter 1.
        --   * the feed *failed* — we do not know what the server thinks, so the
        --     counters are the only evidence there is, and
        --     `firstUnfinishedOrLast` is the honest reading of them.
        --
        -- On the empty path the answer is still fetched rather than taken from
        -- `Catalog.resumeTarget`, whose knowledge ends at the last sync — the
        -- last *row* it had rather than the last chapter.
        local filtered_why, server_says_all_read
        if filter then
            local feed, url, reason = fetch(filter)
            if feed then
                -- `firstIn` returns `sequence[1]`, so a nil answer means the
                -- feed was empty and nothing more.
                local ok_fresh, target = pcall(freshResumeTarget,
                    driver, feed, url, ctx, series, firstIn)
                if ok_fresh and target then
                    return target
                end
                filtered_why = "nothing unread in the filtered feed"
                server_says_all_read = true
            elseif reason == "empty" then
                server_says_all_read = true
            else
                filtered_why = "the filtered feed could not be fetched"
            end
        end

        local feed, url = fetch(nil)
        if feed then
            local ok_fresh, target = pcall(freshResumeTarget, driver, feed, url, ctx, series,
                -- `lastIn` when the server already said there is nothing unread.
                -- Passing nil leaves `freshResumeTarget` its own default.
                server_says_all_read and lastIn or nil)
            if ok_fresh and target then
                return target
            end
            why = "the feed carried no entry for this series"
        else
            why = filtered_why or "the feed could not be fetched"
        end
    end

    -- The catalog only knows what the last sync saw, plus whichever chapters
    -- were opened since, so this answer can lag badly — which is the whole
    -- reason the fresh read above exists. Which of the two produced the answer
    -- is otherwise invisible, and the two need opposite fixes.
    logger.info("Meguru: resume point from the catalog, not the feed (",
        why, ")")
    local found = Catalog.resumeTarget(series.id)
    return found and found.item or nil
end

--- Open a catalog item whose stream is already known — the file-manager and
--- History path, where the marker is what is being opened and there is no feed
--- in hand.
---
--- Two cases, and the second is the reason this exists at all. An item that has
--- been opened before already has a marker on disk: open that file, and its
--- reading progress comes with it. An item that has never been
--- opened has no marker, and — for a Suwayomi chapter — no page stream either,
--- because a sync records every item of a series while deliberately fetching
--- nothing per item. Resolving that stream is one request, made here, at the
--- moment the reader asks for that chapter and at no other time.
---
--- Returns the path the marker *will* have, or nil after reporting why. Not a
--- file until the reader answers.
---
--- `target` is the caller's *fresh* answer to "where is this reader in this
--- series", and a caller that has one is obliged to pass it. Omitting it does
--- not mean "no answer" — it means "ask the catalog", and the catalog answers a
--- different question: `Catalog.resumeTarget` is the furthest row with any
--- progress, where the fresh read is the first *unfinished* one. On a series read
--- to volume 6 with 7 and 8 both started, those are volume 8 and volume 7, and
--- the reader got a row that opened volume 7 while the dialog's only "Continue"
--- button pointed at volume 8. That is the split `readingOrder` and
--- `firstUnfinished` exist to prevent, surviving on the one path that kept asking
--- the catalog. Every surviving caller passes a `target`; omitting it is kept
--- only because "no fresh answer available" is a state that can legitimately
--- recur.
---
--- The shape is a catalog row (what `Catalog.itemByKey` and `registerBook`'s
--- `resume` both return), not a `{ item, page }` pair: only `item_key` and
--- `last_read` are read off it.
function Open.openCatalogItem(host, server, series, item, target)
    local plan = planMarker(server, series, item)
    if not plan then
        return nil
    end

    Open.offerResume(host, server, series, item, {
        count = plan.count,
        -- The path, not the file: `offerResume` reads the sidecar to decide what
        -- to say, and a sidecar is found by path. The write is `openPlanned`'s.
        file = plan.path,
        target = target,
        open = function()
            openPlanned(host, plan)
        end,
    })
    -- Reports "planned", not "opened": when the resume dialog is up the book
    -- opens on the reader's tap, and a caller that treated the nil here as
    -- failure would be wrong. A caller that *uses* the path must not assume the
    -- file is there — `reader.lua` only asks whether this returned something.
    return plan.path
end

--- The resume offer for a marker opened from the file manager or History.
---
--- A different situation from `offerResume`, and not a variation of it. There is
--- no feed in hand here and no caller to hand the open back to — the reader is
--- being built by whoever called us — so this gathers its own data and starts the
--- reader itself.
---
--- `proceed(file)` opens `file`, or the one this was called for when given none.
function Open.offerResumeForFile(file, host, proceed)
    -- No early "is it new?" test here, deliberately. This path is where a book
    -- already being read has to be askable about — clicking volume 3 while the
    -- server says volume 5 — so whether it has been opened is one of the
    -- answers `offerResume` weighs, not a reason to skip it. It is also what
    -- `neverOpened` inside `offerResume` decides the *wording* of.

    -- pcall: a marker this plugin did not write, or a database that will not
    -- open, must cost the reader a dialog, never the book.
    local ok, desc = pcall(Marker.load, file)
    if not ok or type(desc) ~= "table" then
        proceed()
        return
    end

    -- `resolveMarker` returns the item and the series, not the server — the
    -- server row is reached through the series. Reading it as a third return
    -- would leave `server` nil, which is silent here: the fresh fetch would just
    -- not happen, and the chapter button would fail on `server.name` only once
    -- the reader tapped it.
    local item, series = Catalog.resolveMarker(desc.server_name,
        desc.series_remote_id, desc.item_key, desc.item_id)
    local server = series and Catalog.server(series.server_id) or nil

    Open.offerResume(host, server, series, item or desc, {
        -- The page comes from the marker itself, so it is free and works
        -- offline. The chapter target cannot: it is a fact about the whole
        -- series, and the catalog's copy of it is a snapshot from the last sync.
        count = tonumber(desc.count),
        file = file,
        target = series and currentResumeTarget(server, series) or nil,
        open = proceed,
        -- This one has no feed behind it, so it plans the marker and hands that
        -- file to whoever is opening this one.
        --
        -- Deliberately *not* through `handToReader`: `proceed` is the wrap's own
        -- unwrapped opener, so there is no second `showReader` to arm against.
        open_item = function(target)
            local plan = planMarker(server, series, target)
            if not plan then
                return
            end
            local other = commitMarker(plan)
            if other then
                proceed(other)
            end
        end,
    })
end

-- Saving ----------------------------------------------------------------------

--- Ask for a folder with KOReader's own picker — the same dialog the built-in
--- OPDS plugin uses for its download folder — then run `on_chosen(dir)`.
---
--- **Cancelling changes nothing.** It does not abort an open and it does not
--- clear the stored folder; it simply never calls back, which is what a
--- dismissal should mean. (This used to be the save dialog's question, where a
--- cancellation really did abort the open; now the only caller is the menu row
--- in `ui/menu.lua`, so the reader just stays on the folder they had.)
---
--- Without a picker the default folder is passed back, so the row keeps working
--- and re-renders with the folder it already showed.
function Open.chooseMarkerDir(on_chosen)
    local ok, DownloadMgr = pcall(require, "ui/downloadmgr")
    if not ok or type(DownloadMgr) ~= "table"
        or type(DownloadMgr.new) ~= "function"
        or type(DownloadMgr.chooseDir) ~= "function" then
        logger.warn("Meguru: no folder picker available; using the default marker folder")
        on_chosen(Marker.pickerStartDir())
        return
    end
    DownloadMgr:new{
        onConfirm = function(dir)
            if type(dir) ~= "string" or dir == "" then
                return
            end
            Settings.set("marker_dir", dir)
            logger.info("Meguru: marker folder chosen:", dir)
            on_chosen(dir)
        end,
    }:chooseDir(Marker.pickerStartDir())
end

-- Opening ---------------------------------------------------------------------

--- The OPDS-PSE stream among an entry's acquisitions.
---
--- A real stream template carries `{pageNumber}`; that placeholder is what tells
--- it apart from a plain "download the whole file" acquisition, which also has a
--- count.
function Open.findStream(item)
    for _, acq in ipairs(item and item.acquisitions or {}) do
        if type(acq) == "table" and acq.count
            and type(acq.href) == "string"
            and acq.href:find("{pageNumber}", 1, true) then
            return acq
        end
    end
    return nil
end

--- Turn a browsed stream into a marker and open it as a book.
---
--- Takes no destination folder, deliberately. `Marker.dirFor` defaults
--- `base_dir` to `Marker.baseDir()`, which is the one thing `Open.chooseMarkerDir`
--- and the menu row in `ui/menu.lua` write — and `planMarker` already relies on
--- exactly that. A folder passed in here was the save dialog's doing, and a second
--- way to name the destination is how the save paths drift apart: every entry
--- point must put a book in the same place, and with no parameter they cannot
--- disagree.
function Open.openAsBook(browser, item, stream)
    local server_name = catalogTitle(browser)
    if not server_name then
        return
    end
    local kind, kind_source = Open.serverKindFor(browser)
    local lang = langFromBrowser(browser)
    if lang then
        Catalog.setServerLang(server_name, lang)
    end
    local ctx = { lang = lang }

    local raw_entry = rawEntryFor(browser, stream)
    if raw_entry and not kind then
        -- Nobody has said what this catalog is: its feeds carry no `<author>` a
        -- driver knows, and no earlier open recorded a kind for it. Ask the
        -- drivers instead, which is the last chance to give this book a series —
        -- without one it can never have a next chapter.
        kind = Base.kindFor(raw_entry, stream.href, ctx)
        if kind then
            kind_source = "inferred"
            logger.info("Meguru: catalog", server_name,
                "signs itself with no known author; detected", kind, "from the entry")
        end
    end

    local registered
    if raw_entry then
        registered = registerBook(browser, server_name, kind, kind_source, raw_entry, stream, ctx)
    else
        -- Distinct from every bail inside `registerBook`: nothing there was even
        -- reached. Either the parse hook never saw a feed for this catalog, or
        -- none of its entries carries the stream being opened — which is what a
        -- feed the user navigated away from looks like. The retained feed is
        -- named because a bare "nothing retained" cannot tell a hook that never
        -- ran apart from a feed that was recorded and then replaced underneath
        -- the open, and those two need opposite fixes.
        local record = last_feed[server_name]
        local retained = record
            and (#(record.feed.entry or {}) .. " entry(ies) from " .. tostring(record.url))
            or "nothing"
        logger.info("Meguru: not catalogued: no retained entry matches this stream",
            "(catalog=" .. tostring(server_name) .. ", retained=" .. retained .. ")")
    end

    local desc = Marker.new{
        server_name      = server_name,
        series_remote_id = registered and registered.series.remote_id or nil,
        item_key         = registered and registered.item.item_key or nil,
        item_id          = registered and registered.item.id or nil,
        title            = Naming.stripAliasPrefix(item.title or item.text),
        template         = stream.href,
        count            = tonumber(stream.count) or 0,
        last_read        = tonumber(stream.last_read) or nil,
    }

    -- A marker that names no item is still a valid book; it just cannot be
    -- looked up. Deriving the fallback key from the stream URL is safe *here*
    -- and nowhere else: nothing ever looks this key up, so the API-key rotation
    -- that makes URL-derived keys dangerous in the catalog cannot duplicate
    -- anything — it only renames one unconcatenated marker.
    --
    -- 64 bits, not `keySuffix`'s 32, because this key is no longer only a name:
    -- it is the whole of this book's identity — with no series to disambiguate
    -- it — so `Marker.matches` and `Marker.pathFor` decide two markers are the
    -- same book by it, and a collision collapses two unrelated books onto one
    -- marker file.
    if not desc.item_key then
        desc.item_key = "flat:" .. Naming.digest64(stream.href)
        logger.info("Meguru: book has no catalog identity; marker stays flat")
    end

    local series = registered and registered.series or nil
    local dir = Marker.dirFor(desc, series, {
        -- No `base_dir`: the default is `Marker.baseDir()`, i.e. the stored
        -- preference, which is what `planMarker` uses too.
        server_folder = Settings.get("marker_server_dir") and true or false,
        series_folder_claimed = registered and Catalog.folderClaimedByOther(
            registered.server.id, series.name, series.id) or false,
    })
    -- Planned here, written on the answer — see `planMarker`. The marker is what
    -- puts the book in the library and in History, so writing it before the
    -- question leaves a phantom shelf entry behind when the question is
    -- dismissed with a tap past it.
    --
    -- Not shaped as a `planMarker` result, because the write below cannot go
    -- through `commitMarker`: this path remembers the credentials the reader
    -- just typed into the OPDS form, and `commitMarker` would look them up in
    -- `sources` instead — which is exactly what has not been flushed yet.
    local path = Marker.pathFor(dir, desc)
    local count = tonumber(desc.count)

    local manager = browser._manager
    local host = (manager and manager.ui) and manager or fallback_host

    -- Where the reader is, resolved before the dialog is built because the
    -- dialog is built from it.
    --
    -- `currentResumeTarget` fetches, so it is reached only when `registerBook`
    -- declined to answer — a server that flags chapters read, where the feed on
    -- screen by construction cannot. Nil either way means the catalog answers,
    -- which is `offerResume`'s own fallback.
    local resume_target = registered and registered.resume or nil
    if not resume_target and registered and registered.server_target then
        resume_target = currentResumeTarget(registered.server, registered.series)
    end

    -- The resume question comes before the handoff, not inside it: the two
    -- handoffs below are alternatives and both are terminal, so the choice has
    -- to be made while there is still something to choose about.
    Open.offerResume(host, registered and registered.server, series,
        -- `or desc` so a book that could not be catalogued still gets its own
        -- name on the buttons instead of "this book". Safe: `position` comes from
        -- `registered` on this path, so it is nil exactly when `item` is, and the
        -- `item_key` comparison in `offerResume` is never reached with a flat
        -- descriptor.
        registered and registered.item or desc, {
            count = count,
            file = path,
            -- What `registerBook` read off the feed the browser has just
            -- fetched, which is current; the catalog's answer is a snapshot.
            -- Fetched instead when the server flags chapters read, because the
            -- browser's feed cannot answer this one — see `registerBook`.
            target = resume_target,
            open = function()
                -- Everything the marker write used to do up front — the file,
                -- the catalog's `marker_path`, the in-memory credentials — now
                -- happens here, on the answer, and only for a book that is
                -- actually being opened. The credentials stay in memory only;
                -- nothing is written into the marker itself.
                local file = Marker.saveAt(path, desc)
                if not file then
                    -- Nothing was written, so there is nothing to open. Saying so
                    -- beats handing the reader a path to a file that is not
                    -- there: the reader would fail later, naming nothing.
                    UIManager:show(InfoMessage:new{
                        text = T(_("could not write the book file.\n%1"), path),
                    })
                    return
                end
                if registered then
                    Catalog.setMarkerPath(registered.item.id, file)
                end
                Sources.remember(file,
                    browser.root_catalog_username, browser.root_catalog_password)

                -- Prefer the built-in plugin's own open path: it closes the
                -- browser cleanly and hands the marker to ReaderUI.
                --
                -- One tail for both branches rather than a `return` and a
                -- fallthrough: the walk below has to start on the path OPDS
                -- actually takes, and that path used to leave here.
                local handed
                if manager and type(manager.openDownloadedFile) == "function"
                    and manager.opds_browser then
                    -- Not through `handToReader`, so this is the second place the
                    -- one-shot is armed — same reason and same instant: the dialog
                    -- above has already asked, and the `showReader` wrap must not
                    -- ask again.
                    handed = handOff(file, function() manager:openDownloadedFile(file) end)
                else
                    handed = openPrepared(host, file) ~= nil
                end

                -- Only when the book reached a reader. A handoff that failed
                -- leaves the reader in the browser, and the reason this walk
                -- exists — a book added, its series unpopulated — has not
                -- happened.
                --
                -- Deferred, because `SyncJob.run` calls `Sync.prepare`
                -- synchronously and that is a database read plus, on refusal, an
                -- UPDATE. Neither belongs inside the tap that is still building
                -- a reader.
                if handed then
                    UIManager:nextTick(function()
                        -- pcall'd so a mistake in here can never cost the reader
                        -- the book that just opened — but not *silently*: a
                        -- swallowed error would look exactly like a walk that
                        -- was never due, and those two need opposite fixes.
                        local ok_start, err = pcall(startBackgroundSync, registered)
                        if not ok_start then
                            logger.warn("Meguru: the background sync could not"
                                .. " be started:", err)
                        end
                    end)
                end
            end,
        })
end

--- Add the "Meguru this series" row to the dialog the built-in browser just
--- built. Silently does nothing when the dialog is not the expected shape or the
--- entry carries no stream — the official dialog is not ours to break.
function Open.injectBookRow(browser, item)
    local dialog = browser and browser.download_dialog
    if not dialog or type(dialog.buttons) ~= "table" then
        return
    end
    local stream = Open.findStream(item)
    if not stream then
        return
    end

    local buttons = dialog.buttons
    -- The official dialog's last row is always "Book cover | Book information";
    -- move it down so our row reads as an action block above it.
    local last_row = table.remove(buttons)
    table.insert(buttons, {}) -- separator
    table.insert(buttons, {
        {
            text = "\u{25B6} " .. _("Meguru this series"),
            font_bold = true,
            callback = function()
                UIManager:close(dialog)
                -- Opening a streamed book reads its first pages immediately, so
                -- this needs a connection the same way a download does; the
                -- manager prompts for one instead of failing. **This gate is not
                -- about the destination** — it is about the pages — which is why
                -- it stays now that the destination question is gone.
                NetworkMgr:runWhenConnected(function()
                    Open.openAsBook(browser, item, stream)
                end)
            end,
        },
    })
    if last_row then
        table.insert(buttons, last_row)
    end
    dialog:reinit()
    UIManager:setDirty("all", "ui")
    logger.dbg("Meguru: added \"Meguru this series\" button for", item.text)
end

return Open
