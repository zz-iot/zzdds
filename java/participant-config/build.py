#!/usr/bin/env python3
"""Builds the zzdds Java participant-config example.

Prerequisites:
  - A zzdds checkout built with `zig build -Djava-binding=true install`
    (set ZZDDS_ZIG_OUT to its zig-out/ dir; defaults to ../../zzdds/zig-out).
  - JAVA_HOME set to a full JDK (needs jni.h -- a JRE isn't enough for
    zzdds's own build, though this script itself only needs javac/java).
  - ZIDL_EXECUTABLE, to point at a different zidl than the one zzdds's own
    build.zig.zon pins, if you need one.
"""
from __future__ import annotations

import glob
import os
import shutil
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from _common import require_path, run_build, zzdds_zig_out

SCRIPT_DIR = Path(__file__).resolve().parent
BUILD_DIR = SCRIPT_DIR / "build"
GENERATED_DIR = BUILD_DIR / "generated"
CLASSES_DIR = BUILD_DIR / "classes"


def main() -> int:
    zig_out = zzdds_zig_out()
    zidl_exe = Path(os.environ.get("ZIDL_EXECUTABLE", str(zig_out / "bin" / "zidl")))

    if not require_path(
        zidl_exe,
        "Build zzdds first: (cd zzdds && zig build -Djava-binding=true install)",
        "Or set ZIDL_EXECUTABLE to a local zidl build.",
    ):
        return 1
    if not require_path(
        zig_out / "java",
        "Rebuild zzdds with -Djava-binding=true.",
    ):
        return 1

    print("Generating ConfigPing TypeSupport/DataWriter/DataReader from idl/config_ping.idl...")
    if GENERATED_DIR.exists():
        shutil.rmtree(GENERATED_DIR)
    GENERATED_DIR.mkdir(parents=True)
    if not run_build(
        [
            str(zidl_exe),
            "-b", "java",
            "--generate-zzdds-wrappers",
            "--java-import-package", "DDS=io.zzdds.dcps",
            "-o", str(GENERATED_DIR),
            str(SCRIPT_DIR / "idl" / "config_ping.idl"),
        ],
        cwd=SCRIPT_DIR,
        log_path=BUILD_DIR / "zidl.log",
    ):
        print(f"FAIL: zidl codegen -- see {BUILD_DIR}/zidl.log", file=sys.stderr)
        return 1

    print("Compiling...")
    if CLASSES_DIR.exists():
        shutil.rmtree(CLASSES_DIR)
    CLASSES_DIR.mkdir(parents=True)
    sources = (
        glob.glob(str(zig_out / "java" / "io" / "zzdds" / "dcps" / "*.java"))
        + glob.glob(str(zig_out / "java" / "io" / "zzdds" / "ext" / "*.java"))
        + glob.glob(str(zig_out / "java" / "io" / "zzdds" / "runtime" / "*.java"))
        + glob.glob(str(GENERATED_DIR / "*.java"))
        + [str(SCRIPT_DIR / "Publisher.java"), str(SCRIPT_DIR / "Subscriber.java")]
    )
    if not run_build(
        ["javac", "-d", str(CLASSES_DIR), *sources],
        cwd=SCRIPT_DIR,
        log_path=BUILD_DIR / "javac.log",
    ):
        print(f"FAIL: javac -- see {BUILD_DIR}/javac.log", file=sys.stderr)
        return 1

    print(f"Build OK: {CLASSES_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
