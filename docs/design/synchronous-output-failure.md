# Synchronous output and failure contract

Status: reconciled D7/D8 baseline, 2026-09-28.

[Selection and claims](prepared-read-conflicts.md) governs read/take. Certified native
conversion must be bounded, non-reentrant and infallible after selection, including final
transfer. Foreign conversion commits READ/NOT_NEW at selection, pins payload and hides
take claims before releasing rights. Failure restores eligible claims without reverting
state effects; it can expose temporary NO_DATA to another consumer. No optimistic retry
budget or conflict-exhaustion ERROR remains. Same-reader recursion remains guarded.

[Binding failure mappings](binding-access-failures.md) defines DDS versus codec errors,
precise batch helpers and convenience binding exceptions. Arbitrary user output containers
may fail after successful conversion/consumption; document that separate effect phase,
release all loans/temporaries and never repeat an already completed take automatically.
Ordinary preselection failures have no access effect. Neither an arbitrary language nor
its default allocator proves native-path certification.

The required binding limitation is explicit: a foreign-path failure after selection may
leave undelivered samples READ and their instances NOT_NEW. NOT_READ/NEW masks (including
conditions) can skip them. Retry with ANY sample/view masks, subject to normal retention;
applications unable to accept that behavior should avoid those filters. The certified
native path is unaffected only when its full capability requirements hold.

The [archived source audit](archive/review-baseline/synchronous-output-failure.md)
records the earlier generated output/loan cleanup deficiencies and abandoned optimistic
proposal. Preserve its source findings as migration tasks, not its old access algorithm.
Actual generated allocation/exception injection remains a binding release gate.
