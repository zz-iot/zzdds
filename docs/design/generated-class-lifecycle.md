# Generated-Class Lifecycle & C-ABI Ownership — Handoff

## Purpose

This is a handoff, not a finished design. It captures a concrete bug we hit and fixed
(2026-08-23/24, zzdds PR #69's raw/loan API work), the design alternatives we tried
(including one we fully implemented, verified, and then reverted), and what we think the
next phase — "creation/destruction of generated classes and how they interact with
allocators and the C-ABI" — needs to resolve. Read this before touching C-ABI
create/destroy/free codegen again; it'll save re-deriving the reasoning below.

Related docs, for context this one builds on rather than repeats:
- `docs/design/allocator-strategy.md` — the existing, much larger design doc covering
  *injecting* a caller-controlled allocator into zzdds's C/C++ ABI (factory bootstrap,
  CDR decode, C++ wrapper objects, STL containers). That work is what makes per-entity
  custom allocators (`zzdds_create_factory_with_allocator`) possible at all — this doc is
  about a gap in what happens *after* injection: releasing a buffer correctly once
  multiple allocators can legitimately be in play in the same process.
- `docs/design/raw-loan-api.md` — the raw/loan API design this bug was found in.
- `docs/decisions.md` — architectural decisions log; the fix below should probably get an
  entry once it ships.

## The motivating bug

`DataReader::take_raw`/`read_raw` (the raw/loan API, added this session) produce three
outputs: `cdr_payloads`, `key_hashes`, `sample_infos`. Two of the three
(`cdr_payloads`/`sample_infos`) were always released through `return_loan_raw` — an
operation on the reader itself, which has `self.alloc` (the reader's own, possibly
custom, allocator) in scope. `key_hashes` was designed differently: allocated via
`self.alloc` like everything else, but marked releasable through the *generic*,
zidl-generated `{Type}_free()` export (`DDS_OctetSeq_free` in C/C++) — a `pub export fn`
with no entity/context parameter at all.

That generic free is hardcoded to a single allocator choice (`std.heap.c_allocator`) at
codegen time, because it has no way to know *which* reader produced the buffer it's
freeing, or what allocator that reader was created with. Allocate via a custom allocator
(`zzdds_create_factory_with_allocator`), free via the generic path → `free(): invalid
pointer`. Reproduced concretely via `zzdds-examples`' `c`/`cpp` `custom-allocator`
cross-binding example (a real crash, both directions, not a hypothetical).

**The general shape of the bug**: any C-ABI output that (a) can be allocated by a
per-entity/per-factory allocator, and (b) is released through a function with no entity
context, is exposed to this exact mismatch. `key_hashes` is the one confirmed instance.
It is very likely not the only one — see "Known, not-yet-audited similar gaps" below.

## Two designs, and why we picked the narrower one

**Design A — reuse zidl-cdr's existing process-wide settable allocator.**
`zidl_cdr_set_allocator`/`zidl_cdr_alloc`/`zidl_cdr_free` already exist (CDR decode of
unbounded fields routes through them — see `allocator-strategy.md` Phase 2, which chose
this same process-wide shape for a similar reason: the free side there also has no
per-call context). We built a `zidl_rt.allocator.cdrAllocator()` adapter and routed both
`key_hashes`' allocation *and* the generic `{Type}_free()`'s implementation through it.
Fully implemented, fully verified (including a full `run_deterministic_matrix.py
--include-tsan` pass and a real re-run of the crashing example), then **reverted** after
a design discussion surfaced a real problem: it made `zidl-rt` (the pure-Zig CDR runtime,
whose own doc comments claim "no C build dependency") reach into `zidl-cdr` (the C
implementation) via a bare `extern fn` — backwards from the only precedent in this
codebase (`zidl-cdr`'s test suite imports `zidl-rt`, never the reverse). It also required
newly linking `libzidl_cdr` into zzdds's *core* build (previously C-ABI-only), a real
structural expansion just to fix one field.

**Design B — extend the existing entity-aware release op (what shipped).**
Every call site that needs to release `key_hashes` already has the reader handle in
scope, sitting right next to an existing `return_loan_raw(reader, payloads, infos)` call.
Adding `key_hashes` as a third parameter closes the gap with **no new mechanism at all** —
not even reusing zidl-cdr's global. `return_loan_raw` already has `self.alloc` in scope,
so it always frees correctly, unconditionally, regardless of which allocator the reader
was created with.

**Why B won**: it's not a workaround, it's the same pattern the codebase already uses
correctly for the other two outputs. It needed no new cross-repo dependency, no new
build.zig linking, no new global state. The one real complexity was `take_loaned`/
`return_loan` (loan mode): `key_hashes` is *always* a plain copy regardless of loan/copy
mode (its own doc comment says so), so it doesn't share `cdr_payloads`'/`sample_infos`'
loan-mode lifetime — it must be released immediately, not held until the caller's later
`return_loan()` call. Solved by calling the (now 3-arg) `return_loan_raw` *twice* with
disjoint, zeroed scope: once immediately after `take_raw`, passing zeroed/empty
payloads+infos locals so only `key_hashes` is actually released; once later (error path,
or the real `return_loan()`), passing a zeroed/empty `key_hashes` local since the real one
is already gone.

**When Design A's shape *would* be right**: if a future case genuinely has no entity in
scope at the release site — e.g., a value decoded standalone with no owning DDS entity at
all. `key_hashes` isn't that case (a reader is always right there), which is exactly why
B was strictly better here. Don't reach for a global allocator registration as the default
answer; check whether an entity-aware release op can just grow one parameter first.

## Known, not-yet-audited similar gaps

Found while investigating this bug, deliberately **not fixed** (out of scope for a
CI-red fix, no confirmed matching allocate-side bug — fixing the free side alone without
auditing the allocate side risks *introducing* a mismatch rather than closing one):

- **`emitTypedef`'s `is_entity_seq` branch** (zidl `zig.zig` backend) — the generic free
  for a boxed entity sequence (e.g. `ConditionSeq` from `WaitSet::wait()`). Still
  hardcoded to `std.heap.c_allocator`. Never confirmed whether the *allocate* side
  (`emitCApiOp`'s boxing adaptation) ever uses anything else — if it never does, this is
  fine as-is; if it can inherit a per-entity allocator the way `key_hashes` did, it's the
  same bug class, unexercised so far because nobody's built a custom-allocator consumer
  of `WaitSet::wait()` yet.
- **`emitStructCApiFree`** (same backend) — the generic free for any C-ABI struct with
  owned/sequence fields (config-mirror structs, etc.). Also hardcoded to
  `std.heap.c_allocator`. Unlike the two cases above, this one's allocate side
  (`{Struct}FromCAbi`) *also* always uses `std.heap.c_allocator` — no confirmed mismatch,
  but this should be a **documented, deliberate** classification ("this struct family is
  always process-default-allocator, never entity-custom-allocator, because X"), not an
  unexamined assumption that happens to hold today.
- **Anywhere else a raw-op-shaped or entity-op-shaped function returns a buffer without
  routing its release through an op on the owning entity.** This needs a systematic sweep
  of `dcps.idl`, not spot fixes — see "long-term requirements" below.

## Long-term requirements for the next design phase

The user's framing for the next phase — "solidify the design for creation/destruction of
generated classes and how they interact with allocators and the C-ABI" — should, at
minimum, resolve:

1. **An explicit, per-type/per-op classification rule**: for every C-ABI-visible buffer
   or object, does releasing it ever need to know *which allocator produced it*? If yes,
   it *must* be released through an op on the owning entity — never a generic,
   context-free `_free()`. If no (the type/op family is architecturally guaranteed to
   only ever use one fixed allocator), a generic free is fine, but that guarantee should
   be documented at the point of generation, not assumed. This is the rule `key_hashes`
   violated silently; making it explicit and checkable (ideally something zidl's codegen
   can assert or lint, not just a comment) prevents the next instance of this bug class
   from being invented by accident.
2. **A systematic audit against `dcps.idl`**, not spot fixes — walk every operation that
   returns caller-owned memory and classify it per (1). The two items in "Known,
   not-yet-audited gaps" above are the starting list, not the whole list.
3. **A decision on whether the C-ABI's two codegen layers should even allow a typed
   wrapper to call a generic `_free()` directly.** There are two distinct codegen layers
   in play: `--zig-generate-c-api` (`zig.zig` backend — emits the raw C-ABI `_free()`
   exports, generic, no entity context) and `--generate-zzdds-wrappers` (`c.zig`/`cpp.zig`
   — hand-templated text orchestrating calls *between* raw ops for the typed-wrapper
   convenience layer). The bug lived specifically in the second layer choosing to call
   the first layer's generic free instead of routing through an available entity-aware
   op. Consider whether codegen should structurally prevent that choice for outputs
   classified as "needs entity context" per (1), rather than relying on each hand-written
   template to get it right independently.
4. **Confirm and preserve the Zig-native binding's structural immunity.** The Zig backend's
   typed wrapper calls core Zig methods directly and never goes through the C-ABI generic
   free path at all — it was never exposed to this bug class. Worth treating as the
   consistency target/reference implementation for whatever C/C++ redesign comes out of
   this, rather than a coincidence to note in passing.
5. **Confirm Java's status explicitly, don't assume from one data point.** Java was
   unaffected by this specific bug (its generic JNI marshaling copies through a fresh
   buffer per call, no persistent generic-free-of-a-custom-allocated-buffer pattern) —
   but check whether Java's binding even exposes `zzdds_create_factory_with_allocator`
   today, and if/when it does, re-verify this holds rather than assuming it always will.
6. **Relationship to `allocator-strategy.md`'s existing phases.** That doc's Phase 2
   already made the "process-wide vs. per-entity" tradeoff explicitly for CDR decode, for
   a similar no-context-at-free-time reason. Phase 5 audited and fixed every generated
   `{Type}_free()` body for *value structs with owned fields* — but that audit predates
   the raw/loan API (a later addition) and, by construction, only ever covers types whose
   producer and consumer are both the same process-wide CDR allocator, so it structurally
   can't have caught this bug class. The next phase should decide whether raw-op outputs
   (and any future op family with the same shape) get folded into that same audit
   methodology, or need their own.

## Lessons learned

- **Discuss cross-cutting design changes before implementing them broadly**, especially
  when introducing new global state or a new inter-package dependency direction. The
  global-allocator design was fully built, tested, and verified before the layering
  objection surfaced — requiring a complete revert. A narrower alternative (extend an
  existing entity-aware op) existed the whole time and turned out to be less work once
  identified. When "buffer needs releasing but the release site has no context" comes up
  again, check for an existing entity-aware op to extend *before* reaching for a new
  global mechanism.
- **Verify Zig compilation-model assumptions empirically, not by reasoning.** Two
  non-obvious behaviors surfaced and were only trusted after real build failures/passes,
  not source-reading: (1) a function reached only via a top-level `pub const X = mod.X;`
  alias in a test-root module is eagerly compiled (forcing its `extern fn` references to
  resolve) even if never called; the same function reached via a *namespace* import
  (`pub const ns = @import(...)`, then `ns.X()`) is not. (2) A module-level `const` vtable
  literal holding function pointers forces eager compilation of the referenced functions;
  the identical literal constructed *inside* a function body is lazy, materialized only
  if that function is actually invoked. Both mattered for why the (reverted) Design A
  needed its adapter reached a specific way to avoid breaking `zidl-rt`'s own standalone
  test suite.
- **Bulk/mechanical text edits across near-duplicate codegen call sites are risky when one
  site's semantics genuinely differ from its siblings, even if it looks similar.** The
  `take_loaned`/`return_loan` pair (loan-mode, where `key_hashes`' lifetime diverges from
  `cdr_payloads`'/`sample_infos`') was silently mis-edited by the same regex-based bulk
  pass, independently, in *both* `c.zig` and `cpp.zig` — caught only by the next compile
  (a missing-argument error against the new signature), not by inspection. The compiler
  caught it this time because the edit happened to change an argument count; a bulk edit
  that preserved argument count but got the semantics wrong would not have been caught
  this way. Treat any site with different lifetime/ownership semantics from its
  neighbors as needing individual, not bulk, review after a mechanical pass.
- **Review rounds surfaced this gap one layer at a time** (a UAF race → an OOM leak → an
  unguarded delete path → this allocator mismatch), each requiring its own investigation.
  For the next phase's audit, do the systematic sweep (per "long-term requirements" #2)
  up front rather than waiting for each gap to surface individually through review.
