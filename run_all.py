#!/usr/bin/env python3
"""Top-level orchestrator: builds/runs every example and smoke test in this
repo against a single zzdds zig-out. By default, whatever that zig-out
wasn't built to support (a missing binding, missing OpenCV) is SKIPPED,
not failed -- e.g. a c-binding-only zzdds build just skips the cpp/java/
interop sections. This is the end-user-friendly default: point this at
whatever you happened to build and see what actually works.

Pass --strict to turn every skip into a hard failure instead. That's what
zzdds's own CI should use: if a change to zzdds's build flags accidentally
drops a binding these examples need, --strict makes that a red CI run
instead of a quietly-shrinking test surface.

Real failures (something was available and the build/run actually failed)
are always failures, in both modes -- --strict only changes how a missing
prerequisite is treated.

Usage:
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run_all.py [--strict]

See ZZDDS_VERSION for the zzdds commit these examples are known to work
against, if you need a baseline rather than testing your own local build.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from _common import run_build, zzdds_zig_out

SCRIPT_DIR = Path(__file__).resolve().parent

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
    """Run a Python script as a subprocess, inheriting stdout/stderr live
    (these are top-level build/test steps a human or CI log wants to watch
    as they happen, not something to buffer and dump after the fact)."""
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


def has_opencv() -> bool:
    if shutil.which("pkg-config") and subprocess.run(
        ["pkg-config", "--exists", "opencv4"]
    ).returncode == 0:
        return True
    for inc in (
        "/usr/include/opencv4",
        "/usr/local/include/opencv4",
        "/usr/include",
        "/usr/local/include",
    ):
        if (Path(inc) / "opencv2" / "core.hpp").is_file():
            return True
    return False


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

    # Mirrors zzdds/build.zig exactly: -Dc-binding installs include/zzdds_c.h;
    # -Dcpp-binding additionally installs src/dcps_impl.cpp; -Djava-binding
    # installs java/ and (like every binding) needs the shared bin/zidl.
    c_binding = (zig_out / "include" / "zzdds_c.h").is_file()
    cpp_binding = (zig_out / "src" / "dcps_impl.cpp").is_file()
    java_binding = (zig_out / "java").is_dir() and (zig_out / "bin" / "zidl").is_file()
    opencv = has_opencv()

    print(f"ZZDDS_ZIG_OUT={zig_out}")
    print(f"Detected: c-binding={int(c_binding)} cpp-binding={int(cpp_binding)} java-binding={int(java_binding)} opencv={int(opencv)}")
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
        def run_java() -> bool:
            java_dir = SCRIPT_DIR / "java"
            return run_script(java_dir / "build_all.py", env=env) and run_script(java_dir / "run_all.py", env=env)

        run_section("java", run_java)
    else:
        skip_or_fail("java", "zzdds not built with -Djava-binding=true (missing java/ or bin/zidl)", strict)

    # ── Cross-binding interop (needs both c and cpp) ────────────────────
    if c_binding and cpp_binding:
        run_section("interop/cross-binding", lambda: run_script(SCRIPT_DIR / "interop" / "cross_binding_smoke_test.py", env=env))
    else:
        skip_or_fail("interop/cross-binding", "needs both c-binding and cpp-binding", strict)

    # ── Shape cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section("interop/shape-cross-binding", lambda: run_script(SCRIPT_DIR / "interop" / "shape_cross_binding_smoke_test.py", env=env))
    else:
        skip_or_fail("interop/shape-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── hello_world cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section("interop/hello-world-cross-binding", lambda: run_script(SCRIPT_DIR / "interop" / "hello_world_cross_binding_smoke_test.py", env=env))
    else:
        skip_or_fail("interop/hello-world-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── WaitSet cross-binding interop (needs c, cpp, and java; zig is native) ──
    if c_binding and cpp_binding and java_binding:
        run_section("interop/waitset-cross-binding", lambda: run_script(SCRIPT_DIR / "interop" / "waitset_cross_binding_smoke_test.py", env=env))
    else:
        skip_or_fail("interop/waitset-cross-binding", "needs c-binding, cpp-binding, and java-binding", strict)

    # ── opencv_zzdds (needs cpp-binding and OpenCV) ─────────────────────
    if cpp_binding and opencv:
        run_section("cpp/opencv_zzdds", lambda: run_script(SCRIPT_DIR / "cpp" / "opencv_zzdds" / "smoke_test.py", env=env))
    elif cpp_binding:
        skip_or_fail("cpp/opencv_zzdds", "OpenCV not found (install libopencv-dev)", strict)
    else:
        skip_or_fail("cpp/opencv_zzdds", "needs cpp-binding", strict)

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
