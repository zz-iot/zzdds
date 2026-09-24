# WaitSet result ownership across bindings

Status: temporary result ownership rule accepted and bounded model checked,
2026-09-14. Concrete bridge/anchor representation and conversion failure mapping
remain implementation contract items; acceptance does not freeze an ABI.

## Findings

The native wait (`src/dcps/waitset.zig:359`) copies Condition fat pointers into an
allocated sequence, releases its membership lock, and returns. AttachedCondition
owns an optional release context but the returned sequence has no independent
per-element lifetime ownership. Sequence-buffer ownership is not condition ownership.

The generated Zig C export (`zidl/src/backend/zig.zig`, emitCApiOp entity-sequence
handling around lines 2547 and 2729) calls the native method, then invokes each
condition's get_c_abi_handle to box it. It frees the native buffer and returns an
opaque-pointer C sequence. That conversion still dereferences native conditions
after the native wait returns. The current generated allocation for the boxed
buffer panics on failure; an OUT_OF_RESOURCES return in the core scan does not cover
that later allocation failure.

C++ WaitSetSupport (`include/zzdds_cpp.hpp:600`) retains a shared_ptr in each accepted
attachment's ReleaseCtx. The generated Condition family cache uses weak_ptr entries;
_getOrCreate reuses an existing live wrapper. A weak identity cache is not a lifetime
pin. Detach can release the attachment's strong wrapper reference before output
conversion establishes the result's strong reference.

Java's attach override (`java_runtime/zzdds_java_runtime.c:265`) similarly installs
one GlobalRef per accepted attachment. Generated entity-sequence conversion
(`zidl/src/backend/java.zig:7407`) boxes native handles, including checked narrowing
to a concrete Condition type, and adds objects to the result list. Its identity
cache uses weak global references. Attachment release and later conversion therefore
have distinct lifetime boundaries here too.

These are source-derived unsafe interleavings to cover, not reproduced failures.
Existing attachment teardown tests do not by themselves establish result safety.

## Recommended mechanism: retained result batch

Give a selected result an internal lease containing exact condition lifetimes,
attachment generations, native/C-box retention and any binding ownership anchors.
Acquire retention while the candidate is still protected by attachment/lifecycle
synchronization, before dropping locks. A later raw-pointer lookup cannot repair a
missed acquisition. A retained binding anchor must preserve the actual wrapper,
not reconstruct its identity from an adapter or multiple-inheritance base address.

Separate logical detach from physical retirement of the attachment ownership record.
Detach removes eligibility immediately. A selected batch can keep the ownership
record alive until it has transferred wrapper ownership to its output. Native pins
are still separately required: retaining a C++/Java wrapper does not necessarily
retain the native reader-owned condition during explicit deletion.

Prefer refcounting an internal ownership anchor that already holds the attachment's
shared_ptr/GlobalRef; do not run arbitrary retain/release hooks under metadata locks
or allocate a JNI GlobalRef on a protocol thread for each trigger. When a selected
batch is retired, final binding cleanup runs outside internal locks and uses the
proper JNI environment. Existing attachment release hooks remain exactly-once;
if the current public hook promises immediate release, use a separate versioned
internal anchor facility rather than silently delaying that existing callback.

The lease must span the complete binding operation:

* Native C/Zig path: protect selection and any native-to-C boxing through output
  publication. Standard raw handles remain borrowed after return; applications must
  coordinate explicit deletion with their subsequent use. Buffer _release does not
  acquire or release condition objects. A retained-result extension could later give
  raw callers explicit longer ownership, but is not necessary for standard APIs.
* C++: hold the lease until each selected wrapper has a strong shared_ptr in the
  output (or temporary output awaiting publication), then release it through RAII.
* Java: keep native and anchor retention through narrowing, boxing and list filling;
  establish strong Java output references before releasing. All JNI failure paths
  release the batch. Do not hold a thread-specific JNIEnv across migration.

A lease only inside the generated C function is insufficient for C++/Java: their
conversion continues after that function returns. Prefer an internal retained-result
entry point or explicit operation envelope used by those bindings, with guaranteed
release on success/exception. Avoid a global last-result slot or unkeyed thread-local
pin stack, both of which fail with reentrancy or concurrent WaitSets. The ordinary C
ABI and ConditionSeq layout need not change. Native C/Zig callers still need valid
object ownership when entering the operation; no mechanism makes arbitrary stale
handles callable.

Do not promise that a returned wrapper can operate on a logically deleted native
condition. Safe deleted-handle invocation requires the separate lifetime-aware handle
contract. In particular, a shared_ptr or Java reference protects wrapper storage, not
automatically the native DDS object's operational lifetime.

## Completion versus conversion failure

Keep the terminal wait observation separate from delivery of its output. Once a
nonempty observation is committed, reset, detach, timeout and close cannot turn it
into a different wait outcome. But allocation/JNI/C++ conversion can still fail:
that is output-delivery failure, not TIMEOUT, and must release all leases without
clearing condition state or replaying a wait with a new deadline.

Recommend temporary output construction where supported, with defined cleanup on
failure; generic Java List implementations can throw or reenter during clear/add,
so do not promise transactional mutation of an arbitrary application-provided List.
Keep the WaitSet waiter slot until conversion/unwind completes, so same-WaitSet
reentrancy receives PRECONDITION_NOT_MET. Exact ReturnCode versus language-exception
mapping needs to follow the binding's error conventions and remains an implementation
contract item; today's generated panic is not the desired recoverable path.

## Scope and next validation

No new listener superclass, universal entity inheritance rewrite or owning standard
C handles are required. Implementation adds bounded per-result lifetime accounting,
an explicit cross-binding release boundary and exception-safe conversion. It may
briefly delay physical reclamation, never logical detach or condition deletion.
Any application-facing generated extension belongs in zzdds.idl; internal bridge
hooks are not additions to OMG dcps.idl.

Apply the same ownership review to get_conditions, which returns the same family of
handles without waiting. Other entity sequences are follow-up audit candidates, not
implicitly included in this implementation scope.

## Bounded ownership validation

Run `python3 docs/design/waitset_result_ownership_model.py`. Raw-output mode passes
138 states/369 transitions; managed-output mode passes 178 states/509 transitions.
The total is 316 scenario-states and 878 transitions, with seven reachable outcome
witnesses. Managed mode abstracts the common C++/Java ownership requirement, not their
different conversion implementations.

The model tracks one condition, a stale candidate and up to two attachment
generations, native lifetime, wrapper ownership, native and anchor pins, conversion
stages, output ownership and irreversible reclamation. Selection acquires pins in
one protected step; detach, explicit condition deletion, WaitSet close and dropping
the application's wrapper reference can interleave with conversion. Conversion
failure unwinds the lease. All reachable states have a path to complete cleanup;
this is existential reachability, not a fairness guarantee.

Four negative controls fail as intended: omit retention at selection, retain only
the wrapper, release retention at the C boundary before managed conversion, and leak
retention on conversion failure. The first two expose a native dereference after
reclamation; the third exposes the same problem in the later managed conversion;
the fourth leaves a pin after operation completion.

The accepted direction needs no policy change. Raw post-return borrowing remains
explicit, and a managed output may retain its wrapper after native logical deletion
without acquiring permission to operate on that deleted object. The model assumes
atomic acquisition and a stable native identity/box while pinned. Concrete locking,
binding hooks, partial Java List mutation, allocation failure during pin acquisition,
multiple results and cross-binding release machinery are not validated here.
Production fixtures must check actual reference transfers, C++ pointer adjustment,
Java identity, allocator routing and reentrant cleanup.

Next return to the WaitSet request protocol: single-waiter admission, attach-true,
reset before observation, check-to-sleep registration, expiry and close. This ownership
model covers selected-result lifetime; it does not yet validate those wakeup races.
