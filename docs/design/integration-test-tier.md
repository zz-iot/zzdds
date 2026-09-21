# Integration test tier — spec

Status: draft, rev 0.1 — proposing structure before implementation, per this project's
convention of a design doc ahead of any new example/tier ([[presence-reference-app.md]],
[[raw-loan-reference-app.md]], [[discovery-association-race-testing.md]]).

## Motivation

The 2026-08-14 testing-tier-expansion decision added three categories on top of the
existing Tier 1–4 model (`testing-strategy.md`): **Examples**, **Integration tests**, and
**Stress tests**. Two of three have landed:

- **Examples** — `presence` (liveliness) and the raw-loan example, both cross-process,
  all 4 bindings, real assertions.
- **Stress tests** — `stress-tests/`, seven `lifecycle_churn` scenarios +
  `entity_lifecycle_stress`, Zig-native, concurrency/lifecycle-under-load.
- **Integration tests** — not started. `docs/design/dcps-api-coverage-audit.md` has a
  prioritized backlog of *what* to cover, but no decisions on *how* — harness shape,
  directory layout, cross-binding strategy, or CI wiring. This doc is that missing half.

## What "Integration" means here, vs. Examples and Stress

The audit's own definition: "new, in-repo, real cross-process, targets a specific
outcome — prioritized toward APIs already Zig-unit-tested but binding-unexercised, since
that's where this project's real bugs have historically clustered."

Sharpened with this round's discussion:

| | Examples | **Integration (this doc)** | Stress |
|---|---|---|---|
| Purpose | demonstrate API usage; teach a binding | verify a specific DCPS behavior actually holds, end to end | find concurrency/lifecycle bugs under load |
| Assertion style | light, demonstration-first (though `presence`/raw-loan already blur this) | hard pass/fail on one targeted, spec-mandated outcome | crash/hang/UAF/leak detection, xfail-tracked |
| Realism | can be contrived (shapes, hello world) | a plausible use case, exercising the target API the way an app actually would | synthetic churn (N threads hammering create/delete) |
| Binding scope | one app per binding + a cross-binding smoke test | **every scenario built once per binding, run cross-binding — the mapping/binding correctness is the point**, not incidental | usually Zig-native only (`stress-tests/zig/`) — these are core-layer bugs, not binding-layer |
| Where it lives | `examples/{c,cpp,java,zig}/<name>` + `examples/interop/*_cross_binding_smoke_test.py` | new `integration-tests/` (below) | `stress-tests/zig/<scenario>` |

The key distinction from Examples: these are not written to be read as sample code. A
scenario can use awkward setup, timing coordination via a status callback, or a
teardown order chosen to stress the exact edge case, if that's what proving the outcome
needs — the audience is CI, not a tutorial reader.

The key distinction from Stress: no thread pools, no churn loops, no xfail list. One
writer, one reader (or a small, fixed handful), doing one plausible thing, with a load-bearing
assertion on the specific DCPS behavior in question — the load-bearing test in every one
of these is a *correctness* check, not a survival check.

## Directory layout

**Proposal: a new top-level `integration-tests/`, not a subfolder of `examples/`.**

Rationale: `stress-tests/` was deliberately split out of `examples/` for exactly this
reason — mixing "things meant to read well as sample code" with "things meant to catch
bugs" degrades both (`stress-tests/README.md`'s opening line: "Deliberately not part of
`zig build test`... the opposite of the deterministic gate"). The same argument applies
here, arguably more directly, since these scenarios are explicitly not meant to double as
documentation. Symmetry with `stress-tests/` also means no new conventions to invent —
reuse the layout and the harness-reuse trick wholesale:

```
integration-tests/
  README.md
  run_all.py                    orchestrator (--strict for CI), mirrors examples/ and stress-tests/
  c/<scenario>/
  cpp/<scenario>/
  java/<scenario>/
  zig/<scenario>/
  interop/<scenario>_cross_binding_test.py    per-scenario cross-binding runner + assertions
```

`run_all.py` (and every `interop/*_test.py`) reuses `examples/_common.py` exactly the way
`stress-tests/run_all.py` already does — `sys.path.insert(0, ".../examples")`, `import
_common` — rather than forking or re-vendoring it. No new shared-helper file needed unless
something integration-specific comes up that doesn't belong in `_common.py` (e.g. a
coherent-set completion barrier, or a bounded-poll-for-N-samples helper) — those get added
as small `integration-tests/_common_ext.py` additions if and when a second scenario needs
the same one, not speculatively.

**Per-scenario apps, not one big app.** Each scenario gets its own small
publisher/subscriber pair per language (own `idl/`, own `CMakeLists.txt`/`build.zig`),
exactly like `examples/*/raw-loan` or `presence` — small enough to read in one sitting,
one clear thing under test. Reuse a scenario's IDL type across bindings for that scenario
(same shape as `raw-loan`'s `loaned_ping.idl` copied into each language dir); don't try to
build one shared mega-type across all scenarios up front.

## Cross-binding matrix strategy

Full N×N (12 ordered pairs across 4 bindings) per scenario is what `shape` does, but that's
the one app in the whole repo meant as the from-scratch interop baseline; running it per
*every* integration scenario would make the job's CI cost scale with scenario count times
12. `presence` already set a cheaper precedent that fits the "catch binding-mapping
oddities" goal without full combinatorics: **4 same-binding pairs (prove the assertion
holds at all, per binding) + a curated 4 cross-binding pairs**, 8 of the 12 possible
ordered pairs total. Propose reusing that 8-pair convention as the default for every
scenario here, with per-scenario override if a specific pairing turns out to matter (e.g.
a scenario specifically about a type-mapping asymmetry between two bindings might want a
pair added that the default rotation wouldn't hit).

## Assertion & timing conventions

Carried over from `testing-strategy.md`'s guiding principles and enforced already in
`presence`/raw-loan: no fixed-delay sleeps waiting for discovery or delivery. Every
scenario blocks on a real signal — a status callback firing, a log-line marker the
publisher process emits once it's actually done (`_common.LiveProcess`'s existing
marker-wait support), or a bounded poll — the same pattern `shape_cross_binding_smoke_test.py`
already uses for its CFT check ("waits for the publisher's own logged match confirmation,
not a fixed delay"). A scenario with no way to observe its target condition without
polling should poll with a short interval and a generous overall timeout, not sleep once
and hope.

Each scenario's cross-binding test should fail loudly and specifically — which pair, which
assertion, log excerpts from both sides — following `_common.print_fail`'s existing
convention, not a bare non-zero exit.

## CI wiring

New `integration` job in `zzdds/.github/workflows/ci.yml`, modeled directly on the
`examples` job (needs cross-binding, so needs all bindings built — unlike `stress`, which
only needs a native Zig build):

```
integration:
  needs: test-linux
  # build zzdds with -Dc-binding -Dcpp-binding -Djava-binding, like `examples`
  # run: integration-tests/run_all.py --strict
```

Gate on every PR from the start, same as `examples` and `stress` — don't stand this up as
nightly-only. The cost concern is scenario *count* over time, not whether cross-process
DDS tests belong in the PR gate at all (they clearly already do, twice over). Start with
one scenario so the job's initial cost is small, and let it grow the way `stress-tests/`
did (one scenario at a time, each its own PR).

## Scenario backlog (from `dcps-api-coverage-audit.md`, reordered)

Proposed build order — highest-value first:

1. **Coherent/ordered access grouping correctness** — multiple writers publish a
   correlated group under `begin_coherent_changes`/`end_coherent_changes`; the reader
   (PRESENTATION `COHERENT_ACCESS=true`, `GROUP` scope) must see the whole group appear
   atomically, never a partial group. Explicitly flagged high-value in the audit "given
   past CoherentSets flakiness investigations" — this project has real history here
   ([[project-coherent-sets-flake-track1]]), even though that flake was traced to the
   *external* dds-rtps harness, not zzdds. A first-party coherent-sets integration test
   closes the gap that let that ambiguity exist for as long as it did.
2. **`delete_contained_entities` bulk teardown, across the C-ABI** — build a small entity
   tree (participant → publisher/subscriber → writers/readers → conditions), call
   `delete_contained_entities`, verify everything is actually gone (no dangling C-ABI
   handles, no leaked listeners) and that a subsequent `delete_participant` succeeds. Audit
   notes: "this project has repeatedly found real bugs specifically in teardown-cascade
   edge cases."
3. **`enable()` / `autoenable_created_entities=false`** — create disabled, assert no
   discovery/matching occurs while disabled, `enable()`, assert matching now proceeds.
   Currently untested anywhere, including the Zig-native unit suite (worth double-checking
   that claim once this scenario is being built).
4. **SAMPLE_REJECTED / SAMPLE_LOST** — force a resource-limit or KEEP_LAST-eviction
   condition that should fire the status/listener, per binding.
5. **`wait_for_historical_data`** — late-joining TRANSIENT_LOCAL reader; assert the call
   unblocks only once durable replay has actually landed, not on its own timeout.
6. **`ignore_participant`/`ignore_topic`/`ignore_publication`/`ignore_subscription`** —
   needs two real processes to mean anything; assert the ignored side stops being
   discovered/matched.
7. **`set_expression_parameters` runtime CFT reconfiguration** — behavioral correctness
   (does changing parameters without recreating the CFT actually re-filter subsequent
   samples), distinct from the stress `cft` scenario's concurrency-safety coverage.
8. **`_w_timestamp` family** — verify the explicit source timestamp actually propagates to
   `SampleInfo.source_timestamp` on the receiving side.
9. **`on_liveliness_lost` / AUTOMATIC / MANUAL_BY_PARTICIPANT** — the narrow slice
   deliberately left out of `presence` to keep it a single-scenario example. Candidate to
   fold in here instead of a second example, since it's a terminal/negative case.

Not a commitment to build all nine before shipping anything — land #1, get the harness
conventions right, then proceed down the list, re-ranking as needed once one is actually
built.

## Non-goals

- **Not a stress/concurrency tool.** No thread pools, no load generation, no xfail
  tracking of known races — that's `stress-tests/`.
- **Not a demonstration app.** Not held to "reads well as a tutorial" the way `examples/`
  is; awkward-but-correct setup is fine if it's what proving the target behavior needs.
- **Not spec conformance.** Same non-goal `testing-strategy.md` already states for the
  project as a whole — each scenario targets a specific outcome that matters in practice,
  not a section-by-section OMG spec walk.
- **Not a replacement for Tier 1/2 reference-model tests.** Those stay the place for
  fast, deterministic, mock-transport coverage of RTPS/DCPS internals. Integration tests
  are for behaviors that only manifest end-to-end, across real processes and real
  bindings.

## Open for pushback

1. New top-level `integration-tests/` vs. folding into `examples/interop/` — the doc
   recommends the former; flag here in case the symmetry argument with `stress-tests/`
   doesn't land the way it's intended to.
2. Default 8-pair (4 same-binding + 4 cross-binding) matrix per scenario, mirroring
   `presence` — open to a narrower or wider default.
3. Scenario order (#1 coherent-sets, #2 `delete_contained_entities`, ...) — open to
   reordering if a different one looks more valuable to build first.
