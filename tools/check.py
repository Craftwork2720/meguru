#!/usr/bin/env python3
"""Static checks for the meguru plugin, standing in for the Lua interpreter
this machine does not have.

None of the checks is a parser. They are the failure modes that have actually
bitten this codebase, and that a reader cannot reliably catch by eye:

  1. block balance -- a missing or extra `end`/`until`. Lua reports these as a
     syntax error at load time, which on a Kindle means the whole plugin
     silently fails to appear.
  2. cross-module member references -- `Defaults.FOO` where defaults.lua never
     assigns `Defaults.FOO`. This is invisible at load time and only explodes
     when the branch is reached, on the device, in the reader's hands.
  3. module tables that were never bound -- `Geom:new{...}` with no
     `local Geom = require("ui/geometry")`. The plugin loads and appears fine,
     then crashes the moment the branch runs.
  4. lowercase calls to a name bound only *below* them -- `handToReader(x)` with
     a `local function handToReader` further down the file. A `local` enters
     scope from its own statement onwards, so the call site resolves a global and
     finds nil. Loads fine, crashes when the branch runs.
  5. a name read as a *value* -- `pcall(renderMuPDFPage, ...)`, or `MAX_X / 1024`
     -- that is bound nowhere in the file. Checks 3 and 4 both key on the shape
     of the use, so a name handed over as an argument or an operand slips past
     both and reads as a global nil.
  6. a lowercase name reached through a `.` or a `:` -- `data:byte(off + 1)`
     with no `local data` anywhere. Check 3 keys on a capitalized module table,
     4 on a call and 5 on a value, so this last shape of the same failure had no
     pass at all: a refactor deleted a buffer local and left four `data:byte`
     call sites behind it, and nothing said a word.
  7. the marker's field list, which is a contract between the code that writes a
     marker and the code that reads one. A field read off a descriptor that
     `Marker.new` does not copy is nil on the device -- and nil is a legitimate
     answer for several of them, so it surfaces as a feature that quietly does
     nothing rather than as an error.
  8. the same contract for what a marker says about its *series*. This is pass 7
     in a second place, and it shipped twice before the pass existed: `dirFor`
     read `series.name` while every caller passed a context with `series_name`,
     so no series folder was ever created, and `freshResumeTarget` filtered on
     `series.remote_id`, so it never matched and the server-position button
     silently never appeared.
  9. a `for _` loop whose body calls the gettext `_()`. The loop variable
     shadows the function for the length of the body, so the call is an attempt
     to call the loop counter. Every part of it is individually correct and it
     reads perfectly, which is why it survived into a released build and was
     found by a device instead.
  10. an assignment to `_`, which is pass 9's collision seen from the other side:
     `panels, _, reason = f()` writes straight through to the file's gettext,
     because that binding is not a `local`. It shipped too, and it cost a device
     crash on the page-boundary crossing of a view nobody had exercised before.
  11. a field named after a method the host's widgets already define -- `free = nil`
     on a class that extends `ImageViewer`, whose `free` is
     `WidgetContainer:free(full)`. The field reads back as the method, so the next
     index on it throws, and it throws from inside a paint. Shipped, and found by
     a device.

The item-upsert check is gone with the catalog it belonged to: it compared
`UPSERT_ITEM` against the `items` DDL, and neither exists.

Run: python tools/check.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "meguru"

# --------------------------------------------------------------------------
# Stripping: comments and string literals must not take part in either check,
# and Lua has four literal forms -- '..', "..", [[..]], [=[..]=] -- plus long
# comments in the same bracket forms.
# --------------------------------------------------------------------------

LONG_OPEN = re.compile(r"\[(=*)\[")


def strip(source, keep_strings=False):
    """Return `source` with comments blanked out.

    Newlines are preserved so line numbers stay honest. String literals are
    collapsed to a single opaque token by default, which is what the member
    scan wants -- but the *require* scan needs them intact, because the module
    path lives inside one, so `keep_strings` leaves them verbatim.
    """
    out = []
    i, n = 0, len(source)
    while i < n:
        ch = source[i]

        # A comment, in either form. The long form has to be tested *before*
        # the line form: `--[[ foo\nbar ]]` scanned as a line comment would stop
        # at the first newline and leave `bar ]]` to be parsed as code.
        if ch == "-" and source.startswith("--", i):
            m = LONG_OPEN.match(source, i + 2)
            if m:
                close = "]" + m.group(1) + "]"
                end = source.find(close, m.end())
                end = n if end < 0 else end + len(close)
                out.append("\n" * source.count("\n", i, end))
            else:
                end = source.find("\n", i)
                end = n if end < 0 else end
                out.append(" " * (end - i))
            i = end
            continue

        # A long string, `[[...]]` or `[=[...]=]`.
        m = LONG_OPEN.match(source, i)
        if m:
            close = "]" + m.group(1) + "]"
            end = source.find(close, m.end())
            end = n if end < 0 else end + len(close)
            # Content is dropped but its newlines are re-emitted. A schema or
            # SQL block spans dozens of lines, and collapsing it would shift
            # every line number after it -- so a reported error would point at
            # the wrong place. It did: a missing `end` was reported well off its
            # real line, which is worse than useless in a file this size.
            out.append(source[i:end] if keep_strings
                       else " STR " + "\n" * source.count("\n", i, end))
            i = end
            continue

        if ch in "\"'":
            j = i + 1
            while j < n:
                if source[j] == "\\":
                    j += 2
                    continue
                if source[j] == ch:
                    j += 1
                    break
                j += 1
            out.append(source[i:j] if keep_strings else " STR ")
            i = j
            continue

        out.append(ch)
        i += 1
    return "".join(out)


# --------------------------------------------------------------------------
# Check 1: block balance.
# --------------------------------------------------------------------------

# `function`, `if`, `for` and `while` each open exactly one block. `do` also
# opens one -- but only when it is a bare block: after `for`/`while` it is the
# same block already counted, so counting it again doubles the depth. `repeat`
# is closed by `until` rather than `end`.
BLOCK_KEYWORDS = re.compile(
    r"\b(function|if|for|while|do|end|until|elseif|else|then)\b"
)

# `elseif` and `else` continue the `if` that is already open; `then` is part of
# it. None of the three changes the depth.
SKIP = {"elseif", "else", "then"}


def check_balance(path, text):
    """Report lines where the block nesting goes negative or ends non-zero."""
    depth = 0
    errors = []
    # A `for`/`while` header may put its `do` on a later line (`for _, x in
    # ipairs{ ... \n } do` is idiomatic here), so the "this do is already
    # counted" flag has to survive across lines until the `do` is consumed.
    pending_loop = False
    for lineno, line in enumerate(text.split("\n"), 1):
        for tok in BLOCK_KEYWORDS.finditer(line):
            word = tok.group(1)
            if word in SKIP:
                continue
            if word in ("for", "while"):
                pending_loop = True
                depth += 1
            elif word == "do":
                if pending_loop:
                    pending_loop = False
                else:
                    depth += 1
            elif word == "function" or word == "if":
                depth += 1
            else:  # end / until
                depth -= 1
            if depth < 0:
                errors.append(f"{path}:{lineno}: unbalanced 'end' (depth {depth})")
                depth = 0  # resync so one error does not cascade
    if depth != 0:
        errors.append(f"{path}: file ends with block depth {depth} (expected 0)")
    return errors


# --------------------------------------------------------------------------
# Check 2: cross-module member references.
# --------------------------------------------------------------------------

REQUIRE = re.compile(r'local\s+(\w+)\s*=\s*require\(\s*"(meguru[^"]*)"\s*\)')
# `Mod.field = ...` and `function Mod.field(...)` are the two ways a module
# declares a member.
ASSIGN = re.compile(r"^\s*(\w+)\.(\w+)\s*=")
FUNC = re.compile(r"^\s*function\s+(\w+)\.(\w+)\s*\(")
USE = re.compile(r"\b(\w+)\.(\w+)\b")


def module_members():
    """Return (module -> members, file stem -> module, every stem seen).

    The second map is what lets `require("meguru/doc/defaults")` be resolved to
    the `Defaults` local, whose members are the first map's value.

    The third is what keeps a *stale* require apart from a module this pass
    simply cannot read: `doc/document.lua` is a `Document:extend{...}`
    subclass, so it has no `local MegumuDocument = {}` and no members to check
    -- and `main.lua` requires it perfectly legitimately. Only a stem no file
    provides at all means a reference to something that was deleted.
    """
    members = {}
    by_stem = {}
    stems = set()
    for lua in sorted(SRC.rglob("*.lua")):
        stems.add(lua.stem)
        text = strip(lua.read_text(encoding="utf-8"))
        # The module's own local, e.g. `local Defaults = {}` in defaults.lua.
        #
        # **Identified by what the file returns**, not by being the first
        # `local X = {}` in it. That first-match rule was the original guess and
        # it is wrong the moment a module declares a second table at top level
        # before its own -- `syncjob.lua` grew a `local active = {}` guard and
        # this pass immediately reported `SyncJob.run` as "module active has no
        # member 'run'", pointing at a table that has nothing to do with the
        # call. Which table is the module is not a matter of position: it is the
        # one that leaves the file.
        returned = re.search(r"^return\s+(\w+)\s*$", text, re.M)
        if not returned:
            continue
        name = returned.group(1)
        declared = re.search(r"^local\s+" + re.escape(name) + r"\s*=\s*\{\s*\}\s*$",
            text, re.M)
        if not declared:
            continue
        found = set()
        for line in text.split("\n"):
            for rx in (ASSIGN, FUNC):
                m = rx.match(line)
                if m and m.group(1) == name:
                    found.add(m.group(2))
        members[name] = found
        by_stem[lua.stem] = name
    return members, by_stem, stems


def check_members(path, text, raw, members, by_stem, stems):
    """Every `Mod.member` for a required meguru module must be declared."""
    errors = []
    required = {}
    # Against `raw`: the module path is a string literal, which `text` has
    # collapsed -- scanning `text` here finds no requires at all and the whole
    # check passes vacuously.
    for m in REQUIRE.finditer(strip(raw, keep_strings=True)):
        alias, mod = m.group(1), m.group(2)
        # Require("meguru/doc/defaults") resolves to the `Defaults` local.
        name = by_stem.get(mod.split("/")[-1])
        if not name:
            # **A require of a module that no longer exists is an error, not a
            # skip.** This used to fall through silently, which meant that once a
            # module was deleted every `Catalog.foo` left behind became
            # *unchecked* rather than reported: the alias never entered
            # `required`, so the loop below never looked at it. That is the worst
            # possible failure for a checker whose whole job is catching
            # references to things that no longer exist, and it lands exactly when
            # a refactor is deleting modules.
            #
            # A stem that some file *does* provide is a different case and not an
            # error: the module is real, this pass just cannot read its exports
            # (see `module_members`).
            if mod.split("/")[-1] not in stems:
                errors.append(
                    f'{path}: `require("{mod}")` names no module in meguru/ '
                    f'-- is it a stale import?')
            continue
        required[alias] = name
    if not required:
        return errors
    for lineno, line in enumerate(text.split("\n"), 1):
        for m in USE.finditer(line):
            alias, member = m.group(1), m.group(2)
            target = required.get(alias)
            if target and member not in members[target]:
                errors.append(
                    f"{path}:{lineno}: {alias}.{member} -- "
                    f"module {target} has no member '{member}'"
                )
    return errors


# --------------------------------------------------------------------------
# Check 3: module tables that were never bound.
# --------------------------------------------------------------------------

# A capitalized identifier used as a module table: `Geom:new{...}` or
# `Geom.foo`. KOReader defines no global of this shape -- `ui/geometry.lua`
# ends `return Geom`, and every module in `frontend/` is reached through a
# require -- so a bare one is a name that resolves to nil at the moment the
# line runs. That is exactly how this codebase shipped a crash on the open
# path: `document.lua` used `Geom` twice without requiring `ui/geometry`.
#
# Nil-at-load is the easy case, because the whole plugin fails loudly. This
# one is worse: the module loads, the plugin appears, and the crash waits for
# a book to be opened. Nothing else here catches it -- check 2 only covers
# `meguru/...` requires.
#
# Keyed on the `:`/`.` itself, not on a `(` after the method name. An earlier
# draft required `Ident:method(`, which misses the most common call shape in
# this codebase -- `Geom:new{ w = ..., h = ... }` passes a table, so there is a
# `{` where that pattern wanted a `(`. It matched nothing, reported nothing,
# and passed on the exact bug it was written for.
MODULE_USE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\s*[:.]\s*[A-Za-z_]")

# Ways a name becomes bound in a file: `local X`, `local X = ...`,
# `local function X`, `X = ...` as a statement, and `function X.member()`.
#
# re.M is load-bearing on the first two. Without it `^`/`$` anchor to the whole
# file, so a bare `local Mupdf` -- declared, documented, and assigned inside
# the `do` block below it -- matches nothing and is reported as unbound. That
# was a false positive on two files the first time this pass ran.
BINDINGS = (
    re.compile(r"\blocal\s+([A-Za-z0-9_, \t]+?)\s*(?:=|$)", re.M),
    re.compile(r"^\s*([A-Z][A-Za-z0-9_]*)\s*=", re.M),
    re.compile(r"\blocal\s+function\s+([A-Za-z0-9_]+)"),
    re.compile(r"\bfunction\s+([A-Z][A-Za-z0-9_]*)[.:]"),
)

# Deliberately empty. Add a name here only with evidence from the runtime that
# the identifier is a genuine global -- the point of the check is that it is
# not one, and a name added to silence a true positive turns the pass off.
GLOBAL_ALLOWLIST = set()


def check_globals(path, text):
    """Report a capitalized module table used without ever being bound."""
    bound = set()
    for rx in BINDINGS:
        for m in rx.finditer(text):
            # `local a, b` binds both; the first pattern may capture a group.
            for name in m.group(1).split(","):
                bound.add(name.strip())
    errors = []
    for lineno, line in enumerate(text.split("\n"), 1):
        for m in MODULE_USE.finditer(line):
            name = m.group(1)
            if name in bound or name in GLOBAL_ALLOWLIST:
                continue
            errors.append(
                f"{path}:{lineno}: {name} is never bound in this file -- "
                f"missing `local {name} = require(...)`?"
            )
    return errors


# --------------------------------------------------------------------------
# Check 4: a lowercase call to a name that is not yet bound at that point.
# --------------------------------------------------------------------------

# Check 3 covers `Geom:new{...}`: a capitalized module table, never bound. It
# does not cover the same failure spelled with a lowercase name and a `(` --
# `handToReader(host, file)`, which `ui/open.lua` called from three places while
# its `local function` sat a hundred lines *below* them. A `local` enters scope
# only from its own statement onwards, so those call sites resolved the name as
# a global and found nil. It loaded, the plugin appeared, and the crash waited
# for a book to be opened and its neighbour requested.
#
# **Position is the whole check.** A pass that only asked "is this name bound
# anywhere in the file" passes on that bug, because the binding is right there
# -- just later. So bindings are collected with line numbers and a call is only
# excused by a binding at or above it.
CALL = re.compile(r"(?<![:.\w])([a-z_][A-Za-z0-9_]*)\s*\(")

# Every parameter list in the file. Load-bearing: `on_done(ok, err)` is a call
# on a parameter, and a pass that ignored parameters would report every callback
# in the codebase and be switched off inside a day.
FUNC_PARAMS = re.compile(r"\bfunction\b[^(]*\(([^)]*)\)")

# The lowercase counterparts of check 3's bindings, plus a bare `function f()`
# -- which assigns a global, and so genuinely does bind the name.
LOWER_BINDINGS = (
    re.compile(r"\blocal\s+([A-Za-z0-9_, \t]+?)\s*(?:=|$)", re.M),
    re.compile(r"\blocal\s+function\s+([A-Za-z0-9_]+)"),
    re.compile(r"^\s*function\s+([a-z_][A-Za-z0-9_]*)\s*\(", re.M),
)

# Lua's own globals, plus the keywords that can sit before a `(`. No KOReader
# name belongs here: one added to silence a true positive turns the pass off,
# so a real global gets its own entry with the evidence next to it.
LUA_GLOBALS = {
    "assert", "collectgarbage", "dofile", "error", "getfenv", "getmetatable",
    "ipairs", "load", "loadfile", "loadstring", "module", "next", "pairs",
    "pcall", "print", "rawequal", "rawget", "rawset", "require", "select",
    "setfenv", "setmetatable", "tonumber", "tostring", "type", "unpack",
    "xpcall",
    # The environment table itself, which `settings.lua` reads through
    # (`rawget(_G, "G_reader_settings")`) to avoid a hard dependency on a name
    # that may not exist yet at plugin-load time.
    "_G",
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function",
    "if", "in", "local", "nil", "not", "or", "repeat", "return", "then",
    "true", "until", "while",
}

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


def check_lowercase_calls(path, text):
    """Report a lowercase call to a name not bound at or above that line."""
    lines = text.split("\n")

    def lineno(offset):
        return text.count("\n", 0, offset) + 1

    bindings = {}

    def bind(name, line):
        name = name.strip()
        if not IDENT.match(name):
            return
        if name not in bindings or line < bindings[name]:
            bindings[name] = line

    for rx in LOWER_BINDINGS:
        for m in rx.finditer(text):
            for name in m.group(1).split(","):
                bind(name, lineno(m.start()))
    for m in FUNC_PARAMS.finditer(text):
        for name in m.group(1).split(","):
            bind(name, lineno(m.start()))

    errors = []
    for line_no, line in enumerate(lines, 1):
        for m in CALL.finditer(line):
            name = m.group(1)
            if name in LUA_GLOBALS:
                continue
            if name in bindings and bindings[name] <= line_no:
                continue
            errors.append(
                f"{path}:{line_no}: {name}(...) is not bound at this point -- "
                f"a `local` below it would resolve as a global here"
            )
    return errors


# --------------------------------------------------------------------------
# Check 5: a name used as a VALUE that is bound nowhere in the file.
# --------------------------------------------------------------------------

# Checks 3 and 4 both key on the shape of the *use*: 3 wants `Name.member` or
# `Name:member`, 4 wants `name(`. A name handed over as a plain value matches
# neither, and two bugs of exactly that shape reached the device:
#
#   `pcall(renderMuPDFPage, self.mupdf_doc, 1, nil)` has a comma where check 4
#   wanted a `(`. `renderMuPDFPage` is a file-local of `image.lua`, exported as
#   `Image.renderMupdfPage`, so in `document.lua` it was a global reading nil --
#   `pcall(nil, ...)` returns false, the caller logged "could not render local
#   cbz cover" and returned nil, and a local cbz never had a cover.
#
#   `MAX_LOSSLESS_NATIVE_PIXELS / 1024 / 1024` is not a call at all. The
#   constant is a local of `image.lua`; in `document.lua` it was nil, so the one
#   log line that exists to explain why a giant lossless page is skipped raised
#   "attempt to perform arithmetic on a nil value" instead of explaining it.
#
# The rule was the narrowest one that catches both: the name must be bound
# NOWHERE in the file. Check 4 kept the positional half of the problem, on the
# grounds that a pass claiming it here "would report every forward reference in
# the codebase" -- and that was wrong, and it cost a bug.
#
#   A `local function maskToQuad` was added BELOW `Image.renderRegion`, which
#   called it through `pcall(maskToQuad, ...)`. Lua resolves a name at COMPILE
#   time against the locals in scope at that point in the source, so inside
#   `renderRegion` the name was a global read: `pcall(nil, ...)` returned false,
#   the pcall's own handler logged "panel crop mask failed", and the panel crop
#   silently went unmasked. Every page loaded, every test passed, and the
#   feature did nothing.
#
# The old reasoning confused two things. A forward reference to a `local` is
# *not* a legitimate pattern in Lua -- it is this same bug -- and the pattern
# that does work, mutual recursion, declares `local b` before its first use, so
# it is bound at or above the use and passes. There were no false positives
# waiting: adding the positional rule below reports nothing anywhere in the
# tree, which is the measurement that settles it.
#
# So a use is excused by a binding at or above its line, exactly as check 4
# excuses a call. Same approximation, same direction: a `local` in a function
# that is not in scope at the use still counts, which can only ever miss a
# finding and never invent one.
#
# Deliberately not a style police: a name that is only ever ASSIGNED is left
# alone. `foo = 1` at file scope is a deliberate global, and so is a table key.
# Only a name that is read and never written is reported.
#
# Note it cannot see the use side of `local x` itself -- `x` in `local x = 1`
# is followed by `=`, which is the assignment exemption below. That is the
# intended direction: the binding patterns run over the whole file first, so a
# name declared anywhere is excused here.
VALUE_USE = re.compile(r"(?<![\w.:])([A-Za-z_][A-Za-z0-9_]*)(?![\w])")

# `strip` collapses every string literal to this token, and to this pass the
# token reads as a bare identifier -- so every string in the codebase reported
# as an unbound name until it was named here. Spelling the coupling out from
# both ends is the point: change the sentinel in `strip` and this line is what
# tells you there was a second reader of it.
STRIPPED_STRING = "STR"

# Words that may legally sit immediately before a value-use without being one:
# only the statement forms whose *next* token is a binding or a keyword rather
# than a read -- `local x`, `for k, v in`, and the clause openers.
#
# `return`, `not`, `and` and `or` were in this set and are not: what follows each
# of them is read, not bound, so listing them here silently exempted the token
# from the pass. `if not lead_index then` with the name misspelled was exactly
# that -- a name read as a value, bound nowhere, and reported by nothing. Found
# by injecting the typo while self-testing a new module; with them removed the
# pass finds it and the rest of the tree is unchanged (no false positives).
VALUE_PREFIX_SKIP = {"local", "function", "for", "in", "if", "while",
                     "until", "then", "else", "elseif", "repeat", "do"}

# For-loop variables, which are bound by the loop header rather than by a
# `local`: `for key, item in self.cache:pairs()`. Without this every loop in
# the codebase reports its own counters.
FOR_BINDINGS = re.compile(r"\bfor\s+([A-Za-z0-9_, \t]+?)\s*(?:=|in\b)")

# The receiver of a method definition, which is implicit rather than declared.
IMPLICIT_BINDINGS = {"self", "..."}

# Every bare global this codebase genuinely reads, with the evidence. KOReader
# creates these in `setupkoenv`/`datastorage` before any plugin loads; each one
# added here is a name this pass would otherwise report on every run, and a
# name added to silence a true positive turns the pass off.
VALUE_GLOBAL_ALLOWLIST = {
    # `_` is KOReader's gettext table and `C_` its context variant. Both are
    # installed as globals by `setupkoenv.lua` (`_ = require("gettext")`).
    "_", "C_", "N_",
    # LuaSettings instances KOReader sets on the global table at startup.
    "G_reader_settings", "G_defaults",
    # The device's own screen, in files that reach it through `Device` instead
    # of requiring `device`.
    "Screen",
}


def check_value_uses(path, text):
    """Report a name read as a value that is not bound at or above its line."""
    def lineno(offset):
        return text.count("\n", 0, offset) + 1

    # Name -> the earliest line that binds it, the same shape check 4 builds.
    bindings = {}

    def bind(name, line):
        name = name.strip()
        if not IDENT.match(name):
            return
        if name not in bindings or line < bindings[name]:
            bindings[name] = line

    for rx in BINDINGS + LOWER_BINDINGS:
        for m in rx.finditer(text):
            for name in m.group(1).split(","):
                bind(name, lineno(m.start()))
    for m in FUNC_PARAMS.finditer(text):
        for name in m.group(1).split(","):
            bind(name, lineno(m.start()))
    for m in FOR_BINDINGS.finditer(text):
        for name in m.group(1).split(","):
            bind(name, lineno(m.start()))

    errors = []
    for lineno_, line in enumerate(text.split("\n"), 1):
        for m in VALUE_USE.finditer(line):
            name = m.group(1)
            if name == STRIPPED_STRING or name in LUA_GLOBALS:
                continue
            if name in IMPLICIT_BINDINGS or name in VALUE_GLOBAL_ALLOWLIST:
                continue
            bound_here = bindings.get(name)
            if bound_here is not None and bound_here <= lineno_:
                continue
            rest = line[m.end():]
            if rest[:1] == "." or rest[:1] == ":":
                continue  # a field or method: checks 2 and 3 own this
            after = rest.lstrip()
            if after[:1] == "(":
                continue  # a call: check 4 owns this
            if after[:1] == "=" and after[:2] != "==":
                continue  # an assignment or a table key: a write, not a read
            before = line[:m.start()].rstrip()
            word = re.search(r"([A-Za-z_][A-Za-z0-9_]*)$", before)
            if word and word.group(1) in VALUE_PREFIX_SKIP:
                continue
            errors.append(
                f"{path}:{lineno_}: {name} is read as a value but not bound at "
                f"this point -- it resolves to a global reading nil"
            )
    return errors


# --------------------------------------------------------------------------
# Check 6: a lowercase name used as a table, bound nowhere in the file.
# --------------------------------------------------------------------------

# Check 3 covers `Geom:new{...}` — a capitalized module table used without being
# bound. Check 4 covers `handToReader(x)` — a call. Check 5 covers a name read as
# a value. Between them, one shape is left: a LOWERCASE name reached through a
# `.` or a `:`.
#
# That is not hypothetical. A refactor of the crop scanner replaced a buffer
# read with a pointer read and deleted the `local data` that four lines further
# down were still calling `data:byte(off + 1)` through. Nothing complained: the
# plugin loads, the page renders, and the crop dies on the first page turn with
# "attempt to index a nil value" -- on the device, in the reader's hands, which
# is the failure this whole file exists to prevent. It was caught by grepping
# for the name by hand, which is exactly what a check is for.
#
# Position matters as it does in check 4: a `local` below the use does not bind
# it. `self` is the one name that is never bound and never should be, so it is
# exempt by name rather than by allowlist -- see the note on VALUE_GLOBAL_ALLOWLIST
# about names added to silence true positives.
RECEIVER_USE = re.compile(r"(?<![\w.:])([a-z_][A-Za-z0-9_]*)\s*[.:]\s*[A-Za-z_]")

# Receivers that are neither bound nor wrong: `self` is declared by the method
# syntax, and `...` is not a name at all.
RECEIVER_SKIP = {"self"}

# Lua's own library tables. These are globals in every Lua 5.1 runtime -- the
# `string`, `table`, `math` and `os` half of the language, which is why they are
# never bound anywhere and never should be. `bit`, `jit` and `ffi` come with
# LuaJIT, which is the only Lua this plugin runs on.
#
# Deliberately NOT part of LUA_GLOBALS: that set is shared with checks 4 and 6,
# and widening it would quietly widen those too -- a change to a check that was
# self-tested against its own failure is not something to make as a side effect
# of adding another.
LUA_STDLIB_TABLES = {
    "string", "table", "math", "os", "io", "coroutine", "debug", "package",
    "bit", "jit", "ffi",
}


def check_receiver_uses(path, text):
    """Report a lowercase `name.member` / `name:member` with no binding."""
    lines = text.split("\n")

    def lineno(offset):
        return text.count("\n", 0, offset) + 1

    bindings = {}

    def bind(name, line):
        name = name.strip()
        if not IDENT.match(name):
            return
        if name not in bindings or line < bindings[name]:
            bindings[name] = line

    for rx in LOWER_BINDINGS + BINDINGS:
        for m in rx.finditer(text):
            for name in m.group(1).split(","):
                bind(name, lineno(m.start()))
    for m in FUNC_PARAMS.finditer(text):
        for name in m.group(1).split(","):
            bind(name, lineno(m.start()))
    # For-loop variables are bound by the loop header, not by a `local`.
    for m in FOR_BINDINGS.finditer(text):
        for name in m.group(1).split(","):
            bind(name, lineno(m.start()))

    errors = []
    for line_no, line in enumerate(lines, 1):
        for m in RECEIVER_USE.finditer(line):
            name = m.group(1)
            if (name in LUA_GLOBALS or name in RECEIVER_SKIP
                    or name in LUA_STDLIB_TABLES):
                continue
            if name == STRIPPED_STRING:
                continue
            if name in bindings and bindings[name] <= line_no:
                continue
            errors.append(
                f"{path}:{line_no}: {name} is used as a table but is bound "
                f"nowhere in this file -- it resolves to a global reading nil"
            )
    return errors




# --------------------------------------------------------------------------
# Check 7: the marker's field list is a contract between the code that writes a
# marker and the code that reads one, and Lua checks neither end. A field read
# off a descriptor that `Marker.new` does not copy is nil on the device,
# silently -- and nil is a legitimate answer for several of them, so the failure
# surfaces as a feature that quietly does nothing. That is what happens the
# first time a field is added to a reader and not to the writer.
#
# Scope is the descriptor, named on purpose: `desc` is this plugin's word for a
# marker and nothing else, so the pattern has no false positives to trade
# against. A general "every table field is written somewhere" pass would be a
# much larger and much more false-positive-prone job than the failure this
# prevents.
# --------------------------------------------------------------------------

MARKER_NEW_BODY = re.compile(r"function Marker\.new\(fields\)\s*return \{(.*?)\n    \}", re.S)
MARKER_NEW_CALL = re.compile(r"Marker\.new\s*\{(.*?)\}", re.S)
# The full identifier, not `[a-z_]+`: a field name with a capital in it -- which
# is what a typo looks like, and what a field added later might legitimately be
# -- would otherwise be truncated to its lowercase prefix and reported under a
# name nobody typed. An injected `desc.seriesXX` was caught as `desc.series`,
# which is the right verdict for the wrong reason: it fired because `series`
# happens to be absent too, and would have stayed silent for a field whose
# prefix *is* a real field name.
DESC_READ = re.compile(r"\bdesc\.([A-Za-z_][A-Za-z0-9_]*)")
TABLE_KEY = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=", re.M)


def marker_fields():
    """The fields `Marker.new` copies, or None if its shape could not be read."""
    src = strip((SRC / "marker.lua").read_text(encoding="utf-8"))
    m = MARKER_NEW_BODY.search(src)
    if not m:
        return None
    return set(TABLE_KEY.findall(m.group(1)))


def check_marker_fields(fields):
    """Report a descriptor field read, or passed, that `Marker.new` drops."""
    if fields is None:
        return ["tools/check.py: could not read Marker.new -- "
                "this check has gone stale"]
    errors = []
    files = sorted(SRC.rglob("*.lua")) + [ROOT / "main.lua"]
    for lua in files:
        rel = lua.relative_to(ROOT)
        src = strip(lua.read_text(encoding="utf-8"))
        for name in sorted(set(DESC_READ.findall(src))):
            if name not in fields:
                errors.append(
                    f"{rel}: `desc.{name}` is read, but Marker.new does not "
                    f"write that field")
        for call in MARKER_NEW_CALL.finditer(src):
            for name in sorted(set(TABLE_KEY.findall(call.group(1)))):
                if name not in fields:
                    errors.append(
                        f"{rel}: Marker.new is handed `{name}`, which it does "
                        f"not copy")
    return errors


# --------------------------------------------------------------------------
# Check 8: the same contract for what a marker says about its *series*.
#
# This is pass 7's failure in a second place, and it shipped twice before this
# pass existed. A field read off a shape that does not have it is nil on the
# device rather than an error, so the symptom is a feature that quietly does
# nothing:
#
#   * `Marker.dirFor` read `series.name` while every caller passed a context
#     with `series_name`, so **no series folder was ever created** -- every new
#     marker landed beside its series rather than inside it.
#   * `freshResumeTarget` filtered on `series.remote_id`, which the context does
#     not have either, so nothing matched and it always returned nil: the `▶`
#     server-position button never appeared, and "the server has no opinion" is
#     a legitimate state, so nothing reported it.
#
# The shape has exactly one definition -- `Marker.seriesContext` -- so this is
# the same name-based rule pass 7 uses, with the same caveat: it assumes
# `series` and `context` mean one thing here. They do, and the parameter that
# did not (`dirFor`'s `series`) was precisely the bug.
# --------------------------------------------------------------------------

SERIES_CONTEXT_BODY = re.compile(
    r"function Marker\.seriesContext\(desc\)(.*?)\n    \}", re.S)
CONTEXT_READ = re.compile(r"\b(?:series|context)\.([A-Za-z_][A-Za-z0-9_]*)")


def series_context_fields():
    """The fields `Marker.seriesContext` returns, or None if unreadable."""
    src = strip((SRC / "marker.lua").read_text(encoding="utf-8"))
    m = SERIES_CONTEXT_BODY.search(src)
    if not m:
        return None
    return set(TABLE_KEY.findall(m.group(1)))


def check_series_context(fields):
    """Report a context field read that `Marker.seriesContext` does not return."""
    if fields is None:
        return ["tools/check.py: could not read Marker.seriesContext -- "
                "this check has gone stale"]
    errors = []
    files = sorted(SRC.rglob("*.lua")) + [ROOT / "main.lua"]
    for lua in files:
        rel = lua.relative_to(ROOT)
        src = strip(lua.read_text(encoding="utf-8"))
        for name in sorted(set(CONTEXT_READ.findall(src))):
            if name not in fields:
                errors.append(
                    f"{rel}: `series.{name}` or `context.{name}` is read, but "
                    f"Marker.seriesContext does not return that field")
    return errors


# --------------------------------------------------------------------------
# Check 9: a `for _` loop whose body calls the gettext `_()`.
#
# Every Lua file here opens with `local _ = require("gettext")`, and every
# discarded loop index is written `_` -- those two conventions collide the moment
# a message is needed *inside* the loop, and the call becomes an attempt to call
# the index:
#
#     for _, relative in ipairs(FILES) do
#         return nil, _("not a Meguru release")   -- calls the counter
#     end
#
# This one reached a device, inside the updater's verification step, and the
# crash it produced is the reason it is a check rather than a note. What makes
# it survivable by reading is that nothing is individually wrong: the loop is
# idiomatic, the message is a message, and the shadowing is invisible unless you
# hold both in mind at once. Passes 5 and 6 both skip `_` by name -- correctly,
# since it is a global they must not report -- so nothing covered it.
#
# The extent of a loop is found by matching blocks, not by indentation or by
# scanning for the next `end`: a loop body is full of nested `function`s and
# tables, and the first `end` after the header almost never closes the loop. The
# keyword stack below is the whole of Lua's nesting rule for this purpose --
# `do` opens a block except when it terminates a `for`/`while` header, which
# consumed it already.
# --------------------------------------------------------------------------

LUA_KEYWORD = re.compile(r"\b(function|if|for|while|do|end|until|repeat)\b")
FOR_HEADER = re.compile(r"\bfor\s+([^)]*?)\s+(?:in|=)")
GETTEXT_CALL = re.compile(r"(?<![\w.])_\s*\(")
# `_` in an assignment, but not `==`, not a field (`x._ =`), not a longer name.
ASSIGN_TARGETS = re.compile(r"^\s*([^=<>~]*?)\s*=(?!=)")


def block_spans(text):
    """(start, end) offsets of every block, `end` inclusive of its keyword.

    Shared by the two `_` passes, which need the same thing: the extent of the
    scope a name was bound in. Pass 9 asks it of a `for` header, the assignment
    pass of a `local` -- both are asking "how far does this binding reach".
    """
    spans = []
    stack = []
    pending_do = 0
    for m in LUA_KEYWORD.finditer(text):
        word = m.group(1)
        if word in ("function", "if", "repeat"):
            stack.append(m.start())
        elif word in ("for", "while"):
            stack.append(m.start())
            pending_do += 1
        elif word == "do":
            if pending_do:
                pending_do -= 1
            else:
                stack.append(m.start())
        elif word in ("end", "until"):
            if stack:
                spans.append((stack.pop(), m.end()))
    return spans


def enclosing_span(spans, offset):
    """The innermost span containing `offset`, or None for the file itself."""
    best = None
    for start, end in spans:
        if start <= offset < end and (best is None or end - start < best[1] - best[0]):
            best = (start, end)
    return best


def check_gettext_shadow(path, text):
    """Report a `_()` call inside a loop that binds `_` as its variable."""
    errors = []
    for start, end in block_spans(text):
        header = FOR_HEADER.match(text, start)
        if not header:
            continue
        names = [n.strip() for n in header.group(1).split(",")]
        if "_" not in names:
            continue
        body = text[header.end():end]
        call = GETTEXT_CALL.search(body)
        if call:
            lineno = text.count("\n", 0, header.end() + call.start()) + 1
            errors.append(
                f"{path}:{lineno}: `_()` here is inside a `for _` loop -- `_` is "
                f"the loop counter, not gettext, so this calls a number"
            )
    return errors

def check_gettext_assign(path, text, raw):
    """Report a binding of `_` that outlives its statement, other than gettext.

    `_` is the translate function in every file here, and Lua's other use of the
    name -- a discarded value -- writes through to it whenever the binding is
    *not* a `local`: `panels, _, reason = doc:getPanelsFromPage(...)` replaced the
    file's gettext with that function's second return, a boolean. It shipped, and
    it cost a device crash: the line was years older than the `_(...)` in the same
    file that finally called a boolean, so nothing had ever noticed.

    The test looks at the assignment's **targets**, split on commas, and asks
    whether one of them is `_` -- not at the shape `_ =`, which is what the first
    version of this did and which misses every multiple assignment, the case it
    exists for. Its first version also passed on the injected bug, which is the
    whole reason each pass here is self-tested before it is trusted.

    What is allowed: the gettext binding itself, and a `for` counter, which lives
    only inside its loop (pass 9 is the other half of that one). The binding is
    recognised in the *raw* line, because stripping has already collapsed
    `require("gettext")` to `require( STR )`; both texts have the same line count,
    which is what makes one line number mean the same thing in each.

    The two shapes are not equally dangerous and the pass does not treat them as
    such. A plain assignment reaches the *file's* binding, so every `_(...)` that
    runs afterwards anywhere in the file is broken -- always reported. A `local`
    shadows only for the rest of its own block, so it is reported only when
    something in that block translates after it: five files here discard a value
    into `_` with no `_(...)` anywhere near, and flagging those would be noise that
    teaches a reader to ignore the pass.

    What it cannot see: an assignment whose `=` sits on a later line than its
    targets. Nothing here writes one, and this is a guard rather than a parser.
    """
    errors = []
    raw_lines = raw.split("\n")
    spans = block_spans(text)
    offset = 0
    for lineno, line in enumerate(text.split("\n"), start=1):
        m = ASSIGN_TARGETS.match(line)
        if m:
            left = m.group(1).strip()
            keyword = ""
            for kw in ("local", "for"):
                if left.startswith(kw + " ") or left == kw:
                    keyword = kw
                    left = left[len(kw):].strip()
                    break
            raw_line = raw_lines[lineno - 1] if lineno <= len(raw_lines) else ""
            if ("_" in [name.strip() for name in left.split(",")]
                    and keyword != "for" and "gettext" not in raw_line):
                if keyword != "local":
                    errors.append(
                        f"{path}:{lineno}: this assigns to `_`, which is gettext in "
                        f"every file here, so every `_(...)` that runs after it -- "
                        f"anywhere in the file -- calls whatever was assigned"
                    )
                else:
                    span = enclosing_span(spans, offset)
                    call = GETTEXT_CALL.search(text, offset + m.end())
                    if call and call.start() < (span[1] if span else len(text)):
                        call_line = text.count("\n", 0, call.start()) + 1
                        errors.append(
                            f"{path}:{lineno}: `local ... , _ = ...` shadows gettext, "
                            f"and line {call_line} in the same block calls `_(...)` -- "
                            f"give the discarded value a name of its own"
                        )
        offset += len(line) + 1
    return errors

# The methods KOReader's own widget classes define, and which therefore cannot be
# *fields* of a class that extends one: `ImageViewer` is a `WidgetContainer`, so
# `self.free` is `WidgetContainer:free(full)` — a function, and the next `.scale` on it
# is `attempt to index field 'free' (a function value)`, thrown from inside a paint.
# This shipped, and a device found it.
#
# The list is the widget lifecycle plus the viewer's own event handlers, and it is short
# on purpose: a name here is a claim that the host owns it, and a name the host does not
# own would be a false positive that teaches a reader to ignore the pass.
WIDGET_METHODS = {
    "free", "init", "update", "paintTo", "getSize", "handleEvent", "setText",
    "onShow", "onClose", "onCloseWidget", "onTap", "onSwipe", "onHold",
    "onHoldRelease", "onPan", "onPanRelease", "onPinch", "onSpread",
    "onZoomIn", "onZoomOut", "onSaveImageView", "openFile", "close", "show", "hide",
}

TABLE_OPEN = re.compile(r":(?:extend|new)\s*\{")


def check_widget_fields(path, text):
    """Report a field named after a method the host's widgets already define.

    Only *field* names are reported — a `name = value` inside an `extend{...}` table or a
    `:new{...}` call. An override written as `function PanelViewer:onSwipe(...)` is this
    file's own method and is exactly right, and the two look nothing alike in the source,
    which is why the distinction is mechanical rather than a judgement.
    """
    errors = []
    for open_brace in TABLE_OPEN.finditer(text):
        depth = 1
        i = open_brace.end()
        while i < len(text) and depth > 0:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        body = text[open_brace.end():i - 1]
        for field in re.finditer(r"(?<![\w.:])(\w+)\s*=(?!=)", body):
            name = field.group(1)
            if name in WIDGET_METHODS:
                lineno = text.count("\n", 0, open_brace.end() + field.start()) + 1
                errors.append(
                    f"{path}:{lineno}: `{name}` is a method of the widget classes this "
                    f"file extends, so a field of that name is not a field -- it reads "
                    f"back as the method, and indexing it throws inside a paint"
                )
    return errors

def main():
    members, by_stem, stems = module_members()
    all_errors = []
    files = sorted(SRC.rglob("*.lua")) + [ROOT / "main.lua"]
    for lua in files:
        raw = lua.read_text(encoding="utf-8")
        text = strip(raw)
        rel = lua.relative_to(ROOT)
        all_errors += check_balance(rel, text)
        all_errors += check_members(rel, text, raw, members, by_stem, stems)
        all_errors += check_globals(rel, text)
        all_errors += check_lowercase_calls(rel, text)
        all_errors += check_value_uses(rel, text)
        all_errors += check_receiver_uses(rel, text)
        all_errors += check_gettext_shadow(rel, text)
        all_errors += check_gettext_assign(rel, text, raw)
        all_errors += check_widget_fields(rel, text)

    all_errors += check_marker_fields(marker_fields())
    all_errors += check_series_context(series_context_fields())

    if all_errors:
        for e in all_errors:
            print(e)
        print(f"\n{len(all_errors)} problem(s)")
        return 1
    print(f"ok -- {len(files)} files, {len(members)} modules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
