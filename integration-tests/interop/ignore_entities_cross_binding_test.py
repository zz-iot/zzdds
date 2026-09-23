#!/usr/bin/env python3
"""ignore-entities cross-binding integration test: builds all four
ignore-entities ports (zig, c, cpp, java), then runs a representative
subset of (ignorer, peer, bystander) triples over real UDP DDS discovery --
4 same-binding self-tests plus a 4-triple cross-binding rotation that
exercises each language in each of the three roles at least once, mirroring
the sizing (8 total) of every other scenario's 8-pair convention, adapted
for a third role.

Unlike every other scenario in this tier, this one is three processes, not
two -- see docs/design/integration-test-tier.md for why ignore_participant()
specifically needs its own dedicated "bystander" participant, distinct from
the "peer" that serves the other three ignore_*() ops. It's also the only
scenario needing a strict THREE-PHASE start order, not just a simple
"ignorer first" gate:

  1. ignorer starts alone, sets up its topics/readers, and calls
     ignore_topic() (needs no discovery at all) before printing "ready for
     bystander".
  2. Only THEN does bystander start. ignorer's own get_discovered_participants()
     poll grabs handles[0] and calls ignore_participant() on it -- this is
     only safe to treat as "definitely bystander" because bystander is
     *provably the only participant that could possibly exist yet*.
     get_discovered_participants() makes no ordering promise across
     multiple simultaneously-discovered participants; if peer had already
     been running too, handles[0] could just as easily have been peer's
     handle. This was a REAL bug in an earlier version of this harness,
     which started peer and bystander together: it intermittently ignored
     peer by mistake, silently blackholing every one of peer's endpoints
     for the rest of that run (an ignore_participant()-scoped mismatch, not
     a networking flake, even though it looked exactly like one from the
     symptoms alone -- see docs/roadmap.md).
  3. Only once ignorer prints "ignore_participant() applied to bystander."
     -- i.e. bystander is confirmed ignored -- does peer start. Everything
     from here on (ignore_topic()'s topic-name block, the probe-then-ignore
     dances for ignore_publication()/ignore_subscription()) is proven
     against writers/readers that don't exist yet at ignore time, not ones
     that already do.

wait_for_marker() below enforces each gate by polling the ignorer's own
log for the relevant marker -- a real signal, not a fixed sleep -- the same
pattern interop/wait_for_historical_data_cross_binding_test.py uses for its
own (single-gate) process-ordering constraint.

See c/ignore-entities/src/ignorer.c for the assertions themselves -- this
script's own checks below are a belt-and-suspenders check on the log
content, not a substitute.

A note on PROC_TIMEOUT_S: this scenario's own internal per-step timeouts
(discover-bystander, two probe-match dances, ControlTopic match/receive) are
individually as generous as any other scenario's, but they chain
sequentially in one process instead of running independently in two, so
their worst-case sum is real and this constant has to clear it with margin
-- see the comment at its definition below for the exact accounting. Do not
shrink it without redoing that arithmetic.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./ignore_entities_cross_binding_test.py
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
# integration-tests/interop/*.py smoke test's own domain (9-22 are taken --
# coherent-sets=18, delete-contained-entities=19, sample-rejected-lost=20,
# enable-defer=21, wait-for-historical-data=22). Same one-fixed-domain-for-
# every-pair convention every other scenario's interop test uses.
DOMAIN = "23"
# Phase 1 -> 2 gate: ignorer has finished its own setup and is ready for
# bystander to start (but NOT peer yet -- see the module docstring's
# three-phase explanation).
READY_FOR_BYSTANDER_MARKER = "Ignorer: ready for bystander."
# Generous: cold JVM startup (for a java ignorer) plus the ignorer's own
# topic/reader setup before it prints this marker.
READY_MARKER_TIMEOUT_S = 30
# Phase 2 -> 3 gate: ignorer has confirmed ignoring bystander's participant.
# Only after this may peer start -- see the module docstring for why
# starting it any earlier makes get_discovered_participants()'s handles[0]
# ambiguous between bystander and peer.
BYSTANDER_IGNORED_MARKER = "Ignorer: ignore_participant() applied to bystander."
# Generous: covers DISCOVER_BYSTANDER_TIMEOUT_MS (15s in every ignorer
# implementation) plus bystander's own process startup.
BYSTANDER_IGNORED_TIMEOUT_S = 20
# Ignorer's own internal deadline chain, worst case if every step actually
# hits its own timeout (discover-bystander 15s + publication probe-match
# 45s + subscription probe-match 45s + settle window 3s + ControlTopic
# match 20s + ControlTopic receive 20s) sums to 148s -- this MUST stay
# comfortably above that sum, not just "generous-looking" on its own: an
# external stop() firing before the ignorer's own internal timeout has even
# had a chance to fire and self-report isn't a real failure, just a
# truncated run that looks like one. The two probe-match timeouts
# (ignorer.{c,cpp,zig}/Ignorer.java's PROBE_MATCH_TIMEOUT) were bumped from
# 20s to 45s after this scenario -- alone among every scenario in this tier
# -- showed intermittent probe-match delays under this suite's own CI/dev
# sandbox load that a 20s bound didn't reliably clear; see docs/roadmap.md.
PROC_TIMEOUT_S = 240

ZIG_DIR = SUITE_ROOT / "zig" / "ignore-entities"
C_DIR = SUITE_ROOT / "c" / "ignore-entities"
CPP_DIR = SUITE_ROOT / "cpp" / "ignore-entities"
JAVA_DIR = SUITE_ROOT / "java" / "ignore-entities"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

# Self-test per language (ignorer/peer/bystander all the same binding),
# plus a cross-binding rotation covering every language in every one of the
# three roles at least once -- 8 triples total, matching every other
# scenario's 8-pair sizing.
TRIPLES = [
    ("zig", "zig", "zig"),
    ("c", "c", "c"),
    ("cpp", "cpp", "cpp"),
    ("java", "java", "java"),
    ("zig", "java", "cpp"),
    ("java", "cpp", "c"),
    ("cpp", "c", "zig"),
    ("c", "zig", "java"),
]


def build_all(zig_out: Path) -> bool:
    print("== Building zig/ignore-entities ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/ignore-entities build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/ignore-entities"), (CPP_DIR, "cpp/ignore-entities")):
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

    print("== Building java/ignore-entities ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/ignore-entities build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "ignore_entities_ignorer",
        ZIG_DIR / "zig-out" / "bin" / "ignore_entities_peer",
        ZIG_DIR / "zig-out" / "bin" / "ignore_entities_bystander",
        C_DIR / "build" / "ignore_entities_ignorer",
        C_DIR / "build" / "ignore_entities_peer",
        C_DIR / "build" / "ignore_entities_bystander",
        CPP_DIR / "build" / "ignore_entities_ignorer",
        CPP_DIR / "build" / "ignore_entities_peer",
        CPP_DIR / "build" / "ignore_entities_bystander",
    ):
        if not bin_.is_file():
            print(f"FAIL: expected binary not found: {bin_}", file=sys.stderr)
            return False
    if not JAVA_CP.is_dir():
        print(f"FAIL: expected Java classes dir not found: {JAVA_CP}", file=sys.stderr)
        return False
    return True


def ignorer_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "ignore_entities_ignorer")],
        "c": [str(C_DIR / "build" / "ignore_entities_ignorer")],
        "cpp": [str(CPP_DIR / "build" / "ignore_entities_ignorer")],
        "java": java_cmd(zig_out, JAVA_CP, "Ignorer"),
    }[lang]


def peer_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "ignore_entities_peer")],
        "c": [str(C_DIR / "build" / "ignore_entities_peer")],
        "cpp": [str(CPP_DIR / "build" / "ignore_entities_peer")],
        "java": java_cmd(zig_out, JAVA_CP, "Peer"),
    }[lang]


def bystander_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "ignore_entities_bystander")],
        "c": [str(C_DIR / "build" / "ignore_entities_bystander")],
        "cpp": [str(CPP_DIR / "build" / "ignore_entities_bystander")],
        "java": java_cmd(zig_out, JAVA_CP, "Bystander"),
    }[lang]


def wait_for_marker(proc: LiveProcess, marker: str, timeout: float) -> bool:
    """Polls proc's own log for `marker` -- a real signal that a specific
    phase of the app has completed, not a fixed sleep. See the module
    docstring for why this scenario's three-phase startup is load-bearing."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if marker in proc.log_text():
            return True
        if proc.poll() is not None:
            return marker in proc.log_text()
        time.sleep(0.05)
    return marker in proc.log_text()


def run_triple(ignorer_lang: str, peer_lang: str, bystander_lang: str, domain: str, zig_out: Path) -> bool:
    label = f"{ignorer_lang} ignorer / {peer_lang} peer / {bystander_lang} bystander"
    env = run_env(zig_out)
    logdir = SUITE_ROOT / "interop" / ".smoke-logs" / f"ignore-entities-{ignorer_lang}-{peer_lang}-{bystander_lang}"

    # Phase 1: ignorer starts alone -- see the module docstring.
    # ignore_topic()'s whole point is blocking a writer that doesn't exist
    # yet at ignore time, which only holds if peer genuinely hasn't started.
    ignorer = LiveProcess(ignorer_cmd(ignorer_lang, zig_out) + ["-d", domain], env=env, log_path=logdir / "ignorer.log")

    if not wait_for_marker(ignorer, READY_FOR_BYSTANDER_MARKER, READY_MARKER_TIMEOUT_S):
        ignorer_rc = ignorer.stop()
        print_fail(label, f"ignorer never printed its ready-for-bystander marker within {READY_MARKER_TIMEOUT_S}s (ignorer_rc={ignorer_rc})", ("ignorer", ignorer))
        return False

    # Phase 2: bystander starts alone -- NOT peer yet. See the module
    # docstring: get_discovered_participants()'s handles[0] is only
    # unambiguously bystander's handle if bystander is provably the only
    # participant that could exist at this point.
    bystander = LiveProcess(bystander_cmd(bystander_lang, zig_out) + ["-d", domain], env=env, log_path=logdir / "bystander.log")

    if not wait_for_marker(ignorer, BYSTANDER_IGNORED_MARKER, BYSTANDER_IGNORED_TIMEOUT_S):
        ignorer_rc = ignorer.stop()
        bystander_rc = bystander.stop()
        print_fail(
            label,
            f"ignorer never confirmed ignoring bystander within {BYSTANDER_IGNORED_TIMEOUT_S}s (ignorer_rc={ignorer_rc} bystander_rc={bystander_rc})",
            ("ignorer", ignorer),
            ("bystander", bystander),
        )
        return False

    # Phase 3: only now does peer start.
    peer = LiveProcess(peer_cmd(peer_lang, zig_out) + ["-d", domain], env=env, log_path=logdir / "peer.log")

    ignorer.wait(PROC_TIMEOUT_S)
    ignorer_rc = ignorer.stop()
    peer.wait(PROC_TIMEOUT_S)
    peer_rc = peer.stop()
    bystander.wait(PROC_TIMEOUT_S)
    bystander_rc = bystander.stop()

    ok = ignorer_rc == 0 and peer_rc == 0 and bystander_rc == 0
    ok = ok and "Ignorer: ignore_topic() applied to TopicIgnoredTopic." in ignorer.log_text()
    ok = ok and "Ignorer: ignore_participant() applied to bystander." in ignorer.log_text()
    ok = ok and "Ignorer: ignore_publication() applied via probe." in ignorer.log_text()
    ok = ok and "Ignorer: ignore_subscription() applied via probe." in ignorer.log_text()
    ok = ok and "Ignorer: all ignore checks passed." in ignorer.log_text()
    ok = ok and "Ignorer: ControlTopic received all 5 samples." in ignorer.log_text()
    ok = ok and "Ignorer: done." in ignorer.log_text()
    ok = ok and "Peer: SubscriptionIgnoredTopic reader received zero samples from the real (post-ignore) writer." in peer.log_text()
    ok = ok and "Peer: done." in peer.log_text()
    ok = ok and "Bystander: created writer for ParticipantIgnoredTopic." in bystander.log_text()
    ok = ok and "Bystander: done." in bystander.log_text()
    # Belt-and-suspenders: the apps' own internal assertions already exit
    # nonzero and print "FAIL: ..." the instant a violation is observed --
    # this just double-checks the log content itself never contains one, in
    # case a future change made the exit code mismatch the log content.
    ok = ok and "FAIL:" not in ignorer.log_text()
    ok = ok and "FAIL:" not in peer.log_text()
    ok = ok and "FAIL:" not in bystander.log_text()

    if ok:
        print(f"OK: {label}")
        return True
    print_fail(label, f"ignorer_rc={ignorer_rc} peer_rc={peer_rc} bystander_rc={bystander_rc}", ("ignorer", ignorer), ("peer", peer), ("bystander", bystander))
    return False


def main() -> int:
    for tool in ("zig", "cmake", "java"):
        if not require_tool(tool):
            return 1
    zig_out = zzdds_zig_out()

    if not build_all(zig_out):
        return 1

    failed = False
    for ignorer_lang, peer_lang, bystander_lang in TRIPLES:
        if not run_triple(ignorer_lang, peer_lang, bystander_lang, DOMAIN, zig_out):
            failed = True

    if failed:
        print("FAIL: ignore-entities cross-binding integration test", file=sys.stderr)
        return 1
    print(f"OK: all {len(TRIPLES)} ignore-entities cross-binding triples (zig, c, cpp, java) interoperate.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
