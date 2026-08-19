# Presence example — what it demonstrates

A pub/sub example built around DDS's LIVELINESS QoS — the "is this
device/service still alive" pattern that shows up in almost every real DDS
deployment (watchdog-style presence detection), and, per
`zzdds/docs/design/dcps-api-coverage-audit.md`, currently has **zero**
exercise anywhere in this project: no example, no binding, no interop
script ever constructs a non-default `LivelinessQosPolicy`, calls
`assert_liveliness()`, or wires `on_liveliness_changed`/`on_liveliness_lost`.

Where `hello_world` is reliability-focused and `waitset` is condition-driven,
this is the first example centered on an *entity status* transition rather
than data content — the payload itself is almost incidental; what matters is
the reader observing the writer go quiet and come back.

## The type

```idl
@appendable
struct PresenceBeacon {
    int32 seq_num;
};
```

Topic name `PresenceBeacon`. Deliberately keyless and minimal — like
`hello_world`, the point isn't the payload, so it stays tiny. `seq_num` only
exists so the subscriber's log has something concrete to print alongside
each `on_data_available` beacon, distinguishing "I got data" lines from the
liveliness-transition lines in the output. (Named `seq_num`, not the more
natural `sequence` — `sequence` is an IDL reserved keyword, confirmed by a
real `zidl` parse error the first time this was written as `sequence`.)

## QoS

`RELIABLE` + `KEEP_LAST(1)` on both sides (only the latest beacon ever
matters here, unlike `hello_world`'s KEEP_ALL). The QoS that actually matters
for this example: `LivelinessQosPolicy{ kind: MANUAL_BY_TOPIC_LIVELINESS_QOS,
lease_duration: 2s }` on the **writer** (liveliness QoS must match/be
compatible on both sides per spec, so the reader specifies the same kind and
a lease_duration >= the writer's).

MANUAL_BY_TOPIC (rather than MANUAL_BY_PARTICIPANT or AUTOMATIC) so that
liveliness is scoped to this one DataWriter and asserted by this one
DataWriter — `DataWriter.assert_liveliness()`, not
`DomainParticipant.assert_liveliness()`. AUTOMATIC was rejected deliberately:
zzdds's DEADLINE/LIVELINESS timer thread already drives AUTOMATIC liveliness
without any app involvement at all (see `zzdds/docs/roadmap.md`'s
"DEADLINE/LIVELINESS QoS is now enforced automatically" entry) — a
MANUAL_BY_TOPIC writer that deliberately stops writing *and* stops asserting
is the only way to make "going offline" an app-driven, demonstrable action
rather than something that just happens to the process regardless of what it
does.

## Publisher flow

1. Create participant → register `PresenceBeacon`'s TypeSupport → topic →
   publisher → DataWriter with the MANUAL_BY_TOPIC QoS above.
2. **Online phase**: write beacons on a ~500ms cadence for ~4 seconds
   (well under the 2s lease, so liveliness never lapses during this phase
   purely from write cadence alone).
3. **Offline phase**: go quiet for longer than the lease (~5s) — no writes,
   no `assert_liveliness()` calls. This is what actually lets the lease
   expire and the reader observe the drop.
4. **Recovery**: call `DataWriter.assert_liveliness()` once explicitly
   (demonstrating the manual-assert API directly, not relying on write() as
   an implicit assertion), then resume writing beacons for a few more
   seconds.
5. Wait for the subscriber's matched-reader count to drop back to zero
   (same shutdown-gating idiom as `hello_world`), then tear down.

Required stdout markers: `Create topic:`, `Create writer for topic:`,
`Publisher: wrote sequence=`, `Publisher: going offline (no writes/asserts
for `, `Publisher: asserting liveliness and resuming`, `Publisher: done.`

## Subscriber flow

1. Create participant → TypeSupport → topic → subscriber → DataReader with a
   listener on both `on_data_available` and `on_liveliness_changed`.
2. `on_liveliness_changed(status)`: print an explicit `ONLINE`/`OFFLINE`
   marker line derived from `status.alive_count` crossing 0 in either
   direction (0 → 1 = `ONLINE`, 1 → 0 = `OFFLINE`), plus the raw
   `alive_count`/`not_alive_count` for anyone reading the log closely.
3. `on_data_available`: take and print each beacon's `sequence` — mostly to
   give the log a second, independent signal that data is/isn't flowing,
   corroborating the liveliness transitions rather than replacing them.
4. Exit successfully once it has observed, in order: an initial `ONLINE`, a
   subsequent `OFFLINE`, and a final `ONLINE` again — the one thing this
   example actually asserts programmatically (not just prints).

Required stdout markers: `Create topic:`, `Create reader for topic:`,
`ONLINE alive_count=`, `OFFLINE alive_count=`, `Subscriber: observed full
online -> offline -> online cycle.`

## Real, live bugs found building this example

Confirms the design doc's own earlier caveat: "this is the first example/
binding to actually exercise that path end-to-end though, so treat 'it
already works' as unverified until proven, not assumed." It didn't. Four
real, previously-undiscovered bugs, all in `zzdds` core, found in this
order:

**1. `on_liveliness_changed` never fired on a writer's initial match or its
recovery after expiry — only on lease expiry itself.** `onWriterMatchedCb`/
`onWriterAliveCb` updated `status_changes`/counts on the "went alive"
transition but never actually called `notifyLivelinessChanged()` themselves
— only `checkTimersFn`'s own lease-expiry loop did, and only for its own
"just expired" direction. Fixed by having both callbacks call
`notifyLivelinessChanged()` themselves once unlocked (it takes `self.mu`
itself, so can't be called while already holding it — same reason
`checkTimersFn`'s own call site unlocks first). A real Zig-native regression
test (`qos_runtime_test.zig`, `TwoPartyTimerFixture`) was added and verified
to fail without the fix — but this in-process test harness doesn't exercise
real wire encode/decode, which is exactly why bug 3 below wasn't caught by
it.

**2. Real, separate `zidl` bug found along the way: `getFieldFromCdr`'s
generated `scratch` parameter was left completely unreferenced for any
struct with no string-typed members** (`PresenceBeacon` has exactly one
`int32` field) — a hard Zig compile error, not a runtime bug. Root cause:
`scratch` is only referenced inside the generator's `string_like` per-member
branch; a struct with zero such members never emits any reference to it.
Naive fix attempt (unconditionally emit `_ = field; _ = scratch;`) doesn't
work: Zig equally rejects a discard of something that's genuinely used
later ("pointless discard"), so the real fix pre-scans a struct's members to
decide whether either discard is actually needed. Regression test added
(`zig.zig`), verified to fail without the fix.

**3. The big one: `PID_LIVELINESS` was never encoded on the wire at all**
(`discovery/sedp.zig`, both the publication and subscription announcement
encoders) — a deliberate prior decision, not an oversight, per the comment
it replaced: "Cyclone and OpenDDS use different on-wire representations for
Duration_t INFINITE, so explicitly encoding it causes QoS-match failures."
Confirmed live via a real two-process run: the writer matched
(`on_publication_matched` fired), but the reader's own liveliness tracking
was never populated at all — every remote peer always looked like
AUTOMATIC+INFINITE regardless of its real configured QoS, meaning
`on_liveliness_changed`/`on_liveliness_lost` could never fire for *any* real
cross-process peer, under *any* QoS configuration, until this fix. Fixed
per spec, matching Cyclone DDS's own encoding (confirmed against
`OMG_specs/formal-22-04-01.pdf` §9.3.2's DURATION_INFINITE definition,
`seconds=0x7fffffff, fraction=0xffffffff`) rather than continuing to avoid
the PID: `RtpsDuration.fromDuration` already special-cases DDS's own
Duration_t INFINITE sentinel correctly (confirmed by reading it, not
assumed), so there was never a real encoding incompatibility to avoid in
the first place — only a genuinely broken previous assumption. `checkSnapshots`'
RxO compatibility check was extended to actually compare the now-real
`lease_duration` too (previously skipped, per its own comment, "not present
in QosSnapshot" — it was present as a struct field, just never populated
from the wire). No unit round-trip test added for the encode/decode path
itself (this project's SEDP encoders have no existing unit-level round-trip
test precedent to extend, even for DEADLINE/LIFESPAN); verified instead via
real two-process runs across all four bindings.

**4. A RELIABLE writer's own background HEARTBEAT traffic was
unconditionally treated as liveliness evidence for every LIVELINESS kind.**
Found immediately after fixing bug 3: the offline/online cycle still hung
even with the wire fix, because `vtHandleHeartbeat` signals `on_writer_alive`
on *every* incoming HEARTBEAT — legitimate for AUTOMATIC (any writer
activity counts), spec-incorrect for MANUAL_BY_TOPIC/PARTICIPANT (only an
actual `write()`/`assert_liveliness()` counts). Since RELIABLE writers send
HEARTBEATs on a fixed schedule regardless of app activity, a MANUAL_BY_TOPIC
lease could never actually expire over RELIABLE — the exact QoS/reliability
combination this example uses. Fixed by tagging alive-evidence as `.data`
(from an actual received sample — legitimate for all three kinds) vs.
`.heartbeat` (protocol-only — legitimate only for AUTOMATIC), threaded from
`protocol_adapters.zig`'s two call sites through a new
`MatchedWriterInfo.liveliness_kind` field down to `reader.zig`'s
`onWriterAliveCb`, which now gates on it.

All four fixes verified together: `zig build test` and `zig build test-tsan`
green throughout: the full online → offline → online cycle, cross-process,
confirmed on all four bindings (`zig`, `cpp`, `c`, `java`) and all 8
same-binding/cross-binding pairs in
`interop/presence_cross_binding_smoke_test.py`, each run clean on the first
attempt once all four fixes landed together.

## Deliberately out of scope

`DomainParticipant.assert_liveliness()` and the AUTOMATIC/
MANUAL_BY_PARTICIPANT liveliness kinds, and `on_liveliness_lost`/
`get_liveliness_lost_status` (the writer-side "lease expired with no
recovery, ever" terminal case — distinct from this example's "lease expired,
then recovered" story). Forcing a second scenario into one example to cover
these would work against the "not a complex test case" goal; left as a
documented remaining gap, not silently forgotten.

See each language's own README (`zig/presence`, `cpp/presence`,
`c/presence`, `java/presence`) for build and run instructions.
