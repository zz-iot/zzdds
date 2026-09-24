# Runtime handles and resource reclamation

Status: R1/R2 ownership direction accepted, including an optional borrowed-resource
completion fence, 2026-09-15. No ABI or generated IDL is changed. Concrete scope
accounting and generated interface integration still require validation.

## Public ownership roles

Expose operational ownership separately from observation, with these semantic roles
(names are provisional until IDL integration):

| Role | Keeps runtime operational? | Storage/lifetime contract |
| --- | --- | --- |
| RuntimeOwner | Yes | Explicit creation or successful ownership acquisition supplies one operational lease; releasing it can initiate retirement |
| RuntimeRef | No | Stable identity/state observation and eligible helping; safe control-block retention, never automatic revival |
| ResourceCompletion | No | Observes a sealed resource scope's final reclamation; must not itself pin that scope's allocator or runtime backend |

Default/participant runtime getters return RuntimeRef. WaitSet configuration retains
RuntimeRef even when the application supplies an owner: it does not copy operational
ownership. Explicit factory runtime selection acquires operational ownership as part
of successful configuration; failure leaves the prior selection unchanged. Participant
creation similarly acquires its operational lease atomically before publication.

Provide explicit try-acquire-owner from RuntimeRef, with failure once retirement has
begun. Acquisition and final-owner retirement share synchronization. A fresh implicit
default is a new identity, not resurrection through an old reference. A ref to a
stopped runtime remains safe to inspect until released. ReturnCode-style acquisition
uses ALREADY_DELETED for a safely recognized retiring/stopped lifetime; a constructor
uses its declared nil/failure convention. Invalid inputs retain normal validation.

Each explicit acquisition creates an owning lease. Binding aliases of that same lease
share its release state; copying a C++ shared_ptr or Java reference does not require a
new operational count on every language reference copy. Explicit additional acquisition
creates another lease. Releasing a lease is idempotent at the binding-owned lease
object, not permission to call an already-freed raw handle. C/Zig need explicit
release operations; managed bindings provide their deterministic cleanup conventions
with safe finalization fallback. Holding an owner while waiting for automatic runtime
retirement is a self-created dependency; release it and observe via RuntimeRef instead.

## Three resource modes

1. **Library-owned default:** allocation/backend owners are retained internally;
   ordinary DDS teardown automatically releases them after work retirement.
2. **Retained custom owner:** construction accepts a versioned ownership anchor that
   keeps the allocator descriptor, allocator state and other required resources valid.
   Accepted runtime/entity/output users retain that anchor until their last use.
3. **Raw borrowed resource:** existing allocator pointer APIs remain borrowed. Their
   resources must outlive all associated reclamation, including deferred work. A new
   explicit tracked resource scope can provide a completion fence for safe local teardown.

`include/zzdds_c.h` currently documents borrowed allocator lifetime for factory,
WaitSet and GuardCondition construction. This proposal does not append fields to
ZidlAllocator, reinterpret those pointers as owned, or claim existing destroy functions
already provide an allocator fence. Migration must document/validate the existing
path and provide a versioned opt-in path before recommending stack/arena teardown
under deferred execution. Defaults must not require applications to use the extension.

Prefer a retained owner when practical. A foreign release hook or reference-counted
anchor cannot keep a stack arena alive unless the application actually supplies a
lifetime owner with that capability. No API can infer or extend arbitrary borrowed
memory lifetime. Anchor release is exactly once after its accepted users retire,
outside metadata locks, with the required binding environment.

## Tracked resource scope and fence

A resource scope accounts for every accepted user of the covered allocator/environment,
including entity storage, pending I/O, foreign hooks, returned allocations and shutdown
work. Its coverage must be explicit; a runtime-only fence is not a fence for all
factory/WaitSet allocations in the process. A user must not assume generated C output
buffers allocated from a separate allocator are covered by that scope.

Closing/sealing the scope prevents new independent resource users. Existing accepted
operations can finish required cleanup within their accounted lifetime; sealing does
not delete their DDS objects or abandon them. The ResourceCompletion becomes complete
only after all covered users and final hooks retire and no later callback can use the
resource. Returning a loan, destroying returned owned buffers, releasing operational
owners and deleting covered entities may be prerequisites; merely stopping workers
is insufficient. A copied raw pointer is not an accounted owner.

Keep completion observation metadata in separately owned storage (or caller storage
with a separately documented lifetime), so retaining the completion token cannot
prevent completion of the allocator it observes. Runtime identity/control-block
storage must likewise either be outside the resource being fenced or be included in
its remaining user count. Do not hide that choice behind the word observer.

Offer nonblocking readiness and a timed completion wait on the extension surface.
The latter uses a single deadline and permitted cleanup helping; TIMEOUT means the
resource is still in use, not permission to destroy it. Never recursively drain a
callback's own resource scope. Reject a proven self-dependency with ERROR; explicitly
integrated nonblocking loops continue servicing their registered retirement path.
A stalled foreign callback can delay completion indefinitely. This fence is optional
custom-resource management, not a mandatory runtime shutdown call for standard DDS.

Example borrowed-arena sequence: construct tracked scope and DDS objects; use them;
delete objects and release returned resources/owners; seal scope; observe/drive until
ResourceCompletion succeeds; destroy arena. The token remains independently valid.
Default library-owned resources and properly retained custom owners need no such
application wait merely to preserve memory safety.

## Boundaries and next review

Non-OMG generated RuntimeOwner/RuntimeRef/resource-scope control belongs in zzdds.idl.
Allocator bridge layout/versioning and language-specific owner adapters remain part
of coordinated zidl/zzdds integration. The semantic roles are a proposal, not newly
implemented interfaces. Existing direct native APIs must not bypass required lease
accounting when participating in the new runtime.

This resolves the conceptual R1/R2 gaps: ownership queries are explicit,
observation cannot prolong operational life, and allocator reclamation has either an
actual retained owner or an observable fence. The explicit resource scope/fence is
included in the initial extension direction for borrowed-resource users. Names/IDL,
scope admission/sealing and independently stored completion metadata remain concrete
integration work. The borrowed legacy contract must not silently acquire new guarantees.

Validation targets: ref promotion versus last-owner release; observer across stopped
runtime; WaitSet conversion of owner to observer; custom factory selection rollback;
seal versus new allocation admission; delayed output/loan/hook retirement; and a token
that cannot keep its own observed allocator alive. Use binding fixtures for real
reference transfer and a bounded model only where the scope algorithm is uncertain.
