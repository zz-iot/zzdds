#!/usr/bin/env python3
"""Reject wall-clock sleeps in deterministic tests.

Existing socket/full-stack tests have a small audited allowlist because they still
depend on real receive threads or SPDP timer ticks. New model/unit tests should
not add sleep loops; use MockTransport delivery rounds or ManualClock instead.
"""

from __future__ import annotations

import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]

ALLOWLIST = {
    # Full UDP loopback tests use receive threads and real sockets.
    "test/dcps/loopback_test.zig": (2, "UDP loopback receive/discovery polling"),
    # MockTransport avoids sockets, but SPDP timer threads still announce on intervals.
    "test/dcps/mock_loopback_test.zig": (13, "SPDP timer-thread discovery polling"),
    # API and WaitSet tests intentionally wake waits from another thread.
    "test/dcps/api_test.zig": (1, "threaded WaitSet wakeup"),
    "test/dcps/waitset_test.zig": (1, "threaded WaitSet wakeup"),
    # TCP transport tests exercise real listener/connection threads.
    "test/transport/tcp_transport_test.zig": (1, "TCP listener thread startup"),
}

PATTERNS = (
    "time_mod.sleepNs",
    "zzdds.util.time.sleepNs",
    "std.time.sleep",
    "std.Thread.sleep",
)


def code_before_line_comment(line: str) -> str:
    return line.split("//", 1)[0]


def main() -> int:
    offenders: list[str] = []
    allowed_counts = {rel: 0 for rel in ALLOWLIST}
    for path in sorted((ROOT / "test").rglob("*.zig")):
        rel = path.relative_to(ROOT).as_posix()
        for lineno, line in enumerate(path.read_text().splitlines(), 1):
            code = code_before_line_comment(line)
            if any(pattern in code for pattern in PATTERNS):
                if rel in ALLOWLIST:
                    allowed_counts[rel] += 1
                else:
                    offenders.append(f"{rel}:{lineno}: {line.strip()}")

    for rel, (expected, reason) in ALLOWLIST.items():
        got = allowed_counts[rel]
        if got != expected:
            offenders.append(
                f"{rel}: expected {expected} audited sleep(s), found {got} ({reason})"
            )

    if offenders:
        print("Wall-clock sleep found in deterministic tests:", file=sys.stderr)
        for offender in offenders:
            print(f"  {offender}", file=sys.stderr)
        print(
            "\nUse ManualClock/MockTransport delivery, or update the audited allowlist count with a rationale.",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
