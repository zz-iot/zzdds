# java/participant-config

Java port of `zig/participant-config` — see
[`docs/design/participant-config-reference-app.md`](../../docs/design/participant-config-reference-app.md)
at the repo root for what this example demonstrates and why (programmatic
vs. file-based participant configuration). This directory is just the
Java/JNI-specific build/run wiring.

Uses `java/hello_world`'s JNI build pattern (`build.py`, `ZzddsRuntime`).

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
```

Programmatic mode:

```sh
java --enable-native-access=ALL-UNNAMED -Djava.library.path=/path/to/zzdds/zig-out/lib -cp build/classes Subscriber -d 42 &
sleep 1
java --enable-native-access=ALL-UNNAMED -Djava.library.path=/path/to/zzdds/zig-out/lib -cp build/classes Publisher -d 42
```

File mode (TCP user-data transport):

```sh
java --enable-native-access=ALL-UNNAMED -Djava.library.path=/path/to/zzdds/zig-out/lib -cp build/classes Subscriber -d 42 --config ../../config/tcp-non-discovery.toml &
sleep 1
java --enable-native-access=ALL-UNNAMED -Djava.library.path=/path/to/zzdds/zig-out/lib -cp build/classes Publisher -d 42 --config ../../config/tcp-non-discovery.toml
```

Both invocations need `LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib` set too
(transitive dependency of `libzzdds_jni.so` on `libzzdds.so`; Linux doesn't
consult `java.library.path` for that).

`-d`/`--domain <id>` (default 0) and `--config <path>` are the only flags
either class takes.

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

- `ZzddsRuntime.createFactory()` always boxes into the base
  `io.zzdds.dcps.DomainParticipantFactoryImpl` view — programmatic mode
  narrows it to `io.zzdds.ext.Zzdds.zzdds.DomainParticipantFactory` via the
  new `ZzddsRuntime.asZzddsFactory()` helper (added for this example;
  mirrors the existing `asZzddsDataWriter()` narrowing `on_reliable_reader_
  ready` already needed) to reach `create_participant_ex`/
  `set_default_participant_config`/`get_default_participant_config`.
- zidl's Java backend names the generated file's outer wrapper class from
  the IDL file's stem (`config_ping` → `Config_ping`), separately from the
  struct's own name (`ConfigPing`) — a sample is constructed as
  `Config_ping.ConfigPing`, not `ConfigPing.ConfigPing`. See
  `java/hello_world`'s own README for the same note.
