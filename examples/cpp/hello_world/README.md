# cpp/hello_world

C++ port of `zig/hello_world` — see
[`docs/design/hello-world-reference-app.md`](../../docs/design/hello-world-reference-app.md)
at the repo root for what this example demonstrates and why (keyless topic,
fixed RELIABLE/KEEP_ALL QoS, reader-ready-gated write loop). This directory
is just the C++-specific build/run wiring.

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

## Build and run

```sh
cmake -DCMAKE_PREFIX_PATH=/path/to/zzdds/zig-out -B build -S .
cmake --build build
```

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/hello_world_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/hello_world_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

## Notes

Entities returned by zzdds's factory methods (`create_topic`,
`create_datawriter`, ...) are really instances of zzdds's own extended
`zzdds::detail::*Support` classes, which publicly derive from the matching
`zzdds::*Impl` extension class. That's what makes
`std::static_pointer_cast<zzdds::DataWriterImpl>(dw)->set_listener_ex(...)`
(used in `publisher.cpp` to install `on_reliable_reader_ready`) a real,
valid upcast rather than a cast between unrelated types — `set_listener_ex`
is a zzdds extension not part of the plain `DDS::DataWriter` interface, so
reaching it needs that cast. `native_handle()` (used to get the raw handle
each generated `HelloWorldDataWriter`/`HelloWorldDataReader` wrapper
constructor needs) is a plain virtual on every entity interface and doesn't
need any cast at all.
