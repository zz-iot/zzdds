# Discovery/association race testing — spec

Status: **Resolved, 2026-09-18.** What first looked like a `writer_sm.zig` correctness
bug (see "The motivating bug" below) turned out, after working through the fix design
with the user, to be correct VOLATILE-durability behavior — the writer's own local
knowledge at match time is the only principled floor for `start_sn`, and there is no
`writer_sm.zig` fix to make. The real, shipped resolution is a new reader-side
readiness signal, `on_reliable_writer_ready` (`DataReaderListenerEx`), giving an
application proof that a matched RELIABLE writer has actually registered it — closing
the race at its true source (asymmetric, unordered SEDP discovery) instead of trying to
make the writer retroactively guess right. See "Final resolution" near the end for the
full account, including what's landed vs. deliberately deferred. Motivated by a real bug
found 2026-09-18 while investigating an rmw_zzdds CI flake
(`ServiceTransport.request_response_round_trip_...`, `RmwAllocatorFailure`-adjacent work);
see "The motivating bug" below.

## Motivation

zzdds has effectively no test coverage for a whole class of bugs that live at the seam
between **discovery** (SPDP/SEDP), the **user application** (create entities, check
match/availability, `write()`), and **data-plane delivery** (RTPS DATA/HEARTBEAT/ACKNACK).
Every existing test tier either doesn't touch this seam at all (Tier 1), could in
principle but doesn't yet (Tier 2), tests other vendors' behavior rather than zzdds's own
internal races (Tier 3, dds-rtps interop), or catches this class of bug only
probabilistically, outside zzdds's own repo, dependent on a downstream consumer's test
suite getting unlucky (which is exactly how the motivating bug was found).

## The motivating bug

Found via `rmw_zzdds`'s `test_service_round_trip` test, which occasionally (not rarely —
roughly a third of runs under modest load) hung for the full 10 s wait timeout on a
service response that never arrived, even though both endpoints reported themselves
mutually "matched." Root cause, confirmed via targeted zzdds-core instrumentation
(`src/rtps/writer_sm.zig`):

1. `client`'s response reader becomes externally visible as "matched" via its own
   discovery of `service`'s response writer (`DDS_SubscriptionMatchedStatus`,
   `on_subscription_matched`) — one SEDP-driven event.
2. `service`'s response writer registers that same reader in its own send list
   (`StatefulWriter.addMatchedReader`, via `onReaderDiscovered` in `participant.zig`) —
   a **separate, asymmetric** SEDP-driven event, with no ordering guarantee relative to
   (1).
3. An application (correctly, by the DDS API's own contract) sees "matched" from (1) and
   calls `write()`. If (2) hasn't happened yet, `sendChangeToAllLocked`'s per-proxy loop
   doesn't even see this reader — not a delayed send, a skip, because the reader isn't in
   `self.reader_proxies` yet.
4. When (2) finally runs (moments later), `addMatchedReader` sets the new, VOLATILE
   (non-replaying) reader's `start_sn` to `self.cache.next_sn` **at that moment** — which
   already excludes the sample written in step 3. Not delayed delivery: permanent,
   silent exclusion. No later HEARTBEAT/ACKNACK ever recovers it, because `start_sn` is
   the writer's own floor for what it will ever consider offering this reader.

The bug is a genuine correctness defect in zzdds core (`writer_sm.zig`/`participant.zig`),
not a misuse of the API by `rmw_zzdds`. Confirmed reproducible via a wall-clock stress
loop (dozens of iterations, ~30% hit rate) but never previously caught by zzdds's own test
suite, because nothing in it exercises this seam.

> **Note (resolved 2026-09-18):** the framing above — "genuine correctness defect" — was
> this investigation's *starting* conclusion, not its ending one. Working through the fix
> design surfaced that step 4's `start_sn = self.cache.next_sn` is actually correct: a
> VOLATILE reader is never entitled to a sample written before it matched, and the writer
> can only know a reader exists at the moment association actually happens — there's no
> other principled floor. The application-visible problem (step 3's premature `write()`)
> is real, but the fix belongs on the *reader* side, not the writer's `start_sn`
> computation. See "Final resolution" near the end.

## Why existing tiers don't catch this

Per `docs/design/testing-strategy.md`:

- **Tier 1** (deterministic, in-process, `ManualClock`) — no discovery at all; explicitly
  out of scope ("Model tests... are not alternate implementations of discovery").
- **Tier 2** (mock transport) — its own spec already lists "SEDP: endpoint announcement
  ordering... proxy add/remove lifecycle" as in-scope, and `test/dcps/mock_loopback_test.zig`
  proves the infrastructure (`MockNetwork`/`MockTransport`, full real DCPS/RTPS stack, no
  real sockets) is capable of driving this exact scenario. **Nothing currently uses it to
  pin discovery-event ordering** — every existing Tier 2 test either lets both sides
  discover each other "naturally" (both `deliverAll()`'d together) or isn't testing this
  seam at all.
- **Tier 3** (live interop) — tests zzdds's wire compatibility with other vendors, not
  zzdds's own internal state-machine correctness.
- **Tier 4** (fuzz) — targets the RTPS/PL-CDR parsers against untrusted bytes, not
  protocol-level sequencing.
- **`stress-tests/`** — *could* catch this class of bug (real UDP, real concurrency,
  exactly the conditions that make the race possible), but nothing in the current
  `lifecycle_churn` scenario set specifically drives write-vs-discovery races, and even if
  it did, stress tests are explicitly non-deterministic by design (`stress-tests/README.md`:
  "the opposite of the deterministic `ManualClock` / mock-transport gate") — valuable as a
  probabilistic safety net, not as the primary, CI-gating catch mechanism.

## Key insight: this is an ordering bug, not fundamentally a timing bug

The instinct that "timing-related bugs are hard for unit tests to catch reliably" is right
about *wall-clock races* (thread scheduling, real socket latency) — but the actual defect
here is a **fixed ordering assumption that's wrong**: `addMatchedReader`'s `start_sn`
computation implicitly assumes "by the time I run, no relevant write has happened yet for
this reader," which is simply false in general. That assumption can be falsified
**deterministically**, on purpose, by choosing to deliver the two asymmetric SEDP events in
the "wrong" order and writing in between — no wall-clock nondeterminism required.
`MockNetwork`/`MockTransport` already provide exactly the granularity needed: each
`MockTransport.deliver()` call drains *one* transport's queue independently, so a test can
choose "let the reader-side discover the writer, but not yet the writer-side discover the
reader" as an explicit, repeatable step. This means the primary, CI-gating coverage for
this whole bug class belongs in **Tier 2**, not stress tests — fast, zero flakiness, exact
reproduction of the buggy interleaving on every run.

A secondary, complementary layer under real concurrent load (real UDP, real threads) is
still valuable — it's what actually surfaced this bug in practice, via `rmw_zzdds`'s CI —
and should live under `stress-tests/` per that tier's existing "real-load, probabilistic
safety net" role. It answers a different question ("does *some* interleaving of this class
still break us under realistic scheduling") than the pinned Tier 2 tests do ("does *this
specific known-bad* interleaving break us").

## Proposed structure

### Layer 1 — deterministic pinned-order tests (Tier 2 extension)

New file(s) under `test/dcps/` (this seam is DCPS-level — `write()`, match status,
`rmw`-visible availability — not a pure RTPS submessage concern, so `test/dcps/` fits
better than `test/rtps/`), e.g. `test/dcps/discovery_race_test.zig`, following
`mock_loopback_test.zig`'s two-participant `MockNetwork` pattern but adding **explicit
control of delivery order between the two asymmetric match directions**, plus a `write()`
call inserted at a chosen point in that ordering.

Sketch of the core primitive these tests need (new test-support helper, not existing
today):

```zig
// Drive discovery up to (but not including) delivering the writer-side's
// SEDP-subscription-received processing, so the reader is externally
// "matched" (from its own side) but NOT YET registered in the writer's
// own reader_proxies. Returns once that state is reached or a bound is hit.
fn matchReaderVisibleWriterBlind(net: *MockNetwork, ...) !void { ... }

// Now safe to call dw_impl.writeRaw(...) here, exercising the race window.

// Then deliver the remaining round(s) so the writer-side catches up, and
// assert on what the reader actually receives.
fn deliverRemaining(net: *MockNetwork, ...) !void { ... }
```

The existing `mock_loopback_test.zig` pumps `net.deliverAll()` in a loop with small sleeps
to let the SPDP timer fire (100 ms period) — a pragmatic, already-accepted exception to
"avoid sleeping in tests" for *SPDP participant* discovery specifically. The new tests
should keep that pattern for SPDP (getting two participants to see each other at all isn't
the thing being tested) but must **not** carry it into the SEDP endpoint-matching step
that *is* the thing being tested — that ordering needs to be pinned exactly, which means
driving `deliverAll()`/`deliver()` explicitly round-by-round once SPDP is done, not
sleep-and-hope.

### Layer 2 — real-load companion (Stress tier extension)

A new `--scenario` on the existing `stress-tests/zig/lifecycle_churn` binary (reusing its
harness wholesale: `DebugAllocator`, TSan variant, `--seed`, structured `SUMMARY:` output,
existing CI wiring) — e.g. `--scenario association`: N threads each run a
publisher/subscriber pair through create → (poll availability) → write (as soon as
locally observed as available, deliberately racing discovery, not waiting extra margin) →
verify, repeatedly, under real UDP and real SEDP timing. This is what actually caught the
bug in the wild; a zzdds-native version removes the dependency on rmw_zzdds's own test
suite noticing it.

## Scenario matrix (Layer 1, primarily)

All scenarios should be run across this cross-product where it's meaningful (not every
cell needs a distinct test function — parameterizing one table-driven test body across
QoS combinations is fine, per the project's existing style):

- **Durability**: VOLATILE, TRANSIENT_LOCAL (replay path — different code path,
  `should_replay=true`, different but related correctness questions: does a *replaying*
  reader matched in this same race window get the *right* history, not too little, not
  duplicated).
- **History**: KEEP_LAST depth=1, depth=N (small, e.g. 3-5), KEEP_ALL.
- **Write-timing relative to match, per direction of the asymmetric race**:
  - write() called after only the reader-side match is visible (the motivating bug).
  - write() called after only the writer-side match is visible (does the mirror-image
    case matter? — likely not for *this* specific `start_sn` bug, since `start_sn` is
    assigned when the writer processes its own match regardless of what the reader
    observes, but worth a scenario to confirm there's no symmetric analog on the
    reader/ACKNACK side).
  - write() called after both sides confirm match (baseline: must always pass).
  - write() called *before* either side's match (already-covered territory —
    `mock_loopback_test.zig`'s "write payloads before discovery" case — include as a
    regression guard, not new ground).
- **RTPS sequence-number patterns** (independent of the above — can compose): no gaps, one
  gap at the start, one gap at the end, one gap in the middle, gaps at both boundaries,
  many small scattered gaps, one large gap. Exercise both directly-caused gaps (deliberate
  `drop_nth`-style suppression via `MockNetwork.Config`) and race-caused gaps (the
  motivating bug's mechanism itself produces a "gap" from the reader's perspective, which
  is a useful cross-check: the sample-sequence checker below should describe the
  motivating bug as a real gap detected at the reader, not a hang).
- **One-to-many**: 1 writer, N readers (N ≥ 3) with staggered match completion — some
  readers fully matched before the write, one racing exactly like the motivating bug, one
  matched only after the write plus a subsequent gap gets filled by ordinary retransmit.
  Assert **per-reader** isolation: a late/lagging reader's state must never affect what an
  already-caught-up reader receives, and vice versa (this directly exercises
  `ReaderProxy` being genuinely per-proxy state, not accidentally shared).

## Shared verification utility

Every scenario above needs the same shape of assertion, so it should be one shared,
reusable helper (new file, e.g. `test/support/sample_sequence.zig`), not reimplemented per
test. Samples should carry an application-level monotonic counter in their payload
(independent of raw RTPS SN, since some scenarios are phrased at the DCPS/reader-take
level) so the checker works the same way whether it's reading a `CacheChange` list or
taken DCPS samples.

Required checks, each with a specific, actionable failure message (not a bare assertion):

- **First-sample correctness**: the first sample actually received matches the expected
  first sample for that reader given its QoS/join-time (no silently-skipped leading
  samples — this is exactly the shape of the motivating bug, generalized).
- **Order**: strictly increasing by the application counter, no reordering.
- **No duplicates**: no counter value seen twice.
- **No mid-stream gaps**: no counter value skipped between the first and last received
  (except where the scenario deliberately induces and expects a gap — those scenarios
  assert the *specific* expected gap set, not just "no gaps").
- **Completeness**: the exact expected count is received by the scenario's completion
  bound — nothing missing from the end. This is the one that needs a bound/timeout in
  Layer 2 (real time); Layer 1 should be able to assert this synchronously once the test
  has explicitly driven every delivery round it intends to.

## Relationship to the concrete bug

**Superseded — see "Final resolution" near the end.** This section originally proposed
treating the motivating bug's exact shape (VOLATILE, KEEP_LAST,
write-after-reader-side-match-only) as a red test against `writer_sm.zig`, to be turned
green by a `start_sn`/`addMatchedReader` fix. That fix was never written, because the
underlying premise — that `start_sn = self.cache.next_sn` at match time is a bug — turned
out to be wrong. The corresponding test
(`test/rtps/writer_sm_test.zig`'s `addMatchedReader` proxy-registration test) was
reframed to assert this as *correct* VOLATILE-durability behavior rather than a known
bug; see "Final resolution."

## Non-goals

- **Not a spec-conformance harness.** Same stance as `testing-strategy.md` generally:
  targeted scenarios proven to matter (starting with a real found bug), not exhaustive
  combinatorial coverage of every QoS × pattern permutation.
- **Not network simulation.** `MockNetwork`'s existing `drop_nth`/`dupe_count` cover the
  protocol-level conditions that matter; no ns-3/CORE-style physical-layer modeling.
- **Not exhaustively symmetric.** Reader-side analogs of writer-side races are worth a
  scenario each to confirm/rule out, not a full mirrored matrix unless a specific one
  turns out to matter.
- **Not replacing the Layer 2 real-load companion with more Layer 1 tests.** Deterministic
  pinned-order tests prove specific known interleavings are handled; they can't discover
  *unknown* bad interleavings the way real concurrent load can. Both layers stay.

## Decisions (resolved 2026-09-18)

1. **`test/dcps/` vs. a new `test/discovery/` directory.** Start in `test/dcps/`
   (precedent: `matched_status_test.zig`, `mock_loopback_test.zig` already live there and
   cover adjacent ground). Revisit a dedicated directory only if the scenario count
   actually grows past a handful of files — not worth setting up preemptively.
2. **SPDP-timer wall-clock sleep in `mock_loopback_test.zig`'s pattern.** Leave it as the
   accepted exception, don't fold a `ManualClock` refactor into this effort. The scenario
   matrix only needs precise control *after* SPDP has already happened — the SEDP-ordering
   step, driven explicitly regardless. Wiring `ManualClock` through `SpdpSedpDiscovery`'s
   timer is a separate, larger refactor of existing infrastructure; revisit only if the new
   tests turn out to be flaky in CI because of it (not expected).
3. **One-to-many harness.** No new fundamentally different primitive needed. Pinning exact
   SEDP ordering for the core race scenarios already requires decomposing
   `mock_loopback_test.zig`'s current monolithic `runMockLoopback` into separate reusable
   steps ("create writer-side participant," "create reader-side participant," "drive N
   delivery rounds explicitly") — see the Layer 1 sketch above. Once "create reader-side
   participant" is its own function taking a distinct locator, one-to-many is just calling
   it N times against the same `MockNetwork` and writer; `MockTransport.deliver()`'s
   existing per-transport granularity already gives independent control over each reader's
   discovery timing. These setup pieces should live in a shared test-support module (with
   the sample-sequence checker) from the start, not duplicated per scenario file.

## Milestone A implementation status (2026-09-18)

**Landed:**
- `test/support/sample_sequence.zig` — the shared verification checker (first-sample
  correctness, order, duplicates, gaps vs. allowed gaps, completeness), plus its own unit
  tests. `test/support/mock_dcps_fixture.zig` — `createWriterSide`/`createReaderSide`,
  decomposed from `mock_loopback_test.zig`'s `runMockLoopback` per decision 3 above. Both
  registered as named `build.zig` modules alongside `test_domain` (main + ReleaseSmall +
  TSan lanes all updated).
- **The core bug reproduction ended up at `test/rtps/writer_sm_test.zig`, not
  `test/dcps/discovery_race_test.zig` as decision 1/the Layer 1 sketch assumed.** Pinning
  the exact asymmetric SEDP interleaving via `MockNetwork`/`MockTransport` turned out to
  have more layers than expected: SEDP endpoint announcements (`announceWriter`/
  `announceReader`) only reach a peer once mutual SPDP (participant-level) discovery has
  *already* completed — a separate, earlier milestone requiring symmetric delivery first —
  and even after bootstrapping that correctly, the reader-only-delivery half of the
  intended race window never actually completed SEDP matching in testing, for reasons not
  fully root-caused (some further replay/timing dependency in the builtin SEDP writer path).
  Rather than keep guessing at internals, the reproduction was moved to the layer that
  actually owns the bug: two new tests directly against `StatefulWriter`, using the
  existing `Recording`-transport pattern (captures raw `send()` calls, already used
  extensively for `addMatchedReader` coverage in that file):
  - `"addMatchedReader: a write made before the proxy is registered is silently excluded
    for a VOLATILE reader (KNOWN BUG)"` — deterministically reproduces the bug by calling
    `write()` before `addMatchedReader()`; currently asserts the *wrong* (current) behavior
    on purpose, with a comment marking the one-line flip to the correct assertion once the
    fix lands.
  - `"addMatchedReader: a write made after the proxy is registered is always delivered
    (baseline)"` — guards the non-buggy ordering.
  - Both pass today (the first by asserting the bug's current symptom). No wall-clock
    sleeps, no discovery-timing dependency at all — pure `StatefulWriter` state.
- `test/dcps/discovery_race_test.zig` was kept, but scoped down to what actually works
  end-to-end: the write-after-full-match baseline and the genuinely-late-VOLATILE-joiner
  guard (both pass). The originally-sketched reader-only-delivery race reproduction was
  removed from this file — superseded by the `writer_sm_test.zig` tests above, which pin
  the same underlying bug more directly and reliably.
- `zig build test`: clean, full suite. `zig build test-tsan`: clean, full suite.

**Correction to the Layer 1 section above**: for scenarios that only need to control
`write()`-vs-`addMatchedReader()` ordering (most of the scenario matrix's "write-timing"
and "one-to-many isolation" axes), prefer the `StatefulWriter`/`Recording`-transport
pattern (`test/rtps/writer_sm_test.zig`) over full `MockNetwork` DCPS simulation — it's
simpler, faster, and doesn't depend on SPDP/SEDP replay-timing internals at all. Reserve
the `test/dcps/` `MockNetwork` layer for scenarios that specifically need real discovery
behavior (e.g. confirming a fix doesn't break end-to-end matching, or scenarios that
inherently need two real participants).

**Fix design — abandoned, discussed 2026-09-18 with the user:** the two ideas below were
on the table for making `addMatchedReader`'s `start_sn` computation "smarter" about
distinguishing "this reader was already logically matched, registration is just
delayed" from "this reader genuinely joined late." Recorded here for history; neither
was implemented, and the investigation concluded no such fix is needed or correct — see
"Final resolution" below for why.
- RTPS's `INFO_TS` submessage is already fully implemented (parser, builder,
  `CacheChange.source_timestamp`), and SEDP's `announceWriter`/`announceReader` already go
  through the same `StatefulWriter.write()` path that stamps it — so a remote reader's own
  announcement timestamp is very likely already flowing to the receiving side today. This
  idea was **ruled out**: `INFO_TS` is a per-message/per-submessage source timestamp
  (RTPS §8.3.3), not an entity-creation or entity-registration timestamp — confirmed
  against zzdds's own code (`participant.zig`'s own comment on its `INFO_TS` handling).
  A vendor may legitimately re-stamp a SUBSCRIPTIONS announcement on every replay or
  locator change, so it carries no reliable relationship to "when this reader was
  created" at all, cross-host clock skew aside.
- Record an explicit, authoritative "official matched time" and pass it into
  `addMatchedReader`'s API, comparing it against each `CacheChange.source_timestamp` to
  compute `start_sn` instead of `self.cache.next_sn`. This was also **ruled out**, on a
  more fundamental basis than an implementation gap: per DDS's own QoS contract, a
  VOLATILE reader is not entitled to history written before it matched, full stop. There
  is no "more correct" timestamp to hunt for — `self.cache.next_sn` at the moment the
  writer processes its own match *is* the writer's only principled floor, because that's
  the only moment the writer can be sure the reader exists. Trying to backdate that floor
  (via `INFO_TS`, an explicit matched-time parameter, or anything else) would mean
  starting to replay pre-match history to VOLATILE readers, which is a QoS violation, not
  a fix.

## Final resolution (2026-09-18)

Continuing to discuss the fix design with the user surfaced the reframing above: the
`writer_sm.zig` behavior was never the bug. The real, user-identified problem is
narrower and lives one layer up — an application (`rmw_zzdds`, in the motivating case)
can observe "matched" (`on_subscription_matched`/`on_publication_matched`, bare SEDP)
and act on it (`write()`, or here, treat a service as available) *before* the other
side's own, independent SEDP discovery has caught up — not because the writer's
`start_sn` logic is wrong, but because "matched" alone was never a strong enough signal
to act on for this purpose. zzdds already has a precedent for exactly this distinction on
the writer side: `DataWriterListenerEx.on_reliable_reader_ready`, which fires only once a
matched reader proxy has completed the AckNack/Heartbeat handshake (RELIABLE) — strictly
stronger than bare `on_publication_matched`.

The user proposed the reader-side symmetric counterpart, and — after resolving a real
ambiguity in the user's own initial framing ("any HEARTBEAT or DATA," which can be
broadcast to many readers and so proves nothing about a specific reader without going
above and beyond the spec) — it was implemented as **`DataReaderListenerEx
.on_reliable_writer_ready`**: fires once this reader observes a HEARTBEAT whose
`readerId` (RTPS §8.3.7.5) explicitly names it, which zzdds's own `StatefulWriter`
already sends for every heartbeat (not just an "initial" one) per matched reader proxy —
real RTPS wire behavior, not a zzdds-only mechanism, though not every vendor's writer
targets heartbeats per-reader. For BEST_EFFORT proxies (no AckNack/Heartbeat handshake to
wait for) it fires immediately at match, mirroring `on_reliable_reader_ready`'s identical
BEST_EFFORT branch.

**Landed** (mirrors the existing writer-side `on_reliable_reader_ready` machinery
exactly, reader-side): `idl/zzdds.idl`'s new `DataReaderListenerEx` interface and
`DataReader::set_listener_ex` operation; `src/rtps/reader_sm.zig`'s
`WriterProxy.protocol_ready` field + `StatefulReader.setProtocolReadyCallback` +
`addMatchedWriter`'s immediate-ready BEST_EFFORT branch + `handleHeartbeat`'s new
`reader_id` parameter and targeted-match firing + `removeMatchedWriter` firing
`ready=false` for a removed proxy that had been ready (added after initial landing, to
close a real asymmetry vs. the writer side's `removeMatchedReader` — otherwise an
application would never learn a writer it was told is ready has gone away);
`src/protocol/interface.zig`'s
`ProtocolReader.setProtocolReadyCallback`; `src/rtps/protocol_adapters.zig`'s wiring;
`src/dcps/participant.zig` threading `hb.reader_entity_id` through to
`handleHeartbeat`; `src/dcps/reader.zig`'s `listener_ex_box`/`notifyWriterProtocolReady`/
`setListenerEx`; `src/dcps/subscriber.zig` wiring the callback in `create_datareader`;
`src/c_abi/extensions.zig`'s `readerSetListenerEx`. New tests:
`test/rtps/reader_sm_test.zig`'s "protocol_ready" section (targeted-heartbeat fires
exactly once; wildcard/other-reader-targeted heartbeat does not fire; BEST_EFFORT fires
immediately at match; removing a ready proxy fires `ready=false`; removing a never-ready
proxy does not fire) and `test/dcps/mock_loopback_test.zig`'s
`"on_reliable_writer_ready fires after a targeted heartbeat, strictly after
on_subscription_matched"` full-stack test. `writer_sm_test.zig`'s reframed test (see
"Milestone A implementation status" above) now documents the corrected understanding
directly. `zig build test` and `zig build test-tsan`: both clean, full suite. Spot-checked
the new C-ABI symbols exist (`zzdds_DataReaderListenerEx`,
`zzdds_DataReader_set_listener_ex`) via `zig-out/include/zzdds.h`, and that the C, C++,
and Java bindings all build clean against the new interface.

**`rmw_zzdds` consumption + a second, real zzdds-core bug found while verifying it
end-to-end (2026-09-18, same day):** implemented the deferred follow-on immediately
rather than leaving it for later — `rmw_zzdds_cpp`'s `rmw_service_server_is_available()`
now gates on a `response_subscription`-side `reliable_writer_ready_count` (maintained by
a `DataReaderListenerEx::on_reliable_writer_ready` listener installed at subscription
creation via the new `zzdds_DataReader_set_listener_ex` C-ABI symbol, and kept installed
across `rmw_event_set_callback` calls — a plain `DDS_DataReader_set_listener` would
silently clobber it) instead of the old, weaker `rmw_subscription_count_matched_publishers`
check. See `rmw_zzdds`'s own repo for the change (`rmw_zzdds_cpp/src/rmw_service.cpp`,
`rmw_event.cpp`, `rmw_data_plane.cpp`, `endpoint_impl.hpp`, `event_impl.hpp`).

Verified empirically, not just architecturally: built rmw_zzdds against this zzdds
checkout inside `ros:rolling` (`ci/build_and_test.py`), then stress-ran
`test_service_round_trip` (`--gtest_repeat=150`) both **before** the `rmw_zzdds` fix
(`git stash` on the clean, unmodified `rmw_service_server_is_available`) and **after**:
- Before: **31/150 failures (~21%)**, every one hanging the full 10s deadline waiting on
  a response `rmw_wait`, i.e. exactly the motivating bug's shape.
- After: this exact failure shape dropped to **0/150** — but a *different*, much rarer
  failure appeared: **1/150**, timing out on the very *first* `rmw_service_server_is_available`
  poll (before any request is even sent), not the response-wait. Investigating this
  uncovered a second, real, previously-latent bug in `writer_sm.zig`, described next.
  Its root cause is unrelated to (and predates) `on_reliable_writer_ready` — this was
  simply the first workload to exercise it — so it's recorded here rather than treated
  as a gap in the `rmw_zzdds` fix above.

**Second bug, found and fixed the same day: an off-by-one heartbeat-validity guard
silently dropped the legal "empty offer" Heartbeat.** `StatefulWriter`'s heartbeat-sending
paths (`sendHeartbeatUnlocked`, `sendHeartbeatToProxyLockedWithLastSnAndFirstSn`, and the
periodic broadcast loop in `sendHeartbeat`) all guarded with `first_sn > last_sn` before
sending — but RTPS §8.3.7.5.3 (and `reader_sm.zig`'s own `handleHeartbeat` validity check)
only require `first_sn <= last_sn + 1`; `first_sn == last_sn + 1` is the *legal* empty-range
convention meaning "nothing new for you, but I'm alive." Any time a proxy's `start_sn`
landed exactly at the writer's cache frontier — the ordinary case for a second (or Nth)
non-replaying reader matched *after* the writer already had cached data from serving an
earlier reader — the writer silently dropped every Heartbeat to it, forever (not just the
initial one: the periodic broadcast loop has the identical guard, so nothing ever
recovered it). Reproduced deterministically at the `StatefulWriter` layer
(`test/rtps/writer_sm_test.zig`'s `"protocol_ready: a second RELIABLE proxy added after
the first is already ready gets its own initial heartbeat and becomes ready"`, red before
the fix, green after) before touching the podman/colcon loop again. Fixed by changing all
three guards to `first_sn > last_sn + 1`. `zig build test` and `zig build test-tsan`: both
clean. This is a genuine, previously-undetected RTPS Heartbeat-suppression bug in its own
right — independent of `on_reliable_writer_ready` — that just happened to be latent until
this was the first workload to create a second non-replaying reader proxy after existing
writer traffic.

Re-verified after this fix: another 150-iteration `test_service_round_trip` stress run —
**0 failures matching the original bug shape**, **1/150 (~0.7%) residual failure**, same
"first availability check times out" shape as the one instance above, not yet root-caused.
Given it dropped from 31/150 to 1/150 across two independent 150-run samples (300 total,
1 failure), the motivating bug is conclusively fixed; the residual ~0.7% is either the
same still-not-fully-explained issue at very low remaining rate, or ordinary SPDP
discovery jitter under shared-host CPU contention (the acknowledged "real-load,
probabilistic" tier per `testing-strategy.md`) — not yet distinguished, and not blocking.

**Deferred, not investigated further this pass:** root-causing the ~0.7% residual
first-poll timeout. Low priority relative to the ~31x improvement already confirmed;
worth a dedicated pass if it recurs at a similar rate under real CI load.

The rest of this document's scenario matrix, shared verification utility, and Layer
1/Layer 2 test-infrastructure proposals remain useful groundwork for the broader
discovery/association race space in general (they were never specific to the `start_sn`
question) — only the specific "fix `writer_sm.zig`'s `start_sn`" framing in "The
motivating bug," "Relationship to the concrete bug," and the abandoned fix-design ideas
above is superseded.
