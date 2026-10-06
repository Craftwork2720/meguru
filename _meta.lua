--[[
    _meta.lua — manifest for plugins/meguru.koplugin.

    No `name` key: pluginloader assigns it from the directory name and warns
    that a `name` here is deprecated and ignored (pluginloader.lua:258).

    `version` is load-bearing and has three readers, none of which can be
    checked from here:

      * `pluginloader.lua:255-261` copies every key of this table except `name`
        onto the plugin module, which is how `main.lua` gets `self.version` and
        hands it to the updater;
      * `.github/workflows/release.yml` refuses to publish a release whose tag
        does not match it, because the updater compares the tag against this
        value — a stale one here makes every check report a new release as "up
        to date", for good and silently;
      * `meguru/updater.lua` reads it back off a *downloaded* archive to prove
        the file it fetched is the release it asked for.

    So: bump it before tagging, and never let it be absent.

    **A development build carries its branch in the version** —
    `1.5.0-dev-derainbow-filter` — and that is a tag, a version and a release
    flag at once: the tag is `v` + this string, the workflow publishes anything
    with a hyphen after the version as a *prerelease*, and `/releases/latest`
    skips those, so no installed Meguru is ever offered one. Note the fourth
    reader this gives the field: `updater.lua`'s `versionLessThan` reads only
    the digits, so a dev build compares as `1.5.0` and will not be offered the
    plain `1.5.0` release either. That is the intended trade — a development
    build is replaced by hand.
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
    version = "1.5.0-dev-derainbow-filter",
}
