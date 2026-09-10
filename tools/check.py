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
        local = re.search(r"^local\s+(\w+)\s*=\s*\{\s*\}\s*$", text, re.M)
        if not local:
            continue
        name = local.group(1)
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

    if all_errors:
        for e in all_errors:
            print(e)
        print(f"\n{len(all_errors)} problem(s)")
        return 1
    print(f"ok -- {len(files)} files, {len(members)} modules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
