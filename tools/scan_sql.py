"""Find a semicolon inside a SQL comment, in any Lua string literal.

ljsqlite3's `conn:exec` splits a script on every `;` with no understanding of
SQL, so a `--` comment containing one tears a statement in half and SQLite
reports the fragment as `incomplete input` -- naming no file, line or statement.
That cost a diagnosis round once; this makes the next one free.

Run from the repo root:  python tools/scan_sql.py
"""

import pathlib
import re
import sys

sys.stdout.reconfigure(encoding="utf-8", errors="replace")

SQL_KEYWORDS = re.compile(
    r"\b(SELECT|INSERT|UPDATE|DELETE|CREATE|PRAGMA|BEGIN|COMMIT|ON CONFLICT|WHERE|FROM)\b",
    re.IGNORECASE,
)


def string_literals(src):
    """Yield the body of every Lua string literal in `src`, comments skipped."""
    i, n = 0, len(src)
    while i < n:
        if src.startswith("--", i):
            long_open = re.match(r"\[(=*)\[", src[i + 2:])
            if long_open:
                closer = "]" + long_open.group(1) + "]"
                start = i + 2 + long_open.end()
                end = src.find(closer, start)
                if end == -1:
                    return
                yield src[start:end]
                i = end + len(closer)
                continue
            newline = src.find("\n", i)
            i = newline + 1 if newline != -1 else n
            continue
        long_open = re.match(r"\[(=*)\[", src[i:])
        if long_open:
            closer = "]" + long_open.group(1) + "]"
            start = i + long_open.end()
            end = src.find(closer, start)
            if end == -1:
                return
            yield src[start:end]
            i = end + len(closer)
            continue
        if src[i] in "\"'":
            quote = src[i]
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 2
                    continue
                if src[j] == quote:
                    break
                j += 1
            yield src[i + 1:j]
            i = j + 1
            continue
        i += 1


def main():
    found = 0
    scanned = 0
    for path in sorted(pathlib.Path(".").rglob("*.lua")):
        src = path.read_text(encoding="utf-8")
        for literal in string_literals(src):
            if not SQL_KEYWORDS.search(literal):
                continue
            scanned += 1
            for match in re.finditer(r"--[^\n]*;", literal):
                found += 1
                print(f"{path}: SQL comment contains ';': {match.group(0).strip()[:90]!r}")
    print(f"scanned {scanned} SQL-looking literals in .lua files")
    if found:
        print(f"FAIL -- {found} comment(s) would split a statement under db:exec")
        return 1
    print("ok -- no semicolon inside any SQL comment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
