#!/usr/bin/env python3
"""Runs every Java example under this directory (build_all.py first). Stops
and reports at the first example whose run.py exits non-zero, but still
runs every example rather than aborting the whole script early, so a CI
log shows every failure in one pass instead of just the first.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run_all.py
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def main() -> int:
    failed = []
    for example_dir in sorted(SCRIPT_DIR.iterdir()):
        run_script = example_dir / "run.py"
        if not run_script.is_file():
            continue
        name = example_dir.name
        print(f"== Running {name} ==")
        rc = subprocess.run([sys.executable, str(run_script)]).returncode
        if rc != 0:
            failed.append(name)

    if failed:
        print(f"FAIL: {' '.join(failed)}", file=sys.stderr)
        return 1
    print("OK: all Java examples passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
