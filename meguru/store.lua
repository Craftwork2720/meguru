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

-- 2: `items.cover_url` -- a book's own artwork, distinct from its series'.
local SCHEMA_VERSION = 2

local SCHEMA = [[
CREATE TABLE IF NOT EXISTS servers (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    -- The catalog title as the user saved it in KOReader's OPDS settings.
    -- That title is also the key credentials are looked up by, so it is the
    -- natural identity of a server here. A URL would not do: Kavita's carries
    -- an API key and every host/scheme/key change would fork a new server row.
    name         TEXT NOT NULL UNIQUE,
    kind         TEXT,                -- 'kavita' | 'suwayomi' | 'komga' | NULL
    kind_source  TEXT,                -- 'author' (sniffed) | 'inferred' -- the
                                      -- 'manual' override has no writer any more
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
    new_since            INTEGER,     -- watermark: items newer than this are "new"
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
    removed_at      INTEGER,          -- soft delete: the row is kept for progress history
    marker_path     TEXT,             -- last marker written for this item, if any
    -- The book's own artwork, where its feed publishes one. Kavita does, on
    -- every entry of a series feed. Suwayomi's chapter list does not (see the
    -- driver). A book with none falls back to the series cover and then to the
    -- first page of its stream, so this only ever *improves* the picture.
    --
    -- Last in the table on purpose: `ALTER TABLE ADD COLUMN` appends, so a
    -- database migrated to v2 and a fresh one then have the same column order
    -- and the same `.schema` output.
    cover_url       TEXT,
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

--- Split a SQL script into individual statements.
---
--- `db:exec` cannot do this job. It splits the script on every `;` with no
--- understanding of SQL, so a semicolon inside a `--` comment cuts a statement
--- in half; the fragment before the cut then ends mid-comment, and SQLite
--- reports that as `incomplete input` — an error naming no file, no line and no
--- statement. That is not hypothetical: it is exactly what happened the first
--- time this schema ran, because two of its column comments contain a semicolon.
---
--- So comments and quoted literals are skipped over here rather than trusted not
--- to contain a separator. Comments are *dropped* from the output, which is what
--- makes the result safe to hand to `prepare` unchanged.
local function splitStatements(sql)
    local statements, buf = {}, {}
    local i, n = 1, #sql
    while i <= n do
        local c = sql:sub(i, i)
        local two = sql:sub(i, i + 1)
        if two == "--" then
            local nl = sql:find("\n", i + 2, true)
            i = nl and nl + 1 or n + 1
        elseif two == "/*" then
            local close = sql:find("*/", i + 2, true)
            i = close and close + 2 or n + 1
        elseif c == "'" or c == '"' or c == "`" then
            -- Copied verbatim, so a separator inside a literal stays content.
            -- A doubled quote is SQL's escape for a literal quote.
            local j = i + 1
            while j <= n do
                local cj = sql:sub(j, j)
                if cj ~= c then
                    j = j + 1
                elseif sql:sub(j + 1, j + 1) == c then
                    j = j + 2
                else
                    break
                end
            end
            buf[#buf + 1] = sql:sub(i, j)
            i = j + 1
        elseif c == ";" then
            statements[#statements + 1] = table.concat(buf)
            buf = {}
            i = i + 1
        else
            buf[#buf + 1] = c
            i = i + 1
        end
    end
    statements[#statements + 1] = table.concat(buf)
    return statements
end

--- Run every statement in `sql` for its effect.
---
--- `prepare` is called directly rather than through `db:exec` so the statement
--- reaches SQLite exactly as `splitStatements` produced it. A failure carries the
--- offending statement with it: the raw `incomplete input` above cost a round of
--- diagnosis precisely because it did not.
local function execScript(db, sql)
    for _, statement in ipairs(splitStatements(sql)) do
        local trimmed = statement:match("^%s*(.-)%s*$")
        if #trimmed > 0 then
            local stmt = db:prepare(trimmed)
            -- Via a closure: `stmt` is ffi cdata and its method lookup goes
            -- through the metatype, which `pcall(stmt.step, stmt)` would depend
            -- on. Same reasoning as `Store.exec`.
            local ok, err = pcall(function() stmt:step() end)
            stmt:close()
            if not ok then
                error(string.format(
                    "meguru: schema statement failed: %s\n  %s",
                    tostring(err), trimmed), 0)
            end
        end
    end
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

    execScript(db, SCHEMA)
    Store.migrate(db)
    return db
end

--- Add one column to an existing table, unless it is already there.
---
--- Returns false when the ALTER failed, so the caller can leave the schema
--- version alone and try again on the next start.
---
--- The existence check is not politeness. `CREATE TABLE IF NOT EXISTS` in
--- `SCHEMA` has already given a *fresh* database every current column, while
--- `user_version` on that same new file is still 0 — so an unguarded ALTER
--- fails with "duplicate column name" and logs a warning on the first start of
--- every new install. That is the kind of noise that teaches a reader to skim
--- the log, which is the last thing this codebase can afford.
---
--- `pragma_table_info` is a table-valued function, so this is one statement
--- rather than a row loop over `PRAGMA table_info`. It needs SQLite 3.16+, and
--- the runtime here is 3.53.
local function addColumn(db, table_name, column, declaration)
    local present = tonumber(db:rowexec(string.format(
        "SELECT COUNT(*) FROM pragma_table_info('%s') WHERE name = '%s';",
        table_name, column))) or 0
    if present > 0 then
        return true
    end
    local ok, err = pcall(db.exec, db, string.format(
        "ALTER TABLE %s ADD COLUMN %s %s;", table_name, column, declaration))
    if not ok then
        logger.warn(string.format("meguru: migration: %s.%s:",
            table_name, column), err)
        return false
    end
    return true
end

--- Look at `PRAGMA user_version` and bring the database up to SCHEMA_VERSION.
--- A fresh database gets its version stamped without any migration running.
---
--- Each step is guarded by its own version and wrapped, so a failure is logged
--- and the remaining steps still run: a database the reader can still open
--- beats a plugin that refuses to start. The version is stamped only once every
--- step has succeeded, so a failed migration is retried on the next start
--- instead of being frozen in — stamping regardless would leave a database that
--- is one column short and will never grow it.
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

    local complete = true

    if version < 2 then
        -- A book's own artwork. Existing rows stay NULL and gain one on their
        -- next sync, which is harmless: a NULL here falls back to the series
        -- cover and then to page 1, so nothing regresses in the meantime.
        complete = addColumn(db, "items", "cover_url", "TEXT")
    end

    if complete then
        db:exec(string.format("PRAGMA user_version=%d;", SCHEMA_VERSION))
    end
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
