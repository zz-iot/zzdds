# Established encoding and transaction digest disposition

Status: draft-3 schema and fixture migration validated, 2026-09-28. Core normative wire documents are reconciled. No production wire/ABI is frozen.

## Generated representation comparison

`probes/run_broker_encoding_sizes.sh` generates three temporary versions of the current
schema, changing only the measured body types to mutable/appendable/final. Nested fixed
types remain fixed and the checked-in schema is untouched. Generated serializers report
body lengths
excluding the four-byte test encapsulation:

| Representative body | Mutable | Appendable | Final |
| --- | ---: | ---: | ---: |
| VIEW_SYNC | 28 | 20 | 16 |
| ORIGIN_BEGIN | 52 | 36 | 32 |
| SNAPSHOT_END, no transaction digest | 52 | 36 | 32 |
| FRESHNESS_QUERY | 40 | 28 | 24 |
| FRESHNESS_MARKER, no exceptions | 76 | 48 | 44 |
| FRESHNESS_MARKER, one exception | 116 | 88 | 84 |
| Compact Envelope, empty features/body | 52 | 28 | 24 |

All three generated serialization probes pass. These are byte measurements, not CPU,
flash, peak-memory or full-decoder benchmarks. Mutable decode behavior is characterized
by the existing codec tests; the comparison does not certify final/appendable admission.

## Decision and compatibility cost

Draft 3 uses final positional encoding for established Envelope and operation bodies. Those peers already negotiate the exact established version/encoding;
freeze each final layout within that mapping. No opportunistic trailing fields and no
silent reinterpretation of later versions. New fields require a separately negotiated
mapping/version or an explicit bounded extension container with its own defined semantics.
Do not claim final types provide transparent minor-version field evolution.

Retain mutable bootstrap bodies for REGISTER/ACCEPT/PATH/rejection: introduction grammar
and optional negotiated offers have a separate evolution boundary. Keep its strict
required/unique member validation and unknown-required handling. The reduction in mutable
established types does not eliminate that generator/validator requirement. Native discovery
ParameterLists and opaque record metadata retain their original extensibility rules.

Appendable saves most mutable overhead but introduces another trailing-extension policy
and DHEADER without solving arbitrary semantic compatibility. With exact established
negotiation, final is the smaller/simpler initial contract. We can add an explicitly
negotiated appendable mapping later if a concrete evolution need justifies it.

Retain one outer checked Frame wrapper, including magic, for bootstrap and established
traffic. Removing it is a separate parser distinction with small relative savings; no need
to couple that change to this revision. Signal the incompatible draft clearly. Bind
scope/epoch/session/generation from the validated transport/endpoint association to every
internal descriptor before dispatch, as in draft 2.

## Transaction digest dependency audit

| Current use | Actual property | Replacement obligation |
| --- | --- | --- |
| ORIGIN_END digest | Byte-content consistency of indexed inventory assembly | Ordered STATE transaction, fixed generation/cut, exact count/bytes, unique valid records and deterministic ordering; retain exact assigned retry bytes |
| SNAPSHOT_END digest | Byte-content consistency of the staged baseline | Same assembly checks plus atomic publication of the identified view baseline |
| APPLIED.snapshot_digest | Echoed identity/checksum of acknowledged baseline | Validate current view and snapshot cut against the retained session baseline, then bound the contiguous applied frontier |
| ResumeCursor.snapshot_digest | Echoed identity/checksum of previous baseline | Resolve full previous epoch/session/owner generation/view generation/cut, verify retained configuration and history; never reconstruct missing state from a cursor |
| Inventory/snapshot hash fixtures | Detect drift in the old assembly algorithm | Archive when fields are removed; new tests exercise identity, ordering and exact assembly directly |

No inspected use makes a sender-computed transaction digest an authentication proof.
A malicious sender can compute a matching digest for its own false content. The audit also
found no content-addressed store requiring snapshot_digest as its only lookup identity.
Epoch/session/view identities and immutable baseline retention already define that boundary.
This is a source/spec audit, not a claim that hash collisions can never matter to any future
feature. Do not build a future content-addressed optimization on removed fields implicitly.

Draft 3 removes inventory/snapshot digests from END bodies, APPLIED and ResumeCursor.
Do not replace them with CRC or add a diagnostic feature bit now. This intentionally gives
up an additional check against some implementation/storage assembly errors. Ordered streams,
counts and bounds are not equivalent checksums; tests must verify exact record assembly and
baseline association. Physical storage corruption protection, if required by a deployment,
belongs to its storage/integrity layer and must not be advertised as supplied by this protocol.

## Resume identity safety

Resolve a cursor only against an existing retained baseline identified by previous broker
epoch, session, owner generation, view generation and snapshot cut. Validate original scope,
filter/policy compatibility and the actual contiguous delivery history. Unknown/retired
identity falls back to a fresh snapshot; neither a guessed cut nor a client assertion
creates a baseline. Two views at one global cut are not interchangeable. A new session's
view generation is distinct from the old cursor generation. Apply acknowledgements only
to their currently bound session/view. Removal of digests must not relax any of these rules.

## Hashes and bytes that remain

Keep client/server SPDP, path-request and REGISTER/rejection correlation hashes. Their
fixed-size correlation purpose and raw-byte binding are separate from full inventory
assembly. They remain hashes, not authentication. SHA-256 code does not disappear from a
broker build merely because transaction hashing is removed; the expected saving is repeated
snapshot/inventory byte processing and message fields, not the entire crypto footprint.

Keep original raw record bytes and unknown optional native metadata. Exact duplicate
comparison must not become a comparison of reserialized projections or just record counts.
Origin revision conflict detection is independent of transaction digests and remains intact.

## Schema/fixture acceptance

Established body types/Envelope are final; bootstrap types remain mutable. The four
transaction-digest uses are removed. Registry checks and exact-consumption tests cover
that split. Nested blobs have independent alignment origins and no encapsulation.

Negative tests cover truncation/extra final bytes, old grammar, cross-view APPLIED/resume
and missing retained baseline. Bootstrap optional/required/missing/duplicate behavior
remains characterized. Independent encoders verify positional bytes. Broader production
borrowed-storage and admission-validation gates remain unchanged.

## Draft-3 migration evidence

The checked-in schema now uses `ZZDBRK03`, final established bodies/Envelope and
mutable bootstrap bodies. The four transaction digest fields are removed; historical
hash vectors live in `archive/review-baseline/transaction-digests/`.

All 23 generated codec tests pass, including independent positional fixtures,
truncated/extra body rejection and old Frame magic/old mutable body rejection. The
synthetic standalone mutable test header needs an explicit fixture reader context;
production nested bodies have no encapsulation header. This does not add standalone
PL_CDR2 support to zidl or certify production admission validation.

The complete VIEW_SYNC Frame is now 64 bytes (draft 2: 104). A freshness marker with
no required features is 92 + 40N bytes for N exceptions. Small REGISTER/ACCEPT/PATH
fixtures remain 368/464/192 bytes; the large resume/feature fixtures are
1196/1292/192 bytes after removing the cursor digest.

`test/design-models/broker_baseline_identity.py` passes 22 bounded checks and exposes
two unsafe shortcuts (cut-only lookup and trusting a missing baseline). It covers each
identity component, scope/tag/policy mismatch, lost retention, out-of-range frontier,
and separation of resumed old identity from new-session APPLIED. Compatibility and
retained contiguous history are inputs, not implementations of filtering or replay;
this is not a complete protocol model.
