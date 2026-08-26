# participant-config example — what it demonstrates

A pub/sub example built around zzdds's participant/factory-level
configuration APIs — the knobs that sit outside standard DDS QoS entirely
(transport selection, RTPS fragment size, SPDP timing, ...). Per
`zzdds/docs/design/dcps-api-coverage-audit.md` and this project's own
roadmap, `create_participant_ex`/`set_default_participant_config`/
`get_default_participant_config` had **zero** cross-language exercise
anywhere in this project before this example — every existing use of them
(`zig/shape`, `dds-rtps`'s zzdds port) is a pure-Zig call that never
crosses the C ABI. This example exists specifically to close that gap, and
it found a serious, previously-undiscovered bug doing so (see below).

Where `hello_world` is reliability-focused and `presence` is
liveliness-focused, this is the first example centered on *how a
participant itself gets configured*, not on the QoS of what it publishes
or subscribes.

## The type

```idl
@appendable
struct ConfigPing {
    int32 count;
};
```

Topic name `ConfigPing`. Deliberately minimal, like `hello_world` and
`presence` — this example is about participant/factory configuration, not
the data type, so the type stays out of the way.

## Two mutually exclusive modes

**Programmatic (default, no `--config`)**: builds a
`DomainParticipantConfig` value in the binding's own idiom, round-trips it
through `set_default_participant_config`/`get_default_participant_config`
(asserting the value read back matches what was set — the one thing this
example actually asserts programmatically), then creates the participant
via `create_participant_ex` using that same config.

Two fields are set, deliberately spanning two different kinds of struct
member: `participant.name` (a plain `string` field) and `rtps.fragment_size`
(a `uint16` scalar in an otherwise all-primitive nested struct). A mismatch
in either is unambiguous about which kind of field broke — see "Real, live
bug found" below for why that distinction mattered in practice.

**File (`--config <path>`)**: loads a zzdds.toml-style file via
`zzdds_process_configure_from_file` (or the pure-Zig
`zzdds.process_config.configureFromFile` for `zig/participant-config`)
before the factory is created, then creates the participant the plain way.
Every port's README points this at
`zzdds-examples/config/tcp-non-discovery.toml` — a real, concrete,
demoable feature (user-data traffic moves to TCP while discovery stays on
UDP), not just a knob for its own sake.

The two modes are mutually exclusive by design in `c`/`cpp`/`java`
(documented in each `--help`, a clear error if both are given) —
`zzdds_process_configure_from_file` can only run once per process, and
composing arbitrary user TOML with a generated programmatic override is
more machinery than this example warrants. `zig/participant-config` is the
one port that *does* compose them (starting from
`get_default_participant_config`'s current result before overriding, a
pure-Zig call with no ABI-crossing risk) — see its own README.

Both modes then run the same minimal reliable write/read loop (3 samples)
as `hello_world`, to prove the configured participant actually works
end-to-end, not just that it was constructed.

## Publisher / subscriber flow

Both processes: create the participant per the active mode (see above) →
register `ConfigPing`'s TypeSupport → topic → writer or reader → wait for
the reliable-reader-ready handshake (writer) or just the data (reader) →
exchange 3 samples → shutdown-gate on the matched count returning to zero
(same idiom as `hello_world`).

Required stdout markers: `Create topic:`, `Create writer/reader for
topic:`, 3× `Publisher: wrote count=` / `Subscriber: received count=`,
`Publisher: done.` / `Subscriber: received all 3 samples in order.`.
Programmatic mode additionally prints `Config round-trip OK:
participant.name='...' rtps.fragment_size=...` before either side creates
its participant.

## Real, live bug found building this example — fixed and released

**Update (2026-08-20): fixed and released.** The programmatic round-trip
check passes cleanly on all four bindings (`zig`, `c`, `cpp`, `java`).
zidl's C-ABI mirror-struct fix shipped in zidl `v0.3.7-zig.0.16.0`
(zidl PR #41); `zzdds`'s `build.zig.zon` now pins that release. Verified
against the real pinned release, not just a local checkout: the full
3-sample pub/sub exchange passes end-to-end on `c`/`cpp`/`java`, not just
the round-trip assertion in isolation. The fix and its verification are
written up in `zzdds/docs/roadmap.md`. The account below of the original
bug is kept for reference.

Originally, the programmatic round-trip check crashed or failed on
`c`/`cpp`/`java`; only `zig/participant-config` passed cleanly (a pure-Zig
call, verified never to cross the C ABI). This was not a bug in the
example — it is exactly what this example was built to surface, and it
did:

**`create_participant_ex`/`set_default_participant_config`/
`get_default_participant_config`'s exported C-ABI symbols use zzdds's
internal Zig-native `DomainParticipantConfig` type (which carries a hidden
`_toml_applied` bookkeeping field on every struct in the tree, added when
zzdds gained TOML-file config loading) as their parameter type — not the
plain struct the public `zzdds.h` header actually declares and every
C/C++/Java caller necessarily builds against.** Confirmed via this example
across all three affected bindings, each failing a different way:

- **C / C++**: `set_default_participant_config` returns
  `RETCODE_OUT_OF_RESOURCES` — the misaligned read produces a garbage
  string length for `participant.name`, and the resulting allocation
  attempt inside `DomainParticipantConfig.clone()` fails cleanly rather
  than crashing.
- **Java**: a hard JVM segfault inside `zzdds_DomainParticipantConfig_free`
  (`StringSeq.deinit`), called from `set_default_participant_config`'s own
  JNI wrapper as post-call cleanup. Confirmed to be the *same* root cause,
  not a separate JNI-specific bug: `zzdds_jni.c`'s generated glue code is
  itself C, compiled against the same public `zzdds.h` header C/C++ use —
  so it builds the identical, incorrectly-shaped struct before crossing
  into the same broken exported symbol.

Full root-cause writeup, the exact affected operations (these three, plus
`get_discovered_topic_data`/`get_matched_publication_data`/
`get_matched_subscription_data` — see the `discovery` example), and
candidate fixes are in `zzdds/docs/roadmap.md`. **Deliberately not fixed as
part of building this example** — the fix belongs in zidl's C-ABI codegen,
not in application code, and this example's job was to prove the bug and
give the eventual fix a concrete, cross-language regression test, not to
work around it.

One prerequisite bug had to be fixed first to get this far at all: Java's
JNI marshaling for `@optional` scalar struct fields (`UdpConfig`'s
port/participant-id fields, reachable from `DomainParticipantConfig`) used
the wrong method descriptor and crashed on a NULL `jmethodID` before ever
reaching the bug above — fixed in zidl (`src/backend/java.zig`), with a
regression test, released in the same `v0.3.7-zig.0.16.0` bundle as the
fix above (see the roadmap entry for that fix specifically).

## Deliberately out of scope

Fixing the ABI bug itself (see above). Composing `--config` with the
programmatic check in `c`/`cpp`/`java` (see "Two mutually exclusive modes"
above). A `run.py`-style automated harness comparing pass/fail across all
four bindings — worth adding once the underlying bug is fixed and the
programmatic mode reliably passes everywhere, so the harness has a
meaningful green baseline to protect rather than an expected-red one.

See each language's own README (`zig/participant-config`,
`cpp/participant-config`, `c/participant-config`,
`java/participant-config`) for build and run instructions.
