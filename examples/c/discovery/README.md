# c/discovery

C port of `zig/discovery` — see
[`docs/design/discovery-reference-app.md`](../../docs/design/discovery-reference-app.md)
at the repo root for what this example demonstrates and why. This
directory is just the C-specific build/run wiring.

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
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/discovery_sub -d 42 &
sleep 1
LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib ./build/discovery_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

## Notes

- Calls `DDS_DomainParticipant_get_discovered_topic_data`/
  `DDS_DataWriter_get_matched_subscription_data`/`DDS_DataReader_get_
  matched_publication_data` directly against the C-ABI struct shapes
  declared in `dcps.h` — unlike `zig/discovery`, which never crosses the C
  ABI at all. See the design doc for why that distinction matters here
  specifically (the C-ABI mirror-struct fix this example regression-tests).
- `DDS_TopicBuiltinTopicData_default()`/`DDS_SubscriptionBuiltinTopicData_
  default()`/`DDS_PublicationBuiltinTopicData_default()` seed a struct with
  its IDL-declared defaults before first use, same idiom as
  `participant-config`'s `zzdds_DomainParticipantConfig_default()`.
- Each of these three operations frees the caller's *previous* struct
  content before writing new content on every call (same "free old, write
  new" contract `get_default_participant_config` uses) — no manual
  free/reset is needed between repeated calls in a loop, only a final
  `DDS_*BuiltinTopicData_free()` once the returned strings are done being
  read.
