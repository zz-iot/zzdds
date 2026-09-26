#!/usr/bin/env python3
"""liveliness-lost cross-binding integration test: builds all four
liveliness-lost ports (zig, c, cpp, java), then runs a representative
subset of (subscriber, publisher) pairs over real UDP DDS discovery -- the
same 4-self + 4-cross-cycle subset raw_loan_cross_binding_smoke_test.py
uses.

Exercises on_liveliness_lost()/get_liveliness_lost_status() -- "zero
coverage anywhere" per the API audit -- for the two LIVELINESS kinds
`presence` (examples/{c,cpp,java,zig}/presence) deliberately left out to
keep itself a single-scenario example: AUTOMATIC and MANUAL_BY_PARTICIPANT.
`presence` already covers MANUAL_BY_TOPIC, `assert_liveliness()`, and
`on_liveliness_changed`'s full ONLINE->OFFLINE->ONLINE recovery cycle; this
scenario is a one-way lapse (no recovery) targeting a sharper, more
spec-precise question: *what counts* as a liveliness assertion differs by
kind, and it's easy to get backwards. Both writers write continuously at
the same cadence for the whole run, never calling assert_liveliness() --
AUTOMATIC's own write()s should keep it alive forever; MANUAL_BY_PARTICIPANT
should lose liveliness anyway, despite writing the entire time, since write()
does not count as an assertion for that kind. See
docs/design/integration-test-tier.md for the full scenario spec and
c/liveliness-lost/src/subscriber.c for the assertions themselves -- this
script's own checks below are a belt-and-suspenders check on the log
content, not a substitute.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./liveliness_lost_cross_binding_test.py
"""
from __future__ import annotations

import os
import shutil
import sys
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
# integration-tests/interop/*.py smoke test's own domain (9-25 are taken --
# coherent-sets=18, delete-contained-entities=19, sample-rejected-lost=20,
# enable-defer=21, wait-for-historical-data=22, ignore-entities=23,
# cft-reconfigure=24, source-timestamp=25).
DOMAIN = "26"
# Publisher's own internal deadline chain: match wait (40s, see
# publisher.c's MATCH_TIMEOUT_MS comment) + write loop (~8s) + drain wait
# (15s) = ~63s. Subscriber's: match wait (40s) + observe window (12s) =
# ~52s. 90s gives comfortable margin over either worst-case sum.
PROC_TIMEOUT_S = 90

ZIG_DIR = SUITE_ROOT / "zig" / "liveliness-lost"
C_DIR = SUITE_ROOT / "c" / "liveliness-lost"
CPP_DIR = SUITE_ROOT / "cpp" / "liveliness-lost"
JAVA_DIR = SUITE_ROOT / "java" / "liveliness-lost"
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
    print("== Building zig/liveliness-lost ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/liveliness-lost build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/liveliness-lost"), (CPP_DIR, "cpp/liveliness-lost")):
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

    print("== Building java/liveliness-lost ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/liveliness-lost build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "liveliness_lost_publisher",
        ZIG_DIR / "zig-out" / "bin" / "liveliness_lost_subscriber",
        C_DIR / "build" / "liveliness_lost_publisher",
        C_DIR / "build" / "liveliness_lost_subscriber",
        CPP_DIR / "build" / "liveliness_lost_publisher",
        CPP_DIR / "build" / "liveliness_lost_subscriber",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "liveliness_lost_publisher")],
        "c": [str(C_DIR / "build" / "liveliness_lost_publisher")],
        "cpp": [str(CPP_DIR / "build" / "liveliness_lost_publisher")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def subscriber_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "liveliness_lost_subscriber")],
        "c": [str(C_DIR / "build" / "liveliness_lost_subscriber")],
        "cpp": [str(CPP_DIR / "build" / "liveliness_lost_subscriber")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(subscriber_lang: str, publisher_lang: str, zig_out: Path) -> bool:
    label = f"{subscriber_lang} subscriber <- {publisher_lang} publisher"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"liveliness-lost-{subscriber_lang}-{publisher_lang}"

    sub = LiveProcess(subscriber_cmd(subscriber_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    pub = LiveProcess(publisher_cmd(publisher_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as expected." in pub.log_text()
    ok = ok and "Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness" in pub.log_text()
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: AUTOMATIC reader never observed NOT_ALIVE, as expected." in sub.log_text()
    ok = ok and "Subscriber: MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as expected." in sub.log_text()
    ok = ok and "Subscriber: done." in sub.log_text()
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
        print("FAIL: liveliness-lost cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} liveliness-lost cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
