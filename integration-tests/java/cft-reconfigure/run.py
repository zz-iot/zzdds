#!/usr/bin/env python3
"""Runs the zzdds Java cft-reconfigure integration test: Publisher and
Subscriber as two separate JVM processes, communicating over real UDP DDS
discovery. Run build.py first.

Usage: ./run.py [-d domain_id]
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "examples"))
from _common import LiveProcess, java_cmd, require_path, run_env, zzdds_zig_out

SCRIPT_DIR = Path(__file__).resolve().parent
CLASSES_DIR = SCRIPT_DIR / "build" / "classes"

# Matches interop/cft_reconfigure_cross_binding_test.py's own PROC_TIMEOUT_S --
# shorter than the scenario's own internal deadline chain (match wait 40s +
# go-ahead wait 20s + drain wait 15s = 75s worst case) would let this script's
# own stop() kill an otherwise-valid run before its FAIL message could explain
# why, instead of the run failing on its own terms (found via Greptile review).
PROC_TIMEOUT_S = 100


def main() -> int:
    if not require_path(CLASSES_DIR, "Run build.py first."):
        return 1
    zig_out = zzdds_zig_out()
    env = run_env(zig_out)
    extra_args = sys.argv[1:]

    print("Starting subscriber...")
    subscriber = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Subscriber", *extra_args), env=env)
    time.sleep(1)

    print("Starting publisher...")
    publisher = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Publisher", *extra_args), env=env)

    publisher.wait(PROC_TIMEOUT_S)
    publisher_rc = publisher.stop()
    subscriber.wait(PROC_TIMEOUT_S)
    subscriber_rc = subscriber.stop()

    if publisher_rc != 0 or subscriber_rc != 0:
        print(f"FAIL: publisher rc={publisher_rc} subscriber rc={subscriber_rc}", file=sys.stderr)
        return 1
    print("OK: publisher and subscriber both exited successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
