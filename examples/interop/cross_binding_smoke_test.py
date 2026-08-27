#!/usr/bin/env python3
"""Cross-binding interoperability smoke test: builds c/custom-allocator and
cpp/custom-allocator, then runs each one's publisher against the OTHER
binding's subscriber (and vice versa) over real UDP DDS discovery. Both
examples compile the same idl/sensor.idl to the same wire (CDR) layout and
use the same domain ID (7) by construction -- this test is what actually
proves that in both directions, rather than each binding only ever being
exercised against itself.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./cross_binding_smoke_test.py
"""
from __future__ import annotations

import multiprocessing
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _common import (
    LiveProcess,
    REPO_ROOT,
    print_fail,
    require_tool,
    run_build,
    run_env,
    zzdds_zig_out,
)

C_DIR = REPO_ROOT / "c" / "custom-allocator"
CPP_DIR = REPO_ROOT / "cpp" / "custom-allocator"

# Both binaries run to completion on their own (write/read a fixed sample
# count then exit) -- no SIGINT/synchronization needed, just a generous
# ceiling in case something hangs.
PROC_TIMEOUT_S = 20


def build_one(dir_: Path, zig_out: Path) -> bool:
    name = dir_.relative_to(REPO_ROOT)
    print(f"== Building {name} ==")
    build_dir = dir_ / "build"
    if build_dir.exists():
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True)

    if not run_build(
        ["cmake", f"-DCMAKE_PREFIX_PATH={zig_out}", ".."],
        cwd=build_dir,
        log_path=build_dir / "cmake.log",
    ):
        print(f"FAIL: cmake configure failed for {name} -- see {build_dir}/cmake.log", file=sys.stderr)
        return False

    if not run_build(
        ["make", f"-j{multiprocessing.cpu_count()}"],
        cwd=build_dir,
        log_path=build_dir / "make.log",
    ):
        print(f"FAIL: build failed for {name} -- see {build_dir}/make.log", file=sys.stderr)
        return False
    return True


def run_pair(pub_dir: Path, sub_dir: Path, label: str, zig_out: Path) -> bool:
    print(f"== {label} ==")
    env = run_env(zig_out)

    # cwd matters here, not just for tidiness: each example's zzdds.toml
    # (CMake-copied next to the binary) is resolved relative to the
    # process's working directory, the same way the original bash version
    # relied on `cd "$dir/build"` before running.
    sub = LiveProcess(
        ["./subscriber"],
        cwd=sub_dir / "build",
        env=env,
        log_path=sub_dir / "build" / "sub.log",
    )
    time.sleep(1)
    pub = LiveProcess(
        ["./publisher"],
        cwd=pub_dir / "build",
        env=env,
        log_path=pub_dir / "build" / "pub.log",
    )

    # wait() gives it a chance to exit cleanly on its own; stop() is always
    # called afterward too -- a no-op if it already exited, a bounded
    # SIGINT-then-SIGKILL escalation if wait() timed out. Either way this
    # never blocks past PROC_TIMEOUT_S + stop()'s own grace period.
    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    if pub_rc == 0 and sub_rc == 0:
        print(f"OK: {label}")
        return True

    print_fail(label, f"pub_rc={pub_rc} sub_rc={sub_rc}", ("publisher", pub), ("subscriber", sub))
    return False


def main() -> int:
    if not require_tool("cmake"):
        return 1
    zig_out = zzdds_zig_out()

    if not build_one(C_DIR, zig_out):
        return 1
    if not build_one(CPP_DIR, zig_out):
        return 1

    ok = True
    ok &= run_pair(C_DIR, CPP_DIR, "C publisher -> C++ subscriber", zig_out)
    ok &= run_pair(CPP_DIR, C_DIR, "C++ publisher -> C subscriber", zig_out)

    if not ok:
        print("FAIL: cross-binding smoke test", file=sys.stderr)
        return 1
    print("OK: C and C++ custom-allocator examples interoperate in both directions.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
