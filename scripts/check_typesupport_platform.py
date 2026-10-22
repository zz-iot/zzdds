#!/usr/bin/env python3
"""Native experimental typesupport qualification, using the pinned zidl release by default."""
import argparse
from pathlib import Path
import platform
import subprocess
import sys
import tempfile


def run(command, cwd):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run([str(arg) for arg in command], cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zidl", type=Path, help="Optional development checkout override")
    parser.add_argument("--zig", default="zig")
    parser.add_argument("--optimize", choices=("Debug", "ReleaseSafe"), default="Debug")
    parser.add_argument("--domain", type=int, default=187)
    args = parser.parse_args()
    if not 0 <= args.domain <= 232:
        parser.error("expected UDP domain 0..232")
    root = Path(__file__).resolve().parents[1]
    zidl = args.zidl.resolve() if args.zidl else None
    if zidl is not None and not (zidl / "packages/zidl-typesupport/include/zidl_typesupport.h").is_file():
        parser.error("zidl checkout must contain the experimental typesupport contract")
    print(platform.platform(), flush=True)
    run([args.zig, "version"], root)
    run(["git", "rev-parse", "HEAD"], root)
    if zidl is not None:
        run(["git", "rev-parse", "HEAD"], zidl)
    # Spaces and Unicode also exercise the Windows UTF-8 -> UTF-16 loader path.
    with tempfile.TemporaryDirectory(prefix="zzdds typesupport é ") as work:
        work = Path(work)
        windows = sys.platform == "win32"
        common = [args.zig, "build", "-j2", f"-Doptimize={args.optimize}",
                  "-Dtypesupport-library=true"]
        if zidl is not None:
            run([args.zig, "build", "-j2", "--prefix", work / "zidl"], zidl)
            generator = work / "zidl/bin" / ("zidl.exe" if windows else "zidl")
            common.extend([f"-Dtypesupport-package={zidl / 'packages/zidl-typesupport'}",
                           f"-Dtypesupport-generator={generator}"])
        stage = work / "host"
        run([*common, "test-typesupport-library", "typesupport-example", "--prefix", stage, "--summary", "all"], root)
        suffix = ".dll" if windows else ".dylib" if sys.platform == "darwin" else ".so"
        library_dir = stage / ("bin" if windows else "lib")
        prefix = "" if windows else "lib"
        run([sys.executable, root / "examples/zig/typesupport-library/smoke_test.py",
             "--host", stage / "bin" / ("typesupport-demo.exe" if windows else "typesupport-demo"),
             "--sensors", library_dir / f"{prefix}demo_sensors{suffix}",
             "--control", library_dir / f"{prefix}demo_control{suffix}",
             "--domain", str(args.domain)], root)
        run([*common, "test-typesupport-library", "-Dtypesupport-dynamic=false", "--summary", "all"], root)


if __name__ == "__main__":
    main()
