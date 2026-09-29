# Broker wire byte baseline

Status: incompatible draft revision 3, 2026-09-28; generated/independent byte evidence.
Not a production wire freeze. Read alongside broker-wire-contract.md and the draft
registry. Numeric broker assignments below are private proposal values, not OMG allocations.

## Fixed sample wrapper

The outermost serialized object is final Frame. Use little-endian PLAIN_CDR2 with
encapsulation identifier bytes `00 07`. XTypes associates the encapsulation with the
outermost object's extensibility, not types stored within its fields; mutable standalone
types use a different identifier. This is why the broker Frame can carry mutable body
bytes without being a top-level mutable object.
[OMG DDS-XTypes 1.3, section 7.6.3.1.2 / table 60](https://www.omg.org/spec/DDS-XTypes/1.3/PDF).

Proposed major/minor baseline is 1.0; bootstrap framing remains invariant while
negotiating the supported application protocol version. All multibyte Frame fields
except the encapsulation identifier are little-endian.

| Offset from serialized sample start | Bytes | Meaning |
| --- | --- | --- |
| 0 | 2 | `00 07`, outer final XCDR2 little-endian encapsulation |
| 2 | 1 | Zero, reserved encapsulation options |
| 3 | 1 | Terminal padding count p (0–3); other bits zero in this profile |
| 4 | 8 | ASCII `ZZDBRK03` (`5a 5a 44 42 52 4b 30 33`), no terminator |
| 12 | 2 | Protocol major |
| 14 | 2 | Selected protocol minor; bootstrap request uses baseline grammar |
| 16 | 2 | Operation registry code |
| 18 | 2 | Body encoding 1: the broker baseline XCDR2 LE body mapping |
| 20 | 4 | Body byte count n, excluding terminal padding |
| 24 | n | Body bytes |
| 24+n | p | Zero padding to a 4-byte boundary, p = (-n) mod 4 |

The encapsulation padding count follows XTypes' payload-end convention. The broker
profile requires zero reserved bits and zero emitted padding. Validate total size as
24+n+p with checked/bounded arithmetic. Reject truncation, trailing bytes, impossible
lengths, unsupported encoding/version and mismatched padding. Operation/phase validation
is additional to Frame validation. Limits include all wrapper bytes; RTPS headers and
transport/security overhead are separately accounted for by channel budgets.

TCP's existing big-endian transport length prefixes the complete RTPS transport message,
not this Frame alone. UDP carries its usual RTPS message. DATA_FRAG fragments the complete
serialized sample for established traffic only; reassemble under bounded accounting
before interpreting its body. Bootstrap Frames and SPDP service introductions remain
unfragmented under the lifecycle contract; this paragraph does not permit preadmission
reassembly.
No second stream delimiter or ad hoc checksum is introduced.

## Body origins and exact bytes

ACCEPT, ADMISSION_REJECT, PATH_CHALLENGE, PATH_RESPONSE and REGISTER bodies are
their direct mutable type encodings (PATH_RESPONSE echoes PathChallenge). Other active
operations carry
final positional Envelope encodings, whose operation_body octet sequence contains the selected
operation's final positional encoding. These byte blobs have no encapsulation headers. Each
independently serialized blob starts its alignment origin at its own byte zero; it is
not aligned according to where its octets happen to land in the containing sequence.
Ordinary nested typed struct fields follow XCDR2 alignment within their containing stream.

Body encoding 1 selects this mapping; it is not an RTPS encapsulation ID. Immutable
record_bytes likewise contain the baseline final OriginRecord encoding without an
encapsulation header. change_metadata contains the final MetadataList encoding without
an encapsulation header. Original discovery_payload includes its original encapsulation
and is preserved unchanged, including its source byte order and parameter padding.

Assign draft discovery_encoding 1 to retained RTPS PL_CDR little-endian payload and 2
to its big-endian counterpart. Verify the declared encoding against retained bytes;
unknown negotiated future encodings must not be parsed as this baseline. Internal
canonical record alignment padding is zero. Absent native-sequence state uses zero
sequence and writer GUID, distinct from a fabricated native publication.

## Transaction assembly without digests

Draft 3 carries no inventory/snapshot digest in END, APPLIED or ResumeCursor.
Validate exact indexed record membership, unique entity keys, deterministic order,
count and declared byte total; END follows its records on ordered STATE. Preserve exact
record bytes for duplicate/conflict checks. Empty downstream snapshots are valid; an
origin inventory includes exactly one participant record and cannot be empty.

APPLIED resolves the current session/view baseline and snapshot cut, with a contiguous
frontier no greater than sent history. Resume resolves the full retained previous
epoch/session/owner generation/view generation/cut and checks scope, policy and history.
Missing state requires snapshot fallback, never reconstruction from a cursor. These
checks do not provide a checksum against storage/assembly corruption. See the
[encoding and digest disposition](broker-encoding-and-digests.md).

SPDP, path and REGISTER/rejection correlation hashes remain unchanged in purpose;
none authenticates an insecure sender. Historical transaction hash vectors are archived
under `archive/review-baseline/transaction-digests/` and are not draft-3 wire requirements.

## Golden fixtures and reproduction

[Independent reference](probes/broker_golden/reference.py) uses Python struct/hashlib,
not generated codecs. Default execution checks ten committed vectors; `--write`
explicitly regenerates the draft vectors. No test automatically blesses new outputs.

The [Zig fixture](probes/broker_wire_codec.zig) compares generated encodings with:

* VIEW_SYNC body, Envelope and complete Frame bytes;
* a wrapper-only three-byte body/padding vector (not a valid STATUS operation body);
* a structural OriginRecord containing opaque discovery bytes;
* positional END, APPLIED and ResumeCursor bodies, including exact extent checks.

The OriginRecord fixture is not a semantically complete SPDP announcement. It tests
record layout and byte preservation, not discovery admission. Earlier mutable-codec
unit checks use a synthetic decoder header as a test harness; those headers are not
nested encapsulations on the broker wire. The complete Frame vector is the actual
proposed layering.

Run from zzdds:

```sh
python3 docs/design/probes/broker_golden/reference.py
ZIDL_EXE=/path/to/zidl ZIG_EXE=/path/to/zig \
  bash docs/design/probes/run_broker_wire_codec.sh
```

The generated suite passes 23 checks. Six independent Python scripts check 53 vectors.
Frame emission explicitly appends terminal padding and adjusts options:
CdrWriter.writeEncapHeader alone does not finalize the sample. Production must implement
and validate this boundary. The borrowed Frame checker is fixture code, not a production
admission parser. Synthetic standalone mutable fixtures explicitly initialize a reader
context because the runtime encapsulation dispatcher does not accept that identifier;
this workaround is confined to tests of nested bodies.

## Remaining wire review

The draft assignments are concrete proposals, not a deployed protocol. Semantic
admission, bounded storage and network/state-machine validation remain implementation
gates. Future secure admission depends on DDS Security; insecure v1 does not claim
protected transcripts. See the [review ledger](review-decisions.md) for current scope.

## Draft revision 3 migration

The magic change rejects draft 1/2 before body decoding. Selected protocol remains
provisional 1.0 and encoding 1; do not accept old layouts under the new magic.
Bootstrap bodies remain mutable. Established Envelope and bodies are final positional
layouts: no DHEADER/member headers, unknown-field skipping or trailing extensions.
A layout change requires a separately negotiated mapping/version. Bootstrap mutable
required-member/duplicate checks and native metadata extensibility remain necessary.

Envelope contains request ID, required features and operation body, in schema order.
Resolve scope/epoch/session/owner generation from a validated endpoint/channel association
and retain them in queued descriptors. Stale endpoints cannot establish a new association;
never fall back to GUID alone. Requests without a logical ID use the specified zero value.

VIEW_SYNC is 64 complete Frame bytes, compared with draft 2's 104. Freshness query
body is 24 bytes; marker body is 44 + 40*N. With empty required features, Envelope and
Frame make marker total 92 + 40*N. Derive N from the smaller negotiated marker/frame
byte cap, not only the schema's exception count ceiling. Small REGISTER/ACCEPT/PATH
fixtures are 368/464/192 bytes; large resume/feature fixtures are 1196/1292/192.
