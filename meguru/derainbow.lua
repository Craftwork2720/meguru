--[[--
The rainbow-moiré filter, vendored from `derainbowify.koplugin`.

A Kaleido 3 panel puts a colour filter array over a monochrome one, and fine
black-and-white artwork — which is most manga — beats against that array and
comes up in rainbows. The filter that removes them is a Fourier pass in a native
library, written by someone else and shipped in `libs/` beside this file.

**None of that plugin's own code reaches a Meguru book.** It wraps
`KoptInterface.renderPage`, `KoptInterface.renderOptimizedPage`,
`CreDocument:drawCurrentView` and `Document.hintPage`, and hangs its switch off
the `KoptOptions`/`CreOptions` sections. A Meguru book is none of those: it
renders through MuPDF itself (`meguru/doc/image`) and answers
`self.koptinterface = {}` (see `doc/document`'s init), so every one of those
hooks is inert here — and `Document.hintPage`, the only one that could have
fired, is shadowed by `MeguruDocument:hintPage`, which never calls the base.

So this module calls the same four exported symbols itself. That much was always
true; what changed is **where the files come from**. It used to look for an
installed `derainbowify.koplugin` and answer "unavailable" when there was none,
which made the row depend on a second install for no reason a reader could see.
The libraries now ship with this plugin (`libs/`, taken unmodified from that
project's version 0.0.12 — `libs/README.md` records the provenance and the
licence) and an installed copy of the other plugin is neither needed nor used.

**That freezes the ABI, and that is the trade.** The four prototypes below are
written against 0.0.12. LuaJIT's FFI does not check a signature against the
library it calls — a changed one is undefined behaviour rather than an error —
so these files are never updated by anything but a human deciding to re-copy and
re-test them. A newer `derainbowify` cannot break this, and cannot fix it either.

**Only one buffer shape is ever handed over, and that is a safety rule rather
than a preference.** `remove_moire` decides what it is looking at from
`bpp = stride / width`:

  * `bpp == 4` takes the colour path, which is the one this filter is for;
  * `bpp == 3` (RGB24) falls into the *grayscale* branch, which writes the same
    value into three bytes — a colour page comes back grey;
  * `bpp == 2` (BB8A) takes that same three-byte-per-pixel branch over a
    two-byte pixel, which is a heap overflow of one byte per pixel.

The other plugin's own bridge gates on `bpp >= 3` and so lets the second case
through; it never meets the third only because it never filters an alpha buffer.
This module gates on `TYPE_BBRGB32` and an exact stride instead, and refuses
everything else — a page that is not filtered is a page as it was, which is the
only failure worth having here. See `docs/derainbow.md`.
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local FS = require("meguru/fs")
local Paths = require("meguru/paths")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local logger = require("logger")
local util = require("util")

local Derainbow = {}

-- The library names, and the versions of them this was written against. The
-- suffixes are the other project's filename convention; `libs/README.md` says
-- where the files came from.
local COLOR_LIB = "color_detect-%s.so"
local MOIRE_LIB = "moire_filter-%s.so"

-- Its constants, kept as they are so a page filtered here looks like a page
-- filtered by that plugin itself.
local COLOR_TOLERANCE = 20
local FILTER_STRENGTH = 0.9

-- Declared here because this module loads its own handle to the libraries.
-- Nothing else in the process declares these names, but the declaration is
-- guarded anyway: a second `ffi.cdef` for a symbol that is already declared is
-- refused by LuaJIT, and a refusal here would mean the symbols exist, which is
-- a working state rather than a fault.
local CDEF = [[
bool is_page_colored(uint8_t* data, int width, int height, int stride, int tolerance);
void remove_moire(unsigned char *fb_data, int width, int height, int stride, bool is_colored, float strength);
int init_moire_resources();
void cleanup_moire_resources();
]]

-- Monotonic milliseconds, for the one timing line. Same clock `doc/document`
-- measures a paint with.
local function nowMs()
    local secs, usecs = ffiutil.gettime()
    return secs * 1000 + usecs / 1000
end

-- Every answer this module caches, and they are all settled by one probe.
--
-- `available` is a fact about an *installation and a panel*, neither of which
-- changes under a running KOReader, so it is asked once and kept — which is also
-- why `apply` does not re-ask it per tile. `initialized` is separate because
-- `init_moire_resources` allocates, and a reader who never turns the row on
-- should not pay for that; `filter_failed` because a library that throws will
-- throw on every tile of every page and must be reported once.
local state = {
    probed = false,
    available = false,
    color = nil,
    moire = nil,
    initialized = false,
    filter_failed = false,
    active_reported = false,
}

-- Whether `Device` answers a given predicate, tolerantly. Every one of these is
-- a plain method on KOReader's device table, but a build that lacks one must
-- cost the row and not the plugin.
local function deviceSays(method)
    local fn = Device and Device[method]
    if type(fn) ~= "function" then
        return false
    end
    local ok, answer = pcall(fn, Device)
    return ok and answer == true
end

-- Which build of the libraries this device needs, spelled exactly as the other
-- plugin spells it — the suffixes are its filename convention and nothing else
-- can be inferred from them.
local function platformSuffix()
    if deviceSays("isDesktop") or deviceSays("isEmulator") then
        return "amd64"
    end
    if deviceSays("isKobo") then
        return "kobo"
    end
    if deviceSays("isPocketBook") then
        return "pocketbook"
    end
    if deviceSays("isKindle") then
        -- The two Kindle builds differ by ABI, and the loader on the device is
        -- what says which one this is.
        return util.pathExists("/lib/ld-linux-armhf.so.3") and "kindlehf" or "kindle"
    end
    if deviceSays("isAndroid") then
        local arch = jit.arch
        if type(arch) == "string" and arch:sub(1, 3) == "arm" then
            return "android-" .. arch
        end
    end
    return nil
end

local function libPaths()
    local suffix = platformSuffix()
    if not suffix then
        return nil, nil
    end
    return Paths.lib(string.format(COLOR_LIB, suffix)),
           Paths.lib(string.format(MOIRE_LIB, suffix))
end

-- Load both libraries, once, and answer whether this device can filter at all.
--
-- **It loads rather than merely looking.** The files are ours now, so on any
-- supported platform `FS.exists` would say yes every time — and would be wrong
-- on the one platform where it matters: an Android install whose plugin
-- directory sits inside the APK ships these files and cannot `ffi.load` them.
-- A row that appears and then does nothing is worse than a row that is not
-- there, so the only honest test is the load itself.
--
-- Memoised by `available`, so this costs one `dlopen` per session whichever of
-- the two callers reaches it first: the menu, deciding whether to offer the row,
-- or the render path, on the first page that wants filtering.
local function probe()
    if not deviceSays("hasColorScreen") then
        return false
    end
    local color_path, moire_path = libPaths()
    if not (color_path and moire_path) then
        return false
    end
    if not (FS.exists(color_path) and FS.exists(moire_path)) then
        return false
    end

    local ok_color, color = pcall(ffi.load, color_path)
    local ok_moire, moire = pcall(ffi.load, moire_path)
    if not (ok_color and ok_moire and color and moire) then
        -- At warn, once: the files said they were there, so this is a broken
        -- install or a platform the build does not match, and it is worth
        -- saying rather than silently hiding the row.
        logger.warn("Meguru: derainbow libraries are present but would not load:",
            tostring(color), tostring(moire))
        return false
    end
    -- Guarded, not checked: see the note on CDEF.
    pcall(ffi.cdef, CDEF)

    state.color, state.moire = color, moire
    logger.dbg("Meguru: derainbow libraries loaded from", moire_path)
    return true
end

--- Whether this device can offer the switch at all.
---
--- Four questions, and the first is the one that keeps it off most devices: a
--- screen that cannot show colour has no rainbow to remove, and that is a
--- property of the *panel* rather than of the reader's colour setting — which is
--- why this asks `Device:hasColorScreen()` and not `Image.colorEnabled()`. The
--- row asks the second question separately (see `ui/reader`), because a reader
--- who has turned colour rendering off would be offered a switch whose effect
--- `apply` then refuses to produce.
---
--- Memoised, and that is the one thing to know about calling it: the answer is
--- fixed for the session, and asking it may load the libraries.
function Derainbow.available()
    if not state.probed then
        state.probed = true
        state.available = probe()
    end
    return state.available
end

-- `init_moire_resources` allocates whatever the filter needs, on the first page
-- that actually wants filtering rather than when the row is offered.
--
-- Best-effort: the other plugin treats this as a setup step and its own build
-- stubs it out, so a build where it does something and fails must not take the
-- filter — or the page — down.
local function ensureInit()
    if state.initialized then
        return
    end
    state.initialized = true
    local ok_init, init_err = pcall(function()
        state.moire.init_moire_resources()
    end)
    if not ok_init then
        logger.warn("Meguru: derainbow init_moire_resources failed:", tostring(init_err))
    end
end

-- Refusal reasons already said out loud.
--
-- A reader who turns the switch on where it cannot work needs to be told why —
-- and needs to be told *once*. This runs per tile, so without the ledger a
-- grayscale page would put a line in the log for every pan and every zoom step,
-- which is the shape of noise that buries the line worth reading.
local reported = {}

-- The `type` test is not decoration: this is called from the paint path, and
-- `reported[nil] = true` would raise "table index is nil" — a logging helper
-- bringing down a page turn. A reason that is not a string is simply not worth
-- a line.
local function reportOnce(reason)
    if type(reason) ~= "string" or reported[reason] then
        return
    end
    reported[reason] = true
    logger.dbg("Meguru: derainbow skipped -", reason)
end

-- The buffer's raw geometry — `w`, `h`, `stride` — or three nils and the word
-- for the gate that refused it.
--
-- **Every refusal returns four values, with the word in the *fourth*.** Two
-- values would have put the reason in `h`, and a caller reading
-- `w, h, stride, why` would then find it in the wrong place and a nil where it
-- was looking — which is a bug this had, and the reason the shape is spelled
-- out here rather than left to the returns.
--
-- **The layout, not the picture.** It is `stride` the C is told about: the
-- library walks `stride` bytes per row over `h` rows, so what it must be given
-- is the buffer's real row length, not a tidy number derived from the width. A
-- stride that is not exactly `w * 4` is refused rather than passed on —
-- `remove_moire` works out its own bytes-per-pixel as `stride / width`, so row
-- padding would quietly make that wrong and walk the page at the wrong pitch.
--
-- The dimensions come from the buffer's own fields, which is what the other
-- plugin reads too; the accessors are a fallback for a build that spells them
-- differently, and they are only consulted when the field is absent. No such
-- fallback exists for the stride, and deliberately: `w * 4` would be exactly the
-- assumption the check below is there to refuse.
--
-- The word travels into the one log line, so a reader can tell "this device has
-- no filter" from "this page was the wrong shape for it".
local function geometryFor(bb)
    if not (bb and type(bb.getType) == "function") then
        return nil, nil, nil, "no buffer"
    end
    local ok_type, bb_type = pcall(bb.getType, bb)
    if not ok_type or bb_type ~= Blitbuffer.TYPE_BBRGB32 then
        return nil, nil, nil, "not RGB32"
    end
    if type(bb.getRotation) == "function" then
        local ok_rot, rotation = pcall(bb.getRotation, bb)
        if ok_rot and rotation ~= 0 then
            return nil, nil, nil, "rotated"
        end
    end
    if type(bb.getInverse) == "function" then
        local ok_inv, inverse = pcall(bb.getInverse, bb)
        if ok_inv and inverse == true then
            return nil, nil, nil, "inverted"
        end
    end
    local w = tonumber(bb.w)
    local h = tonumber(bb.h)
    if not w and type(bb.getWidth) == "function" then
        local ok_w, width = pcall(bb.getWidth, bb)
        w = ok_w and tonumber(width) or nil
    end
    if not h and type(bb.getHeight) == "function" then
        local ok_h, height = pcall(bb.getHeight, bb)
        h = ok_h and tonumber(height) or nil
    end
    local stride = tonumber(bb.stride)
    if not (w and h and stride) or w < 1 or h < 1 then
        return nil, nil, nil, "no geometry"
    end
    if stride ~= w * 4 then
        return nil, nil, nil, "padded stride"
    end
    return w, h, stride
end

--- Run the moiré filter over `bb`, in place, and hand it back.
---
--- **The buffer is filtered where it lies, and the call site is what makes that
--- safe.** Both places this is called (`MeguruDocument:renderPage` and
--- `MeguruDocument:drawPagePart`) have just produced the buffer themselves —
--- from `page.draw_new`, or from a `decodeRegion` that is documented never to
--- return the LRU-cached native — and neither has cached it yet. So nothing
--- else holds these pixels, and the tile that goes into the LRU afterwards is
--- already filtered, which is what keeps a cache hit from paying twice. The
--- other plugin has to work on a copy because stock's tile is shared with its
--- cache; Meguru's is not, and copying here would only double a transient that
--- is already large.
---
--- **Everything is guarded, and a refusal returns the buffer untouched.** The
--- library is someone else's and frozen at the version this was written against
--- (see `libs/README.md`), and a page that is not filtered is a page as it was —
--- so no failure here may cost a paint.
function Derainbow.apply(bb)
    if not Derainbow.available() then
        return bb
    end
    local w, h, stride, refusal = geometryFor(bb)
    if not w then
        reportOnce(refusal)
        return bb
    end
    ensureInit()

    local t0 = nowMs()
    local ok, err = pcall(function()
        local ptr = ffi.cast("uint8_t*", bb.data)
        local is_colored = state.color.is_page_colored(ptr, w, h, stride, COLOR_TOLERANCE)
        state.moire.remove_moire(ptr, w, h, stride, is_colored, FILTER_STRENGTH)
    end)
    if not ok then
        -- Once per process, for the reason the refusal ledger exists: this runs
        -- on every tile, and a library that throws will throw on all of them.
        -- The likely cause is the one `docs/known-issues.md` names — a library
        -- that does not match the prototypes above — and a hundred copies of it
        -- in the log help nobody.
        if not state.filter_failed then
            state.filter_failed = true
            logger.warn("Meguru: derainbow filter failed:", tostring(err))
        end
        return bb
    end
    -- One line the first time it actually filters, at info, and then per-tile
    -- timing at dbg. The first is for the reader: a switch whose whole effect is
    -- on a panel most devices do not have is otherwise impossible to tell from a
    -- switch that does nothing. One per session is not noise — it is the same
    -- shape as `Meguru: colour page rendering`, which is also said once.
    if not state.active_reported then
        state.active_reported = true
        logger.info(string.format(
            "Meguru: derainbow filter running (%dx%d, %.1f ms)", w, h, nowMs() - t0))
    end
    logger.dbg(string.format("Meguru: derainbow %dx%d = %.1f ms", w, h, nowMs() - t0))
    return bb
end

return Derainbow
