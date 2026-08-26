# c/participant-config

C port of `zig/participant-config` — see
[`docs/design/participant-config-reference-app.md`](../../docs/design/participant-config-reference-app.md)
at the repo root for what this example demonstrates and why (programmatic
vs. file-based participant configuration). This directory is just the
C-specific build/run wiring.

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

- Programmatic mode calls `zzdds_DomainParticipantFactory_set_default_
  participant_config`/`_get_default_participant_config`/
  `_create_participant_ex` directly against the C-ABI struct declared in
  `zzdds.h` — unlike `zig/participant-config`, which never crosses the C
  ABI at all. See the design doc for why that distinction matters here
  specifically.
- `zzdds_DomainParticipantConfig_default()` seeds every field with its
  IDL-declared default before this example overrides
  `participant.name`/`rtps.fragment_size` — the same "seed defaults, then
  override just what matters" idiom `hello_world`/`shape` use for QoS
  structs.
