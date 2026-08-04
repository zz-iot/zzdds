# cpp/shape

C++ port of the OMG DDS-Interoperability "Shapes" demo app, talking to
zzdds through its native C++ API (`dcps.hpp`/`dcps_impl.hpp`'s shared_ptr-
based entity model, `zzdds_cpp.hpp`), using `cpp/custom-allocator`'s CMake/
zidl codegen pattern (the same three-artifact model: shared lib + zzdds's
pre-generated `dcps_impl.cpp`/`zzdds_impl.cpp` + this example's own generated
`shape_cdr.cpp`). One binary, `-P`/`-S` selects publisher/subscriber mode —
same convention as `c/shape` and `zig/shape` (see there, and
`docs/design/shape-reference-app.md` at the repo root for the full plan).

**Fresh implementation, not a port of anything in dds-rtps** (no working
zzdds C++ shape port existed there — see the design doc's investigation).
Same scope as `c/shape`: implements the design doc's "Must-have (v1)" CLI/
QoS subset plus `--config`, not the stretch flags. Run `zig/shape -h` for
the full spec those belong to.

## Prerequisites

Same as `cpp/custom-allocator`: a zzdds checkout built with the C++ binding
(which also needs the C binding, since C++ still reaches through some C-ABI
pieces):

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

`-h`/`--help` lists the implemented flags; output/behavior matches
`c/shape`/`zig/shape` exactly (see their READMEs for the expected output
shape).

## Config-file support (`--config <path>`)

Same mechanism as `cpp/custom-allocator`: `zzdds::process_configure_from_file(path, nullptr)`,
called before `zzdds::create_factory()`. See `zig/shape`'s README for the
full explanation and `zzdds-examples/config/` for the example scenario
files — verified working here too (`custom-ports.toml` binds port 20010
instead of the default 7410).

## Verified cross-binding

All four ordered pairs among Zig/C/C++ exchange samples correctly:
C++→Zig, Zig→C++, C→C++, C++→C. The one real bug found while building this
suite (a `DataWriterQos`/`DataReaderQos.data_representation` compatibility
mismatch against zig/shape's default) was found and fixed in `c/shape`
first — porting the same `set_default_representation` fix here up front
meant C++↔Zig and C++↔C both worked on the first cross-binding run, with no
new interop bugs. See `c/shape`'s README for that finding's full writeup.
