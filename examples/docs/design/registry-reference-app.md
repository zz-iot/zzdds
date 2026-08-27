# Registry example — what it demonstrates

A pub/sub example built around explicit keyed-instance lifecycle management
— the standard "keys and instances" tutorial every DDS vendor ships, and,
per `zzdds/docs/design/dcps-api-coverage-audit.md`, largely zero-coverage in
this project: `register_instance` (explicit, not implicit-via-`write()`),
`register_instance_w_timestamp`, `dispose_w_timestamp`,
`unregister_instance_w_timestamp`, `get_key_value`, and `lookup_instance`
are exercised nowhere else.

Where `hello_world` is unkeyed and `presence` is about entity status rather
than data, this is the first example centered on **instances** — the DDS
concept that one Topic can hold many independently-tracked logical objects,
each identified by its `@key` fields, each with its own lifecycle
(`ALIVE` → `NOT_ALIVE_DISPOSED`/`NOT_ALIVE_NO_WRITERS`).

Fully deterministic — no timing, no concurrency, no network-jitter-dependent
behavior. Everything this example asserts follows directly from a fixed
sequence of API calls, so it should be the easiest of the three new examples
to keep CI-green.

## The type

```idl
@appendable
struct SensorReading {
    @key int32 sensor_id;
    int32 value;
};
```

Topic name `SensorReading`. `sensor_id` is the key — three distinct
instances (ids 1, 2, 3) are used, one per lifecycle outcome (disposed,
unregistered, left alive). `value` is a trivial payload, printed alongside
each sample so the log shows real content flowing, not just lifecycle
bookkeeping.

## QoS

`RELIABLE` + `KEEP_ALL` on both sides, matching `hello_world`'s baseline —
this example isn't about QoS tuning, it's about the instance API surface.

## Publisher flow

One writer, three instances, walked through deliberately different
lifecycles:

1. **Instance A (`sensor_id=1`)**: `register_instance()` explicitly (not
   implicit-via-`write()`), then two `write()` calls, then
   `dispose()`. Ends `NOT_ALIVE_DISPOSED`.
2. **Instance B (`sensor_id=2`)**: `register_instance()`, one
   `write_w_timestamp()` call (exercising the explicit-timestamp variant
   at least once), then `unregister_instance_w_timestamp()`. Ends
   `NOT_ALIVE_NO_WRITERS`.
3. **Instance C (`sensor_id=3`)**: `register_instance()`, one `write()`,
   left alive — never disposed or unregistered. Ends `ALIVE` (the writer
   simply exits with it live, same as any normal writer teardown).

After all three, one more thing before exiting: call `get_key_value()` on
the handle `register_instance()` returned for instance A, and confirm the
key it round-trips (`sensor_id=1`) matches what was registered — proving
the handle-to-key direction works, not just key-to-handle.

Required stdout markers: `Create topic:`, `Create writer for topic:`,
`Publisher: registered instance sensor_id=`, `Publisher: wrote sensor_id=`,
`Publisher: disposed sensor_id=`, `Publisher: unregistered sensor_id=`,
`Publisher: get_key_value round-trip OK for sensor_id=`, `Publisher: done.`

## Subscriber flow

One reader, `take()`-ing everything and tracking each instance's observed
`SampleInfo.instance_state` sequence:

1. For each sample taken, record `(sensor_id, instance_state)` and confirm
   it's a legal transition from that instance's last known state (fail fast
   on an unexpected transition, matching the fail-fast ethos every other
   example in this repo already uses).
2. Once instance A shows `NOT_ALIVE_DISPOSED`, instance B shows
   `NOT_ALIVE_NO_WRITERS`, and instance C has been seen at least once
   `ALIVE` and nothing further arrives for it, call `lookup_instance()` with
   a sample keyed on `sensor_id=3` and confirm the returned handle matches
   the handle instance C's own samples carried — proving the key-to-handle
   direction, the other half of the publisher's `get_key_value()` check.
3. Exit successfully once all three instances have reached their expected
   terminal observation.

Required stdout markers: `Create topic:`, `Create reader for topic:`,
`Subscriber: sensor_id=... instance_state=...`, `Subscriber:
lookup_instance round-trip OK for sensor_id=`, `Subscriber: all three
instance lifecycles observed correctly.`

## Real, live bug found building this example

Zig, C++, and C all worked correctly on the first real run — genuinely
deterministic, no timing edge cases, matching the design intent. Java did
not, but for a different reason than `presence`'s core-protocol bugs: the
Java binding's generated `SensorReadingDataReader.Sample` class returned by
`take()`/`read()` had no way to observe `SampleInfo.instance_state` at all —
just `instanceHandle` and `validData`. Traced to the JNI native glue
(`zzdds_java_take_or_read`/`zzdds_java_take_or_read_instance` in
`java_runtime/zzdds_java_runtime.c`): both already receive a full
`zzdds_sample_info` from the underlying `zzdds_take_one_raw`/
`zzdds_read_one_raw` calls, but only ever extracted `instance_handle` and
`valid_data` before discarding the rest — `instance_state` was computed and
immediately thrown away on every single call, for every binding-generated
Java reader that has ever existed.

Fixed by adding a `stateOut` (`int[]`) parameter alongside the existing
`handleOut`/`validOut`, threaded through `ZzddsRuntime.takeRaw`/`readRaw`/
`takeNextInstanceRaw`/`readNextInstanceRaw` (the single-sample native calls
`take()`/`read()`/`take_next_instance()`/`read_next_instance()` use) and
zidl's generated `Sample` class, which now carries a real
`instanceState` field. **Deliberately not extended** to the batch-take
family (`take_n`/`read_n`/`take_instance`/`read_instance`/
`take_w_condition`/etc.) — those call different native entry points
(`takeNRaw`, `takeNInstanceRaw`, `takeWConditionRaw`, ...) that would need
their own, larger signature change. Rather than leave those methods
silently returning a plausible-looking-but-fake value, `Sample` exposes a
documented `UNKNOWN_INSTANCE_STATE` sentinel (`-1`, outside the real
bitmask range) that every batch method's `Sample`s carry today — a real,
flagged gap, not a silent one. Extending the batch family the same way is a
reasonable, contained follow-up whenever a real use case needs it.

## Deliberately out of scope

`register_instance_w_timestamp` (the writer already exercises the plain
`register_instance` and `write_w_timestamp`/`unregister_instance_w_timestamp`
— adding a fourth explicit-timestamp variant for symmetry alone doesn't
teach anything new) and `dispose_w_timestamp` (same reasoning — one
`_w_timestamp` exercise per operation family is enough to prove the pattern
works; this example already covers `write_w_timestamp` and
`unregister_instance_w_timestamp`). Batch `read_instance`/`take_instance`
and the `_w_condition` instance-selection family are also out of scope —
those are about *selecting* which instance to read, not about instance
*lifecycle*, and `waitset` already exercises the condition-based selection
path.

See each language's own README (`zig/registry`, `cpp/registry`,
`c/registry`, `java/registry`) for build and run instructions.
