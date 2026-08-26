# cpp/registry

C++ port of `zig/registry` — see
[`docs/design/registry-reference-app.md`](../../docs/design/registry-reference-app.md)
at the repo root for what this example demonstrates and why (explicit
`register_instance`/`write_w_timestamp`/`dispose`/`unregister_instance`,
`get_key_value`, `lookup_instance`). This directory is just the
C++-specific build/run wiring.

Uses `cpp/custom-allocator`'s CMake pattern (the "three-artifact model"),
the standard template every C++ example in this repo follows.

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
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/registry_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/registry_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.
Fully deterministic — runs in well under a second once matched.

## Notes

Unlike the Zig/C typed-writer ports, the generated C++
`SensorReadingDataWriter` tracks each instance's handle internally
(`instance_handles_`, keyed by key hash) — `write()`/`dispose()`/
`unregister_instance()` take just the sample/key, no explicit handle
parameter, resolving it internally. `_w_handle` variants exist for when
you already have one and want to skip that lookup; this example uses the
plain forms throughout except where it needs the handle explicitly
(`register_instance()`'s own return value, used for the `get_key_value()`
round-trip check). `get_key_value(handle, key_out)` takes the handle
*first*, key output *second* — the reverse parameter order from
`zig/registry`'s `get_key_value(key_holder_ptr, handle)`.
