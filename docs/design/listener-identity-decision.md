# Listener identity: proposed default and remaining lifetime decision

Status: identity-domain scope, binding defaults and creation-time nesting composition
accepted, 2026-09-15. Refines L1 in [listener-execution.md]. This status supersedes
historical proposed/awaiting-acceptance wording below; concrete ABI representation
and binding validation remain implementation work.
This is a bounded specification investigation, not another scheduler prototype.

## Evidence after updating main

Inspected zzdds main `c86934e` and zidl main `a069f4a`, with the local broker-spec
commits rebased above zzdds main. `ListenerBox` retains an installed callback struct
across dispatch/replacement; it neither serializes execution nor identifies aliases
across registrations. In zidl's Java `emitListenerParamPrep`, every registration
allocates a new native context holding a global reference to the listener object.
Consequently, native context address equality cannot recognize repeated installation
of the same Java object. C/C++/Zig application-owned callback context lifetime is not
extended merely by retaining the native box.

## Recommended identity scope

Use one reclaimable identity domain shared by the runtimes/factories participating
in a loaded zzdds library instance. Registering the same identifiable application
listener in two runtimes should not silently permit overlapping automatic callbacks.
This preserves the agreed shared-listener default without requiring an extension
call or forcing a particular worker assignment.

Do not claim coordination between separately loaded independent copies of zzdds,
separate processes or distinct foreign runtimes without an explicit shared domain.
The exact ABI/loader boundary needs documentation. An identity domain is a bounded
registry and dispatch-exclusion service, not a global executor or lock held across
application callbacks. Identity creation/lookup can occur at registration; callback
entry uses the retained identity record rather than rediscovering object identity.

Alternative: per-runtime identity is cheaper to isolate but narrows the agreed
shared-object guarantee. It would require applications sharing a listener across
runtimes to provide additional coordination. The recommendation above favors the
standard-only default; this scope choice remains proposed.

## Binding keys and conservative defaults

| Binding | Recommended identity input | Remaining verification |
| --- | --- | --- |
| C/Zig callback struct | Non-null application context address within the identity domain, independent of callback method table | Lifetime/address reuse rules; generated adapters that wrap rather than directly expose application context |
| Null-context C/Zig callback struct | Registration identity, plus the existing per-entity exclusion | Function addresses do not reveal shared global state; explicit grouping is needed to express otherwise unidentifiable sharing |
| C++ listener object | Canonical application-object identity supplied by the generated adapter, shared across base/extended views | Audit actual adapter representation and multiple-inheritance adjustment before choosing the token machinery |
| Java listener object | Canonical Java object identity within its VM, retained separately from per-registration native wrappers | Registry canonicalization and reference release; never use wrapper address or an identity hash alone as proof of equality |

Using one non-null C context for several callback tables conservatively serializes
them. That is a reasonable default for shared state even when the tables differ.
The library cannot infer aliasing through global variables or unrelated pointers.
Distinct reader listeners remain independent unless they share such an identity or
an explicit group. No subscriber-wide group is introduced by this proposal.

Canonical binding metadata should be generated/internal, with an explicit ABI
compatibility plan if callback-struct layout changes. It does not require an OMG
`get_listener_identity` operation. New application grouping/quiescence controls,
if selected, belong in `zzdds.idl`; do not modify `dcps.idl` to carry zzdds policy.

## Identity retirement is separate from registration retirement

The identity record survives all registrations, active invocations, explicit
callback-chain tokens and pending dispatch references that still use it. Replacing
one registration does not retire the shared identity while another uses it.
Reinstalling the same live listener during an old callback must find the existing
identity and exclusion state, not create a second gate that permits overlap.

A record may leave the registry only after those edges retire under the registry's
synchronization. New allocation at the same address then obtains a new generation.
Generation numbers do not repair application destruction/reuse while old callbacks
still access that memory; the listener-lifetime contract must prevent that misuse.
Default registries must not accumulate immortal entries. Exhausted configured
capacity must fail registration explicitly without discarding the old installation;
exact DDS error mapping still needs the API audit.

For shared identities across runtimes, pending dispatch retains a destination
runtime and a bounded wake/publication obligation. Releasing exclusion can signal
that destination; it must not recursively drive another runtime while retaining
listener rights or call application code under the identity registry lock. This
is a required interface to the runtime contract, not transport implementation work.

## Relationship to accepted replacement/quiescence

The [quiescence contract](listener-quiescence-decision.md) has resolved the setter
policy: external calls drain a captured retired frontier; any callback-chain call
publishes without waiting. That choice supersedes the earlier uniform nonblocking
proposal. Identity scope and binding defaults above still await acceptance.

The remaining L1 decision is therefore where shared identity exclusion applies and
how bindings supply its keys, not whether to reopen setter quiescence. Cross-runtime
identity, dependency tracking and callback-context detection must use compatible
scope. Entity deletion remains a separate unresolved L4 contract.

## Focused acceptance cases

Before implementation approval, cover shared object across two readers/runtimes,
null-context registrations, Java object registered through different wrappers,
C++ base/extended views, replacement while the old callback is active, reinstallation
before retirement, and address reuse after final retirement. These are required
fixtures, not newly executed test claims. A small binding fixture is warranted if
source inspection cannot establish canonical identity; a new full runtime prototype
is not needed to discuss the scope/lifetime policies.

## Concrete v1 decision package

Status: recommended for acceptance; this section does not infer acceptance from
permission to investigate. The following choices close the observable L1 scope and
binding defaults while leaving representation/ABI implementation work explicit.

Review checkpoint, 2026-09-15: after consolidating L5, the recommendations below
remain the proposed final L1/nesting refinements. No new prototype is needed to
choose them. A loaded core instance means the concrete core identity-registry
instance shared by its bindings, not merely a library filename or an OS process;
independently instantiated/static-linked registries are separate domains. Internal
keys must include their identity kind/namespace (native context, C++ complete object,
or Java VM/object token) to prevent accidental numeric collisions. Cross-binding
aliases require deliberate canonicalization; pointer equality across unrelated
namespaces does not establish shared object identity.

The scope has a deliberate cost: sharing a listener across participants/runtimes
couples their callback admission, so a slow callback can delay another registration
of that object. Unrelated listener identities retain independent execution. Registry
metadata synchronization is short-lived; scope does not introduce a global callback
lock or authorize a waiter to drive an otherwise unpermitted runtime. A dependency
can be tracked across runtimes without granting execution permission there.

1. **One default identity domain per loaded core library instance.** All its factories,
   runtimes and participants use that domain automatically. Separate loaded core
   copies are separate domains; do not claim universal process-wide exclusion.
   Cross-copy domain federation is deferred. An optional configuration must not
   silently weaken standard-only shared-listener exclusion.
2. **Object identity, not callback implementation identity.** Raw C/Zig registrations
   with the same non-null application context share an identity independently of
   their callback tables. Null contexts get per-registration identities and per-entity
   exclusion, not an implicit global gate. C++ adapters supply complete application
   object identity across supported interface views. Java adapters canonicalize the
   actual Java object within its VM; separate wrapper allocations and identity-hash
   collisions cannot split or merge listener identities incorrectly.
3. **Dispatch context and identity key are separate.** Preserve the exact pointer
   required by each callback trampoline even when its canonical exclusion identity
   differs. Never replace an adjusted C++ base pointer with a complete-object pointer
   and pass it to a trampoline expecting the original base. Metadata identifying
   the binding/key namespace prevents accidental collisions between VM/object tokens
   and unrelated native addresses. Cross-language aliasing requires explicit adapter
   metadata expressing the common object; arbitrary foreign wrappers are not inferred.
4. **Retained identity on the hot path.** Canonicalize at registration and retain
   the record through dispatch/admission. Callback entry does not perform a Java
   object search, C++ identity discovery or fresh registry allocation. Registry
   synchronization protects lookup/retirement; it never spans application callbacks.
   One-thread builds may specialize synchronization only under the existing complete
   execution-exclusivity requirement. The default scope does not mandate a shared
   worker pool or participant-wide callback serialization.
5. **One chain across supported runtime/binding crossings.** Explicit synchronous
   delegation carries chain identity, inherited rights, active recursion frames and
   depth into the destination runtime. Identity-domain dependency tracking and
   callback-context setter detection use that same scope. A posted asynchronous task
   or application-spawned thread does not inherit rights by causal association.
   Cross-runtime admission retains a destination wake obligation; it cannot assume
   that another worker exists, nor recursively invoke arbitrary callbacks there.
6. **Bounded lifetime and failure.** Identity records retire only after registrations,
   claims and pending internal users release them. Generation reuse cannot substitute
   for lifetime protection. Registration capacity failure preserves the installed
   registration; precise setter error mapping remains an L4/API task. Internal stale
   records surviving external quiescence must contain no borrowed application access.

### Binding evidence refined

`zidl/src/backend/cpp.zig` emits `ListenerBase::c_listener()` beginning with `this`
(line 5251 in the inspected checkout); parameter conversion obtains that bridge via
an adapter dynamic cast (around line 4484). That pointer is appropriate dispatch
context, but by itself does not prove equal addresses for all application-object
views. Generated canonical metadata is required before promising cross-view identity.
The precise RTTI-based or adapter-token mechanism is an implementation choice with
multiple-inheritance/extended-interface fixtures as a release gate.

`zidl/src/backend/java.zig::emitListenerParamPrep` (around line 5783) creates a new
native context and global reference for each parameter registration. This confirms
that default raw-context equality cannot implement the Java guarantee. The core must
receive a canonical token from the binding or use equivalent explicit binding support.
No layout change to generated callback structs is made by this specification edit;
its versioning and rollout require a concrete ABI plan before implementation.

### Participant nesting configuration recommendation

Fix each participant's positive finite nesting limit at creation. Standard-only
creation uses the build-time default (initially eight). Explicit configuration belongs
in `zzdds.idl` or its generated participant configuration surface. Distinguish a
build's configurable default from its supported maximum capacity; validate the value
before publishing the participant. Zero is invalid, rather than a hidden unlimited
or delegation-disabled mode. Exact configuration failure mapping follows its API.

For each proposed nested call, count total active `notify_datareaders` frames plus
one, and compare against the smallest participant limit represented in the active
callback/delegation chain, including the destination participant. Include the root
callback's participant even if it has no active `notify_datareaders` frame yet.
Ordinary external entry has no root callback and initially uses the destination's
limit. On unwind, remove the departing frames' restrictions. Sibling child callbacks
within one traversal do not consume additional delegation depth.

Examples: A with limit two may delegate into B with limit eight at depth two, but
cannot proceed to depth three while A remains active. Entering B with limit one at
depth two fails immediately. Returning from B restores the enclosing participants'
limits. A root callback with limit one can make the ordinary first delegation call,
but its child cannot start another. Cross-runtime calls do not reset the count.

This is a resource contract for library-tracked nesting; it does not bound arbitrary
application recursion, callback stack frames or the total dependency graph. Fixing
configuration at creation avoids retroactively invalidating active calls and gives
storage sizing a stable bound. Live mutation can be a later extension if justified.

## Selected binding architecture refinement

The discussion accepted separating dispatch context, canonical identity and ownership
as the binding direction. This does not select a callback-struct layout or freeze a
new ABI, and it does not by itself accept every scope/configuration proposal above.

Preserve the current dispatch context exactly as required by each generated trampoline.
Supply canonical identity independently at registration, retain the resolved exclusion
record for callbacks, and track binding-resource ownership separately. An identity
record is not ownership of a borrowed application object.

For C++, registration-time `dynamic_cast<void*>(this)` is the preferred candidate
for obtaining complete-object identity while retaining the adjusted ListenerBase
pointer for dispatch. It needs no new application override or common virtual base.
Constructor/destructor registration and multiple-inheritance/interface-view tests
must be addressed before selecting the implementation. Separate forwarding objects
remain distinct unless an adapter explicitly supplies common identity or the
application groups them. This is not an entity-wrapper identity mechanism.

For Java, prefer binding-owned canonicalization of actual object identity over a
mandatory application superclass containing a native handle. Registration-time lookup
and reference bookkeeping keep this work off the callback path. Raw C/Zig retain
application-context identity defaults. Canonical tokens must have an explicit namespace
and lifetime; they cannot alias unrelated native or VM objects accidentally.

A separate identity field, versioned registration descriptor or identity-query hook
remain ABI alternatives. Appending a field to existing generated callback structs
is not automatically binary-compatible. Resolve layout/version negotiation and
failure ownership in an implementation plan rather than changing OMG interfaces.
New application controls remain in `zzdds.idl`; generated internal metadata does not
require an application identity accessor.

Entity identity continues to derive from the native entity lifetime, including its
existing shared C-ABI box/interface-view machinery. Listener identity derives from
the application object through the binding. Unifying their dispatch representations
is not a prerequisite for implementing either identity contract.
