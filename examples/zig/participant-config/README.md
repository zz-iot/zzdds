# zig/participant-config

Exercises zzdds's participant/factory-level configuration APIs, talking to
zzdds's native Zig API directly — no C ABI, no code generation shim in
between. See
[`docs/design/participant-config-reference-app.md`](../../docs/design/participant-config-reference-app.md)
at the repo root for the full spec. The `c/`, `cpp/`, and
`java/participant-config` ports exercise the same two operations through
their respective C-ABI/JNI bindings.

Two separate binaries (`participant_config_pub`, `participant_config_sub`),
matching `hello_world`'s convention, each supporting two mutually exclusive
modes:

- **Programmatic (default, no `--config`)**: builds a
  `zzdds.ZZDDS.DomainParticipantConfig` value in-process, round-trips it
  through `set_default_participant_config`/`get_default_participant_config`
  (asserting the value read back matches what was set), then creates the
  participant via `create_participant_ex` using that same config.
- **File (`--config <path>`)**: loads a zzdds.toml-style file via
  `zzdds.process_config.configureFromFile` before the factory is created,
  then creates the participant the plain way. Point this at
  `../../config/tcp-non-discovery.toml` to see user-data traffic move to
  TCP while discovery stays on UDP.

Both modes then run the same minimal reliable write/read loop (3 samples,
`ConfigPing`) as `hello_world`, to prove the configured participant
actually works end-to-end, not just that it was constructed.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/participant_config_pub` and
`zig-out/bin/participant_config_sub`.

Programmatic mode:

```sh
./zig-out/bin/participant_config_sub -d 42 &
sleep 1
./zig-out/bin/participant_config_pub -d 42
```

File mode (TCP user-data transport):

```sh
./zig-out/bin/participant_config_sub -d 42 --config ../../config/tcp-non-discovery.toml &
sleep 1
./zig-out/bin/participant_config_pub -d 42 --config ../../config/tcp-non-discovery.toml
```

`-d`/`--domain <id>` (default 0) and `--config <path>` are the only flags
either binary takes.

Expected output — programmatic mode: `Config round-trip OK: ...` before
either binary creates its participant, then the same `hello_world`-shaped
sequence (`Create topic:` → `Create writer/reader for topic:` → 3 samples
→ `Publisher: done.` / `Subscriber: received all 3 samples in order.`).
File mode: the same sequence without the round-trip line. Both exit 0.

## Notes

- The round-trip check sets two fields spanning two different failure
  modes this is designed to catch: `participant.name` (a plain string
  field) and `rtps.fragment_size` (a scalar field in an otherwise
  all-primitive nested struct) — see the design doc for why both matter.
- This is a pure-Zig call path (`factory.toZZDDSFactory().set_default_
  participant_config(...)`, dispatched through the interface's own vtable)
  — it never crosses the C ABI's exported `zzdds_DomainParticipantFactory_*`
  wrapper functions the way the C/C++/Java ports necessarily do. Expect
  this port to pass even when the others don't.

## Prerequisites

Same as `zig/hello_world`: Zig 0.16.0, a local `zzdds` checkout built as a
sibling of `zzdds-examples` (`../../../zzdds`).
