# c/hello_world

C port of `zig/hello_world` — see
[`docs/design/hello-world-reference-app.md`](../../docs/design/hello-world-reference-app.md)
at the repo root for what this example demonstrates and why (keyless topic,
fixed RELIABLE/KEEP_ALL QoS, reader-ready-gated write loop). This directory
is just the C-specific build/run wiring.

Uses `c/custom-allocator`'s CMake + zidl-codegen pattern, the standard
template every C example in this repo follows for talking to zzdds.

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
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/hello_world_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/hello_world_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

## Notes

`src/publisher.c`/`src/subscriber.c` fetch each entity's default QoS via
`DDS_Publisher_get_default_datawriter_qos`/
`DDS_Subscriber_get_default_datareader_qos` and override just the fields
that matter (reliability, history) — the standard OMG DDS C-PSM idiom for
building a QoS struct, and the pattern every C example in this repo follows.
