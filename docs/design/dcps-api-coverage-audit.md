# DCPS API Coverage Audit (2026-08-14)

Living doc, updated as gaps close — see entries below marked with a later date.
References to `examples/` mean this repo's `examples/` tree; the standalone
`zz-iot/zzdds-examples` repo it originally referred to was folded in on 2026-08-26
(`CHANGELOG.md`) and is not otherwise referenced by name below.

Cross-process/cross-binding DCPS API coverage, audited across every harness that runs
zzdds as a real separate process against another DDS application: the dds-rtps vendor
matrix, `examples/`'s 12 per-binding example ports, and its `interop/`
cross-binding smoke scripts. Does **not** cover zzdds's own Zig-native unit test suite
(`zig build test`) — see `docs/testing.md`/`docs/design/testing-strategy.md` Tier 1/2 for
that. The distinction matters: an API can be well-covered at the Zig-native unit-test
layer and still be a real integration-test gap, because the risk being tested for is
*binding marshaling* (C-ABI/JNI), not DCPS logic correctness.

Companion doc: `docs/design/testing-strategy.md` (the tier model this audit feeds into).

## Method

Four parallel surveys:
- `dds-rtps/srcZig/shape_main.zig` — the only zzdds-authored dds-rtps entry (srcC/srcCxx/srcRs
  are other vendors' own native implementations). Cross-checked against
  `test_suite_functions.py`'s `pexpect`-based content matching.
- `examples/{zig,c}/{hello_world,shape,waitset}` — internal (in-app) assertions.
- `examples/{cpp,java}/{hello_world,shape,waitset}` — same.
- `examples/interop/*.py` — what the cross-binding orchestration scripts assert,
  independent of what the binaries do internally.

For each API found, classified as:
- **Asserted** — return/result checked, and something meaningful happens on
  failure/mismatch (fail loudly, compare content, branch control flow).
- **Called-only** — executes in a real cross-process run (so a hard crash would be
  caught) but nothing checks the outcome was *correct*.
- **Uncalled** — zero exercise in any of the four harnesses.

## What's genuinely well-covered

| API | Where | Note |
|---|---|---|
| Entity constructors (`create_participant`/`create_topic`/`create_publisher`/`create_subscriber`/`create_datawriter`/`create_datareader`) | everywhere | nil/return-code checked, every binding, every harness |
| `write` (typed) | everywhere | return-checked everywhere |
| `take`/`take_next_sample` in `hello_world` | zig/c/cpp/java + dds-rtps | content-asserted end-to-end (expected sequence, hard-fail on gap/reorder). Does **not** carry over to `shape` — none of the 4 bindings' `shape` examples assert take/read content themselves |
| `WaitSet.wait()` | zig/c/cpp/java `waitset` | return-code branched AND active-set inspected — best-covered non-trivial API in the suite |
| CFT filtering (behavioral) | `interop/shape_cross_binding_smoke_test.py` | the one genuine negative-case test: confirms non-matching shapesizes absent AND matching present, bidirectionally. Log-content-based, not wire-level, but real |
| `on_publication_matched` (writer-side match) | most examples | drives shutdown-gating control flow, so effectively asserted |

## Zero coverage anywhere — no binding, no harness

| Category | APIs |
|---|---|
| Liveliness (narrowed 2026-09-22 — see below) | ~~`on_liveliness_lost`, `get_liveliness_lost_status`, AUTOMATIC/MANUAL_BY_PARTICIPANT kinds~~ — **Done**, Integration-tier `liveliness-lost` scenario (see "First-pass classification" below). `assert_liveliness()`, `on_liveliness_changed`, and MANUAL_BY_TOPIC are covered by the `presence` example (all 4 bindings) — see "Examples" bucket below. Still open, small: `get_liveliness_changed_status` called as an explicit getter (both `presence` and `liveliness-lost` only ever observe it via the listener callback's own status parameter, never call the getter directly) |
| Rejection/loss | ~~`on_sample_rejected`/`on_sample_lost`, `get_sample_rejected_status`/`get_sample_lost_status`~~ — **Done**, Integration-tier `sample-rejected-lost` scenario (see "First-pass classification" below) |
| Historical data | `wait_for_historical_data` — confirmed zero across every harness |
| Timestamped/explicit instance ops | ~~`register_instance` (explicit), `write_w_timestamp`, `dispose_w_timestamp`~~ — **Done**, Integration-tier `source-timestamp` scenario (see "First-pass classification" below). Still uncovered: `register_instance_w_timestamp` (its timestamp is a documented no-op in zidl, covered by zidl's own backend unit tests instead), `unregister_instance_w_timestamp` (shares the same underlying wire-timestamp plumbing `write_w_timestamp`/`dispose_w_timestamp` already exercise, so a dedicated scenario is low-value) |
| Instance introspection | `lookup_instance`; `get_key_value` now exercised by the stress `instance` scenario, which found it returns the wrong key for non-leading-key types (zidl codegen, all backends — see below) |
| Loans | `return_loan_raw`, any loaned-read (`take_raw`/`read_raw` in loan mode) or write-loan (`loan_raw`/`publish_loan_raw`) path — no `examples/` port exercises these yet (internal test-suite coverage exists, see the loan-lifecycle entry below) |
| Entity admin, post-creation | `set_qos`/`get_qos` round-trip, `get_listener` read-back, `get_status_changes()`, `contains_entity()`. ~~`enable()`/`autoenable_created_entities`~~ — **Done** (2026-09-21; was a uniform no-op stub across every entity type, see `docs/roadmap.md`'s Integration-tier entry) — both core semantics and the `enable-defer` cross-binding scenario now landed |
| Discovery/ignore | `ignore_participant`/`ignore_topic`/`ignore_publication`/`ignore_subscription`, `get_discovered_participants`/`get_discovered_topics` + `_data` variants |
| Misc participant ops | `find_topic`, `MultiTopic` (unimplemented in zzdds core — expected), `suspend_publications`/`resume_publications`, `notify_datareaders`, `get_current_time`, `get_domain_id`, `copy_from_topic_qos` |
| Lookup/matched introspection | `lookup_datawriter`/`lookup_datareader`, `get_matched_subscriptions`/`get_matched_publications` + `_data` variants |
| Bulk teardown | ~~`delete_contained_entities`~~ — **Done**, Integration-tier `delete-contained-entities` scenario (see "First-pass classification" below) |
| WaitSet/Condition introspection | `WaitSet.get_conditions()`, every getter on every Condition type (`get_query_expression`/`get_query_parameters`/`set_query_parameters`, `get_sample_state_mask`/`get_view_state_mask`/`get_instance_state_mask`/`get_datareader`, `get_enabled_statuses`/`get_entity`, generic `get_trigger_value`) |
| Conditional/batch reads | `read_w_condition`/`read_next_instance_w_condition`/`take_next_instance_w_condition` (only plain `take_w_condition` gets any exercise, in `waitset` only), batch `read_instance`/`take_instance` |

## Called but not verified

| API | Where | Gap |
|---|---|---|
| `begin_coherent_changes`/`end_coherent_changes`, `begin_access`/`end_access` | `shape`, all bindings | return always discarded; coherent/ordered grouping behavior never asserted by any app. Notable given past CoherentSets flakiness investigations elsewhere in this project's history |
| `wait_for_acknowledgments` | dds-rtps, `shape` | return always ignored |
| `dispose`/`unregister_instance` | `shape`, all 4 bindings | called-only; errors explicitly swallowed in some ports |
| `create_contentfilteredtopic` | `shape` | C++/Java don't null-check the result at all; zig/c check but don't hard-fail. Filtering correctness only verified externally |
| `take_w_condition` | `waitset` | C++ and Java's own code comments **self-acknowledge** they don't trust which take-call a sample came from (a known race) — filter-bucket correctness exercised but not really verified even here |

## Per-binding asymmetries (small, mechanical, worth fixing regardless of the bigger picture)

**All three resolved as of 2026-08-20** — re-checked against current code (not just this
audit's original 2026-08-14 snapshot) while working the "Examples" bucket below:
`lookup_topicdescription` and the `get_default_*_qos()`-before-mutating pattern are now
consistent across all four `shape` ports (landed sometime in the presence/registry/catchup/
waitset work since this audit was written). The one real remaining gap —
`zig/waitset`'s publisher/subscriber ignoring `registerTypeSupport`'s return code, unlike
every other example in the repo — is fixed (see `CHANGELOG.md`, 2026-08-20).

---

## First-pass classification: which bucket for each gap

Per `docs/design/testing-strategy.md`'s tier model, extended with three new categories:
**Examples** (demonstration-first, light assertions, all 4 bindings), **Integration
tests** (new, in-repo, real cross-process, targets a specific outcome — prioritized
toward APIs already Zig-unit-tested but binding-unexercised, since that's where this
project's real bugs have historically clustered), **Stress tests** (new, in-repo,
concurrency/lifecycle-under-load, `OpenDDS EntityLifecycleStress`-shaped).

### → Examples (fix/extend existing, or add small new ones)
- ~~Fix the 3 per-binding asymmetries above (mechanical, all 4 bindings).~~ Done — see above.
- ~~Add content assertions to `shape`'s take/read loops (upgrades called-only → asserted,
  one code path × 4 bindings).~~ Done — all four `shape` ports hard-fail on a color change
  within one instance or an out-of-bounds x/y/shapesize, re-confirmed 2026-08-20.
- ~~`WaitSet.get_conditions()` — trivial one-line addition to `waitset`.~~ Done — all four
  `waitset` subscribers call it and assert exactly 4 conditions, re-confirmed 2026-08-20.
- ~~New small example: **liveliness**~~ — **Done**, as the `presence` example
  (`examples/{zig,c,cpp,java}/presence`, `examples/docs/design/presence-reference-app.md`):
  MANUAL_BY_TOPIC + `assert_liveliness()` + `on_liveliness_changed`, cross-process across
  all 4 bindings and all 8 same/cross-binding pairs
  (`interop/presence_cross_binding_smoke_test.py`). Found and fixed 4 real bugs, including
  a wire-level one (`PID_LIVELINESS` was never encoded on the wire at all). Deliberately
  left out to keep it one scenario: `on_liveliness_lost`/`get_liveliness_lost_status` and
  the AUTOMATIC/MANUAL_BY_PARTICIPANT kinds — since closed by the Integration-tier
  `liveliness-lost` scenario instead of a second example (see below).
- New small example: **loaned read/write** (`take_raw`/`read_raw` in loan mode —
  `cdr_payloads._maximum == 0` on entry — plus `return_loan_raw`; and the write side,
  `loan_raw`/`publish_loan_raw`/`return_loan_raw`) — distinct usage pattern. The old
  hand-written `take_loaned`/`return_loan` family (and its non-standard retcode
  convention, `1`=success rather than the usual `RETCODE_OK`=0) is long gone —
  `bootstrap.zig` deleted 2026-08-22, replaced by real `dcps.idl` ops, generated
  uniformly across **all four bindings** (C, C++, Java, Zig — not C/C++-only), standard
  retcode convention throughout. Re-verified 2026-09-17: still true, nothing has
  regressed it since. No example port in *any* binding demonstrates the new loan-mode ops
  yet; `examples/spikes/rust` and this project's own
  `writer_vtable_test.zig`/`reader_vtable_test.zig`/`JavaSmoke.java` do (see the
  "Integration tests" loan-lifecycle entry below), but none of those is an `examples/`
  port in the sense this table means, and C/C++ have zero exercise even at that level.
  Given the API's stability across all 4 bindings for a month now, this is a strong
  candidate to build `presence`-style: cross-binding from the start, not per-language.
- Extend `shape` or `hello_world` publisher to use explicit `register_instance` +
  `get_key_value`/`lookup_instance` once, instead of implicit registration only.
- Extend an example with `get_discovered_participants`/`get_discovered_topics` — genuinely
  demo-able ("list what's on the network"), not just a correctness check.

### → Integration tests (new, in-repo)
- ~~**Liveliness through each binding's listener/status marshaling**~~ — closed by the
  `presence` example (see "Examples" bucket above) for MANUAL_BY_TOPIC/`assert_liveliness()`/
  `on_liveliness_changed`, and by the Integration-tier `liveliness-lost` scenario for the
  remaining narrower slice — `on_liveliness_lost`/`get_liveliness_lost_status` and the
  AUTOMATIC/MANUAL_BY_PARTICIPANT kinds — see "First-pass classification" below.
- ~~**SAMPLE_REJECTED/SAMPLE_LOST through each binding**~~ — **Done**, as the
  `sample-rejected-lost` Integration-tier scenario (`integration-tests/{c,cpp,java,zig}/sample-rejected-lost`):
  a tight-`resource_limits` reader deliberately overflowed by 5 back-to-back writes
  (RejectedTopic), and a KEEP_LAST(1)/TRANSIENT_LOCAL writer that writes+evicts 5 samples
  before any reader is matched at all, so a deliberately-late-joining reader hits a genuine
  HEARTBEAT-implied gap (LostTopic). See `docs/roadmap.md`'s Integration-tier entry for the
  full mechanism and the one design iteration it took to get LostTopic's trigger
  deterministic rather than a race.
- ~~**`enable()` / `autoenable_created_entities=false`**~~ — **Done**, as the `enable-defer`
  Integration-tier scenario (`integration-tests/{c,cpp,java,zig}/enable-defer`). This
  turned out not to be a test-coverage gap at all: `enable()` was a uniform no-op stub
  across every entity type, so the feature itself had to be implemented first (see
  `docs/roadmap.md`'s Integration-tier entry for the full mechanism, the real bugs found in
  the process, and the two over-broad `NOT_ENABLED` guards it also found and corrected).
- ~~**`wait_for_historical_data`**~~ — **Done**, as the `wait-for-historical-data`
  Integration-tier scenario (`integration-tests/{c,cpp,java,zig}/wait-for-historical-data`).
  Modeled on `examples/*/catchup`'s late-joining-reader mechanism but held to a harder bar:
  a deterministic negative case (a short, non-zero `max_wait` called while no writer exists
  anywhere on the domain yet must return `RETCODE_TIMEOUT`, not `RETCODE_OK` — closing the
  negative case `docs/roadmap.md` recorded as deliberately out of scope for `catchup`
  itself) followed by a positive case (a generous `max_wait` must return `RETCODE_OK` only
  once every historical sample has actually been delivered). See `integration-tests/README.md`
  for the full scenario writeup.
- ~~**`ignore_participant`/`ignore_topic`/`ignore_publication`/`ignore_subscription`**~~ —
  **Done**, as the `ignore-entities` Integration-tier scenario
  (`integration-tests/{c,cpp,java,zig}/ignore-entities`) — the only scenario in this tier
  needing three processes (ignorer/peer/bystander), since `ignore_participant()` would
  blackhole a whole participant `peer` needs to keep serving the other three ops. Found and
  fixed a real bug: the retroactive-match scan run when a new local reader/writer is
  created never checked the ignore lists, so an already-discovered-then-ignored remote
  entity stayed retroactively matchable to an entity created after the ignore call. See
  `integration-tests/README.md` for the full scenario writeup and `docs/roadmap.md` for the
  bug.
- ~~**`set_expression_parameters` at runtime** (CFT dynamic reconfiguration)~~ — **Done**,
  as the `cft-reconfigure` Integration-tier scenario
  (`integration-tests/{c,cpp,java,zig}/cft-reconfigure`) — behavioral correctness (does
  changing parameters without recreating the CFT actually re-filter subsequent samples),
  distinct from the stress-tier `cft` scenario's concurrency-safety coverage (a UAF
  between reconfigure and receive-thread filter eval, already found and fixed there).
  Also closes the CFT introspection gap this same audit flags below
  (`get_filter_expression`/`get_expression_parameters`/`get_related_topic`). Found a real
  Zig-native-binding gotcha along the way: the raw `zzdds.registerTypeSupport()` call
  doesn't wire up `TypeSupport.get_field` automatically the way the generated
  `TypeSupport.register()` wrapper C/C++/Java go through does, silently leaving a CFT
  reader unfiltered with no error. See `integration-tests/README.md` for the full scenario
  writeup and `docs/roadmap.md` for the bug.
- ~~**Coherent/ordered access grouping correctness**~~ — **Done**, as the `coherent-sets`
  Integration-tier scenario (`integration-tests/{c,cpp,java,zig}/coherent-sets`,
  `docs/design/integration-test-tier.md`): a real coherent set across two DataWriters
  (Position/Velocity) under one GROUP-scope Publisher, cross-process, all 4 bindings, 8
  same/cross-binding pairs. Asserts atomic delivery directly (the two readers' taken-
  `group_id` sequences must stay exactly equal-length and pairwise equal after every
  `begin_access()`/`end_access()` bracket) — not a count-per-time-window guess, unlike the
  now-understood `dds-rtps` CoherentSets flake this was motivated by. Building it found and
  fixed a real `hasPendingDataFn` bug (see `docs/roadmap.md`'s Integration-tier entry for the
  full mechanism) that permanently starved a `WaitSet`-driven coherent-access loop after its
  first iteration.
- ~~**`_w_timestamp` family**~~ — **Done**, as the `source-timestamp` Integration-tier
  scenario (`integration-tests/{c,cpp,java,zig}/source-timestamp`) — verifies the explicit
  source timestamp actually propagates to `SampleInfo.source_timestamp` on the receiving
  side, not just "now". Found and fixed a real zzdds core bug on the very first real
  cross-process run: `src/util/time.zig`'s RTPS wire fraction↔nanosecond conversion used
  truncating division, systematically losing ~1ns for nearly any nonzero explicit
  nanosecond value. See `integration-tests/README.md` for the full scenario writeup and
  `docs/roadmap.md` for the bug.
- **Loan lifecycle edges — real coverage now exists, but mostly outside this audit's own
  defined scope** (see this doc's intro: cross-process/cross-binding only, not zzdds's
  Zig-native unit suite). As of the 2026-08-22 raw/loan API redesign:
  `writer_vtable_test.zig`/`reader_vtable_test.zig` cover real vtable-dispatch round trips
  + `PRECONDITION_NOT_MET` teardown-blocking (deliberately re-broken and restored) but are
  Zig-native, out of this audit's scope by its own definition. `JavaSmoke.java`
  (dispose-via-loan + `delete_datawriter` succeeding afterward) **is** in scope — real JNI
  marshaling, a genuine gap closed. `examples/spikes/rust` covers a real,
  compiler-enforced double-return rejection (`LoanedSample`'s `Drop` impl makes an explicit
  second `return_loan_raw` call unreachable in safe Rust, verified by
  `examples/escape_attempt.rs`'s expected `E0597`), but it's a throwaway spike, not one of
  the audited 12 example ports, so still a gap by this doc's own counting. Still zero
  coverage in C/C++: nothing stops a C/C++ caller from reading a loaned buffer after
  returning it (same as any other raw-pointer contract in those bindings). The old
  retcode-convention quirk this entry originally flagged no longer exists — the old
  hand-written `take_loaned_raw` family it applied to was deleted, replaced by the
  standard-convention `take_raw`/`read_raw`.
- ~~**`delete_contained_entities`**~~ — **Done**, as the `delete-contained-entities`
  Integration-tier scenario (`integration-tests/{c,cpp,java,zig}/delete-contained-entities`,
  `docs/design/integration-test-tier.md`): a "session" builds a small entity tree (2
  DataWriters, a plain DataReader, a ContentFilteredTopic-backed DataReader, a
  WaitSet-attached ReadCondition) under one participant, exchanges samples with a "peer",
  then tears the whole tree down in one shot instead of deleting each child first.
  Confirms this project's own prior finding that this class of bug clusters in
  teardown-cascade edge cases: `DomainParticipantImpl.vtDeleteContained`
  (`src/dcps/participant.zig`) drained publishers/subscribers/topics but never
  `cft_topics`, so `delete_contained_entities()` returned RETCODE_OK while leaving a
  ContentFilteredTopic behind — the immediately-following `delete_participant()` then
  always failed with PRECONDITION_NOT_MET for any app that had created one. Fixed; the
  scenario also asserts no matched-status listener ever fires after teardown begins (a
  UAF-class check).

### → Stress tests (new, in-repo)
Landed in `stress-tests/` (`lifecycle_churn` scenarios + `entity_lifecycle_stress`):
- ~~**Generalized reentrant-listener/entity-lifecycle churn**~~ — `--scenario reentrant`.
- ~~**WaitSet/Condition churn under load**~~ — `--scenario waitset` (threads
  attach/detach ReadConditions/QueryConditions on a shared WaitSet while a waiter is in
  `wait()` and a waker flips a GuardCondition; includes delete-while-attached).
- ~~**Listener-fallback chain under load**~~ — `--scenario listener` (participant +
  publisher + subscriber listeners; per-iteration `set_listener` swaps incl. `null`
  racing entity teardown and event delivery). Found the unsynchronised `listener_mask`
  race, now fixed + TSan-gated.
- ~~**Rapid DataWriter/DataReader create/delete during active SEDP matching**~~ —
  `--scenario entities`. Found the discovery-driven listener-dispatch UAF, now fixed.
- **Runtime `set_expression_parameters` reconfiguration** — `--scenario cft`. Found a
  UAF between the reconfigure and receive-thread filter eval, now fixed + TSan-gated.
- ~~**Many-writer/many-reader fan-in/fan-out discovery**~~ + ~~**participant-churning
  fallback**~~ — `--scenario participants` (N threads each churning a whole participant on
  one shared domain, listeners at every level, W/R mix for fan-in/fan-out). Clean.
- ~~**`instance` churn**~~ — `--scenario instance`. Clean for the instance-map /
  reader-tracking / register-dispose-unregister paths, but surfaced two pre-existing bugs
  it deliberately doesn't gate on: `get_key_value` parses the stored *full* sample with the
  *key-only* deserializer in all four zidl backends (wrong key for any type whose key
  member isn't first — see `stress-tests/README.md`), and concurrent `write()` on one
  `DataWriter` is unsynchronised (`writeRaw` takes no lock). Each needs its own PR.

Still open:
- A scenario that churns the reader-side WaitSet/condition graph *and* the participant at
  once (the closest current pair is `waitset` + `participants` run separately).

### Not prioritized / low value
- Condition introspection getters (`get_query_expression`, `get_sample_state_mask`, etc.)
  — already covered at the Zig-native unit layer per `docs/testing.md` Tier 2
  ("WaitSet + ReadCondition + StatusCondition + GuardCondition + QueryCondition
  lifecycle/state-mask triggering"). Getter-only APIs don't make a compelling example
  narrative either. Worth a one-line incidental call in an existing example if convenient,
  not a dedicated effort.
- `MultiTopic` — unimplemented in zzdds core; not testable until that lands.
