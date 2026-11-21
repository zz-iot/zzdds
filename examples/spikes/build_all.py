#!/usr/bin/env python3
"""Builds every language spike against zzdds's zig-out, without running a probe.

CI runs this so that a change to zzdds's C ABI that breaks a spike fails
there. A build checks where each spike finds zzdds, the names of the C
functions it links, and, for Go (cgo checks calls against the headers),
their signatures. It does not check the Python, Rust or Haskell
declarations against the headers: only running a probe does that.

Needs `zig build install -Dc-binding=true` first, plus gcc, python3, go,
cargo and ghc. Everything it builds goes under --out (a temporary
directory by default), not into the source tree.

Usage:
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build_all.py [--out DIR]

ZZDDS_ZIG_OUT defaults to ../../zig-out, the zzdds repo these spikes live in.
"""
from __future__ import annotations

import argparse
import os
import py_compile
import subprocess
import sys
import tempfile
from pathlib import Path

SPIKES = Path(__file__).resolve().parent
# Every build here takes seconds to a few minutes; this bounds a hung one.
STEP_TIMEOUT_S = 900

failures: list[str] = []


def run(name: str, cmd: list[str], cwd: Path, env: dict[str, str] | None = None, expect_fail: str | None = None) -> None:
    """Runs one build step. With `expect_fail`, the step passes only if the
    command fails and its output contains that text."""
    print(f"== {name}", flush=True)
    try:
        proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=STEP_TIMEOUT_S)
    except subprocess.TimeoutExpired:
        failures.append(f"{name}: timed out after {STEP_TIMEOUT_S} s")
        print(f"FAIL: timed out after {STEP_TIMEOUT_S} s", flush=True)
        return
    output = proc.stdout + proc.stderr
    if expect_fail is None:
        ok = proc.returncode == 0
    else:
        ok = proc.returncode != 0 and expect_fail in output
    if not ok:
        failures.append(name)
        print(output, flush=True)
        reason = f"exit {proc.returncode}" if expect_fail is None else f"expected a failure mentioning {expect_fail!r}, got exit {proc.returncode}"
        print(f"FAIL: {reason}", flush=True)


def shim(name: str, sources: list[str], src_dir: Path, out_dir: Path, include: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    run(f"{name}: spike_shim", ["gcc", "-shared", "-fPIC", f"-I{include}", "-o", str(out_dir / "libspike_shim.so"), *sources], src_dir)


def build_python(out: Path, include: Path) -> None:
    src = SPIKES / "python"
    shim("python", ["spike_shim.c"], src, out / "python", include)
    print("== python: compile probes", flush=True)
    for probe in sorted(src.glob("probe*.py")):
        try:
            py_compile.compile(str(probe), cfile=str(out / "python" / (probe.stem + ".pyc")), doraise=True)
        except py_compile.PyCompileError as e:
            failures.append(f"python: {probe.name}")
            print(e.msg, flush=True)


def build_go(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "go"
    # Each probe's #cgo directives name ../../zig-out; these add ZZDDS_ZIG_OUT's.
    env = dict(os.environ)
    env["CGO_CFLAGS"] = f"{env.get('CGO_CFLAGS', '')} -I{include}".strip()
    env["CGO_LDFLAGS"] = f"{env.get('CGO_LDFLAGS', '')} -L{lib}".strip()
    for probe in sorted(p.name for p in src.iterdir() if p.is_dir()):
        run(f"go: {probe}", ["go", "build", "-o", str(out / "go" / probe), f"./{probe}"], src, env)


def build_rust(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "rust"
    shim("rust", ["spike_shim.c", "static_pool_allocator.c"], src, out / "rust", include)
    env = dict(os.environ)
    env["CARGO_TARGET_DIR"] = str(out / "rust" / "target")
    # build.rs finds the shim beside Cargo.toml, where the README builds it.
    env["RUSTFLAGS"] = f"{env.get('RUSTFLAGS', '')} -L native={out / 'rust'} -L native={lib}".strip()
    run("rust: spike and allocator_spike", ["cargo", "build", "--locked", "--bin", "zzdds_rust_spike", "--example", "allocator_spike"], src, env)
    # The spike's point: using a loaned sample after its return is a compile error.
    run("rust: escape_attempt does not compile", ["cargo", "build", "--locked", "--example", "escape_attempt"], src, env, expect_fail="E0597")


def build_haskell(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "haskell"
    shim_dir = out / "haskell"
    shim("haskell", ["spike_shim.c"], src, shim_dir, include)
    link = [f"-L{lib}", f"-L{shim_dir}", "-lzzdds", "-lspike_shim"]
    for probe, rts in [("ProbeAttach", "-threaded"), ("ProbeAttach", None), ("ProbeStablePtr", "-threaded")]:
        name = probe + ("_threaded" if rts else "_unthreaded")
        flags = [rts] if rts else []
        run(f"haskell: {name}", ["ghc", "-v0", *flags, "-O0", "-outputdir", str(shim_dir / f"{name}.build"), "-o", str(shim_dir / name), f"{probe}.hs", *link], src)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, help="where to build (default: a temporary directory)")
    args = parser.parse_args()

    zig_out = Path(os.environ.get("ZZDDS_ZIG_OUT", SPIKES.parent.parent / "zig-out")).resolve()
    include, lib = zig_out / "include", zig_out / "lib"
    if not (include / "zzdds_c.h").is_file():
        print(f"FAIL: no {include / 'zzdds_c.h'}: run `zig build install -Dc-binding=true` first", flush=True)
        return 1

    with tempfile.TemporaryDirectory(prefix="zzdds-spikes-") as tmp:
        out = (args.out or Path(tmp)).resolve()
        out.mkdir(parents=True, exist_ok=True)
        build_python(out, include)
        build_go(out, include, lib)
        build_rust(out, include, lib)
        build_haskell(out, include, lib)

    if failures:
        print(f"\n{len(failures)} spike build step(s) failed:", flush=True)
        for f in failures:
            print(f"  {f}", flush=True)
        return 1
    print("\nEvery spike built.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
