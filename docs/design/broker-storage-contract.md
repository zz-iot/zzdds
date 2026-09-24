# Broker bounded decoding and retained-byte ownership

Specification baseline, 2026-09-24. No wire or public API changes. This completes the
storage direction for the design baseline; production codec/runtime integration remains
required. Read with the resource, operation-validation and concurrency contracts.

## Representation decision

Use bounded borrowed views to inspect received bytes, then retain only the immutable
bytes and compact validated descriptors required by protocol obligations. The current
generated owning draft types are codec-test artifacts, not the production receive model.
Their inline BoundedArray mapping reserves schema maxima: Frame is at least 1 MiB and
OriginRecord at least 512 KiB, regardless of actual encoded length or negotiated limits.
Moving those types to the heap alone does not solve per-message footprint or copy costs.

Keep the IDL bounds as wire ceilings. Production descriptors contain scalars, bounded
small metadata and slices/offsets backed by explicitly owned storage. Neither stack size
nor one queue slot may scale with the schema's largest octet sequence. Platform limits
may be lower; support for the full schema maximum is not an embedded build requirement.

Prefer generic zidl support for checked borrowed decoding and bounded allocator-backed
owning mappings, preserving schema bounds, over broker-specific copies of the generated
schema. The concrete generator API is an implementation choice, not a new wire feature
or binding ABI requirement. Do not silently change existing zidl mappings for all users.
Small current generated types remain usable where their measured storage and validation
properties fit. A broker validation layer still enforces phase, scope and state semantics.

## Receive stages

1. Enforce transport frame/datagram and outstanding-input limits before allocation. TCP
   length prefixes cannot authorize arbitrary buffering; reserve bounded space before
   accumulating an incomplete message and impose its deadline. Established RTPS fragment
   reassembly has separate byte/count/deadline accounting. Bootstrap never reassembles.
2. Validate RTPS framing and effective source/destination/path context. Locate a complete
   serialized sample under existing input ownership; broker Frame preflight checks its
   exact length, encapsulation, padding, version, opcode and encoding without decoding
   a maximum-sized owning Frame.
3. Decode through bounded sub-readers: Frame body, mutable Envelope, operation body and
   record bytes each respect their declared extent and alignment origin. Typed nested
   fields retain their specified containing-stream alignment. Checked subtraction and
   conversion precede slicing, allocation and multiplication by element sizes.
4. Validate presence, uniqueness, unknown-required members, all nested bounds, discriminators
   and exact consumption. Bound both memory and work: maximum encoded input plus finite
   nesting/element/member counts must bound parsing. Unknown optional members are skipped
   without allocating their declared lengths, while their raw bytes remain available where
   required. A fixed member table overflowing is a failure, not permission to stop checking.
5. Apply the operation table's scope/session/generation/feature and semantic checks. Reserve
   descriptors, retained bytes, indexing and mandatory outcome/cleanup capacity before
   accepting effects. Parsing success alone does not install a participant or acknowledge
   application completion. Recheck ownership at the ordered commit point.
6. If work must outlive the receive call, acquire durable ownership or copy the required
   immutable range into a reserved buffer before enqueueing. Allocation/validation failure
   releases provisional reservations and follows the specified bounded failure/recovery
   path. No partially installed record or borrowed stack view escapes.

A complete protected/reassembled sample may require a contiguous provider buffer. This
contract permits that bounded allocation; it does not require zero-copy across encryption,
fragmentation or network APIs. It forbids uncontrolled duplication through nested codecs.

## Ownership and retention

| Data | Retention rule |
| --- | --- |
| Receive view | Valid only while its input buffer and parameter scratch are owned; contains no promise of transport-buffer lifetime |
| Pending UDP challenge | Retain the client introduction evidence required by the path-provider contract before challenge issue; a digest alone cannot recover it |
| Validated introduction/REGISTER result | Retain immutable samples/context or allowed descriptors plus exact evidence, and exact retry-comparison material through their separate deadlines |
| Origin/view record | Retain exact record_bytes and the native payload/metadata ranges within them; never hash a regenerated projection |
| Installed discovery indexes | Compact validated descriptors referencing immutable backing or independent bounded copies; unknown optional source content stays available when forwarding requires it |
| Queued/reliable output | Own referenced bytes until encoding/send completion and applicable reliability/retry obligations finish; a local send completion is not application COMMIT/APPLIED |
| Callback/status delivery | Follow the existing listener/output ownership contract; do not expose internal receive views as new public loans |

A retained buffer owner is distinct from a participant/session's authority token. Holding
bytes alive cannot keep a retired registration authorized. Every queued effect carries the
session/generation fence; retirement removes authority first and frees storage only after
its last reference and protocol obligation end. Reference handling must work in both
manual and hosted runtimes and must not invoke application callbacks from reclamation.

Pinning a receive buffer is allowed only if the transport explicitly supports it and its
pool occupancy is charged. Charge the full backing allocation, not merely the retained
slice length; otherwise a tiny retained field could pin a large frame outside the budget.
Prefer a compact copy for long-lived small records when pinning would exhaust ingress.
If one frame backs several records, charge that backing once and separately charge each
index/reference. Releasing one slice cannot release storage still used by another.

A send builder may borrow payload slices synchronously; asynchronous transport use needs
an owner lasting through completion. Shared bytes may be referenced by installed state,
retry history and output simultaneously. Logical obligations each count against their
own limits even when physical byte storage is shared. Sharing is an optimization, not
an excuse to omit worst-case capacity planning or required independent lifetime fencing.

## Resource accounting and progress

Wire ReceiveLimits count serialized protocol quantities; local capacity counts actual
backing allocations, allocator/pool overhead, descriptors, indexes, queues, fragment state
and control/retirement reserves. Advertising a frame maximum does not promise that every
maximum can be received concurrently. Derive limits from a feasible plan and enforce both
per-item and aggregate budgets; peer proposals can only reduce local allowances.

The implementation must account for overlap: installed view plus staged replacement,
retained retry results plus in-flight output, pending/consumed cookies, and decoding scratch
plus durable copies during promotion. Reserve the overlap before copying or publishing.
A copy-and-release optimization temporarily costs both buffers. Credits transfer explicitly
between owners and are released once; accounting cannot disappear merely because a
reference crosses a runtime queue or protocol phase.

Preserve bounded control/retirement capacity when record budgets are full. Reliable RTPS
receipt must not become ACK-and-forget of an application-required record: if durable
retention fails after transport delivery, take the defined explicit rejection or session/
view recovery path. Do not advance COMMIT/APPLIED/readiness past missing state. Old valid
installed state remains intact until its replacement commits or its own validity ends.
These rules require no new resource-plan getter, six-knob API or per-message allocation
callback; those proposals remain deferred.

## Generator and integration acceptance gates

The generic codec work must demonstrate bounded slice decoding, exact sub-reader limits,
required/duplicate tracking, nested unknown-field handling, allocation-failure cleanup and
no hidden maximum-sized temporaries or by-value copies. Any borrowed result must state
its input lifetime. An owning mapping must enforce the IDL ceiling and allocation budget
before allocating actual lengths, with safe cleanup of partially decoded collections.

Acceptance cases include tiny messages under large schema ceilings; nested length overflow;
unknown optional/required and duplicate members; receive-buffer reuse after queueing;
shared backing released in different orders; failure at every promotion reservation;
full record queues with control progress; staged-view overlap; session retirement during
send; and byte-for-byte digest/retry preservation across LE/BE native discovery payloads.
Measure peak native memory and allocations for representative and limit cases, including
manual-runtime builds. Generated byte compatibility must continue to pass the independent
vectors. These are required implementation checks, not tests claimed by this document.

Source evidence: the current generated artifact maps BodyBytes and DiscoveryBytes to
inline BoundedArray; the existing codec probe explicitly checks their large owning sizes
and includes only a fixture-level borrowed Frame checker. This pass inspected that evidence
and established the contract; it did not implement a production borrowed decoder.

With this direction fixed, no further storage-layout decision is needed to review the
specification baseline. Wire publication still requires the named codec/provider/transport
integration evidence. Concrete zidl API design and measurements belong to implementation.
