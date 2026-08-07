# c/shape

C port of the OMG DDS-Interoperability "Shapes" demo — see
[`docs/design/shape-reference-app.md`](../../docs/design/shape-reference-app.md)
at the repo root for what this example demonstrates, the wire type, and the
full CLI/config-file overview. This directory is just the C-specific
build/run wiring.

Talks to zzdds through its C ABI (`zzdds_c.h` + the zidl-generated
`ShapeTypeDataWriter`/`ShapeTypeDataReader` wrappers), using
`c/custom-allocator`'s CMake + zidl codegen pattern. One binary; `-P`/`-S`
selects publisher/subscriber mode.

Content filtering (`--cft`) is automatic at the reader layer — no app-side
re-checking needed; zzdds's own CFT evaluator does the filtering once
`TypeSupport` is registered with a `get_field_from_cdr` callback (already
wired up in `src/shape_main.c`).

## Prerequisites

A zzdds checkout built with the C binding:

```sh
cd /path/to/zzdds
zig build -Dc-binding=true install
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

`-h`/`--help` lists every flag. Publisher output: `Create topic:` → `Create
writer for topic:` → (once a reader matches) `on_publication_matched()`,
then one `COLOR    COLOR     xxx yyy [size]` line per write when `-w` is
passed. Subscriber output: `Create topic:` → `Create reader for topic:`,
then one line per received sample.

## Config-file support (`--config <path>`)

Same mechanism as `c/custom-allocator`: `zzdds_process_configure_from_file(path, NULL)`,
called before `zzdds_create_factory()`. See the design doc above and
`zzdds-examples/config/` for the example scenario files.
