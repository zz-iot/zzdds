# cpp/shape

C++ port of the OMG DDS-Interoperability "Shapes" demo — see
[`docs/design/shape-reference-app.md`](../../docs/design/shape-reference-app.md)
at the repo root for what this example demonstrates, the full CLI reference,
and how config-file support works. This directory is just the C++-specific
build/run wiring.

One binary, `-P`/`-S` selects publisher/subscriber mode — same convention as
`c/shape` and `zig/shape`. Uses `cpp/custom-allocator`'s CMake pattern (the
same three-artifact model as `cpp/hello_world`).

## Prerequisites

A zzdds checkout built with the C++ binding (which also needs the C
binding, since C++ still reaches through some C-ABI pieces):

```sh
cd /path/to/zzdds
zig build -Dc-binding=true -Dcpp-binding=true install
```

## Build and run

```sh
mkdir -p build && cd build
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out ..
make
```

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./shape_main -S --read-period 200 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./shape_main -P --write-period 200 -w
```

`-h`/`--help` lists every flag.

## Config-file support (`--config <path>`)

`zzdds::process_configure_from_file(path, nullptr)`, called before
`zzdds::create_factory()` — see the design doc and `zzdds-examples/config/`
for the example scenario files.

## Notes

Every entity's `native_handle()` (used throughout to bridge into the
generated `ShapeTypeDataWriter`/`ShapeTypeDataReader` wrapper classes) is a
plain virtual on the abstract interface — call it directly on whatever
`shared_ptr<DDS::...>` a factory method returned, no cast needed.
