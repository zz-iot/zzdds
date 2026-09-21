#!/usr/bin/env python3
"""enable-defer cross-binding integration test: builds all four enable-defer
ports (zig, c, cpp, java), then runs a representative subset of
(configurer, peer) pairs over real UDP DDS discovery -- the same 4-self +
4-cross-cycle subset raw_loan_cross_binding_smoke_test.py uses.

Unlike a demonstration example, this is a targeted correctness test: each
pair must observe real `enable()`/`autoenable_created_entities` semantics end
to end -- a disabled writer's write() rejected, enabling a child before its
own factory rejected with PRECONDITION_NOT_MET, zero premature SEDP matching
while disabled, and normal matching/data exchange immediately after
enabling -- across two real processes and (for the cross pairs) two
different bindings' generated code. See docs/design/integration-test-tier.md
for the full scenario spec and c/enable-defer/src/configurer.c for the
assertions themselves -- this script's own checks below are a
belt-and-suspenders check on the log content, not a substitute.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./enable_defer_cross_binding_test.py
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
# integration-tests/interop/*.py smoke test's own domain (9-20 are taken --
# coherent-sets=18, delete-contained-entities=19, sample-rejected-lost=20).
DOMAIN = "21"
# The configurer's own internal pre-enable delay is ~4s, plus a 20s
# reader-ready wait and a 15s drain wait after enabling -- 40s gives
# comfortable margin over the worst case.
PROC_TIMEOUT_S = 40

ZIG_DIR = SUITE_ROOT / "zig" / "enable-defer"
C_DIR = SUITE_ROOT / "c" / "enable-defer"
CPP_DIR = SUITE_ROOT / "cpp" / "enable-defer"
JAVA_DIR = SUITE_ROOT / "java" / "enable-defer"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language, plus a representative cross-binding cycle covering
# every language as both configurer and peer at least once -- mirrors
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
    print("== Building zig/enable-defer ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/enable-defer build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/enable-defer"), (CPP_DIR, "cpp/enable-defer")):
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

    print("== Building java/enable-defer ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/enable-defer build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "enable_defer_configurer",
        ZIG_DIR / "zig-out" / "bin" / "enable_defer_peer",
        C_DIR / "build" / "enable_defer_configurer",
        C_DIR / "build" / "enable_defer_peer",
        CPP_DIR / "build" / "enable_defer_configurer",
        CPP_DIR / "build" / "enable_defer_peer",
    ):
        if not bin_.is_file():
            print(f"FAIL: expected binary not found: {bin_}", file=sys.stderr)
            return False
    if not JAVA_CP.is_dir():
        print(f"FAIL: expected Java classes dir not found: {JAVA_CP}", file=sys.stderr)
        return False
    return True


def configurer_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "enable_defer_configurer")],
        "c": [str(C_DIR / "build" / "enable_defer_configurer")],
        "cpp": [str(CPP_DIR / "build" / "enable_defer_configurer")],
        "java": java_cmd(zig_out, JAVA_CP, "Configurer"),
    }[lang]


def peer_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "enable_defer_peer")],
        "c": [str(C_DIR / "build" / "enable_defer_peer")],
        "cpp": [str(CPP_DIR / "build" / "enable_defer_peer")],
        "java": java_cmd(zig_out, JAVA_CP, "Peer"),
    }[lang]


def run_pair(configurer_lang: str, peer_lang: str, zig_out: Path) -> bool:
    label = f"{configurer_lang} configurer -> {peer_lang} peer"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"enable-defer-{configurer_lang}-{peer_lang}"

    peer = LiveProcess(peer_cmd(peer_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "peer.log")
    time.sleep(1)
    configurer = LiveProcess(configurer_cmd(configurer_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "configurer.log")

    configurer.wait(PROC_TIMEOUT_S)
    configurer_rc = configurer.stop()
    peer.wait(PROC_TIMEOUT_S)
    peer_rc = peer.stop()

    ok = configurer_rc == 0 and peer_rc == 0
    ok = ok and "Configurer: write on disabled writer correctly returned" in configurer.log_text()
    ok = ok and "Configurer: enabling writer before publisher correctly returned PRECONDITION_NOT_MET." in configurer.log_text()
    ok = ok and "Configurer: done." in configurer.log_text()
    ok = ok and "Peer: no premature match during" in peer.log_text()
    ok = ok and "Peer: no premature match; matched and received cleanly after enable()." in peer.log_text()
    # Belt-and-suspenders: the apps' own internal assertions already exit
    # nonzero and print "FAIL: ..." the instant a violation is observed --
    # this just double-checks the log content itself never contains one, in
    # case a future change made the exit code mismatch the log (see the
    # module docstring).
    ok = ok and "FAIL:" not in configurer.log_text()
    ok = ok and "FAIL:" not in peer.log_text()

    if ok:
        print(f"OK: {label}")
        return True
    print_fail(label, f"configurer_rc={configurer_rc} peer_rc={peer_rc}", ("configurer", configurer), ("peer", peer))
    return False


def main() -> int:
    for tool in ("zig", "cmake", "java"):
        if not require_tool(tool):
            return 1
    zig_out = zzdds_zig_out()

    if not build_all(zig_out):
        return 1

    failed = False
    for configurer_lang, peer_lang in PAIRS:
        if not run_pair(configurer_lang, peer_lang, zig_out):
            failed = True

    if failed:
        print("FAIL: enable-defer cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} enable-defer cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
