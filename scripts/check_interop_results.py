#!/usr/bin/env python3
"""Parse a dds-rtps JUnit XML report and exit non-zero if any test failed.

Usage:
    check_interop_results.py <report.xml> [--tsan-log-dir <dir>]
        [--known-failures <file.toml> --vendor <name> --direction pub|sub]

Failure output from each test (the pexpect-captured shape_main output, which
includes any ThreadSanitizer warnings when the binary is built with
sanitize_thread) is extracted from the JUnit XML and printed in full.

With --known-failures, a failing test listed there for this vendor and
direction is a known failure: reported, but not a failure of this check,
unless its output shows a sanitizer report or a crash. A listed test that
passes is reported too, so the entry can be removed. See
.github/interop-known-failures.toml for the format.

When run under GitHub Actions (GITHUB_ACTIONS=true):
  - Each failing test's detail is wrapped in a collapsible ::group:: section.
  - Failed test names are emitted as ::error:: annotations, known failures
    and listed tests that passed as ::warning:: annotations.
  - Any TSAN log files found in --tsan-log-dir are printed the same way.
  - A results table is appended to the job summary ($GITHUB_STEP_SUMMARY).
"""

import sys
import os
import re
import html as html_mod
import argparse
import tomllib
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


def gha_warning(msg):
    if IN_GHA:
        print(f"::warning::{msg}", flush=True)


def gha_summary(lines):
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if IN_GHA and path:
        with open(path, "a") as f:
            f.write("\n".join(lines) + "\n")


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
    """True if the failure is due to the vendor binary not implementing the
    tested feature (not a zzdds bug).

    The JUnit XML failure message contains an HTML table with a 'Code Produced'
    column.  strip_html() flattens it to tab-separated text, so the status
    codes appear as plain strings like SUB_UNSUPPORTED_FEATURE.  A test is a
    vendor limitation when any participant's code contains UNSUPPORTED_FEATURE;
    cascade failures (e.g. READER_NOT_MATCHED on publishers when the subscriber
    reports SUB_UNSUPPORTED_FEATURE) are also covered by this check."""
    if not detail:
        return False
    return bool(re.search(r'UNSUPPORTED_FEATURE', detail))


# Output that marks a failure as a sanitizer report or crash: never a known
# failure, whatever the list says (ThreadSanitizer, the DebugAllocator's leak
# and double-free reports, Zig panics, signals).
SANITIZER_OR_CRASH = re.compile(
    r'ThreadSanitizer|AddressSanitizer|error\(gpa\)|panic:|Segmentation fault|SIGSEGV|SIGABRT')


def test_name(case):
    """The dds-rtps test name (Test_<Group>_<N>) at the end of a case name."""
    m = re.search(r'(Test_\w+)$', case.name)
    return m.group(1) if m else case.name


def load_known_failures(path, vendor, direction):
    """Return {test name: reason} listed in `path` for this vendor (matched as
    a prefix of the CI vendor matrix name) and direction."""
    with open(path, "rb") as f:
        data = tomllib.load(f)
    known = {}
    for entry in data.get("known_failure", []):
        if entry["direction"] not in ("pub", "sub"):
            sys.exit(f"{path}: direction must be pub or sub, got {entry['direction']!r}")
        if vendor.startswith(entry["vendor"]) and entry["direction"] == direction:
            for name in entry["tests"]:
                known[name] = entry["reason"]
    return known


def check_junit(path, known):
    """Return (total, real_failures, known_failures, known_passed,
    vendor_skipped); known_passed holds test names, the rest TestCases."""
    xml = junitparser.JUnitXml.fromfile(path)
    total = 0
    real_failures = []
    known_failures = []
    vendor_skipped = []
    seen = []
    for suite in xml:
        for case in suite:
            total += 1
            name = test_name(case)
            seen.append(name)
            if case.result:
                detail = failure_detail(case)
                if is_vendor_limitation(detail):
                    vendor_skipped.append(case)
                elif name in known and not SANITIZER_OR_CRASH.search(detail or ""):
                    known_failures.append(case)
                else:
                    real_failures.append(case)
    failed = {test_name(c) for c in known_failures}
    known_passed = [n for n in seen if n in known and n not in failed]
    return total, real_failures, known_failures, known_passed, vendor_skipped


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
    ap.add_argument("--known-failures", metavar="FILE",
                    help="TOML list of known failures (needs --vendor and --direction)")
    ap.add_argument("--vendor", help="CI vendor matrix name (release asset name without _shape_main_linux.zip)")
    ap.add_argument("--direction", choices=("pub", "sub"),
                    help="pub: zzdds publishes; sub: zzdds subscribes")
    args = ap.parse_args()
    if args.known_failures and not (args.vendor and args.direction):
        ap.error("--known-failures needs --vendor and --direction")

    ok = True

    known = (load_known_failures(args.known_failures, args.vendor, args.direction)
             if args.known_failures else {})
    total, real_failures, known_failures, known_passed, vendor_skipped = \
        check_junit(args.report, known)
    passed = total - len(real_failures) - len(known_failures) - len(vendor_skipped)
    print(f"Interop results: {passed}/{total} passed"
          + (f", {len(known_failures)} known failures" if known_failures else "")
          + (f", {len(vendor_skipped)} vendor-skipped" if vendor_skipped else ""))

    if vendor_skipped:
        print("VENDOR LIMITATION (not a zzdds failure):")
        for case in vendor_skipped:
            print(f"  SKIP  {case.name}")

    if known_failures:
        print(f"KNOWN FAILURES (listed in {args.known_failures}; not a failure of this check):")
        for case in known_failures:
            name = test_name(case)
            print(f"  KNOWN {case.name}: {known[name]}")
            gha_warning(f"Known interop failure: {case.name}")

    if known_passed:
        print(f"LISTED AS KNOWN FAILURES BUT PASSED (remove from {args.known_failures} once reliable):")
        for name in known_passed:
            print(f"  PASS  {name}")
            gha_warning(f"{name} passed but is listed as a known failure")

    title = f"{args.vendor} / {args.direction}" if args.vendor else os.path.basename(args.report)
    summary = [f"### Interop: {title}", "",
               f"{passed}/{total} passed, {len(real_failures)} failed, "
               f"{len(known_failures)} known failures, {len(vendor_skipped)} vendor-skipped", ""]
    rows = ([("❌ failed", test_name(c)) for c in real_failures]
            + [("⚠️ known failure", test_name(c)) for c in known_failures]
            + [("ℹ️ listed as known, passed", n) for n in known_passed]
            + [("⏭️ vendor-skipped", test_name(c)) for c in vendor_skipped])
    if rows:
        summary += ["| Result | Test |", "|---|---|"] + [f"| {r} | {n} |" for r, n in rows]
    gha_summary(summary + [""])

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
