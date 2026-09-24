# Reader variant and precondition audit

Status: source/standards review, 2026-09-15. No production changes. Prepared-access
and binding failure directions remain accepted; strict cursor advancement is accepted.

## Standards findings

DDS 1.4 §§2.2.2.5.3.8–.20 distinguishes collection ownership/capacity preconditions,
condition ownership, instance selection and loan return. Conditions must belong to
the reader; mismatches return PRECONDITION_NOT_MET. Next-sample operations select
unread samples. Invalid explicit instance handles can yield BAD_PARAMETER, whereas
next-instance cursors need not identify currently retained instances.

Plain next-instance uses strict greater-than ordering. The condition variant says
otherwise identical but explicitly uses >=. This is a textual inconsistency requiring
a documented interpretation, not a concurrency consequence.

Data and SampleInfo sequences must have matching input properties. Nonempty-capacity
borrowed input and excessive requested copy counts violate preconditions. GROUP ordered
access returns at most one sample. Read changes sample/view state; take also removes
samples. Loan return validates the originating reader and matching result pair;
valid non-loaned collections are harmless. Loaned data and metadata remain immutable.
Sample-access operations also carry the subscriber access-period preconditions.

Source: [OMG DDS 1.4](https://www.omg.org/spec/DDS/1.4/PDF), printed pages 76–83,
with the access-period cross-reference to §2.2.2.5.2.8.

## Source findings and migration requirements

* reader.zig resolveRawFilter recognizes native condition vtables but does not check
  owning reader there; unrecognized vtables return the plain filter. Resolve and
  retain condition identity before reading masks/query state. Reject an unsupported
  or invalid supplied condition explicitly, never silently remove its filter. Check
  owner membership and lifecycle again at prepared commit. A condition's WaitSet
  attachment is distinct from its ownership by a reader.
* rawReadOrTake resets output sequences before acquiring its quiescence guard.
  The raw convention chooses copy mode from payload _maximum and allocates fresh
  result storage; this is not the standard typed sequence contract. Preserve an
  explicit adapter boundary rather than blindly adding standard sequence checks to
  the private/raw allocation convention. Validate input before destructive output
  reset; reject reuse of outstanding results instead of losing their ownership.
* Current raw empty results return OK. Standard typed adapters must normalize genuine
  empty selection to NO_DATA while retaining explicit raw failure detection, as the
  accepted binding mapping requires. Convenience single read/take using ANY states
  must not be mistaken for standard read_next_sample/take_next_sample.
* vtReturnLoanRaw looks up payload descriptors, but a missing loan-table entry takes
  the copy-result freeing path. It does not establish that descriptors and SampleInfo
  form a pair from this reader. Introduce authoritative result provenance for both
  raw copy results and loans. Validate the complete pair before consuming any record
  or freeing any allocation. Unknown pointers must not be presumed owned copies.
  Standard return_loan on valid caller-owned collections remains a separate harmless
  path; raw return_loan_raw currently also releases allocated copy results.
* Selection helpers treat every negative max_samples as unlimited. The adapter must
  distinguish the supported sentinel from invalid arguments; empty selection must
  not conceal an invalid request. Exact raw extension compatibility should be stated
  during ABI migration rather than inferred from a helper's permissiveness.
* takeNextInstanceFiltered/readNextInstanceFiltered use strict cursor advancement.
  Keep the requested cursor fixed across retries. Revalidate the selected instance
  against all eligible instances under the chosen ordering, not just retained sample
  membership; insertion of a nearer eligible instance may invalidate selection.

These are inspected paths on the refreshed baseline, not reproduced security or
fault-injection tests. The raw API differs deliberately from standard typed sequences;
its differences alone are not evidence of a standards violation.

## Prepared-access composition

For each operation, prepare an explicit variant descriptor: state masks or retained
condition, exact-instance restriction or cursor, sample bound, copy/loan ownership,
and presentation/access generation. Resolve instance identity independently of sample
availability. The descriptor determines eligibility and metadata dependencies; do not
reduce every variant to plain FIFO plus a final filter.

Validate preconditions without consuming samples or changing caller-owned collections.
Perform foreign decoding outside ownership locks, then revalidate the entire selected
batch and applicable access rights before publishing read/take and loan effects.
Retain immutable returned SampleInfo independently of subsequent internal state changes.
A published loan pins storage, not continued eligibility for another consumer.

The existing GROUP access contract supplies access-period ownership. Do not create a
second epoch mechanism for prepared conversion. GROUP-disabled builds remove those
specific dependencies but retain ordinary sample/view state, condition, identity and
loan validation. No new timeout or listener exclusion policy follows from this audit.

## Cursor interpretation and finish line

Recommend retaining strict advancement for both plain and condition next-instance
operations, consistent with the existing filtered implementation and iteration intent.
This is a proposed interpretation of inconsistent wording, not a claim that >= is
absent from the published standard. Before freezing it, check OMG issue resolutions
and primary implementation documentation; record the conclusion in the API contract.
Do not change production cursor behavior during this audit.

Migration tests should cover foreign-reader/deleted conditions, query changes during
preparation, empty versus invalid explicit handles, retired next-instance cursors,
nearer-instance insertion, mismatched loans/copy results, repeated valid no-loan
return, GROUP one-sample ordering, and invalid_data metadata. They should exercise
the actual generated adapters and native core; no additional scalar model is needed.

Reader variant review is now recorded. Resolve the narrow cursor wording question,
then consolidate the extension surface and remaining implementation gates. This
review does not claim every existing variant is already correct.

## Cursor follow-up evidence

The targeted OMG issue search found DDS12-70, which clarifies that cursor handles
need not identify current instances; it does not resolve the > versus >= discrepancy.
See the [OMG DDS 1.1 issue archive](https://issues.omg.org/issues/spec/DDS/1.1?view=ALL).
No resolution of the equality question was established by this search.

[Fast DDS API documentation](https://fast-dds.docs.eprosima.com/en/2.x/fastdds/api_reference/dds_pim/subscriber/datareader.html)
repeats the >= wording, while its cursor parameter descriptions use greater-than.
It therefore does not independently settle behavior. The inspected RTI documentation
also reproduces this tension; vendor prose alone is insufficient evidence of runtime
semantics. No cross-vendor execution experiment was performed.

Recommendation remains strict advancement for zzdds, explicitly documented as its
interpretation. With an ANY-state read condition, inclusive selection can repeatedly
return the same instance when the caller feeds back its last returned handle. Strict
advancement preserves iteration and current implementation behavior; callers wanting
more samples of the same instance can select that instance explicitly. This reasoning
is a design judgment, not an OMG erratum. Acceptance of this interpretation is the
only reader-audit policy question left here; do not expand it into another scheduler
prototype or block unrelated extension-surface consolidation.

The user accepted strict advancement for both plain and condition next-instance
variants. The wording discrepancy remains documented; no production change is needed
for the inspected filtered selection paths.
