# java/shape

Java port of `zig/shape` — see
[`docs/design/shape-reference-app.md`](../../docs/design/shape-reference-app.md)
at the repo root for what this example demonstrates, the `ShapeType`
definition, and the CLI overview. This directory is just the Java/JNI-
specific build/run wiring.

One class, `ShapeMain`; `-P`/`-S` selects publisher/subscriber mode (run
twice, once per role), matching the other three bindings' single-binary
convention rather than `java/listener-pubsub`'s separate
`Publisher.java`/`Subscriber.java`.

## Prerequisites

Same as `java/listener-pubsub`: a JDK (`JAVA_HOME` set, needs `jni.h`),
Python 3.10+, and a zzdds checkout built with the Java binding:

```sh
cd /path/to/zzdds
zig build -Djava-binding=true -Dxtypes=true install
```

## Build and run

```sh
export ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out   # defaults to ../zzdds/zig-out
./build.py
./run.py
```

`run.py` runs a subscriber and publisher as two JVM processes (real
loopback UDP discovery), checks both exit 0 and that a real sample line
reached the subscriber, then runs a `--config` smoke test (see below).

To run manually:

```sh
java --enable-native-access=ALL-UNNAMED -Djava.library.path=$ZZDDS_ZIG_OUT/lib \
    -cp build/classes ShapeMain -S --read-period 200 &
sleep 1
java --enable-native-access=ALL-UNNAMED -Djava.library.path=$ZZDDS_ZIG_OUT/lib \
    -cp build/classes ShapeMain -P --write-period 200 -w
```

`-h`/`--help` lists every implemented flag.

## Config-file support (`--config <path>`)

Java has no native JNI wrapper for zzdds's config-file-loading API yet, so
this example works around it: before creating the factory, `ShapeMain.main()`
copies the file named by `--config` to `./zzdds.toml` in the process's
working directory. Every binding's `create_factory()` (Java included, via
its own ambient `ProcessConfig` lazy-resolve) already picks up a file with
exactly that name/location automatically — the same mechanism
`java/listener-pubsub`'s own `zzdds.toml` relies on, just staged at run
time here instead of shipped as a permanent file. `run.py`'s config smoke
test exercises this for real: `config/custom-ports.toml` makes the
subscriber bind port 20010 instead of the default 7410, checked with a
plain Python socket bind probe (no external tool dependency).

## Wire format note (XCDR1 vs XCDR2)

`zig/shape`, `c/shape`, and `cpp/shape` default to XCDR1 wire encoding.
This port's writer explicitly selects the same via
`new ShapeTypeDataWriter(writer, ShapeTypeDataWriter.XCDR1)` and declares
`data_representation=[XCDR_DATA_REPRESENTATION]` in its QoS to match —
readers don't need to pick a version at all, since a `ShapeTypeDataReader`
parses each payload's own encapsulation header and self-configures for
either XCDR1 or XCDR2.
