# cpp/waitset

C++ port of `zig/waitset` — see
[`docs/design/waitset-reference-app.md`](../../docs/design/waitset-reference-app.md)
at the repo root for what this example demonstrates and why (WaitSet-driven
flow instead of listeners, all four condition types on one WaitSet, a
background watchdog thread for a real concurrency exercise). This directory
is just the C++-specific build/run wiring.

Uses `cpp/hello_world`'s CMake pattern (the "three-artifact model": zzdds's
own pre-generated `dcps_impl.cpp`/`zzdds_impl.cpp` plus per-type generated
files, all compiled directly by the consumer).

## Prerequisites

A local `zzdds` checkout built with the C++ binding:

```sh
cd /path/to/zzdds
zig build -Dcpp-binding=true install
```

## Build and run

```sh
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S .
cmake --build build
```

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/waitset_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/waitset_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

## Notes

- Real C++ polymorphism means `GuardCondition`/`StatusCondition`/
  `ReadCondition`/`QueryCondition` upcast to `Condition` (and
  `QueryCondition` to `ReadCondition`) implicitly via `std::shared_ptr`'s own
  conversion — `ws->attach_condition(sc)` just works, no equivalent of
  `zig/waitset`'s `statusAsCondition()`-style workaround needed.
- Both `publisher.cpp` and `subscriber.cpp` branch on membership in `wait()`'s
  returned `ConditionSeq`, the spec-idiomatic pattern — a held `shared_ptr`
  (e.g. `std::shared_ptr<::DDS::Condition> gc_cond = gc;`, an implicit upcast)
  is `==`-comparable against what `wait()` returns for the same underlying
  condition. This used to be impossible even after the raw-C-ABI-handle
  identity fix landed: `wait()`'s generated C++ binding boxes every returned
  `Condition` via the base class's own `_getOrCreate`, which historically
  kept its own independent identity cache per concrete class — a real,
  C++-wrapper-layer gap on top of the C-ABI-level one, closed by collapsing
  every condition-family (and entity-family) sibling's cache into one shared
  per-family cache, plus registering `GuardCondition` into it on construction
  (it has no generated `_getOrCreate` of its own) — see zidl's
  `docs/roadmap.md` "Binding design review: decision" and its
  "shared-family `_getOrCreate` cache" follow-up. Verified directly against
  the fixed zzdds (rebuilt, both binaries rerun clean, twice) before
  switching to the membership-based form here — including through
  `qc_cond`'s two-level `QueryCondition` → `ReadCondition` → `Condition`
  upcast, the deepest chain the fix covers.
- `QueryCondition`'s "priority > %0" expression is real (attach, trigger,
  `get_query_expression()`/parameters all genuinely exercised), but the
  actual high/low split is a plain field check after draining — no
  binding's C ABI has a `take_w_condition`-equivalent operation yet (see
  `subscriber.cpp`'s comment). `zig/waitset` has a Zig-native raw path to
  real query-scoped draining that this binding doesn't.
