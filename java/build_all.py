#!/usr/bin/env python3
"""Builds every Java example under this directory (each is its own
build.py/run.py pair, matching the c/ and cpp/ examples' one-per-example
build unit -- see this repo's top-level README for why).

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build_all.py
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def main() -> int:
    for example_dir in sorted(SCRIPT_DIR.iterdir()):
        build_script = example_dir / "build.py"
        if not build_script.is_file():
            continue
        print(f"== Building {example_dir.name} ==")
        rc = subprocess.run([sys.executable, str(build_script)]).returncode
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
