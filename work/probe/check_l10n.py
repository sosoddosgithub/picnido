#!/usr/bin/env python3
r"""Checks the translation tables are sound, without launching the app.

Three things go wrong quietly in a `.strings` file, and all three look identical from the
outside — the row stays English:

  * a key is spelled differently from what SwiftUI derives, so the lookup misses;
  * a table is missing an entry the other two have, so one language is half translated;
  * a key or a value carries a stray `%`, which `String(format:)` then eats.

The first cannot be checked here — only the app knows what key it asks for. The other two can,
and this also prints the format specifier census so a missing `%lld` is visible before it
becomes a silent English row.

    check_l10n.py [Resources-dir]

Exit code is non-zero when a table fails to parse or the key sets disagree.
"""
import re
import sys
from pathlib import Path

LANGS = ["zh-Hans", "ja", "ko"]
ENTRY = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;', re.M)
# `%` followed by anything that is not a specifier we actually use.
SPEC = re.compile(r'%(?:\d+\$)?[-+ #0]*[\d.]*(?:lld|ld|d|lf|f|@|%)')


def strip_comments(text: str) -> str:
    """Drop `/* ... */` and `// ...`.

    Only the quoted key/value text reaches the parser, so a comment is free to quote a Swift
    interpolation — and ours do, since they explain how SwiftUI derives a key from one. Testing
    the raw file for that sequence reports those comments as corruption.
    """
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def parse(path: Path):
    raw = path.read_text()
    text = strip_comments(raw)
    entries, dup = {}, []
    for m in ENTRY.finditer(text):
        if m.group(1) in entries:
            dup.append(m.group(1))
        entries[m.group(1)] = m.group(2)
    return entries, dup, text


def offenders(field: str, value: str):
    """`%` occurrences that are not one of the specifiers we use."""
    stripped = SPEC.sub("", value)
    return [field] if "%" in stripped else []


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "Resources")
    tables, bad = {}, False

    for lang in LANGS:
        path = root / f"{lang}.lproj" / "Localizable.strings"
        if not path.exists():
            print(f"missing {path}")
            return 1
        entries, dup, text = parse(path)
        tables[lang] = entries
        problems = []
        if dup:
            problems.append(f"duplicate keys: {sorted(set(dup))}")
        if "\\(" in text:
            problems.append("contains an escaped parenthesis `\\(`, which invalidates the table")
        for key, value in entries.items():
            problems += offenders(f"key {key!r}", key)
            problems += offenders(f"value of {key!r}", value)
        spec = sorted({s for s in SPEC.findall(" ".join(entries)) if s != "%%"})
        print(f"{lang:<8} {len(entries):>4} entries  specifiers: {' '.join(spec) or '-'}")
        for p in problems:
            print(f"         !! {p}")
            bad = True

    base = set(tables[LANGS[0]])
    for lang in LANGS[1:]:
        only_here = sorted(set(tables[lang]) - base)
        only_base = sorted(base - set(tables[lang]))
        if only_here or only_base:
            bad = True
            print(f"\n{lang} vs {LANGS[0]}:")
            for k in only_base:
                print(f"  only in {LANGS[0]}: {k}")
            for k in only_here:
                print(f"  only in {lang}: {k}")

    print("\nOK" if not bad else "\nFAILED")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
