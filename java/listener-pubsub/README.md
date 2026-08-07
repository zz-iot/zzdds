# zzdds Java pub/sub example

Two separate JVM processes (`Publisher`, `Subscriber`) that discover each
other over real UDP DDS discovery and exchange `SensorSample` samples — the
same shape of example as `c/custom-allocator`, for Java.

`Subscriber` registers a real `DataReaderListener` (`on_data_available`),
which exercises the native-code-calling-back-into-Java JNI upcall path —
worth calling out specifically, since that direction (native → JVM) needs
more care than the more familiar Java → native direction every other call
in this example uses. `Publisher` instead polls
`get_publication_matched_status()`, to keep that side minimal and
single-threaded.

## Prerequisites

- A JDK (not just a JRE — building zzdds's own JNI bridge needs `jni.h`).
  `JAVA_HOME` should point at it.
- A zzdds checkout, built with the Java binding enabled:

  ```sh
  cd /path/to/zzdds
  zig build -Djava-binding=true -Dxtypes=true install
  ```

  This installs the DDS API classes, the `io.zzdds.runtime.ZzddsRuntime`
  native runtime shim, `libzzdds.so`, and `libzzdds_jni.so` into
  `zig-out/`, and installs the `zidl` code generator itself (used below to
  generate this example's own `SensorSample` TypeSupport/DataWriter/
  DataReader).

## Build and run

```sh
export ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out   # defaults to ../zzdds/zig-out
./build.sh
./run.sh
```

Expected output (interleaved from two processes):

```
Starting subscriber...
Starting publisher...
Subscriber: waiting for 10 samples...
Publisher: waiting for a subscriber to match...
Publisher: matched a subscriber, writing 10 samples.
Publisher: wrote sample 0 temperature_c=20.0
Subscriber: received sensor_id=1 temperature_c=20.0 label=sensor-1
Publisher: wrote sample 1 temperature_c=20.5
Subscriber: received sensor_id=1 temperature_c=20.5 label=sensor-1
...
Publisher: done.
Subscriber: done, received 10 samples.
OK: publisher and subscriber both exited successfully.
```

## What this actually exercises

Both `Publisher`/`Subscriber` use nothing but the generated Java API —
`DomainParticipantFactory`, `DomainParticipant`, `Topic`, `Publisher`/
`Subscriber`, `DataWriter`/`DataReader`, QoS structs (passing `null` for
"use default" throughout), and a registered `DataReaderListener` — plus the
typed `SensorSampleTypeSupport`/`DataWriter`/`DataReader` wrappers generated
from `idl/sensor.idl` by `zidl -b java --generate-zzdds-wrappers`.

## Known limitations

- Replacing a listener already registered on the same entity (a second
  `set_listener`-style call) leaks the old global reference — not an issue
  for this example (each entity's listener is set once). See zzdds's
  `docs/language-bindings.md` for the full list of Java-binding notes.
