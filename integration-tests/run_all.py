#!/usr/bin/env python3
"""Top-level orchestrator: builds/runs every integration-test scenario in
this repo against a single zzdds zig-out. Mirrors examples/run_all.py's
model exactly (see that file's docstring for the --strict rationale):
by default a missing prerequisite (a binding zzdds wasn't built with) is
SKIPPED, not failed; --strict (what zzdds's own CI uses) turns every skip
into a hard failure.

Unlike examples/, every scenario here is built once per binding and run
cross-binding on purpose -- see docs/design/integration-test-tier.md for
why this tier exists and how it differs from examples/ and stress-tests/.

Usage:
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run_all.py [--strict]

Defaults to ../zig-out (the zzdds repo this integration-tests/ directory
lives in) if ZZDDS_ZIG_OUT isn't set -- see _common.py's zzdds_zig_out().
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent / "examples"))
from _common import run_build, zzdds_zig_out  # noqa: E402

PASSED: list[str] = []
SKIPPED: list[str] = []
FAILED: list[str] = []


def skip_or_fail(name: str, reason: str, strict: bool) -> None:
    if strict:
        print(f"FAIL (strict, missing prerequisite): {name} -- {reason}", file=sys.stderr)
        FAILED.append(name)
    else:
        print(f"SKIP: {name} -- {reason}")
        SKIPPED.append(name)


def run_section(name: str, fn) -> None:
    print(f"== {name} ==")
    ok = fn()
    if ok:
        print(f"OK: {name}")
        PASSED.append(name)
    else:
        print(f"FAIL: {name}", file=sys.stderr)
        FAILED.append(name)
    print()


def run_script(path: Path, *, env: dict | None = None) -> bool:
    return subprocess.run([sys.executable, str(path)], env=env).returncode == 0


def build_cmake(name: str, source_dir: Path, build_dir: Path, zig_out: Path) -> bool:
    if build_dir.exists():
        shutil.rmtree(build_dir)
    build_dir.mkdir(parents=True)
    log_path = build_dir / "cmake.log"
    if not run_build(
        ["cmake", f"-DCMAKE_PREFIX_PATH={zig_out}", "-B", str(build_dir), "-S", str(source_dir)],
        cwd=SCRIPT_DIR,
        log_path=log_path,
    ):
        print(f"FAIL: {name} configure -- see {log_path}", file=sys.stderr)
        return False
    if not run_build(["cmake", "--build", str(build_dir)], cwd=SCRIPT_DIR, log_path=log_path):
        print(f"FAIL: {name} build -- see {log_path}", file=sys.stderr)
        return False
    print(log_path.read_text(errors="replace"))
    return True


def main() -> int:
    args = sys.argv[1:]
    strict = False
    for arg in args:
        if arg == "--strict":
            strict = True
        else:
            print(f"Unknown argument: {arg} (only --strict is supported)", file=sys.stderr)
            return 2

    zig_out = zzdds_zig_out()
    if not zig_out.is_dir():
        print(f"FAIL: ZZDDS_ZIG_OUT ({zig_out}) does not exist.", file=sys.stderr)
        return 1

    c_binding = (zig_out / "include" / "zzdds_c.h").is_file()
    cpp_binding = (zig_out / "src" / "dcps_impl.cpp").is_file()
    java_binding = (zig_out / "java").is_dir() and (zig_out / "bin" / "zidl").is_file()

    print(f"ZZDDS_ZIG_OUT={zig_out}")
    print(f"Detected: c-binding={int(c_binding)} cpp-binding={int(cpp_binding)} java-binding={int(java_binding)}")
    if strict:
        print("Mode: --strict (missing prerequisites are failures)")
    print()

    env = os.environ.copy()
    env["ZZDDS_ZIG_OUT"] = str(zig_out)

    # ── C ────────────────────────────────────────────────────────────────
    if c_binding:
        run_section("c", lambda: build_cmake("c", SCRIPT_DIR / "c", SCRIPT_DIR / "c" / "build", zig_out))
    else:
        skip_or_fail("c", "zzdds not built with -Dc-binding=true (missing include/zzdds_c.h)", strict)

    # ── C++ ──────────────────────────────────────────────────────────────
    if cpp_binding:
        run_section("cpp", lambda: build_cmake("cpp", SCRIPT_DIR / "cpp", SCRIPT_DIR / "cpp" / "build", zig_out))
    else:
        skip_or_fail("cpp", "zzdds not built with -Dcpp-binding=true (missing src/dcps_impl.cpp)", strict)

    # ── Java ─────────────────────────────────────────────────────────────
    if java_binding:
        run_section("java", lambda: run_script(SCRIPT_DIR / "java" / "coherent-sets" / "build.py", env=env))
    else:
        skip_or_fail("java", "zzdds not built with -Djava-binding=true (missing java/ or bin/zidl)", strict)

    # ── Coherent-sets cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/coherent-sets-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "coherent_sets_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/coherent-sets-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Delete-contained-entities cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/delete-contained-entities-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "delete_contained_entities_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/delete-contained-entities-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Sample-rejected-lost cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/sample-rejected-lost-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "sample_rejected_lost_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/sample-rejected-lost-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Enable-defer cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/enable-defer-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "enable_defer_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/enable-defer-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Wait-for-historical-data cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/wait-for-historical-data-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "wait_for_historical_data_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/wait-for-historical-data-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Ignore-entities cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/ignore-entities-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "ignore_entities_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/ignore-entities-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Cft-reconfigure cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/cft-reconfigure-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "cft_reconfigure_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/cft-reconfigure-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Source-timestamp cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/source-timestamp-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "source_timestamp_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/source-timestamp-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Liveliness-lost cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section(
            "interop/liveliness-lost-cross-binding",
            lambda: run_script(SCRIPT_DIR / "interop" / "liveliness_lost_cross_binding_test.py", env=env),
        )
    else:
        skip_or_fail("interop/liveliness-lost-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── Summary ──────────────────────────────────────────────────────────
    print("======================================")
    print(f"Passed:  {' '.join(PASSED) if PASSED else '(none)'}")
    print(f"Skipped: {' '.join(SKIPPED) if SKIPPED else '(none)'}")
    print(f"Failed:  {' '.join(FAILED) if FAILED else '(none)'}")

    if FAILED:
        print("RESULT: FAIL")
        return 1
    print("RESULT: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
