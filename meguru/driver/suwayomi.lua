--[[--
Suwayomi's OPDS surface.

Two things about it drive the whole shape of this file, both observed on a live
instance (see PROTOCOL.md):

  * **A chapter entry carries no stream.** It links to a metadata feed, which
    returns a feed containing one entry that holds the `stream` link. So
    `resolveStream` is real I/O here, and `parseCatalogPage` stores
    `template = NULL` on purpose — resolving it at sync time would be one HTTP
    request per chapter, so a 500-chapter series would take 500 requests to sync.

  * **The chapter number is not an identity.** The feed contradicts itself:
    a chapter titled "Chapter 56.5" sits at path position 58, and numbers are
    renumbered when metadata is refreshed. The `<id>` URN
    (`urn:suwayomi:chapter:16851`) is the only stable handle, so that — not the
    number — is the item key.
--]]

local Base = require("meguru/driver/base")
local Naming = require("meguru/naming")
local PSE = require("meguru/pse")

local Suwayomi = {}

--- Matched against the lowercased feed-level `<author>` name and uri.
Suwayomi.authorSignatures = { "suwayomi" }

local CHAPTER_URN = "^urn:suwayomi:chapter:(.+)$"
local MANGA_URN = "^urn:suwayomi:manga:(.+)$"

-- The same chapter is spelled differently by the two feeds it appears in: the
-- chapter list says `urn:suwayomi:chapter:9345`, and its own metadata feed says
-- `urn:suwayomi:chapter:9345:metadata`. Observed on a live instance, and
-- load-bearing — a sync builds keys from the list while an open builds one from
-- the metadata feed, so without stripping this suffix the two never agree and
-- every book opened would add a second, unreconcilable row for its chapter.
--
-- Only this one suffix is removed, rather than truncating at the first colon:
-- that way an id containing a colon for some other reason survives intact.
local METADATA_SUFFIX = ":metadata"

local function chapterKeyFromId(id)
    local key = type(id) == "string" and id:match(CHAPTER_URN)
    if not key then
        return nil
    end
    if key:sub(-#METADATA_SUFFIX) == METADATA_SUFFIX then
        key = key:sub(1, #key - #METADATA_SUFFIX)
    end
    return key ~= "" and key or nil
end
-- The trailing "chapter" is load-bearing, not decoration. Matching plain
-- `/series/{id}/` made this driver claim *Kavita* entries: a Kavita entry's
-- download link is
--   /api/opds/<KEY>/series/17517/volume/117120/chapter/180346/download/….cbz
-- which contains `/series/17517/`. Since `kindFor` refuses an entry two drivers
-- claim, that turned every Kavita server whose <author> the sniff missed into an
-- uncatalogued one — the exact failure this pattern-free version was meant to
-- prevent. Both documented Suwayomi paths put `chapter` right after the id
-- (`/series/{id}/chapters`, `/series/{id}/chapter/{n}/metadata`), and Kavita puts
-- `volume`, so requiring it separates them on evidence rather than on luck.
local SERIES_IN_PATH = "/series/(%d+)/chapter"
-- A chapter's page stream embeds the manga id ("/manga/3649/chapter/35/page/").
-- The same id space the chapter-list paths use — the old plugin relied on
-- exactly that, matching a list row by looking for "/<manga_id>/chapter/" in
-- it — and it is the only handle available when the entry being opened is the
-- single-entry metadata feed, which links to nothing but its own stream.
local MANGA_IN_STREAM = "/manga/(%d+)/chapter/"

local DEFAULT_LANG = "en"

--- The chapters feed titles itself "<Manga> Chapters"; see `seriesName`.
local SERIES_SUFFIX = " Chapters"

--- The language segment every Suwayomi URL carries. Inherited from whatever the
--- user was browsing with, because a library can hold several translations of
--- one manga and `lang` is what selects between them.
local function lang(ctx)
    local value = ctx and ctx.lang
    if type(value) == "string" and value ~= "" then
        return value
    end
    return DEFAULT_LANG
end

--- The manga id behind an entry, from whatever it happens to offer: on a series
--- entry the `<id>` is a manga URN, on a chapter list row any link path names
--- the series, and on a chapter's own metadata feed the only handle is the
--- stream the cursor was opened with.
local function seriesIdFrom(entry, stream)
    local id = entry and entry.id
    if type(id) == "string" then
        local manga = id:match(MANGA_URN)
        if manga then
            return manga
        end
    end
    local links = entry and entry.link or {}
    for _, link in ipairs(links) do
        local href = type(link) == "table" and link.href
        if type(href) == "string" then
            local series = href:match(SERIES_IN_PATH)
            if series then
                return series
            end
        end
    end
    -- The entry's *own* stream link, before the passed-in one. A metadata-feed
    -- entry is the case that needs it: its links are `alternate` (the scanlator's
    -- web page), `open-access` (the CBZ) and the stream, with no `/series/` path
    -- anywhere, so without this the driver recognised only the entry it was
    -- handed a cursor for. `Kavita.discover` already falls back to the entry's
    -- own link (`stream or streamHref(entry)`); this is the same fallback, and
    -- `kindFor` — which calls `discover` with no cursor at all — depends on it.
    -- Read as a bare href, never absolutized: `MANGA_IN_STREAM` matches a path,
    -- and `url.absolute` with no base returns nil often enough to be a footgun.
    local link = Base.link(entry, PSE.STREAM_REL)
    local own = link and link.href
    local series = type(own) == "string" and own:match(MANGA_IN_STREAM)
    if series then
        return series
    end
    if type(stream) == "string" then
        return stream:match(MANGA_IN_STREAM)
    end
    return nil
end

--- Identify the series a browsed entry belongs to. Never guesses: without a
--- series id the caller must ask the user rather than sync an arbitrary series.
function Suwayomi.discover(entry, stream, ctx)
    local remote_id = seriesIdFrom(entry, stream)
    if not remote_id then
        return nil
    end
    return {
        series_remote_id = remote_id,
        -- The stream carries the manga id, so this holds whatever page the book
        -- was opened from — including an aggregate, whose chapter entries do
        -- not link to their series at all.
        discovered_from = "stream",
        lang = lang(ctx),
    }
end

--- The canonical, paginated chapter list.
---
--- `sort=number_asc` is load-bearing: the default order is *descending*, so
--- without it the whole series would be indexed newest-first and every "next
--- chapter" would run backwards through the book.
function Suwayomi.catalogURL(base_url, series_remote_id, ctx)
    return string.format("%s/series/%s/chapters?lang=%s&sort=number_asc&filter=all",
        base_url, series_remote_id, lang(ctx))
end

--- One page of the canonical feed to normalized items. No position numbers and
--- no series metadata: the engine assigns feed positions, the catalog owns
--- everything else.
---
--- `template` and `page_count` stay nil — that is the lazy path, and the engine
--- resolves them on first open.
--- No `cover_url`, deliberately, and it is the one thing Kavita's driver does
--- that this one cannot. A Kavita series entry carries its own `image` links; a
--- Suwayomi *chapter-list* entry carries only `rel=subsection` — no image at
--- all. A chapter's own artwork exists solely in its metadata feed, reachable
--- only by fetching that feed per chapter, which is one HTTP request each and
--- precisely what the sync rules forbid spending.
---
--- So chapters fall back to the series cover, on purpose. Should that ever be
--- wanted differently, it is one line here: `cover_url =
--- Base.coverFromEntry(entry, base_url)` — the metadata feed's entry *does*
--- carry `<link rel="http://opds-spec.org/image" …/page/0>`, which Suwayomi
--- titles "chapter cover". Because `ui/open.lua`'s `driverItemFor` reaches
--- drivers through this same function, covers would then fill in as chapters
--- are opened, at no extra request and no extra sync cost.
--- The chapter's reading progress, read out of the entry's `<summary>` prose.
---
--- Suwayomi reports progress nowhere machine-readable on this feed. A
--- chapter-list entry carries no stream link, so it carries no PSE attributes at
--- all, and the metadata feed that does state `pse:lastRead` costs one request
--- per chapter — which is exactly what a sync may not spend. What the list entry
--- does carry is:
---
---   <summary>My Girlfriend is 8 Meters Tall | Chapter 63| Przez Unknown| Postęp: 0 z 31</summary>
---
--- So only the *digits* are read, never the words. The last two integers of the
--- final `|` field are `read` and `total`, and `?lang=` localises the prose
--- without touching the numbers, so "Postęp: 0 z 31" and "Progress: 0 of 31"
--- parse alike. Every failure — no `|`, fewer than two numbers, a count outside
--- its own total — returns nil, which is the honest outcome rather than a guess:
--- no progress hint, i.e. precisely the behaviour before this existed.
---
--- Deliberately *not* returned as `page_count`: that number arrives
--- authoritatively as `pse:count` when the stream is resolved, and a figure
--- scraped out of prose must not displace one the server stated.
---
--- One shape this reads wrongly, and knowingly: a *fractional* first number, as
--- in `Postęp: 0.5 z 31`, yields 5 — the pair `(5, 31)` matches and a dot is
--- invisible to a digits-only scan. Not defended against, because progress here
--- is a page index and no fractional one has been observed in the field; the
--- cost of meeting one is a starting page that is a few off, which is a swipe to
--- correct. It is recorded because a silent wrong answer is worth knowing about,
--- not because it needs code.
local function progressFromSummary(summary)
    if type(summary) ~= "string" then
        return nil
    end
    -- `|` is not a pattern metacharacter, and the anchored greedy class cannot
    -- cross one, so this lands on the *last* field.
    local field = summary:match("|([^|]*)$") or summary
    local numbers = {}
    for value in field:gmatch("%d+") do
        numbers[#numbers + 1] = tonumber(value)
    end
    local read = numbers[#numbers - 1]
    local total = numbers[#numbers]
    if not read or not total or read > total then
        return nil
    end
    -- 0 is returned as 0, and that is the whole point: Suwayomi writes progress
    -- as "0 of 31" for a chapter that is not read, including one that *was* read
    -- and has been reset. Returning nil there would leave `Catalog.upsertItem`'s
    -- COALESCE holding the old value, so a chapter marked unread would stay the
    -- furthest-read one here forever. See `PSE.attributesFromLink`, which carries
    -- the same rule for Kavita's `lastRead="0"`.
    return read
end

function Suwayomi.parseCatalogPage(feed, base_url, ctx)
    local items = {}
    for _, entry in ipairs(feed and feed.entry or {}) do
        local item_key = chapterKeyFromId(entry.id)
        if item_key then
            local detail = Base.link(entry, "subsection")
            items[#items + 1] = Base.item({
                item_key        = item_key,
                item_key_source = "entry.id",
                title           = entry.title,
                detail_url      = detail and Base.absolute(base_url, detail.href) or nil,
                template        = nil,
                page_count      = nil,
                last_read       = progressFromSummary(entry.summary),
            })
        end
    end
    return items
end

--- The series name, from the feed title when that title says one.
---
--- Two feed titles carry it, in different shapes, and which one is seen depends
--- entirely on where the user is:
---
---   chapter list   "… Chapters"                     <- strip the suffix
---   metadata feed  "<Manga> | Chapter 1 | Details"  <- first "|" field
---
--- Each is checked for the *evidence* that makes it a series title, never just
--- for being non-empty: a feed title that matches neither shape is not naming a
--- series, and taking it anyway would name the series after whichever chapter
--- happened to be opened.
---
--- Falling back to the entry's own title is weak by design — a chapter entry is
--- titled "Chapter 1" and yields nothing — so the feed title is what carries
--- this. Its shape varies by source and cannot be assumed: "Ch. 5",
--- "Chapter 51", "Chapter 56.5".
function Suwayomi.seriesName(feed, entry, _ctx)
    local title = feed and feed.title
    if type(title) == "string" then
        if #title > #SERIES_SUFFIX and title:sub(-#SERIES_SUFFIX) == SERIES_SUFFIX then
            local name = title:sub(1, #title - #SERIES_SUFFIX)
            if name ~= "" then
                return name
            end
        end
        local piped = title:match("^%s*(.-)%s*|")
        if piped and piped ~= "" then
            return Naming.stripSeriesLabel(piped)
        end
    end
    local derived = Naming.deriveSeries(entry and entry.title or "")
    if derived and derived ~= "" then
        return Naming.stripSeriesLabel(derived)
    end
    return nil
end

--- Fetch a chapter's metadata feed and pull the stream out of it.
---
--- This is the only place in the plugin where a driver causes I/O, and it goes
--- through the injected `fetch` so the engine keeps ownership of credentials,
--- timeouts and logging.
function Suwayomi.resolveStream(item, fetch, _ctx)
    if not item.detail_url or not fetch then
        return nil
    end
    local feed = fetch(item.detail_url)
    if not feed then
        return nil
    end
    -- A `<feed>` wrapping exactly one `<entry>`, which holds the stream.
    local entry = feed.entry and feed.entry[1]
    if not entry then
        return nil
    end
    -- Absolute against the metadata URL: the stream href is a path
    -- ("/api/v1/manga/3649/chapter/35/page/{pageNumber}"), not a full URL.
    return PSE.streamFromEntry(entry, item.detail_url)
end

Base.register("suwayomi", Suwayomi)

return Suwayomi
