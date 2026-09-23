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

### `wait-for-historical-data`

Tests `wait_for_historical_data()` -- a late-joining reader scenario directly modeled on
`examples/*/catchup` (a publisher writes a TRANSIENT_LOCAL historical batch with no reader
matched yet, then a live batch once one matches), but held to this tier's harder
correctness bar instead of that example's demonstration-first one: proving the call
"unblocks only once durable replay actually lands, not on a timer"
(`docs/design/dcps-api-coverage-audit.md`'s own phrasing for this scenario).

Two assertions, in order, on the same reader:

1. **Negative case**: the subscriber calls `wait_for_historical_data()` with a short,
   non-zero `max_wait` immediately after creating its reader, while the harness guarantees
   no publisher process exists anywhere on the domain yet -- deterministic, not a timing
   race, since a call with genuinely zero writers to wait for cannot return `RETCODE_OK` no
   matter how long it's given. Requires `RETCODE_TIMEOUT`. This closes the
   `wait_for_historical_data()`-should-time-out negative case `docs/roadmap.md` recorded as
   deliberately out of scope for the `catchup` example itself, and is the same shape as the
   regression `test/dcps/wait_for_historical_test.zig`'s "non-zero max_wait with no matched
   writer times out" test covers at the Zig-unit level (both exist because an earlier,
   real bug made this case return `RETCODE_OK` immediately purely because discovery hadn't
   matched a writer *yet*, not because there was truly nothing to wait for).
2. **Positive case**: only once the subscriber has printed its own "ready for publisher"
   log marker (which the cross-binding harness polls for -- see
   `interop/wait_for_historical_data_cross_binding_test.py`'s `wait_for_marker()` -- before
   starting the publisher process at all) does it make a second, generous-timeout call and
   confirm every one of the 8 historical samples actually arrived by the time that call
   returns `RETCODE_OK`, not just that the return code itself was `RETCODE_OK`.

Cross-binding matrix: the same 8-pair subset as `coherent-sets`, with subscriber and
publisher roles assigned per pair the same way `coherent-sets` assigns them.

### `ignore-entities`

Tests all four `DomainParticipant` `ignore_*()` operations --
`ignore_topic()`, `ignore_participant()`, `ignore_publication()`, `ignore_subscription()`
-- the only scenario in this tier that needs **three** processes instead of two: an
`ignorer` (the entity under test), a `peer` (provides the writers/readers for
`ignore_topic`/`ignore_publication`/`ignore_subscription`, plus an unignored `ControlTopic`
sanity check), and a `bystander` (a throwaway third participant, needed because
`ignore_participant()` would blackhole *everything* from `peer`'s participant if applied to
it, which would break the other three ops' shared use of `peer`).

**The central, easy-to-get-wrong fact this scenario is built around**: `ignore_topic()`/
`ignore_publication()`/`ignore_subscription()` are a strictly one-sided, *local* filter (DDS
spec wording: "locally ignore"). They change only what the ignorer's own participant
decides counts as a match -- the other side has no idea it's been ignored and legitimately
keeps reporting itself matched from its own perspective. `ignore_participant()` is the one
exception: in zzdds's implementation it additionally tears down the underlying SEDP proxy
exchange with that prefix, but `bystander`'s own side *still* sees itself matched too (it
has no idea it's been ignored either) -- so every assertion in this scenario lives entirely
on the ignorer's own side (see `c/ignore-entities/src/ignorer.c`'s header comment for the
full explanation); `peer.c`/`bystander.c` deliberately never assert their own match-count
drops to zero, only that no ignored writer's samples were ever received by anyone who
shouldn't have gotten them (and, for `SubscriptionIgnoredTopic`, that `peer`'s reader never
received any of the ignorer's real, post-ignore writer's samples either -- the one check the
non-ignoring side of a pairing *can* make).

Per-op mechanism:

- **`ignore_topic()`**: resolved from the ignorer's own local topic instance handle -- no
  discovery needed at all -- called before `peer` (or anyone) exists, so the block is
  unconditional from the very first SEDP announcement onward.
- **`ignore_participant()`**: `bystander` deliberately delays creating its writer
  (`PRE_WRITER_DELAY`, same convention as `enable-defer`'s pre-enable delay), giving the
  ignorer a wide, comfortable window to discover (`get_discovered_participants()`) and
  ignore its participant handle first -- but only because `bystander` doesn't start until
  after ignorer is set up and `peer` doesn't start until after ignorer has confirmed
  ignoring `bystander` (see "Process ordering" below); `get_discovered_participants()`
  makes no ordering promise across multiple simultaneously-known participants, so without
  that strict sequencing `handles[0]` could just as easily be `peer`'s handle.
- **`ignore_publication()`/`ignore_subscription()`**: these target one specific remote
  entity's handle, learnable only by discovering it -- so each uses a throwaway "probe"
  reader/writer purely to learn `peer`'s counterpart handle via
  `get_matched_publications()`/`get_matched_subscriptions()`, ignores it, deletes the probe,
  then creates the real entity under test and confirms it never matches (or, for
  `ignore_publication()`, never receives any of `peer`'s continuously-written samples).

Building this scenario found and fixed a real bug: the retroactive-match scan
(`participant.zig`'s `subAnnounceProtoReader`/`pubAnnounceProtoWriter`, which exist to match
a newly-created local reader/writer against an already-discovered remote entity) never
checked the ignore lists at all -- so a remote entity discovered *before* being ignored
stayed retroactively matchable to a local reader/writer created *after* the ignore call,
exactly backwards from the ignore operations' contract. Confirmed via this scenario's own
real cross-process run (a Zig-unit-test mock reproduction attempt didn't reliably exercise
this path); fixed by mirroring the live-discovery callbacks' own three ignore-list guards
into both retroactive scans. See `docs/roadmap.md`.

**Process ordering is load-bearing here in a way no other scenario needs -- a strict
THREE-phase start, not just "ignorer first"**: (1) ignorer finishes its own setup and
prints "ready for bystander"; (2) only then does `bystander` start, and ignorer's
`get_discovered_participants()` poll can safely treat `handles[0]` as unambiguously
`bystander`'s handle, because `bystander` is provably the only participant that could
exist yet; (3) only once ignorer prints "ignore_participant() applied to bystander." does
`peer` start. `interop/ignore_entities_cross_binding_test.py`'s `wait_for_marker()`
enforces both gates by polling ignorer's own log (the same pattern
`wait-for-historical-data`'s interop test uses for its single gate). Skipping the middle
gate (starting `peer` and `bystander` together) is exactly the bug an earlier version of
this harness had: `get_discovered_participants()` doesn't promise anything about the order
of simultaneously-discovered participants, so `handles[0]` could -- and intermittently did
-- turn out to be `peer`'s handle instead of `bystander`'s, silently ignoring `peer` for
the rest of the run. This looked exactly like a networking flake from the symptoms alone
(ignorer's later probe against `peer` would time out) and took substantial live diagnosis
(direct `ss -ulnp` port inspection during a captured failure, then per-topic
`onWriterDiscovered`/retroactive-scan tracing) to actually distinguish from one.

Fixing the ordering bug alone surfaced a second, unrelated bug immediately behind it,
100% reproducible and specific to C/C++-as-ignorer triples: `ignorer.c`/`ignorer.cpp` only
`fflush(stdout)`ed after their *first* required marker; every later one (starting with
`"ignore_participant() applied to bystander."`) sat in glibc's fully-buffered (non-tty)
stdio buffer, invisible to the log file `wait_for_marker()` polls live, until the harness's
timeout killed the process and discarded the buffer -- even though the ignorer had, in
every case, already correctly discovered and ignored `bystander` internally (confirmed with
temporary instrumentation in `participant.zig`'s shared, binding-agnostic
`onParticipantDiscovered`/`vtGetDiscoveredParticipants`/`vtIgnoreParticipant`). Zig's
`std.debug.print` and Java's `println` don't share this failure mode, which is why only
C/C++-as-ignorer triples ever failed. Fixed by adding `fflush(stdout)`/`std::fflush(stdout)`
after every required marker print in both files. Also tried, and reverted, an `IFF_RUNNING`
check in zzdds's interface enumeration (`src/transport/monitor/polling.zig`) along the way,
on the theory that a carrier-down interface (e.g. a dormant Docker bridge) could be
enumerated first and become the `IP_MULTICAST_IF` sends go out on -- reverted because this
VM's real, working `eth0` also reports no `IFF_RUNNING` bit despite `ip link show` showing
`LOWER_UP`, so the check excluded every non-loopback interface here and made things
strictly worse; left as a comment for future reference rather than landed. See
`docs/roadmap.md` for the full trail.

Cross-binding matrix: 4 same-binding self-tests (ignorer/peer/bystander all one language)
plus a 4-triple cross-binding rotation covering every language in every one of the three
roles at least once -- 8 triples total, matching every other scenario's 8-pair sizing,
adapted for a third role.

### `cft-reconfigure`

Tests `set_expression_parameters()`'s runtime `ContentFilteredTopic` reconfiguration --
"does changing parameters without recreating the CFT actually re-filter subsequent
samples" -- distinct from the stress `cft` scenario's concurrency-safety coverage (a UAF
between reconfigure and receive-thread filter eval, already found and fixed there). Also
exercises the CFT introspection surface (`get_filter_expression`/
`get_expression_parameters`/`get_related_topic`) the API audit flags as completely
untested: "CFT is set once at creation, never read back or changed".

Two processes, `publisher` and `subscriber`, reusing one minimal `CftEvent{seq}` type for
both the real data topic and a `GoTopic` signal channel (same minimalism convention
`sample-rejected-lost`'s `SyncTopic` follows). The subscriber creates two DataReaders on
the same underlying topic: a plain, unfiltered "witness" reader (proves what actually
arrived over the wire, independent of the filtered reader's own behavior) and a CFT reader
(filter `"seq >= %0"`, initial parameter `"1000"` -- unreachable by phase1's seq range, so
every phase1 sample is filtered out). The publisher writes phase1 (seq 0..4) once both
readers have matched; the subscriber confirms via the witness reader that all 5 arrived,
confirms via the filtered reader that zero passed the filter, then calls
`set_expression_parameters(["3"])` on the *same, already-live* CFT -- no recreation of the
CFT or its DataReader -- and read-back-verifies the new parameter. It signals the publisher
over `GoTopic`, which then writes phase2 (seq 5..9) on the same DataWriter.

The core assertion: the filtered reader's final set must be *exactly* `{5,6,7,8,9}`.
Phase2 correctly re-filtered against the new threshold (proving live reconfiguration
works) -- and, just as importantly, phase1's seq=3 and seq=4 (both `>= 3`, the *new*
threshold) never retroactively appear, proving CFT filtering is a one-time decision made
at receive time, not something replayed against a reader's own history when parameters
change.

**Zig-native gotcha found building this**: the raw `zzdds.registerTypeSupport()` call
(used directly by Zig-native apps, bypassing the generated `TypeSupport.register()`
convenience wrapper C/C++/Java call through) does not wire up `TypeSupport.get_field`
automatically -- without it, a CFT reader silently receives *everything* unfiltered, no
error anywhere, since `get_field == null` degrades to "CFT evaluation deferred" rather
than failing loudly. Every zidl-generated Zig type provides a matching `getFieldFromCdr`
function for exactly this; must be passed explicitly:
`.get_field = CftEvent.getFieldFromCdr`. Found because the C/C++/Java ports all worked
immediately while the Zig port's filtered reader passed everything through unfiltered on
the first run -- see `zig/cft-reconfigure/subscriber.zig`'s `registerTypeSupport()` call
comment.

**Timeout note**: `MATCH_TIMEOUT_MS` is 40s here, not the 20s every other match-wait in
this tier uses -- this scenario waits for *two* readers to match (witness + filtered),
twice the SEDP discovery work of a typical 1-reader scenario, and showed intermittent
timeouts specifically as the first Java pair run right after a from-scratch 4-binding
rebuild (JVM cold-start contending with residual build-tail CPU/IO load). The
subscriber's own `WITNESS_TIMEOUT_MS` (45s) is bumped to match, since both processes start
together and race the same environmental delay rather than one waiting on the other
sequentially -- see `publisher.c`/`subscriber.c`'s matching comments.

Cross-binding matrix: the standard 4 same-binding self-tests plus a 4-pair cross-binding
rotation, 8 pairs total, matching every other 2-process scenario's sizing.

### `source-timestamp`

Tests the `_w_timestamp` family (`write_w_timestamp()`/`dispose_w_timestamp()`) --
does an explicit, caller-supplied source timestamp genuinely propagate end-to-end to
`SampleInfo.source_timestamp` on the receiving side, or does something along the way
silently substitute "now"? `register_instance_w_timestamp()`'s timestamp is a documented,
deliberate no-op in zidl (delegates straight to plain `register_instance()`, covered by
zidl's own backend unit tests), so this scenario doesn't duplicate that; `write_w_timestamp()`
and `dispose_w_timestamp()` share the identical wire-timestamp plumbing in zzdds core
(`writer.zig`'s `vtWriteRaw`/`rtpsTimestampFromRaw`, keyed only by `WriteKind`), so
exercising both is a real, non-redundant check on that one shared path.

Two processes, `publisher` and `subscriber`, one keyed `TimestampEvent{id, seq}` type
(`id` fixed at 0 -- a single instance is all `dispose_w_timestamp()` needs a real target
for). The publisher writes 5 samples via `write_w_timestamp()` with deliberately
fabricated, deterministic explicit timestamps (`WRITE_BASE_SEC+seq`, ~11.5 days since the
epoch -- nowhere near whatever the real wall-clock time is during an actual test run, so
a bug that silently substitutes a real clock reading shows up as an immediate, unambiguous
wrong-value failure, not a flaky near-miss), then disposes the instance via
`dispose_w_timestamp()` with its own distinct explicit timestamp, including a nonzero
nanosecond component to prove nanosecond-level (not just whole-second) propagation.
The subscriber asserts an *exact* match on `SampleInfo.source_timestamp` for all 6
samples (5 alive + the disposed-instance entry).

**Found and fixed a real zzdds core bug on the very first real cross-process run**:
`src/util/time.zig`'s `RtpsTimestamp.fromTime()`/`.toTime()` (and `RtpsDuration.fromDuration()`)
used plain truncating integer division for the RTPS wire fraction<->nanosecond conversion
(fraction is 1/2^32-second units, not nanoseconds). Composing floor(floor(x)) across the
round trip systematically loses ~1ns for nearly any nonzero nanosecond value -- caught
immediately: the dispose sample's explicit nanosecond `123456789` came back as
`123456788`. `RtpsDuration.toDuration()` already did this correctly (round-to-nearest,
with carry-into-seconds handling for the rare case that rounds up to a full extra
second); the fix brings the other three conversions in line with it. Zero write-side
(`nanosec=0`) samples never triggered this, since 0 is trivially exact under either
truncation or rounding -- only the dispose call's nonzero nanosecond exposed it. See
`docs/roadmap.md`.

Cross-binding matrix: the standard 4 same-binding self-tests plus a 4-pair cross-binding
rotation, 8 pairs total, matching every other 2-process scenario's sizing.

### `liveliness-lost`

Tests `on_liveliness_lost()`/`get_liveliness_lost_status()` -- "zero coverage anywhere"
per the API audit -- for the two LIVELINESS kinds `presence` (`examples/{c,cpp,java,zig}/presence`)
deliberately left out to keep itself a single-scenario example: AUTOMATIC and
MANUAL_BY_PARTICIPANT. `presence` already covers MANUAL_BY_TOPIC, `assert_liveliness()`,
and `on_liveliness_changed`'s full ONLINE->OFFLINE->ONLINE recovery cycle; this scenario
is a one-way lapse (no recovery) targeting a sharper, more spec-precise question than "did
a writer go silent": *what counts* as a liveliness assertion differs by kind, and it's
easy to get backwards.

Two DataWriters (one AUTOMATIC, one MANUAL_BY_PARTICIPANT, both `lease_duration=2s`) write
continuously at the same cadence (every 0.5s, ~8s total) for the whole run, deliberately
never calling `assert_liveliness()` at all:

- AUTOMATIC: per spec, any `write()` itself counts as a liveliness assertion. Expected:
  `on_liveliness_lost` never fires, despite the same 2s lease as the other writer.
- MANUAL_BY_PARTICIPANT: per spec, only an explicit `assert_liveliness()` call counts --
  `write()` does not. Expected: `on_liveliness_lost` *does* fire (repeatedly, roughly once
  per lease period it stays silent -- asserted as `>= 1`, not an exact count), *despite*
  writing continuously the entire time. This is the surprising, easy-to-invert case an
  implementation bug could plausibly get backwards.

The subscriber side runs the same differential independently via `on_liveliness_changed`:
an AUTOMATIC reader's `alive_count` must never drop to 0; a MANUAL_BY_PARTICIPANT reader's
must drop to 0 at least once -- extending `presence`'s (MANUAL_BY_TOPIC-only) reader-side
coverage to these two kinds too, not just the writer's own self-observation.

**C++ listener-lifetime bug found while building this (own harness code, not zzdds)**:
the first draft factored topic/QoS/entity creation into `create_writer()`/`create_reader()`
helper functions that constructed the `shared_ptr<Listener>` as a *local* variable inside
the helper -- which goes out of scope and gets destroyed the moment the helper returns,
since `create_datawriter()`/`create_datareader()` take the listener as a `shared_ptr`
parameter but don't necessarily extend its lifetime beyond the call. Both processes
segfaulted the instant SEDP matching tried to fire a callback into the now-dangling
listener. Every other scenario this tier declares its listener directly in `main()`'s own
scope; this was the first time a helper function was introduced to reduce duplication
across the two DataWriter/DataReader pairs, and it broke that discipline. Fixed by having
`main()` construct and hold the listener `shared_ptr`s itself, passing them *into* the
helpers rather than letting the helpers own them.

**Timeout note**: `MATCH_TIMEOUT_MS` is 40s here, not the 20s every other match-wait in
this tier uses -- same precedent as `cft-reconfigure`: this scenario creates *two*
writers/readers per process (AUTOMATIC + MANUAL_BY_PARTICIPANT), twice the SEDP discovery
work of a typical 1-writer scenario, and showed the same environment-contention-driven
"0 matched" timeout under a from-scratch 4-binding rebuild that `cft-reconfigure` did.
Isolated reruns are reliably clean (3/3); full-suite reruns are clean more often than not
(2/3) with every failure a pure discovery-timing miss, never wrong data -- the same
accepted category `cft-reconfigure`'s own writeup documents.

Cross-binding matrix: the standard 4 same-binding self-tests plus a 4-pair cross-binding
rotation, 8 pairs total, matching every other 2-process scenario's sizing. This was the
last scenario in the Integration-tier backlog to land, closing out the whole spec doc's
list.
