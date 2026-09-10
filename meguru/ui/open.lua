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

  * register the book — server, series and item — so the library view lists it
    and a later sync has something to attach to;
  * write a marker thin enough to open the stream with no database at all.

It deliberately does **not** walk the series feed. That is `sync.lua`, it costs
tens of seconds, and it must never sit between a tap and a book opening.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local CheckButton = require("ui/widget/checkbutton")
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

--- Which driver serves this catalog: a manual override, else what was sniffed
--- this session, else what the catalog recorded when a book was last opened
--- from it, else nothing.
---
--- The manual override wins outright because a sniff is a heuristic, and one
--- wrong classification otherwise makes a server permanently unsyncable. The
--- sniff outranks the stored kind because it is current: the stored one may
--- have been written by a build that guessed differently.
function Open.serverKindFor(browser)
    local name = catalogTitle(browser)
    if not name then
        return nil
    end
    local server = Catalog.serverByName(name)
    if server and server.kind_source == "manual" then
        return server.kind, server.kind_source
    end
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
    -- Drivers leave `feed_index` to the engine, and this path reaches them
    -- without going through the sync that would otherwise number the page. It
    -- did not number it, and the column is NOT NULL: every open died at the
    -- insert on the constraint, after the series row had already been written.
    -- Provisional — a metadata-feed page is one entry deep, so the position
    -- means nothing until the next sync overwrites it.
    Catalog.numberPositions(items)
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

--- The series' furthest-read item, read from the feed the browser just fetched.
---
--- The catalog cannot answer this question. `items.last_read` is a snapshot from
--- the last sync, and the only thing that refreshes a row in between is opening
--- that very chapter — so the catalog is fresh exactly where the reader has
--- clicked and stale everywhere else, and the furthest item *known* is routinely
--- not the furthest item *read*. Asking the feed the reader is already looking at
--- costs nothing: `OPDSBrowser` fetched it to draw the list on screen.
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
--- Returns a catalog row, because the caller opens it as one. The target is
--- upserted on the way, which is the same write `registerBook` makes for the
--- book actually being opened, from the same feed, for the same series.
local function freshResumeTarget(driver, feed, feed_url, ctx, series)
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
    local best
    for _, parsed_item in ipairs(parsed or {}) do
        if type(parsed_item.last_read) == "number" and parsed_item.last_read > 0 then
            best = parsed_item
        end
    end
    if not best then
        logger.info("Meguru: nothing in series", series.remote_id,
            "is marked read in this feed - resume point falls back to the catalog")
        return nil
    end

    logger.info("Meguru: the feed says", best.display_title or best.title,
        "is the furthest read in series", series.remote_id)

    Catalog.numberPositions(parsed)
    Catalog.upsertItem(series.id, best, Catalog.nextTimestamp())
    return Catalog.itemByKey(series.id, best.item_key)
end

--- Register the server, series and item of an opened book, returning the item's
--- catalog row.
---
--- Returns nil when the series cannot be identified or the item cannot be built.
--- That is a supported outcome, not a failure: the marker alone opens and reads,
--- and the book merely has no neighbours and no new-chapter count until
--- something else brings its series into the catalog.
---
--- Note the order: the server row is written before the driver is resolved, and
--- that is the point of the ordering rather than an accident. The kind override
--- in the menu lists `Catalog.servers()`, so a server with no row cannot be
--- corrected — and while the row was written only after a driver was found, a
--- failed author sniff left a server with no row, no way to set its kind, and a
--- menu advising "use Meguru this series on a book", i.e. the very step that had
--- just failed. A sniff failing was therefore not the soft failure its comment
--- claimed, but a server permanently stranded.
---
--- The row is now written on the strength of the configured catalog alone, which
--- is enough to describe a server: name, host and redacted root all come from
--- `settings/opds.lua`. `upsertServer` keeps an existing manual kind, so this
--- cannot undo a choice the user already made.
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
        return why("no driver for this server's kind -- set it in the Meguru "
            .. "server-type menu", "kind=" .. tostring(kind))
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
        resume = freshResumeTarget(driver, feed, feed_url, ctx, series),
    }
    -- Said out loud because every way this can fail says so, and the success was
    -- the only silent outcome — which makes "is it catalogued?" unanswerable from
    -- the log. Note what it counts: **one** item. The siblings arrive from a sync,
    -- never from this path.
    --
    -- Every field goes through `tostring`: a status line must never be able to
    -- take down the operation it exists to report on, which it once did here.
    logger.info("Meguru: catalogued", item.display_title or item.title,
        "(series " .. tostring(series.remote_id)
        .. ", kind " .. tostring(kind)
        .. ", key " .. tostring(item.item_key) .. ")")
    return registered
end

-- Opening from the catalog ------------------------------------------------------

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
    if host.ui.document then
        host.ui:switchDocument(file)
    else
        host.ui:openFile(file)
    end
    return true
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
--- The flows that come through here routinely stay silent without any extra
--- rule: a next chapter reached from the reader has no progress of its own and
--- the furthest-read item lies *behind* it, so nothing qualifies and no dialog is
--- built at all.
---
--- The caller passes the open step rather than being called back into because the
--- two entry points hand the marker on differently — the browser goes through the
--- built-in plugin's own opener.
---
--- `opts.target` is the caller's fresh answer when it has one, and the catalog's
--- is the fallback when it does not. They are not equivalent and the difference
--- is deliberate: see `freshResumeTarget`.
---
--- `opts.open_item(target)` is how the third button opens the chosen chapter.
--- The two entry points reach a marker differently — the browser has a catalog
--- view to open through, the file manager has whoever is opening this file — so
--- the default is the browser's, and the file path supplies its own.
---
--- @param opts { count, file, target, open, open_item }
function Open.offerResume(host, server, series, item, opts)
    local file, open = opts.file, opts.open

    -- Has this book been read here before? Two things follow, and they are not
    -- the same thing: the page the server reports is only worth *offering* when
    -- there is no local position to prefer, and "continue" names something
    -- different in each case.
    local opened_before = not neverOpened(file)

    -- A page worth offering: past the first, and inside the book. The old
    -- plugin's guard, unchanged (`meguru_hook.lua:996`).
    local page
    if not opened_before then
        page = item and tonumber(item.last_read)
        if not (page and page > 1 and opts.count and page <= opts.count) then
            page = nil
        end
    end

    -- Somewhere further along in the series to go instead. Never the item
    -- already being opened — offering that would be a button that does nothing.
    local target = opts.target
    if not target and server and series then
        local found = Catalog.resumeTarget(series.id)
        target = found and found.item or nil
    end
    if target and item and target.item_key == item.item_key then
        target = nil
    end

    -- Asked whenever there is a choice to make, and only then. Deliberately
    -- **not** gated on the book being new: a reader who has read volume 3 here
    -- and got to volume 5 elsewhere is exactly the case worth asking about, and
    -- their local position is then one of the answers rather than a reason not
    -- to ask. With nothing further along, there is no question to put — the book
    -- opens where it was left.
    if not target and not page then
        open()
        return
    end

    local dialog
    local buttons = {
        {
            {
                text = _("Start from the beginning"),
                callback = function()
                    UIManager:close(dialog)
                    -- Not a no-op, and not decoration. Choosing this leaves no
                    -- sidecar behind, and `MeguruDocument:init` silently seeds
                    -- the server's page into a book that has none — so this
                    -- choice would be quietly undone a moment later and the book
                    -- would open at the server's page after all. Writing page 1
                    -- says what was chosen and marks the book as decided.
                    Open.seedLastPage(file, 1)
                    open()
                end,
            },
        },
    }
    if opened_before then
        -- Their own position, which KOReader restores unaided — so this button's
        -- entire job is to *not* override it. It is the answer to "or open the
        -- one I clicked, where I had got to in it", and without it that choice
        -- would be unreachable: the other two both move somewhere else.
        buttons[#buttons + 1] = {
            {
                text = _("Continue where I left off"),
                callback = function()
                    UIManager:close(dialog)
                    open()
                end,
            },
        }
    elseif page then
        buttons[#buttons + 1] = {
            {
                text = T(_("Continue here (page %1)"), page),
                callback = function()
                    UIManager:close(dialog)
                    Open.seedLastPage(file, page)
                    open()
                end,
            },
        }
    end
    if target then
        buttons[#buttons + 1] = {
            {
                text = T(_("Continue at %1"),
                    target.display_title or target.title),
                callback = function()
                    UIManager:close(dialog)
                    -- Opening the marker this was called for as well would leave
                    -- a book nobody asked for sitting next to the one they did.
                    local open_target = opts.open_item or function(chosen)
                        Open.openCatalogItem(host, server, series, chosen)
                    end
                    open_target(target)
                end,
            },
        }
    end

    dialog = ButtonDialog:new{
        title = _("Meguru: where would you like to start?"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- Build, or find, the marker for a catalog item. Returns `file, count`, or nil.
---
--- Split out of `openCatalogItem` so the resume dialog's "continue at that
--- chapter" can be reached from either entry point: the browser and the file
--- manager prepare a marker identically and differ only in how they hand it on.
local function prepareMarker(server, series, item)
    if type(item.marker_path) == "string" and item.marker_path ~= ""
        and FS.exists(item.marker_path) then
        return item.marker_path
    end

    local template, count = Sync.resolveStream(item, server)
    if type(template) ~= "string" or template == "" then
        logger.warn("Meguru: no page stream for", item.title)
        UIManager:show(InfoMessage:new{
            text = T(_("Meguru: could not find a page stream for “%1”."),
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
    local file = Marker.save(desc, dir)
    Catalog.setMarkerPath(item.id, file)

    -- Same credentials this book will be fetched with, kept in memory only so
    -- the very first page does not race the built-in plugin's own settings
    -- flush. Never written into the marker.
    local conn = Sources.connection(server.name)
    if conn then
        Sources.remember(file, conn.username, conn.password)
    end

    return file, count
end

--- The series' furthest-read item, fetched rather than skimmed from the catalog.
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
--- Falls back to the catalog on any failure. A slightly stale answer beats a
--- dialog that never opens.
--- Fresh answers already fetched, keyed by series id, with when they were taken.
---
--- The file-open path asks on every open now, including for books being resumed,
--- so an unmemoised lookup would be one feed fetch per tap on a book: a few
--- hundred milliseconds in front of a dialog, and up to `Net.RESUME_*` against a
--- server that has stopped answering. Short-lived on purpose — this exists to
--- stop a burst of opens paying repeatedly, not to cache a fact that goes stale.
--- A failure is never memoised, so a series that could not be reached is retried
--- on the next open rather than written off for the rest of the session.
local recent_targets = {}
local RESUME_MEMO_SECONDS = 45

local function currentResumeTarget(server, series)
    local memo = series and recent_targets[series.id]
    if memo and (os.time() - memo.at) < RESUME_MEMO_SECONDS then
        return memo.target
    end

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
        local url = driver.catalogURL(conn.url, series.remote_id, ctx)
        local ok, feed = pcall(Net.fetchFeed, url, {
            username = conn.username,
            password = conn.password,
            timeout = "resume",
        })
        if ok and feed then
            local ok_fresh, target = pcall(freshResumeTarget, driver, feed, url, ctx, series)
            if ok_fresh then
                -- Memoised even when nil: "this series has nothing read" is an
                -- answer, and re-fetching to hear it again is the cost this
                -- guards against.
                recent_targets[series.id] = { target = target, at = os.time() }
                return target
            end
            why = "the feed could not be read"
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

--- Open a catalog item from a library view.
---
--- Two cases, and the second is the reason this exists at all. An item that has
--- been opened before already has a marker on disk: open that file, and its
--- reading progress and page cache come with it. An item that has never been
--- opened has no marker, and — for a Suwayomi chapter — no page stream either,
--- because a sync records every item of a series while deliberately fetching
--- nothing per item. Resolving that stream is one request, made here, at the
--- moment the reader asks for that chapter and at no other time.
---
--- Returns the marker path, or nil after reporting why.
function Open.openCatalogItem(host, server, series, item)
    local file, count = prepareMarker(server, series, item)
    if not file then
        return nil
    end

    Open.offerResume(host, server, series, item, {
        count = count,
        file = file,
        open = function()
            if not handToReader(host, file) then
                logger.err("Meguru: no opener available for", file)
                UIManager:show(InfoMessage:new{
                    text = T(_("Meguru: could not open the book.\nMarker written to:\n%1"),
                        file),
                })
            end
        end,
    })
    -- The marker is ready either way, so this reports "prepared", not "opened":
    -- when the resume dialog is up the book opens on the reader's tap, and a
    -- caller that treated the nil here as failure would be wrong.
    return file
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
        -- The browser's jump goes through `openCatalogItem`; this one has no
        -- catalog view behind it, so it prepares the marker and hands that file
        -- to whoever is opening this one.
        open_item = function(target)
            local other = prepareMarker(server, series, target)
            if other then
                proceed(other)
            end
        end,
    })
end

-- Saving ----------------------------------------------------------------------

--- Ask where the marker for a new stream should go, then run the chosen action
--- with that folder.
---
--- `server_name` turns on the "add to the <catalog> source subfolder" checkbox,
--- which is a plugin-wide preference: the box flips the stored setting right
--- away, so whichever button is pressed next — and every later open — follows
--- it.
function Open.askSaveDestination(on_save_and_open, on_choose_folder, server_name)
    local dest = Marker.pickerStartDir()
    local dialog
    dialog = ButtonDialog:new{
        title = T(_("Save the stream as a book.\nDestination: %1"), dest),
        buttons = {
            {
                {
                    text = _("Choose folder…"),
                    callback = function()
                        UIManager:close(dialog)
                        on_choose_folder()
                    end,
                },
                {
                    text = _("▶ Save & open"),
                    callback = function()
                        UIManager:close(dialog)
                        on_save_and_open(dest)
                    end,
                },
            },
        },
    }
    if type(server_name) == "string" and server_name ~= ""
        and type(dialog.addWidget) == "function"
        and type(dialog.getAddedWidgetAvailableWidth) == "function" then
        -- The local is declared before the CheckButton is built: a closure can
        -- only capture a local already in scope, and the initializer's
        -- right-hand side runs before the name enters scope — so a
        -- self-referencing callback inside it would see a global instead.
        local add_to_source
        add_to_source = CheckButton:new{
            text = T(_("Add to the “%1” source subfolder"), server_name),
            checked = Settings.get("marker_server_dir") and true or false,
            parent = dialog,
            show_parent = dialog,
            callback = function()
                Settings.set("marker_server_dir", add_to_source.checked and true or false)
            end,
        }
        dialog:addWidget(add_to_source)
    end
    UIManager:show(dialog)
end

--- Ask for a folder with KOReader's own picker — the same dialog the built-in
--- OPDS plugin uses for its download folder — then run `on_chosen(dir)`.
--- Cancelling the picker aborts the open. Without a picker the default folder is
--- used, so the button keeps working.
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
function Open.openAsBook(browser, item, stream, marker_dir)
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
        -- driver knows, and the user has not set the kind by hand. Ask the
        -- drivers instead, which is the last chance to give this book a series —
        -- without one it can never have a next chapter.
        kind = Base.kindFor(raw_entry, stream.href, ctx)
        if kind then
            kind_source = "inferred"
            logger.info("Meguru: catalog", server_name,
                "signs itself with no known author; detected", kind,
                "from the entry — set it by hand in Meguru servers if that is wrong")
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
    if not desc.item_key then
        desc.item_key = "flat:" .. Naming.keySuffix(stream.href)
        logger.info("Meguru: book has no catalog identity; marker stays flat")
    end

    local series = registered and registered.series or nil
    local dir = Marker.dirFor(desc, series, {
        base_dir = marker_dir,
        server_folder = Settings.get("marker_server_dir") and true or false,
        series_folder_claimed = registered and Catalog.folderClaimedByOther(
            registered.server.id, series.name, series.id) or false,
    })
    local file = Marker.save(desc, dir)
    if registered then
        Catalog.setMarkerPath(registered.item.id, file)
    end

    -- Keep this run's credentials in memory, keyed by the marker, so the book
    -- works immediately — before the built-in plugin has flushed
    -- settings/opds.lua. Nothing is written into the marker itself.
    Sources.remember(file, browser.root_catalog_username, browser.root_catalog_password)

    local manager = browser._manager
    local host = (manager and manager.ui) and manager or fallback_host

    -- The resume question comes before the handoff, not inside it: the two
    -- handoffs below are alternatives and both are terminal, so the choice has
    -- to be made while there is still something to choose about.
    Open.offerResume(host, registered and registered.server, series,
        registered and registered.item, {
            count = tonumber(desc.count),
            file = file,
            -- What `registerBook` read off the feed the browser has just
            -- fetched, which is current; the catalog's answer is a snapshot.
            target = registered and registered.resume or nil,
            open = function()
                -- Prefer the built-in plugin's own open path: it closes the
                -- browser cleanly and hands the marker to ReaderUI.
                if manager and type(manager.openDownloadedFile) == "function"
                    and manager.opds_browser then
                    manager:openDownloadedFile(file)
                    return
                end
                if handToReader(host, file) then
                    return
                end
                logger.err("Meguru: no opener available for", file)
                UIManager:show(InfoMessage:new{
                    text = T(_("Meguru: could not open the streamed book.\nMarker written to:\n%1"), file),
                })
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
                -- manager prompts for one instead of failing.
                local function open(dir)
                    NetworkMgr:runWhenConnected(function()
                        Open.openAsBook(browser, item, stream, dir)
                    end)
                end
                Open.askSaveDestination(
                    open,
                    function()
                        Open.chooseMarkerDir(open)
                    end,
                    browser.root_catalog_title
                )
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
