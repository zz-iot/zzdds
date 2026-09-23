#!/usr/bin/env python3
"""source-timestamp cross-binding integration test: builds all four
source-timestamp ports (zig, c, cpp, java), then runs a representative
subset of (subscriber, publisher) pairs over real UDP DDS discovery -- the
same 4-self + 4-cross-cycle subset raw_loan_cross_binding_smoke_test.py
uses.

Verifies that write_w_timestamp()/dispose_w_timestamp()'s explicit,
caller-supplied timestamps genuinely propagate end-to-end to
SampleInfo.source_timestamp on the receiving side -- not silently replaced
with "now" at send or receive time. See docs/design/integration-test-tier.md
for the full scenario spec and c/source-timestamp/src/subscriber.c for the
assertions themselves -- this script's own checks below are a
belt-and-suspenders check on the log content, not a substitute.

Building this scenario found and fixed a real zzdds core bug: src/util/time.zig's
RtpsTimestamp.fromTime()/.toTime() (and RtpsDuration.fromDuration()) used
truncating integer division for the RTPS wire fraction<->nanosecond
conversion, composing floor(floor(x)) and systematically losing ~1ns on the
round trip for nearly any nonzero explicit nanosecond value -- caught
immediately by this scenario's dispose_w_timestamp() assertion (nanosecond
123456789 came back as 123456788) on its very first real cross-process run.
Fixed to round-to-nearest, matching RtpsDuration.toDuration()'s own
already-correct rounding. See docs/roadmap.md.

Like cft-reconfigure, this scenario needs no particular process start order
-- both sides just need to match before the publisher starts writing, which
its own internal wait handles -- so publisher and subscriber start together
like most other 2-process scenarios in this tier.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./source_timestamp_cross_binding_test.py
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
# integration-tests/interop/*.py smoke test's own domain (9-24 are taken --
# coherent-sets=18, delete-contained-entities=19, sample-rejected-lost=20,
# enable-defer=21, wait-for-historical-data=22, ignore-entities=23,
# cft-reconfigure=24).
DOMAIN = "25"
PROC_TIMEOUT_S = 60

ZIG_DIR = SUITE_ROOT / "zig" / "source-timestamp"
C_DIR = SUITE_ROOT / "c" / "source-timestamp"
CPP_DIR = SUITE_ROOT / "cpp" / "source-timestamp"
JAVA_DIR = SUITE_ROOT / "java" / "source-timestamp"
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
    print("== Building zig/source-timestamp ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/source-timestamp build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/source-timestamp"), (CPP_DIR, "cpp/source-timestamp")):
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

    print("== Building java/source-timestamp ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/source-timestamp build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "source_timestamp_publisher",
        ZIG_DIR / "zig-out" / "bin" / "source_timestamp_subscriber",
        C_DIR / "build" / "source_timestamp_publisher",
        C_DIR / "build" / "source_timestamp_subscriber",
        CPP_DIR / "build" / "source_timestamp_publisher",
        CPP_DIR / "build" / "source_timestamp_subscriber",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "source_timestamp_publisher")],
        "c": [str(C_DIR / "build" / "source_timestamp_publisher")],
        "cpp": [str(CPP_DIR / "build" / "source_timestamp_publisher")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def subscriber_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "source_timestamp_subscriber")],
        "c": [str(C_DIR / "build" / "source_timestamp_subscriber")],
        "cpp": [str(CPP_DIR / "build" / "source_timestamp_subscriber")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(subscriber_lang: str, publisher_lang: str, zig_out: Path) -> bool:
    label = f"{subscriber_lang} subscriber <- {publisher_lang} publisher"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"source-timestamp-{subscriber_lang}-{publisher_lang}"

    sub = LiveProcess(subscriber_cmd(subscriber_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    pub = LiveProcess(publisher_cmd(publisher_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: received disposed instance with source_timestamp matching the explicit dispose timestamp." in sub.log_text()
    ok = ok and "Subscriber: done." in sub.log_text()
    # All 5 alive samples individually, not just the summary -- a subscriber
    # that (incorrectly) declared done early could otherwise slip through.
    for seq in range(5):
        ok = ok and f"Subscriber: received seq={seq} with source_timestamp sec={1000000 + seq} matching the explicit write timestamp." in sub.log_text()
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
        print("FAIL: source-timestamp cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} source-timestamp cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
