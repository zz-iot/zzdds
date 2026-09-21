#!/usr/bin/env python3
"""delete-contained-entities cross-binding integration test: builds all four
delete-contained-entities ports (zig, c, cpp, java), then runs a
representative subset of (session, peer) pairs over real UDP DDS discovery --
the same 4-self + 4-cross-cycle subset raw_loan_cross_binding_smoke_test.py
and coherent_sets_cross_binding_test.py use, not the full 4x3=12-pair mesh.

Unlike a demonstration example, this is a targeted correctness test: the
"session" role builds a small entity tree (2 DataWriters, a plain
DataReader, a ContentFilteredTopic-backed DataReader, a WaitSet-attached
ReadCondition) and tears the whole tree down in one shot via
delete_contained_entities() instead of deleting each child first -- proving
the cascade genuinely leaves nothing dangling (delete_participant()
immediately afterward must also succeed) and that no matched-status
listener ever fires after the torn_down flag is set. See
docs/design/integration-test-tier.md for the full scenario spec and
c/delete-contained-entities/src/session.c for the core assertions
themselves (each language's session does the same checks and fails loudly
and specifically if one is ever violated -- this script's own checks below
are a belt-and-suspenders check on the log content, not a substitute).

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./delete_contained_entities_cross_binding_test.py
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
# own domain and from coherent_sets_cross_binding_test.py's domain 18.
DOMAIN = "19"
PROC_TIMEOUT_S = 40

ZIG_DIR = SUITE_ROOT / "zig" / "delete-contained-entities"
C_DIR = SUITE_ROOT / "c" / "delete-contained-entities"
CPP_DIR = SUITE_ROOT / "cpp" / "delete-contained-entities"
JAVA_DIR = SUITE_ROOT / "java" / "delete-contained-entities"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language, plus a representative cross-binding cycle covering
# every language as both session and peer at least once -- mirrors
# coherent_sets_cross_binding_test.py's PAIRS exactly (see its docstring for
# why this subset, not the full mesh). First element of each pair runs the
# "session" role (the one under test); second runs "peer".
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
    print("== Building zig/delete-contained-entities ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/delete-contained-entities build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/delete-contained-entities"), (CPP_DIR, "cpp/delete-contained-entities")):
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

    print("== Building java/delete-contained-entities ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/delete-contained-entities build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "delete_contained_entities_session",
        ZIG_DIR / "zig-out" / "bin" / "delete_contained_entities_peer",
        C_DIR / "build" / "delete_contained_entities_session",
        C_DIR / "build" / "delete_contained_entities_peer",
        CPP_DIR / "build" / "delete_contained_entities_session",
        CPP_DIR / "build" / "delete_contained_entities_peer",
    ):
        if not bin_.is_file():
            print(f"FAIL: expected binary not found: {bin_}", file=sys.stderr)
            return False
    if not JAVA_CP.is_dir():
        print(f"FAIL: expected Java classes dir not found: {JAVA_CP}", file=sys.stderr)
        return False
    return True


def session_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "delete_contained_entities_session")],
        "c": [str(C_DIR / "build" / "delete_contained_entities_session")],
        "cpp": [str(CPP_DIR / "build" / "delete_contained_entities_session")],
        "java": java_cmd(zig_out, JAVA_CP, "Session"),
    }[lang]


def peer_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "delete_contained_entities_peer")],
        "c": [str(C_DIR / "build" / "delete_contained_entities_peer")],
        "cpp": [str(CPP_DIR / "build" / "delete_contained_entities_peer")],
        "java": java_cmd(zig_out, JAVA_CP, "Peer"),
    }[lang]


def run_pair(session_lang: str, peer_lang: str, zig_out: Path) -> bool:
    label = f"{session_lang} session -> {peer_lang} peer"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"delete-contained-entities-{session_lang}-{peer_lang}"

    peer = LiveProcess(peer_cmd(peer_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "peer.log")
    time.sleep(1)
    session = LiveProcess(session_cmd(session_lang, zig_out) + ["-d", DOMAIN], env=env, log_path=logdir / "session.log")

    session.wait(PROC_TIMEOUT_S)
    session_rc = session.stop()
    peer.wait(PROC_TIMEOUT_S)
    peer_rc = peer.stop()

    ok = session_rc == 0 and peer_rc == 0
    ok = ok and "Session: torn down via delete_contained_entities." in session.log_text()
    ok = ok and "Peer: session disconnected cleanly." in peer.log_text()
    # Belt-and-suspenders: the session's own internal assertions already
    # exit nonzero and print a specific "FAIL: ..." the instant
    # delete_contained_entities()/delete_participant() misbehaves, or a
    # listener fires post-teardown -- this just double-checks the log
    # content itself never contains one of those, in case a future change
    # made the exit code mismatch the log.
    ok = ok and "FAIL:" not in session.log_text()
    ok = ok and "FAIL:" not in peer.log_text()

    if ok:
        print(f"OK: {label}")
        return True
    print_fail(label, f"session_rc={session_rc} peer_rc={peer_rc}", ("session", session), ("peer", peer))
    return False


def main() -> int:
    for tool in ("zig", "cmake", "java"):
        if not require_tool(tool):
            return 1
    zig_out = zzdds_zig_out()

    if not build_all(zig_out):
        return 1

    failed = False
    for session_lang, peer_lang in PAIRS:
        if not run_pair(session_lang, peer_lang, zig_out):
            failed = True

    if failed:
        print("FAIL: delete-contained-entities cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(PAIRS)} delete-contained-entities cross-binding pairs (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
