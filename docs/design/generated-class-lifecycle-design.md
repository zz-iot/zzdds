# Generated-Class Lifecycle & Allocators

## Status

Implemented. This document describes how zzdds's generated bindings create and destroy
objects, and how they resolve which allocator to use when doing so — the design that
emerged from a review triggered by a real bug (`key_hashes`, below) in the raw/loan API.
`allocator-strategy.md` is still authoritative for the underlying allocator-*injection*
mechanics (factory bootstrap, CDR decode, C++ wrapper objects, STL containers) this doc
assumes as given; this doc is about what happens once multiple allocators can legitimately
be in play in the same process — specifically, how a generated `_free()` or entity
constructor decides which one to use.

## Background

`DataReader::take_raw`/`read_raw` produce three outputs: `cdr_payloads`, `key_hashes`,
`sample_infos`. Two of the three were released through `return_loan_raw`, an operation on
the reader itself — `self.alloc` (the reader's own, possibly custom, allocator) is in scope
there. `key_hashes` was released differently: allocated via `self.alloc` like everything
else, but freed through the *generic*, zidl-generated `{Type}_free()` export
(`DDS_OctetSeq_free`) — a `pub export fn` with no entity/context parameter at all, hardcoded
to a single allocator choice because it has no way to know which reader produced the buffer.
Allocate via a custom allocator, free via the generic path: `free(): invalid pointer`.
Reproduced concretely via `zzdds-examples`' `custom-allocator` cross-binding example, both
C and C++.

Two designs were weighed to fix it. Reusing `zidl-cdr`'s process-wide settable allocator was
fully implemented and verified, then reverted: it made `zidl-rt` (the pure-Zig CDR runtime,
which claims "no C build dependency") reach into `zidl-cdr` (the C implementation) — backwards
from this codebase's only precedent (`zidl-cdr`'s own test suite imports `zidl-rt`, never the
reverse) — and required a new `libzidl_cdr` link into zzdds's core build. The fix that
shipped instead extended `return_loan_raw` to take `key_hashes` as a third parameter: every
call site needing to release it already had the reader handle in scope, so this closed the
gap with no new mechanism at all, not even a new global. The general shape of the bug — any
C-ABI output that *can* be allocated by a per-entity allocator but is released through a
function with no entity context — turned out not to be an isolated incident (see
[Enforcement & tooling](#enforcement--tooling)): the same class of bug was found four more
times as this design was built out, and a sixth instance the moment real test coverage for
it was added. Every instance traces to the same root cause: a generic free function was
still hardcoded to a single allocator when a per-entity or process-configured one could
legitimately differ from it. That pattern is now the classification rule below.

## The classification rule

For any C-ABI-visible type or buffer that a generated binding hands to, or accepts from,
application code, ask one question: **does releasing this value happen by handing it back
to the entity that produced it, or does the application hold it and free it directly?**

- **Category 1 — entity-mediated (loan-style).** Release always happens through an op on
  the owning entity (`return_loan_raw(reader, ...)`, the `key_hashes` pattern). The entity
  is in scope at both allocation and release time, so it can always use its own
  `self.alloc` — no ambiguity, no global state needed. This is the preferred shape whenever
  a parent-entity relationship exists.
- **Category 2 — standalone / app-owned value.** The application either constructs the
  value itself (no factory op involved) or receives it from an operation with no
  corresponding "give it back" op, and calls a generic `{Type}_free()` directly. No entity
  is in scope at release time, by construction — not a gap to close, an inherent property
  of this shape. A generic free for a Category 2 type must never hardcode a specific
  allocator; it must route through whatever the process has been configured with (see
  [Allocator resolution](#allocator-resolution)).

Any type where ownership crosses the app/middleware boundary directly — the app constructs
it and hands it in, or the middleware produces it and hands it out for the app to free — is
Category 2 by construction: Category 1's defining property (a "give it back" op) is exactly
what's absent when ownership transfers outright. This is the shape of both
`GuardCondition`/`WaitSet` (app constructs, no factory op) and `ConditionSeq`
(middleware produces, no return-style op) — see the [appendix](#appendix-boundary-crossing-type-audit).

This rule does not conflict with `docs/decisions.md`'s "always explicit, no global
allocator" invariant. That invariant is about zzdds's Zig core — every Zig-native
allocation is explicit via `self.alloc`. Category 2 exists entirely at the C-ABI/C++
boundary, where the application is C or C++ code holding a value with no Zig entity object
anywhere in reach; the process-wide allocator is a property of the C-ABI layer's generated
free functions, never something Zig core code reads.

## Allocator resolution

Three mechanisms resolve "which allocator" for a generated free, matching the two
categories above plus one deployment concern:

**Entity-scoped (Category 1).** Every generated interface vtable carries a synthetic
`get_allocator: *const fn (*anyopaque) std.mem.Allocator` slot, mirroring the existing
`get_c_abi_handle` slot — implemented identically everywhere as `return self.alloc;`. Code
generated for a C-ABI operation wrapper (`emitCApiOp` in zidl's Zig backend) that needs to
release a buffer it produced *itself*, for an entity it already has in scope (e.g. the
native temporary behind `WaitSet::wait()`'s output boxing), calls
`_self.vtable.get_allocator(_self.ptr)` rather than guessing at a process-wide default.
Internal-only — this never crosses the C ABI, so it carries no ABI-break risk and needed no
new dependency.

One buffer shape needs care here: `emitCApiOp`'s entity-sequence boxing produces *two*
buffers with genuinely different correct allocator sources. The **native temporary**
(allocated internally by the vtable call, freed within the same generated function, never
exposed to the app) is correct to route through the entity's own `get_allocator()`. The
**app-owned boxed buffer** (handed to the caller, later freed via the standalone
`{Type}_free()` export) must stay on the process-wide allocator below, because that
generated free has no entity parameter to ask. **This is the one place the design is not
fully closed**: it's correct only as long as an entity's own `_with_allocator` allocator
matches whatever's registered process-wide — true for every existing example, not
structurally enforced. Closing it fully would need `{Type}_free()` itself to take an entity
parameter, a real C-ABI shape change not undertaken here.

**Process-wide (Category 2).** `zidl_cdr_get_allocator()` (paired with the pre-existing
`zidl_cdr_set_allocator()`, which CDR decode of unbounded fields already used for the same
reason) lets a generated free with no entity in scope — standalone sequence typedefs,
C-ABI struct mirrors used for QoS/config types — route through the process-wide registered
allocator instead of a hardcoded default.

**Opt-in at the codegen level.** Calling `zidl_cdr_get_allocator()` requires linking
`libzidl_cdr` — a real, new native-library dependency for *any* consumer of
`--zig-generate-c-api`, not just zzdds, including a "links only `zidl_rt`" configuration
that was fully valid before this design shipped (`zidl_rt` has zero dependencies of its
own). Making this the unconditional default broke exactly that configuration — confirmed
with a real link failure (`error: undefined symbol: zidl_cdr_get_allocator`) before the fix
shipped. So the routing is gated behind an opt-in flag, `--zig-generate-c-api-cdr-allocator`
— absent, generated frees fall back to `std.heap.c_allocator` (zero new dependency, the
behavior every consumer had before this design); present, they route through the
process-wide allocator. zzdds passes both flags together at its two `--zig-generate-c-api`
call sites in `build.zig`, since it already links `libzidl_cdr` unconditionally for C/C++
CDR decode — no added cost for zzdds specifically, only the fix. This mirrors
`allocator-strategy.md`'s own `--cpp-pmr-containers` precedent: a real dependency/
compatibility cost must not be forced on a consumer that didn't ask for it. Worth revisiting
if/when zidl grows a real plugin mechanism, which may offer a cleaner way to avoid
accumulating special-case flags like this one.

## The `@standalone` annotation

`GuardCondition` and `WaitSet` are the two condition-family types with no factory
operation in `dcps.idl` — per OMG spec, both are app-instantiated directly. Both carry
`@standalone` in the IDL, an inert, documentation/future-tooling marker: it costs zero
parser/builder changes (annotation capture is fully generic — any `@Identifier` is captured
into a type's `.raw` list regardless of whether anything interprets it, the same plumbing
`@shared_c_abi_box` already uses), and it records the classification for the diagnostic
tooling described below to check against. It's a bare marker with no parameters — the
number of Category-2-needing standalone types is expected to stay small (these two, plus a
handful of "simple" value types like `OctetSeq`/`StringSeq` an application might construct
directly), so a heuristic ("has owned fields → needs this treatment") would risk silently
reclassifying types as the IDL evolves, where an explicit annotation stays inert until
deliberately opted in — matching this codebase's existing precedent (`@key`, `@optional`,
`@default`) of driving codegen off explicit annotations rather than inferring intent from
shape.

The create/destroy boilerplate for `@standalone` types stays hand-written, not generated.
Generating `{Type}_create_with_allocator(...)`'s real body (e.g. `WaitSetImpl.init(alloc)`
→ `.toDDSWaitSet()` → box via `get_c_abi_handle`) would require generated code to name a
concrete Zig impl type — something no zidl-generated C-ABI export does anywhere else in this
codebase; every other generated export operates purely on abstract vtable-boxed interface
values. Instead, the actual repeated logic (allocator resolution, construct,
log-and-fall-back-to-nil on error, box) is collapsed into one shared helper,
`zzdds/src/util/standalone_create.zig`'s `createWithAllocator(comptime Iface, allocator,
comptime log_name, comptime construct, nil_value)` — mirroring `src/util/c_abi_handle.zig`'s
`CachedCAbiHandle` as the precedent for "a shared helper for a recurring C-ABI pattern."
`zzdds_create_waitset_with_allocator`/`zzdds_create_guardcondition_with_allocator`
(`extensions.zig`) each collapse to a small `{x}Ctor` function (combining the impl's
`.init()` and `.toDDS{Iface}()` into the signature the helper expects) plus a one-line call
into it — the impl-type reference stays in zzdds's own hand-written call site, ordinary Zig,
compiler-checked, never in generated code or an annotation string. The plain
`zzdds_create_waitset()`/`zzdds_create_guardcondition()` forms are unchanged, already-minimal
one-liners delegating to the `_with_allocator` form with a null allocator.

## `DomainParticipantFactory` and the other no-parent-op types

The factory is the root, and stays a deliberate exception, not a generalization target.
Every `@standalone` type exists independent of any particular allocator instance — several
`GuardCondition`s could be constructed under several different allocators in the same
process, no problem. The factory is different: it's the one object that *establishes* which
allocator everything downstream inherits. Folding
`zzdds_create_factory_with_allocator`/`zzdds_destroy_factory` into the same
annotation-driven pattern as leaf value types would force an artificial uniformity onto
something structurally singular — an allocator's origin point, not just another allocator
consumer — for no real benefit. Its hand-written `extensions.zig` implementation stays as
architecturally is: already correct, already the reference the rest of
`allocator-strategy.md`'s phases build on. Explicit allocator injection at construction is
the shared idea with the rest of this design; the mechanics legitimately differ for a root.

## Future bindings

"Consistent across bindings" means the same conceptual contract per binding — an explicit
create/destroy op pair for Category 2 types, an allocator injection point where the
language realistically offers one — expressed in each language's own idiom, not a uniform
method signature. This is as much a non-goal statement as a goal one: Python/C#/Haskell are
GC'd with no meaningful manual-allocator story at the object-construction level, so this
design does not attempt to design an allocator-injection story for them.

**Rust — spiked, not built.** A throwaway probe
(`zzdds-examples/spikes/rust/examples/allocator_spike.rs`) answered the concrete question:
can Rust consume zzdds's `ZidlAllocator` C-ABI injection point today, on stable, and what's
the realistic ceiling for a real future Rust binding's create/destroy story? Yes — it's a
`#[repr(C)]` struct with `extern "C" fn` pointers, ordinary FFI, nothing to do with Rust's
own allocator-trait machinery; a real end-to-end run (creating a factory, `WaitSet`, and
`GuardCondition` all under the same custom pool allocator) confirms it, and deliberately
breaking the pool allocator confirms it's genuinely consulted, not silently bypassed. Rust's
own per-object allocator generics (`Box<T, A>`, `std::alloc::Allocator`) remain nightly-only
(`error[E0658]`, tracking issue #32838, open since 2016) — confirmed with a direct compiler
check, not assumed. So the realistic idiomatic shape for a future Rust binding is exactly
what this design already uses elsewhere: an explicit `create_with_allocator(&ZidlAllocator)
-> Self` constructor paired with ordinary `Drop`. What that ceiling rules out: the binding's
own Rust-side wrapper types (an RAII guard, or a hypothetical `WaitSet` wrapper struct) being
*themselves* allocated through the injected allocator via `Box<T, A>`-style generics — those
stay on Rust's ordinary allocator until `allocator_api` stabilizes, an external constraint on
the Rust ecosystem, not a gap in this design. Full writeup in `spikes/rust/README.md`'s
"Allocator injection" section.

### The GC-lifecycle contract

Java's binding has no GC-driven release anywhere: entity lifetime is 100%
explicit-`delete_*`-call-driven, exactly mirroring the C/C++ parent-deletes-children
contract. What Java's GC does touch is a separate concern — a per-family weak-reference
identity cache that dedupes repeated `box()` calls for the same native handle so the same
Java wrapper object is reused; a GC'd wrapper just makes that cache lookup miss and lazily
reclaim the stale node, it does not free the underlying native resource. If an application
drops all references without calling `delete_<entity>()`, the native entity leaks —
accepted, load-bearing, though not previously stated as an explicit contract anywhere in the
repo before this review.

**Decision: explicit-only everywhere, matching Java's existing contract.** No GC-driven
release for any future GC'd binding either. Predictable behavior beats a forgiving one here
— a leaked or misused entity fails loudly and consistently rather than being inconsistently
masked by a best-effort finalizer whose timing is itself GC-nondeterministic across
languages. This removes an entire class of per-language design work (Java's `Cleaner`,
Python's `weakref.finalize`/`__del__`, C#'s `SafeHandle`/finalizer, Haskell's `ForeignPtr`
finalizers) from scope for every future binding, deliberately.

One wrinkle any future GC'd binding will hit, not unique to Java: a Category 2 type with no
factory op (`GuardCondition`) has nothing that naturally calls `box()`/registers it in the
identity cache the way an entity created via a parent op does — Java's binding needs a
separate manual registration entry point for it. Any future annotation-driven codegen for
Category 2 types should generate that registration hook generically for GC'd bindings, not
leave each binding to rediscover the gap independently the way Java did.

**Open action item**: this contract is currently true of Java's binding but is not written
down as an explicit statement in Java's own binding docs — this review is the first time
it's been stated anywhere. Whoever documents the next GC'd binding should carry the same
explicit statement forward on purpose, not by silent precedent.

## Zig-native binding

The Zig-native binding's typed wrapper calls core Zig methods directly and never goes
through the C-ABI generic free path at all — it was never exposed to the Category 2
hardcoded-allocator bug class, and has no analogous "generic free with no entity in scope"
problem, because Zig-native code always has an explicit `std.mem.Allocator` in scope by the
language's own construction discipline (`docs/decisions.md`'s "always explicit" invariant).
Treat it as the reference for what "correct" looks like conceptually, not as a fourth
binding needing its own version of this design's mechanics.

## Enforcement & tooling

The classification rule is checkable, not just documented, via two independent mechanisms
that close different halves of it:

**Structural elimination (allocator safety).** A permanent `zig build test` unit test in
zidl's Zig backend (`src/backend/zig.zig`, "allocator hygiene") reads the backend's own
source via `@embedFile` and fails if any hardcoded-default-allocator line appears in
C-ABI-facing generated-code paths outside two documented, legitimate exceptions (the
process-wide-allocator fallback, one per state of the opt-in flag). Deliberately pure Zig
rather than a shell `grep` step, so it runs identically across the whole CI matrix,
including Windows. This guarantees every generated free routes through one of the two
resolution mechanisms above — never a silent third hardcode — but says nothing about whether
a type's release *shape* (Category 1 vs. 2) was a deliberate choice.

**Classification sweep (shape correctness).** A diagnostic CLI flag,
`zidl -b <any> --audit-lifecycle <file.idl>`, walks an IDL file's interfaces and classifies
every operation's heap-owning output/return type: does a same-interface operation take it
back as an `inout` parameter? Found → Category 1; not found → Category 2, the normal case,
not an error. Prints a Markdown table (see the [appendix](#appendix-boundary-crossing-type-audit)
for the real output against `dcps.idl`/`zzdds.idl`). This is a reporting tool, not a build
gate — the classification rule's own text makes "no return-op" a definitive Category 2
answer, not an ambiguous one, so a hard-error-on-unclassifiable pass would essentially never
fire; the one thing genuinely worth surfacing is a type that looks Category-1-shaped on one
interface (some op produces it with no matching return-op, some *other* op on the same
interface separately takes it back) — a shape that could mean "this output should have been
released via that other op" as easily as it could mean two unrelated uses of a reusable
sequence typedef, so it's flagged for human judgment, never auto-resolved either way.
Confirmed cases in the real IDL are all the latter (legitimate type reuse), not bugs.

Both mechanisms were themselves the source of real findings, not just theoretical
guardrails: building structural elimination surfaced a previously-unknown bug (an
operation's by-value mirror-struct return path freeing an entity's own return value via a
hardcoded allocator instead of the entity's own — latent, since no real IDL operation uses
that shape yet, but fixed and tested to the same bar as if it were live); building the
classification sweep surfaced two matching-heuristic imprecisions once run against the real
IDL (the raw-loan family's shared `inout` parameters needed a name-based tiebreak to avoid
picking an arbitrary sibling over the real release op; QoS getter/setter pairs needed the
"give it back" check narrowed to `inout`-only, since a plain `in_` setter parameter sharing
a type name with a getter's output isn't a release signal). And extending
`zzdds-examples`' `custom-allocator` examples with real `WaitSet`+`GuardCondition` coverage
inside their existing `noalloc_guard` (an `LD_PRELOAD` shim aborting on any libc
`malloc`/`free`/`operator new`/`operator delete` while armed) caught two more real instances
on the spot: the C++ backend's shared entity identity-cache (`_familyCache`) had `pmr`-routed
*values* but a plain, non-`pmr` container; a hand-written bookkeeping object
(`WaitSetImpl::attach_condition`'s `ReleaseCtx` in `zzdds_cpp.hpp`) used plain `new`/`delete`
unconditionally. Both fixed the same way as everything else here: route through the
registered allocator, never hardcode.

That `ReleaseCtx` fix had a second, subtler bug of its own, caught by Greptile review on the
resulting PR: it *routed through* the registered allocator correctly, but re-queried
`std::pmr::get_default_resource()` independently at both allocation and free time rather than
capturing which resource was actually used at allocation. A live attachment can span a
`zidl::setCppAllocator()` reconfiguration (the default resource is process-wide and
mutable), so the free could silently select a *different* resource than the one that
allocated — this is the exact bug class `allocator-strategy.md`'s Phase 3 post-merge review
already found and fixed once before, for `_getOrCreate`'s own `ZidlAllocatorResource`, for
the identical reason. Fixed the same way: `ReleaseCtx` now stores the resource pointer
captured at construction and reuses it unconditionally at destruction, never re-querying.
Verified with a standalone program using two independent, pointer-bounds-checked tracking
resources — attach under resource A, reconfigure the default to resource B, detach; confirmed
the free correctly targets resource A regardless. Deliberately reverting the fix reproduces
a real, caught cross-resource free (not a hypothetical): resource B's tracking check aborts
on a pointer that was never allocated from its own buffer.

## Known limitations & future work

- **The app-owned boxed buffer's allocator match is not structurally enforced** — see
  [Allocator resolution](#allocator-resolution). Closing it needs `{Type}_free()` to take an
  entity parameter, a real C-ABI shape change.
- **The classification sweep is a diagnostic, not a build gate.** No case in the real IDL
  currently warrants hard-failing the build, but if one ever does, promoting it from report
  to gate is a real, separate design decision, not assumed here.
- **The full `dcps.idl`/`zzdds.idl` sweep is exhaustive as of this writing but not
  continuously re-verified** — the appendix below is a snapshot from a real tool run, not a
  CI-enforced invariant. Wiring `--audit-lifecycle` into CI (or into the classification
  sweep becoming a gate) would close that gap.
- **The opt-in `--zig-generate-c-api-cdr-allocator` flag is a point solution**, accepted
  because we don't know who else consumes `--zig-generate-c-api` besides zzdds. Revisit once
  zidl has a real plugin mechanism.
- **No real Rust (or Python/C#/Haskell) binding exists** — the Rust allocator spike answers
  one design question empirically; it is not the start of an implementation.
- **Java's explicit-only GC contract isn't written down in Java's own binding docs yet** —
  see [The GC-lifecycle contract](#the-gc-lifecycle-contract).

## Engineering notes

Lessons from building this out that are worth keeping visible for whoever touches this
codegen next, independent of the specific bugs above:

- **Check for an existing entity-aware op to extend before reaching for a new global
  mechanism.** The reverted `key_hashes` design (a new process-wide allocator adapter
  reaching across a package boundary) and the narrower one that shipped (extend
  `return_loan_raw` by one parameter) illustrate the general case: a narrower alternative
  using an existing pattern is often less work once identified than it first appears, and
  carries far less structural risk than introducing new global state or a new inter-package
  dependency direction. Discuss cross-cutting design changes before implementing them
  broadly — the reverted design was fully built and verified before the layering objection
  surfaced.
- **Verify Zig compilation-model assumptions empirically, not by reasoning.** Two
  non-obvious behaviors mattered here and were only trusted after real build failures/passes:
  a function reached only via a top-level `pub const X = mod.X;` alias in a test-root module
  is eagerly compiled (forcing its `extern fn` references to resolve) even if never called,
  where the same function reached via a namespace import (`pub const ns = @import(...)`,
  then `ns.X()`) is not; and a module-level `const` vtable literal holding function pointers
  forces eager compilation of the referenced functions, where the identical literal
  constructed inside a function body is lazy. The general habit this argues for: when a
  design's correctness depends on *when* Zig resolves or compiles something, confirm it with
  a real build, don't reason about it from the language spec alone.
- **Bulk/mechanical edits across near-duplicate call sites are risky when one site's
  semantics genuinely differ from its siblings.** A regex-driven pass across the
  `take_loaned`/`return_loan` family silently mis-edited the one site whose lifetime
  semantics diverged from its neighbors, in two backends independently — caught only by the
  next compile, and only because the edit happened to change an argument count. A bulk edit
  that preserved argument count but got the semantics wrong would not have been caught that
  way. Treat any site with different lifetime/ownership semantics from its neighbors as
  needing individual review after a mechanical pass, not just trust in the pattern.
- **A regression test's value is only as good as its own verification.** Every fix in this
  design was confirmed with a deliberate revert-and-confirm-it-fails cycle — temporarily
  undo the fix, confirm the specific failure mode reproduces (the exact crash signature, the
  exact test failure, the exact link error), reapply, confirm clean again — not just "the
  test passes now." This caught real problems on its own: a test helper that deinitialized
  an IR arena before returning strings borrowed from it produced a real segfault the first
  time the test actually ran, not a hypothetical one.

## Appendix: boundary-crossing type audit

### Reference examples

Hand-curated, with narrative detail the automated sweep below doesn't capture:

| Type | How created | How freed today | Crosses app/mw boundary | Needs entity context to free? | Category |
|---|---|---|---|---|---|
| `GuardCondition` | `zzdds_create_guardcondition[_with_allocator]` (hand-written, no IDL op) | `zzdds_destroy_guardcondition` | Y | N — self-contained pair already threads its own allocator | 2 (hand-written, `@standalone`-marked) |
| `WaitSet` | `zzdds_create_waitset[_with_allocator]` (hand-written, no IDL op) | `zzdds_destroy_waitset` | Y | N — same pattern | 2 (hand-written, `@standalone`-marked) |
| `ConditionSeq` (`WaitSet::wait()`/`get_conditions()` output) | Boxed via `emitTypedef`'s `is_entity_seq` branch | Generic `_free()`, routes through the process-wide allocator (app-owned half) / entity's own `get_allocator()` (native-temporary half) | Y (buffer of boxed handles) | Split — see [Allocator resolution](#allocator-resolution); the sweep below independently flags `wait`/`get_conditions` as a structurally-ambiguous pair, consistent with this | 2 |
| `key_hashes`/`cdr_payloads`/`sample_infos` (`take_raw`/`read_raw`) | Produced by `DataReader::take_raw`/`read_raw` | `return_loan_raw(reader, ...)` | Y | N | 1 — reference example, cleanly confirmed by the sweep below (no review flag) |
| Struct-with-owned-fields (e.g. `SensorLog`) | Decoded via generated `_deserialize` | Generic `{Type}_free()`, routes through the process-wide allocator | Y | N — already allocator-aware | 2 |
| `DomainParticipantFactory` | `zzdds_create_factory[_with_allocator]` | `zzdds_destroy_factory` | Y (root) | N — root/bootstrap case, binds the allocator everything else inherits | Root exception |
| Every other entity (`DomainParticipant`, `Publisher`, `Subscriber`, `Topic`, `DataWriter`, `DataReader`, `StatusCondition`, `ReadCondition`, `QueryCondition`) | Parent factory op | Matching `delete_*` on parent | Y (handle, not buffer) | N — parent entity already has `self.alloc` in scope | 1 |

### Full sweep

Tool-generated (`zidl -b zig --audit-lifecycle <file>`), every operation output/return type
across both files that structurally owns heap memory, per the classification rule.
**Flag = review** means the match is structurally plausible but not name-confirmed as a
release op; none of the flagged cases below are bugs — all are legitimate type-reuse or
getter/producer ambiguity (see [Enforcement & tooling](#enforcement--tooling)).

**`dcps.idl`:**

| Interface | Producing op | Type | Category | Matching return-op | Flag |
|---|---|---|---|---|---|
| `WaitSet` | `wait` | `DDS::ConditionSeq` | 1 (entity-mediated) | get_conditions | **review** |
| `WaitSet` | `get_conditions` | `DDS::ConditionSeq` | 1 (entity-mediated) | wait | **review** |
| `QueryCondition` | `get_query_expression` | `<unnamed>` | 2 (standalone) | — | |
| `QueryCondition` | `get_query_parameters` | `DDS::StringSeq` | 2 (standalone) | — | |
| `DomainParticipant` | `get_qos` | `DDS::DomainParticipantQos` | 2 (standalone) | — | |
| `DomainParticipant` | `get_default_publisher_qos` | `DDS::PublisherQos` | 2 (standalone) | — | |
| `DomainParticipant` | `get_default_subscriber_qos` | `DDS::SubscriberQos` | 2 (standalone) | — | |
| `DomainParticipant` | `get_default_topic_qos` | `DDS::TopicQos` | 2 (standalone) | — | |
| `DomainParticipant` | `get_discovered_participants` | `DDS::InstanceHandleSeq` | 1 (entity-mediated) | get_discovered_topics | **review** |
| `DomainParticipant` | `get_discovered_participant_data` | `DDS::ParticipantBuiltinTopicData` | 2 (standalone) | — | |
| `DomainParticipant` | `get_discovered_topics` | `DDS::InstanceHandleSeq` | 1 (entity-mediated) | get_discovered_participants | **review** |
| `DomainParticipant` | `get_discovered_topic_data` | `DDS::TopicBuiltinTopicData` | 2 (standalone) | — | |
| `DomainParticipant` | `get_current_time` | `DDS::Time_t` | 2 (standalone) | — | |
| `DomainParticipantFactory` | `get_default_participant_qos` | `DDS::DomainParticipantQos` | 2 (standalone) | — | |
| `DomainParticipantFactory` | `get_qos` | `DDS::DomainParticipantFactoryQos` | 2 (standalone) | — | |
| `TopicDescription` | `get_type_name` | `<unnamed>` | 2 (standalone) | — | |
| `TopicDescription` | `get_name` | `<unnamed>` | 2 (standalone) | — | |
| `Topic` | `get_qos` | `DDS::TopicQos` | 2 (standalone) | — | |
| `Topic` | `get_inconsistent_topic_status` | `DDS::InconsistentTopicStatus` | 2 (standalone) | — | |
| `ContentFilteredTopic` | `get_filter_expression` | `<unnamed>` | 2 (standalone) | — | |
| `ContentFilteredTopic` | `get_expression_parameters` | `DDS::StringSeq` | 2 (standalone) | — | |
| `MultiTopic` | `get_subscription_expression` | `<unnamed>` | 2 (standalone) | — | |
| `MultiTopic` | `get_expression_parameters` | `DDS::StringSeq` | 2 (standalone) | — | |
| `Publisher` | `get_qos` | `DDS::PublisherQos` | 2 (standalone) | — | |
| `Publisher` | `get_default_datawriter_qos` | `DDS::DataWriterQos` | 1 (entity-mediated) | copy_from_topic_qos | **review** |
| `Publisher` | `copy_from_topic_qos` | `DDS::DataWriterQos` | 1 (entity-mediated) | get_default_datawriter_qos | **review** |
| `DataWriter` | `get_qos` | `DDS::DataWriterQos` | 2 (standalone) | — | |
| `DataWriter` | `get_liveliness_lost_status` | `DDS::LivelinessLostStatus` | 2 (standalone) | — | |
| `DataWriter` | `get_offered_deadline_missed_status` | `DDS::OfferedDeadlineMissedStatus` | 2 (standalone) | — | |
| `DataWriter` | `get_offered_incompatible_qos_status` | `DDS::OfferedIncompatibleQosStatus` | 2 (standalone) | — | |
| `DataWriter` | `get_publication_matched_status` | `DDS::PublicationMatchedStatus` | 2 (standalone) | — | |
| `DataWriter` | `get_matched_subscriptions` | `DDS::InstanceHandleSeq` | 2 (standalone) | — | |
| `DataWriter` | `get_matched_subscription_data` | `DDS::SubscriptionBuiltinTopicData` | 2 (standalone) | — | |
| `DataWriter` | `loan_raw` | `DDS::OctetSeq` | 1 (entity-mediated) | return_loan_raw | |
| `DataWriter` | `publish_loan_raw` | `DDS::OctetSeq` | 1 (entity-mediated) | return_loan_raw | |
| `DataWriter` | `return_loan_raw` | `DDS::OctetSeq` | 1 (entity-mediated) | loan_raw | **review** |
| `Subscriber` | `get_datareaders` | `DDS::DataReaderSeq` | 2 (standalone) | — | |
| `Subscriber` | `get_qos` | `DDS::SubscriberQos` | 2 (standalone) | — | |
| `Subscriber` | `get_default_datareader_qos` | `DDS::DataReaderQos` | 1 (entity-mediated) | copy_from_topic_qos | **review** |
| `Subscriber` | `copy_from_topic_qos` | `DDS::DataReaderQos` | 1 (entity-mediated) | get_default_datareader_qos | **review** |
| `DataReader` | `get_qos` | `DDS::DataReaderQos` | 2 (standalone) | — | |
| `DataReader` | `get_sample_rejected_status` | `DDS::SampleRejectedStatus` | 2 (standalone) | — | |
| `DataReader` | `get_liveliness_changed_status` | `DDS::LivelinessChangedStatus` | 2 (standalone) | — | |
| `DataReader` | `get_requested_deadline_missed_status` | `DDS::RequestedDeadlineMissedStatus` | 2 (standalone) | — | |
| `DataReader` | `get_requested_incompatible_qos_status` | `DDS::RequestedIncompatibleQosStatus` | 2 (standalone) | — | |
| `DataReader` | `get_subscription_matched_status` | `DDS::SubscriptionMatchedStatus` | 2 (standalone) | — | |
| `DataReader` | `get_sample_lost_status` | `DDS::SampleLostStatus` | 2 (standalone) | — | |
| `DataReader` | `get_matched_publications` | `DDS::InstanceHandleSeq` | 2 (standalone) | — | |
| `DataReader` | `get_matched_publication_data` | `DDS::PublicationBuiltinTopicData` | 2 (standalone) | — | |
| `DataReader` | `take_raw` | `DDS::OctetSeqSeq` / `OctetSeq` / `SampleInfoSeq` | 1 (entity-mediated) | return_loan_raw | |
| `DataReader` | `read_raw` | `DDS::OctetSeqSeq` / `OctetSeq` / `SampleInfoSeq` | 1 (entity-mediated) | return_loan_raw | |
| `DataReader` | `take_next_instance_raw` | `DDS::OctetSeqSeq` / `OctetSeq` / `SampleInfoSeq` | 1 (entity-mediated) | return_loan_raw | |
| `DataReader` | `read_next_instance_raw` | `DDS::OctetSeqSeq` / `OctetSeq` / `SampleInfoSeq` | 1 (entity-mediated) | return_loan_raw | |
| `DataReader` | `return_loan_raw` | `DDS::OctetSeqSeq` / `OctetSeq` / `SampleInfoSeq` | 1 (entity-mediated) | take_raw | **review** |

**`zzdds.idl`** (its own new interfaces only — imported `dcps.idl` interfaces aren't
re-swept per file, matching how codegen itself only generates each file once):

| Interface | Producing op | Type | Category | Matching return-op | Flag |
|---|---|---|---|---|---|
| `DomainParticipantFactory` | `get_default_participant_config` | `zzdds::DomainParticipantConfig` | 2 (standalone) | — | |
| `DataReader` | `take_serialized` | `zzdds::SerializedSample` | 1 (entity-mediated) | take_next_instance_serialized | **review** |
| `DataReader` | `take_next_instance_serialized` | `zzdds::SerializedSample` | 1 (entity-mediated) | take_serialized | **review** |

`take_serialized`/`take_next_instance_serialized` mutually flagging is the same
legitimate-reuse shape as `WaitSet`'s pair above — both produce `SerializedSample`, neither
name suggests a release op, worth a human glance but not a confirmed bug.
