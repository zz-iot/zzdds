#!/usr/bin/env python3
"""coherent-sets cross-binding integration test: builds all four
coherent-sets ports (zig, c, cpp, java), then runs a representative subset
of (publisher, subscriber) pairs over real UDP DDS discovery -- the same
4-self + 4-cross-cycle subset raw_loan_cross_binding_smoke_test.py uses, not
the full 4x3=12-pair mesh.

Unlike a demonstration example, this is a targeted correctness test: each
pair must observe PRESENTATION access_scope=GROUP coherent/ordered-access
atomicity end to end, across two real processes and (for the cross pairs)
two different bindings' generated code -- exercising both zzdds core's
reader-side coherent-set gating and each binding's own QoS/condition/
WaitSet mapping. See docs/design/integration-test-tier.md for the full
scenario spec and c/coherent-sets/src/subscriber.c for the atomicity
assertion itself (each language's subscriber does the same check and fails
loudly and specifically if it's ever violated -- this script's own checks
below are a belt-and-suspenders check on the log content, not a substitute).

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./coherent_sets_cross_binding_test.py
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

# Dedicated domain, distinct from every examples/interop/*.py smoke test's
# own domain (9-17 are taken -- see that directory).
DOMAIN = "18"
# GROUP_COUNT (20) ticks, each gated on a WaitSet wake plus a coherent-set
# gate -- comfortably above the worst-case internal deadline chain (10s
# reader-ready + ~20*8ms write gaps + 30s subscriber receive + 15s drain).
PROC_TIMEOUT_S = 40

ZIG_DIR = SUITE_ROOT / "zig" / "coherent-sets"
C_DIR = SUITE_ROOT / "c" / "coherent-sets"
CPP_DIR = SUITE_ROOT / "cpp" / "coherent-sets"
JAVA_DIR = SUITE_ROOT / "java" / "coherent-sets"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language, plus a representative cross-binding cycle covering
# every language as both publisher and subscriber at least once -- mirrors
# raw_loan_cross_binding_smoke_test.py's PAIRS exactly (see its docstring
# for why this subset, not the full mesh).
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
    print("== Building zig/coherent-sets ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/coherent-sets build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/coherent-sets"), (CPP_DIR, "cpp/coherent-sets")):
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

    print("== Building java/coherent-sets ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/coherent-sets build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "coherent_sets_pub",
        ZIG_DIR / "zig-out" / "bin" / "coherent_sets_sub",
        C_DIR / "build" / "coherent_sets_pub",
        C_DIR / "build" / "coherent_sets_sub",
        CPP_DIR / "build" / "coherent_sets_pub",
        CPP_DIR / "build" / "coherent_sets_sub",
    ):
        if not bin_.is_file():
            print(f"FAIL: expected binary not found: {bin_}", file=sys.stderr)
            return False
    if not JAVA_CP.is_dir():
        print(f"FAIL: expected Java classes dir not found: {JAVA_CP}", file=sys.stderr)
        return False
    return True


def pub_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "coherent_sets_pub")],
        "c": [str(C_DIR / "build" / "coherent_sets_pub")],
        "cpp": [str(CPP_DIR / "build" / "coherent_sets_pub")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def sub_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "coherent_sets_sub")],
        "c": [str(C_DIR / "build" / "coherent_sets_sub")],
        "cpp": [str(CPP_DIR / "build" / "coherent_sets_sub")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(pub_lang: str, sub_lang: str, zig_out: Path) -> bool:
    label = f"{pub_lang} pub -> {sub_lang} sub"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"coherent-sets-{pub_lang}-{sub_lang}"

    sub = LiveProcess(sub_cmd(sub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    time.sleep(1)
    pub = LiveProcess(pub_cmd(pub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: received all 20 groups, atomic and ordered." in sub.log_text()
    # Belt-and-suspenders: the subscriber's own internal assertion already
    # exits nonzero and prints "FAIL: atomicity violated" the instant a
    # partial group is observed -- this just double-checks the log content
    # itself never contains one of those, in case a future change made the
    # exit code mismatch the log (see the module docstring).
    ok = ok and "atomicity violated" not in sub.log_text()
    ok = ok and "ordered_access violated" not in sub.log_text()

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
    for pub_lang, sub_lang in PAIRS:
        if not run_pair(pub_lang, sub_lang, zig_out):
            failed = True

    if failed:
        print("FAIL: coherent-sets cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} coherent-sets cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
