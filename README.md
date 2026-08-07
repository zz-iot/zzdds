# zzdds-examples
A repository of examples for Zenzen DDS

## Layout

One top-level directory per binding language, one subdirectory per example
within it:

```
zig/
  hello_world/        minimal pub/sub, native Zig API, no C ABI
  shape/              configurable pub/sub (see docs/design/shape-reference-app.md)
c/
  hello_world/        C port of zig/hello_world
  shape/              C port of zig/shape
  custom-allocator/   zero-heap-allocation pub/sub over real UDP discovery
cpp/
  hello_world/        C++ port of zig/hello_world
  shape/              C++ port of zig/shape
  custom-allocator/   C++ version of c/custom-allocator
  opencv_zzdds/       video capture -> ROI detection -> display over DDS, using OpenCV
java/
  hello_world/        Java port of zig/hello_world
  shape/              Java port of zig/shape
  listener-pubsub/    pub/sub over real UDP discovery, exercising the JNI listener path
interop/
  cross-binding-smoke-test.sh          C and C++ custom-allocator interop
  shape-cross-binding-smoke-test.sh    all 12 ordered pairs of the 4 shape ports

run-all.sh   builds+runs everything above at once, skipping what your zzdds build doesn't support
```

`docs/design/` has a short "what this demonstrates" reference for
`hello_world` and `shape` shared across all four language ports — see
those before diving into a specific language's README.

Every example builds against a local zzdds checkout — none of these are
released/tagged against a specific zzdds version, or pinned via a git
submodule. Point everything at whatever local `zig build ... install` tree
you want to test. If you just want a known-good baseline rather than testing
your own local zzdds, `ZZDDS_VERSION` names the zzdds commit these examples
are last confirmed to fully pass against.

Build zzdds first with whatever bindings you need — `run-all.sh` (below)
detects which of these you actually built and skips accordingly, so it's
fine to only build what you're testing:

```sh
cd /path/to/zzdds
zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install
```

Then see each example's own README for exact prerequisites and run steps.

## Config file library

`config/` holds a handful of standalone `zzdds.toml`-style scenarios
(`ipv4-only.toml`, `ipv6-only.toml`, `tcp-non-discovery.toml`,
`unicast-only.toml`, `custom-ports.toml`, `short-lease.toml`) that any
binding's `--config <path>` support can point at, to reproduce/isolate a
reported interop or config-resolution bug without writing new code each
time. Each file has a top comment describing exactly what it isolates and
why. All four `shape` ports (`zig/shape`, `c/shape`, `cpp/shape`,
`java/shape`) support `--config`; see each one's own README for how it's
wired up (Java uses an MVP copy-trick rather than a direct call -- see
`java/shape/README.md`).

## Running everything at once

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run-all.sh
```

Builds and runs every example and smoke test below in one pass. Whatever
that zig-out wasn't built to support (a missing binding, missing OpenCV) is
**skipped**, not failed — e.g. a c-binding-only zzdds build just skips the
cpp/java/interop sections and still exits 0. That's the right default for a
human pointing this at whatever they happened to build.

For CI wired into zzdds's own pipeline, pass `--strict` instead: every skip
becomes a hard failure, so a change to zzdds's build flags that accidentally
drops a binding these examples need shows up as a red CI run instead of a
silently-shrinking test surface. A real build/run failure is always a
failure, in both modes — `--strict` only changes how a *missing
prerequisite* is treated.

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run-all.sh --strict
```

## Building everything for one language

`run-all.sh` covers all of this at once; the commands below are the same
work broken out per language, for when you only want one of them:

Each example is a self-contained build unit (own `CMakeLists.txt` in
c/cpp, own `build.sh`/`run.sh` in java), but each language directory also has
a single entrypoint that builds every example under it in one shot:

```sh
# C
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B c/build -S c
cmake --build c/build

# C++ (opencv_zzdds is skipped automatically if OpenCV isn't installed)
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B cpp/build -S cpp
cmake --build cpp/build

# Java
cd java
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build_all.sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run_all.sh
```

Zig examples are plain `zig build` packages with no shared aggregator —
build each one directly (see `zig/hello_world/README.md` /
`zig/shape/README.md`):

```sh
cd zig/hello_world && zig build
cd zig/shape && zig build
```

## CI-friendly execution checks

Also covered by `run-all.sh`. Building everything is necessary but not
sufficient — these actually run each example and check for correct output,
no camera/display/hardware required:

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./interop/cross-binding-smoke-test.sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./interop/shape-cross-binding-smoke-test.sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./cpp/opencv_zzdds/smoke-test.sh
```
