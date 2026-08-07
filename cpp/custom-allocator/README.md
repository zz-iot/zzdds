# cpp/custom-allocator

A real, runnable demonstration of zzdds's C++ support for caller-controlled
allocation — useful for embedded/real-time consumers that can't allow
unbounded heap use. Two small programs (`publisher`, `subscriber`) discover
each other over real UDP DDS discovery and exchange samples, with every
allocation routed through a caller-supplied fixed-size static-pool allocator
(`src/static_pool_allocator.c`) instead of libc `malloc`/`free`/`operator
new` — both at the C-ABI level (factory/entity bootstrap, via
`zzdds_create_factory_with_allocator`) and at the C++ level (wrapper objects
via `zidl::setCppAllocator`'s `std::pmr` routing, and `string`/`sequence`
fields via `--cpp-pmr-containers`).

This is the C++ counterpart to `c/custom-allocator` — same sample types,
same acceptance test, same allocator, ported to idiomatic C++
(`std::shared_ptr` entities, `std::pmr::string`/`std::pmr::vector` fields).

Two sample types show two different allocation shapes:

- **`SensorSample`** is fully bounded (no unbounded `string`/`sequence`
  field). `--cpp-pmr-containers` still makes its bounded `label` field a
  `std::pmr::string` (zidl's C++ backend has no fixed-capacity string type),
  so "zero-heap" here means "routed through the caller-registered
  `std::pmr` allocator," not "no allocation call at all."
- **`SensorLog`** (same IDL file) is unbounded (`string log_message` and
  `sequence<double> readings`), exercising the decode-side allocator path:
  decoding an unbounded field grows a `std::pmr::vector`/`std::pmr::string`
  through whatever `std::pmr::memory_resource` was current when the
  containing `Sample` was default-constructed (`zidl::setCppAllocator`'s
  `std::pmr::set_default_resource` registration — not
  `zidl_cdr_set_allocator`, which only governs the CDR writer's own
  scratch-buffer growth). Both programs write/read both types in one run.

## Build and run

```sh
cd /path/to/zzdds
zig build -Dcpp-binding=true install
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

## The zero-allocation acceptance test

`src/noalloc_guard_preload.cpp` builds into `libnoalloc_guard.so`, an
`LD_PRELOAD` shim that interposes `malloc`/`calloc`/`realloc`/`free` **and**
global `operator new`/`operator delete` (all four overloads) process-wide,
aborting with a backtrace the moment any of them fire while armed —
overriding `operator new`/`delete` directly is what makes this a real test
of "no C++ allocation at all," not just "no libc allocation that C++
happens to route through."

Both programs arm the guard after setup and a short discovery-settling
delay — per-matched-peer heartbeat threads still allocate via
`std.heap.c_allocator`, a Zig stdlib limitation not routable through the
injected allocator, so arming immediately at startup would be a false
failure, not a real one.

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

### Two independent allocator registrations, two different lifetimes

```cpp
zidl_cdr_set_allocator(&static_pool_allocator);  // CDR writer/reader scratch buffers
zidl::setCppAllocator(&static_pool_allocator);   // C++ wrapper objects (std::pmr)
```

- **`zidl::setCppAllocator`** governs one-time entity construction
  (`DomainParticipantImpl`, `TopicImpl`, `DataWriterImpl`, ...), all of
  which happens during setup, and also governs any C++ wrapper object
  constructed later — e.g. `SensorLogDataReader::Sample`, freshly
  default-constructed on every `take()` in the steady-state loop, whose
  `std::pmr::string`/`std::pmr::vector` fields need this registration to
  avoid falling back to libstdc++'s default heap resource.
- **`zidl_cdr_set_allocator`** routes the CDR writer's buffer growth, which
  runs on every `write()` call (each call starts a fresh `ZidlCdrWriter` at
  length 0). It plays no role in the C++/pmr decode path — `ZidlCdrReader`
  reads from a caller-supplied stack buffer directly, and the `std::pmr`
  containers' own growth bypasses it entirely.

Unlike the C showcase's `SensorLog_free(&out)` (required after every
`take()`), the C++/pmr backend needs no explicit free call:
`std::pmr::string`/`std::pmr::vector`'s destructors release back to
whichever `memory_resource` they were bound to at construction,
automatically.

## Config-file bootstrap (`zzdds.toml`)

A process-wide `zzdds.toml` (this directory) supplies a
`default_participant_config` — same mechanism as `c/custom-allocator`; see
that example's README for the general config-file explanation. Both
programs call `zzdds::process_configure_from_file()` (`zzdds_cpp.hpp`, a
thin wrapper over the C-ABI's `zzdds_process_configure_from_file`) with
`&static_pool_allocator` before `create_factory(&static_pool_allocator)`,
so config resolution itself also stays off the libc heap.
