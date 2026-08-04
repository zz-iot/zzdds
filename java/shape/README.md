# java/shape

Java port of the OMG DDS-Interoperability "Shapes" demo app, talking to
zzdds through its Java binding (JNI, `io.zzdds.dcps.Dcps`/
`io.zzdds.runtime.ZzddsRuntime`), using `java/listener-pubsub`'s JNI/build
patterns. One class, `-P`/`-S` selects publisher/subscriber mode -- matching
`zig/shape`, `c/shape`, `cpp/shape`'s single-binary convention (here: one
`java ShapeMain ...` invocation, run twice, one per role) rather than
listener-pubsub's separate `Publisher.java`/`Subscriber.java`.

**Fresh implementation -- no existing zzdds Java shape port anywhere.**
Same "Must-have (v1)" CLI/QoS scope as `c/shape`/`cpp/shape` plus `--config`
(see `docs/design/shape-reference-app.md` at the repo root); not the
stretch flags. Run `zig/shape -h` for the full spec those belong to.

## Prerequisites

Same as `java/listener-pubsub`: a JDK (`JAVA_HOME` set, needs `jni.h`), and
a zzdds checkout built with the Java binding:

```sh
cd /path/to/zzdds
zig build -Djava-binding=true -Dxtypes=true install
```

## Build and run

```sh
export ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out   # defaults to ../zzdds/zig-out
./build.sh
./run.sh
```

`run.sh` runs a subscriber and publisher as two JVM processes (real
loopback UDP discovery), checks both exit 0 *and* that a real sample line
reached the subscriber, then runs a `--config` smoke test (see below).

To run manually:

```sh
java --enable-native-access=ALL-UNNAMED -Djava.library.path=$ZZDDS_ZIG_OUT/lib \
    -cp build/classes ShapeMain -S --read-period 200 &
sleep 1
java --enable-native-access=ALL-UNNAMED -Djava.library.path=$ZZDDS_ZIG_OUT/lib \
    -cp build/classes ShapeMain -P --write-period 200 -w
```

`-h`/`--help` lists the implemented flags.

## Config-file support (`--config <path>`) -- the MVP option, not real JNI

`docs/design/shape-reference-app.md` calls out that Java has no
`zzdds_process_configure_from_file` JNI wrapper (confirmed: grepped every
`native` declaration in `ZzddsRuntime.java`, found none) and offers two
choices: an MVP copy-trick, or add a real JNI wrapper as a separate zzdds
follow-up. This port takes the MVP path: before creating the factory,
`ShapeMain.main()` copies the file named by `--config` to `./zzdds.toml` in
the process's cwd. Every binding's `create_factory()` (Java included, via
its own ambient `ProcessConfig` lazy-resolve) already picks up a file with
exactly that name/location with zero explicit call -- this is the same
mechanism `java/listener-pubsub`'s own `zzdds.toml` already relies on, just
staged at run time here instead of being a permanent example file. Verified
by `run.sh`'s config smoke test (acceptance criterion from the design doc:
"covered by at least one test case, not just implemented and unverified"):
`config/custom-ports.toml` makes the subscriber bind port 20010 instead of
the default 7410, checked via `ss -uln`.

## Cross-binding interop: Java now joins the ring

Building this port originally surfaced a real bug in `zidl` (the shared IDL
compiler zzdds's bindings are generated from), not in this example. It's
since been fixed at the source (`zidl/src/backend/java.zig`), and this port
was updated to match -- Java now interoperates with `zig/shape`, `c/shape`,
and `cpp/shape` in both directions, exchanging real samples, not just with
itself.

**What was wrong.** zidl's Java backend was hardcoded to always generate
XCDR2 wire encoding (unconditional DHEADER on `@appendable` types, 4-byte
alignment even for 8-byte fields, no read-side awareness of what
encapsulation it actually received) while the C/C++/Zig backends default to
real, DHEADER-less XCDR1 -- `zig/shape`/`c/shape`/`cpp/shape`'s actual wire
format. Two Java writer/reader instances could talk to each other, but
Java's payloads were never byte-compatible with what the other three ports
produce or expect.

**The fix**, in `zidl` itself: writers now carry an explicit `xcdrVersion`
(mirroring the C backend's existing pattern) that conditionally
reserves/patches the DHEADER for `@appendable` types (`@mutable` is
unaffected -- it always requires XCDR2 per spec) and selects natural 8-byte
vs. capped 4-byte alignment accordingly. Readers don't take an
`xcdrVersion` parameter at all -- they parse the 4-byte encapsulation header
of each incoming payload and self-configure, so a Java reader correctly
decodes either XCDR1 or XCDR2 payloads without the caller having to know in
advance which one is coming. `ShapeTypeDataWriter` now exposes
`XCDR1`/`XCDR2` constants and a constructor overload
(`new ShapeTypeDataWriter(writer, ShapeTypeDataWriter.XCDR1)`); this port
uses `XCDR1` to match the other three ports' default wire format. QoS is
back to declaring `data_representation=[XCDR_DATA_REPRESENTATION]`
explicitly (`buildWriterQos`/`buildReaderQos` in `ShapeMain.java`), same as
`c/shape`/`cpp/shape`/`zig/shape` -- the earlier workaround of leaving it
unset no longer applies now that Java's actual wire output matches what it
declares.

The `data_representation` mismatch this port originally reported as a
*separate* JNI-marshalling bug did not resurface once the above was fixed
and the QoS declaration was restored to an honest, non-empty value --
strongly suggesting it was a downstream symptom of the same root cause
(declared QoS not matching actual wire behavior) rather than an independent
bug.

Verified in both directions for all three pairings (`run-all.sh`/manual
`-P`/`-S` smoke tests, checking for real received `COLOR ... [size]``
sample lines, not just exit codes): Java↔Zig, Java↔C, Java↔C++, plus the
Java↔Java regression check. The interop ring
`zig/shape`→`c/shape`→`cpp/shape`→`java/shape`→`zig/shape` the design doc
describes as the acceptance target is now fully closed.

**Known, deliberately deferred follow-up**: bitset/bitmask types with an
8-byte-backed representation still always align to 4 bytes in zidl's Java
backend (the same XCDR1/XCDR2 alignment gap fixed above for structs/unions,
just not yet extended to bitsets) -- doesn't affect `ShapeType` (no bitset
fields), not chased here.
