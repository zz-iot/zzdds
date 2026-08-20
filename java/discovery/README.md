# java/discovery

Java port of `zig/discovery` — see
[`docs/design/discovery-reference-app.md`](../../docs/design/discovery-reference-app.md)
at the repo root for what this example demonstrates and why. This
directory is just the Java/JNI-specific build/run wiring.

Uses `java/hello_world`'s JNI build pattern (`build.py`, `ZzddsRuntime`).

## Prerequisites

- A zzdds checkout built with `zig build -Djava-binding=true install`.
- `JAVA_HOME` set to a full JDK.
- Python 3.10+.

## Build and run

```sh
ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build.py
```

```sh
java --enable-native-access=ALL-UNNAMED -Djava.library.path=/path/to/zzdds/zig-out/lib -cp build/classes Subscriber -d 42 &
sleep 1
java --enable-native-access=ALL-UNNAMED -Djava.library.path=/path/to/zzdds/zig-out/lib -cp build/classes Publisher -d 42
```

Both invocations need `LD_LIBRARY_PATH=/path/to/zzdds/zig-out/lib` set too
(transitive dependency of `libzzdds_jni.so` on `libzzdds.so`; Linux doesn't
consult `java.library.path` for that).

`-d`/`--domain <id>` (default 0) is the only flag either class takes.

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

- `InstanceHandleSeq` maps to `java.util.List<Integer>`, and
  `TopicBuiltinTopicData`/`SubscriptionBuiltinTopicData`/
  `PublicationBuiltinTopicData` are plain, GC-managed Java classes — fully
  idiomatic, nothing to free manually. See the design doc for why this
  still exercises the same C-ABI mirror-struct fix `c/discovery` does
  underneath (`zzdds_jni.c`'s generated glue is itself plain C, compiled
  against the same public headers `c`/`cpp` build against).
- zidl's Java backend names the generated file's outer wrapper class from
  the IDL file's stem (`discovery_ping` → `Discovery_ping`), separately
  from the struct's own name (`DiscoveryPing`) — a sample is constructed as
  `Discovery_ping.DiscoveryPing`, not `DiscoveryPing.DiscoveryPing`. See
  `java/hello_world`'s own README for the same note.
