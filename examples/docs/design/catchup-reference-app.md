# Catchup example — what it demonstrates

A pub/sub example built around DDS's built-in durability — arguably the
single best "why not just a message queue" selling point DDS has over
plain pub/sub messaging systems, and, per
`zzdds/docs/design/dcps-api-coverage-audit.md`, `wait_for_historical_data`
has **zero** exercise anywhere in this project (the audit lists it under
"Integration tests," not "Examples," but it's a compelling enough
new-user-facing pattern to earn a dedicated example here too — DDS
replaying missed history to a late joiner is a genuine "wow" moment for
anyone coming from a plain socket/queue background).

Where `presence` is about a writer's status and `registry` is about
per-instance lifecycle, this is about **time**: a publisher writes a batch
of data *before* any subscriber exists, and a subscriber that starts late
still gets the full backlog, deterministically, before it sees anything
"live."

## The type

```idl
@appendable
struct HistoryEvent {
    int32 seq_num;
};
```

Topic name `HistoryEvent`. Deliberately minimal and keyless (single logical
stream, like `hello_world`) — the point is durability/timing, not the
payload or instance model those other two examples already cover.

## QoS

`RELIABLE` + `DurabilityQosPolicy{ kind: TRANSIENT_LOCAL_DURABILITY_QOS }` +
`HistoryQosPolicy{ kind: KEEP_ALL_HISTORY_QOS }` on both sides (durability
QoS must match/be compatible per spec — TRANSIENT_LOCAL on both writer and
reader). KEEP_ALL rather than a bounded KEEP_LAST because the whole point is
that *every* historical sample survives to replay, not just the most recent
one.

TRANSIENT_LOCAL (not TRANSIENT or PERSISTENT) deliberately: those require a
separate persistence/durability service this project doesn't implement
(see `zzdds/docs/roadmap.md`'s "Deferred / Out of Scope" list) —
TRANSIENT_LOCAL's "the writer itself caches history for late joiners, no
external service needed" model is both the simplest durability kind to
demonstrate and the only one zzdds actually supports.

## Publisher flow

1. Create participant → register `HistoryEvent`'s TypeSupport → topic →
   publisher → DataWriter with the QoS above.
2. **Historical batch**: write 10 samples (`seq_num` 0–9) immediately, with
   no reader matched yet — no wait, no gating. This is deliberate: the
   whole scenario only means something if the writer doesn't know or care
   whether anyone's listening yet.
3. Wait for a reader to match (needed so the process doesn't exit before
   the late-joining subscriber has had a chance to actually connect and
   fetch the cached history — the process itself must stay alive for
   TRANSIENT_LOCAL replay to happen at all, since zzdds's cache lives in
   the writer's own process, not an external service).
4. **Live batch**: once matched, write 5 more samples (`seq_num` 10–14) —
   the "happening right now" data a normal, non-late subscriber would also
   see.
5. Wait for the subscriber's matched-reader count to drop back to zero
   (same shutdown-gating idiom as `hello_world`), then tear down.

Required stdout markers: `Create topic:`, `Create writer for topic:`,
`Publisher: wrote historical seq_num=`, `Publisher: reader matched, writing
live batch`, `Publisher: wrote live seq_num=`, `Publisher: done.`

## Subscriber flow — the late joiner

1. **Deliberately starts after the publisher has already written its full
   historical batch** — the interop smoke test's own orchestration
   enforces this ordering explicitly (start publisher, wait for its own
   "wrote historical" log lines to complete, *then* start the subscriber),
   not a race the app code resolves on its own. See the "real timing
   wrinkle" callout in the original brainstorm this example came from:
   getting a genuinely late subscriber needs an explicit ordering step in
   the harness, the app pattern itself is simple.
2. Create participant → TypeSupport → topic → subscriber → DataReader with
   the same TRANSIENT_LOCAL/KEEP_ALL QoS and no listener yet.
3. Wait for the publisher's writer to match the reader, polling
   `get_subscription_matched_status` for up to `max_wait`.
   `wait_for_historical_data` waits only for the writers matched when it is
   called, and with none returns OK at once (zzdds
   `docs/design/concurrency/operations.md#historical-wait-compatibility`).
4. **Then call `wait_for_historical_data(max_wait)` — before taking
   anything.** This is the API this whole example exists to exercise. It
   blocks until the cached historical batch has actually been delivered (or
   `max_wait` elapses).
5. Once `wait_for_historical_data` returns successfully, take everything
   currently available and confirm it's exactly the historical batch
   (`seq_num` 0–9, in order) — printing a `HISTORICAL BATCH COMPLETE`
   marker only after confirming the count and order, not just that the call
   returned.
   The subscriber takes the batch on its own thread: `wait_for_historical_data`
   waits for the samples to reach the reader, not for a listener to have
   taken them, so counting what a listener took right after the call
   returns races the listener's last take.
6. Attach the `on_data_available` listener (`set_listener` delivers
   anything that arrived since the take) and continue taking as live data
   arrives (`seq_num` 10–14), printing a distinct `LIVE SAMPLE` marker per
   item, until all 15 total samples have been seen.
7. Exit successfully once both the historical batch and the live batch have
   been fully and correctly observed, *in that order* (the one thing this
   example actually asserts programmatically: a sample never counted as
   "historical" after the `wait_for_historical_data` boundary, and never
   counted as "live" before it).

Required stdout markers: `Create topic:`, `Create reader for topic:`,
`Subscriber: wait_for_historical_data() returned`, `HISTORICAL BATCH
COMPLETE (10 samples)`, `LIVE SAMPLE seq_num=`, `Subscriber: observed
historical batch then live batch correctly.`

## A bug found building this example, and what replaced its fix

`wait_for_historical_data()` had no coverage anywhere in this project before
this example (`zzdds/docs/design/dcps-api-coverage-audit.md`), and building
it found a bug in the most common call pattern: called right after creating
the reader, before discovery had matched the publisher's writer, a real
10-second wait returned `RETCODE_OK` on its first check with no historical
sample delivered. The first fix made a nonzero wait on a reader that had
never matched a writer wait for one to match.

That fix is superseded. `wait_for_historical_data` now waits for the writers
that owe the reader history when it is called, and with none returns OK at
once (zzdds
`docs/design/concurrency/operations.md#historical-wait-compatibility`):
discovery readiness is its own predicate, not something this call waits
for. So the subscriber waits for the publisher's writer to match first
(step 3 above), and the `wait-for-historical-data` integration scenario
asserts that a reader no writer matches returns OK at once.

## Deliberately out of scope

TRANSIENT and PERSISTENT durability (need a persistence service zzdds
doesn't implement — see the QoS section above). `DurabilityServiceQosPolicy`
tuning (history depth/resource limit knobs for the durability cache) — not
part of the trimmed `dcps.idl` this project uses, and not needed to
demonstrate the core replay behavior. A negative case (subscriber joins
*before* `wait_for_historical_data`'s `max_wait` would plausibly be
exceeded, e.g. deliberately delaying the writer) is a real, separate
integration-test-shaped question (does it correctly time out rather than
hang forever) — left to a future integration test per the audit's own
bucket classification, not this example, which is about the success path a
new user would actually reach for.

See each language's own README (`zig/catchup`, `cpp/catchup`, `c/catchup`,
`java/catchup`) for build and run instructions.
