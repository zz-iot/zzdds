#!/usr/bin/env python3
"""CI-friendly smoke test: builds video_capture/video_roi_display, then runs
them against each other with no real camera and no display -- video_capture
falls back to a synthetic mock frame source (OVIDDS_MOCK_CAMERA=1) and
video_roi_display runs text-only (OVIDDS_HEADLESS=1), both bounded by
OVIDDS_RUN_SECONDS instead of waiting on stdin/a keypress. Confirms the
full DDS write/fragment/reassemble/read path works end to end without
hardware, not just that the binaries compile.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./smoke_test.py
"""
from __future__ import annotations

import multiprocessing
import re
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from _common import LiveProcess, run_build, run_env, zzdds_zig_out

SCRIPT_DIR = Path(__file__).resolve().parent
BUILD_DIR = SCRIPT_DIR / "build"
PROC_TIMEOUT_S = 15

FRAMES_RE = re.compile(r"received (\d+) frames total")


def main() -> int:
    zig_out = zzdds_zig_out()

    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)
    BUILD_DIR.mkdir(parents=True)
    if not run_build(
        ["cmake", f"-DCMAKE_PREFIX_PATH={zig_out}", ".."], cwd=BUILD_DIR, log_path=BUILD_DIR / "cmake.log"
    ):
        print(f"FAIL: cmake configure failed -- see {BUILD_DIR}/cmake.log", file=sys.stderr)
        return 1
    if not run_build(
        ["make", f"-j{multiprocessing.cpu_count()}"], cwd=BUILD_DIR, log_path=BUILD_DIR / "make.log"
    ):
        print(f"FAIL: build failed -- see {BUILD_DIR}/make.log", file=sys.stderr)
        return 1

    env = run_env(zig_out)
    env.pop("DISPLAY", None)

    sub_env = dict(env, OVIDDS_HEADLESS="1", OVIDDS_RUN_SECONDS="10")
    sub = LiveProcess(["./video_roi_display"], cwd=BUILD_DIR, env=sub_env, log_path=BUILD_DIR / "sub.log")
    time.sleep(1)

    pub_env = dict(env, OVIDDS_MOCK_CAMERA="1", OVIDDS_RUN_SECONDS="8")
    pub = LiveProcess(["./video_capture"], cwd=BUILD_DIR, env=pub_env, log_path=BUILD_DIR / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    sub_log = sub.log_text()
    match = FRAMES_RE.search(sub_log)
    frames_received = int(match.group(1)) if match else 0

    if pub_rc != 0 or sub_rc != 0 or frames_received == 0:
        print(f"FAIL: smoke test (pub_rc={pub_rc} sub_rc={sub_rc} frames_received={frames_received})", file=sys.stderr)
        print("-- publisher log --", file=sys.stderr)
        print(pub.log_text(), file=sys.stderr)
        print("-- subscriber log --", file=sys.stderr)
        print(sub_log, file=sys.stderr)
        return 1

    print(f"OK: opencv_zzdds smoke test passed, {frames_received} frames received headless with a mock camera.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
