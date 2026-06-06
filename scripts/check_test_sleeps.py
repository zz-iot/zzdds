#!/usr/bin/env python3
"""Reject wall-clock sleeps in deterministic tests.

Existing socket/full-stack tests have a small allowlist because they still depend
on real receive threads or SPDP timer ticks. New model/unit tests should not add
sleep loops; use MockTransport delivery rounds or ManualClock instead.
"""

from __future__ import annotations

import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]

ALLOWLIST = {
    "test/dcps/api_test.zig",
    "test/dcps/loopback_test.zig",
    "test/dcps/mock_loopback_test.zig",
    "test/dcps/waitset_test.zig",
    "test/transport/tcp_transport_test.zig",
}

PATTERNS = (
    "time_mod.sleepNs",
    "zzdds.util.time.sleepNs",
    "std.time.sleep",
    "std.Thread.sleep",
)


def main() -> int:
    offenders: list[str] = []
    for path in sorted((ROOT / "test").rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        if rel in ALLOWLIST:
            continue
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            if any(pattern in line for pattern in PATTERNS):
                offenders.append(f"{rel}:{lineno}: {line.strip()}")

    if offenders:
        print("Wall-clock sleep found in deterministic tests:", file=sys.stderr)
        for offender in offenders:
            print(f"  {offender}", file=sys.stderr)
        print(
            "\nUse ManualClock/MockTransport delivery, or add a narrowly justified allowlist entry.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
