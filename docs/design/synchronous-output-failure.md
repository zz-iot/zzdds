# Synchronous output preparation and failure

Status: prepared-access direction selected, 2026-09-15; optimistic conflict policy selected and bounded-model checked; exact binding
error mappings remain open. No implementation or new error-code ABI.
The accepted effect/result/storage boundaries remain authoritative.

## Source findings

`src/dcps/reader.zig:3457` calls takeFiltered/readRaw or loan-selection helpers before
building the raw output sequences. `buildRawOutputFromTaken` (line 3609) allocates
payload descriptors, key hashes and SampleInfo arrays afterwards. Consequently output
construction is not a single pre-reserved publication step in this path.

Generated C++ typed reader helpers (`zidl/src/backend/cpp.zig`, around lines 2370–2430)
call the raw read/take, then deserialize into the caller's sample, then return the raw
loan. Cleanup is emitted as a subsequent call rather than an exception-safe scope in
these inspected helpers. The decode return integer is returned from a DDS ReturnCode_t
method; its numeric/error mapping needs verification rather than assumed equivalence.

Generated Java typed helpers (around lines 3540–3625) invoke raw operations and then
convert payload lists into samples/arrays. These inspected helpers do not check the
raw ReturnCode before interpreting empty lists as no result. Neither their shape nor
the native void delivery callback establishes atomic typed output construction.

These are source-derived audit findings, not reproduced allocation or exception tests.
The changes belong to coordinated generated-binding/core migration, not just a wrapper
catch block. Native Zig and raw C also need pre-reserved output publication.

## Recommended prepared access operation

For generated typed read/take, prepare normal fallible work before sample-state or
removal commitment:

1. Under reader/access ownership select candidates and retain immutable payload,
   identity and applicable state versions. Selection/pinning alone does not read or
   take the sample and is not a published application loan.
2. Outside protocol locks, reserve raw result/loan bookkeeping and construct typed
   temporary values, including bounded deserialization and ordinary output storage.
   Retain candidate and binding lifetimes throughout this phase.
3. Reacquire ownership and validate selection against consumption, lifecycle,
   presentation and other state changes. Commit sample-state/removal and result/loan
   ownership together only for a still-valid selection.
4. Publish prepared output with the binding's defined non-failing transfer where
   supported. Release temporary references on every exit.

A raw read followed by a raw take is not an implementation of this contract: read
already has effects and another consumer can change the selected set. This requires
an internal prepared-access protocol used across the binding boundary. Do not hold
reader locks across Java calls or C++ allocation, or roll back a committed take by
reinserting samples after other operations have observed its removal.

Selection conflicts require revalidation/reselection or a defined conflict failure,
not stale commitment. Pinning storage is insufficient to preserve semantic validity.
Do not copy listener preparation's numeric retry budgets into read/take implicitly;
the selected contention/progress policy is in [prepared-read-conflicts.md](prepared-read-conflicts.md). Any
reservation that excludes another consumer must have explicit bounded lifetime and
reentrant-call rules before being selected as the implementation.

## Failure categories and results

| Failure point | Required behavior |
| --- | --- |
| Argument/precondition failure | Existing operation-specific DDS result; no new access effect |
| Ordinary allocation before commit | OUT_OF_RESOURCES on ReturnCode APIs; mapped failure on convenience bindings, never disguised as NO_DATA |
| Invalid representation/typed decode before commit | Defined decode/ERROR mapping, no access commitment; retain diagnostic distinction from allocation failure |
| Candidate invalidation | Revalidate/reselect under the eventual access protocol; no stale output or silent sample consumption |
| Reader close before commit | ALREADY_DELETED for a safely recognized retained lifetime; discard temporaries |
| Close after commit | Preserve the committed effect and prepared output ownership; no rollback |
| Unavoidable caller-output publication exception | Propagate/map explicit delivery failure, release all temporaries/loans, preserve committed effects; document partial output where the container permits it |

For Java arbitrary supplied List implementations, clear/add can throw or reenter.
Do not promise all-or-nothing mutation of that list. Prepare values first, keep native
leases through publication, check exceptions and stop further JNI mutation after a
pending exception. C++ cleanup must be RAII-protected even if deserialization or output
assignment throws. Raw C must receive explicit failure, not a panic from routine
boxing allocation. Convenience APIs that currently return null/empty must distinguish
NO_DATA from a failed raw call through their selected error convention.

A returned error/exception does not universally mean no effect: postcommit publication
failures must say that effects may have occurred. Do not automatically retry an entire
read/take after such failure. Distinguish this from the stronger no-effect guarantee
for failures known to occur in preparation. Exact language mapping remains an API
review item; no numeric CDR error is assumed to be a DDS ReturnCode.

## Scope and tradeoffs

Recommend prepared access for core/generated raw result construction and normal typed
conversion. This improves behavior for memory pressure and invalid payloads at the cost
of a cross-binding preparation/commit seam and conflict handling. Default transfers
can remain inline without a mandatory worker hop. Arbitrary user-container atomicity
is excluded rather than introducing a transaction over application code.

Malformed data should also be rejected at the earliest valid reception/admission
boundary under the roadmap task. A precommit decode failure must not lead to silent
sample consumption; repeated failure on the same retained sample needs a separate
explicit quarantine/drop policy if desired, not an accidental side effect of take.

Scalar-returning mutation APIs should preflight any ordinary fallible result machinery
before commit; do not force all writer operations through typed read preparation.
Entity-returning creation requires safe wrapper construction/cleanup and its own
publication audit. The table is a common classification, not proof that every API has
identical error codes or a complete solution for every creation path.

The prepared-access direction is selected. The [candidate conflict proposal](prepared-read-conflicts.md)
selects optimistic whole-batch validation with bounded retries and an explicit
same-reader recursion guard; its two-consumer bounded model passes. Exact binding error mappings remain
before closing R3; a bounded ownership model alone cannot settle observable semantics.

The [binding failure mapping proposal](binding-access-failures.md) now records the
CDR/DDS code-domain mismatch, precise batch helper migration and Java convenience
exception policy. These application-visible refinements await acceptance.
