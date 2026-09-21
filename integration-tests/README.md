# zzdds integration tests

Real cross-process tests, built once per binding (C/C++/Java/Zig) and run
cross-binding, each targeting one specific DCPS behavior with a plausible
use case. Full rationale and structure decisions in
[`docs/design/integration-test-tier.md`](../docs/design/integration-test-tier.md).

Distinct from the other two directories at the repo root:

- **`examples/`** is demonstration-first -- reads well as a tutorial, light
  assertions. This tier is not: awkward-but-correct setup is fine if it's
  what proving the target behavior needs.
- **`stress-tests/`** is concurrency/lifecycle-under-load, Zig-native only,
  xfail-tracked. This tier has no thread pools or churn loops -- one writer,
  one reader (or a small fixed handful) doing one plausible thing, with a
  hard correctness assertion on the specific DCPS behavior under test.

Layout mirrors `examples/` (not `stress-tests/`'s Zig-only layout, since
every scenario here needs all four bindings):

```
integration-tests/
  run_all.py                       orchestrator -- builds + runs everything (--strict for CI)
  c/<scenario>/
  cpp/<scenario>/
  java/<scenario>/
  zig/<scenario>/
  interop/<scenario>_cross_binding_test.py   cross-binding runner + assertions
```

Run everything:

```
cd zzdds && zig build -Dc-binding=true -Dcpp-binding=true -Djava-binding=true install
ZZDDS_ZIG_OUT="$PWD/zig-out" integration-tests/run_all.py           # dev: skips what isn't built
ZZDDS_ZIG_OUT="$PWD/zig-out" integration-tests/run_all.py --strict  # CI: any skip is a failure
```

Reuses `examples/_common.py` for build/process helpers (the same
`sys.path.insert(...)` trick `stress-tests/run_all.py` uses) -- no separate
shared-helper module here.

## Scenarios

### `coherent-sets`

Tests PRESENTATION `access_scope=GROUP` coherent/ordered-access atomicity
across two DataWriters under one Publisher: a vehicle telemetry publisher
that must never let a subscriber observe a `Position` update without its
paired `Velocity` update (or vice versa). Each of the 20 ticks writes both
under one `begin_coherent_changes()`/`end_coherent_changes()` bracket, with
a deliberate ~8ms gap between the two writes so back-to-back UDP delivery
can't accidentally make a broken reader-side gate look correct.

The subscriber synchronizes via a `WaitSet` with a `ReadCondition` per
reader (`on_data_on_readers` has zero firing sites in zzdds today -- see
`docs/roadmap.md`) and asserts, after every `begin_access()`/`end_access()`
bracket, that the two readers' taken-`group_id` sequences stay exactly
equal-length and pairwise equal -- a direct test of reader-side coherent-set
gating, not a count-per-time-window guess (see
`docs/design/integration-test-tier.md` for why that distinction matters,
given this project's history with the `dds-rtps` CoherentSets flake).

Cross-binding matrix: the same 8-of-12-pair subset (4 same-binding + a
4-pair cross-binding cycle) `examples/interop/raw_loan_cross_binding_smoke_test.py`
uses, for the same reason -- see that script's docstring.

### `delete-contained-entities`

Tests bulk-teardown correctness across the C-ABI: a "session" role builds a
small entity tree (2 DataWriters, a plain DataReader, a
ContentFilteredTopic-backed DataReader, a WaitSet-attached ReadCondition)
under one participant, exchanges a few samples with a "peer" role, then
tears the whole tree down in one shot via
`DomainParticipant.delete_contained_entities()` instead of deleting each
child first -- exercising the cascade, not manual teardown.

Core assertions: `delete_contained_entities()` returns `RETCODE_OK`, the
immediately-following `delete_participant()` ALSO returns `RETCODE_OK` (per
spec this only succeeds if the cascade genuinely left nothing dangling), no
matched-status listener ever fires once the session's `torn_down` flag is
set, and the peer observes matched-current-count reach zero on every
matched entity within a generous timeout. Found and fixed a real bug this
way: `vtDeleteContained` never drained `cft_topics`, so any app using a
ContentFilteredTopic always got `PRECONDITION_NOT_MET` from
`delete_participant()` right after a "successful" `delete_contained_entities()`
-- see `docs/roadmap.md`.

Cross-binding matrix: the same 8-pair subset as `coherent-sets`, with the
session role and peer role assigned per pair the same way `coherent-sets`
assigns publisher/subscriber.

### `sample-rejected-lost`

Tests SAMPLE_REJECTED and SAMPLE_LOST -- a "slow consumer" scenario, three
topics. `RejectedTopic` (RELIABLE, KEEP_ALL): a reader with tight
`resource_limits` (`max_samples`/`max_samples_per_instance` = 3) deliberately
never drains until it has confirmed rejection, so the publisher's 5
back-to-back writes overflow it. `LostTopic` (RELIABLE, KEEP_LAST depth=1,
TRANSIENT_LOCAL): the writer writes+evicts 5 samples *before* any reader is
matched at all, and the subscriber deliberately defers creating that reader
until a `SyncTopic` signal confirms the publisher is done writing -- a
genuine, deterministic late-join gap (the writer's HEARTBEAT reveals a
firstSN gap to a reader with nothing yet acked), not a real-time ack race.
`SyncTopic` exists purely so the subscriber never checks final status while
the publisher might still be mid-write.

Core assertions: RejectedTopic's rejected-count + successfully-buffered-count
== 5 (a conservation invariant, not a hardcoded split, matching this
project's own `dds-rtps` CoherentSets flake lesson about not asserting exact
counts where a property suffices); LostTopic's surviving last sample
(seq=4) is still delivered correctly even though earlier ones were lost.

An earlier design tried triggering SAMPLE_LOST by racing fast writes against
an *already-matched* reader, hoping `writer_sm.zig`'s KEEP_LAST-eviction GAP
notification would fire in time -- it didn't, empirically: localhost
round-trips are fast enough that each sample got acked before the next write
evicted it. The late-join design above is what actually works
deterministically. No zzdds core bug was found building this scenario --
unlike `coherent-sets` and `delete-contained-entities`, both mechanisms
worked exactly as documented once the scenario itself was designed
correctly.

Cross-binding matrix: the same 8-pair subset as `coherent-sets`.

### `enable-defer`

Tests `enable()`/`autoenable_created_entities` (ENTITY_FACTORY QoS) -- a "configuration
phase" scenario: a configurer sets `autoenable_created_entities=false` on its own
participant, builds a Publisher and DataWriter under it (both come in disabled), proves
`write()` on the still-disabled writer fails, proves enabling the writer before its own
Publisher returns `PRECONDITION_NOT_MET`, then enables the Publisher and writer top-down.
A peer proves it observes zero matching for a window comfortably inside the configurer's
own pre-enable delay, then matches and receives cleanly once enabling actually happens.

This turned out not to be a test-coverage gap at all: `enable()` was a uniform no-op
across every entity type before this landed -- see `docs/roadmap.md`'s Integration-tier
entry for the full feature-implementation writeup, the real bugs building this scenario
found (a discovery-matching path that ignored disabled entities' state entirely, and a
native-Zig write path that bypassed the `NOT_ENABLED` guard), and two over-broad
`NOT_ENABLED` guards from that implementation this scenario found and got corrected
(default-QoS/copy-from-topic-QoS operations and navigational parent/topic getters must
not be gated -- they configure or navigate the tree, they don't operate the entity).

Cross-binding matrix: the same 8-pair subset as `coherent-sets`, with the configurer role
and peer role assigned per pair the same way `coherent-sets` assigns publisher/subscriber.
