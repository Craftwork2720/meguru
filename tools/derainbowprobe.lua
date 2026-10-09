-- A development aid, not part of the plugin: a KOReader user patch that drives
-- derainbow through the three views a reader sees, so a headless run can say
-- whether each one is filtered.
--
--   install: cp tools/derainbowprobe.lua ~/.config/koreader/patches/2-derainbowprobe.lua
--   run:     MEGURU_PROBE_BOOK=/path/to/book.cbz KO_MULTIUSER=1 SDL_VIDEODRIVER=dummy \
--              timeout 120 ./luajit reader.lua > /tmp/dr.log 2>&1
--   read:    grep -n "drprobe\|derainbow\|paint\|panel zoom" /tmp/dr.log
--   remove it from patches/ afterwards: it opens that book and quits KOReader
--   at startup, which is the point headlessly and a nuisance otherwise.
--
-- The book must be a local `.cbz`, opened through the FileManager: that is the
-- one path where the plugin has registered its provider before a file is asked
-- for. `reader.lua <book>` cannot reach it.
--
-- What it settles: that the filter runs at both seams -- renderPage (the reader
-- and both halves of a spread) and drawPagePart (panel zoom, the one view that
-- never passes through renderPage) -- on buffers that pass the format gate, with
-- a byte diff proving each seam changed pixels, a line per tile, and timings.
-- It is the headless half of the derainbow checklist in development.md.
--
-- What it cannot: whether the shimmer actually goes away. That is a property of
-- the panel, not of the code, and no run on a virtual screen can answer it. Nor
-- does it measure an ARM reader; the vendored build here is amd64.
--
-- It flips the per-book switches, which is what the book's sidecar would carry
-- away on close, so both are put back before quitting.

local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local logger = require("logger")

-- logger.info alone would show nothing per tile; the timing lines are dbg.
require("dbg"):turnOn()

local BOOK = os.getenv("MEGURU_PROBE_BOOK")

local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    io.stderr:write("[drprobe] " .. table.concat(parts, " ") .. "\n")
end

local function quit(reason)
    if reason then
        say(reason)
    end
    say("done")
    UIManager:quit()
end

local function readerUI()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance or nil
end

local function waitFor(pred, then_do, tries)
    tries = tries or 30
    local function again(n)
        local ok, value = pcall(pred)
        if ok and value then
            then_do()
        elseif n > 0 then
            UIManager:scheduleIn(1, function() again(n - 1) end)
        else
            quit("timeout waiting for the reader")
        end
    end
    again(tries)
end

-- Byte-level evidence, so a filter that ran but changed nothing is told apart
-- from one that did not run at all.
local function diff(a, b, what)
    if not (a and b) then
        say("A/B", what, ": no buffer", tostring(a), tostring(b))
        return
    end
    local count, maxd = 0, 0
    local n = math.min(#a, #b)
    for i = 1, n do
        local d = math.abs(a:byte(i) - b:byte(i))
        if d > 0 then
            count = count + 1
            if d > maxd then maxd = d end
        end
    end
    say(string.format("A/B %s: bytes=%d differing=%d (%.3f%%) maxdelta=%d",
        what, n, count, 100 * count / n, maxd))
end

local function bytesOf(bb)
    local ffi = require("ffi")
    return ffi.string(bb.data, tonumber(bb.stride) * tonumber(bb.h))
end

-- The reader/spread seam: the same page and rect, switch off then on.
local function abRenderPage(doc)
    local Geom = require("ui/geometry")
    local Screen = require("device").screen
    local rect = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    local function snap(on)
        doc.configurable.derainbow = on and 1 or 0
        doc:syncTone()
        local tile = doc:renderPage(1, rect, 1.0, 0)
        if not (tile and tile.bb) then
            return nil
        end
        say(string.format("renderPage tile type %s %dx%d",
            tostring(tile.bb:getType()), tile.bb:getWidth(), tile.bb:getHeight()))
        return bytesOf(tile.bb)
    end
    diff(snap(false), snap(true), "renderPage")
end

-- The panel seam: the same panel and output size, switch off then on.
local function abDrawPagePart(doc, page, panel)
    local function snap(on)
        doc.configurable.derainbow = on and 1 or 0
        local bb = doc:drawPagePart(page, panel, 0, 600, 800)
        return bb and bytesOf(bb) or nil
    end
    diff(snap(false), snap(true), "drawPagePart")
end

if not BOOK then
    -- Nothing to open and nothing to guess: a wrong book is a wasted run.
    quit("set MEGURU_PROBE_BOOK to a local .cbz")
    return
end

UIManager:scheduleIn(2, function()
    say("opening", BOOK)
    local FileManager = require("apps/filemanager/filemanager")
    FileManager.instance:openFile(BOOK)

    waitFor(function()
        local ui = readerUI()
        return ui and ui.document
    end, function()
        local ui = readerUI()
        local doc = ui.document
        if doc.provider ~= "meguru" then
            quit("not a Meguru document: " .. tostring(doc.provider))
            return
        end
        local orig_derainbow = doc.configurable.derainbow
        local orig_spread = doc.configurable.spread
        say("reader up; provider:", tostring(doc.provider),
            "local_cbz:", tostring(doc.local_cbz),
            "available:", tostring(require("meguru/derainbow").available()))

        -- Single page first: the spread below would otherwise draw the pair.
        doc.configurable.spread = "off"
        doc:syncTone()
        abRenderPage(doc)

        say("--- step 1: single page, derainbow on ---")
        doc.configurable.derainbow = 1
        doc:syncTone()
        ui:handleEvent(Event:new("ReZoom"))

        UIManager:scheduleIn(4, function()
            say("--- step 2: spread, one derainbow line per half ---")
            local page = ui:getCurrentPage()
            doc.configurable.spread = "on"
            doc:syncTone()
            say("spreadActive:", tostring(doc:spreadActive()), "page:", tostring(page))
            -- Warm first: a fetch during layout would freeze the paint.
            doc:prepareSpread(page)
            ui:handleEvent(Event:new("GotoPage", page + 1))

            UIManager:scheduleIn(5, function()
                say("--- step 3: panel view, one line per panel ---")
                local Reader = require("meguru/ui/reader")
                local PanelZoom = require("meguru/ui/panelzoom")
                local page_now = ui:getCurrentPage()
                local mode = Reader.panelZoomMode(ui)
                local direction = Reader.panelZoomDirection(ui)
                local ok, panels, accepted, reason =
                    pcall(doc.getPanelsFromPage, doc, page_now, mode)
                say("panels:", ok and type(panels) == "table" and #panels or tostring(panels),
                    "accepted:", tostring(accepted), "reason:", tostring(reason))
                if ok and panels and #panels > 0 then
                    abDrawPagePart(doc, page_now, panels[1])
                    doc.configurable.derainbow = 1
                    local shown = PanelZoom.open(ui, page_now, panels, 1, mode, direction,
                        { window = true, level = 1.6 })
                    say("PanelZoom.open ->", tostring(shown))
                end

                UIManager:scheduleIn(8, function()
                    doc.configurable.derainbow = orig_derainbow
                    doc.configurable.spread = orig_spread
                    doc:syncTone()
                    logger.info("Meguru probe: derainbow switches restored")
                    quit()
                end)
            end)
        end)
    end)
end)
