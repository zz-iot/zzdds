#!/usr/bin/env python3
"""Participant-config cross-binding interoperability smoke test: builds all
four participant-config ports (zig, c, cpp, java), then runs a
representative subset of (publisher, subscriber) pairs over real UDP DDS
discovery -- not the full 4x3=12-pair mesh hello_world_cross_binding_smoke_test.py
runs.

Run without --config, each side defaults to "programmatic mode": builds a
DomainParticipantConfig value, round-trips it through
set_default_participant_config/get_default_participant_config, and creates
its participant via create_participant_ex -- so the cross-binding risk here
is each binding's own marshaling of the DomainParticipantConfig mirror
struct across the C-ABI/JNI boundary, not a wire-format-specific concern
(same category as registry's instance-lifecycle wrapper risk). A
same-binding self-test per language plus a handful of cross pairs (covering
every language as both publisher and subscriber at least once) covers that.

A pair only counts as passing if both sides actually printed their real
completion markers, not just that both processes exited 0 -- see
hello_world_cross_binding_smoke_test.py's comment for why that distinction
matters.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./participant_config_cross_binding_smoke_test.py
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
DOMAIN = "16"
PROC_TIMEOUT_S = 30

ZIG_DIR = REPO_ROOT / "zig" / "participant-config"
C_DIR = REPO_ROOT / "c" / "participant-config"
CPP_DIR = REPO_ROOT / "cpp" / "participant-config"
JAVA_DIR = REPO_ROOT / "java" / "participant-config"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language, plus a representative cross-binding cycle covering
# every language as both publisher and subscriber at least once -- see the
# module docstring for why this matrix is lighter-weight than hello_world's.
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
    print("== Building zig/participant-config ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/participant-config build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/participant-config"), (CPP_DIR, "cpp/participant-config")):
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

    print("== Building java/participant-config ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/participant-config build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "participant_config_pub",
        ZIG_DIR / "zig-out" / "bin" / "participant_config_sub",
        C_DIR / "build" / "participant_config_pub",
        C_DIR / "build" / "participant_config_sub",
        CPP_DIR / "build" / "participant_config_pub",
        CPP_DIR / "build" / "participant_config_sub",
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
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "participant_config_pub")],
        "c": [str(C_DIR / "build" / "participant_config_pub")],
        "cpp": [str(CPP_DIR / "build" / "participant_config_pub")],
        "java": java_cmd(zig_out, JAVA_CP, "Publisher"),
    }[lang]


def sub_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "participant_config_sub")],
        "c": [str(C_DIR / "build" / "participant_config_sub")],
        "cpp": [str(CPP_DIR / "build" / "participant_config_sub")],
        "java": java_cmd(zig_out, JAVA_CP, "Subscriber"),
    }[lang]


def run_pair(pub_lang: str, sub_lang: str, zig_out: Path) -> bool:
    label = f"{pub_lang} pub -> {sub_lang} sub"
    env = run_env(zig_out)
    logdir = REPO_ROOT / "interop" / ".smoke-logs" / f"participant-config-{pub_lang}-{sub_lang}"

    sub = LiveProcess(sub_cmd(sub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "sub.log")
    time.sleep(1)
    pub = LiveProcess(pub_cmd(pub_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "pub.log")

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "Config round-trip OK:" in pub.log_text()
    ok = ok and "Publisher: done." in pub.log_text()
    ok = ok and "Config round-trip OK:" in sub.log_text()
    ok = ok and "Subscriber: received all 3 samples in order." in sub.log_text()

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
        print("FAIL: participant-config cross-binding smoke test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} participant-config cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
