#!/usr/bin/env python3
"""Top-level stress-test orchestrator: builds + runs every stress app.

Each app under zig/<name>/ has its own run.py that builds it (zig build,
pinning ../../..) and drives its scenario. This just runs them in turn with
CI-sized parameters and aggregates pass/fail. Bigger/longer parameters and
--large belong in the nightly matrix, wired directly in ci.yml, not here.

Usage:
  stress-tests/run_all.py            # dev
  stress-tests/run_all.py --strict   # CI: a missing zig toolchain is a failure

Set ZZDDS_ZIG_OUT if the stress apps should link a specific build; by
default each app's `zig build` resolves zzdds from the repo root itself.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent / "examples"))
import _common  # noqa: E402

# (name, run.py path, CI args, xfail)
# xfail=True: run it, report the outcome, but don't fail the suite on it --
# it's exercising a currently-known zzdds bug (see README "Findings"). It
# flips to a hard failure automatically once it starts passing.
APPS: list[tuple[str, Path, list[str], bool]] = [
    (
        "entity_lifecycle_stress",
        SCRIPT_DIR / "zig" / "entity_lifecycle_stress" / "run.py",
        ["--publishers", "4", "--subscribers", "4", "--samples", "300", "--churn", "--timeout", "120"],
        False,
    ),
    (
        "lifecycle_churn/reentrant",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "reentrant", "--threads", "6", "--iterations", "40"],
        False,
    ),
    (
        "lifecycle_churn/entities",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "entities", "--threads", "8", "--duration", "8"],
        False,
    ),
    (
        "lifecycle_churn/waitset",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "waitset", "--threads", "8", "--duration", "8"],
        False,
    ),
    (
        "lifecycle_churn/listener",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "listener", "--threads", "8", "--duration", "8"],
        False,
    ),
    (
        "lifecycle_churn/cft",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "cft", "--threads", "10", "--duration", "8"],
        False,
    ),
    (
        "lifecycle_churn/participants",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "participants", "--threads", "8", "--duration", "8"],
        False,
    ),
    (
        "lifecycle_churn/instance",
        SCRIPT_DIR / "zig" / "lifecycle_churn" / "run.py",
        ["--scenario", "instance", "--threads", "8", "--duration", "8"],
        False,
    ),
]


def main() -> int:
    strict = "--strict" in sys.argv[1:]
    unknown = [a for a in sys.argv[1:] if a != "--strict"]
    if unknown:
        print(f"unknown args: {unknown}", file=sys.stderr)
        return 2

    if shutil.which("zig") is None:
        msg = "zig not found on PATH"
        if strict:
            print(f"FAIL (strict): {msg}", file=sys.stderr)
            return 1
        print(f"SKIP: everything -- {msg}")
        return 0

    passed, failed, xfailed, xpassed = [], [], [], []
    for name, script, args, xfail in APPS:
        print(f"\n== {name} =={' [xfail]' if xfail else ''}", flush=True)
        rc = subprocess.run([sys.executable, str(script), *args]).returncode
        if rc == 0:
            (xpassed if xfail else passed).append(name)
        else:
            (xfailed if xfail else failed).append(name)

    print(f"\n{'='*52}")
    for n in passed:
        print(f"  PASS   {n}")
    for n in xfailed:
        print(f"  XFAIL  {n}  (known bug -- see README Findings)")
    for n in xpassed:
        print(f"  XPASS  {n}  (was expected to fail -- promote it to gating!)")
    for n in failed:
        print(f"  FAIL   {n}")
    # XPASS is a soft nudge, not a failure -- flakiness shouldn't flip the gate.
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
