# cpp/participant-config

C++ port of `zig/participant-config` — see
[`docs/design/participant-config-reference-app.md`](../../docs/design/participant-config-reference-app.md)
at the repo root for what this example demonstrates and why (programmatic
vs. file-based participant configuration). This directory is just the
C++-specific build/run wiring.

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

Programmatic mode:

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/participant_config_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/participant_config_pub -d 42
```

File mode (TCP user-data transport):

```sh
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/participant_config_sub -d 42 --config ../../config/tcp-non-discovery.toml &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/participant_config_pub -d 42 --config ../../config/tcp-non-discovery.toml
```

`-d`/`--domain <id>` (default 0) and `--config <path>` are the only flags
either binary takes.

## Notes

- `factory->set_default_participant_config`/`get_default_participant_config`/
  `create_participant_ex` are called directly on `zzdds::create_factory()`'s
  return value — unlike `zzdds::DataWriter`/`Topic`, the factory interface
  already exposes zzdds's extension operations without any upcast, since
  `create_factory()` returns the extension view from the start.
- Despite `zzdds::DomainParticipantConfig`'s fields being idiomatic C++
  (`std::string`, not `char*`), this still crosses the same
  `zzdds_DomainParticipantFactory_*` C-ABI boundary `c/participant-config`
  does underneath — the C++ wrapper only changes what the *caller* sees, not
  which exported symbol actually gets called. See the design doc for why
  that distinction matters here specifically.
