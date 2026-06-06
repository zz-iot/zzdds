#!/usr/bin/env python3
"""Run the deterministic local test matrix.

This is a convenience wrapper around the checks that are useful before pushing:
formatting, sleep guardrails, Debug tests, feature-minimal tests, ReleaseSafe
tests, and fuzz harness compile-checks.  ThreadSanitizer is available as an
opt-in because it is slower and can be noisy on some local systems.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Step:
    name: str
    cmd: list[str]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--zig",
        default=os.environ.get("ZIG", "zig"),
        help="Zig executable to use. Defaults to $ZIG, then 'zig'.",
    )
    parser.add_argument(
        "--include-tsan",
        action="store_true",
        help="Also run zig build test-tsan.",
    )
    parser.add_argument(
        "--only",
        choices=("format", "sleeps", "debug", "feature-minimal", "release-safe", "fuzz", "tsan"),
        action="append",
        help="Run only the named step. May be passed more than once.",
    )
    return parser.parse_args()


def steps(zig: str, include_tsan: bool) -> list[Step]:
    all_steps = [
        Step("format", [zig, "fmt", "--check", "src/", "test/", "build.zig"]),
        Step("sleeps", [sys.executable, "scripts/check_test_sleeps.py"]),
        Step("debug", [zig, "build", "test"]),
        Step("feature-minimal", [zig, "build", "test", "-Dipv6=false", "-Dinterface-monitor=false"]),
        Step("release-safe", [zig, "build", "test", "-Doptimize=ReleaseSafe"]),
        Step("fuzz", [zig, "build", "test-fuzz"]),
    ]
    if include_tsan:
        all_steps.append(Step("tsan", [zig, "build", "test-tsan"]))
    return all_steps


def run_step(step: Step) -> int:
    print(f"\n==> {step.name}: {' '.join(step.cmd)}", flush=True)
    start = time.monotonic()
    proc = subprocess.run(step.cmd, cwd=ROOT)
    elapsed = time.monotonic() - start
    if proc.returncode == 0:
        print(f"==> {step.name}: PASS ({elapsed:.1f}s)", flush=True)
    else:
        print(f"==> {step.name}: FAIL rc={proc.returncode} ({elapsed:.1f}s)", flush=True)
    return proc.returncode


def main() -> int:
    args = parse_args()
    selected = steps(args.zig, args.include_tsan)
    if args.only:
        wanted = set(args.only)
        selected = [step for step in selected if step.name in wanted]
        missing = wanted - {step.name for step in selected}
        if missing:
            hint = ""
            if missing == {"tsan"}:
                hint = " (pass --include-tsan to enable the tsan step)"
            print(
                "Requested step(s) require additional flags: "
                + ", ".join(sorted(missing))
                + hint,
                file=sys.stderr,
            )
            return 2

    total_start = time.monotonic()
    for step in selected:
        rc = run_step(step)
        if rc != 0:
            return rc
    print(f"\nAll deterministic matrix steps passed ({time.monotonic() - total_start:.1f}s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
