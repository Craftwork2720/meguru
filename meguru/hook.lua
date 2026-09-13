--[[--
Runtime integration with the built-in OPDS plugin.

Four wraps on `OPDSBrowser` plus one on `ReaderUI`, all read-only in effect — the
official return value always passes through untouched, and each wrap's own work is
either pcall'd or written so it cannot throw into the plugin that owns the method:

  * `showDownloads` — after the official dialog has been built, add the "Meguru
    this series" row to it.
  * `parseFeed` — hand the raw parsed Atom to `ui/open.lua`, and note which
    server software signed the feed.
  * `genItemTableFromURL` — put the "Meguru this series" row at the top of a
    series feed.
  * `onMenuSelect` — intercept that row, which carries no acquisitions and would
    otherwise be read as a catalog link.

The second is not an optimisation. `OPDSBrowser` keeps only a title, an author
and a list of acquisitions per entry, discarding the entry's `<id>` and its
`<link>` array — and a driver needs both to say which series and which item a
book is. Kavita's stream URL happens to carry its own `seriesId` and
`chapterId`, but Suwayomi's chapter URN exists nowhere else. It is also the only
writer of `ui/open.lua`'s `last_feed`, from which both the row above and a
Komga entry's `ctx.url` are read — so losing this one wrap costs three features,
not one.

**The wraps are installed twice, and the second time is the load-bearing one.**
Once here, when the plugin loads, and again every time an `OPDSBrowser` is
constructed. The reason is that another plugin may replace these methods on the
class *after* we wrapped them — `zenos.koplugin` does exactly that for
`showDownloads` and `parseFeed`, wholesale and without chaining, and it loads
after meguru because `pluginloader.lua` sorts plugin directories by path. The
browser's own construction is the latest moment at which our wrap can be the
outermost layer: by then every plugin has been loaded and every patch applied.

That second pass is **per method**, and it has to be: such a plugin replaces some
of these methods and leaves the others alone, and re-wrapping one it never took
would be wrapping our own wrapper.
--]]

local logger = require("logger")

local Open = require("meguru/ui/open")

local Hook = {}

local installed = false

--- The wrapper we installed for each method, so a later pass can tell whether that
--- method is still ours. A nil entry means the method was not a function when we
--- looked and was never wrapped.
local m_showDownloads
local m_parseFeed
local m_genItemTableFromURL
local m_onMenuSelect

local browser_wrapped = false
local init_wrapped = false
local repatched_logged = false
local warned_showDownloads = false

--- Whether `current` is still the wrapper we installed for this method, so its
--- chain to the original is intact and it must be left exactly as it is.
---
--- **Asking this of the whole set at once was the bug, and the symptom was two
--- rows.** A plugin that patches the browser replaces some of these methods and
--- not others — `zenos.koplugin` takes `showDownloads` and `parseFeed`, and
--- leaves `genItemTableFromURL` and `onMenuSelect` alone. Told to re-install
--- whenever *anything* was missing, this wrapped the two it had never lost, so
--- `genItemTableFromURL` carried two layers of our wrapper and inserted the row
--- once per layer.
local function stillOurs(current, ours)
    return ours ~= nil and current == ours
end

--- Wrap whichever of the browser's methods are not already carrying our wrapper,
--- capturing whatever each is *now* as its original. Safe to call more than once
--- for that reason: a method we still own is left untouched, so neither the feed
--- is retained twice nor the row added twice.
local function installBrowserWraps(OPDSBrowser)
    -- The first pass is silent — nothing had been replaced, because there had been
    -- nothing to replace yet. Every later pass that changes something is worth a
    -- line, once.
    local repatched = browser_wrapped
    local changed = false

    -- `showDownloads` first and on its own: it is the one method this integration
    -- cannot do without, so a browser that does not have it gets nothing wrapped
    -- rather than half of something.
    if not stillOurs(OPDSBrowser.showDownloads, m_showDownloads) then
        local orig_showDownloads = OPDSBrowser.showDownloads
        if type(orig_showDownloads) ~= "function" then
            -- Warned once rather than once per browser: the shape is either wrong
            -- from the start or it is not wrong at all, and this runs on every
            -- construction.
            if not warned_showDownloads then
                warned_showDownloads = true
                logger.warn("Meguru: unexpected OPDSBrowser:showDownloads, integration disabled")
            end
            return false
        end

        m_showDownloads = function(browser, item, ...)
            -- Show the official dialog first, then extend it. In a pcall so an
            -- unexpected dialog shape costs the built-in OPDS feature nothing.
            orig_showDownloads(browser, item, ...)
            local ok_inject, err = pcall(Open.injectBookRow, browser, item)
            if not ok_inject then
                logger.warn("Meguru: could not inject book button:", err)
            end
        end
        OPDSBrowser.showDownloads = m_showDownloads
        changed = true

        logger.dbg("Meguru: hooked OPDSBrowser:showDownloads")
    end

    if not stillOurs(OPDSBrowser.parseFeed, m_parseFeed) then
        local orig_parseFeed = OPDSBrowser.parseFeed
        if type(orig_parseFeed) == "function" then
            m_parseFeed = function(browser, item_url, ...)
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
            OPDSBrowser.parseFeed = m_parseFeed
            changed = true

            logger.dbg("Meguru: hooked OPDSBrowser:parseFeed (feed retention, kind sniffing)")
        else
            m_parseFeed = nil
        end
    end

    -- Two more wraps, for the row at the top of a series feed. Both are needed:
    -- `onMenuSelect` reads every row with no acquisitions as a *catalog link* and
    -- navigates to its `url`, so a row of ours would try to open a URL it does
    -- not have — which is why `Open.seriesRow` marks it and this intercepts it.
    if not stillOurs(OPDSBrowser.genItemTableFromURL, m_genItemTableFromURL) then
        local orig_genItemTableFromURL = OPDSBrowser.genItemTableFromURL
        if type(orig_genItemTableFromURL) == "function" then
            m_genItemTableFromURL = function(browser, item_url, ...)
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
            OPDSBrowser.genItemTableFromURL = m_genItemTableFromURL
            changed = true
        else
            m_genItemTableFromURL = nil
        end
    end

    if not stillOurs(OPDSBrowser.onMenuSelect, m_onMenuSelect) then
        local orig_onMenuSelect = OPDSBrowser.onMenuSelect
        if type(orig_onMenuSelect) == "function" then
            m_onMenuSelect = function(browser, item)
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
            OPDSBrowser.onMenuSelect = m_onMenuSelect
            changed = true
        else
            m_onMenuSelect = nil
        end
    end

    browser_wrapped = true

    if changed and repatched and not repatched_logged then
        -- A decision, and a once-per-process one — hence `info`, and hence the
        -- flag. It deliberately does not name the plugin that did it: detecting
        -- one by its private fields would tie this repair to a foreign
        -- implementation we do not control, and the useful fact is that our
        -- hooks were replaced, not by whom.
        repatched_logged = true
        logger.info("Meguru: OPDSBrowser re-patched since load; OPDS hooks re-installed")
    end

    return changed
end

--- Install the wraps, and arm the re-install that survives another plugin
--- replacing them. Safe to call more than once (see `installed`).
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

    -- **The re-install, and the one place it can happen.** A plugin that patches
    -- `OPDSBrowser` wholesale does so while plugins are loading, and meguru loads
    -- before any of them whose directory sorts later — so the wraps installed
    -- here, at load, may be gone by the time anything browses a catalog.
    -- Constructing a browser is the last moment at which the class is settled and
    -- an instance exists: every plugin has loaded, every patch has been applied,
    -- and nothing re-patches afterwards.
    --
    -- `init` rather than an event, because the OPDS plugin is not on the
    -- `UIManager` stack and so never receives a broadcast; and rather than a wrap
    -- on the instance, because a class-level re-install reaches the class the
    -- browser actually inherits from. It chains to the original, so it is
    -- transparent whoever wrapped it — `OPDSBrowser.init` is `Menu:init` through
    -- `__index` in stock, and a foreign patch captures our wrap from the class
    -- and calls it, which is exactly why ours runs at all in that case.
    if not init_wrapped then
        init_wrapped = true
        local orig_init = OPDSBrowser.init
        if type(orig_init) == "function" then
            OPDSBrowser.init = function(browser, ...)
                installBrowserWraps(OPDSBrowser)
                return orig_init(browser, ...)
            end
        end
    end

    installBrowserWraps(OPDSBrowser)

    -- The fifth wrap, and the most careful one: `ReaderUI:showReader` is how
    -- *every* document in KOReader is opened. A marker opened from the file
    -- manager or History reaches the reader through it with no other moment to
    -- ask where to start, which is the gap this closes. It is not wrapped again
    -- at browser construction: it is on a different class, and no OPDS patch
    -- replaces it.
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

            -- Read *and clear* the one-shot before anything else, including the
            -- extension test: a record that outlived the open it was armed for
            -- has to clear on the very next call to this wrap, whatever that
            -- open turns out to be.
            local decided = Open.takeHandoff()

            if type(file) ~= "string" or file:sub(-7) ~= ".meguru" then
                return open_instead()
            end

            -- **Already decided, a moment ago, by the dialog.** `handOff` arms
            -- this immediately before `switchDocument`, and `offerResume` asked
            -- — or deliberately did not ask — a few statements earlier, so
            -- asking again here is the dialog asking a question it has just had
            -- answered. `once` inside `offerResume` cannot cover that: it makes
            -- one dialog act once, and the failure here is a *second* dialog.
            if decided == file then
                return open_instead()
            end

            local ok_offer, err = pcall(Open.offerResumeForFile, file,
                -- A host-shaped shim: `openItemSilently` and the neighbour opens
                -- take one, and on this path the only thing it can usefully do is
                -- hand a file back to the opener we were called from.
                { ui = { openFile = function(_, other) return open_instead(other) end } },
                open_instead)
            if not ok_offer then
                logger.warn("Meguru: resume offer failed, opening normally:", err)
                open_instead()
            end
        end
        logger.dbg("Meguru: hooked ReaderUI:showReader (resume on file open)")
    else
        logger.warn("Meguru: unexpected ReaderUI:showReader, resume-on-open disabled")
    end

    return true
end

return Hook
