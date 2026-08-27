# java/registry

Java port of `zig/registry` — see
[`docs/design/registry-reference-app.md`](../../docs/design/registry-reference-app.md)
at the repo root for what this example demonstrates and why (explicit
`register_instance`/`write_w_timestamp`/`dispose`/`unregister`,
`get_key_value`, `lookup_instance`). This directory is just the
Java/JNI-specific build/run wiring.

Uses `java/hello_world`'s JNI build pattern (`build.py`/`run.py`,
`ZzddsRuntime`), plus the `DataWriterListenerEx` extension listener for
`on_reliable_reader_ready` (used only to gate the drain wait at the end,
same as `hello_world`).

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
  Needs the `Sample.instanceState` JNI fix (see the reference doc's "real,
  live bugs found" section) — without it, `take()`'s returned `Sample`
  never carries a real `instance_state`, which this example's whole
  premise depends on.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run.py -d 42
```

or run `Subscriber`/`Publisher` as two separate JVM processes directly
(see `run.py` for the exact `java` invocation). `-d`/`--domain <id>`
(default 0) is the only flag either class takes. Fully deterministic —
runs in well under a second once matched.

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

Same `Registry_sample.SensorReading` (not `SensorReading.SensorReading`)
outer-wrapper-class naming quirk as `java/hello_world`'s own note.
`write_w_timestamp`/`dispose_w_timestamp`/`unregister_w_timestamp` take raw
`(int sec, int nanosec)` rather than a `Time_t`-shaped object, unlike
Zig/C/C++'s equivalents. `Sample.instanceState` is the raw
`SampleInfo.instance_state` bitmask value (compare against
`Dcps.DDS.ALIVE_INSTANCE_STATE.value`/etc., same `.value` idiom every other
generated Java constant uses) — see `Sample.UNKNOWN_INSTANCE_STATE`'s own
doc comment for which other `SensorReadingDataReader` methods don't (yet)
populate it.
