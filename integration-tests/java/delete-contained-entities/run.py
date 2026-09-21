#!/usr/bin/env python3
"""Runs the zzdds Java delete-contained-entities integration test: Peer and
Session as two separate JVM processes, communicating over real UDP DDS
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

PROC_TIMEOUT_S = 35


def main() -> int:
    if not require_path(CLASSES_DIR, "Run build.py first."):
        return 1
    zig_out = zzdds_zig_out()
    env = run_env(zig_out)
    extra_args = sys.argv[1:]

    print("Starting peer...")
    peer = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Peer", *extra_args), env=env)
    time.sleep(1)

    print("Starting session...")
    session = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Session", *extra_args), env=env)

    session.wait(PROC_TIMEOUT_S)
    session_rc = session.stop()
    peer.wait(PROC_TIMEOUT_S)
    peer_rc = peer.stop()

    if session_rc != 0 or peer_rc != 0:
        print(f"FAIL: session rc={session_rc} peer rc={peer_rc}", file=sys.stderr)
        return 1
    print("OK: session and peer both exited successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
