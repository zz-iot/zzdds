# dds-rtps Interoperability Suite Coverage Audit (2026-08-14)

Companion to `docs/design/dcps-api-coverage-audit.md`, which covers zzdds-examples/
dds-rtps from the "which DCPS API gets exercised" angle. This doc looks the other way:
given dds-rtps's `test_suite.py` (104 test cases, upstream OMG suite at
github.com/omg-dds/dds-rtps) is meant to gauge cross-vendor **RTPS wire interoperability**,
where are the gaps worth proposing back to the interop group — new test cases, and
possibly new/newly-documented `shape_main` switches?

Two angles: (1) `shape_main` flag parity across ports — does zzdds's own port support
everything the suite might want to throw at it, and are there implemented-but-undocumented
switches; (2) `test_suite.py` scenario coverage — which QoS/behavior dimensions are thin
or missing entirely.

## 1. `shape_main` flag parity

The canonical parameter list lives in dds-rtps's `README.md` ("Shape Application
parameters"). `srcC/shape_main.c`'s argument parser has several single-letter case labels
that don't obviously map to that list; checked each one against the actual code, not just
the letter.

**zzdds (`srcZig/shape_main.zig`) port gap: missing `--datafrag-size`/`-Z` — fixed
(2026-08-20), and rolled out to zzdds-examples' `zig/c/cpp/java shape` ports too, not just
this one.** `srcC` implements this (validated ≤65535 bytes, RTPS spec-referenced in its own
error message) — sets the DATA_FRAG fragment size directly, independent of payload size.
zzdds's shape had `--additional-payload-size` for large payloads but no way to pin a
specific fragment size, so it couldn't participate in any test case that targets a
fragmentation boundary precisely rather than just "payload is large." See `docs/roadmap.md`'s
"`-Z`/`--datafrag-size` rolled out to every `shape` port" entry for the full writeup,
including two real bugs found along the way (a silently-broken `--periodic-announcement` in
all five ports, and a serious C-ABI/Zig-native struct-layout mismatch in
`create_participant_ex`/`get_default_participant_config`/`set_default_participant_config`
affecting every non-Zig-native caller, not fixed yet). This directly unblocks item 5 below.

Minor, not worth prioritizing: zig's port has no `-v` verbosity flag (cosmetic, no wire
effect). One flag goes the other way — zig's `--publisher-matches`/`--subscriber-matches`
don't exist in `srcC` at all (a zzdds-only addition, not a gap).

**Undocumented-but-implemented in `srcC`** (all confirmed used in `test_suite.py`, so
these are "needs documenting," not "needs building"):
- `-F`/`--cft <expression>` — ContentFilteredTopic expression on the subscriber.
- `-Q`/`--size-modulo <int>` — wraps `-z 0`'s auto-incrementing shapesize back to 1 after
  reaching this modulo.

**Undocumented, implemented, validated, spec-referenced, and *zero* test cases use it:**
- `-Z`/`--datafrag-size <bytes>` — see above. This is the standout candidate: a real,
  already-built, already-validated switch that the official suite has simply never
  written a test case against. Low-effort, concrete "propose upstream" candidate — both
  documenting the switch and adding real DATA_FRAG-boundary test cases.

(Every other "mystery" case letter in `srcC`'s parser turned out to be a short-flag alias
of an already-documented long option — e.g. `-l`→`--lifespan`, `-K`→`--take-read`,
`-N`→`--periodic-announcement` — not a real gap, just the README not listing short forms.)

`validate()` in `srcC` (just above the parser) is worth knowing before proposing new
cases: several flags are silent no-ops on the subscriber side (`--lifespan`,
`--num-instances`, `--final-instance-state`, `--coherent-sample-count`), `--cft` and `-c`
are mutually exclusive on subscribers (hard error), and `--access-scope` without
`--coherent`/`--ordered` is a warning not an error.

## 2. `test_suite.py` scenario coverage (104 test cases)

| Dimension | Cases | Depth |
|---|---|---|
| CoherentSets | 22 | largest category; presentation scope × coherent/ordered combos |
| Durability | 18 | thorough on **compatibility matching** (all 16 kind combinations); only 2 cases have **behavioral** verification (VOLATILE, TRANSIENT_LOCAL) |
| OrderedAccess | 16 | INSTANCE vs TOPIC scope (case 11 is missing/removed from the numbering) |
| Lifespan | 8 | expiry timing, multi-instance |
| Ownership | 7 | SHARED/EXCLUSIVE compat (3) + strength arbitration at fixed creation-time values (4) |
| Reliability | 6 | compat matrix (3) + ordering/no-loss behavior (3) |
| Deadline | 4 | compat matrix (3) + exactly one missed-deadline case, permanently-missed (never re-armed) |
| DataRepresentation | 4 | XCDR1/XCDR2 — **compatibility only**, no content-correctness check |
| Partition | 3 | exact match, no-match, wildcard match |
| FinalInstanceState | 3 | unregister, dispose, implicit-unregister-on-exit |
| Domain | 3 | basic isolation |
| History | 2 | KEEP_LAST=5, but deliberately sized so depth is never actually exceeded |
| Cft | 2 | key-field filter, non-key-field filter |
| TimeBasedFilter | 2 | single/multi-instance |
| Topic | 2 | name match / no-match |
| LargeData | 1 | single fixed size (100000 bytes), RELIABLE only |

No `SKIP`/vendor-exclusion logic exists in `test_suite.py` itself — every case runs for
every vendor pair the outer CI matrix selects; vendor-specific exclusions live entirely
outside this file.

### Candidate gaps worth proposing upstream, ranked by (value ÷ effort)

1. **RESOURCE_LIMITS: zero coverage.** `max_samples`/`max_instances`/`max_samples_per_instance`
   never appear anywhere. Real QoS policy, wire-visible cross-vendor behavior
   (SAMPLE_REJECTED), currently entirely untested. New category, not a tweak.
2. **TRANSIENT/PERSISTENT durability have zero behavioral verification.** Only VOLATILE
   and TRANSIENT_LOCAL are confirmed to actually replay-or-not correctly; TRANSIENT and
   PERSISTENT are compatibility-matched but never checked for the replay behavior their
   whole purpose is. `test_durability_transient_local`'s exact pattern is trivially
   reusable — cheapest high-value fix on this list.
3. **`--datafrag-size` has zero test cases** (see §1) — implemented, validated, spec-cited,
   unused. Requires zzdds's own port to add the flag first (§1's action item) before zzdds
   could even participate in a case that used it.
4. **KEEP_LAST eviction is never actually exercised.** `Test_History_0`/`_1`'s own
   description admits the write rate is chosen so depth=5 is "enough" — i.e. they test
   RELIABLE delivery surviving a slow reader, not eviction. No case confirms a late
   joiner under KEEP_LAST N receives only the last N samples.
5. **Deadline re-arming/clearing is untested.** The one deadline-missed case is permanently
   missed by construction; nothing confirms a writer that resumes in-time writes correctly
   clears the missed condition rather than latching it.
6. **`--num-topics` is completely unused** despite being documented and (presumably)
   implemented across ports — zero multi-topic coverage.
7. **Ownership strength is only tested at fixed creation-time values.** No case changes
   `ownership_strength` post-match via `set_qos()` to confirm dynamic re-arbitration; the
   existing test comments even acknowledge the late-joining-higher-strength case without
   testing it.
8. **LargeData is one fixed size, RELIABLE only.** No BEST_EFFORT-large-data (fragment-loss
   handling differs meaningfully by reliability kind), no MTU-boundary-targeted size, no
   combination with multiple instances/topics.
9. **XCDR1/XCDR2 is compatibility-only**, no content round-trip check. Lower priority in
   practice — Shape's own type is too trivial (no optional/appendable/mutable members) for
   this to be very revealing without extending the type itself, which is a bigger ask.

## Bottom line

One immediate zzdds-side action (add `--datafrag-size` to `shape_main.zig`), one
documentation-only upstream fix (`--cft`/`--size-modulo` aren't in the README), and a
short, concrete list of new-test-case proposals for the interop group — RESOURCE_LIMITS
and TRANSIENT/PERSISTENT durability behavioral checks are the strongest candidates by
value-to-effort ratio.
