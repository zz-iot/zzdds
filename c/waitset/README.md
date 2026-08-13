# c/waitset

C port of `zig/waitset` — see
[`docs/design/waitset-reference-app.md`](../../docs/design/waitset-reference-app.md)
at the repo root for what this example demonstrates and why (WaitSet-driven
flow instead of listeners, all four condition types on one WaitSet, a
background watchdog thread for a real concurrency exercise). This directory
is just the C-specific build/run wiring.

Uses `c/hello_world`'s CMake + zidl-codegen pattern.

## Prerequisites

A local `zzdds` checkout built with the C binding:

```sh
cd /path/to/zzdds
zig build -Dc-binding=true install
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

- Both `publisher.c` and `subscriber.c` branch on membership in `wait()`'s
  returned `DDS_ConditionSeq`, the spec-idiomatic pattern — a held handle
  (e.g. `DDS_GuardCondition_as_DDS_Condition(gc)`) is `==`-comparable
  against what `wait()` returns for the same underlying condition. This used
  to require branching on each condition's own `get_trigger_value()`
  directly instead, working around a real identity gap in `WaitSet.wait()`'s
  handling of boxed C-ABI handles (confirmed at the raw C-ABI level, not
  specific to any one binding) — see zidl's `docs/roadmap.md` "Binding
  design review: decision" for the bug and its fix (zidl/zzdds, 2026-08-12).
  Verified directly against the fixed zzdds (rebuilt, both binaries rerun
  clean, twice) before switching to the membership-based form here —
  including through `qc_cond`'s two-level `QueryCondition` →
  `ReadCondition` → `Condition` upcast, the deepest chain the fix covers.
- `QueryCondition`'s `"priority > %0"` expression is real (attach, trigger,
  and its query-expression/parameters are all genuinely exercised), but the
  actual high/low split is a plain field check after draining — see
  `subscriber.c`'s comment (no binding's C ABI has a
  `take_w_condition`-equivalent operation yet).
