--[[--
Komga's OPDS surface.

A series-feed entry is one *book* — Komga's own unit, one CBZ with one page
stream — so entry ↔ stream is 1:1 and this driver stores the template directly,
exactly as Kavita's does. The lazy path `resolveStream` exists for does not
apply here.

**The one thing Komga does not put in an entry is the series it belongs to.**
`BookDto.toOpdsEntry` builds four links and none of them names a series: its
`thumbnail/small`, its `thumbnail`, its `file/…` acquisition, and its
`pages/{pageNumber}` stream. Whatever a Kavita entry gets for free — `seriesId`
riding along in its own stream query — Komga simply does not publish, so the
series identity has to come from **the feed the entry was read out of**, and
that is `ctx.url`. See `Komga.discover` — and, for the feeds that name no series
either, `Komga.resolveSeries`.

The page number is **zero based**, and that is worth writing down because it
looks like an off-by-one and is not: `OpdsController.kt` handles
`books/{bookId}/pages/{pageNumber}` with `getBookPageInternal(bookId,
pageNumber + 1, …)`, converting to its own one-based internal numbering. Meguru
is zero based at this seam too — `PSE.pageURL(template, pageno - 1, …)` in
`doc/document.lua` — so the template goes into the marker verbatim and nothing
here adjusts a number. PROTOCOL.md carries the evidence.
--]]

local Base = require("meguru/driver/base")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Komga = {}

--- Matched against the lowercased feed-level `<author>` name and uri. Komga
--- signs every feed with `<name>Komga</name>` and its own GitHub uri.
Komga.authorSignatures = { "komga" }

--- The stream template a Komga marker carries, for a marker written before the
--- descriptor held `server_kind`.
---
--- Three needles, not one: `streamSignatures` are plain substrings, and every
--- Kavita template also contains `/opds/` — its API key is the segment right
--- after it. Requiring all three is what keeps a Komga-shaped claim off a
--- Kavita URL. The `{pageNumber}` half is spelled the same way the stream rel
--- spells it, so a template that lost its substitution fails the test rather
--- than matching on the path alone.
Komga.streamSignatures = { { "/opds/", "/books/", "/pages/{pageNumber}" } }

--- The series id inside a feed's own URL: `…/opds/v1.2/series/{id}`.
---
--- Anchored on the literal segment rather than on position, and cut at `/` or
--- `?` so a sorted or paginated variant (`?page=2`) still answers with the id.
local SERIES_IN_PATH = "/series/([^/?]+)"

--- The book id inside a stream template: `…/books/{bookId}/pages/{pageNumber}`.
local BOOK_IN_TEMPLATE = "/books/([^/]+)/pages/"

--- The REST prefix and the book id inside a stream template:
--- `…/opds/v1.2/books/{bookId}/pages/{pageNumber}`.
---
--- Anchored on the literal segment rather than on position, like the two above,
--- and it captures what *precedes* `/opds/` — which is the whole point: a Komga
--- behind a reverse proxy keeps its path prefix on both of its surfaces, so the
--- REST URL is that prefix with the OPDS path rewritten, never rebuilt from
--- `scheme://host:port`. See `Komga.progressRequest` and `Komga.seriesCover`.
local REST_IN_TEMPLATE = "^(.*)/opds/v1%.2/books/([^/]+)/pages/"

--- Identify the series a browsed entry belongs to.
---
--- **From the feed, because the entry cannot answer it.** Komga publishes no
--- series handle on a book entry — not in `<id>`, which is the book's own, and
--- not in any of its four links. The feed URL is the only place the series id
--- appears, and the engine has it: `ctx.url` is the URL of the feed the entry
--- was parsed out of.
---
--- Returns nil with no `ctx.url`, and that refusal is the feature. A caller with
--- no browsing context cannot know which series an entry belongs to, and
--- guessing from a title would sync a library against a feed that describes
--- something else.
---
--- **An aggregate refuses here too, and the refusal is still right.** Komga's
--- `books/latest`, `ondeck` and `keep-reading` list books across every series and
--- carry no series id anywhere at all, so this answers nil for each of their
--- entries. What is *not* right, and what `resolveSeries` below exists for, is
--- leaving the book unreachable: the id is one REST request away, and the
--- question is only who may spend it. Not this function — it is called in a loop
--- over a whole feed (`freshResumeTarget`, `feedSeries`) and over every
--- registered driver (`kindFor` for any server whose `<author>` matched nothing),
--- so a request here would turn one tap into a walk of the network instead of a
--- walk of the feed. The caller that may spend it is one that has a **book**,
--- which is one request for one open.
---
--- `kindFor` is unaffected: it is the fallback for a server whose `<author>`
--- matched nothing, and Komga's author always matches — and it must stay
--- unaffected, which is the whole reason the request lives in a second hook
--- rather than behind this one.
function Komga.discover(entry, _stream, ctx)
    local feed_url = type(ctx) == "table" and ctx.url
    if type(feed_url) ~= "string" or feed_url == "" then
        return nil
    end
    local remote_id = feed_url:match(SERIES_IN_PATH)
    if not remote_id then
        return nil
    end
    return {
        series_remote_id = remote_id,
        -- The entry was read out of a series feed, which is where the identity
        -- came from.
        discovered_from = "series",
    }
end

--- The canonical series feed: the one URL that lists this series' books.
---
--- `/catalog` is stripped because the two callers hand over different things.
--- `Feed.plan` passes `baseURL(conn.url)`, which only trims a trailing slash,
--- while `currentResumeTarget` passes the configured URL raw — and the
--- configured URL is the catalogue the user typed into the OPDS browser, which
--- for Komga is `…/opds/v1.2/catalog`. Komga serves a book list at
--- `…/opds/v1.2/series/{id}` and nothing at `…/catalog/series/{id}`, so a
--- driver that appended to whichever it was given would work from one entry
--- point and 404 from the other, which reads as "History has no resume point".
---
--- What it deliberately does *not* do is fall back to the catalogue root when
--- the pattern does not match: a wrong base builds a URL that describes a
--- different series, and returning nothing is the honest answer.
function Komga.catalogURL(base_url, series_remote_id, _ctx)
    if type(base_url) ~= "string" or base_url == "" then
        return nil
    end
    local base = base_url:gsub("/+$", ""):gsub("/catalog$", "")
    return string.format("%s/series/%s", base, series_remote_id)
end

--- One page of the canonical feed to normalized items.
---
--- `PSE.streamFromEntry` does the whole of the wire format: the absolute
--- template from the `stream` rel, `pse:count`, and `pse:lastRead` when Komga
--- publishes one. It publishes none until a book has progress — the attribute
--- is `readProgress?.page`, absent for a book nobody has opened — which is why
--- a fresh Komga library looks like a server that tracks nothing. It does.
---
--- The key is cut from the **template**, not taken from `entry.id`, and that is
--- the same call `Kavita.parseCatalogPage` makes: the key and the stream are
--- then two readings of one string and cannot drift apart. `entry.id` happens
--- to hold the same book id today, so a template that stopped carrying it would
--- be a silent divergence rather than a visible one.
---
--- The cover is the entry's own. Komga emits `image/thumbnail` and `image` on
--- every book, so no volume of a series falls back to page 1 of its own stream
--- — the same page for the whole series, in a larger and slower form.
function Komga.parseCatalogPage(feed, base_url, _ctx)
    local items = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local template, count, last_read = PSE.streamFromEntry(entry, base_url)
        local item_key = template and template:match(BOOK_IN_TEMPLATE)
        if item_key then
            items[#items + 1] = Base.item({
                item_key        = item_key,
                item_key_source = "bookId",
                title           = entry.title,
                template        = template,
                page_count      = count,
                last_read       = last_read,
                cover_url       = Base.coverFromEntry(entry, base_url),
            })
        end
    end
    return items
end

--- The series' own artwork, which the feed does not carry.
---
--- **Komga publishes no series image in OPDS at any level** — not on a series
--- entry at `/series`, and not on the feed of `/series/{id}`, whose only links
--- are `self`, `start` and `next`. The images there belong to *books*. So
--- without this hook `Base.coverFromFeed` falls through to the entry's artwork,
--- and a value stored once per series is taken from whichever volume happened to
--- be opened first — a different picture depending on the order a reader taps.
---
--- The real one is in Komga's REST surface, and it is the same server the rest
--- of this driver already assumes: `/api/v1/series/{id}/thumbnail`, a JPEG.
--- Smaller than a volume's cover (211x300 against 844x1200), and worth it for
--- being *the* series' picture rather than *a* volume's.
---
--- Everything needed is already in `base_url`, which is why this takes no `ctx`.
---
--- **The OPDS path is rewritten, not the origin taken.** A Komga behind a
--- reverse proxy with a path prefix keeps that prefix on both of its surfaces
--- (`http://host/komga/opds/…` and `http://host/komga/api/v1/…`), so rebuilding
--- from `scheme://host:port` would drop it and the cover would 404 — the same
--- trap `Komga.catalogURL` documents for `/catalog`, one surface over. Keeping
--- whatever precedes `/opds/v1.2/` keeps the prefix.
function Komga.seriesCover(_feed, _entry, base_url)
    if type(base_url) ~= "string" or base_url == "" then
        return nil
    end
    local prefix, remote_id = base_url:match("^(.*)/opds/v1%.2/series/([^/?]+)")
    if not prefix or not remote_id then
        return nil
    end
    return string.format("%s/api/v1/series/%s/thumbnail", prefix, remote_id)
end

--- Where the reader is, described for `meguru/progress` to send.
---
--- **The REST surface, not the OPDS one.** `/api/v1/books/{id}/read-progress` is
--- what fills `readProgress`, and `readProgress?.page` is what `OpdsController.kt`
--- publishes as `pse:lastRead` on the feed — so this is the write end of the loop
--- whose read end is `PSE.streamFromEntry`. Komga's OPDS **v2** feed carries a
--- `progression` link that looks like a natural home for this and is not one: it
--- is the Readium surface, aimed at EPUB readers, and Komga does not feed it back
--- into `readProgress`. Writing there would move the open end, not close it.
---
--- **Two numbers, two bases, and neither is converted here.** The page in a
--- stream URL is zero-based (`doc/document.lua` passes `pageno - 1`); the page
--- this takes is one-based, which is what the reader pages with and what
--- `readProgress.page` is. It goes out unchanged. A driver that "unified" the two
--- would be off by one on one surface or the other, and only one of them is
--- wrong to be off by one.
---
--- **The prefix is taken, not rebuilt** — the same call `Komga.seriesCover` makes
--- above, and the regex is required to name `/opds/v1.2/` rather than matching
--- any version: a loose pattern would widen the match for nothing, since a v2
--- template cannot be in a marker at all (v2 publishes no PSE link).
---
--- The body is built by hand — one field, a number, nothing to escape, so nothing
--- drags in an encoder.
---
--- **One field and not two, and that is a correction rather than a preference.**
--- The first version sent `{"page":N,"completed":B}` with `B` computed from the
--- marker's own `count`, on the reasoning that saying `false` for a book Komga has
--- finished is the one value that can un-read it. The server's own schema is
--- better than that reasoning: `ReadProgressUpdateDto` documents `completed` as
--- optional and *derived* — "set accordingly depending on the page passed and the
--- total number of pages in the book" — so Komga answers it from its own count,
--- which is the only count that is authoritative. Ours is a snapshot in a marker,
--- and a book replaced on the server since would have made it say `true` about a
--- book that is not finished. `PATCH` is also the verb the endpoint accepts: a
--- `PUT` here is answered **405** (Komga 1.27.0; its own OpenAPI lists `PATCH` and
--- `DELETE`), which is what a first, derived-not-observed version of this cost.
---
--- Nil is the ordinary answer here for a marker that carries no usable template,
--- no count, or a page below 1 — and for every future Komga marker the template
--- is the same string the page fetches are built from, so the book being reported
--- on and the book being paged cannot diverge.
function Komga.progressRequest(desc, page)
    if type(desc) ~= "table" then
        return nil
    end
    local template = desc.template
    local total = tonumber(desc.count)
    local wanted = math.floor(tonumber(page) or 0)
    if type(template) ~= "string" or template == "" then
        return nil
    end
    if wanted < 1 or not total or total < 1 then
        return nil
    end
    -- The count is required for this and nothing else, and clamping *down* is the
    -- right direction: the last page is a position Komga accepts, where a page
    -- past the end is `400 Page number does not exist`.
    if wanted > total then
        wanted = total
    end
    local prefix, book_id = template:match(REST_IN_TEMPLATE)
    if not prefix or not book_id then
        return nil
    end
    return {
        url          = string.format("%s/api/v1/books/%s/read-progress", prefix, book_id),
        content_type = "application/json",
        body         = string.format('{"page":%d}', wanted),
    }
end

--- The series name from the series feed's own `<title>`, which Komga writes as
--- the series title and nothing else.
---
--- **Gated on the feed being a series feed**, which is what `ctx.url` answers.
--- The same element carries "Latest books" or "On Deck" on an aggregate, and
--- returning that as a series name would put a shelf of unrelated books under a
--- heading that names none of them. Where the feed cannot be trusted the entry
--- title is asked instead, and Komga titles every volume
--- `"<Series> v<NN> (<group>) (<group>)"` — a shape `Naming.deriveSeries`
--- already peels apart, release groups included.
function Komga.seriesName(feed, entry, ctx)
    local feed_url = type(ctx) == "table" and ctx.url
    if type(feed_url) == "string" and feed_url:match(SERIES_IN_PATH) then
        local from_feed = feed and feed.title
        if type(from_feed) == "string" and from_feed ~= "" then
            -- No suffix to strip, unlike Kavita's " - Storyline": Komga writes
            -- the series title and nothing else. `stripSeriesLabel` stays for
            -- the leading "<word>:" a feed may add, which is harmless here and
            -- is the one normalisation every series name gets.
            return Naming.stripSeriesLabel(from_feed)
        end
    end
    local derived = Naming.deriveSeries(entry and entry.title or "")
    if derived and derived ~= "" then
        return derived
    end
    return nil
end

--- The series of a book whose feed named none, asked of the server.
---
--- **What this is for.** `Komga.discover` recovers the series id from the feed a
--- book was read out of, and an aggregate — `books/latest`, `ondeck`,
--- `keep-reading` — is a feed that names no series at all. Without this, such a
--- book gets a marker with no series: no series folder, no neighbours, no resume.
--- With it, one request answers what the feed could not, and the book is
--- indistinguishable from one opened out of its series feed.
---
--- **One request for one open, which is the whole reason it is a hook of its own
--- and not code inside `discover`.** That one is called per *entry* over a whole
--- feed and over every driver; this is called once, by a caller holding a book.
--- See `discover` above for the rest of that argument.
---
--- **The id comes out of the stream template, and the prefix is taken rather than
--- rebuilt** — the same call `Komga.seriesCover` and `Komga.progressRequest` make
--- and for the same reason: a Komga behind a reverse proxy keeps its path prefix
--- on both of its surfaces, so `…/komga/api/v1/books/{id}` is the OPDS path
--- rewritten, never `scheme://host:port` re-derived. `entry.id` cannot serve
--- here: it is a bare id with no prefix on it.
---
--- **The name comes back too, and that is not a convenience.** `seriesName` would
--- otherwise derive it from the *book's* title, peeling trailing parentheticals
--- and volume tokens as it goes — so a series called `Foo` with a volume called
--- `Foo (An Anthology) v01` would name a folder `Foo (An Anthology)`, and
--- `Marker.dirFor` keys the folder on the name alone. Two names are two folders
--- for one series, decided by which feed the reader came through. `seriesTitle`
--- is the same string the series feed's own `<title>` carries, so answering with
--- it makes the two entry points agree by construction rather than by derivation.
--- It is normalised here, as the feed's title is above, so both paths land on one
--- spelling.
---
--- **Nil is the ordinary answer**, and it costs this book nothing it does not
--- already lack: no template to read an id out of, a book the server will not
--- serve, a REST surface closed by a deployment — each ends at the same flat
--- marker the reader gets today.
function Komga.resolveSeries(entry, stream, ctx, fetch_json)
    local template = type(stream) == "string" and stream or nil
    if not template or type(fetch_json) ~= "function" then
        return nil
    end
    local prefix, book_id = template:match(REST_IN_TEMPLATE)
    if not prefix or not book_id then
        return nil
    end
    local book = fetch_json(string.format("%s/api/v1/books/%s", prefix, book_id))
    local series_id = type(book) == "table" and book.seriesId or nil
    if type(series_id) ~= "string" or series_id == "" then
        return nil
    end
    local name = type(book.seriesTitle) == "string" and book.seriesTitle or ""
    if name == "" then
        name = nil
    else
        name = Naming.stripSeriesLabel(name)
    end
    return {
        series_remote_id = series_id,
        series_name      = name,
        -- The entry was read out of an aggregate, which is where the question
        -- came from even though the answer did not.
        discovered_from  = "aggregate",
    }
end

-- `resolveStream` is left to the default in base.lua: the stream arrives with
-- the entry, so there is nothing to fetch on open.
--
-- `orderFromTitles` is deliberately not set either, and unlike `unreadFilter`
-- that is a positive claim about this server rather than an absence: Komga sorts
-- a series' books by `metadata.numberSort` ascending before it emits them
-- (`OpdsController.kt`, `getOneSeries`), so the feed arrives in reading order and
-- the number in a title may only ever fight it. Leaving it unset is what gives
-- `Feed.ordered` feed order — see `Suwayomi.orderFromTitles` for the server that
-- does the opposite.
--
-- `unreadFilter` is deliberately not set. Komga has no "unread" feed to ask —
-- its OPDS read flag is not a filter, it is a per-book `pse:lastRead` that
-- arrives on the ordinary feed — so the page-progress rules are the right ones
-- here, and they are what Kavita gets.

Base.register("komga", Komga)

return Komga
