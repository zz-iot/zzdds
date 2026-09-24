# Binding-visible prepared access failures

Status: R3 mapping direction accepted, 2026-09-15. Source audit completed; no generator,
IDL or runtime implementation changed. This refines
[synchronous output failure](synchronous-output-failure.md) and the selected
[prepared access conflict policy](prepared-read-conflicts.md).

## Audited behavior

* `zidl/packages/zidl-cdr/include/zidl_cdr.h` defines success 0, OVERFLOW -1,
  TRUNCATED -2 and INVALID -3. OVERFLOW covers fixed-buffer capacity and allocation
  failure; it is not sufficient evidence by itself for allocation failure.
* `zidl/src/backend/c.zig` single-sample helpers around 2858 and
  `cpp.zig` around 2375 return the decoder integer from DDS ReturnCode methods.
  The DDS constants in `zzdds/idl/dcps.idl:51` are a separate nonnegative domain.
* C/C++ batch helpers around `c.zig:3024` and `cpp.zig:2500` collapse raw errors
  to -1; successful return is a sample count. Typed decoding occurs after raw
  access, and C++ cleanup after conversion is not an exception-safe scope.
* `java.zig` around 3554–3650 ignores raw return codes in typed convenience
  methods before checking empty lists or decoding. Java deserialization can throw.
  Generated IDL exceptions already extend RuntimeException (`java.zig:1302`).
* `zzdds/src/dcps/reader.zig:3446` maps OutOfMemory to OUT_OF_RESOURCES and other
  internal errors to ERROR, but output construction follows sample selection.

These are inspected source paths, not reproduced failures or an audit of every
language backend. Existing integer CDR APIs remain CDR APIs; mapping belongs at the
DDS adapter boundary, not in the standalone codec.

## Common mapping

| Condition | DDS ReturnCode result | Access effect |
| --- | --- | --- |
| Successful whole-batch commit and output transfer | OK | Committed |
| Valid fresh selection is empty | NO_DATA | None by this call |
| Proven allocation failure, or configured preparation storage limit exhausted | OUT_OF_RESOURCES | None |
| Truncated/invalid received representation or unsupported decoding of that representation | ERROR, decode diagnostic | None |
| Four invalidated attempts exhausted with eligible data remaining | ERROR, conflict diagnostic | None |
| Same-reader recursive preparation in one synchronous chain | ERROR, recursion diagnostic | None |
| Recognized logical close before commit | ALREADY_DELETED | None |
| Existing argument, condition, access-period or enablement precondition fails | Existing operation-specific result | None |
| Unavoidable publication failure after commit | ERROR, or OUT_OF_RESOURCES for proven allocation failure; language exception rules below | Committed; output may be partial |

The four-attempt value is the configurable initial default, not a hard-coded ABI.
Ordinary context contention is not storage exhaustion. No wait-for-data timeout is
introduced. An unsupported optional operation/profile keeps its applicable UNSUPPORTED
result; malformed incoming bytes do not make the caller's API arguments BAD_PARAMETER.
An inconsistent successful raw result (mismatched lengths, absent required storage)
is an internal ERROR, not NO_DATA. Normalize legitimate empty selections at the core
boundary; adapters must not infer arbitrary failures from empty output.

Map CDR TRUNCATED/INVALID to ERROR. For OVERFLOW, use retained failure provenance:
allocator failure or a legitimate bounded preparation resource refusal maps to
OUT_OF_RESOURCES; invalid wire lengths/arithmetic and internal sizing mistakes map
to ERROR. Until provenance exists, ambiguous OVERFLOW maps to ERROR, never a guessed
allocation diagnosis. Migration must supply explicit categories through a private
adapter result or an additive codec facility without renumbering existing CDR codes.

## Language contracts

### Zig and raw C

Generated DDS ReturnCode operations return the table's codes. Internal Zig errors
are translated explicitly; no panic for recoverable preparation failure and no error
enum cast to a DDS integer. Prepare descriptors, SampleInfo and loan registration
before commitment. Publication uses non-failing stores to valid caller storage.
No temporary loan escapes on failure. Invalid/dangling caller pointers remain outside
this recoverable-failure guarantee.

C typed output follows the same temporary-then-transfer rule. Preserve documented
caller initialization and ownership requirements; do not overwrite owned fields and
leak them. Failure before commit leaves caller sample storage unchanged, with result
counts/loan outputs in their documented empty state. No C++ exception or Java pending
exception may unwind through the C ABI. Supported foreign hooks must communicate
failure explicitly through the private preparation protocol.

### C++

ReturnCode methods map generated preparation std::bad_alloc to OUT_OF_RESOURCES and
recognized decode errors to ERROR. RAII owns all pins, partial typed values and raw
results across every exit. Ordinary generated output types must support a proven
non-throwing final transfer, or the path must document publication failure.

Exceptions from arbitrary application code (including output assignment) propagate
as their original C++ exception after cleanup. Do not silently catch every exception
and call it malformed input. At a C ABI bridge, capture the exception, unwind native
leases safely, then rethrow only after returning to the C++ boundary. No dependency
on allocating a diagnostic is allowed to make cleanup fail. Throwing destructors or
non-returning callbacks are outside the recoverable exception contract.

A failure before commit has no read/take effect. A publication exception after commit
may leave partial caller output and must never trigger automatic re-execution. A
ReturnCode-only caller must follow this documented distinction; it cannot infer
absence of effects from every non-OK code on arbitrary-output paths.

### Java

Raw generated ReturnCode methods retain their numeric result for native DDS failures.
Java VM exceptions, including OutOfMemoryError, propagate unchanged; do not clear them
to return a misleading code, or allocate a replacement exception during OOM. JNI
must stop ordinary Java calls when an exception is pending and perform only legal
native/JNI cleanup. Caller List.clear/add failures preserve the original exception
and may leave partial list output after a committed access.

Typed convenience methods check the raw/prepared result explicitly. Genuine NO_DATA
remains null for a single sample or an empty array for a batch. Other DDS failures
throw a proposed unchecked zzdds AccessFailure carrying the DDS return code, a bounded
reason enum and effect phase (not committed or committed). Define shared public error
metadata in zzdds.idl, not dcps.idl; attach a Java cause in the binding when available.
Names/layout are integration work, not a new DDS ReturnCode or a standard DDS exception.

Recognized generated decode failures become AccessFailure(ERROR, decode, not committed).
Unrelated application exceptions and VM errors propagate unchanged. Do not classify
all RuntimeException instances as decoding errors. Fully prepare the normal returned
Sample/array before commit so returning its reference does not require allocation.
Arbitrary caller containers retain the weaker publication guarantee above. The custom
exception improves convenience API observability; standard APIs require no new setup.

## Batch helper compatibility

C/C++ count-returning convenience helpers cannot carry a precise DDS failure without
an additional convention. Recommend additive result-and-count helpers: return a DDS
ReturnCode and write a count only on success (zero on NO_DATA/error). These are typed
binding helpers, not new methods on DCPS entity interfaces. Any shared public types
or entity extensions belong in zzdds.idl.

Retain legacy helpers as compatibility adapters: nonnegative success counts, zero
for genuine empty selection, negative for failure. They remain explicitly lossy and
are deprecated for code requiring a precise reason. Do not reinterpret old negative
CDR values as positive DDS codes or positive counts. Exact negative failure values
are not the new precise API; document changes to the previous empty/error behavior
in migration notes. Avoid a thread-local last-error mechanism: reentrant preparation
and evented execution make per-invocation results more reliable.

## Variant coverage and migration gates

Apply the preparation boundary to single and batch read/take, instance and next-instance
selection, condition variants, raw copy and raw loan paths. Key-only invalid_data
samples still need correct key decoding. Revalidate condition ownership/generation,
instance/cursor eligibility, ranks, sample/view state and GROUP access dependencies
as applicable; do not copy plain FIFO selection into every variant. A successful read
can change read/view state even though it retains payloads.

get_key_value, entity creation and WaitSet conversion share cleanup/error principles
but do not have read/take effects. They require their own result-publication audit;
this document does not silently change handle-returning APIs or loan-return rules.

Before production migration is accepted, targeted generated-binding tests must inject
allocation/decode failure before commit, invalidate a prepared selection, throw from
output publication, close during preparation, and verify cleanup exactly once. Cover
C/C++ batch counts, Java NO_DATA versus ERROR, valid_data=false, both loan modes and
condition/next-instance variants. Prove the actual generated non-throwing transfer and
preserve allocator/loan lifetime. These are implementation gates, not grounds for a
new scalar prototype.

## Decision to settle

The user accepted explicit DDS/codec translation and the language rules above, including the
additive C/C++ precise batch helper and unchecked Java convenience exception. This
settles R3's read/take failure mapping direction. The broader operation-variant audit and
concrete IDL/bridge integration remain tracked separately; no claim that all binding
or concurrency review items are closed follows from this decision.
