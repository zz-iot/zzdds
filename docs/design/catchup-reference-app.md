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
   the same TRANSIENT_LOCAL/KEEP_ALL QoS, listener on `on_data_available`.
3. **Immediately after creating the reader, call
   `wait_for_historical_data(max_wait)` — before taking anything.** This is
   the API this whole example exists to exercise. Blocks until the cached
   historical batch has actually been delivered (or `max_wait` elapses).
4. Once `wait_for_historical_data` returns successfully, take everything
   currently available and confirm it's exactly the historical batch
   (`seq_num` 0–9, in order) — printing a `HISTORICAL BATCH COMPLETE`
   marker only after confirming the count and order, not just that the call
   returned.
5. Continue taking as live data arrives (`seq_num` 10–14), printing a
   distinct `LIVE SAMPLE` marker per item, until all 15 total samples have
   been seen.
6. Exit successfully once both the historical batch and the live batch have
   been fully and correctly observed, *in that order* (the one thing this
   example actually asserts programmatically: a sample never counted as
   "historical" after the `wait_for_historical_data` boundary, and never
   counted as "live" before it).

Required stdout markers: `Create topic:`, `Create reader for topic:`,
`Subscriber: wait_for_historical_data() returned`, `HISTORICAL BATCH
COMPLETE (10 samples)`, `LIVE SAMPLE seq_num=`, `Subscriber: observed
historical batch then live batch correctly.`

## Real, live bug found building this example

`wait_for_historical_data()` had **zero coverage anywhere in this project**
before this example (confirmed by `zzdds/docs/design/dcps-api-coverage-audit.md`),
and it turned out to have a real, previously-undiscovered bug affecting
exactly the most common real call pattern: calling it immediately after
creating the reader, before discovery has had any chance to run.

Traced to `StatefulReader.historicalDelivered()` (`src/rtps/reader_sm.zig`):
it walks `writer_proxies` and returns `true` if every entry has delivered
its full history -- which is vacuously `true` when the list is *empty*, and
it's empty both when genuinely no writer will ever match *and* when a
writer simply hasn't matched yet. `DataReader.wait_for_historical_data`'s
poll loop (`vtWaitForHistorical`, `src/dcps/reader.zig`) trusted that return
value unconditionally, so a real 10-second `max_wait` call returned
`RETCODE_OK` on its very first poll -- before discovery had even had a
chance to run -- with zero historical samples actually delivered. Confirmed
live: the subscriber logged `wait_for_historical_data() returned` followed
immediately by `only 0/10 historical samples were actually received`.

This wasn't an accidental oversight: an existing unit test explicitly
asserted the old behavior for a *zero*-duration wait
(`"wait_for_historical_data: TRANSIENT_LOCAL with no matched writers returns
OK immediately"`) -- a reasonable "just check current state, don't block"
degenerate case that the fix deliberately preserves unchanged. The bug was
specifically that the *same* vacuous-empty-list shortcut also applied to
real, non-zero waits, where it's never correct: an app passing a real
`max_wait` is explicitly asking to give a not-yet-discovered writer a
chance to appear.

Fixed with a new `hasMatchedWriters()` (sticky -- true once any writer has
*ever* matched, not "currently matched", so a writer that delivers
everything and later disappears still counts as done): a non-zero wait no
longer trusts `historicalDelivered()`'s vacuous `true` until at least one
writer has actually matched, keeping the same zero-duration semantics
otherwise. Two new unit tests lock this in
(`test/dcps/wait_for_historical_test.zig`): a negative case (non-zero
`max_wait`, no writer ever matches → `RETCODE_TIMEOUT`, not an instant
false `RETCODE_OK`) and a positive case using a real background thread that
matches a writer *while* the call is already blocked (mirroring `catchup`'s
actual runtime shape) → `RETCODE_OK` once history genuinely lands. Both
verified to fail without the fix. Verified end-to-end across all four
bindings and all 16 cross-binding pairs in
`interop/catchup_cross_binding_smoke_test.py`, each clean on the first
attempt once the fix landed.

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
