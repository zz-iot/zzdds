#!/usr/bin/env python3
"""wait-for-historical-data cross-binding integration test: builds all four
wait-for-historical-data ports (zig, c, cpp, java), then runs a
representative subset of (subscriber, publisher) pairs over real UDP DDS
discovery -- the same 4-self + 4-cross-cycle subset
raw_loan_cross_binding_smoke_test.py uses.

Unlike a demonstration example (examples/*/catchup, which this scenario's
apps are directly modeled on), each pair here must clear a harder
correctness bar on wait_for_historical_data(): a negative case (a short,
non-zero max_wait called while genuinely no writer exists anywhere on the
domain must return RETCODE_TIMEOUT, not RETCODE_OK) followed by a positive
case (a generous max_wait must return RETCODE_OK only once the full
TRANSIENT_LOCAL historical batch has actually been delivered). See
docs/design/integration-test-tier.md for the full scenario spec and
c/wait-for-historical-data/src/subscriber.c for the assertions themselves --
this script's own checks below are a belt-and-suspenders check on the log
content, not a substitute.

The negative case is what makes process start *order* load-bearing here,
unlike every other scenario in this tier: the subscriber must start alone,
prove the negative case deterministically (no writer can possibly exist yet
since the publisher process hasn't started), and only then may the
publisher start. wait_for_marker() below enforces that ordering by polling
the subscriber's own log for its "ready for publisher" marker -- a real
signal, not a fixed sleep (see docs/design/integration-test-tier.md's
Assertion & timing conventions section) -- before launching the publisher.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./wait_for_historical_data_cross_binding_test.py
"""
from __future__ import annotations

import os
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "examples"))
from _common import (
    LiveProcess,
    java_cmd,
    print_fail,
    require_tool,
    run_build,
    run_env,
    zzdds_zig_out,
)

SUITE_ROOT = Path(__file__).resolve().parents[1]

# Dedicated domain, distinct from every examples/interop/*.py and
# integration-tests/interop/*.py smoke test's own domain (9-21 are taken --
# coherent-sets=18, delete-contained-entities=19, sample-rejected-lost=20,
# enable-defer=21).
DOMAIN = "22"
READY_MARKER = "Subscriber: ready for publisher."
# Generous margin over subscriber setup + the negative check's own 300ms
# wait -- this should trip in well under a second in practice.
READY_MARKER_TIMEOUT_S = 15
# Subscriber's own internal deadline chain: negative wait (0.3s) + positive
# wait_for_historical_data() (15s) + live-batch receive (30s). Publisher's:
# match wait (20s) + drain wait (15s). 60s gives comfortable margin over the
# worst case on either side.
PROC_TIMEOUT_S = 60

ZIG_DIR = SUITE_ROOT / "zig" / "wait-for-historical-data"
C_DIR = SUITE_ROOT / "c" / "wait-for-historical-data"
CPP_DIR = SUITE_ROOT / "cpp" / "wait-for-historical-data"
JAVA_DIR = SUITE_ROOT / "java" / "wait-for-historical-data"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language, plus a representative cross-binding cycle covering
# every language as both subscriber and publisher at least once -- mirrors
# raw_loan_cross_binding_smoke_test.py's PAIRS exactly.
PAIRS = [
    ("zig", "zig"),
    ("c", "c"),
    ("cpp", "cpp"),
    ("java", "java"),
    ("zig", "java"),
    ("java", "cpp"),
    ("cpp", "c"),
    ("c", "zig"),
]


def build_all(zig_out: Path) -> bool:
    print("== Building zig/wait-for-historical-data ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/wait-for-historical-data build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/wait-for-historical-data"), (CPP_DIR, "cpp/wait-for-historical-data")):
        print(f"== Building {name} ==")
        build_dir = dir_ / "build"
        if build_dir.exists():
            shutil.rmtree(build_dir)
        build_dir.mkdir(parents=True)
        log_path = build_dir / "cmake.log"
        if not run_build(["cmake", f"-DCMAKE_PREFIX_PATH={zig_out}", "-B", str(build_dir), "-S", str(dir_)], cwd=dir_, log_path=log_path):
            print(f"FAIL: {name} build -- see {log_path}", file=sys.stderr)
            return False
        if not run_build(["cmake", "--build", str(build_dir)], cwd=dir_, log_path=log_path):
            print(f"FAIL: {name} build -- see {log_path}", file=sys.stderr)
            return False

    print("== Building java/wait-for-historical-data ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/wait-for-historical-data build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "wait_for_historical_data_publisher",
        ZIG_DIR / "zig-out" / "bin" / "wait_for_historical_data_subscriber",
        C_DIR / "build" / "wait_for_historical_data_publisher",
        C_DIR / "build" / "wait_for_historical_data_subscriber",
        CPP_DIR / "build" / "wait_for_historical_data_publisher",
        CPP_DIR / "build" / "wait_for_historical_data_subscriber",
    ):
        if not bin_.is_file():
            print(f"FAIL: expected binary not found: {bin_}", file=sys.stderr)
            return False
    if not JAVA_CP.is_dir():
        print(f"FAIL: expected Java classes dir not found: {JAVA_CP}", file=sys.stderr)
        return False
    return True


def publisher_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "wait_for_historical_data_publisher")],
        "c": [str(C_DIR / "build" / "wait_for_historical_data_publisher")],
        "cpp": [str(CPP_DIR / "build" / "wait_for_historical_data_publisher")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def subscriber_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "wait_for_historical_data_subscriber")],
        "c": [str(C_DIR / "build" / "wait_for_historical_data_subscriber")],
        "cpp": [str(CPP_DIR / "build" / "wait_for_historical_data_subscriber")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def wait_for_marker(proc: LiveProcess, marker: str, timeout: float) -> bool:
    """Polls proc's own log for `marker` -- a real signal that a specific
    phase of the app has completed, not a fixed sleep. See the module
    docstring for why the subscriber's own "ready for publisher" marker is
    load-bearing for this scenario specifically."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if marker in proc.log_text():
            return True
        if proc.poll() is not None:
            return marker in proc.log_text()
        time.sleep(0.05)
    return marker in proc.log_text()


def run_pair(subscriber_lang: str, publisher_lang: str, zig_out: Path) -> bool:
    label = f"{subscriber_lang} subscriber <- {publisher_lang} publisher"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"wait-for-historical-data-{subscriber_lang}-{publisher_lang}"

    # Subscriber starts alone -- see the module docstring. The negative
    # case's whole point is that no writer exists anywhere on this domain
    # yet, which only holds if the publisher genuinely hasn't started.
    sub = LiveProcess(subscriber_cmd(subscriber_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")

    if not wait_for_marker(sub, READY_MARKER, READY_MARKER_TIMEOUT_S):
        sub_rc = sub.stop()
        print_fail(label, f"subscriber never printed its ready marker within {READY_MARKER_TIMEOUT_S}s (sub_rc={sub_rc})", ("subscriber", sub))
        return False

    pub = LiveProcess(publisher_cmd(publisher_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: negative check (no writer yet) correctly returned TIMEOUT." in sub.log_text()
    ok = ok and "Subscriber: wait_for_historical_data() returned" in sub.log_text()
    ok = ok and "HISTORICAL BATCH COMPLETE (8 samples)" in sub.log_text()
    ok = ok and "Subscriber: observed historical batch then live batch correctly." in sub.log_text()
    # All 4 live samples individually, not just the summary marker -- a
    # subscriber that (incorrectly) declared done after only some live
    # samples could otherwise slip through as a false pass.
    for i in range(8, 12):
        ok = ok and f"LIVE SAMPLE seq_num={i}" in sub.log_text()
    # Belt-and-suspenders: the apps' own internal assertions already exit
    # nonzero and print "FAIL: ..." the instant a violation is observed --
    # this just double-checks the log content itself never contains one, in
    # case a future change made the exit code mismatch the log content.
    ok = ok and "FAIL:" not in pub.log_text()
    ok = ok and "FAIL:" not in sub.log_text()

    if ok:
        print(f"OK: {label}")
        return True
    print_fail(label, f"pub_rc={pub_rc} sub_rc={sub_rc}", ("publisher", pub), ("subscriber", sub))
    return False


def main() -> int:
    for tool in ("zig", "cmake", "java"):
        if not require_tool(tool):
            return 1
    zig_out = zzdds_zig_out()

    if not build_all(zig_out):
        return 1

    failed = False
    for subscriber_lang, publisher_lang in PAIRS:
        if not run_pair(subscriber_lang, publisher_lang, zig_out):
            failed = True

    if failed:
        print("FAIL: wait-for-historical-data cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} wait-for-historical-data cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
