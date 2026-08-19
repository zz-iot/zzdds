# zig/presence

LIVELINESS QoS reference app, talking to zzdds's native Zig API directly.
See [`docs/design/presence-reference-app.md`](../../docs/design/presence-reference-app.md)
at the repo root for what this example demonstrates and why (MANUAL_BY_TOPIC
liveliness, `assert_liveliness()`, `on_liveliness_changed`). The `c/`,
`cpp/`, and `java/presence` ports do the same thing through their respective
C-ABI/JNI bindings.

Two separate binaries (`presence_pub`, `presence_sub`), matching
`hello_world`'s convention.

## Build and run

```sh
zig build
```

Produces `zig-out/bin/presence_pub` and `zig-out/bin/presence_sub`.

```sh
zig build run-sub -- -d 42 &
sleep 1
zig build run-pub -- -d 42
```

or run the binaries directly:

```sh
./zig-out/bin/presence_sub -d 42 &
sleep 1
./zig-out/bin/presence_pub -d 42
```

`-d`/`--domain <id>` (default 0) is the only flag either binary takes.

Expected output — publisher: `Create topic:` → `Create writer for topic:` →
`on_reliable_reader_ready() is_ready=true` → 8 `Publisher: wrote sequence=`
lines → `Publisher: going offline (no writes/asserts for 5s, lease is 2s)`
→ (5s pause) → `Publisher: asserting liveliness and resuming` → 8 more
`Publisher: wrote sequence=` lines → `Publisher: done.` Subscriber: `Create
topic:` → `Create reader for topic:` → `ONLINE alive_count=1` →
`OFFLINE alive_count=0` → `ONLINE alive_count=1` → `Subscriber: observed
full online -> offline -> online cycle.` Both exit 0. Total runtime ~13s
(dominated by the deliberate 5s offline pause).

## Notes

- `LivelinessQosPolicy{ kind: MANUAL_BY_TOPIC_LIVELINESS_QOS, lease_duration:
  2s }` on both sides — see the reference doc for why MANUAL_BY_TOPIC rather
  than AUTOMATIC (zzdds's DEADLINE/LIVELINESS timer thread already drives
  AUTOMATIC without any app involvement, which would make "going offline"
  something that just happens rather than something this example
  demonstrates).
- `DataWriter.assert_liveliness()` is the one API call this example exists
  to exercise — it's what brings the writer back `ONLINE` after the
  deliberate quiet period, rather than resuming writes alone (which would
  also work, since write() implicitly asserts liveliness too, but wouldn't
  demonstrate the explicit API).

## Prerequisites

Same as `zig/hello_world`: Zig 0.16.0, a local `zzdds` checkout built as a
sibling of `zzdds-examples` (`../../../zzdds`).
