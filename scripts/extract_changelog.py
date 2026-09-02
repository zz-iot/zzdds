#!/usr/bin/env python3
"""Print the slice of CHANGELOG.md that belongs in a release's notes.

`release.yml`'s publish job used to build its GitHub-release body from raw
`git log --pretty=%s` subjects between tags. Now that CHANGELOG.md is a curated,
section-headed log, the release notes quote *it* instead.

CHANGELOG.md is a sequence of `## <heading>` sections, newest first. The slice
for a release is "every section added since the previous release tag". Given
`--prev-ref <tag>`, this emits the leading run of sections whose heading is not
present in CHANGELOG.md as it stood at that tag. Comparing whole headings (not
dates) means a section dated the same day as the previous tag is still emitted
as long as its heading text is new.

If the previous tag predates CHANGELOG.md (or `--prev-ref` is omitted / not a
resolvable ref), it falls back to emitting the leading run of date-headed
sections (`## 2026-09-02`, or a range `## 2026-08-09 - 2026-08-10`), stopping at
the first heading with no date -- correct for the first release cut under the
dated-entry scheme.

Two releases on the *same calendar day* that both write under one `## <date>`
heading are not distinguishable here: the second finds its heading already
present and emits nothing, so the caller falls back to a git-log body for it
(fine for a same-day hotfix; the maintainer can hand-edit the release notes).
Splitting bullets out of a shared dated section by line was tried and dropped --
line-level diffing of prose fragments the entries.

Exit status:
  0  one or more sections printed
  1  nothing to emit (caller should fall back to a git-log body)
  2  bad usage / unreadable changelog
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")


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


def changelog_at_ref(ref: str, changelog: Path) -> str | None:
    """The contents of `changelog` as of git `ref`, or None if that ref /
    path pair does not resolve (e.g. the tag predates CHANGELOG.md)."""
    # `<rev>:./<path>` resolves the path relative to cwd, which is where the
    # workflow invokes this script (repo root).
    proc = subprocess.run(
        ["git", "show", f"{ref}:./{changelog.name}"],
        cwd=changelog.resolve().parent,
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    return proc.stdout if proc.returncode == 0 else None


def slice_by_prev_headings(sections: list[tuple[str, list[str]]], prev_text: str) -> list[str]:
    prev_headings = {h for h, _ in split_sections(prev_text)}
    out: list[str] = []
    for heading, body in sections:
        if heading in prev_headings:
            break
        out.append(heading)
        out.extend(body)
    return out


def slice_by_dated_run(sections: list[tuple[str, list[str]]]) -> list[str]:
    out: list[str] = []
    for heading, body in sections:
        if not DATE_RE.search(heading):
            break
        out.append(heading)
        out.extend(body)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    ap.add_argument("--prev-ref", default="",
                    help="git ref of the previous release tag; sections already present in "
                         "CHANGELOG.md at that ref are excluded. Omit / unresolvable => emit "
                         "the leading run of date-headed sections.")
    args = ap.parse_args()

    try:
        text = args.changelog.read_text()
    except OSError as e:
        print(f"extract_changelog: cannot read {args.changelog}: {e}", file=sys.stderr)
        return 2

    sections = split_sections(text)

    prev_text = changelog_at_ref(args.prev_ref, args.changelog) if args.prev_ref else None
    if prev_text is not None:
        out = slice_by_prev_headings(sections, prev_text)
    else:
        out = slice_by_dated_run(sections)

    while out and not out[-1].strip():
        out.pop()

    if not out:
        return 1

    print("\n".join(out))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
