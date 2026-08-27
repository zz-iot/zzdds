# java/catchup

Java port of `zig/catchup` — see
[`docs/design/catchup-reference-app.md`](../../docs/design/catchup-reference-app.md)
at the repo root for what this example demonstrates and why (TRANSIENT_LOCAL
durability, late-joining subscriber, `wait_for_historical_data()`). This
directory is just the Java/JNI-specific build/run wiring.

Uses `java/hello_world`'s JNI build pattern (`build.py`/`run.py`,
`ZzddsRuntime`).

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run.py -d 42
```

`run.py` deliberately starts `Publisher` first and `Subscriber` second
(with a short pause between) — the reverse of every other example in this
repo — since the whole point is a subscriber that joins *after* the
publisher has already written its historical batch. See `zig/catchup`'s
own README for the same note on running the two binaries directly.

`-d`/`--domain <id>` (default 0) is the only flag either class takes.

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

Same `Catchup_sample.HistoryEvent` (not `HistoryEvent.HistoryEvent`)
outer-wrapper-class naming quirk as `java/hello_world`'s own note.
`wait_for_historical_data(Dcps.DDS.Duration_t)` is a plain
`DataReader` member — no `ZzddsRuntime` narrowing needed.
