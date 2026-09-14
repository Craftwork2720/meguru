-- SPDX-License-Identifier: AGPL-3.0-or-later

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")

local Association = require("meguru/association")
local Defaults = require("meguru/doc/defaults")
local Hook = require("meguru/hook")
local MeguruDocument = require("meguru/doc/document")
local Menu = require("meguru/ui/menu")
local Open = require("meguru/ui/open")
local Paths = require("meguru/paths")
local Reader = require("meguru/ui/reader")
local Updater = require("meguru/updater")

-- DocumentRegistry:addProvider only ever appends, so a second call would leave
-- two providers for the same extension and a "Open with…" list with the entry
-- twice. The plugin loader never unloads a plugin, but this module can still be
-- required twice across a session; the flag makes the registration idempotent.
local provider_registered = false

local Meguru = WidgetContainer:extend{
    -- `name` and `path` are assigned by pluginloader from the directory name.
    is_doc_only = false,

    -- MIME type recorded against a marker when KOReader files it. Its own type
    -- rather than a comic one: a marker is not an archive and nothing else
    -- should claim it.
    mimetype = "application/x-koreader-meguru-stream",
}

function Meguru:init()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Where the plugin is installed, handed over before anything can want a file
    -- inside it. `pluginloader` assigns `path` from the directory it found us in
    -- (`pluginloader.lua:248`), and it is the only reliable source: the plugin
    -- may sit on removable media under any name ending in `.koplugin`.
    Paths.setPluginDir(self.path)

    -- The installed version, handed over the same way and for the same reason:
    -- pluginloader copied it off `_meta.lua` onto this instance and it cannot be
    -- derived from inside the updater. Both of these are idempotent, because
    -- this method runs once for the FileManager at startup *and* again for every
    -- book opened — `setInstalledVersion` overwrites one string, and
    -- `checkAtStartup` arms at most one background check per process.
    Updater.setInstalledVersion(self.version)
    Updater.checkAtStartup()

    -- Wrap the built-in OPDS browser so a browsed stream can be opened as a
    -- book. Its own work is a hint for that flow only, so a failure here
    -- disables the button rather than the plugin.
    Hook.install()
    Open.setFallbackHost(self)
    self:registerProvider()

    -- Class-level and once per process: the hook lives on ReaderFooter and
    -- there is no instance to hang it on. Installed from whichever instance
    -- loads first (FileManager, at startup) so it is in place before any book
    -- opens.
    Reader.installStatusBarHook()

    -- Reader-side plumbing for this document, if this instance is a reader
    -- with one of our books open. Self-gating: a PDF in the same session gets
    -- nothing.
    Reader.install(self)
end

--- Teach DocumentRegistry to open markers, and to open a .cbz when the user
--- asks for it.
---
--- A marker is claimed outright — nothing else can open one. The .cbz
--- registration is at the lowest weight, so the *registration* alone leaves
--- MuPDF the default and this engine reachable only through KOReader's own
--- "Open with…" dialog. Being the reader for `.cbz` is a separate matter, and
--- `meguru/association` is where it lives: a file-type association, claimed once
--- on the first run and given back from the menu. The registration comes first
--- because the claim looks the provider up by key and refuses to name one that
--- is not registered.
function Meguru:registerProvider()
    if provider_registered then
        return
    end
    provider_registered = true
    local DocumentRegistry = require("document/documentregistry")
    DocumentRegistry:addProvider(Paths.MARKER_EXT, self.mimetype, MeguruDocument, 1)
    DocumentRegistry:addProvider("cbz", "application/vnd.comicbook+zip",
        MeguruDocument, 1)
    logger.info("Meguru: registered ." .. Paths.MARKER_EXT
        .. " and .cbz document providers")
    Association.claimOnce()
end

--- A book is being opened and its settings have been read. Anything that was
--- left at a KOReader default has to be corrected here, because for a streamed
--- book the defaults are wrong: the pages are a fixed layout, not a reflowable
--- text, and the fit is against a cropped box.
function Meguru:onReadSettings(_config)
    local ok, err = pcall(Defaults.apply, self.ui, self.ui and self.ui.document)
    if not ok then
        -- A book that opens with stock defaults still reads correctly; it just
        -- looks wrong. Never let this cost the open.
        logger.warn("Meguru: could not seed per-book defaults:", err)
    end
end

--- Called for every instance of this plugin class — once for the FileManager
--- at startup, once per open book. Which menu gets built is decided by whether
--- there is a document, not by the caller, because the two surfaces have
--- nothing in common: one is the library, the other is the book on screen.
function Meguru:addToMainMenu(menu_items)
    if self.ui and self.ui.document then
        Menu.addReaderItems(self, menu_items)
    else
        Menu.addFileManagerItems(self, menu_items)
    end
end

return Meguru
