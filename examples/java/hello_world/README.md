# java/hello_world

Java port of `zig/hello_world` — see
[`docs/design/hello-world-reference-app.md`](../../docs/design/hello-world-reference-app.md)
at the repo root for what this example demonstrates and why (keyless topic,
fixed RELIABLE/KEEP_ALL QoS, reader-ready-gated write loop). This directory
is just the Java/JNI-specific build/run wiring.

Uses `java/listener-pubsub`'s JNI build pattern (`build.py`/`run.py`,
`ZzddsRuntime`), plus the `DataWriterListenerEx` extension listener (see
`zzdds/test/bindings/smoke/JavaSmoke.java` for another example of the same
pattern) to implement `on_reliable_reader_ready`.

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run.py -d 42
```

or run `Subscriber`/`Publisher` as two separate JVM processes directly
(see `run.py` for the exact `java` invocation). `-d`/`--domain <id>`
(default 0) is the only flag either class takes.

`build.py` accepts a `ZIDL_EXECUTABLE` override if you want to generate
against a different `zidl` build than the one bundled with your zzdds
checkout:

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out \
ZIDL_EXECUTABLE=/path/to/zidl/zig-out/bin/zidl \
./build.py
```

## Notes

zidl's Java backend names the generated file's outer wrapper class from the
IDL file's stem (`hello_world` → `Hello_world`), separately from the
struct's own name (`HelloWorld`, used directly for `HelloWorldDataWriter`/
`HelloWorldDataReader`/`HelloWorldTypeSupport`). So a sample is constructed
as `Hello_world.HelloWorld`, not `HelloWorld.HelloWorld` — an easy thing to
trip over the first time, hence this note.
