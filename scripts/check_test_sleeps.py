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
    # Full UDP loopback tests use receive threads and real sockets. Third
    # sleep added with the same-participant self-matching regression test
    # (a real writer+reader on one participant, waiting for real SPDP/SEDP
    # discovery to complete before writing) -- same category as the other
    # two, not a new one.
    "test/dcps/loopback_test.zig": (3, "UDP loopback receive/discovery polling"),
    # Real UDP loopback WLP tests: polling for SEDP match completion, and
    # polling get_liveliness_changed_status while the real background
    # checkTimers() thread (real wall-clock, not ManualClock -- WLP's
    # periodic driver and the reader-side lease-expiry check both need a
    # real timer thread ticking to prove the wire mechanism actually works,
    # not just the local bookkeeping) drives WLP sends and lease expiry.
    "test/dcps/wlp_loopback_test.zig": (5, "UDP loopback WLP match/liveliness-status polling"),
    # MockTransport avoids sockets, but SPDP timer threads still announce on
    # intervals. 15th sleep added with the writer-discovered-before-reader
    # retroactive-match regression test (polling discovered_writers via real
    # SPDP/SEDP timer-thread announcements) -- same category as the rest.
    "test/dcps/mock_loopback_test.zig": (15, "SPDP timer-thread discovery polling"),
    # API and WaitSet tests intentionally wake waits from another thread.
    "test/dcps/api_test.zig": (1, "threaded WaitSet wakeup"),
    "test/dcps/waitset_test.zig": (1, "threaded WaitSet wakeup"),
    # TCP transport tests exercise real listener/connection threads.
    "test/transport/tcp_transport_test.zig": (1, "TCP listener thread startup"),
    # Regression test for deinit() reentrancy from the participant's own
    # background timer thread: needs the real timer thread to notice a real
    # DEADLINE expiry (ManualClock only ever advances from the calling test
    # thread, so it can't reach this path), polled with a bounded timeout.
    # Second sleep in the same test: a fixed post-completion delay giving
    # the detached timer thread (see deinit()'s self-reentrant/detach path)
    # real time to finish its own deferred alloc.destroy() before this test
    # function returns -- without it, that still-in-flight background
    # thread activity can race the next test (or this file's own final leak
    # check) on testing.allocator's shared state. See that sleep's own
    # comment for the full story (confirmed via repeated local Valgrind
    # reproduction, not just theory).
    "test/dcps/participant_vtable_test.zig": (2, "timer-thread self-delete polling + post-detach settle"),
    # Concurrent wait()-vs-attach/delete-entity/detach cycling test: a real
    # (if small) backoff, not a pure busy-spin, so its worker thread doesn't
    # hammer ws.mu at native CPU-bound frequency. Confirmed necessary, not
    # just nice-to-have -- under Valgrind (20-50x slower), the zero-backoff
    # version combined with 50 real DDS entity lifecycles blew through CI's
    # Valgrind job timeout without even finishing this one test.
    "test/dcps/waitset_lifecycle_test.zig": (1, "concurrent wait()-vs-entity-cycling backoff, avoids Valgrind CI timeout"),
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
