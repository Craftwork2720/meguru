--[[--
Runtime integration with the built-in OPDS plugin.

Two wraps, both read-only in effect — the official return value always passes
through untouched, and each wrap's own work is either pcall'd or written so it
cannot throw into the plugin that owns the method:

  * `showDownloads` — after the official dialog has been built, add the "Meguru
    this series" row to it. KOReader's plugin loader never unloads a plugin, so
    this runs once per process.
  * `parseFeed` — hand the raw parsed Atom to `ui/open.lua`, and note which
    server software signed the feed.

The second is not an optimisation. `OPDSBrowser` keeps only a title, an author
and a list of acquisitions per entry, discarding the entry's `<id>` and its
`<link>` array — and a driver needs both to say which series and which item a
book is. Kavita's stream URL happens to carry its own `seriesId` and
`chapterId`, but Suwayomi's chapter URN exists nowhere else.
--]]

local logger = require("logger")

local Open = require("meguru/ui/open")

local Hook = {}

local installed = false

--- Wrap the browser's two methods. Safe to call more than once: the loader
--- keeps plugins loaded for the life of the process, but a second call would
--- otherwise wrap the already-wrapped method and add the button twice.
function Hook.install()
    if installed then
        return true
    end
    installed = true

    local ok, OPDSBrowser = pcall(require, "opdsbrowser")
    if not ok or type(OPDSBrowser) ~= "table" then
        logger.info("Meguru: built-in OPDS plugin not available, integration disabled")
        return false
    end

    local orig_showDownloads = OPDSBrowser.showDownloads
    if type(orig_showDownloads) ~= "function" then
        logger.warn("Meguru: unexpected OPDSBrowser:showDownloads, integration disabled")
        return false
    end
    OPDSBrowser.showDownloads = function(browser, item, ...)
        -- Show the official dialog first, then extend it. In a pcall so an
        -- unexpected dialog shape costs the built-in OPDS feature nothing.
        orig_showDownloads(browser, item, ...)
        local ok_inject, err = pcall(Open.injectBookRow, browser, item)
        if not ok_inject then
            logger.warn("Meguru: could not inject book button:", err)
        end
    end

    local orig_parseFeed = OPDSBrowser.parseFeed
    if type(orig_parseFeed) == "function" then
        OPDSBrowser.parseFeed = function(browser, item_url, ...)
            local catalog = orig_parseFeed(browser, item_url, ...)
            -- pcall'd so a surprise in the parsed shape costs the built-in
            -- browser nothing — but not *silently*: a swallowed error here is
            -- indistinguishable from a feed that was never retained, which is
            -- exactly the state this hook exists to prevent.
            local ok_note, err = pcall(Open.noteFeed, browser, item_url, catalog)
            if not ok_note then
                logger.warn("Meguru: could not retain the feed:", err)
            end
            local ok_author, err_author = pcall(Open.noteCatalogAuthor, browser, catalog)
            if not ok_author then
                logger.warn("Meguru: could not sniff the catalog author:", err_author)
            end
            return catalog
        end
        logger.info("Meguru: hooked OPDSBrowser:parseFeed (feed retention, kind sniffing)")
    end

    -- Two more wraps, for the row at the top of a series feed. Both are needed:
    -- `onMenuSelect` reads every row with no acquisitions as a *catalog link* and
    -- navigates to its `url`, so a row of ours would try to open a URL it does
    -- not have — which is why `Open.seriesRow` marks it and this intercepts it.
    local orig_genItemTableFromURL = OPDSBrowser.genItemTableFromURL
    if type(orig_genItemTableFromURL) == "function" then
        OPDSBrowser.genItemTableFromURL = function(browser, item_url, ...)
            local item_table = orig_genItemTableFromURL(browser, item_url, ...)
            -- Wrapped here rather than at `switchItemTable`, which is switched
            -- from four places: an append, a catalog edit and a search all reach
            -- it, and only one of them is a series feed. This function is handed
            -- the URL, and the URL is what tells them apart — so the decision is
            -- made where the evidence is, not reconstructed from how the switch
            -- was called.
            --
            -- **The append is the caller the URL does *not* rule out**, and the
            -- one that has to be named. `OPDSBrowser:appendCatalog` calls this
            -- same function for every tap on the next-page chevron
            -- (`opdsbrowser.lua:979`), on the same series, with the feed's own
            -- `rel=next` href — which is a series feed like any other. What it
            -- does with the result is the whole problem: it folds it into the
            -- table already on screen (`appendCatalog`'s `table.insert`), so a row
            -- added here is not another list but the *same* list with a second
            -- copy of the row in it — halfway down, once per tap.
            --
            -- The append is identifiable exactly, and by the same evidence as the
            -- rest of this function: its URL is the `next` that the page
            -- currently retained advertises. A navigation, a search and a catalog
            -- edit all arrive with a URL that is not that one.
            --
            -- Skipping it also repairs a test in the caller we do not own:
            -- `appendCatalog` returns true only when `#menu_table > 0`, and a row
            -- of ours satisfies that by itself — so a page carrying no real entry
            -- would read as a successful append and `onNextPage` would keep
            -- asking for more.
            local retained = browser.item_table
            local hrefs = type(retained) == "table" and retained.hrefs
            local is_append = type(hrefs) == "table" and hrefs.next == item_url
            if not is_append then
                local ok, row = pcall(Open.seriesRow, browser, item_url)
                if ok and row and type(item_table) == "table" then
                    table.insert(item_table, 1, row)
                end
            end
            return item_table
        end
    end

    local orig_onMenuSelect = OPDSBrowser.onMenuSelect
    if type(orig_onMenuSelect) == "function" then
        OPDSBrowser.onMenuSelect = function(browser, item)
            if type(item) == "table" and item.meguru then
                -- pcall'd so a failure in our own row costs the built-in browser
                -- nothing, and for the same reason as elsewhere here: a swallowed
                -- error is indistinguishable from a row that was never wired up.
                local ok, err = pcall(Open.openFirstUnread, browser, item.meguru)
                if not ok then
                    logger.warn("Meguru: could not open the series:", err)
                end
                return true
            end
            return orig_onMenuSelect(browser, item)
        end
    end

    logger.info("Meguru: hooked OPDSBrowser:showDownloads")

    -- The third wrap, and the most careful one: `ReaderUI:showReader` is how
    -- *every* document in KOReader is opened. A marker opened from the file
    -- manager or History reaches the reader through it with no other moment to
    -- ask where to start, which is the gap this closes.
    --
    -- Three things keep it from ever costing anyone a book:
    --   * non-`.meguru` files fall straight through, before anything else;
    --   * the whole offer runs inside a pcall, and any failure opens normally;
    --   * the open is called at most once, so a throw after it cannot open twice.
    local ok_ui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_ui and type(ReaderUI) == "table"
        and type(ReaderUI.showReader) == "function" then
        local orig_showReader = ReaderUI.showReader
        ReaderUI.showReader = function(...)
            local n = select("#", ...)
            local args = { n = n, ... }
            -- Colon calls pass the class *or* an instance (`switchDocument` does
            -- `self:showReader`), so the file is whichever of the first two
            -- arguments is the string — never `self == ReaderUI`.
            local file = type(args[1]) == "string" and args[1] or args[2]

            local opened = false
            local function open_instead(other)
                if opened then
                    return
                end
                opened = true
                local forwarded = { }
                for i = 1, n do
                    forwarded[i] = args[i]
                end
                if type(forwarded[1]) == "string" then
                    forwarded[1] = other or forwarded[1]
                else
                    forwarded[2] = other or forwarded[2]
                end
                return orig_showReader(unpack(forwarded, 1, n))
            end

            if type(file) ~= "string" or file:sub(-7) ~= ".meguru" then
                return open_instead()
            end

            local ok_offer, err = pcall(Open.offerResumeForFile, file,
                -- A host-shaped shim: `prepareMarker` and `openCatalogItem` take
                -- one, and on this path the only thing it can usefully do is hand
                -- a file back to the opener we were called from.
                { ui = { openFile = function(_, other) return open_instead(other) end } },
                open_instead)
            if not ok_offer then
                logger.warn("Meguru: resume offer failed, opening normally:", err)
                open_instead()
            end
        end
        logger.info("Meguru: hooked ReaderUI:showReader (resume on file open)")
    else
        logger.warn("Meguru: unexpected ReaderUI:showReader, resume-on-open disabled")
    end

    return true
end

return Hook
