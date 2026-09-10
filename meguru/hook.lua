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

    logger.info("Meguru: hooked OPDSBrowser:showDownloads")
    return true
end

return Hook
