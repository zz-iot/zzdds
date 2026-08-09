#!/usr/bin/env python3
"""WaitSet cross-binding interoperability smoke test: builds all four
waitset ports (zig, c, cpp, java), then runs a representative subset of
(publisher, subscriber) pairs over real UDP DDS discovery -- not the full
4x3=12-pair mesh hello_world_cross_binding_smoke_test.py runs.

WaitSet/GuardCondition/StatusCondition/ReadCondition/QueryCondition are a
purely local API with no wire-format effect (see
docs/design/waitset-reference-app.md) -- attaching a condition, waiting on
it, and draining data through one never touches the RTPS wire differently
than the listener-driven examples do. So the thing actually worth verifying
cross-binding here isn't wire compatibility (hello_world_cross_binding_smoke_test.py
already covers that at the RTPS level for the listener-driven path, and
nothing about that changes here) -- it's that a StatusCondition triggered by
*remote* discovery (a different binding's participant/writer/reader) still
fires correctly through each binding's own local WaitSet.wait(), and that
each binding's own condition-driven data flow still works end to end when
the peer is foreign. A same-binding self-test per language plus a handful of
cross pairs (covering every language as both publisher and subscriber at
least once) covers that without the cost of the full mesh.

A pair only counts as passing if both sides actually printed their real
completion markers, not just that both processes exited 0 -- see
hello_world_cross_binding_smoke_test.py's comment for why that distinction
matters.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./waitset_cross_binding_smoke_test.py
"""
from __future__ import annotations

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

# Dedicated domain, distinct from every other smoke test's own domain (see
# hello_world_cross_binding_smoke_test.py's matching comment) so this can't
# cross-talk with anything else that might be running nearby.
DOMAIN = "11"
PROC_TIMEOUT_S = 40  # comfortably above each binary's own 25s/30s watchdog deadline

ZIG_DIR = REPO_ROOT / "zig" / "waitset"
C_DIR = REPO_ROOT / "c" / "waitset"
CPP_DIR = REPO_ROOT / "cpp" / "waitset"
JAVA_DIR = REPO_ROOT / "java" / "waitset"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language, plus a representative cross-binding cycle covering
# every language as both publisher and subscriber at least once -- see the
# module docstring for why this is a deliberately lighter matrix than
# hello_world's full 12-pair mesh.
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
    print("== Building zig/waitset ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/waitset build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/waitset"), (CPP_DIR, "cpp/waitset")):
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

    print("== Building java/waitset ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/waitset build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "waitset_pub",
        ZIG_DIR / "zig-out" / "bin" / "waitset_sub",
        C_DIR / "build" / "waitset_pub",
        C_DIR / "build" / "waitset_sub",
        CPP_DIR / "build" / "waitset_pub",
        CPP_DIR / "build" / "waitset_sub",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "waitset_pub")],
        "c": [str(C_DIR / "build" / "waitset_pub")],
        "cpp": [str(CPP_DIR / "build" / "waitset_pub")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def sub_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "waitset_sub")],
        "c": [str(C_DIR / "build" / "waitset_sub")],
        "cpp": [str(CPP_DIR / "build" / "waitset_sub")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(pub_lang: str, sub_lang: str, zig_out: Path) -> bool:
    label = f"{pub_lang} pub -> {sub_lang} sub"
    env = run_env(zig_out)
    logdir = REPO_ROOT / "interop" / ".smoke-logs" / f"ws-{pub_lang}-{sub_lang}"

    sub = LiveProcess(sub_cmd(sub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    time.sleep(1)
    pub = LiveProcess(pub_cmd(pub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Publisher: StatusCondition remained attached through delete_datawriter (safe)." in pub.log_text()
    ok = ok and "Subscriber: received all 10 samples." in sub.log_text()
    # Every sample must show up on exactly one side of the priority split --
    # a wire/QoS mismatch that still exits 0 (e.g. wrong reliability) could
    # otherwise slip through as a false pass.
    for i in range(5):
        ok = ok and f"low-priority count={i} priority={i}" in sub.log_text()
    for i in range(5, 10):
        ok = ok and f"high-priority count={i} priority={i}" in sub.log_text()

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
        print("FAIL: waitset cross-binding smoke test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} waitset cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
