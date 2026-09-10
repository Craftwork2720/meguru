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
        series = Catalog.series(series.id),
        item   = Catalog.itemByKey(series.id, item.item_key),
    }
    -- Said out loud because every way this can fail says so, and the success was
    -- the only silent outcome — which makes "is it catalogued?" unanswerable from
    -- the log. Note what it counts: **one** item. The siblings arrive from a sync,
    -- never from this path.
    --
    -- Read off `registered.series`, not off the local `series`: `upsertSeries`
    -- returns only `{ id, new_since }`, so the local has no `remote_id` — and
    -- concatenating it aborted the whole open, *after* both rows had committed.
    -- Every field goes through `tostring` for the same reason: a status line
    -- must never be able to take down the operation it exists to report on.
    local stored = registered.series
    logger.info("Meguru: catalogued", item.display_title or item.title,
        "(series " .. tostring(stored and stored.remote_id)
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
    if type(item.marker_path) == "string" and item.marker_path ~= ""
        and FS.exists(item.marker_path) then
        if handToReader(host, item.marker_path) then
            return item.marker_path
        end
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

    if not handToReader(host, file) then
        logger.err("Meguru: no opener available for", file)
        UIManager:show(InfoMessage:new{
            text = T(_("Meguru: could not open the book.\nMarker written to:\n%1"),
                file),
        })
        return nil
    end
    return file
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

    -- Prefer the built-in plugin's own open path: it closes the browser cleanly
    -- and hands the marker to ReaderUI.
    local manager = browser._manager
    if manager and type(manager.openDownloadedFile) == "function" and manager.opds_browser then
        manager:openDownloadedFile(file)
        return
    end

    local host = (manager and manager.ui) and manager or fallback_host
    if handToReader(host, file) then
        return
    end

    logger.err("Meguru: no opener available for", file)
    UIManager:show(InfoMessage:new{
        text = T(_("Meguru: could not open the streamed book.\nMarker written to:\n%1"), file),
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
