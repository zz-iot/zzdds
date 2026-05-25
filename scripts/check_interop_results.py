#!/usr/bin/env python3
"""Parse a dds-rtps JUnit XML report and exit non-zero if any test failed.

Usage:
    check_interop_results.py <report.xml> [--tsan-log-dir <dir>]

Failure output from each test (the pexpect-captured shape_main output, which
includes any ThreadSanitizer warnings when the binary is built with
sanitize_thread) is extracted from the JUnit XML and printed in full.

When run under GitHub Actions (GITHUB_ACTIONS=true):
  - Each failing test's detail is wrapped in a collapsible ::group:: section.
  - Failed test names are emitted as ::error:: annotations.
  - Any TSAN log files found in --tsan-log-dir are printed the same way.
"""

import sys
import os
import re
import html as html_mod
import argparse
import junitparser

IN_GHA = os.environ.get("GITHUB_ACTIONS") == "true"


def gha_group(title):
    if IN_GHA:
        print(f"::group::{title}", flush=True)


def gha_endgroup():
    if IN_GHA:
        print("::endgroup::", flush=True)


def gha_error(msg):
    if IN_GHA:
        print(f"::error::{msg}", flush=True)


def strip_html(text):
    """Convert the harness's HTML failure message to readable plain text."""
    # <br> → newline
    text = re.sub(r'<br\s*/?>', '\n', text, flags=re.IGNORECASE)
    # table rows → newlines, cells → tabs
    text = re.sub(r'</tr>', '\n', text, flags=re.IGNORECASE)
    text = re.sub(r'</?t[rdh][^>]*>', '\t', text, flags=re.IGNORECASE)
    # strip all remaining tags
    text = re.sub(r'<[^>]+>', '', text)
    # decode HTML entities (&lt; etc.)
    text = html_mod.unescape(text)
    # collapse runs of blank lines
    text = re.sub(r'\n[ \t]*\n[ \t]*\n', '\n\n', text)
    return text.strip()


def failure_detail(case):
    """Return plain-text failure output for a test case, or None."""
    results = case.result
    if not results:
        return None
    if not isinstance(results, list):
        results = [results]
    parts = []
    for r in results:
        # junitparser stores the message in .message; full text in .text
        content = getattr(r, 'text', None) or getattr(r, 'message', None) or ''
        if content:
            parts.append(strip_html(content))
    return '\n'.join(parts) if parts else None


def is_vendor_limitation(detail):
    """True if every non-OK 'Code found:' in the failure detail is an
    UNSUPPORTED_FEATURE variant — meaning the vendor binary does not
    implement the tested feature, not a zzdds bug."""
    if not detail:
        return False
    found_codes = re.findall(r'Code found:\s*(\S+)', detail)
    non_ok = [c for c in found_codes if c != 'OK']
    return bool(non_ok) and all('UNSUPPORTED_FEATURE' in c for c in non_ok)


def check_junit(path):
    """Return (total, real_failures, vendor_skipped) as lists of TestCase."""
    xml = junitparser.JUnitXml.fromfile(path)
    total = 0
    real_failures = []
    vendor_skipped = []
    for suite in xml:
        for case in suite:
            total += 1
            if case.result:
                detail = failure_detail(case)
                if is_vendor_limitation(detail):
                    vendor_skipped.append(case)
                else:
                    real_failures.append(case)
    return total, real_failures, vendor_skipped


def print_tsan_logs(log_dir):
    """Print full contents of non-empty TSAN log files; return list of filenames."""
    hits = []
    if not os.path.isdir(log_dir):
        return hits
    for name in sorted(os.listdir(log_dir)):
        p = os.path.join(log_dir, name)
        if not (os.path.isfile(p) and os.path.getsize(p) > 0):
            continue
        hits.append(name)
        gha_group(f"ThreadSanitizer report: {name}")
        with open(p) as f:
            print(f.read(), end="", flush=True)
        gha_endgroup()
    return hits


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("report", help="JUnit XML report file")
    ap.add_argument("--tsan-log-dir", metavar="DIR",
                    help="directory of TSAN log files (for log_path= style capture)")
    args = ap.parse_args()

    ok = True

    total, real_failures, vendor_skipped = check_junit(args.report)
    passed = total - len(real_failures) - len(vendor_skipped)
    print(f"Interop results: {passed}/{total} passed"
          + (f", {len(vendor_skipped)} vendor-skipped" if vendor_skipped else ""))

    if vendor_skipped:
        print("VENDOR LIMITATION (not a zzdds failure):")
        for case in vendor_skipped:
            print(f"  SKIP  {case.name}")

    if real_failures:
        ok = False
        print("FAILURES:")
        for case in real_failures:
            print(f"  FAIL  {case.name}")
            gha_error(f"Interop test failed: {case.name}")

        # One collapsible group per failing test containing the full captured
        # shape_main output (includes ThreadSanitizer warnings if present).
        for case in real_failures:
            detail = failure_detail(case)
            if detail:
                gha_group(f"Output: {case.name}")
                print(detail, flush=True)
                gha_endgroup()

    # Secondary: explicit TSAN log files (used when TSAN_OPTIONS includes
    # log_path=... so reports go to files rather than stderr/pexpect capture).
    if args.tsan_log_dir:
        tsan_hits = print_tsan_logs(args.tsan_log_dir)
        if tsan_hits:
            ok = False
            gha_error(f"ThreadSanitizer detected races in {len(tsan_hits)} report(s) — see groups above")

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
