#!/usr/bin/env python3
"""Builds every language spike against zzdds's zig-out, and with --run runs
each probe that is expected to pass.

CI runs this with --run, so that a change to zzdds's C ABI that breaks a
spike fails there. A build checks where each spike finds zzdds, the names of
the C functions it links, and, for Go (cgo checks calls against the
headers), their signatures. Only running a probe checks the Python, Rust and
Haskell declarations, which are written by hand. The modes a spike's README
expects to crash (Python's probe3 --unsafe and probe4 --crash, Go's
SPIKE_MODE=raw) are not run.

Needs `zig build install -Dc-binding=true` first, plus gcc, python3, go,
cargo and ghc. Everything it builds goes under --out (a temporary directory
by default), not into the source tree. The probes run one at a time, each
in-process over loopback.

Usage:
  ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build_all.py [--out DIR] [--run]

ZZDDS_ZIG_OUT defaults to ../../zig-out, the zzdds repo these spikes live in.
"""
from __future__ import annotations

import argparse
import os
import py_compile
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

SPIKES = Path(__file__).resolve().parent
# Every build here takes seconds to a few minutes; this bounds a hung one.
BUILD_TIMEOUT_S = 900
# Each probe takes seconds; this bounds a hung one.
PROBE_TIMEOUT_S = 120

failures: list[str] = []


@dataclass
class Probe:
    name: str
    cmd: list[str]
    cwd: Path
    env: dict[str, str] = field(default_factory=dict)
    # Where it finds its libspike_shim.so: each spike builds its own.
    shim_dir: Path | None = None


probes: list[Probe] = []


def run(name: str, cmd: list[str], cwd: Path, env: dict[str, str] | None = None, *,
        timeout: int = BUILD_TIMEOUT_S, expect_fail: str | None = None, expect_out: str | None = None) -> None:
    """Runs one step: it passes when the command exits 0 (and, with
    `expect_out`, prints that text), or with `expect_fail` when the command
    fails and its output contains that text."""
    print(f"== {name}", flush=True)
    try:
        # On timeout, subprocess.run kills the child before raising.
        proc = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        failures.append(f"{name}: timed out after {timeout} s")
        print(f"FAIL: timed out after {timeout} s", flush=True)
        return
    output = proc.stdout + proc.stderr
    if expect_fail is not None:
        ok = proc.returncode != 0 and expect_fail in output
        reason = f"expected a failure mentioning {expect_fail!r}, got exit {proc.returncode}"
    else:
        ok = proc.returncode == 0 and (expect_out is None or expect_out in output)
        reason = f"exit {proc.returncode}" if proc.returncode != 0 else f"no {expect_out!r} in its output"
    if not ok:
        failures.append(name)
        print(output, flush=True)
        print(f"FAIL: {reason}", flush=True)


def with_env(**extra: str) -> dict[str, str]:
    env = dict(os.environ)
    env.update(extra)
    return env


def shim(name: str, sources: list[str], src_dir: Path, out_dir: Path, include: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    run(f"{name}: spike_shim", ["gcc", "-shared", "-fPIC", f"-I{include}", "-o", str(out_dir / "libspike_shim.so"), *sources], src_dir)


def build_python(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "python"
    shim("python", ["spike_shim.c"], src, out / "python", include)
    print("== python: compile probes", flush=True)
    for probe in sorted(src.glob("probe*.py")):
        try:
            py_compile.compile(str(probe), cfile=str(out / "python" / (probe.stem + ".pyc")), doraise=True)
        except py_compile.PyCompileError as e:
            failures.append(f"python: {probe.name}")
            print(e.msg, flush=True)
    env = {"ZZDDS_LIB": str(lib / "libzzdds.so"), "SPIKE_SHIM_LIB": str(out / "python" / "libspike_shim.so")}
    for args in (["probe1_deadline_timer.py"], ["probe2_many_threads_stress.py"],
                 ["probe3_dangling_trampoline.py", "--safe"], ["probe4_condition_ownership.py", "--vanish"],
                 ["probe5_waitset_lifetime_and_typesupport_ctx.py", "--waitset"],
                 ["probe5_waitset_lifetime_and_typesupport_ctx.py", "--typesupport-ctx"]):
        probes.append(Probe(f"python: {' '.join(args)}", [sys.executable, *args], src, env))


def build_go(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "go"
    # Each probe's #cgo directives name ../../zig-out; these add ZZDDS_ZIG_OUT's.
    env = with_env(CGO_CFLAGS=f"{os.environ.get('CGO_CFLAGS', '')} -I{include}".strip(),
                   CGO_LDFLAGS=f"{os.environ.get('CGO_LDFLAGS', '')} -L{lib}".strip())
    for probe in sorted(p.name for p in src.iterdir() if p.is_dir()):
        run(f"go: {probe}", ["go", "build", "-o", str(out / "go" / probe), f"./{probe}"], src, env)
    probes.append(Probe("go: probe1_attach", [str(out / "go" / "probe1_attach")], src))
    probes.append(Probe("go: probe2_ctx_handle (handle)", [str(out / "go" / "probe2_ctx_handle")], src, {"SPIKE_MODE": "handle"}))


def build_rust(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "rust"
    shim("rust", ["spike_shim.c", "static_pool_allocator.c"], src, out / "rust", include)
    target = out / "rust" / "target"
    # build.rs finds the shim beside Cargo.toml, where the README builds it.
    env = with_env(CARGO_TARGET_DIR=str(target),
                   RUSTFLAGS=f"{os.environ.get('RUSTFLAGS', '')} -L native={out / 'rust'} -L native={lib}".strip())
    run("rust: spike and allocator_spike", ["cargo", "build", "--locked", "--bin", "zzdds_rust_spike", "--example", "allocator_spike"], src, env)
    # The spike's point: using a loaned sample after its return is a compile error.
    run("rust: escape_attempt does not compile", ["cargo", "build", "--locked", "--example", "escape_attempt"], src, env, expect_fail="E0597")
    probes.append(Probe("rust: zzdds_rust_spike", [str(target / "debug" / "zzdds_rust_spike")], src, shim_dir=out / "rust"))
    probes.append(Probe("rust: allocator_spike", [str(target / "debug" / "examples" / "allocator_spike")], src, shim_dir=out / "rust"))


def build_haskell(out: Path, include: Path, lib: Path) -> None:
    src = SPIKES / "haskell"
    shim_dir = out / "haskell"
    shim("haskell", ["spike_shim.c"], src, shim_dir, include)
    link = [f"-L{lib}", f"-L{shim_dir}", "-lzzdds", "-lspike_shim"]
    for probe, rts in [("ProbeAttach", "-threaded"), ("ProbeAttach", None), ("ProbeStablePtr", "-threaded")]:
        name = probe + ("_threaded" if rts else "_unthreaded")
        flags = [rts] if rts else []
        run(f"haskell: {name}", ["ghc", "-v0", *flags, "-O0", "-outputdir", str(shim_dir / f"{name}.build"), "-o", str(shim_dir / name), f"{probe}.hs", *link], src)
        probes.append(Probe(f"haskell: {name}", [str(shim_dir / name)], src, shim_dir=shim_dir))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--out", type=Path, help="where to build (default: a temporary directory)")
    parser.add_argument("--run", action="store_true", help="also run every probe expected to pass")
    args = parser.parse_args()

    zig_out = Path(os.environ.get("ZZDDS_ZIG_OUT", SPIKES.parent.parent / "zig-out")).resolve()
    include, lib = zig_out / "include", zig_out / "lib"
    if not (include / "zzdds_c.h").is_file():
        print(f"FAIL: no {include / 'zzdds_c.h'}: run `zig build install -Dc-binding=true` first", flush=True)
        return 1

    with tempfile.TemporaryDirectory(prefix="zzdds-spikes-") as tmp:
        out = (args.out or Path(tmp)).resolve()
        out.mkdir(parents=True, exist_ok=True)
        build_python(out, include, lib)
        build_go(out, include, lib)
        build_rust(out, include, lib)
        build_haskell(out, include, lib)
        built = not failures
        if args.run and built:
            for p in probes:
                # The compiled probes find libzzdds and their shim here.
                dirs = [str(lib)] + ([str(p.shim_dir)] if p.shim_dir else []) + [os.environ.get("LD_LIBRARY_PATH", "")]
                env = with_env(LD_LIBRARY_PATH=os.pathsep.join(d for d in dirs if d), **p.env)
                run(p.name, p.cmd, p.cwd, env, timeout=PROBE_TIMEOUT_S, expect_out="PASS")
        elif args.run:
            print("\nNot running the probes: a build failed.", flush=True)

    if failures:
        print(f"\n{len(failures)} spike step(s) failed:", flush=True)
        for f in failures:
            print(f"  {f}", flush=True)
        return 1
    print("\nEvery spike built" + (", and every probe passed." if args.run else "."), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
