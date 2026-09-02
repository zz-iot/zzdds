# DCPS API Coverage Audit (2026-08-14)

Cross-process/cross-binding DCPS API coverage, audited across every harness that runs
zzdds as a real separate process against another DDS application: the dds-rtps vendor
matrix, zzdds-examples' 12 per-binding example ports, and zzdds-examples' `interop/`
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
- `zzdds-examples/{zig,c}/{hello_world,shape,waitset}` — internal (in-app) assertions.
- `zzdds-examples/{cpp,java}/{hello_world,shape,waitset}` — same.
- `zzdds-examples/interop/*.py` — what the cross-binding orchestration scripts assert,
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
| Liveliness | LIVELINESS QoS variation, `assert_liveliness`, `on_liveliness_lost`/`on_liveliness_changed`, `get_liveliness_lost_status`/`get_liveliness_changed_status` |
| Rejection/loss | `on_sample_rejected`/`on_sample_lost`, `get_sample_rejected_status`/`get_sample_lost_status` — neither listener nor polling form, anywhere |
| Historical data | `wait_for_historical_data` — confirmed zero across every harness |
| Timestamped/explicit instance ops | `register_instance` (explicit), `register_instance_w_timestamp`, `write_w_timestamp`, `dispose_w_timestamp`, `unregister_instance_w_timestamp` |
| Instance introspection | `lookup_instance`; `get_key_value` now exercised by the stress `instance` scenario, which found it returns the wrong key for non-leading-key types (zidl codegen, all backends — see below) |
| Loans | `return_loan_raw`, any loaned-read (`take_raw`/`read_raw` in loan mode) or write-loan (`loan_raw`/`publish_loan_raw`) path — no `zzdds-examples` port exercises these yet (internal test-suite coverage exists, see the loan-lifecycle entry below) |
| Entity admin, post-creation | `set_qos`/`get_qos` round-trip, `get_listener` read-back, `enable()`, `get_status_changes()`, `contains_entity()` |
| Discovery/ignore | `ignore_participant`/`ignore_topic`/`ignore_publication`/`ignore_subscription`, `get_discovered_participants`/`get_discovered_topics` + `_data` variants |
| Misc participant ops | `find_topic`, `MultiTopic` (unimplemented in zzdds core — expected), `suspend_publications`/`resume_publications`, `notify_datareaders`, `get_current_time`, `get_domain_id`, `copy_from_topic_qos` |
| Lookup/matched introspection | `lookup_datawriter`/`lookup_datareader`, `get_matched_subscriptions`/`get_matched_publications` + `_data` variants |
| Bulk teardown | `delete_contained_entities` (every example tears down via `delete_participant`'s cascade instead) |
| WaitSet/Condition introspection | `WaitSet.get_conditions()`, every getter on every Condition type (`get_query_expression`/`get_query_parameters`/`set_query_parameters`, `get_sample_state_mask`/`get_view_state_mask`/`get_instance_state_mask`/`get_datareader`, `get_enabled_statuses`/`get_entity`, generic `get_trigger_value`) |
| CFT introspection | `get_filter_expression`/`get_expression_parameters`/`set_expression_parameters`/`get_related_topic` — CFT is set once at creation, never read back or changed |
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
- New small example: **liveliness** (MANUAL_BY_TOPIC/PARTICIPANT + `assert_liveliness()`
  + `on_liveliness_lost`/`changed`) — a genuine common real-world DDS pattern
  (watchdog-style liveliness), worth showing across all 4 bindings.
- New small example: **loaned read** (`take_raw`/`read_raw` in loan mode —
  `cdr_payloads._maximum == 0` on entry — plus `return_loan_raw`) — distinct usage
  pattern. Stale as of the 2026-08-22 raw/loan API redesign: the old hand-written
  `take_loaned`/`return_loan` family (and its non-standard retcode convention, `1`=success
  rather than the usual `RETCODE_OK`=0) is gone — `bootstrap.zig` deleted, replaced by real
  `dcps.idl` ops using the standard convention throughout. No zzdds-examples port
  demonstrates the new loan-mode ops yet; `zzdds-examples/spikes/rust` and this project's
  own `writer_vtable_test.zig`/`reader_vtable_test.zig`/`JavaSmoke.java` do (see the
  "Integration tests" loan-lifecycle entry below), but none of those are a `zzdds-examples`
  port in the sense this table means.
- Extend `shape` or `hello_world` publisher to use explicit `register_instance` +
  `get_key_value`/`lookup_instance` once, instead of implicit registration only.
- Extend an example with `get_discovered_participants`/`get_discovered_topics` — genuinely
  demo-able ("list what's on the network"), not just a correctness check.

### → Integration tests (new, in-repo)
- **Liveliness through each binding's listener/status marshaling** — Zig-native already
  unit-tests this; the gap is binding correctness.
- **SAMPLE_REJECTED/SAMPLE_LOST through each binding** — same reasoning.
- **`enable()` / `autoenable_created_entities=false`** — create disabled, verify no
  discovery/matching occurs, call `enable()`, verify matching now proceeds. Currently
  untested anywhere (worth checking whether even the Zig-native unit suite covers this).
- **`wait_for_historical_data`** — late-joining reader + DURABILITY, verify it unblocks
  only once durable replay actually lands, not on a timer.
- **`ignore_participant`/`ignore_topic`/`ignore_publication`/`ignore_subscription`** —
  needs 2 real processes to mean anything.
- **`set_expression_parameters` at runtime** (CFT dynamic reconfiguration) — does
  changing parameters without recreating the CFT actually re-filter subsequent samples?
  Real spec-mandated behavior; the *behavioural* question is still untested (the
  stress-tier `cft` scenario now covers its *concurrency safety* and fixed a UAF there).
  CFT has an established bug history in this project (missing null-checks found in this
  same audit).
- **Coherent/ordered access grouping correctness** — build a real coherent set across
  multiple writers, verify atomic delivery. High value given past CoherentSets
  flakiness investigations.
- **`_w_timestamp` family** — verify the explicit source timestamp actually propagates
  to `SampleInfo.source_timestamp` on the receiving side, not just "now".
- **Loan lifecycle edges — real coverage now exists, but mostly outside this audit's own
  defined scope** (see this doc's intro: cross-process/cross-binding only, not zzdds's
  Zig-native unit suite). As of the 2026-08-22 raw/loan API redesign:
  `writer_vtable_test.zig`/`reader_vtable_test.zig` cover real vtable-dispatch round trips
  + `PRECONDITION_NOT_MET` teardown-blocking (deliberately re-broken and restored) but are
  Zig-native, out of this audit's scope by its own definition. `JavaSmoke.java`
  (dispose-via-loan + `delete_datawriter` succeeding afterward) **is** in scope — real JNI
  marshaling, a genuine gap closed. `zzdds-examples/spikes/rust` covers a real,
  compiler-enforced double-return rejection (`LoanedSample`'s `Drop` impl makes an explicit
  second `return_loan_raw` call unreachable in safe Rust, verified by
  `examples/escape_attempt.rs`'s expected `E0597`), but it's a throwaway spike, not one of
  the audited 12 example ports, so still a gap by this doc's own counting. Still zero
  coverage in C/C++: nothing stops a C/C++ caller from reading a loaned buffer after
  returning it (same as any other raw-pointer contract in those bindings). The old
  retcode-convention quirk this entry originally flagged no longer exists — the old
  hand-written `take_loaned_raw` family it applied to was deleted, replaced by the
  standard-convention `take_raw`/`read_raw`.
- **`delete_contained_entities`** — bulk-teardown correctness across the C-ABI; this
  project has repeatedly found real bugs specifically in teardown-cascade edge cases.

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
