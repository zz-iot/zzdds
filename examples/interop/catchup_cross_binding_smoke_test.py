#!/usr/bin/env python3
"""Catchup cross-binding interoperability smoke test: builds all four
catchup ports (zig, c, cpp, java), then runs the full 4x3=12-pair mesh
(every language as both publisher and subscriber against every other
language) -- unlike waitset/presence/registry's lighter subset, matching
hello_world_cross_binding_smoke_test.py's own full-mesh choice.

Durability/historical replay is real wire-format-adjacent RTPS behavior
(TRANSIENT_LOCAL history caching and replay to a late-joining reader, not
just a local API), so this leans toward more cross-binding coverage, not
less -- see docs/design/catchup-reference-app.md's design note on this,
carried over from the original example brainstorm.

A pair only counts as passing if both sides actually printed their real
completion markers, not just that both processes exited 0 -- see
hello_world_cross_binding_smoke_test.py's comment for why that distinction
matters.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./catchup_cross_binding_smoke_test.py
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

# Dedicated domain, distinct from every other smoke test's own domain (see
# hello_world_cross_binding_smoke_test.py's matching comment) so this can't
# cross-talk with anything else that might be running nearby.
DOMAIN = "14"
# Comfortably above the worst-case internal deadline chain (writer's own
# 15s match-wait/15s drain-wait, reader's own 10s historical-wait/30s
# live-wait) -- see docs/design/catchup-reference-app.md.
PROC_TIMEOUT_S = 45
# Gives the publisher time to actually finish writing its historical batch
# before the late-joining subscriber starts -- see run_pair below.
PUBLISHER_HEAD_START_S = 2

ZIG_DIR = REPO_ROOT / "zig" / "catchup"
C_DIR = REPO_ROOT / "c" / "catchup"
CPP_DIR = REPO_ROOT / "cpp" / "catchup"
JAVA_DIR = REPO_ROOT / "java" / "catchup"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Full 4x3 mesh: every language as both publisher and subscriber against
# every other language (excluding self-pairs, which the per-binding build
# step itself already exercises implicitly since pub/sub of the same
# language share a build) -- see the module docstring for why this example
# gets the fuller matrix rather than a lighter subset.
PAIRS = [(p, s) for p, s in itertools.product(LANGS, LANGS) if p != s] + [
    (lang, lang) for lang in LANGS
]


def build_all(zig_out: Path) -> bool:
    print("== Building zig/catchup ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/catchup build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/catchup"), (CPP_DIR, "cpp/catchup")):
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

    print("== Building java/catchup ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/catchup build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "catchup_pub",
        ZIG_DIR / "zig-out" / "bin" / "catchup_sub",
        C_DIR / "build" / "catchup_pub",
        C_DIR / "build" / "catchup_sub",
        CPP_DIR / "build" / "catchup_pub",
        CPP_DIR / "build" / "catchup_sub",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "catchup_pub")],
        "c": [str(C_DIR / "build" / "catchup_pub")],
        "cpp": [str(CPP_DIR / "build" / "catchup_pub")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def sub_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "catchup_sub")],
        "c": [str(C_DIR / "build" / "catchup_sub")],
        "cpp": [str(CPP_DIR / "build" / "catchup_sub")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(pub_lang: str, sub_lang: str, zig_out: Path) -> bool:
    label = f"{pub_lang} pub -> {sub_lang} sub"
    env = run_env(zig_out)
    logdir = REPO_ROOT / "interop" / ".smoke-logs" / f"catchup-{pub_lang}-{sub_lang}"

    # Publisher starts first and gets a head start -- this example's whole
    # point is a subscriber that joins *after* the historical batch is
    # already written, not a race the app resolves on its own (see the
    # module docstring and docs/design/catchup-reference-app.md).
    pub = LiveProcess(pub_cmd(pub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")
    time.sleep(PUBLISHER_HEAD_START_S)
    sub = LiveProcess(sub_cmd(sub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Subscriber: wait_for_historical_data() returned" in sub.log_text()
    ok = ok and "HISTORICAL BATCH COMPLETE (10 samples)" in sub.log_text()
    ok = ok and "Subscriber: observed historical batch then live batch correctly." in sub.log_text()
    # All 5 live samples individually, not just the summary marker -- a
    # subscriber that (incorrectly) declared done after only some live
    # samples could otherwise slip through as a false pass.
    for i in range(10, 15):
        ok = ok and f"LIVE SAMPLE seq_num={i}" in sub.log_text()

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
        print("FAIL: catchup cross-binding smoke test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} catchup cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
