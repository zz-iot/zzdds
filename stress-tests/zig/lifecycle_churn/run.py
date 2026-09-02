#!/usr/bin/env python3
"""Build + run one lifecycle_churn scenario.

churn_stress is a single self-contained binary (DebugAllocator as the
allocator, so a leak/UAF fails at exit). This wrapper just builds it,
runs the requested --scenario with a wall-clock ceiling, and checks for a
`SUMMARY: OK` line and the absence of crash markers. `--tsan` rebuilds
zzdds + the binary with ThreadSanitizer first (the CI examples-tsan-style
lane).

Pass/fail: exit 0, one `SUMMARY: OK` line, no `FAIL:` / panic / sanitizer
report.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(APP_DIR.parents[2] / "examples"))
import _common  # noqa: E402

SCENARIOS = ["entities", "reentrant", "waitset", "listener", "cft", "participants", "instance"]
SUMMARY_RE = re.compile(r"^SUMMARY: OK scenario=(\w+) ops=(\d+)", re.M)
BAD = ("FAIL:", "panic", "Segmentation fault", "General protection",
       "ThreadSanitizer", "data race", "leaked")


def build(tsan: bool) -> Path:
    log = _common.mktemp_logdir("churn-stress") / "build.log"
    cmd = ["zig", "build"]
    if tsan:
        cmd.append("-Dsanitize-thread=true")
    if not _common.run_build(cmd, cwd=APP_DIR, log_path=log, timeout=900):
        print(Path(log).read_text(errors="replace"), file=sys.stderr)
        raise SystemExit("FAIL: churn_stress build failed")
    return APP_DIR / "zig-out" / "bin" / "churn_stress"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--scenario", required=True, choices=SCENARIOS)
    ap.add_argument("--threads", type=int, default=6)
    ap.add_argument("--iterations", type=int, default=40)
    ap.add_argument("--duration", type=int, default=8)
    ap.add_argument("--domain", type=int, default=71)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--timeout", type=int, default=90)
    ap.add_argument("--tsan", action="store_true")
    args = ap.parse_args()

    binary = build(args.tsan)
    cmd = [str(binary), "--scenario", args.scenario,
           "--threads", str(args.threads), "--iterations", str(args.iterations),
           "--duration", str(args.duration), "--domain", str(args.domain),
           "--seed", str(args.seed)]
    logdir = _common.mktemp_logdir("churn-stress-run")
    lp = _common.LiveProcess(cmd, log_path=logdir / f"{args.scenario}.log")
    rc = lp.stop(grace=10) if lp.wait(timeout=args.timeout) is None else lp.proc.returncode
    text = lp.log_text()

    problems = []
    if rc != 0:
        problems.append(f"exit {rc}")
    if not SUMMARY_RE.search(text):
        problems.append("no `SUMMARY: OK` line")
    for b in BAD:
        if b in text:
            problems.append(f"log contains {b!r}")
            break

    if problems:
        print(f"FAIL: {args.scenario}: {', '.join(problems)}", file=sys.stderr)
        print(f"Log: {logdir}/{args.scenario}.log", file=sys.stderr)
        return 1
    print(f"OK: churn_stress --scenario {args.scenario} (threads {args.threads})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
