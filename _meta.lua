--[[
    _meta.lua — manifest for plugins/meguru.koplugin.

    No `name` key: pluginloader assigns it from the directory name and warns
    that a `name` here is deprecated and ignored (pluginloader.lua:258).
]]

local _ = require("gettext")

return {
    fullname = _("Meguru"),
    description = _([[Turns OPDS-PSE page streams (Suwayomi, Kavita, Komga, ...)
into ordinary KOReader books: a small marker file stands in for the book, so it
lands in History and keeps normal reading progress, while pages are fetched one
at a time over HTTP — no CBZ/ZIP is ever downloaded.

Series and their chapters are kept in a local SQLite catalog, so the plugin can
tell you what a series contains and which chapters are new without opening
anything.]]),
}
