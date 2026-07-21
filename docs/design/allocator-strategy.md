# Allocator Strategy for Embedded / Real-Time Consumers

## Scope

Who needs to control zzdds's internal allocation, and what do they already have:

| Consumer | Today | Gap |
|---|---|---|
| Zig-native (links zzdds as a Zig module) | **Full control already.** `DomainParticipantFactoryImpl.init(alloc, ...)` takes a `std.mem.Allocator` as its first parameter; every downstream object (`FactoryOwner`/participant/topic/writer/reader/history cache) inherits `self.alloc` from whatever created it. | None found — see inventory below. |
| C (`zzdds_c.h`, `-Dc-binding=true`) | Whatever `zzdds_create_factory()` hands you, which is hardcoded. | No injection point at all. |
| C++ (`zzdds_cpp.hpp` + generated `dcps_impl.hpp/cpp`, `-Dcpp-binding=true`) | Same C-ABI gap, plus its own wrapper-object allocation on top. | No injection point; a second, independent allocation surface in the generated typed layer. |

This document is about the **C and C++ gaps** — making zzdds's internal allocation
end-user-configurable from outside Zig, for real-time/embedded consumers who need bounded,
deterministic, or literally-no-heap allocation behavior. It assumes Linux/POSIX-class
embedded and real-time targets (industrial, automotive, audio, robotics) that can link a
shared/static library and run OS threads — **not** bare-metal/freestanding targets. That's
zidl's separate `--profile xrce` / MicroZig track (`zidl/docs/roadmap.md` "Embedded /
MicroZig / XRCE Roadmap"), which is about not depending on an OS or a real heap at all.
The two tracks are complementary, not competing: this work makes zzdds's *existing*
POSIX/UDP path allocator-configurable; XRCE is a different, more constrained transport and
generation profile entirely. Don't conflate them when prioritizing.

## Current-state inventory (verified against the source, not assumed)

**Zig core — already allocator-agnostic.** Exhaustive search (`grep -rn "std\.heap\."
src/`) found zero hardcoded heap use in `transport/`, `discovery/`, `rtps/`, `dcps/`
(besides `nil.zig`, see below), or `history.zig` — every allocation traces to a
`self.alloc: std.mem.Allocator` field set at construction. This means **Phase 1 below is
sufficient to make the entire Zig core honor a caller-supplied allocator** — there is no
second hardcoded layer hiding underneath.

**The one C-ABI bootstrap hardcode.** `zzdds_create_factory()`
(`src/c_abi/extensions.zig:340`) is the *only* bootstrap entry point in the public C-ABI.
Its implementation, `createFactory()` (same file, ~line 421): `const alloc =
std.heap.c_allocator;` — hardcoded, zero parameters. That allocator is stored once on
`FactoryOwner.alloc` and inherited by construction by every object the factory ever
creates. This is the highest-leverage single fix in this whole plan: one signature change
unlocks the entire Zig core's already-correct allocator-plumbing for C and C++ callers at
once.

**Nil-singleton bookkeeping.** `dcps/nil.zig` and a handful of `nil_*_c_abi` statics in
`c_abi/extensions.zig` hardcode `std.heap.c_allocator` for the C-ABI handle boxes of
*nil* sentinel objects (there's no real impl object to hang a cache field off of). This is
a fixed, one-time, tiny allocation (a handful of pointer-sized boxes, created once per
process, not per call) — not on any hot path, not scaling with entity/traffic count. Not
worth solving; noted here so it isn't mistaken for a missed gap.

**zidl's C CDR runtime — `ZidlCdrAllocator` (already tracked, `zidl/docs/roadmap.md`).**
`zidl_cdr_read_string` / `zidl_cdr_read_seq_*` (`packages/zidl-cdr`) call `malloc`
directly when decoding an unbounded `string` or `sequence` field of a **user-defined
topic type**. This is a separate code path from zzdds's own internal RTPS/discovery CDR
(which is Zig-generated and already allocator-agnostic per above) — it only fires when a
C or C++ application's own message type has an unbounded string/sequence field and gets
deserialized through the generated `_deserialize` function. Directly relevant to the
showcase apps below the moment a sample type isn't fully bounded/fixed-size.

**zidl's C++ typed layer — two distinct allocation surfaces, not one:**
1. *STL containers inside generated types* (already tracked as "C++ generated binding
   allocator injection" / "Custom allocators for `std::string`/`std::vector`/`std::map`"):
   a struct field of type `sequence<T>` becomes `std::vector<T>` using the global
   allocator, unparameterized.
2. **Newly identified while doing this session's `_getOrCreate` work, not previously
   tracked**: every entity wrapper object itself — `TopicImpl`, `DataWriterImpl`,
   etc. — is heap-allocated via `std::make_shared<FooImpl>(h)` inside `_getOrCreate`
   (`zidl/src/backend/cpp.zig`), and the hand-written `zzdds_cpp.hpp` convenience layer
   (`create_factory()`, `FactoryHandleGuard`, etc.) does the same for its own bookkeeping
   objects via ordinary `new`/`shared_ptr` construction. This is orthogonal to (1) — it's
   not about fields *inside* a message type, it's the wrapper objects representing
   entities and the factory itself. Both need solving for a genuinely no-heap C++
   showcase; see "the C++ template problem" below for why (2) is deceptively hard.

**Thread stacks — not a gap, no work needed.** All 9 `std.Thread.spawn` call sites in
zzdds pass a default `SpawnConfig{}` (`allocator: null`), so Zig's stdlib allocates each
thread's stack via a direct `posix.mmap` call, not through `std.mem.Allocator` and not
through libc `malloc`/`new`. A "zero `malloc`/`new`" claim already holds for thread
creation with no changes. Worth stating explicitly in the showcase apps' documentation so
reviewers don't mistake "the app spawns pthreads" for "the app calls malloc" — they're
unrelated. (Related but out of scope: `docs/design/thread-model.md` notes there is no
single-threaded/polling `drive()` API yet, so even a minimal two-participant demo will
have several background threads — UDP recv, SPDP timer, per-matched-reader heartbeat.
That's a thread-*count* question, not an allocator question; not addressed here.)

## The shared allocator-vtable ABI

**Design decision: define it once, in the lowest layer, and reuse it everywhere.**
`zidl-cdr` (the C CDR runtime) is a dependency of zzdds's C-ABI, not the reverse. If
zzdds's C-ABI and zidl-cdr's runtime each invented their own allocator-vtable struct, C/C++
callers would need to bridge two incompatible interfaces for what is conceptually one
knob. The vtable struct — call it `ZidlAllocator` — should be defined in zidl-cdr's public
runtime header (`zidl_cdr.h` or a new small `zidl_allocator.h`) and re-used, unmodified,
by zzdds's C-ABI. This sets the actual build order: **the shared type has to land in zidl
first**, even though the highest-*impact* single change (Phase 1) is in zzdds.

Shape (mirrors `std.mem.Allocator.VTable`'s alloc/resize/remap/free split so the Zig-side
adapter is a mechanical, allocation-free translation, not a semantic remapping):

```c
typedef struct {
    void *ctx;
    void *(*alloc)(void *ctx, size_t len, size_t alignment);
    bool  (*resize)(void *ctx, void *ptr, size_t old_len, size_t new_len, size_t alignment);
    void  (*free)(void *ctx, void *ptr, size_t len, size_t alignment);
} ZidlAllocator;
```

**Critical constraint for a genuine zero-`malloc` bootstrap: zzdds must never heap-allocate
anything to *represent* the caller's allocator.** The adapter that bridges `ZidlAllocator`
into a Zig `std.mem.Allocator` (same shape as the existing `CKeyHashAdapter` pattern in
`src/c_abi/typesupport.zig`, which already bridges a C function pointer into a Zig
interface) must not be heap-boxed. Concretely: `std.mem.Allocator` is just `{ ptr:
*anyopaque, vtable: *const VTable }`, two words, passed by value — construct it as `.{
.ptr = @ptrCast(caller_supplied_ZidlAllocator_ptr), .vtable = &zidl_allocator_adapter_vtable
}`, where `zidl_allocator_adapter_vtable` is a single process-wide `static const` and `ptr`
points directly at the caller's own `ZidlAllocator` struct. The caller owns that struct's
storage (documented lifetime contract: must outlive the factory, same discipline already
used for `zzdds_register_type_support_c`'s callback pointer) — zzdds allocates *nothing* to
represent it. Getting this wrong (e.g. `alloc.create(Adapter)`-ing a copy) would silently
defeat the entire point for a caller whose own `alloc` function is a static pool with no
spare capacity for zzdds's own bookkeeping.

## Phased plan

**Phase 0 — Define `ZidlAllocator` (zidl repo, zidl-cdr package). Done.** `ZidlAllocator`
(`ctx` + `alloc`/`resize`/`free` function pointers, mirroring `std.mem.Allocator.VTable`'s
alloc/resize/free split) defined in `packages/zidl-cdr/include/zidl_allocator.h` — a new,
dependency-free header, not folded into `zidl_cdr.h`, since it's used by zzdds's C-ABI too
and isn't CDR-specific. `toAllocator()` in `packages/zidl-rt/src/allocator.zig` bridges it
into a `std.mem.Allocator`; `ZidlAllocator` is hand-mirrored there as a Zig `extern struct`
(matching the `EntityBox` precedent) rather than pulled in via a C header/translate-c step,
keeping zidl-rt a pure-Zig package. `remap` (Zig 0.16's vtable requires it, but there's no
separate C-ABI concept for it) is implemented by delegating to the same C `resize`
function — a successful in-place resize *is* a remap; a failed one correctly falls through
to Zig's own alloc+copy+free path. Verified allocation-free: a test constructs the adapter
twice against a tracked fixed-pool context and asserts zero bytes were consumed by
`toAllocator` itself, plus tests for alloc/free round-trip, OOM surfacing as
`error.OutOfMemory` (not a crash), and grow-forces-fallback/shrink-in-place behavior. No
behavior change yet — nothing downstream consumes it; that's Phase 1.

**Phase 1 — zzdds C-ABI bootstrap injection (zzdds repo). Done.**
`zzdds_create_factory_with_allocator(const ZidlAllocator *allocator)` added
(`src/c_abi/extensions.zig`); `zzdds_create_factory()` is now a thin wrapper passing
`NULL` (→ `std.heap.c_allocator`, unchanged default), preserving source/ABI compatibility.
Mirrored into `zzdds_cpp.hpp`'s `create_factory(const ZidlAllocator*)` overload (shares
its wrapping logic with the existing zero-arg version via a new `wrapFactoryHandle`
helper, rather than duplicating the `shared_ptr`/deleter setup).

Verified two ways, not just compiled: (1) a Zig-level test
(`test/c_abi/bootstrap_test.zig`) wraps `std.testing.allocator`'s raw vtable functions in
a `ZidlAllocator` shim and confirms real allocation activity through it across factory
bootstrap *and* participant creation (which spins up a real `UdpTransport` +
`SpdpSedpDiscovery` + `DomainParticipantFactoryImpl`/`DomainParticipantImpl` stack) — a
missing free anywhere in the path would trip `testing.allocator`'s own leak detector; (2)
a standalone C++ program compiled and linked against the real built `libzzdds.so` +
generated `dcps_impl.cpp`/`zzdds_impl.cpp`, using `zzdds::create_factory(&custom)` to
create and tear down a real participant — `83 allocations, 83 frees, 0 bytes
outstanding`.

Getting to a real (not just compiled-in-isolation) C++ verification surfaced four
pre-existing bugs in zidl's C++ backend that had never been caught before, because nobody
had ever actually compiled zzdds's own `zzdds_impl.cpp` (as opposed to `dcps_impl.cpp`,
which doesn't hit them) with a real C++ compiler:
1. **`native_handle()` override mismatch** — the IR builder's cross-module import-fill
   reset entity interfaces' `.bases` to empty (deliberately, to avoid growing Zig vtables
   with cross-module operations — see `resetNonCallbackInterfaces` in
   `zidl/src/ir/builder.zig`), which made a real base (e.g. `DDS::DomainParticipant :
   Entity`) look base-less from a different file's generation pass. Fixed by preserving
   `.bases` specifically (still resetting everything else) plus making
   `collectEntityBaseNames` walk the base chain transitively — see zidl's roadmap for
   the full design writeup.
2. **Listener trampoline wrapping the wrong class** — a cross-module `@callback
   interface` (`zzdds::DataWriterListenerEx : DDS::DataWriterListener`) flattens in
   operations whose entity parameter belongs to the *base's* module, but the trampoline
   used a bare class name that resolved in the *listener's own* namespace instead. Fixed
   by using the already-existing `entityImplName()` qualifier consistently.
3. **A real regression from this session's earlier `_getOrCreate` work, not
   pre-existing**: making `_getOrCreate` unconditional meant its `std::make_shared`
   body was compiled for every entity class, including ones intentionally left
   abstract (finished by a hand-written subclass elsewhere, e.g. `zzdds_cpp.hpp`'s
   `DomainParticipantFactorySupport`, composing rather than inheriting). Fixed with a
   pre-scan pass: `_getOrCreate` is now only emitted for interfaces actually wrapped
   somewhere in the spec, matching what the original per-call-site code already did.
4. **Scalar-typedef listener parameters passed inconsistently** — the C backend's
   `isCPrimitive` correctly resolves a typedef-of-primitive (e.g. `typedef long
   InstanceHandle_t`) to pass by value; the C++ backend's trampoline generation had no
   equivalent and treated every non-interface named type as pointer-passed, producing a
   trampoline signature that didn't match the C listener struct's actual field type.
   Fixed with a matching `typeRefIsCScalar` helper in the C++ backend.

All four fixes verified via zidl's own test suite (`zig build test` + `integration-test`)
and by re-running the real `dcps_impl.cpp`/`zzdds_impl.cpp` compile after each one — not
assumed from the fix alone. In a tagged zidl release as of `v0.2.10-zig.0.16.0`, which
zzdds now pins.

**Phase 2 — `ZidlCdrAllocator` wiring (zidl repo, C backend + zidl-cdr). Done.**
Landed as a **process-wide** registration (`zidl_cdr_set_allocator()`), not per-reader as
originally sketched here — the free side (`zidl_cdr_free_str`/`_free_wstr`, and the C
backend's generated sequence-buffer frees) has no reader or other per-call context in
scope by the time a decoded field is freed, so per-reader scoping would have needed either
an ABI-breaking extra field on every generated struct or a breaking signature change to
every `_free()` call site. A single global, set once at startup, avoids both; the accepted
tradeoff is that it's one allocator for the whole process, not one per topic type or
participant. Covers `zidl_cdr_read_string`/`read_wstring` (`zidl-cdr`), the C backend's
inline sequence-buffer allocation, and — found while doing this, not originally scoped —
`@default("...")` string field handling, which used `strdup` directly. Verified with a
real (not just compiled) standalone C program: the actual generated `Sample_deserialize`
(unbounded `string` + unbounded `sequence<long>`) decoded a real CDR payload through a
custom allocator, 2 allocations/2 frees, both fields correct. Full design writeup and the
process-wide-vs-per-reader tradeoff discussion is in zidl's own roadmap now — required the
moment a user-defined topic type has an unbounded `string` or `sequence` field, i.e.
required for the C showcase app unless its sample type is deliberately kept fully bounded
(see below).

**Phase 3 — C++ wrapper-object allocation (zidl repo, C++ backend + hand-written
`zzdds_cpp.hpp`). Done.** Landed as Option E: `std::pmr`-based, process-wide, registered via
`zidl::setCppAllocator(const ZidlAllocator*)` (new `zidl_allocator_pmr.hpp` in zidl-cdr) —
same `ZidlAllocator*` ABI as Phases 0-2, bridged into a `std::pmr::memory_resource`
(`ZidlAllocatorResource`) that's bound permanently to one `ZidlAllocator*` at construction
(each `setCppAllocator` call installs a fresh instance — see the PR #28 review-round fix
below, not a single shared mutable slot). Both identified surfaces now go through
`std::allocate_shared` against `std::pmr::get_default_resource()`:
- Generated `_getOrCreate` (zidl's C++ backend) — gated on a pre-scan pass so the
  `<mutex>`/`<unordered_map>`/`zidl_allocator_pmr.hpp` includes and the allocator machinery
  are only emitted for entity classes actually wrapped somewhere, matching the identity-cache
  work's own scoping.
- `zzdds_cpp.hpp`'s `wrapFactoryHandle`/`DomainParticipantFactorySupport` — rewritten from
  `unique_ptr` + custom deleter + `FactoryHandleGuard` to `allocate_shared`, moving
  `zzdds_destroy_factory` into the destructor (required because `allocate_shared` has no hook
  for a deleter distinct from the allocator-driven one).

Per the C++ `Allocator` named requirement, OOM is signaled via `std::bad_alloc` (not a
graceful null return) — a deliberate, documented departure from every other phase's
graceful-failure contract, accepted per explicit user direction in favor of idiomatic C++;
under `-fno-exceptions` this degrades to `std::terminate()`, matching libstdc++'s own
`operator new` behavior. The registration surface (`ZidlAllocator*`, not a raw
`std::pmr::memory_resource*`) was deliberately chosen so a future graceful/no-exception
option (deferred, not built) stays cheap to retrofit later without an API break.

Verified end-to-end against a real build: rebuilt zzdds against a local zidl checkout
(temporary `build.zig.zon` path override, reverted after), confirmed `zidl_allocator.h` and
the new `zidl_allocator_pmr.hpp` both install to `zig-out/include/` (the latter gated on
`cpp-binding`), and that `dcps_impl.cpp`/`zzdds_impl.cpp` compile cleanly with real g++
(`-std=c++17`). A standalone C++ program (`zzdds::create_factory()` +
`factory->create_participant(...)`) proved: (1) with no allocator registered, construction
goes through ordinary `new`/libc, untracked; (2) after `zidl::setCppAllocator(&za)`, both
`wrapFactoryHandle`'s factory-support object and `_getOrCreate`'s participant object allocate
through the tracked allocator; (3) `wrapFactoryHandle`'s object (uncached) frees immediately
and exactly on scope exit; (4) re-registering a second `ZidlAllocator*` takes effect
immediately, with the first allocator's counters untouched; (5) `nullptr` restores the
default. Note: `_getOrCreate`'s control-block memory is *not* asserted to free promptly in
this test — the identity-cache's `weak_ptr` map never erases stale entries, so a cached
object's allocation stays outstanding (by design, independent of this phase) until the same
handle value is reused or the process exits; only the allocation side was checked for that
path.

**Post-merge review fixes (Greptile, zidl PR #28)**: three real issues surfaced across review
rounds, all fixed in zidl's `zidl_allocator_pmr.hpp` (see zidl's `docs/roadmap.md` for the
full per-round writeup): (1) the original design read the active allocator from a shared
mutable slot at both allocate- and deallocate-time, so re-registering with a different
`ZidlAllocator*` would silently redirect *outstanding* objects' frees to the new allocator —
fixed by binding each `ZidlAllocatorResource` permanently to one allocator at construction
instead; (2) `do_is_equal` used `dynamic_cast`, which requires RTTI and breaks `-fno-rtti`
builds (exactly this feature's embedded/RT audience) — fixed by using pointer identity
instead, since nothing in this codebase's actual usage depends on cross-instance equality;
(3) `ZidlAllocatorResource`'s constructor now asserts non-null, closing a latent
silent-deallocation-drop gap for anyone bypassing `setCppAllocator` to construct it directly.
All three were verified with real, CI-tracked compiles/regression tests (including
`-fno-rtti`), not just manual spot-checks.

**Bare-metal follow-up (user-driven, prompted by a Greptile "worth a second read" note)**:
`setCppAllocator`'s own bookkeeping (installing one `ZidlAllocatorResource` per registration)
used plain `new` unconditionally — the one spot in the whole allocator story not already
routed through a caller-supplied `ZidlAllocator` (factory bootstrap via
`zzdds_create_factory_with_allocator`, and `_getOrCreate`/`wrapFactoryHandle` via
`setCppAllocator` itself, both already are). Added an opt-in
`ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE` macro (defined by the consumer before including the
header) that switches this one spot to placement-new into a fixed-size static pool instead of
the heap, bounded and never wraparound-reused, asserting if exceeded. Default behavior is
unchanged unless the macro is defined. This lives entirely in zidl's header — not a zidl
backend/codegen flag, since `zidl_allocator_pmr.hpp` is hand-written and header-only, not
generated per-IDL-spec; a preprocessor macro is the natural, toolchain-agnostic switch, and no
`cpp.zig` changes were needed. Verified (permanent CI integration tests, plus a manually
confirmed pool-exhaustion assert): pool mode never calls global `operator new`/`delete`, for
both `setCppAllocator` itself and the `_getOrCreate`-style `allocate_shared` calls that follow
it — confirmed meaningfully (default mode was independently confirmed to still call global
`operator new`, so the check isn't vacuous). Net effect: a caller-supplied static-pool-backed
`ZidlAllocator` registered via both `zzdds_create_factory_with_allocator` and
`setCppAllocator` (pool mode) now makes the *entire* C++ allocation chain — not just
after-setup — avoidant of libc `malloc`/global `operator new`, which directly feeds into the
showcase apps' `LD_PRELOAD` verification shim below: a from-process-start abort-on-any-call
shim becomes viable for a fully-configured app, no "only trip after setup" leniency window
needed.

**Post-merge review fix (Greptile, zzdds PR #50)**: a real exception-safety gap in
`zzdds_cpp.hpp`'s `wrapFactoryHandle`, introduced by this same Phase 3 rewrite. The doc
comment justifying the switch from `unique_ptr` + custom deleter to `allocate_shared`
reasoned that `DomainParticipantFactorySupport`'s own constructor can't throw partway through
and leave `handle` stored nowhere — true, but incomplete: `std::allocate_shared`'s PMR
allocation itself (the control-block + object storage) can throw `std::bad_alloc` *before*
the constructor ever runs, e.g. under a bounded pool allocator (`ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE`,
or any real-world bounded allocator) that's exhausted. In that case `DomainParticipantFactorySupport`
never exists, so its destructor (the only thing that calls `zzdds_destroy_factory(handle)`)
never runs — the already-created C-ABI factory, and everything its own allocator allocated
during bootstrap, leaks silently. Confirmed concretely, not just by inspection: a standalone
program with a C-level tracking `ZidlAllocator` (for the factory itself) and a C++-level pmr
allocator rigged to always fail showed 2 bootstrap allocations and 0 frees after the expected
`std::bad_alloc` was caught. Fixed by wrapping the `allocate_shared` call in `wrapFactoryHandle`
in a `try`/`catch (...)` that calls `zzdds_destroy_factory(handle)` before rethrowing —
confirmed the same repro now shows matched alloc/free counts. Added as a permanent CI-tracked
regression (`test/bindings/smoke/cpp_allocator_smoke.cpp`, run by `zig build test-bindings
-Dcpp-binding=true`), alongside a happy-path check that factory + participant creation still
works normally. That test needed its own local `--generate-interfaces`/`--cpp-generate-impl`
codegen (real `DomainParticipantFactory`/`DomainParticipant` entities, not `binding_smoke.idl`'s
minimal CDR-only types) and, incidentally, surfaced a build-plumbing gotcha worth recording:
`--cpp-generate-impl` regenerates its own redundant copy of `dcps.hpp`/`zzdds.hpp` alongside
`dcps_impl.hpp`/`zzdds_impl.hpp`, and since `dcps_impl.hpp`'s own `#include "dcps.hpp"` is a
quoted include (same-directory search wins over `-I` order), naively adding both the
`--generate-interfaces` and `--cpp-generate-impl` output directories to the include path pulls
in two independently-generated (not guaranteed byte-identical) copies of the same C-ABI
declarations into one translation unit — a real compile error. Worked around in `build.zig` by
copying only the needed files into one merged directory (`b.addWriteFiles()`), mirroring how
the real `zig build install` step already avoids this for actual consumers (it only ever
installs one file per name into a flat `zig-out/include/`).

**Phase 4 — C++ STL-container-in-generated-types allocator injection (zidl repo, C++
backend).** The pre-existing "custom STL allocators" gap: `sequence<T>` → `std::vector<T,
Alloc>`, `string` → templated `std::basic_string`, threaded through every generated type.
This is a compile-time template-parameterization change, categorically different from
Phases 0-3 (which are all runtime vtable injection) — see "the C++ template problem"
below. Needed for the C++ showcase only if its sample type carries unbounded
fields *and* is accessed through the idiomatic typed API rather than raw CDR bytes.

**Phase 5 — Implement the missing `{Type}_free()` function bodies (zidl repo, C backend).**
Added last, as a deliberate scope extension beyond the original Phase 0-4 plan: not
strictly required by any of it, but discovered along the way (Phase 2's real-build
verification) that `void {Type}_free({Type} *v);` is declared in every generated C header
and never given a body anywhere — confirmed via golden fixtures and a real build; calling
it today is a link error. It's allocation-related (freeing exactly the heap-owned fields
Phase 2 taught the rest of the C backend to allocate correctly) and leaving it broken
undercuts the rest of this plan's credibility, so it's in scope here even though it isn't
on the critical path to either showcase. Needs a general free-function generator —
extending the existing `emitFreeArrayElements`/`emitFreeSeqElements`-style logic (currently
only reachable from the `@key`-only cleanup path in `compute_key_hash_from_cdr`) to run
over *every* field, not just `@key` ones, recursing into nested structs — that frees each
heap-owned field via the Phase 2 allocator-aware helpers (`zidl_cdr_free_str`/`_free_wstr`/
`_free`), not raw `free()`.

**Deferred, not needed for either showcase:**
- **Tier 2 fine-grained override** (separate allocator for history-cache/CDR-scratch vs.
  lifecycle bookkeeping — the original roadmap's "Tier 2/3" language). Phase 1 already
  gives everything one shared, caller-chosen allocator; wanting *two different* allocators
  for different subsystems is a real but strictly-secondary ergonomics feature for
  advanced tuning once Phase 1 ships and someone actually asks for the split. Don't build
  ahead of that.
- **Tier 3 per-entity-kind/per-topic overrides** — same reasoning, explicitly deferred
  already, unchanged by this plan.

## The C++ template problem (why Phase 4 is the risk in this plan)

Phases 0-3 are all runtime, vtable-based injection — the same pattern zzdds already uses
everywhere (`TypeSupport`, `get_c_abi_handle`, now `ZidlAllocator`): a `{ctx, fn pointers}`
struct passed once at construction. Phase 4 is not that. C++ allocator customization for
STL containers is a **type-level**, not value-level, concern —
`std::vector<T, Alloc1>` and `std::vector<T, Alloc2>` are different, non-interconvertible
types. Making generated types allocator-parameterizable means either:
- threading a template parameter through every generated struct (invasive, changes the
  public shape of every generated type, breaks source compatibility for existing C++
  consumers), or
- standardizing on `std::pmr::*` containers with a runtime `memory_resource*` (avoids the
  template-parameter explosion, but `std::pmr::string`/`std::pmr::vector<T>` are still
  distinct types from `std::string`/`std::vector<T>` — an ABI/source break for anyone
  already consuming the generated headers), or
- a narrower, lower-risk alternative worth seriously considering before committing to
  either of the above: don't make the *generated types* allocator-aware at all; instead
  give the C++ typed DataReader/DataWriter wrapper an option to hand back
  borrowed/non-owning views (spans) into caller-managed storage for the hot read/write
  path, and accept that a *type that structurally contains* an unbounded string/sequence
  is inherently a heap-owning type in idiomatic C++ regardless of which allocator backs it
  — the real fix for such a topic on a constrained target is to make the *type* bounded
  (fixed-capacity), not to make `std::vector`'s allocator swappable.

This needs a short design spike before committing to an approach — flagging it here rather
than picking one, since the three options have materially different compatibility and
effort costs and this is the one place in the plan where "have zidl auto-generate it"
might be the wrong instinct entirely.

## Definition of "zero malloc" — needs an explicit decision, not an assumption

The literal ask ("zero new/malloc use") is stronger than what real-time systems typically
require. Standard RT practice distinguishes:
- **Bounded, one-time, deterministic allocation at setup** (entity creation, factory
  bootstrap) — normal and accepted; the concern is *unbounded or data-dependent* sizing,
  not "allocation exists at all."
- **Unbounded or steady-state allocation on the hot path** (per-sample, per-write, growing
  with traffic) — the actual thing that breaks RT guarantees (jitter, priority inversion
  in the allocator, unbounded worst-case latency).

A showcase that claims "zero allocation on the read/write hot path, using a fixed pool
sized at startup, entirely caller-controlled" is both a **true-to-need** claim for the
actual embedded/RT audience *and* achievable once Phase 1 (+ Phase 2 if the sample type
needs it) lands. A showcase that claims "*zero* `malloc`/`new` calls for the entire process
lifetime, including entity/topic/writer/reader creation" is a **stronger, purer** claim,
but forces Phase 3 (and possibly Phase 4) to be done before a single entity can exist —
a materially bigger lift before anything can ship. Recommend deciding this explicitly
before scoping the showcase (see below) rather than defaulting to the strongest reading by
accident.

## The two showcase apps — proposal and pushback

The idea itself is good: a real, runnable, falsifiable demo is much more convincing than a
roadmap paragraph, and forces the plan to be actually correct rather than plausible on
paper. Concerns, as invited:

1. **Scope the sample type deliberately, and ship in two milestones, not one.**
   Milestone 1 (bounded/fixed-size fields only, e.g. numeric fields + a fixed-capacity
   `string<32>`) needs only Phase 0 + Phase 1 — it can exist almost as soon as the C-ABI
   bootstrap fix lands, and already proves the compelling part of the story (a real DDS
   pub/sub exchange over UDP, actual discovery, zero heap allocation after startup, entirely
   under a caller-supplied static-pool allocator). Milestone 2 (add an unbounded
   string/sequence field) specifically exercises Phase 2 (C) and Phase 3/4 (C++), and
   should be built once those land — not blocking Milestone 1 on the hardest, least-certain
   item in the whole plan (Phase 4).
2. **Pick and state the "zero malloc" definition (previous section) up front**, and design
   the showcase's Definition of Done around it explicitly rather than "compiles and looks
   heap-free."
3. **Prove it, don't eyeball it.** Code review isn't a strong enough guarantee that nothing
   in the dependency chain (libc, a transitively-linked library, a missed call site) falls
   through to real `malloc`/`new`. Recommend an `LD_PRELOAD` shim overriding
   `malloc`/`calloc`/`realloc`/`free`/`operator new`/`operator delete` to abort the process,
   run as the actual acceptance test (and ideally in CI) for both example apps — a
   falsifiable claim, not an assertion.

   **Arming point, resolved**: originally this needed a "only trip after setup completes"
   leniency window, since factory bootstrap and every `_getOrCreate` call allocate at
   startup (accepted under the "zero malloc" definition above) and, prior to the bare-metal
   follow-up in Phase 3 above, `setCppAllocator`'s own bookkeeping unconditionally used `new`
   regardless of configuration. With that follow-up (`ZIDL_ALLOCATOR_PMR_STATIC_POOL_SIZE`),
   a fully-configured C++ showcase app (custom `ZidlAllocator` registered via both
   `zzdds_create_factory_with_allocator` and `setCppAllocator` in pool mode) has no required
   heap touch anywhere in the chain, for its whole process lifetime — so the shim can abort
   on the very first `malloc`/`new` call from process start, no leniency window needed. The C
   showcase (Phase 0 + 1 only, no C++ pmr layer in play) was always going to be able to do
   this trivially; this closes the same gap for the C++ showcase.
4. **"Talking to one another" implies real background threads** (UDP recv, SPDP timer,
   per-matched-reader heartbeat — see the thread-model note above). That's expected and
   fine (thread stacks use `mmap`, not `malloc`), but worth stating explicitly in the
   example's own README so "several pthreads exist" isn't mistaken for a gap during review.
5. **Location**: user specified "in the zz-dev directory" (sibling to `zzdds`/`zidl`, not
   nested inside `zzdds/test/`) — proposing `zz-dev/zzdds-embedded-c-example/` and
   `zz-dev/zzdds-embedded-cpp-example/` as two small standalone repos/dirs, each with its
   own build (CMake or a minimal Makefile, not Zig — the point is showing a normal C/C++
   toolchain consuming the installed `libzzdds` artifacts per `docs/language-bindings.md`'s
   three-artifact model), open to redirection.

## Priority order (summary)

1. Phase 0 — `ZidlAllocator` shared vtable + Zig adapter (zidl) — **Done.**
2. Phase 1 — `zzdds_create_factory_with_allocator` + `zzdds_cpp.hpp` mirror (zzdds) —
   **Done**, verified end-to-end (real Zig-level allocation tracking + a real compiled,
   linked, and run C++ program). Unlocks Showcase Milestone 1. Depends on zidl's Phase 0
   (`ZidlAllocator`), now in a tagged zidl release (`v0.2.10-zig.0.16.0`, which zzdds pins) —
   ready to land in a zzdds release once this PR merges.
3. Phase 2 — `ZidlCdrAllocator` wiring (zidl) — **Done** (process-wide, not per-reader —
   see above), verified with a real compiled/run C program. Unlocks unbounded fields in C.
   In a tagged zidl release as of `v0.2.10-zig.0.16.0`.
4. Phase 3 — C++ wrapper-object (`_getOrCreate`, `zzdds_cpp.hpp`) allocator support (zidl) —
   **Done** (`std::pmr`-based, Option E), verified end-to-end (real compiled, linked, and run
   C++ program proving both `_getOrCreate` and `wrapFactoryHandle` route through
   `zidl::setCppAllocator`). Unlocks entity-wrapper construction under a caller-controlled
   allocator. In a tagged zidl release as of `v0.2.10-zig.0.16.0`.
5. Phase 4 — C++ STL-container-in-generated-types injection (zidl) — needs a design spike
   first, see "the C++ template problem"; unlocks unbounded fields in idiomatic C++
6. Phase 5 — implement the missing `{Type}_free()` bodies (zidl) — last, deliberately out
   of the original scope but allocation-related and worth closing out; not on the critical
   path to either showcase
7. Tier 2 (data-plane override) / Tier 3 (per-entity-kind override) — deferred, revisit
   only once Phase 1 ships and a real need for *separate* allocators (not just one
   configurable one) shows up.
