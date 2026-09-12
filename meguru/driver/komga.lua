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
that is `ctx.url`. See `Komga.discover`.

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
--- something else. The cost is that an aggregate — Komga's `books/latest`,
--- `ondeck`, `keep-reading` — is not openable: those list books across every
--- series and carry no series id anywhere at all. Adding one would mean a REST
--- request per entry, which `discover` is in no position to make; it is called
--- in a loop over a whole feed (`freshResumeTarget`, `feedSeries`) and by
--- `kindFor` for every unknown server.
---
--- `kindFor` is unaffected: it is the fallback for a server whose `<author>`
--- matched nothing, and Komga's author always matches.
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
