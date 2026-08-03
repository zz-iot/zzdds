# zzdds custom-allocator C showcase — Milestones 1-3

A real, runnable proof that zzdds's C bindings support caller-controlled
allocation for embedded/real-time consumers: two small programs (`publisher`,
`subscriber`) that discover each other over real UDP DDS discovery and
exchange samples, with every allocation — factory/entity bootstrap *and* CDR
encode/decode — routed through a caller-supplied fixed-size static-pool
allocator (`src/static_pool_allocator.c`) instead of libc `malloc`/`free`.

**Milestone 1** — `SensorSample` (`idl/sensor.idl`) is deliberately fully
bounded (no unbounded `string`/`sequence` field), so it only needs the C-ABI
allocator bootstrap (`zzdds_create_factory_with_allocator`) — no CDR-level
allocator injection.

**Milestone 2** — `SensorLog` (same IDL file) is deliberately *unbounded* (an
unbounded `string log_message` and `sequence<double> readings`), exercising
Phase 2's read-side CDR allocator injection (`zidl_cdr_set_allocator`):
decoding an unbounded field requires a real, size-at-decode-time heap
allocation that only a registered allocator can keep off libc `malloc`. Both
programs write/read both types in one run. See zzdds's
`docs/design/allocator-strategy.md` for the full phased plan.

**Milestone 3** — a process-wide `zzdds.toml` (this directory) supplies a
`default_participant_config`. Both programs now call the new
`zzdds_process_configure_from_file()` explicitly, through the same
static-pool allocator used everywhere else, before creating their factory —
closing the one bootstrap allocation that used to always go through libc
`malloc` regardless of the allocator requested (see "Closing the
config-resolution bootstrap gap" below). This is both a regression test for
the C-ABI's use of zzdds's new TOML config support, and what closes the gap
finding #4 below used to describe: config-file resolution is now actually
wired into the plain `create_participant()` path.

## Build and run

Note: as of this writing, zzdds's `build.zig.zon` points its `zidl`
dependency at a local path (`../zidl`) rather than a tagged release, because
finding #1 below (the write-side allocator fix) isn't in a zidl release yet.
Build zzdds itself first:

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

Then, in two terminals (or backgrounded as below), pointed at a zzdds build's
`zig-out/lib`:

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./subscriber &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./publisher
```

The publisher writes 10 `SensorSample` values and 5 `SensorLog` values; the
subscriber should report `received 10/10 samples, 5/5 logs` with matching
values.

## The zero-allocation acceptance test

The claim "zero heap allocation after startup" is only meaningful if it's
falsifiable. `src/noalloc_guard_preload.c` builds into `libnoalloc_guard.so`,
an `LD_PRELOAD` shim that interposes `malloc`/`calloc`/`realloc`/`free`
process-wide (including calls made from inside `libzzdds.so` itself) and
aborts with a backtrace the moment any of them fire while "armed". Both
programs call `noalloc_guard_try_arm()` once their one-time setup and
discovery-settling window is done, right before entering the steady-state
write/read loop — and disarm before teardown (destroying the factory
legitimately frees memory).

Without `LD_PRELOAD` set, `noalloc_guard_try_arm()`/`_disarm()` are no-ops
(resolved via `dlsym(RTLD_DEFAULT, ...)`, which finds nothing) — the
executables run exactly as above, unguarded, for normal development.

To actually run the acceptance test, build zzdds with `-Dinterface-monitor=false`
(explained below — it's required for a clean run, not optional):

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

## Background threads are expected

Both programs spawn several real background threads (UDP receive, SPDP
announce timer, per-matched-reader heartbeat, network interface poll) — this
is inherent to two participants actually discovering and talking to each
other over the wire, not a gap in the allocator story. Thread *stacks* use
`mmap` directly, never libc `malloc`/`new` (see `allocator-strategy.md`).

## Real findings from building and guarding this showcase

Getting the `LD_PRELOAD` guard to pass cleanly and repeatably surfaced several
genuine gaps/constraints, not just showcase-app bugs.

1. **Fixed upstream (zidl + zzdds): the generated write path always
   heap-grew, and dropped two spec-implied things it shouldn't have.**
   `{Type}DataWriter_write()` (and `{Type}_compute_key_hash()`, called
   internally for every keyed write) both unconditionally used zidl-cdr's
   malloc/realloc-backed `zidl_cdr_writer_init()`.

   The DDS specification defines typed `FooDataWriter` operations via
   "implied IDL" — `write(in Foo instance_data, in InstanceHandle_t handle)`
   — and the IDL-to-C mapping covers how IDL *interface operations* become C
   functions, not just IDL *value types*. Two earlier iterations of this fix
   got that wrong: first by exposing a raw CDR buffer parameter (leaking an
   implementation detail the spec's model never mentions), then by silently
   dropping the `handle` parameter the spec (and real vendor DDS C APIs)
   actually provide — `handle` also has real value for callers who already
   hold a handle from `register_instance()`. Both were reverted.

   The actual fix has two parts:
   - **Allocator, not a guessed buffer size**: `zidl_cdr_realloc()` (new,
     `zidl-cdr/src/zidl_cdr.c`) routes the CDR writer's growth through
     whatever allocator `zidl_cdr_set_allocator()` has registered (same
     registration Phase 2 already built for the read side), falling back to
     libc `realloc` only if none is registered. `writer_grow_default` and
     `zidl_cdr_writer_deinit` now go through it. The generated write-family
     functions keep the original `zidl_cdr_writer_init()`/spec-shaped
     signature — no buffer parameter, no guessing a fixed size at codegen
     time. It's the calling application's job to register an allocator sized
     for whatever it serializes, exactly as it already must for every other
     allocation in this showcase.
   - **`DDS_InstanceHandle_t handle` restored**: `{Type}DataWriter_write`
     (and `_dispose`/`_unregister`, `_w_timestamp` variants) take `handle` in
     the spec's position (right after the data parameter). `zzdds_write_raw`/
     `_kind`/`_w_timestamp` (`zzdds/src/c_abi/bootstrap.zig`) now accept and
     validate it: `DDS_HANDLE_NIL` derives the instance from the key
     automatically; any other value must match what the key hashes to, or the
     call returns `DDS_RETCODE_BAD_PARAMETER`.

   `src/publisher.c` calls `zidl_cdr_set_allocator(&static_pool_allocator)`
   once at startup (alongside `zzdds_create_factory_with_allocator`) and
   `SensorSampleDataWriter_write(&typed_writer, &sample, DDS_HANDLE_NIL)` —
   genuinely zero heap, spec-shaped signature, no app-level workaround.

   **Found along the way (separate bug, also fixed):** every
   `zzdds_write_raw*` function was passing `history_mod.INSTANCE_HANDLE_NIL`
   for the *internal* per-instance grouping key that `HistoryCache`'s
   `KEEP_LAST` trimming uses (`trimForKeepLast`), instead of the sample's
   real key hash — collapsing every instance into one shared bucket for
   trimming purposes rather than trimming each instance independently. Fixed
   by passing `key_hash.*` there instead. Caveat: this governs the writer's
   own retransmission/late-join replay cache, which turned out to be
   separate from the reader's own live-delivery queue
   (`DataReaderImpl.pending`, populated directly on receipt) — so it isn't
   observable through the existing in-process `zzdds_take_n_raw`-based unit
   tests, and remains unverified by a fast automated test. A real check would
   need to exercise retransmission or late-joining-durable-reader replay
   specifically.

2. **Accepted exception: per-matched-peer heartbeat threads allocate via
   `std.heap.c_allocator`, unconditionally.** When SPDP/SEDP discovery
   matches a newly discovered remote participant, zzdds spawns a heartbeat
   thread via `std.Thread.spawn`. On Linux/glibc, Zig's own standard library
   (`Thread.zig`'s libc/pthread `Impl.spawn`) hardcodes
   `std.heap.c_allocator` for the small `Args` bookkeeping struct and
   silently ignores `SpawnConfig.allocator` entirely on this backend (only
   the WASI thread impl honors it) — there is no fix available in zzdds's own
   code for this specific allocation. It's a one-time, bounded,
   per-newly-discovered-peer cost though, not a per-sample hot-path one, so
   both programs arm the guard only after a short discovery-settling delay
   (mirroring the existing "wait for a matched reader" sleep).

3. **Fixed (zzdds build flag): the interface-poll monitor's `getifaddrs()`
   call mallocs internally, with no allocator hook at all.**
   `transport/monitor/polling.zig`'s `PollingMonitor` re-enumerates network
   interfaces every `interface_poll_interval_ms` (default 5000ms) to detect
   interface changes, calling libc's `getifaddrs()` — which allocates its
   result list via the process's global `malloc`, unconditionally; this is
   glibc's own implementation, entirely outside zzdds's or zidl's allocator
   story. Build zzdds with `-Dinterface-monitor=false` (an existing build
   flag that was defined but never actually wired to anything — also fixed
   as part of this work, in `src/transport/udp.zig`) to get interfaces
   enumerated once at startup only, with no periodic re-poll thread at all —
   the correct choice for a static-topology embedded deployment. Also added:
   `interface_poll_interval_ms = 0` is now a runtime sentinel with the same
   meaning (`src/transport/monitor/polling.zig`), for callers using
   `create_participant_ex()` with an explicit config struct.

4. **Fixed (zzdds): config-file resolution is now wired into the plain
   `create_participant()` C-ABI path.** This used to be a real gap —
   `factoryCreateParticipant` always passed the raw schema-default `Config{}`
   literal, never resolving a file — which is why earlier revisions of this
   showcase needed the `-Dinterface-monitor=false` *build* flag just to avoid
   `getifaddrs()`'s periodic `malloc`. `zzdds_create_factory_with_allocator()`
   now lazily resolves a process-wide `ProcessConfig` the first time it's
   called in a process (`src/config/process.zig`'s `getForNewFactory`), trying
   `./zzdds.toml` in the current working directory and falling back to
   defaults if it's absent — no explicit opt-in call needed. See Milestone 3
   and the config-file section below.

5. **Milestone 2 confirms Phase 2's read-side CDR allocator injection works
   end-to-end, and it's genuinely required, not just belt-and-suspenders.**
   `subscriber.c` calls `zidl_cdr_set_allocator(&static_pool_allocator)`
   before creating the participant (`publisher.c` already needed this for
   Milestone 1's write-side fix); `SensorSampleDataReader` never needed it
   since `SensorSample` has no unbounded fields to decode. Verified this is
   load-bearing, not accidental: temporarily removing the call and re-running
   under the guard reliably aborts with a real `malloc()` backtrace from the
   decode path; restoring it passes cleanly across repeated runs. Also a
   reminder of an existing contract, newly exercised here: decoded unbounded
   fields (`out.log_message`, `out.readings._buffer`) are heap-allocated by
   `SensorLogDataReader_take` and must be released with `SensorLog_free(&out)`
   after use, or every received sample leaks from the pool.

6. **Fixed (zzdds): the process-wide config singleton's persistent storage
   now honors the caller's own allocator, closing what used to be an
   accepted exception.** `config/process.zig`'s `ProcessConfig` singleton
   used to always clone into a fixed `std.heap.c_allocator`-backed
   `state_alloc`, regardless of which allocator was passed to `configure()`
   or to `zzdds_create_factory_with_allocator()` — a one-time, pre-arm
   libc `malloc` that no custom allocator could intercept. `configure()`
   (and the new `configureFromFile()`) now store the singleton through
   whichever allocator the caller actually gave them, and set `state_alloc`
   to match, so a later `resetForTesting()`/re-clone frees through the
   allocator that really owns the memory. The fully-*ambient* path
   (`getForNewFactory` when nobody ever calls `configure` first) still has
   no caller allocator to prefer, so it keeps the `std.heap.c_allocator`
   fallback — see the new C-ABI entry point below, which is what lets a
   caller avoid that fallback entirely.

   New C-ABI function: `zzdds_process_configure_from_file(path, allocator)`
   (`zzdds_c.h`) resolves `path` and installs it as the process-wide config
   in one step, entirely through `allocator`. Both `publisher.c` and
   `subscriber.c` now call this with `&static_pool_allocator` before
   creating their factory, closing the last libc-`malloc` exception in this
   showcase's bootstrap path. Verified two ways: (1) the existing guard
   test still exits 0 for both programs; (2) a new, narrower standalone
   check, `bootstrap_noalloc_check` (`src/bootstrap_noalloc_check.c`), arms
   the guard *before* doing anything at all, then does only
   `zzdds_process_configure_from_file` + `zzdds_create_factory_with_allocator`
   — proving this specific step is genuinely allocation-free, rather than
   relying on the main showcase's arm point (which was always well
   downstream of this code and wouldn't have caught a regression here). A
   negative control (temporarily skipping the `configure_from_file` call)
   reliably aborts that same check with a real `malloc()` backtrace
   straight into `zzdds_create_factory_with_allocator`'s ambient
   lazy-resolve path, confirming the check is meaningful, not vacuous.

   The `--zig-generate-toml-config`-shaped `ZZDDS.ProcessConfig`/
   `DomainParticipantConfig` types used internally (plain Zig structs with
   `[]const u8` fields) are a *different* representation from the public,
   `-b c`-generated `zzdds_ProcessConfig`/`zzdds_DomainParticipantConfig` C
   structs in `zzdds.h` (`char*` fields) — the two are generated by separate
   zidl invocations and aren't interchangeable. This is why the pre-existing
   `zzdds_process_configure(config)` C export was never actually safely
   callable from C (its parameter type has no C-ABI-constructible
   representation, and it isn't declared in `zzdds_c.h`) — left as-is,
   Zig-native/test-only, since `zzdds_process_configure_from_file` above is
   the real, supported entry point for a file-based config from C/C++.

## Config-file-driven, not build-flag-driven

`zzdds.toml` (this directory, copied by CMake into `build/` alongside the
binaries) sets `[default_participant_config.transport.udp]
interface_poll_interval_ms = 0` — `PollingMonitor`'s own runtime sentinel for
"no periodic re-poll thread at all" (see finding #3). This is what lets the
guard acceptance test below pass with a **default** zzdds build (no
`-Dinterface-monitor=false`): the same `libzzdds.so` build now supports both
"poll for interface changes" and "never re-poll" deployments, chosen at run
time via config instead of at compile time via a build flag.

Confirmed load-bearing with a negative control, not just eyeballed: temporarily
moving `zzdds.toml` out of the way and re-running the guard test reliably
aborts both programs with a real `malloc()` backtrace through `getifaddrs()`;
restoring the file passes cleanly across repeated runs. The file also sets
`[default_participant_config.participant] lease_duration_ms = 20000`, a second,
independent field (outside the transport/UDP struct) that reaches a real,
functionally-observable effect — SPDP lease expiry (`src/discovery/spdp.zig`)
— proving the config flows correctly end-to-end for more than one field/type.

Note: `interface_poll_interval_ms = 0` only suppresses the *periodic* re-poll
thread. `UdpTransport.init` still calls `getifaddrs()` once, unconditionally,
to enumerate interfaces at participant-creation time regardless of this
setting — see the list below, which is a one-time, pre-arm cost like
everything else there, not something the config file (or any allocator)
can eliminate.

## Why the guard doesn't arm immediately

Both programs wait until after factory/entity bootstrap and a short
discovery-settling delay before calling `noalloc_guard_try_arm()`. Verified
against the actual source (not assumed), here is everything that allocation
outside our control forces into that pre-arm window, from most to least
significant:

1. **`getifaddrs()`'s one-time interface enumeration** — glibc allocates its
   result list internally with no allocator hook at all (`transport/monitor/polling.zig`).
   Runs exactly once per participant, at creation time, regardless of
   `interface_poll_interval_ms` (see the note above) — a real, unavoidable
   libc `malloc`, just no longer a *recurring* one.
2. **Per-matched-peer heartbeat thread spawn** — `std.Thread.spawn`'s
   bookkeeping (`Args` struct) is hardcoded to `std.heap.c_allocator` on
   Zig's libc/pthread backend; `SpawnConfig.allocator` is silently ignored
   there. One-time per newly-discovered remote participant, not per-sample —
   why both programs sleep briefly after entity creation before arming, to
   let SPDP/SEDP matching settle first.
3. **Type registration** (`zzdds_register_type_support_c`, once per
   registered type) — allocates a small, fixed-size `CKeyHashAdapter` via
   `std.heap.c_allocator` unconditionally (`c_abi/typesupport.zig`), never
   routed through the participant's own configured allocator. Both programs
   register two types (`SensorSample`, `SensorLog`) before arming.
4. **The process-wide config bootstrap** — now avoidable (see above), but
   only if the app calls `zzdds_process_configure_from_file` itself before
   creating its first factory; the ambient/lazy path still falls back to
   `std.heap.c_allocator` for whichever factory resolves it first.
5. **Nil-singleton C-ABI handle boxes** (`dcps/nil.zig`) — a handful of
   pointer-sized boxes for nil sentinel objects, cached via
   `std.heap.c_allocator`, created at most once per process regardless of
   entity/traffic count. Documented in `docs/design/allocator-strategy.md`
   as "not worth solving" — genuinely negligible, not scaling with anything.
6. **`stdio`'s own lazy buffer setup** — glibc allocates an internal stdout
   buffer on first use unless preempted; both programs call `setvbuf` with a
   static (not `malloc`'d) buffer before doing anything else specifically to
   avoid this.

None of these scale with sample count or traffic — each is bounded and fires
at most once per process (interface enumeration and type registration: once
per participant/type; heartbeat spawn: once per newly-discovered peer) — so
arming after setup, rather than from process start, is the correct
"steady-state, not literally-zero-ever" definition of the claim this showcase
makes (see `docs/design/allocator-strategy.md`'s "Definition of 'zero
malloc'"). `bootstrap_noalloc_check` (see above) proves the one exception
that *was* avoidable — the config bootstrap — actually is, when handled
explicitly.

**A related, separate gap, not hit by either program here:** `zzdds_take_n_raw`/
`zzdds_read_n_raw`, `zzdds_take_loaned_raw`, and the `ZZDDS::DataReader`
extension interface's `take_serialized`/`take_next_instance_serialized`
(`c_abi/extensions.zig`, `c_abi/bootstrap.zig`) all unconditionally allocate
their returned sample buffer(s) via `std.heap.c_allocator`, regardless of any
registered allocator — a real per-*call* cost, on whatever path calls them.
This showcase never hits it because `zzdds_take_one_raw`/
`_take_one_raw_instance` (what the generated `{Type}DataReader_take` wrappers
here actually call) take a caller-supplied buffer instead and allocate
nothing beyond a transient, already-configured-allocator-routed internal
copy. A consumer reaching for the array/loaned/serialized-CDR APIs on an
actual per-sample hot path would not get the same guarantee this showcase
demonstrates — worth knowing if extending this pattern to those APIs.
