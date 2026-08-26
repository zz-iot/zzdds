#!/usr/bin/env python3
"""Shape cross-binding interoperability smoke test: builds all four
shape_main ports (zig/shape, c/shape, cpp/shape, java/shape) against a
single zzdds checkout, then runs every ordered (publisher, subscriber)
pair across different languages -- the full 4x3=12-pair mesh among
{zig, c, cpp, java}, not just the minimal zig->c->cpp->java->zig ring --
over real UDP DDS discovery. Also checks each binding's --cft
(ContentFilteredTopic) support.

A pair only counts as passing if a real sample was actually received, not
just that both processes exited 0 -- a QoS mismatch also exits 0 by design
(see java/shape/README.md's "Cross-binding interop" section for exactly
the bug this distinction caught: Java's codegen used to silently negotiate
an incompatible wire format with itself and everyone else, always exiting
clean either way). So each pair additionally requires: the publisher log
shows on_publication_matched(), the subscriber log shows at least one real
received-sample line, and neither log mentions incompatible_qos.

Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./shape_cross_binding_smoke_test.py
"""
from __future__ import annotations

import itertools
import os
import re
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

# Dedicated domain so this can't cross-talk with cross_binding_smoke_test.py
# or anything else that might be running nearby -- every port defaults to
# domain 0.
DOMAIN = "9"
ITERATIONS = "8"
PERIOD_MS = "300"
PROC_TIMEOUT_S = 15

ZIG_DIR = REPO_ROOT / "zig" / "shape"
C_DIR = REPO_ROOT / "c" / "shape"
CPP_DIR = REPO_ROOT / "cpp" / "shape"
JAVA_DIR = REPO_ROOT / "java" / "shape"
JAVA_CP = JAVA_DIR / "build" / "classes"

LANGS = ("zig", "c", "cpp", "java")

MATCHED_RE = re.compile(r"^Square\s+[A-Za-z_]+\s+\d{3}\s+\d{3}\s+\[\d+\]", re.MULTILINE)


def build_all(zig_out: Path) -> bool:
    print("== Building zig/shape ==")
    zig_out_dir = ZIG_DIR / "zig-out"
    zig_out_dir.mkdir(parents=True, exist_ok=True)
    if not run_build(["zig", "build", "-Doptimize=ReleaseSafe"], cwd=ZIG_DIR, log_path=zig_out_dir / "build.log"):
        print(f"FAIL: zig/shape build -- see {zig_out_dir}/build.log", file=sys.stderr)
        return False

    for dir_, name in ((C_DIR, "c/shape"), (CPP_DIR, "cpp/shape")):
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

    print("== Building java/shape ==")
    build_log_dir = JAVA_DIR / "build"
    build_log_dir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)
    if not run_build([sys.executable, str(JAVA_DIR / "build.py")], cwd=JAVA_DIR, log_path=build_log_dir / "build.log", env=env):
        print(f"FAIL: java/shape build -- see {build_log_dir}/build.log", file=sys.stderr)
        return False

    for bin_ in (
        ZIG_DIR / "zig-out" / "bin" / "shape_main",
        C_DIR / "build" / "shape_main",
        CPP_DIR / "build" / "shape_main",
    ):
        if not bin_.is_file():
            print(f"FAIL: expected binary not found: {bin_}", file=sys.stderr)
            return False
    if not JAVA_CP.is_dir():
        print(f"FAIL: expected Java classes dir not found: {JAVA_CP}", file=sys.stderr)
        return False
    return True


def base_cmd(lang: str, zig_out: Path) -> list[str]:
    return {
        "zig": [str(ZIG_DIR / "zig-out" / "bin" / "shape_main")],
        "c": [str(C_DIR / "build" / "shape_main")],
        "cpp": [str(CPP_DIR / "build" / "shape_main")],
        "java": java_cmd(zig_out, JAVA_CP, "ShapeMain"),
    }[lang]


def run_pair(pub_lang: str, sub_lang: str, zig_out: Path) -> bool:
    label = f"{pub_lang} pub -> {sub_lang} sub"
    env = run_env(zig_out)
    logdir = REPO_ROOT / "interop" / ".smoke-logs" / f"shape-{pub_lang}-{sub_lang}"

    sub = LiveProcess(
        base_cmd(sub_lang, zig_out) + ["-S", "-d", DOMAIN, "-i", ITERATIONS, "--read-period", PERIOD_MS],
        env=env,
        log_path=logdir / "sub.log",
    )
    time.sleep(1)
    pub = LiveProcess(
        base_cmd(pub_lang, zig_out) + ["-P", "-w", "-d", DOMAIN, "-i", ITERATIONS, "--write-period", PERIOD_MS],
        env=env,
        log_path=logdir / "pub.log",
    )

    pub.wait(PROC_TIMEOUT_S)
    pub_rc = pub.stop()
    sub.wait(PROC_TIMEOUT_S)
    sub_rc = sub.stop()

    pub_log = pub.log_text()
    sub_log = sub.log_text()

    ok = pub_rc == 0 and sub_rc == 0
    ok = ok and "on_publication_matched()" in pub_log
    ok = ok and MATCHED_RE.search(sub_log) is not None
    ok = ok and "incompatible_qos" not in pub_log.lower() and "incompatible_qos" not in sub_log.lower()

    if ok:
        print(f"OK: {label}")
        return True
    print_fail(label, f"pub_rc={pub_rc} sub_rc={sub_rc}", ("publisher", pub), ("subscriber", sub))
    return False


# ── ContentFilteredTopic (--cft) check, one per binding ────────────────────
#
# Filtering happens entirely on the subscriber side (each binding's own
# generated get_field_from_cdr), so a same-language pair per binding is
# enough to prove each backend's filter codegen actually works -- this
# isn't about wire interop (already proven above), it's about "does this
# binding's ContentFilteredTopic reader actually drop non-matching samples."
#
# Design note: earlier iterations of this check relied on a fixed or
# generous publish *window* and hoped match would complete somewhere
# inside it -- still a guess, just a bigger one, and no fixed number can
# be proven sufficient against an arbitrarily slow/loaded machine. This
# version doesn't guess: both sides run indefinitely (-i -1), the script
# polls the publisher's own log for its genuine on_publication_matched()
# signal (a real, positive event, not an assumed elapsed time), and only
# *after* that confirmed event does it wait a short, well-bounded margin
# for a couple more already-matched write/read cycles to actually happen
# -- safe to bound, since it's no longer gambling on unknown SPDP/SEDP
# discovery time, only on a loopback round-trip or two after a match
# already confirmed to exist.
#
# The assertion is also deliberately not an exact count: it checks a
# purely timing-independent invariant (zero non-matching samples ever
# arrive; at least one of *each* matching value arrives), not "exactly N
# arrived by some deadline" -- the latter conflates "does CFT filtering
# work" with "does the writer guarantee zero data loss for a reader that
# hasn't matched yet" (a separate, unrelated VOLATILE-durability property).
#
# LiveProcess.stop()'s bounded SIGINT-then-SIGKILL escalation is what
# makes this safe at all: an earlier bash version of this exact design
# hung for 40+ minutes because a Java subscriber didn't react to SIGINT
# the way the native binaries do, and a raw `wait "$pid"` had no timeout.
# That can't happen here -- stop() always returns within its grace period.
#
# One more wrinkle, found live: shape_main's publisher has its own
# internal, hardcoded 10-second "give up and exit cleanly if unmatched"
# deadline (`match_deadline`/`READER_NOT_MATCHED` in shape_main.zig) --
# not exposed via any CLI flag. So polling *this* harness's log for up to
# MATCH_POLL_TIMEOUT_S is moot past ~10s: on a genuinely slow-but-working
# machine (not broken, just slow SPDP/SEDP), the publisher process itself
# would already be dead, silently, well before this harness's own window
# closes -- no amount of raising MATCH_POLL_TIMEOUT_S fixes that, since
# the ceiling lives in the binary being tested, not in this script. Can't
# change shape_main.zig from here (a different repo), so the harness
# relaunches a fresh publisher attempt each time the current one exits
# without having matched, keeping the *same* long-lived subscriber running
# throughout (it has no such internal deadline) -- overall wall-clock
# budget is still MATCH_POLL_TIMEOUT_S, just spent as however many
# ~10s attempts fit in it instead of one long wait on a single attempt
# that can only ever use the first ~10s of it anyway.

MATCH_POLL_TIMEOUT_S = 30
POST_MATCH_MARGIN_S = 2


def run_cft_check(lang: str, zig_out: Path) -> bool:
    label = f"{lang} --cft"
    env = run_env(zig_out)
    logdir = REPO_ROOT / "interop" / ".smoke-logs" / f"shape-cft-{lang}"

    # stdbuf -oL: when stdout isn't a TTY, glibc fully-buffers instead of
    # line-buffering by default, so a C/C++ binary's early
    # on_publication_matched() print can sit unflushed for a long time
    # (found live: it took well over 30s to become visible without this).
    # Zig flushes explicitly per print and Java's System.out auto-flushes
    # on newline by default, so this is a no-op for them, but applying it
    # uniformly is simpler than special-casing which languages need it.
    sub = LiveProcess(
        ["stdbuf", "-oL", "-eL", *base_cmd(lang, zig_out), "-S", "-d", DOMAIN, "--cft", "shapesize > 2", "-i", "-1", "--read-period", PERIOD_MS],
        env=env,
        log_path=logdir / "sub.log",
    )

    pub_cmd_argv = ["stdbuf", "-oL", "-eL", *base_cmd(lang, zig_out), "-P", "-w", "-d", DOMAIN, "-z", "0", "--size-modulo", "4", "-i", "-1", "--write-period", PERIOD_MS]

    matched = False
    pub = None
    attempt = 0
    deadline = time.monotonic() + MATCH_POLL_TIMEOUT_S
    while time.monotonic() < deadline:
        if pub is None or pub.poll() is not None:
            # First attempt, or the previous one hit its own internal
            # give-up deadline and exited unmatched -- relaunch fresh.
            attempt += 1
            pub = LiveProcess(pub_cmd_argv, env=env, log_path=logdir / f"pub-attempt-{attempt}.log")
        if "on_publication_matched()" in pub.log_text():
            matched = True
            break
        time.sleep(0.1)

    if not matched:
        if pub is not None:
            pub.stop()
        sub.stop()
        print_fail(label, f"publisher never reported a match within {MATCH_POLL_TIMEOUT_S}s across {attempt} attempt(s)", ("publisher (last attempt)", pub), ("subscriber", sub))
        return False

    time.sleep(POST_MATCH_MARGIN_S)
    # Exit code isn't meaningful here, unlike the mesh test's -i N
    # self-termination: these processes are *always* stopped externally by
    # us, by design, so a JVM dying from the raw SIGINT (exit 130, since
    # it doesn't chain to zzdds's native handler the way the native
    # binaries do) is an expected, successful stop -- not a failure. Only
    # the actually-received data matters.
    pub.stop()
    sub.stop()

    sub_log = sub.log_text()
    n1 = len(re.findall(r"\[1\]$", sub_log, re.MULTILINE))
    n2 = len(re.findall(r"\[2\]$", sub_log, re.MULTILINE))
    n3 = len(re.findall(r"\[3\]$", sub_log, re.MULTILINE))
    n4 = len(re.findall(r"\[4\]$", sub_log, re.MULTILINE))

    ok = n1 == 0 and n2 == 0 and n3 >= 1 and n4 >= 1

    if ok:
        print(f"OK: {label}")
        return True
    print_fail(
        label,
        f"received [1]={n1} [2]={n2} [3]={n3} [4]={n4}, expected 0 0 >=1 >=1",
        ("publisher", pub),
        ("subscriber", sub),
    )
    return False


def main() -> int:
    for tool in ("zig", "cmake", "java", "stdbuf"):
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
        print("FAIL: shape cross-binding smoke test", file=sys.stderr)
        return 1
    print("OK: all 12 shape_main cross-binding pairs (zig, c, cpp, java) interoperate.")

    cft_failed = False
    for lang in LANGS:
        if not run_cft_check(lang, zig_out):
            cft_failed = True
    if cft_failed:
        print("FAIL: shape ContentFilteredTopic check", file=sys.stderr)
        return 1
    print("OK: --cft filters correctly in all 4 bindings (zig, c, cpp, java).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
