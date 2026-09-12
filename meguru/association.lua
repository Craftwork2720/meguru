--[[--
Which reader opens a file type — and Meguru's claim on `.cbz`.

A `.cbz` is an archive of page images, which is what a Meguru book is, so this
plugin would like to be the reader for one. Registering the extension is not
enough: `main.lua` registers it at the **lowest weight**, so KOReader picks the
document handler by weight — MuPDF — unless a **file-type association** says
otherwise. This module is that association, and it is KOReader's own: the same
`provider` table the stock "Open with…" dialog writes, read back by
`DocumentRegistry:getProvider` *before* it falls back to the highest-weighted
provider (`documentregistry.lua:91-101`). That ordering is the whole of why a
weight-1 provider can win.

The claim is made once ever, on the first run with the plugin installed
(`Association.claimOnce`), and the row in `ui/menu.lua` is how it is given back.

**The record of it is ours, and it has to be.** Releasing the association leaves
`provider.cbz` *absent*, which is byte for byte what a device that has never
chosen a reader looks like — so "no association" cannot be read as "not yet
claimed", and a rule of that shape would re-claim the extension on the very next
start after the reader turned the row off. `Settings.cbz_default_claimed` is what
tells the two apart.

Nothing here is per-book. A `.cbz` whose reader was set individually through
"Open with… → Always open with this file" keeps that answer: it is written into
the book's own sidecar, which `getAssociatedProviderKey` reads before the file
type.
--]]

local DocumentRegistry = require("document/documentregistry")
local Settings = require("meguru/settings")
local logger = require("logger")

local Association = {}

--- The provider key this module claims an extension *for*, as registered by
--- `main.lua`. Asking the registry for it rather than writing the string into
--- `provider.cbz` directly is what keeps the entry honest: a key with no
--- registered provider behind it is ignored by everything downstream.
local PROVIDER = "meguru"

--- The extension the plugin claims.
local EXTENSION = "cbz"

--- A name carrying the extension, with no file behind it.
---
--- `setProvider` takes a *file*, not an extension: it reads the suffix off the
--- name it is handed and never touches anything behind it. So a name with no
--- file under it is the whole of what is needed, and inventing one is the only
--- way to say "every .cbz" through that API.
local NAME = "book." .. EXTENSION

--- `setProvider` mutates the table it read and never saves it — the stock dialog
--- gets away with that because something flushes later. A choice the reader just
--- made gets written now.
local function save()
    local g = rawget(_G, "G_reader_settings")
    if g then
        g:flush()
    end
end

--- Does Meguru hold the extension?
---
--- Asked of the registry rather than of `G_reader_settings` directly, because
--- `getAssociatedProviderKey` also insists the key names a provider that is
--- actually registered — so an entry left behind by a Meguru that has since been
--- uninstalled reads as nil. That is the honest answer, and it is also what
--- keeps an abandoned claim from stopping KOReader opening the file its own way.
function Association.holds()
    return DocumentRegistry:getAssociatedProviderKey(NAME, true) == PROVIDER
end

--- Has anything at all claimed the extension?
function Association.taken()
    return DocumentRegistry:getAssociatedProviderKey(NAME, true) ~= nil
end

--- Take the extension for Meguru, or hand it back.
function Association.claim()
    -- `setProvider(file, nil, true)` means *reset*, so a provider the registry
    -- has never heard of would silently do the opposite of what was asked.
    local provider = type(DocumentRegistry.getProviderFromKey) == "function"
        and DocumentRegistry:getProviderFromKey(PROVIDER) or nil
    if not provider then
        logger.warn("Meguru: the provider is not registered, so ." .. EXTENSION
            .. " cannot be claimed")
        return false
    end
    DocumentRegistry:setProvider(NAME, provider, true)
    save()
    logger.info("Meguru: is now the default reader for ." .. EXTENSION)
    return true
end

function Association.release()
    DocumentRegistry:setProvider(NAME, nil, true)
    save()
    logger.info("Meguru: released ." .. EXTENSION .. " to KOReader's own reader")
end

--- Claim the extension, once ever, on the first run with this plugin installed.
---
--- A choice someone else already made is left alone. The record is written
--- either way, because this is a one-time offer rather than a preference that
--- re-asserts itself: once it has run, the answer is the menu row's to give and
--- nobody else's.
---
--- The one case it cannot tell apart is a device upgrading from a build that had
--- the row but no record — where turning the row off wrote the same absent entry
--- this reads as "unclaimed", so the claim is made once more. It is a one-time
--- surprise with a one-tap fix, and the alternative is a row that comes back on
--- by itself forever.
function Association.claimOnce()
    if Settings.get("cbz_default_claimed") then
        return
    end
    Settings.set("cbz_default_claimed", true)
    if Association.taken() then
        return
    end
    Association.claim()
end

return Association
