# zig/discovery

Exercises zzdds's DDS-standard discovery introspection operations, talking
to zzdds's native Zig API directly — no C ABI, no code generation shim in
between. See
[`docs/design/discovery-reference-app.md`](../../docs/design/discovery-reference-app.md)
at the repo root for the full spec. The `c/`, `cpp/`, and `java/discovery`
ports exercise the same operations through their respective C-ABI/JNI
bindings.

Two separate binaries (`discovery_pub`, `discovery_sub`), matching
`hello_world`'s convention:

- The publisher calls `DomainParticipant.get_discovered_topics`/
  `get_discovered_topic_data` right after creating its topic (a
  locally-created topic is visible immediately, no remote peer needed), then
  — once a reliable reader is ready — `DataWriter.get_matched_subscriptions`/
  `get_matched_subscription_data`.
- The subscriber waits for a matched publication, then calls
  `DataReader.get_matched_publications`/`get_matched_publication_data`.

Both sides assert the discovered/matched data's `topic_name`/`type_name`
match what was actually created, then run the same minimal reliable
write/read loop (3 samples, `DiscoveryPing`) as `hello_world`, to prove the
participant/writer/reader still work end-to-end.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/discovery_pub` and `zig-out/bin/discovery_sub`.

```sh
./zig-out/bin/discovery_sub -d 42 &
sleep 1
./zig-out/bin/discovery_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

Expected output: `Discovery OK (participant): ...` right after topic
creation on the publisher side, `Discovery OK (writer): ...` once matched,
`Discovery OK (reader): ...` on the subscriber side once matched, then the
same `hello_world`-shaped sequence (`Create topic:` → `Create writer/reader
for topic:` → 3 samples → `Publisher: done.` / `Subscriber: received all 3
samples in order.`). Both exit 0.

## Notes

- `topic_data`/`subscription_data`/`publication_data`'s string fields
  (`name`, `topic_name`, `type_name`) are *borrowed* slices owned by zzdds
  internally, valid for the matched entity's lifetime — unlike
  participant-config's `DomainParticipantConfig` round-trip, nothing here is
  caller-owned, so nothing is `.deinit()`'d. See the design doc for why the
  C/C++/Java ports differ here (their C-ABI mirror conversion always
  allocates an owned copy, which callers must free).
- This is a pure-Zig call path (`dp.get_discovered_topic_data(...)`,
  dispatched through the interface's own vtable) — it never crosses the C
  ABI's exported `DDS_DomainParticipant_get_discovered_topic_data`-style
  wrapper functions the way the C/C++/Java ports necessarily do. Expect this
  port to pass even when the others don't (see the design doc's bug
  writeup).

## Prerequisites

Same as `zig/hello_world`: Zig 0.16.0, a local `zzdds` checkout built as a
sibling of `zzdds-examples` (`../../../zzdds`).
