#!/usr/bin/env python3
"""Verify a prebuilt zzdds C/C++ library bundle is consumable after relocation.

`release.yml`'s `package-libs` job builds an install tree, renames it, and tars
it up. That job only checks the *contents* of the tree it just built, in place.
This script closes the gap: it takes the finished tarball, extracts it into a
fresh directory unrelated to the build tree, and confirms a downstream C/C++
project can actually consume it from there.

Steps:

  1. Structural completeness -- every file `find_package(ZZDDS)` / pkg-config /
     the C++ "three-artifact" build path needs is present (a superset of
     `package-libs`' inline check: also `bin/zidl`, `src/*.cpp`, `zzdds_c.h`,
     `zidl_allocator.h`, `libzidl_cdr.a`).
  2. Relocatability -- `zzdds.pc` and `zzdds-config.cmake` derive their prefix
     from their own location, with no absolute build path baked in.
  3. The bundled `bin/zidl` code generator runs on this platform.
  4. `find_package(ZZDDS)` resolves from the relocated prefix and its imported
     targets are usable -- `test/release-bundle/cmake_consumer` (fast, no
     codegen) then the real `examples/c/hello_world` + `examples/cpp/hello_world`
     downstream CMake projects, compiled and linked against the bundle.
  5. The linked binaries actually run -- a hello_world publisher/subscriber
     pair exchanges its 10 samples (loads `libzzdds` from the relocated prefix:
     catches broken rpath / install-name).
  6. pkg-config -- `pkg-config --cflags --libs zzdds` from the relocated prefix
     compiles, links and runs `test/release-bundle/consumer.c`.

`--configure-only` stops after step 4's `cmake` *configure* of the small
consumer (no compiler, no run, no examples). Used on Windows, where the
CMake/compiler example build path is not yet covered (same deferral as
`ci.yml`'s Windows Java binding) -- it still exercises the generated
`zzdds-config.cmake` and the bundled `zidl.exe`.
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def log(msg: str) -> None:
    print(f"[verify-bundle] {msg}", flush=True)


def fail(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"::error::verify_release_bundle: {msg}" if os.environ.get("GITHUB_ACTIONS") else f"FAIL: {msg}",
          file=sys.stderr, flush=True)
    raise SystemExit(1)


def run(cmd: list[str], *, cwd: Path | None = None, env: dict[str, str] | None = None,
        timeout: float | None = None, capture: bool = False) -> subprocess.CompletedProcess:
    log(f"$ {' '.join(cmd)}" + (f"   (cwd={cwd})" if cwd else ""))
    return subprocess.run(
        cmd, cwd=cwd, env=env, timeout=timeout,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
        text=True,
    )


# ── step 1: structure ───────────────────────────────────────────────────────

def find_prefix(extract_root: Path) -> Path:
    entries = [p for p in extract_root.iterdir() if p.is_dir()]
    if len(entries) != 1:
        fail(f"expected exactly one top-level directory in the bundle, found: {[p.name for p in entries]}")
    return entries[0]


def check_structure(prefix: Path) -> None:
    required = [
        "include/dcps.h", "include/zzdds.h", "include/zzdds_c.h",
        "include/zidl_cdr.h", "include/zidl_allocator.h",
        "include/dcps.hpp", "include/dcps_impl.hpp",
        "include/zzdds.hpp", "include/zzdds_impl.hpp",
        "lib/libzidl_cdr.a",
        "lib/pkgconfig/zzdds.pc",
        "lib/cmake/ZZDDS/zzdds-config.cmake",
        "src/dcps_impl.cpp", "src/zzdds_impl.cpp",
    ]
    missing = [rel for rel in required if not (prefix / rel).is_file()]
    if missing:
        fail("bundle is missing required files:\n  " + "\n  ".join(missing))

    if not any((prefix / rel).is_file() for rel in ("bin/zidl", "bin/zidl.exe")):
        fail("bundle has no bin/zidl code generator")

    shared = ["lib/libzzdds.so", "lib/libzzdds.dylib", "bin/zzdds.dll", "lib/zzdds.dll"]
    if not any((prefix / rel).is_file() for rel in shared):
        fail("bundle has no dynamic libzzdds (looked for: " + ", ".join(shared) + ")")

    log("structure: all required files present")


def check_relocatable(prefix: Path) -> None:
    pc = (prefix / "lib/pkgconfig/zzdds.pc").read_text()
    prefix_lines = [ln for ln in pc.splitlines() if ln.startswith("prefix=")]
    if not prefix_lines or not prefix_lines[0].startswith("prefix=${pcfiledir}"):
        fail(f"zzdds.pc prefix= is not ${{pcfiledir}}-relative: {prefix_lines}")

    cmake_cfg = (prefix / "lib/cmake/ZZDDS/zzdds-config.cmake").read_text()
    if "CMAKE_CURRENT_LIST_FILE" not in cmake_cfg:
        fail("zzdds-config.cmake does not derive its prefix from CMAKE_CURRENT_LIST_FILE")

    # No absolute build-time path may survive into the shipped metadata.
    needles = ["runner/work", "/home/", "/Users/", "\\Users\\", "zig-out"]
    for rel in ("lib/pkgconfig/zzdds.pc", "lib/cmake/ZZDDS/zzdds-config.cmake"):
        text = (prefix / rel).read_text()
        hits = [n for n in needles if n in text]
        if hits:
            fail(f"{rel} contains a baked-in absolute build path (matched {hits}) -- bundle is not relocatable")

    log("relocatable: pkg-config + CMake metadata derive prefix from their own location")


# ── step 3: bundled zidl runs ───────────────────────────────────────────────

def check_zidl_runs(prefix: Path) -> None:
    zidl = prefix / "bin" / ("zidl.exe" if (prefix / "bin/zidl.exe").is_file() else "zidl")
    proc = run([str(zidl), "--version"], capture=True, timeout=60)
    if proc.returncode != 0:
        fail(f"bundled `{zidl.name} --version` exited {proc.returncode}:\n{proc.stdout}")
    log(f"zidl: bundled generator runs -- {proc.stdout.strip()}")


# ── step 4/5: CMake consumers ───────────────────────────────────────────────

def cmake_configure(src: Path, build: Path, prefix: Path, extra: list[str] | None = None) -> None:
    proc = run(
        ["cmake", "-S", str(src), "-B", str(build), f"-DCMAKE_PREFIX_PATH={prefix}", *(extra or [])],
        capture=True, timeout=600,
    )
    if proc.returncode != 0:
        fail(f"cmake configure of {src} failed:\n{proc.stdout}")


def cmake_build(build: Path) -> None:
    proc = run(["cmake", "--build", str(build), "--parallel"], capture=True, timeout=1200)
    if proc.returncode != 0:
        fail(f"cmake build in {build} failed:\n{proc.stdout}")


def run_hello_world_pair(build_dir: Path, prefix: Path, domain: int) -> None:
    """Start the hello_world sub + pub built in build_dir, on `domain`, and
    require both to exit 0 with their success markers. The pair is designed
    for a clean handshake shutdown (see the example sources), so this does
    not need a settle timer -- just a generous ceiling."""
    def exe(name: str) -> str:
        for cand in (build_dir / name, build_dir / f"{name}.exe"):
            if cand.is_file():
                return str(cand)
        fail(f"{name} not found under {build_dir}")

    env = dict(os.environ)
    libdir = str(prefix / "lib")
    for var in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"):
        env[var] = libdir + (os.pathsep + env[var] if env.get(var) else "")

    sub = subprocess.Popen([exe("hello_world_sub"), "--domain", str(domain)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)
    time.sleep(0.5)
    pub = subprocess.Popen([exe("hello_world_pub"), "--domain", str(domain)],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env)

    deadline = time.monotonic() + 60
    outs: dict[str, str] = {}
    for name, proc in (("pub", pub), ("sub", sub)):
        remaining = max(1.0, deadline - time.monotonic())
        try:
            outs[name], _ = proc.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            proc.kill()
            outs[name], _ = proc.communicate()
            fail(f"hello_world {name} (domain {domain}) did not exit within the deadline:\n{outs[name]}")

    markers = {"pub": "Publisher: done.", "sub": "Subscriber: received all 10 samples in order."}
    for name, proc in (("pub", pub), ("sub", sub)):
        if proc.returncode != 0:
            fail(f"hello_world {name} (domain {domain}) exited {proc.returncode}:\n{outs[name]}")
        if markers[name] not in outs[name]:
            fail(f"hello_world {name} (domain {domain}) missing success marker {markers[name]!r}:\n{outs[name]}")
    log(f"hello_world pair (domain {domain}): pub + sub exchanged 10 samples and exited cleanly")


# ── step 6: pkg-config ──────────────────────────────────────────────────────

def check_pkgconfig(prefix: Path, work: Path) -> None:
    if not shutil.which("pkg-config"):
        log("pkg-config: not installed on this runner -- skipping (CMake path already covered)")
        return
    cc = os.environ.get("CC") or shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if not cc:
        log("pkg-config: no C compiler found -- skipping")
        return

    env = dict(os.environ)
    env["PKG_CONFIG_PATH"] = str(prefix / "lib/pkgconfig") + (
        os.pathsep + env["PKG_CONFIG_PATH"] if env.get("PKG_CONFIG_PATH") else "")

    def pc(*args: str) -> str:
        proc = subprocess.run(["pkg-config", *args, "zzdds"], env=env, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            fail(f"pkg-config {' '.join(args)} zzdds failed:\n{proc.stdout}")
        return proc.stdout.strip()

    version = pc("--modversion")
    cflags = pc("--cflags").split()
    libs = pc("--libs").split()
    log(f"pkg-config: zzdds {version}; cflags={cflags}; libs={libs}")

    out_bin = work / "pkgconfig_consumer"
    src = REPO_ROOT / "test/release-bundle/consumer.c"
    proc = run([cc, str(src), *cflags, *libs, "-o", str(out_bin)], capture=True, timeout=300)
    if proc.returncode != 0:
        fail(f"compiling consumer.c with pkg-config flags failed:\n{proc.stdout}")

    run_env = dict(os.environ)
    libdir = str(prefix / "lib")
    for var in ("LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"):
        run_env[var] = libdir + (os.pathsep + run_env[var] if run_env.get(var) else "")
    proc = subprocess.run([str(out_bin)], env=run_env, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    if proc.returncode != 0:
        fail(f"pkg-config consumer binary exited {proc.returncode}:\n{proc.stdout}")
    log(f"pkg-config: consumer binary ran -- {proc.stdout.strip()}")


# ── driver ─────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bundle", required=True, type=Path, help="path to the zzdds-<version>-<platform>.tar.gz bundle")
    ap.add_argument("--examples-dir", type=Path, default=REPO_ROOT / "examples",
                    help="path to the folded-in examples/ tree (default: <repo>/examples)")
    ap.add_argument("--configure-only", action="store_true",
                    help="stop after cmake-configuring the small consumer (no compiler / no run / no examples)")
    ap.add_argument("--skip-example-run", action="store_true",
                    help="build examples/{c,cpp}/hello_world against the bundle but do not run the "
                         "pub/sub pair (link coverage only; use where live UDP DDS discovery is flaky, "
                         "e.g. hosted macOS runners -- cmake_consumer still runs and loads libzzdds)")
    ap.add_argument("--work", type=Path, default=None, help="working directory (default: a fresh temp dir)")
    ap.add_argument("--keep", action="store_true", help="do not delete the working directory on exit")
    ap.add_argument("--domain-base", type=int, default=58,
                    help="base DDS domain for the hello_world pairs (uses base and base+1)")
    args = ap.parse_args()

    if not args.bundle.is_file():
        fail(f"bundle not found: {args.bundle}")

    work = args.work or Path(tempfile.mkdtemp(prefix="zzdds-verify-bundle-"))
    work.mkdir(parents=True, exist_ok=True)
    extract_root = work / "extracted"
    extract_root.mkdir(exist_ok=True)
    log(f"working directory: {work}")

    try:
        log(f"extracting {args.bundle.name} -> {extract_root}")
        with tarfile.open(args.bundle) as tf:
            if sys.version_info >= (3, 12):
                tf.extractall(extract_root, filter="data")
            else:
                tf.extractall(extract_root)  # noqa: S202 -- our own release artifact
        prefix = find_prefix(extract_root)
        log(f"bundle prefix: {prefix}")

        check_structure(prefix)
        check_relocatable(prefix)
        check_zidl_runs(prefix)

        cc_build = work / "cmake_consumer_build"
        cmake_configure(REPO_ROOT / "test/release-bundle/cmake_consumer", cc_build, prefix)
        if args.configure_only:
            log("--configure-only: stopping after the CMake consumer configure step")
            log("PASS")
            return 0
        cmake_build(cc_build)
        proc = subprocess.run([str(next(p for p in (cc_build / "zzdds_bundle_cmake_consumer",
                                                    cc_build / "zzdds_bundle_cmake_consumer.exe") if p.is_file()))],
                              text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
                              env={**os.environ, "LD_LIBRARY_PATH": str(prefix / "lib"),
                                   "DYLD_LIBRARY_PATH": str(prefix / "lib")})
        if proc.returncode != 0:
            fail(f"cmake_consumer binary exited {proc.returncode}:\n{proc.stdout}")
        log(f"cmake_consumer: ran -- {proc.stdout.strip()}")

        for i, name in enumerate(("c", "cpp")):
            example = args.examples_dir / name / "hello_world"
            if not (example / "CMakeLists.txt").is_file():
                fail(f"example project not found: {example}")
            build = work / f"hello_world_{name}_build"
            cmake_configure(example, build, prefix)
            cmake_build(build)
            if args.skip_example_run:
                log(f"hello_world ({name}): built against the bundle; --skip-example-run set, not running the pair")
            else:
                run_hello_world_pair(build, prefix, args.domain_base + i)

        check_pkgconfig(prefix, work)

        log("PASS")
        return 0
    finally:
        if args.keep:
            log(f"--keep: left working directory in place at {work}")
        else:
            shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
