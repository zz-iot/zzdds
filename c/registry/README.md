# c/registry

C port of `zig/registry` — see
[`docs/design/registry-reference-app.md`](../../docs/design/registry-reference-app.md)
at the repo root for what this example demonstrates and why (explicit
`register_instance`/`write_w_timestamp`/`dispose`/`unregister`,
`get_key_value`, `lookup_instance`). This directory is just the
C-specific build/run wiring.

Uses `c/custom-allocator`'s CMake + zidl-codegen pattern, the standard
template every C example in this repo follows.

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
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/registry_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/registry_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.
Fully deterministic — runs in well under a second once matched.

## Notes

Named `SensorReadingDataWriter_unregister`/`_unregister_w_timestamp`, not
`_unregister_instance`/`_unregister_instance_w_timestamp` — zidl's C
backend shortens the generated name for these two specifically, unlike
`register_instance`/`dispose`, which keep their full DDS-spec-idiom names.
Easy to trip over the first time (an IDE's autocomplete on
`SensorReadingDataWriter_unregister` is the fastest way to notice), hence
this note.
