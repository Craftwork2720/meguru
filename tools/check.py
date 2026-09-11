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
  5. the item upsert's column list, `?` placeholders and `bind` arguments agree.
     Four separate edits have to stay in step and Lua checks none of them, so a
     mismatch is a runtime error on the first sync, on the device.
  6. a name read as a *value* -- `pcall(renderMuPDFPage, ...)`, or `MAX_X / 1024`
     -- that is bound nowhere in the file. Checks 3 and 4 both key on the shape
     of the use, so a name handed over as an argument or an operand slips past
     both and reads as a global nil.
  7. a lowercase name reached through a `.` or a `:` -- `data:byte(off + 1)`
     with no `local data` anywhere. Checks 3 keys on a capitalized module table,
     4 on a call and 6 on a value, so this last shape of the same failure had no
     pass at all: a refactor deleted a buffer local and left four `data:byte`
     call sites behind it, and nothing said a word.

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
    """Return (module -> members, file stem -> module).

    The second map is what lets `require("meguru/doc/defaults")` be resolved to
    the `Defaults` local, whose members are the first map's value.
    """
    members = {}
    by_stem = {}
    for lua in sorted(SRC.rglob("*.lua")):
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
    return members, by_stem


def check_members(path, text, raw, members, by_stem):
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
        if name:
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
# Check 6: a name used as a VALUE that is bound nowhere in the file.
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
# The rule is the narrowest one that catches both: the name must be bound
# NOWHERE in the file. Check 4 keeps the positional half of the problem (a
# binding *below* the use), and a pass that also claimed that here would report
# every forward reference in the codebase.
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
# the statement forms that bind rather than read, plus `return`/`and`/`or`,
# where the following token is still checked on its own account.
VALUE_PREFIX_SKIP = {"local", "function", "for", "in", "return", "not", "and",
                     "or", "if", "while", "until", "then", "else", "elseif",
                     "repeat", "do"}

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
    """Report a name read as a value that is bound nowhere in the file."""
    bound = set(IMPLICIT_BINDINGS)
    for rx in BINDINGS + LOWER_BINDINGS:
        for m in rx.finditer(text):
            for name in m.group(1).split(","):
                bound.add(name.strip())
    for m in FUNC_PARAMS.finditer(text):
        for name in m.group(1).split(","):
            bound.add(name.strip())
    for m in FOR_BINDINGS.finditer(text):
        for name in m.group(1).split(","):
            bound.add(name.strip())

    errors = []
    for lineno, line in enumerate(text.split("\n"), 1):
        for m in VALUE_USE.finditer(line):
            name = m.group(1)
            if name == STRIPPED_STRING or name in LUA_GLOBALS or name in bound:
                continue
            if name in VALUE_GLOBAL_ALLOWLIST:
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
                f"{path}:{lineno}: {name} is read as a value but bound nowhere "
                f"in this file -- it resolves to a global reading nil"
            )
    return errors


# --------------------------------------------------------------------------
# Check 7: a lowercase name used as a table, bound nowhere in the file.
# --------------------------------------------------------------------------

# Check 3 covers `Geom:new{...}` — a capitalized module table used without being
# bound. Check 4 covers `handToReader(x)` — a call. Check 6 covers a name read as
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
# Check 5: the item upsert's columns, placeholders and binds stay in step.
# --------------------------------------------------------------------------

# `Catalog.upsertItems` is the one statement every sync and every open writes
# through, and it is spread over four places that must agree: the INSERT column
# list, the `?` placeholders in VALUES, the positional `stmt:bind(...)` call, and
# the `DO UPDATE SET` list. Lua checks none of them, and getting one wrong is not
# a load-time error -- it is "NOT NULL constraint failed" or "table items has no
# column named X" on the first sync, on the device.
#
# This one has not bitten yet. It was written the moment adding a column meant
# editing all four by hand, with no interpreter on this machine to confirm it --
# the hand-check is the check, so it is worth keeping.
#
# Scope is deliberately one statement, named. A general "every bind matches its
# SQL" pass would need to pair each `prepare` with its `bind` across files, and
# that is a different, much larger, and much more false-positive-prone job than
# the one failure this exists to prevent.
UPSERT_ITEM = re.compile(r"local UPSERT_ITEM = .*?\[\[(.*?)\]\]", re.S)


def check_item_upsert():
    """Report a disagreement inside the item upsert, or a column it cannot have."""
    catalog = (SRC / "catalog.lua").read_text(encoding="utf-8")
    store = (SRC / "store.lua").read_text(encoding="utf-8")
    errors = []

    lit = UPSERT_ITEM.search(catalog)
    if not lit:
        return ["tools/check.py: UPSERT_ITEM not found in catalog.lua -- "
                "this check has gone stale"]
    sql = lit.group(1)

    m = re.search(r"INSERT INTO items \((.*?)\)\s*VALUES \((.*?)\)", sql, re.S)
    if not m:
        return ["tools/check.py: could not read the INSERT from UPSERT_ITEM -- "
                "this check has gone stale"]
    cols = [c.strip() for c in m.group(1).split(",") if c.strip()]
    values = [v.strip() for v in m.group(2).split(",") if v.strip()]
    holders = [v for v in values if v == "?"]
    literals = [v for v in values if v != "?"]

    bind = re.search(r"stmt:bind\((.*?)\)\s*\n", catalog, re.S)
    if not bind:
        return ["tools/check.py: could not read stmt:bind -- "
                "this check has gone stale"]
    args = [a.strip() for a in bind.group(1).split(",") if a.strip()]

    # A literal in VALUES (there is one: `removed_at` is written as NULL, since
    # a row written by an upsert is by definition not removed) takes a column
    # but no placeholder and no argument.
    expected = len(cols) - len(literals)
    if not (expected == len(holders) == len(args)):
        errors.append(
            f"catalog.lua: UPSERT_ITEM is out of step -- {len(cols)} columns "
            f"with {len(literals)} literal(s) need {expected}, but VALUES has "
            f"{len(holders)} placeholder(s) and bind has {len(args)} argument(s)")

    # Every DO UPDATE SET target must be a column `items` actually has, or the
    # statement dies with "no such column" the first time a row already exists.
    ddl = re.search(r"CREATE TABLE IF NOT EXISTS items \((.*?)\n\);", store, re.S)
    if not ddl:
        errors.append("tools/check.py: could not read the items DDL -- "
                      "this check has gone stale")
        return errors
    declared = set(re.findall(r"^\s*([a-z_]+)\s+(?:INTEGER|TEXT|REAL|BLOB)",
                              ddl.group(1), re.M))
    targets = re.findall(r"^\s{4}([a-z_]+)\s*=", sql, re.M)
    for name in targets:
        if name not in declared:
            errors.append(
                f"catalog.lua: UPSERT_ITEM sets `{name}`, which is not a column "
                f"of items")
    return errors


# --------------------------------------------------------------------------

def main():
    members, by_stem = module_members()
    all_errors = []
    files = sorted(SRC.rglob("*.lua")) + [ROOT / "main.lua"]
    for lua in files:
        raw = lua.read_text(encoding="utf-8")
        text = strip(raw)
        rel = lua.relative_to(ROOT)
        all_errors += check_balance(rel, text)
        all_errors += check_members(rel, text, raw, members, by_stem)
        all_errors += check_globals(rel, text)
        all_errors += check_lowercase_calls(rel, text)
        all_errors += check_value_uses(rel, text)
        all_errors += check_receiver_uses(rel, text)

    all_errors += check_item_upsert()

    if all_errors:
        for e in all_errors:
            print(e)
        print(f"\n{len(all_errors)} problem(s)")
        return 1
    print(f"ok -- {len(files)} files, {len(members)} modules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
