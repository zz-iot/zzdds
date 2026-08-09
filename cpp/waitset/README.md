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
- Both `publisher.cpp` and `subscriber.cpp` branch on each held condition's
  own `get_trigger_value()` directly, not on membership in `wait()`'s
  returned `ConditionSeq` — see `publisher.cpp`'s top comment for why (a
  real, found-while-building identity gap: `wait()`'s generated C++ binding
  always re-wraps a returned `Condition` as the base `::DDS::ConditionImpl`,
  never recovering the more-derived type, so it can never
  `std::shared_ptr`-match the concrete condition objects this program
  already holds — `wait()`'s actual blocking behavior is still exercised for
  real either way).
- `QueryCondition`'s "priority > %0" expression is real (attach, trigger,
  `get_query_expression()`/parameters all genuinely exercised), but the
  actual high/low split is a plain field check after draining — no
  binding's C ABI has a `take_w_condition`-equivalent operation yet (see
  `subscriber.cpp`'s comment). `zig/waitset` has a Zig-native raw path to
  real query-scoped draining that this binding doesn't.
