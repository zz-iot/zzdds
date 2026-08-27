#!/usr/bin/env python3
"""Runs the zzdds Java participant-config example: Subscriber and Publisher
as two separate JVM processes, communicating over real UDP DDS discovery.
Run without arguments, both sides default to "programmatic mode" (build a
DomainParticipantConfig value, round-trip it through
set_default_participant_config/get_default_participant_config, create the
participant via create_participant_ex). Pass --config to exercise file-based
config loading instead -- see README.md. Run build.py first.

Usage: ./run.py [-d domain_id] [--config path]
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from _common import LiveProcess, java_cmd, require_path, run_env, zzdds_zig_out

SCRIPT_DIR = Path(__file__).resolve().parent
CLASSES_DIR = SCRIPT_DIR / "build" / "classes"

# The publisher waits up to 10s for a reliable reader to become ready
# before it starts writing -- generous ceiling beyond that in case
# something hangs.
PROC_TIMEOUT_S = 40


def main() -> int:
    if not require_path(CLASSES_DIR, "Run build.py first."):
        return 1
    zig_out = zzdds_zig_out()
    env = run_env(zig_out)
    extra_args = sys.argv[1:]

    print("Starting subscriber...")
    sub = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Subscriber", *extra_args), env=env)
    time.sleep(1)

    print("Starting publisher...")
    pub = LiveProcess(java_cmd(zig_out, CLASSES_DIR, "Publisher", *extra_args), env=env)

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    if pub_rc != 0 or sub_rc != 0:
        print(f"FAIL: publisher rc={pub_rc} subscriber rc={sub_rc}", file=sys.stderr)
        return 1
    print("OK: publisher and subscriber both exited successfully.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
