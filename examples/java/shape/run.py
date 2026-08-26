#!/usr/bin/env python3
"""Runs the zzdds Java shape example: a subscriber and a publisher as two
separate JVM processes (java ShapeMain -S / -P), communicating over real
loopback UDP DDS discovery -- same two-process model as
java/listener-pubsub, using shape's -P/-S single-class CLI (see
zig/shape, c/shape, cpp/shape) instead of separate Publisher/Subscriber
classes. Run build.py first.

Then runs a --config smoke test (see below).
"""
from __future__ import annotations

import re
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from _common import LiveProcess, java_cmd, require_path, run_env, zzdds_zig_out

SCRIPT_DIR = Path(__file__).resolve().parent
CLASSES_DIR = SCRIPT_DIR / "build" / "classes"
PROC_TIMEOUT_S = 20

RECEIVED_RE = re.compile(r"^Square +[A-Z]+ +\d{3} \d{3} \[\d+\]", re.MULTILINE)


def port_is_bound(port: int) -> bool:
    """True if something on this machine has a UDP socket bound to `port`
    (any address) -- portable check, doesn't shell out to `ss`/`netstat`."""
    for family in (socket.AF_INET, socket.AF_INET6):
        try:
            with socket.socket(family, socket.SOCK_DGRAM) as s:
                s.bind(("", port) if family == socket.AF_INET else ("::", port))
        except OSError:
            return True  # bind failed -> something else already owns this port
    return False


def run_main_pubsub(zig_out: Path, env: dict) -> bool:
    print("Starting subscriber...")
    sub = LiveProcess(
        java_cmd(zig_out, CLASSES_DIR, "ShapeMain", "-S", "-i", "10", "--read-period", "200"),
        env=env,
        log_path=SCRIPT_DIR / "build" / "sub.log",
    )
    time.sleep(1)

    print("Starting publisher...")
    pub = LiveProcess(
        java_cmd(zig_out, CLASSES_DIR, "ShapeMain", "-P", "-i", "10", "-w", "--write-period", "200"),
        env=env,
    )

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    sub_log = sub.log_text()
    print(sub_log)

    if pub_rc != 0 or sub_rc != 0:
        print(f"FAIL: publisher rc={pub_rc} subscriber rc={sub_rc}", file=sys.stderr)
        return False

    # Real end-to-end proof, not just "both processes exited 0" -- at least
    # one actual sample line (e.g. "Square     BLUE       123 045 [20]")
    # must have reached the subscriber.
    if not RECEIVED_RE.search(sub_log):
        print("FAIL: subscriber never printed a received sample line", file=sys.stderr)
        return False

    print("OK: publisher and subscriber exchanged samples successfully.")
    return True


# ── --config smoke test ─────────────────────────────────────────────────────
#
# Java's --config is the MVP copy-trick (see ShapeMain.java's main(), and
# this port's README): copy the chosen file to ./zzdds.toml before the first
# factory is created, relying on zzdds's own ambient lazy-resolve to pick it
# up. Acceptance criterion from docs/design/shape-reference-app.md: Java's
# --config support needs at least one real test case, not just an unverified
# implementation -- this is that test. Checks the same externally observable
# effect zig/shape's README verifies: config/custom-ports.toml binds port
# 20010 instead of the default 7410.

CONFIG_PORT = 20010


def run_config_smoke_test(zig_out: Path, env: dict) -> bool:
    config_file = SCRIPT_DIR.parent.parent / "config" / "custom-ports.toml"
    if not require_path(config_file):
        return False

    print()
    print("Config-file smoke test (custom-ports.toml -> port 20010)...")

    # cwd=SCRIPT_DIR so the staged ./zzdds.toml (relative to cwd) lands next
    # to this run, not wherever run.py was invoked from -- ShapeMain.java's
    # own shutdown hook restores whatever was there before (or removes the
    # staged file) once the JVM exits, which our stop()'s SIGINT triggers.
    cfg = LiveProcess(
        java_cmd(zig_out, CLASSES_DIR, "ShapeMain", "-S", "--config", str(config_file), "-i", "10", "--read-period", "500"),
        cwd=SCRIPT_DIR,
        env=env,
        log_path=SCRIPT_DIR / "build" / "config-smoke.log",
    )

    bound = False
    for _ in range(5):
        time.sleep(1)
        if port_is_bound(CONFIG_PORT):
            bound = True
            break
    cfg.stop()

    if not bound:
        print(f"FAIL: no socket bound on port {CONFIG_PORT} -- --config's custom-ports.toml wasn't applied.", file=sys.stderr)
        print(cfg.log_text(), file=sys.stderr)
        return False

    print(f"OK: --config applied custom-ports.toml -- port {CONFIG_PORT} was bound (default is 7410).")
    return True


def main() -> int:
    if not require_path(CLASSES_DIR, "Run build.py first."):
        return 1
    zig_out = zzdds_zig_out()
    env = run_env(zig_out)

    if not run_main_pubsub(zig_out, env):
        return 1
    if not run_config_smoke_test(zig_out, env):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
