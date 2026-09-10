--[[--
SQLite connection, schema and transactions.

One connection for the whole process, held at module level: `require` caches
this module globally, so every consumer — the plugin instance for the
FileManager, the one for each ReaderUI, the sync engine — shares it. That is
correct (SQLite serializes internally) and it is what makes a sync loop of
hundreds of statements cheap. Opening a connection per operation, the way
`vocabbuilder.koplugin` does for its one-lookup-per-keystroke pattern, would be
wasteful here.
--]]

local Device = require("device")
local logger = require("logger")
local SQ3 = require("lua-ljsqlite3/init")

local Paths = require("meguru/paths")

local Store = {}

local SCHEMA_VERSION = 1

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS servers (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    -- The catalog title as the user saved it in KOReader's OPDS settings.
    -- That title is also the key credentials are looked up by, so it is the
    -- natural identity of a server here. A URL would not do: Kavita's carries
    -- an API key and every host/scheme/key change would fork a new server row.
    name         TEXT NOT NULL UNIQUE,
    kind         TEXT,                -- 'kavita' | 'suwayomi' | 'komga' | NULL
    kind_source  TEXT,                -- 'author' (sniffed) | 'manual' (user override)
    host         TEXT,
    root_url     TEXT,                -- redacted: no API key, no token
    last_seen_at INTEGER
);

CREATE TABLE IF NOT EXISTS series (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id            INTEGER NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
    -- The provider's own id for the series. Identity, unlike catalog_url,
    -- which is derived from it and gains sort/filter params that must not
    -- fork a second row for the same series.
    remote_id            TEXT NOT NULL,
    name                 TEXT NOT NULL,
    name_sort            TEXT,        -- case-folded, punctuation-stripped
    cover_url            TEXT,
    -- Item count from the last *complete* sync. Not for display: it is the
    -- denominator of the implausible-shrink gate in sync.lua.
    item_count           INTEGER NOT NULL DEFAULT 0,
    new_since            INTEGER,     -- watermark; items newer than this are "new"
    synced_at            INTEGER,     -- last *successful* sync
    last_sync_attempt_at INTEGER,     -- every attempt, success or not
    sync_fail_count      INTEGER NOT NULL DEFAULT 0,
    sync_error           TEXT,
    created_at           INTEGER NOT NULL,
    UNIQUE(server_id, remote_id)
);

CREATE INDEX IF NOT EXISTS idx_series_server ON series(server_id, name_sort);

CREATE TABLE IF NOT EXISTS items (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    series_id       INTEGER NOT NULL REFERENCES series(id) ON DELETE CASCADE,
    -- Stable natural identity of the item *within its series*, and the only
    -- thing a re-sync may match on. It must be derivable identically from any
    -- feed and must never be computed from a credential-bearing URL: Kavita's
    -- stream template embeds the API key, so hashing it would turn every key
    -- rotation into a duplicate of the whole library.
    item_key        TEXT NOT NULL,
    item_key_source TEXT,             -- diagnostics: how the key was obtained
    feed_index      INTEGER NOT NULL, -- position within the canonical feed, from the last sync
    ordinal         REAL,             -- provider-reported reading order, when it has one
    ordinal_source  TEXT,             -- 'chapter' | 'volume' | 'feed'
    title           TEXT NOT NULL,    -- verbatim from the feed
    display_title   TEXT,             -- alias prefix and reading glyph stripped
    volume_label    TEXT,             -- e.g. 'Volume 3' / 'Ch. 17', when derivable
    template        TEXT,             -- NULL => lazy, resolved via detail_url on open
    detail_url      TEXT,
    page_count      INTEGER,
    last_read       INTEGER,          -- server-reported, cosmetic
    first_seen_at   INTEGER NOT NULL,
    last_seen_at    INTEGER NOT NULL, -- generation marker for the removal sweep
    removed_at      INTEGER,          -- soft delete; the row is kept for progress history
    marker_path     TEXT,             -- last marker written for this item, if any
    UNIQUE(series_id, item_key)
);

CREATE INDEX IF NOT EXISTS idx_items_series_order ON items(series_id, ordinal, feed_index);
CREATE INDEX IF NOT EXISTS idx_items_marker ON items(marker_path);

CREATE TABLE IF NOT EXISTS meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
]]

local conn

-- The binding returns SQLITE_INTEGER as an int64 cdata, which neither compares
-- nor concatenates like a Lua number. Everything downstream expects plain
-- values, so every read goes through here.
local function normalize(value)
    if type(value) == "cdata" then
        return tonumber(value)
    end
    return value
end

local function open()
    local db = SQ3.open(Paths.dbFile())

    -- Per-connection, and off by default: without it the ON DELETE CASCADE
    -- above is silently inert.
    db:exec("PRAGMA foreign_keys=ON;")

    -- WAL is a persistent database property but setting it is harmless when
    -- already set; on filesystems that cannot support it, TRUNCATE is the
    -- documented fallback (see vocabbuilder.koplugin/db.lua).
    if Device:canUseWAL() then
        db:exec("PRAGMA journal_mode=WAL;")
    else
        db:exec("PRAGMA journal_mode=TRUNCATE;")
    end

    db:exec(SCHEMA)
    Store.migrate(db)
    return db
end

--- Look at `PRAGMA user_version` and bring the database up to SCHEMA_VERSION.
--- A fresh database gets its version stamped without any migration running.
function Store.migrate(db)
    local version = tonumber(db:rowexec("PRAGMA user_version;")) or 0
    if version == SCHEMA_VERSION then
        return
    end
    if version > SCHEMA_VERSION then
        error(string.format(
            "meguru: database schema v%d is newer than this plugin (v%d)",
            version, SCHEMA_VERSION))
    end

    -- No migrations yet: v1 is the initial schema, applied by CREATE TABLE
    -- IF NOT EXISTS above. Future steps go here as `if version < N then ...`
    -- blocks, each in a pcall so a half-applied change is logged rather than
    -- fatal, mirroring vocabbuilder.koplugin/db.lua.

    db:exec(string.format("PRAGMA user_version=%d;", SCHEMA_VERSION))
end

--- The shared connection, opened on first use. Raises on failure.
function Store.connect()
    if not conn then
        conn = open()
    end
    return conn
end

--- Same, but never raises — for plugin init, where a broken database must
--- degrade the plugin rather than abort KOReader's startup.
function Store.ensure()
    local ok, result = pcall(Store.connect)
    if ok then
        return result
    end
    logger.warn("Meguru: database unavailable:", result)
    return nil
end

function Store.close()
    if conn then
        conn:close()
        conn = nil
    end
end

function Store.schemaVersion()
    return tonumber(Store.connect():rowexec("PRAGMA user_version;")) or 0
end

--- Run `fn` inside BEGIN IMMEDIATE ... COMMIT, rolling back if it raises.
--- IMMEDIATE takes the write lock up front, so a second plugin instance cannot
--- interleave a read-modify-write with this one.
---
--- Never wrap a network fetch in here. A paginated sync walk takes tens of
--- seconds on a Kindle and would hold the write lock for all of it.
function Store.transaction(fn)
    local db = Store.connect()
    db:exec("BEGIN IMMEDIATE;")
    local ok, err = pcall(fn, db)
    if ok then
        local committed, commit_err = pcall(function() db:exec("COMMIT;") end)
        if not committed then
            pcall(function() db:exec("ROLLBACK;") end)
            error(commit_err)
        end
        return
    end
    pcall(function() db:exec("ROLLBACK;") end)
    error(err)
end

--- A prepared statement, for callers that run the same SQL in a loop.
--- Caller owns it: `stmt:reset():bind(...):step()` per row, `stmt:close()` at
--- the end.
function Store.prepare(sql)
    return Store.connect():prepare(sql)
end

--- All rows, each a table keyed by column name. `...` binds positionally to
--- the statement's `?` placeholders.
function Store.query(sql, ...)
    local db = Store.connect()
    local stmt = db:prepare(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end

    local rows = {}
    local headers = {}
    while true do
        local raw = stmt:step({}, headers)
        if not raw then
            break
        end
        local row = {}
        for i = 1, #headers do
            row[headers[i]] = normalize(raw[i])
        end
        rows[#rows + 1] = row
    end

    stmt:clearbind():reset()
    stmt:close()
    return rows
end

--- The first row, or nil.
function Store.first(sql, ...)
    return Store.query(sql, ...)[1]
end

--- The first column of the first row, or nil. Unlike `first`, this keeps the
--- caller's SQL free to name its column whatever it likes.
function Store.scalar(sql, ...)
    local stmt = Store.prepare(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end
    local raw = stmt:step({})
    stmt:clearbind():reset()
    stmt:close()
    return raw and normalize(raw[1]) or nil
end

--- Run a statement for its effect, with positional binds.
function Store.exec(sql, ...)
    local stmt = Store.prepare(sql)
    if select("#", ...) > 0 then
        stmt:bind(...)
    end
    -- Wrapped in a closure rather than `pcall(stmt.step, stmt)`: `stmt` is
    -- ffi cdata and its method lookup goes through the metatype, which is not
    -- worth depending on.
    local ok, err = pcall(function() stmt:step() end)
    stmt:clearbind():reset()
    stmt:close()
    if not ok then
        error(err)
    end
end

function Store.now()
    return os.time()
end

return Store
