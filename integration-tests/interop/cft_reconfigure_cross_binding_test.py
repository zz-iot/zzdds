#!/usr/bin/env python3
"""cft-reconfigure cross-binding integration test: builds all four
cft-reconfigure ports (zig, c, cpp, java), then runs a representative
subset of (subscriber, publisher) pairs over real UDP DDS discovery -- the
same 4-self + 4-cross-cycle subset raw_loan_cross_binding_smoke_test.py
uses.

Exercises set_expression_parameters()'s runtime CFT reconfiguration
semantics -- distinct from the stress `cft` scenario's concurrency-safety
coverage (a UAF between reconfigure and receive-thread filter eval, already
found and fixed there) -- and the ContentFilteredTopic introspection
surface (get_filter_expression/get_expression_parameters/
get_related_topic) the API audit flags as completely untested ("CFT is set
once at creation, never read back or changed"). See
docs/design/integration-test-tier.md for the full scenario spec and
c/cft-reconfigure/src/subscriber.c for the assertions themselves -- this
script's own checks below are a belt-and-suspenders check on the log
content, not a substitute.

Unlike ignore-entities or wait-for-historical-data, this scenario needs no
particular process start order -- both sides synchronize entirely over a
GoTopic DataWriter/DataReader pair (see subscriber.c's header comment), so
publisher and subscriber start together like every other 2-process
scenario in this tier.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./cft_reconfigure_cross_binding_test.py
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
# integration-tests/interop/*.py smoke test's own domain (9-23 are taken --
# coherent-sets=18, delete-contained-entities=19, sample-rejected-lost=20,
# enable-defer=21, wait-for-historical-data=22, ignore-entities=23).
DOMAIN = "24"
# Publisher's own internal deadline chain: match wait (40s, see
# publisher.c's MATCH_TIMEOUT_MS comment) + go-ahead wait (20s) + drain wait
# (15s) = 75s. Subscriber's: witness wait (45s) + settle (3s) + final
# witness wait (20s) = 68s. 100s gives comfortable margin over either
# worst-case sum.
PROC_TIMEOUT_S = 100

ZIG_DIR = SUITE_ROOT / "zig" / "cft-reconfigure"
C_DIR = SUITE_ROOT / "c" / "cft-reconfigure"
CPP_DIR = SUITE_ROOT / "cpp" / "cft-reconfigure"
JAVA_DIR = SUITE_ROOT / "java" / "cft-reconfigure"
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
    print("== Building zig/cft-reconfigure ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/cft-reconfigure build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/cft-reconfigure"), (CPP_DIR, "cpp/cft-reconfigure")):
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

    print("== Building java/cft-reconfigure ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/cft-reconfigure build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "cft_reconfigure_publisher",
        ZIG_DIR / "zig-out" / "bin" / "cft_reconfigure_subscriber",
        C_DIR / "build" / "cft_reconfigure_publisher",
        C_DIR / "build" / "cft_reconfigure_subscriber",
        CPP_DIR / "build" / "cft_reconfigure_publisher",
        CPP_DIR / "build" / "cft_reconfigure_subscriber",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "cft_reconfigure_publisher")],
        "c": [str(C_DIR / "build" / "cft_reconfigure_publisher")],
        "cpp": [str(CPP_DIR / "build" / "cft_reconfigure_publisher")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def subscriber_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "cft_reconfigure_subscriber")],
        "c": [str(C_DIR / "build" / "cft_reconfigure_subscriber")],
        "cpp": [str(CPP_DIR / "build" / "cft_reconfigure_subscriber")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(subscriber_lang: str, publisher_lang: str, zig_out: Path) -> bool:
    label = f"{subscriber_lang} subscriber <- {publisher_lang} publisher"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"cft-reconfigure-{subscriber_lang}-{publisher_lang}"

    sub = LiveProcess(subscriber_cmd(subscriber_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    pub = LiveProcess(publisher_cmd(publisher_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: CFT introspection (filter_expression/expression_parameters/related_topic) verified at creation." in sub.log_text()
    ok = ok and "Subscriber: witnessed all 5 phase1 samples via unfiltered reader." in sub.log_text()
    ok = ok and "Subscriber: filtered reader correctly received zero phase1 samples (threshold=1000)." in sub.log_text()
    ok = ok and "Subscriber: set_expression_parameters() reconfigured threshold to 3, read-back verified." in sub.log_text()
    ok = ok and "Subscriber: witnessed all 10 total samples via unfiltered reader." in sub.log_text()
    ok = ok and "Subscriber: filtered reader received exactly the post-reconfigure samples {5..9}, confirming live re-filtering without CFT recreation." in sub.log_text()
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
        print("FAIL: cft-reconfigure cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} cft-reconfigure cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
