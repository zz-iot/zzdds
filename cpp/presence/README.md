# cpp/presence

C++ port of `zig/presence` — see
[`docs/design/presence-reference-app.md`](../../docs/design/presence-reference-app.md)
at the repo root for what this example demonstrates and why
(MANUAL_BY_TOPIC liveliness, `assert_liveliness()`, `on_liveliness_changed`).
This directory is just the C++-specific build/run wiring.

Uses `cpp/custom-allocator`'s CMake pattern (the "three-artifact model":
zzdds's own pre-generated `dcps_impl.cpp`/`zzdds_impl.cpp` plus per-type
generated files, all compiled directly by the consumer) — the standard
template every C++ example in this repo follows for talking to zzdds.

## Prerequisites

A local `zzdds` checkout built with the C++ binding:

```sh
cd /path/to/zzdds
zig build -Dcpp-binding=true install
```

Needs a zzdds with the LIVELINESS wire fixes (see the reference doc's
"real, live bugs found" section) — a zzdds built before those land will
build and run this example, but the offline/online cycle will hang.

## Build and run

```sh
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S .
cmake --build build
```

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/presence_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/presence_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.
Total runtime ~13s (dominated by the deliberate 5s offline pause).

## Notes

Same `zzdds::detail::*Support`/`static_pointer_cast<zzdds::DataWriterImpl>`
pattern as `cpp/hello_world` for reaching `set_listener_ex` (needed for
`on_reliable_reader_ready`, used here only to gate the online-phase write
loop start, same as `hello_world`). `on_liveliness_changed` and
`assert_liveliness()`, by contrast, are plain `DDS::DataReaderListenerBase`/
`DDS::DataWriter` members — no cast needed to reach either.
