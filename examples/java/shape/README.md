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

Before creating the factory, `ShapeMain.main()` loads the file named by
`--config` via `ZzddsRuntime.configureFromFile(String)` (a thin JNI wrapper
around `zzdds_process_configure_from_file`) as the process-wide default
participant config. `run.py`'s config smoke test exercises this for real:
`config/custom-ports.toml` makes the subscriber bind port 20010 instead of
the default 7410, checked with a plain Python socket bind probe (no
external tool dependency).

`-Z`/`--datafrag-size` and `--periodic-announcement` compose with
`--config`: when either is set, this port reads the factory's
already-resolved default config (reflecting `--config`, if any) via
`get_default_participant_config`, overrides just the field(s) that changed,
and creates the participant via `create_participant_ex` — same approach as
`c/shape`/`cpp/shape`/`zig/shape`.

## Wire format note (XCDR1 vs XCDR2)

`zig/shape`, `c/shape`, and `cpp/shape` default to XCDR1 wire encoding.
This port's writer explicitly selects the same via
`new ShapeTypeDataWriter(writer, ShapeTypeDataWriter.XCDR1)` and declares
`data_representation=[XCDR_DATA_REPRESENTATION]` in its QoS to match —
readers don't need to pick a version at all, since a `ShapeTypeDataReader`
parses each payload's own encapsulation header and self-configures for
either XCDR1 or XCDR2.
