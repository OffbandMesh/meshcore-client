#!/usr/bin/env python3
"""Fail if an em-dash (U+2014) appears in source-authored text.

The em-dash reads as an AI tell, so it is kept out of the public repo (#457,
#462, #464). This guard runs in CI (the `analyze` job) and can also be wired
into a local pre-commit hook.

In scope:
  - lib/**/*.dart and test/**/*.dart  (code comments + string literals)
  - lib/l10n/app_en.arb               (English UI copy)

Out of scope (never flagged):
  - Generated files: *.g.dart, lib/l10n/app_localizations*.dart
  - Non-English ARB (lib/l10n/app_*.arb except app_en.arb): an em-dash may be
    legitimate target-language punctuation.
  - The lone "no data / not available" glyph placeholder: a dash that is the
    entire quoted value, e.g. `return '—';`, `"key": "—"`, `text: '—'`. That is
    a deliberate UI element, not prose.

Exit status: 0 when clean, 1 when any in-scope em-dash is found (each printed
as file:line: <content>).
"""

from __future__ import annotations

import os
import sys

EM_DASH = "—"
ROOTS = ("lib", "test")


def _has_prose_emdash(line: str) -> bool:
    """True if the line has an em-dash that is NOT a lone glyph placeholder.

    The lone "no data" glyph is a dash that is the entire quoted value (`'—'`
    or `"—"`). Strip those tokens first, so a line carrying both a glyph and a
    real prose em-dash is still flagged.
    """
    stripped = line.replace("'" + EM_DASH + "'", "").replace('"' + EM_DASH + '"', "")
    return EM_DASH in stripped


def _in_scope(path: str) -> bool:
    base = os.path.basename(path)
    if base.endswith(".g.dart") or base.startswith("app_localizations"):
        return False
    if base.endswith(".dart"):
        return True
    # ARB: only the English source is in scope.
    return base == "app_en.arb"


def find_violations(roots=ROOTS):
    hits = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for dirpath, _dirs, filenames in os.walk(root):
            for name in filenames:
                if not (name.endswith(".dart") or name.endswith(".arb")):
                    continue
                path = os.path.join(dirpath, name)
                if not _in_scope(path):
                    continue
                with open(path, encoding="utf-8") as fh:
                    for lineno, line in enumerate(fh, 1):
                        if _has_prose_emdash(line):
                            hits.append((path.replace(os.sep, "/"), lineno, line.rstrip()))
    return hits


def main() -> int:
    roots = tuple(sys.argv[1:]) or ROOTS
    hits = find_violations(roots)
    if not hits:
        print("check_no_emdash: OK (no em-dash characters in source)")
        return 0
    print(
        "check_no_emdash: found the em-dash character (U+2014) in source. "
        "Replace it with a comma, colon, or period (see #464):",
        file=sys.stderr,
    )
    for path, lineno, content in hits:
        print(f"  {path}:{lineno}: {content}", file=sys.stderr)
    print(f"\n{len(hits)} em-dash(es) found.", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
