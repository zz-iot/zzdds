# cpp/discovery

C++ port of `zig/discovery` — see
[`docs/design/discovery-reference-app.md`](../../docs/design/discovery-reference-app.md)
at the repo root for what this example demonstrates and why. This
directory is just the C++-specific build/run wiring.

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
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/discovery_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/discovery_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

## Notes

- Despite `::DDS::TopicBuiltinTopicData`/`SubscriptionBuiltinTopicData`/
  `PublicationBuiltinTopicData`'s fields being idiomatic C++ (`std::string`,
  not `char*`) and `::DDS::InstanceHandleSeq` being a plain
  `std::vector<::DDS::InstanceHandle_t>`, this still crosses the same
  C-ABI boundary `c/discovery` does underneath — the C++ wrapper only
  changes what the *caller* sees (fully RAII, nothing to free manually),
  not which exported symbol actually gets called. See the design doc for
  why that distinction matters here specifically.
