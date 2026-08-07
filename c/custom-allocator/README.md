# c/custom-allocator

A runnable demonstration of zzdds's C support for caller-controlled
allocation — useful for embedded/real-time consumers that can't allow
unbounded heap use. Two small programs (`publisher`, `subscriber`) discover
each other over real UDP DDS discovery and exchange samples, with every
allocation routed through a caller-supplied fixed-size static-pool allocator
(`src/static_pool_allocator.c`) instead of libc `malloc`/`free`.

Two sample types show two different allocation shapes:

- **`SensorSample`** (`idl/sensor.idl`) is fully bounded (no unbounded
  `string`/`sequence` field) — it only needs the factory/entity-bootstrap
  allocator (`zzdds_create_factory_with_allocator`).
- **`SensorLog`** (same IDL file) has an unbounded `string log_message` and
  `sequence<double> readings` — decoding those fields needs a real,
  size-at-decode-time heap allocation, which is why `zidl_cdr_set_allocator`
  is also registered. Both programs write/read both types in one run.

## Build and run

```sh
cd /path/to/zzdds
zig build -Dc-binding=true install
```

```sh
mkdir -p build && cd build
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out ..
make
```

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./subscriber &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./publisher
```

The publisher writes 10 `SensorSample` values and 5 `SensorLog` values; the
subscriber reports `received 10/10 samples, 5/5 logs` with matching values.

`SensorLogDataReader_take`'s decoded sample owns heap memory for its
unbounded fields — call `SensorLog_free(&out)` after use, or each received
sample leaks from the pool.

## The zero-allocation acceptance test

`src/noalloc_guard_preload.c` builds into `libnoalloc_guard.so`, an
`LD_PRELOAD` shim that interposes `malloc`/`calloc`/`realloc`/`free`
process-wide (including calls from inside `libzzdds.so` itself) and aborts
with a backtrace the moment any of them fire while armed. Both programs call
`noalloc_guard_try_arm()` after setup and a short discovery-settling delay —
DDS participant discovery spawns some background threads and does a
one-time network-interface enumeration that aren't yet routed through the
custom allocator, so arming immediately at process start would report a
false failure. Without `LD_PRELOAD` set, the arm/disarm calls are no-ops and
the binaries run exactly as above.

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib \
  LD_PRELOAD=$(pwd)/libnoalloc_guard.so \
  ./subscriber &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib \
  LD_PRELOAD=$(pwd)/libnoalloc_guard.so \
  ./publisher
```

Both should exit 0.

## Config-file bootstrap (`zzdds.toml`)

`zzdds.toml` (this directory, copied by CMake next to the built binaries)
supplies a `default_participant_config`. Both programs call
`zzdds_process_configure_from_file("zzdds.toml", &static_pool_allocator)`
before creating their factory, so config resolution itself also stays off
the libc heap. See the file's own comments for what each setting does.
