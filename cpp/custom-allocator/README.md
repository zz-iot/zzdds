# zzdds custom-allocator C++ showcase — Milestones 1-3

A real, runnable proof that zzdds's C++ bindings support caller-controlled
allocation for embedded/real-time consumers: two small programs (`publisher`,
`subscriber`) that discover each other over real UDP DDS discovery and
exchange samples, with every allocation routed through a caller-supplied
fixed-size static-pool allocator (`src/static_pool_allocator.c`) instead of
libc `malloc`/`free`/`operator new` — both at the C-ABI level (factory/entity
bootstrap, via `zzdds_create_factory_with_allocator`) and at the C++ level
(wrapper objects via `zidl::setCppAllocator`'s `std::pmr` routing, and
`string`/`sequence` fields via `--cpp-pmr-containers`).

This is the C++ counterpart to `c/custom-allocator` — same sample
types, same acceptance test, same allocator, ported to idiomatic C++
(`std::shared_ptr` entities, `std::pmr::string`/`std::pmr::vector` fields).

**Milestone 1** — `SensorSample` is deliberately fully bounded (no unbounded
`string`/`sequence` field). `--cpp-pmr-containers` still makes the bounded
`label` field `std::pmr::string` (zidl's C++ backend has no fixed-capacity
string type), so "zero-heap" here means "routed through the caller-registered
`std::pmr` allocator," not "no allocation call at all."

**Milestone 2** — `SensorLog` (same IDL file) is deliberately *unbounded* (an
unbounded `string log_message` and `sequence<double> readings`), exercising
the C++/pmr backend's *decode-side* allocator story: decoding an unbounded
field means `std::pmr::vector::resize()`/`std::pmr::string` assignment
growing through whatever `std::pmr::memory_resource` was current when the
containing `Sample` was default-constructed — `zidl::setCppAllocator`'s
`std::pmr::set_default_resource` registration, **not**
`zidl_cdr_set_allocator` (that one only governs the CDR *writer*'s own
scratch-buffer growth here — a genuine divergence from the C showcase's
equivalent Milestone 2 finding, which hinges on `zidl_cdr_set_allocator` for
exactly this purpose; see the negative-control finding below). Both programs
write/read both types in one run.

## Build and run

Like the C example, zzdds's `build.zig.zon` currently points its `zidl`
dependency at a local path (`../zidl`) rather than a tagged release, since
several of the fixes below aren't in a zidl release yet. Build zzdds first:

```sh
cd /path/to/zzdds
zig build -Dcpp-binding=true
```

(Default build flags — `-Dinterface-monitor=false` is no longer required; see
Milestone 3.)

Then build this example, pointed at that `zig-out`:

```sh
mkdir -p build && cd build
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out ..
make
```

Then, in two terminals (or backgrounded):

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./subscriber &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./publisher
```

The publisher writes 10 `SensorSample` values and 5 `SensorLog` values; the
subscriber should report `received 10/10 samples, 5/5 logs` with matching
values.

## The zero-allocation acceptance test

Same mechanism as the C example: `src/noalloc_guard_preload.cpp` builds into
`libnoalloc_guard.so`, an `LD_PRELOAD` shim that interposes
`malloc`/`calloc`/`realloc`/`free` **and** global `operator new`/`operator
delete` (all four overloads: throwing, `nothrow`, array, sized-deallocation)
process-wide, aborting with a backtrace the moment any of them fire while
armed. Overriding `operator new`/`delete` directly — not just relying on
libstdc++'s default implementation happening to call `malloc` internally —
is what makes this a real test of "no C++ allocation at all", not just "no
libc allocation that C++ happens to route through."

Both programs arm the guard after setup and a discovery-settling delay,
exactly as in the C example (see that showcase's README for why: per-matched-
peer heartbeat threads still allocate via `std.heap.c_allocator`, a Zig
stdlib limitation, not something zzdds can route through the injected
allocator).

Run the acceptance test:

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib \
  LD_PRELOAD=$(pwd)/libnoalloc_guard.so \
  ./subscriber &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib \
  LD_PRELOAD=$(pwd)/libnoalloc_guard.so \
  ./publisher
```

Both should exit 0. Verified clean across 5+ repeated runs, plus negative
controls (below) confirming the test is actually meaningful, not vacuous.

### Two independent allocator registrations, two different lifetimes

```cpp
zidl_cdr_set_allocator(&static_pool_allocator);  // CDR writer/reader scratch buffers
zidl::setCppAllocator(&static_pool_allocator);   // C++ wrapper objects (std::pmr)
```

These matter on very different timelines, confirmed by two negative-control
runs (temporarily removing each call and re-running under the guard):

- **`zidl::setCppAllocator`** only affects **one-time entity construction**
  (`DomainParticipantImpl`, `TopicImpl`, `DataWriterImpl`, ...) — all of
  which happens during setup, before the guard arms. Removing it did **not**
  trip the guard in this showcase, because no new C++ wrapper objects are
  created in the steady-state loop. It's still necessary for a *complete*
  zero-libc-malloc claim (setup itself must not touch libc either), just not
  observable via this particular arm-after-setup test.
- **`zidl_cdr_set_allocator`** routes the CDR writer's buffer growth, which
  runs on **every single `write()` call** (each call starts a fresh
  `ZidlCdrWriter` at length 0). Removing it reliably aborted with a real
  `realloc()` backtrace from inside `DataWriter::write`, confirming this one
  *is* on the hot path and the test is genuinely exercising it.
- **Milestone 2 changes the picture for `zidl::setCppAllocator`**: unlike
  Milestone 1 (where no new C++ wrapper objects are constructed in the armed
  loop), Milestone 2's per-`take()` `SensorLogDataReader::Sample` — holding
  `std::pmr::string`/`std::pmr::vector` fields — is freshly default-constructed
  *inside* the armed loop on every iteration. Confirmed by a dedicated
  negative control: temporarily removing `zidl::setCppAllocator(&static_pool_allocator)`
  from `subscriber.cpp` and re-running under the guard reliably aborted
  (`free()` this time, not `operator new` — from `std::pmr`'s default
  fallback resource needing genuine heap teardown when a `std::pmr::string`
  assignment exceeds libstdc++'s small-string-optimization inline capacity);
  restoring it passes cleanly across repeated runs. Notably,
  `zidl_cdr_set_allocator` — the mechanism the *C* showcase's equivalent
  Milestone 2 finding hinges on — plays **no role** in this decode path for
  the C++/pmr backend: `ZidlCdrReader` reads from a caller-supplied stack
  buffer directly (no internal growth), and the `std::pmr` containers' own
  growth bypasses `zidl_cdr_alloc` entirely.

**Milestone 3** — a process-wide `zzdds.toml` (this directory) supplies a
`default_participant_config`. Same mechanism and same config file as the C
showcase; see that showcase's README for the full write-up (config-file
resolution now wired into the plain `create_participant()` path, replacing
the `-Dinterface-monitor=false` build flag). Confirmed identically here: both
exit 0 with a **default** zzdds build (no `-Dinterface-monitor=false`), and a
negative control (temporarily moving `zzdds.toml` aside) reliably trips the
guard on `getifaddrs()`.

Both programs also now call the new `zzdds::process_configure_from_file()`
(`zzdds_cpp.hpp`, a thin wrapper over the C-ABI's
`zzdds_process_configure_from_file`) with `&static_pool_allocator` before
`create_factory(&static_pool_allocator)` — closing what used to be the one
libc-`malloc` exception in the bootstrap path: the process-wide config
singleton used to always clone its own persistent storage through
`std.heap.c_allocator` internally, regardless of which allocator was
requested. See the C showcase's README ("Closing the config-resolution
bootstrap gap") for the full write-up of the underlying fix — it's shared,
allocator-honoring `config/process.zig` logic, not something specific to
either language binding. Verified here the same way: the existing guard test
still exits 0, and a new narrower check,
`bootstrap_noalloc_check` (`src/bootstrap_noalloc_check.cpp`), arms the guard
before doing anything at all and confirms
`process_configure_from_file` + `create_factory(allocator)` alone make zero
libc `malloc`/`operator new` calls — including a negative control (skipping
the `process_configure_from_file` call) that reliably trips it.

See the C showcase's README for the full, verified list of every other
pre-arm allocation source ("Why the guard doesn't arm immediately") — all of
it is shared Zig-core/C-ABI behavior, equally applicable here.

## Two real zidl C++ backend bugs found building this

1. **The C-ABI `handle` parameter fix (from the C showcase) was applied to
   `src/backend/c.zig` but not `src/backend/cpp.zig`.** When
   `zzdds_write_raw_kind`/`zzdds_write_raw_w_timestamp` gained a
   `DDS_InstanceHandle_t handle` parameter (see the C showcase's README,
   finding #1), the C++ backend's own three internal write-helper generators
   (`{Type}_write_kind`, `{Type}_write_kind_w_timestamp`,
   `{Type}_write_kind_w_hash` — the last used by `write_w_handle`/
   `dispose_w_handle`/`unregister_instance_w_handle`, which look up a cached
   key hash from a previously-registered `DDS_InstanceHandle_t`) still called
   the old 5/6-argument signatures, failing to compile. Fixed by adding the
   parameter to all three generators and threading it through every call
   site: `DDS_HANDLE_NIL` for the plain `write`/`dispose`/`unregister_instance`
   family (mirroring the C backend), and the caller's actual `handle` for the
   `_w_handle` family (where it's already been looked up and validated
   against the cached hash, and now also validated by the C-ABI itself).

2. **Found, not fixed (real API papercut, has a working alternative):**
   `create_datareader(std::shared_ptr<TopicDescription>, ...)`'s generated
   C-ABI adapter only tries `dynamic_cast<TopicDescriptionImpl*>` on its
   argument. `DDS::Topic : Entity, TopicDescription` at the abstract
   interface level, so `std::shared_ptr<Topic>` converts implicitly to
   `std::shared_ptr<TopicDescription>` and compiles fine — but the *concrete*
   `TopicImpl` class doesn't inherit from `TopicDescriptionImpl` (each
   concrete `DDS::*Impl` class implements exactly one interface's pure
   virtuals), so the `dynamic_cast` fails at runtime and throws
   `std::invalid_argument("zidl: incompatible entity implementation for
   DDS::TopicDescription")`. This is a structural limitation of zidl's
   dynamic-cast-based entity-parameter adaptation: it has no way to try
   every concrete class that implements a given interface, only the one
   its name literally maps to (`entityImplName`, `src/backend/cpp.zig`) —
   fixing it properly needs the interface-hierarchy information at codegen
   time, a bigger change than fits here. **Workaround used in
   `subscriber.cpp`**: call `dp->lookup_topicdescription("SensorTopic")`
   first — its own implementation re-wraps the same underlying handle as a
   genuine `TopicDescriptionImpl`, so the subsequent `dynamic_cast` in
   `create_datareader` succeeds. This is the real, intended pattern (the
   C++ analogue of the C API's `zzdds_topic_as_description()`), not a hack,
   but the *lack* of it being needed to compile-and-fail is a real trap for
   anyone who reasonably expects the public-inheritance upcast to just work.

## Other things learned while wiring this up

- `DomainParticipant`/`Topic`/`DataWriter`/`DataReader`'s **abstract**
  interfaces don't expose `native_handle()` — only the **concrete** `*Impl`
  classes do (`dcps_impl.hpp`, a public header). Getting the raw C-ABI handle
  needed for `{Type}TypeSupport::register_type(...)` and constructing a
  `{Type}DataWriter`/`{Type}DataReader` requires
  `std::static_pointer_cast<::DDS::DomainParticipantImpl>(dp)->native_handle()`
  (and the equivalent for `DataWriterImpl`/`DataReaderImpl`). Undocumented,
  but the only available path — worth zzdds documenting explicitly, or
  exposing a free helper function, since `dcps_impl.hpp` reads as an
  implementation-detail header a consumer might not think to reach for.
- `--generate-zzdds-wrappers`'s C++ output (unlike the C backend) generates
  convenience overloads without an explicit handle
  (`write(value)`/`dispose(key)`/`unregister_instance(key)`, defaulting to
  `DDS_HANDLE_NIL` internally) *and* explicit-handle overloads
  (`write_w_handle(value, handle)` etc.) that maintain their own
  `DDS_InstanceHandle_t → key hash` cache per `DataWriter` — nicer than the
  C API, which always requires passing a handle (even if `DDS_HANDLE_NIL`)
  explicitly.
- Unlike the C showcase's `SensorLog_free(&out)` (required after every
  `take()` to release decode-time heap allocations back to the pool), the
  C++/pmr backend needs **no** explicit free call: `std::pmr::string`/
  `std::pmr::vector`'s destructors release back to whichever
  `memory_resource` they were bound to at construction, automatically, as
  long as `zidl::setCppAllocator` was registered before that `Sample` was
  constructed. A genuine ergonomic win from routing unbounded fields through
  RAII containers instead of a C ABI's `_buffer`/`_length`/`_maximum`/
  `_release` struct.
