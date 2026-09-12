--[[
    _meta.lua — manifest for plugins/meguru.koplugin.

    No `name` key: pluginloader assigns it from the directory name and warns
    that a `name` here is deprecated and ignored (pluginloader.lua:258).
]]

local _ = require("gettext")

return {
    fullname = _("Meguru"),
    description = _([[Turns OPDS-PSE page streams (Kavita, Suwayomi) into
ordinary KOReader books: a small marker file stands in for the book, so it lands
in History and keeps normal reading progress, while pages are fetched one at a
time over HTTP — no CBZ/ZIP is ever downloaded.

The marker carries the identity of the book and of its series, and nothing else
is stored: no database, no page cache. What comes next in a series is read from
the server's own chapter list when you ask for it.]]),
}
