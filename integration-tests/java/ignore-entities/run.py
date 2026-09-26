#!/usr/bin/env python3
"""Runs the zzdds Java ignore-entities integration test: Ignorer, Bystander,
and Peer as three separate JVM processes, communicating over real UDP DDS
discovery. Run build.py first.

Dev convenience script -- live-streams output rather than capturing it (see
LiveProcess's own doc comment), so it can't poll Ignorer's log markers the
way the real interop/ignore_entities_cross_binding_test.py does; generous
fixed delays stand in for that here. The THREE-PHASE order (ignorer, then
bystander alone, then peer) is load-bearing, not just a nicety -- see
ignore_entities_cross_binding_test.py's module docstring: starting peer
before ignorer has confirmed ignoring bystander makes
get_discovered_participants()'s handles[0] ambiguous between the two, and an
earlier version of this harness that started peer and bystander together hit
exactly that bug.

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

# Comfortably longer than cold-JVM startup plus ignorer's own topic/reader
# setup before it prints "ready for bystander".
IGNORER_HEAD_START_S = 5
# Comfortably longer than ignorer's own DISCOVER_BYSTANDER_TIMEOUT_MS (15s)
# plus bystander's own JVM startup -- gives ignorer time to discover and
# ignore bystander's participant before peer ever exists.
BYSTANDER_HEAD_START_S = 10
# Matches interop/ignore_entities_cross_binding_test.py's own PROC_TIMEOUT_S --
# ignorer's own internal deadline chain (DISCOVER_BYSTANDER_TIMEOUT_MS 15s +
# PROBE_MATCH_TIMEOUT_MS 45s, twice + settle/match/receive waits) plus the
# head starts above run well past 60s; a shorter timeout here would let this
# script's own stop() kill an otherwise-valid run before its FAIL message
# could explain why, instead of the run failing on its own terms (found via
# Greptile review).
PROC_TIMEOUT_S = 240


def main() -> int:
    if not require_path(CLASSES_DIR, "Run build.py first."):
        return 1
    zig_out = zzdds_zig_out()
    env = run_env(zig_out)
    extra_args = sys.argv[1:]

    print("Starting ignorer...")
    ignorer = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Ignorer", *extra_args), env=env)
    time.sleep(IGNORER_HEAD_START_S)

    print("Starting bystander...")
    bystander = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Bystander", *extra_args), env=env)
    time.sleep(BYSTANDER_HEAD_START_S)

    print("Starting peer...")
    peer = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Peer", *extra_args), env=env)

    ignorer.wait(PROC_TIMEOUT_S)
    ignorer_rc = ignorer.stop()
    peer.wait(PROC_TIMEOUT_S)
    peer_rc = peer.stop()
    bystander.wait(PROC_TIMEOUT_S)
    bystander_rc = bystander.stop()

    if ignorer_rc != 0 or peer_rc != 0 or bystander_rc != 0:
        print(f"FAIL: ignorer rc={ignorer_rc} peer rc={peer_rc} bystander rc={bystander_rc}", file=sys.stderr)
        return 1
    print("OK: ignorer, peer, and bystander all exited successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
