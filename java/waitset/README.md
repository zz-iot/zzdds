# java/waitset

Java port of `zig/waitset` — see
[`docs/design/waitset-reference-app.md`](../../docs/design/waitset-reference-app.md)
at the repo root for what this example demonstrates and why (WaitSet-driven
flow instead of listeners, all four condition types on one WaitSet, a
background watchdog thread for a real concurrency exercise). This directory
is just the Java/JNI-specific build/run wiring.

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

or run `Subscriber`/`Publisher` as two separate JVM processes directly (see
`run.py` for the exact `java` invocation). `-d`/`--domain <id>` (default 0)
is the only flag either class takes.

`build.py` accepts a `ZIDL_EXECUTABLE` override, same as `java/hello_world`.

## Notes

- `ZzddsRuntime.createWaitSet()`/`createGuardCondition()` (and their
  `destroy*` counterparts) are hand-written native bootstrap methods, added
  alongside `createFactory()` — neither `WaitSet` nor `GuardCondition` has a
  factory operation in `dcps.idl` (per OMG spec, both are app-instantiated
  directly), and neither has a factory delete operation either, so
  `destroyWaitSet()`/`destroyGuardCondition()` are the only way to release
  one.
- Java's condition interfaces (`GuardCondition`, `StatusCondition`,
  `ReadCondition`, `QueryCondition`) all `extends Condition` directly in the
  generated interface hierarchy, same as C++ — `ws.attach_condition(sc)`
  just works, no upcast helper needed.
- Both `Publisher.java` and `Subscriber.java` branch on membership in
  `wait()`'s returned `active_conditions` list (plain `List.contains()`,
  which falls back to `Object`'s reference-identity `equals()` — no
  `equals()`/`hashCode()` override needed), the same idiom `c/waitset` and
  `cpp/waitset` use. This used to be impossible for a more fundamental
  reason than C++'s own gap: Java's JNI bridge constructed a **brand-new**
  Java object on every handle crossing (`zidl_java_box_<c_name>`,
  `src/backend/java.zig`), with no identity cache at all — worse than C++'s
  per-concrete-type cache, not the same shape. Fixed by giving
  `zidl_java_box_<c_name>` a shared native (JNI weak-global-ref) cache per
  `@shared_c_abi_box` family, plus a registration hook for `GuardCondition`
  (`ZzddsRuntime.createGuardCondition()`'s native implementation calls it
  directly, since — like C++'s `GuardConditionSupport` — it constructs its
  Java object by hand rather than through any generated box helper). See
  zidl's `docs/roadmap.md` "Binding design review: decision" and its "Java
  backend: native weak-global-ref box cache" follow-up for the fuller
  writeup. Verified directly against the fixed zzdds (rebuilt, both classes
  rerun clean, twice) before switching to the membership-based form here —
  including through `qcCond`'s `QueryCondition`-satisfies-`ReadCondition`
  identity (Java's own interface inheritance, no upcast needed) and
  `GuardCondition`'s hand-constructed registration path.
- zidl's Java backend names the generated file's outer wrapper class from
  the IDL file's stem (`waitset_sample` → `Waitset_sample`), separately from
  the struct's own name (`WaitsetSample`, used directly for
  `WaitsetSampleDataWriter`/`WaitsetSampleDataReader`/
  `WaitsetSampleTypeSupport`) — see `java/hello_world`'s README for the same
  note in more detail.
