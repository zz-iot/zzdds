#!/usr/bin/env python3
"""HelloWorld cross-binding interoperability smoke test: builds all four
hello_world ports (zig, c, cpp, java), then runs every ordered
(publisher, subscriber) pair across different languages -- the full
4x3=12-pair mesh among {zig, c, cpp, java} -- over real UDP DDS discovery.

Unlike shape_main, each hello_world port is two separate binaries
(publisher/subscriber), not one binary with a -P/-S role flag.

A pair only counts as passing if all 10 samples were actually received in
order, not just that both processes exited 0 -- see
shape_cross_binding_smoke_test.py's comment for why that distinction
matters (a QoS/wire mismatch can still exit 0).

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./hello_world_cross_binding_smoke_test.py
"""
from __future__ import annotations

import itertools
import os
import shutil
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from _common import (
    LiveProcess,
    REPO_ROOT,
    java_cmd,
    print_fail,
    require_tool,
    run_build,
    run_env,
    zzdds_zig_out,
)

# Dedicated domain, distinct from custom-allocator's (7), shape's (9), and
# the default (0) every hello_world binary would otherwise use -- so this
# can't cross-talk with anything else that might be running nearby.
DOMAIN = "10"
PROC_TIMEOUT_S = 15

ZIG_DIR = REPO_ROOT / "zig" / "hello_world"
C_DIR = REPO_ROOT / "c" / "hello_world"
CPP_DIR = REPO_ROOT / "cpp" / "hello_world"
JAVA_DIR = REPO_ROOT / "java" / "hello_world"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")


def build_all(zig_out: Path) -> bool:
    print("== Building zig/hello_world ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/hello_world build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/hello_world"), (CPP_DIR, "cpp/hello_world")):
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

    print("== Building java/hello_world ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/hello_world build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "hello_world_pub",
        ZIG_DIR / "zig-out" / "bin" / "hello_world_sub",
        C_DIR / "build" / "hello_world_pub",
        C_DIR / "build" / "hello_world_sub",
        CPP_DIR / "build" / "hello_world_pub",
        CPP_DIR / "build" / "hello_world_sub",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "hello_world_pub")],
        "c": [str(C_DIR / "build" / "hello_world_pub")],
        "cpp": [str(CPP_DIR / "build" / "hello_world_pub")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def sub_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "hello_world_sub")],
        "c": [str(C_DIR / "build" / "hello_world_sub")],
        "cpp": [str(CPP_DIR / "build" / "hello_world_sub")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(pub_lang: str, sub_lang: str, zig_out: Path) -> bool:
    label = f"{pub_lang} pub -> {sub_lang} sub"
    env = run_env(zig_out)
    logdir = REPO_ROOT / "interop" / ".smoke-logs" / f"hw-{pub_lang}-{sub_lang}"

    sub = LiveProcess(sub_cmd(sub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    time.sleep(1)
    pub = LiveProcess(pub_cmd(pub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: received all 10 samples in order." in sub.log_text()

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
    for pub_lang, sub_lang in itertools.permutations(LANGS, 2):
        if not run_pair(pub_lang, sub_lang, zig_out):
            failed = True

    if failed:
        print("FAIL: hello_world cross-binding smoke test", file=sys.stderr)
        return 1
    print("OK: all 12 hello_world cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
