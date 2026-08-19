# java/presence

Java port of `zig/presence` — see
[`docs/design/presence-reference-app.md`](../../docs/design/presence-reference-app.md)
at the repo root for what this example demonstrates and why (MANUAL_BY_TOPIC
liveliness, `assert_liveliness()`, `on_liveliness_changed`). This directory
is just the Java/JNI-specific build/run wiring.

Uses `java/hello_world`'s JNI build pattern (`build.py`/`run.py`,
`ZzddsRuntime`), plus the `DataWriterListenerEx` extension listener for
`on_reliable_reader_ready` (used only to gate the online-phase write loop
start, same as `hello_world`).

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
  Needs the LIVELINESS wire fixes (see the reference doc's "real, live bugs
  found" section) — a zzdds built before those land will build and run this
  example, but the offline/online cycle will hang.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run.py -d 42
```

or run `Subscriber`/`Publisher` as two separate JVM processes directly
(see `run.py` for the exact `java` invocation). `-d`/`--domain <id>`
(default 0) is the only flag either class takes. Total runtime ~13s
(dominated by the deliberate 5s offline pause).

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

Same `Presence_sample.PresenceBeacon` (not `PresenceBeacon.PresenceBeacon`)
outer-wrapper-class naming quirk as `java/hello_world`'s own note — zidl's
Java backend names the generated file's outer class from the IDL file's
stem (`presence_sample` → `Presence_sample`), separately from the struct's
own name.

`on_liveliness_changed`/`assert_liveliness()` are plain `DataReaderListener`/
`DataWriter` members — no `ZzddsRuntime` narrowing needed to reach either,
unlike `on_reliable_reader_ready`.
