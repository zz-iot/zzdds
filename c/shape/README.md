# c/shape

C port of the OMG DDS-Interoperability "Shapes" demo app, talking to zzdds
through its C ABI (`zzdds_c.h` + the zidl-generated `ShapeTypeDataWriter`/
`ShapeTypeDataReader` wrappers), using `c/custom-allocator`'s CMake/zidl
codegen pattern. One binary, `-P`/`-S` selects publisher/subscriber mode —
matching the CLI/behavior spec and the dds-rtps interop harness convention of
one binary path handed to both roles (see `zig/shape`, the authoritative
reference this was written fresh against, and
`docs/design/shape-reference-app.md` at the repo root for the full plan).

**This is a fresh implementation, not a port of anything in dds-rtps** (no
working zzdds C shape port existed there to adapt — see the design doc's
investigation). It implements the design doc's "Must-have (v1)" CLI/QoS
subset plus `--config`, **not** the stretch flags (deadline, lifespan,
ownership strength, XCDR representation selection via `-x`, partition,
multi-instance/multi-topic, additional-payload/size-modulo, content
filtering, presentation/coherent access, take/read-only). Run `zig/shape
-h` for the full spec these stretch flags belong to.

## Prerequisites

Same as `c/custom-allocator`: a zzdds checkout built with the C binding:

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

`-h`/`--help` lists the implemented flags. Expected output matches
`zig/shape`'s: publisher prints `Create topic:` → `Create writer for
topic:` → (once a reader matches) `on_publication_matched()`, then one
`COLOR    COLOR     xxx yyy [size]` line per write when `-w` is passed;
subscriber prints `Create topic:` → `Create reader for topic:`, then one
line per received sample.

## Config-file support (`--config <path>`)

Same mechanism as `c/custom-allocator`'s Milestone 3:
`zzdds_process_configure_from_file(path, NULL)`, called before
`zzdds_create_factory()`. See `zig/shape`'s README for the full explanation
and `zzdds-examples/config/` for the example scenario files — verified
working here too (`custom-ports.toml` binds port 20010 instead of the
default 7410, and interoperates correctly with a `zig/shape` peer using the
same file).

## Verified cross-binding against zig/shape

Both directions (C publisher ↔ Zig subscriber, Zig publisher ↔ C
subscriber) exchange samples correctly, including with non-default flags
(`-b` best-effort, `-k 0` keep-all, custom topic/color, `-z 0` auto-
increment size) and with `--config custom-ports.toml` on both sides.

**Found and fixed via this cross-binding testing, not by inspection**: this
port originally left `DataWriterQos`/`DataReaderQos`'s `data_representation`
field as a zero-value (empty) sequence. `zig/shape` always explicitly offers
a one-element `[XCDR_DATA_REPRESENTATION]` sequence regardless of the (here
unimplemented) `-x` flag — an empty sequence is DATAREPRESENTATION-
*incompatible* with that under zzdds's QoS matching, so every C↔Zig pair
failed to match (`on_offered_incompatible_qos() ... : 23
(DATAREPRESENTATION)`) until `build_writer_qos`/`build_reader_qos` were
fixed to explicitly set it too (see `shape_main.c`'s
`set_default_representation`).

**Also found, not fixed here (separate, zzdds-core, out of scope)**:
`DDS_DataWriterQos_default`/`DDS_DataReaderQos_default` are declared in
`dcps.h` but not actually exported by `libzzdds.so` (confirmed via
`nm -D libzzdds.so`) — this port zero-initializes QoS structs directly
instead (equivalent, since `dcps.idl` declares no `@default` annotations
for any QoS policy field), but a caller that actually calls those functions
will get a link error.
