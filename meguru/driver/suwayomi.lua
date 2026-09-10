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
local SERIES_IN_PATH = "/series/(%d+)/"
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
    for _, link in ipairs(entry and entry.link or {}) do
        local href = type(link) == "table" and link.href
        if type(href) == "string" then
            local series = href:match(SERIES_IN_PATH)
            if series then
                return series
            end
        end
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
