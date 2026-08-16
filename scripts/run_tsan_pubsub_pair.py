#!/usr/bin/env python3
"""Run a ThreadSanitizer-instrumented publisher/subscriber pair and verify
both sides exited cleanly with their expected completion marker in their
combined stdout/stderr log.

Used by zzdds's ci.yml `examples-tsan` job. Shared here instead of
duplicated per CI step (~15-20 lines of bash each, one per example/language)
as the TSAN example matrix grows.

Python, not bash: this repo already hit a 40+ minute bash hang from a
similar background-subscriber / foreground-publisher-with-timeout pattern
(see the hello_world CI scripts migration in this repo's history) --
subprocess.run's own timeout plus an explicit kill on expiry avoids that
class of bug outright, rather than relying on bash's own `timeout`/`wait`
(which has no forceful-kill escalation of its own).

Usage:
  run_tsan_pubsub_pair.py \\
      --sub-cmd "zig-out/bin/waitset_sub -d 30" \\
      --pub-cmd "zig-out/bin/waitset_pub -d 30" \\
      --sub-log /tmp/sub.log --pub-log /tmp/pub.log \\
      --sub-marker "Subscriber: received all 10 samples." \\
      --pub-marker "Publisher: done."
"""

from __future__ import annotations

import argparse
import os
import platform
import shlex
import subprocess
import sys
from pathlib import Path


def disable_aslr(cmd: list[str]) -> list[str]:
    """Prepend `setarch <machine> -R` to disable ASLR for this one process.

    TSan reserves large, fixed chunks of virtual address space upfront for
    its shadow memory, assuming a layout from when Linux used much lower
    ASLR entropy. On GitHub-hosted ubuntu-latest runners specifically, the
    kernel's wider default ASLR range can occasionally place something where
    TSan's shadow memory needs to go, corrupting its own startup bookkeeping
    -- observed here as an instant SIGSEGV with no TSan report at all,
    stack-overflowing inside the runtime's own __cxa_atexit interceptor
    (confirmed via a CI-side gdb backtrace; never reproduced locally across
    dozens of runs, consistent with this being ASLR-placement-dependent
    rather than a real, deterministic bug). Lowering vm.mmap_rnd_bits alone
    was tried first and did not resolve it; setarch -R disables ASLR for
    this process outright rather than just narrowing its range, which is
    the more reliable fix for this exact failure mode.
    """
    return ["setarch", platform.machine(), "-R", *cmd]


def run_pair(
    sub_cmd: list[str],
    pub_cmd: list[str],
    sub_log: Path,
    pub_log: Path,
    sub_marker: str,
    pub_marker: str,
    startup_delay: float,
    timeout: float,
    env: dict[str, str],
) -> int:
    print(f"==> sub: {' '.join(sub_cmd)}", flush=True)
    with open(sub_log, "wb") as sub_out:
        sub_proc = subprocess.Popen(sub_cmd, stdout=sub_out, stderr=subprocess.STDOUT, env=env)

    try:
        import time

        time.sleep(startup_delay)

        print(f"==> pub: {' '.join(pub_cmd)}", flush=True)
        with open(pub_log, "wb") as pub_out:
            try:
                pub_rc = subprocess.run(
                    pub_cmd, stdout=pub_out, stderr=subprocess.STDOUT, env=env, timeout=timeout
                ).returncode
            except subprocess.TimeoutExpired:
                print(f"FAIL: publisher did not exit within {timeout}s", file=sys.stderr)
                pub_rc = 1

        try:
            sub_rc = sub_proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            print(
                f"FAIL: subscriber did not exit within {timeout}s after publisher finished -- killing",
                file=sys.stderr,
            )
            sub_proc.kill()
            sub_proc.wait(timeout=10)
            sub_rc = 1
    finally:
        # Belt-and-suspenders: never leave a subscriber process running past
        # this function, regardless of which branch above returned early.
        if sub_proc.poll() is None:
            sub_proc.kill()
            sub_proc.wait(timeout=10)

    sub_text = sub_log.read_text(errors="replace")
    pub_text = pub_log.read_text(errors="replace")
    print(pub_text)
    print(sub_text)

    ok = True
    if pub_rc != 0:
        print(f"FAIL: publisher exited {pub_rc}", file=sys.stderr)
        ok = False
    if sub_rc != 0:
        print(f"FAIL: subscriber exited {sub_rc}", file=sys.stderr)
        ok = False
    if pub_marker not in pub_text:
        print(f"FAIL: publisher log missing marker: {pub_marker!r}", file=sys.stderr)
        ok = False
    if sub_marker not in sub_text:
        print(f"FAIL: subscriber log missing marker: {sub_marker!r}", file=sys.stderr)
        ok = False
    return 0 if ok else 1


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sub-cmd", required=True, help="Subscriber command line, shell-quoted (e.g. 'bin/foo_sub -d 30')")
    p.add_argument("--pub-cmd", required=True, help="Publisher command line, shell-quoted (e.g. 'bin/foo_pub -d 30')")
    p.add_argument("--sub-log", required=True, type=Path)
    p.add_argument("--pub-log", required=True, type=Path)
    p.add_argument("--sub-marker", required=True, help="Substring that must appear in the subscriber's log on success")
    p.add_argument("--pub-marker", required=True, help="Substring that must appear in the publisher's log on success")
    p.add_argument("--startup-delay", type=float, default=1.0, help="Seconds to let the subscriber start before launching the publisher")
    p.add_argument("--timeout", type=float, default=40.0, help="Seconds to wait for each process before treating it as hung")
    p.add_argument("--ld-library-path", default=None, help="Prepended to LD_LIBRARY_PATH (for C/C++ binaries linking libzzdds.so)")
    return p.parse_args()


def main() -> int:
    args = parse_args()

    env = dict(os.environ)
    env.setdefault("TSAN_OPTIONS", "abort_on_error=1")
    if args.ld_library_path:
        existing = env.get("LD_LIBRARY_PATH", "")
        env["LD_LIBRARY_PATH"] = f"{args.ld_library_path}:{existing}" if existing else args.ld_library_path

    return run_pair(
        sub_cmd=disable_aslr(shlex.split(args.sub_cmd)),
        pub_cmd=disable_aslr(shlex.split(args.pub_cmd)),
        sub_log=args.sub_log,
        pub_log=args.pub_log,
        sub_marker=args.sub_marker,
        pub_marker=args.pub_marker,
        startup_delay=args.startup_delay,
        timeout=args.timeout,
        env=env,
    )


if __name__ == "__main__":
    sys.exit(main())
