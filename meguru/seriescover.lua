--[[--
A series' artwork, written into the series folder as a file.

**This is the one thing Meguru writes that is not a marker**, and it is written
for something other than KOReader. A folder of markers is anonymous on a disk,
in a backup, or in whatever else is pointed at the library; a `.cover.jpg` beside
them is not. Nothing in this plugin reads the file back — `getCoverPageImage`
still resolves a cover over HTTP, exactly as before — so it is not a cache and
must not be mistaken for one.

**KOReader will not display it.** That is checked, not assumed:
`coverbrowser.koplugin/mosaicmenu.lua` renders a directory as a frame holding its
name and item count (`is_directory` → `TextBoxWidget`), and
`BookInfoManager:extractBookInfo` pulls a cover out of a document's *contents*
and never looks for a file beside it. `cover.jpg` appears in KOReader's tree only
in `device.lua`, for the screensaver. Whoever came here hoping for folder covers
in the file browser should know that is a different feature, in a different
program.

**A reader chooses which servers this runs for**, in ⋮ → Meguru → Settings →
`Covers for folders`, one switch per server. `SeriesCover.KINDS` is the list,
and it answers two questions at once: who may be written for at all, and which
settings keys to ask. On by default for all three — writing the file is the
feature, and someone who does not want it says so there.

**What the bytes are is the server's business, and the three disagree.** The
file is named `.cover.jpg` whatever arrives:

| server | where the series artwork comes from | what arrives |
|---|---|---|
| Suwayomi | feed-level image on the chapter list | WebP 400x600 |
| Kavita | feed-level image on the series feed | WebP 639x908 |
| Komga | `driver.seriesCover` → REST, since OPDS has none | JPEG 211x300 |

So the name lies about two of the three. Chosen knowingly: most readers sniff
the header and are fine, and the ones that trust the extension are the price.
Converting is not an option this plugin has — MuPDF here can *read* WebP but
KOReader carries no JPEG encoder — so a real fix would mean writing one, which
is a different job.

Written once per series and never rewritten: the file is made only when it is
absent, and nothing in this plugin removes it. That is the whole of "once per
series", and it is why the check is `FS.exists` rather than a remembered flag —
a flag would have to live somewhere, and there is nowhere left to put one.
Turning a server off does not remove what it already wrote; it stops new ones.
--]]

local logger = require("logger")

local FS = require("meguru/fs")
local Net = require("meguru/net")
local Settings = require("meguru/settings")
local Sources = require("meguru/sources")

local SeriesCover = {}

SeriesCover.FILENAME = ".cover.jpg"

--- The servers this may run for, and the list `ui/menu` builds its rows from.
---
--- Closed on purpose. A kind that is not here is not asked about its setting —
--- `Settings.get` warns and returns nil for a name it does not know, so a driver
--- outside this list would log a complaint on every open if the gate went
--- straight to the key.
SeriesCover.KINDS = { "suwayomi", "kavita", "komga" }

--- The settings key a kind's switch is stored under.
local function settingFor(kind)
    return "folder_cover_" .. kind
end
SeriesCover.settingFor = settingFor

--- Whether this kind is both known and switched on.
local function wanted(kind)
    for _, known in ipairs(SeriesCover.KINDS) do
        if known == kind then
            return Settings.get(settingFor(kind)) and true or false
        end
    end
    return false
end

--- Whether there is a network to fetch from.
---
--- The same test, in the same shape, that `MeguruDocument:hasConnection` makes,
--- and lazy for the same reason: it is a *device* state, and a module that
--- reached for the network manager at load time would be unusable anywhere the
--- UI is not up yet.
local function isConnected()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    return ok and NetworkMgr ~= nil and NetworkMgr:isConnected()
end

--- Fetch `desc`'s series artwork and leave it beside `marker_path`.
---
--- Returns the path written, or nil — plus a reason where there is one worth
--- saying. **Every failure is survivable and none of them may reach the caller
--- as an error**: this runs inside an open, and a cover is decoration. The
--- caller ignores the return value for exactly that reason.
---
--- The folder is taken from the marker's own path rather than derived again
--- through `Marker.dirFor`. The marker is *in* the series folder, so the two
--- cannot disagree about where that is — and re-deriving it would be a second
--- answer to a question that was already answered when the marker was planned.
function SeriesCover.save(marker_path, desc)
    if type(desc) ~= "table" or type(marker_path) ~= "string" then
        return nil
    end
    if not wanted(desc.server_kind) then
        return nil
    end
    local url = desc.series_cover_url
    if type(url) ~= "string" or url == "" then
        -- A marker written before the field existed, or a feed that published
        -- no artwork. Nothing to fetch and nothing to say.
        return nil
    end
    local dir = marker_path:match("^(.*)/[^/]+$")
    if not dir then
        return nil
    end
    local path = dir .. "/" .. SeriesCover.FILENAME
    if FS.exists(path) then
        -- The whole of "once per series". Silent on purpose: this is the
        -- ordinary case for every volume after the first, and a log line per
        -- open is the noise the frequency rule exists to keep out.
        return nil
    end
    if not isConnected() then
        logger.dbg("Meguru: no connection, leaving the series cover alone for", marker_path)
        return nil
    end

    local username, password = Sources.credentials(desc.server_name, marker_path)
    local code, _, body = Net.get(url, {
        username = username,
        password = password,
        accept = Net.IMAGE_ACCEPT,
        timeout = "page",
    })
    -- An empty body is checked as well as the code: a 200 with nothing in it
    -- would leave a zero-byte file that `FS.exists` then treats as done, and no
    -- later open would ever try again.
    if code ~= 200 or type(body) ~= "string" or #body == 0 then
        logger.info("Meguru: could not fetch the series cover for", marker_path,
            "(", tostring(code), ")")
        return nil
    end

    local written, err = FS.writeFile(path, body)
    if not written then
        -- The only one of these that is a real fault rather than a state: the
        -- server answered and the disk would not take it.
        logger.warn("Meguru: could not write the series cover to", path,
            "-", tostring(err))
        return nil, err
    end
    logger.dbg("Meguru: series cover written to", path)
    return written
end

return SeriesCover
