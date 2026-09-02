#!/usr/bin/env python3
"""Print the slice of CHANGELOG.md that belongs in a release's notes.

`release.yml`'s publish job used to build its GitHub-release body from raw
`git log --pretty=%s` subjects between tags. Now that CHANGELOG.md is a curated,
date-headed log, the release notes should quote *it* instead.

CHANGELOG.md is a sequence of `## <heading>` sections, newest first, each
heading starting with an ISO date (`## 2026-09-02`, or a range
`## 2026-08-09 - 2026-08-10` -- the first date wins). This script walks from the
top and prints every section whose date is strictly after `--since-date`
(the previous release's date), stopping at the first section that is not
(or whose heading carries no parseable date -- the pre-dated-scheme tail).

Exit status:
  0  one or more sections printed
  1  nothing matched (caller should fall back to a git-log body)
  2  bad usage / unreadable changelog
"""

from __future__ import annotations

import argparse
import datetime as dt
import re
import sys
from pathlib import Path


DATE_RE = re.compile(r"(\d{4})-(\d{2})-(\d{2})")


def parse_heading_date(heading: str) -> dt.date | None:
    m = DATE_RE.search(heading)
    if not m:
        return None
    try:
        return dt.date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        return None


def split_sections(text: str) -> list[tuple[str, list[str]]]:
    """-> [(heading_line, [body_line, ...]), ...] in file order. Anything
    before the first `## ` heading (the preamble) is dropped."""
    sections: list[tuple[str, list[str]]] = []
    cur_heading: str | None = None
    cur_body: list[str] = []
    for line in text.splitlines():
        if line.startswith("## "):
            if cur_heading is not None:
                sections.append((cur_heading, cur_body))
            cur_heading = line
            cur_body = []
        elif cur_heading is not None:
            cur_body.append(line)
    if cur_heading is not None:
        sections.append((cur_heading, cur_body))
    return sections


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    ap.add_argument("--since-date", required=True,
                    help="ISO date (YYYY-MM-DD) of the previous release; sections on or before it are excluded")
    args = ap.parse_args()

    try:
        since = dt.date.fromisoformat(args.since_date)
    except ValueError:
        print(f"extract_changelog: --since-date is not an ISO date: {args.since_date!r}", file=sys.stderr)
        return 2

    try:
        text = args.changelog.read_text()
    except OSError as e:
        print(f"extract_changelog: cannot read {args.changelog}: {e}", file=sys.stderr)
        return 2

    out: list[str] = []
    for heading, body in split_sections(text):
        date = parse_heading_date(heading)
        if date is None or date <= since:
            break
        out.append(heading)
        out.extend(body)

    while out and not out[-1].strip():
        out.pop()

    if not out:
        return 1

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
