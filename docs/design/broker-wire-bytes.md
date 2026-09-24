# Broker wire byte baseline

Status: proposed byte assignments with executable golden evidence, 2026-09-17.
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
| 4 | 8 | ASCII `ZZDBRK01` (`5a 5a 44 42 52 4b 30 31`), no terminator |
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
mutable Envelope encodings, whose operation_body octet sequence contains the selected
operation's mutable encoding. These byte blobs have no encapsulation headers. Each
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

## Digest input

Domain labels are exact ASCII bytes followed by one NUL byte:

* Inventory: `zzdds-broker/inventory/v1\0`
* Snapshot: `zzdds-broker/snapshot/v1\0`

Compute SHA-256 over label, u64 little-endian record count, then each record's u64
little-endian length followed by exact record_bytes in the specified deterministic
entity order. Include no frame/envelope, encapsulation, item index or extra padding
between these digest pieces. Padding already inside record_bytes remains included.
Count/length prefixes prevent concatenation ambiguity; the domain label distinguishes
inventory from snapshot. Authentication and transaction fencing remain separate.

Empty downstream snapshots have the count-zero digest; an origin inventory cannot be
empty. Its record count includes its participant record. Validate unique entity keys,
ordering, contiguous item indices and declared total bytes before accepting the digest.
A correct hash is not evidence that the contained discovery data is semantically valid.

## Golden fixtures and reproduction

[Independent reference](probes/broker_golden/reference.py) uses Python struct/hashlib,
not generated codecs. Default execution checks eight committed vectors; `--write`
explicitly regenerates the draft vectors. No test automatically blesses new outputs.

The [Zig fixture](probes/broker_wire_codec.zig) compares generated encodings with:

* VIEW_SYNC body, Envelope and complete Frame bytes;
* a wrapper-only three-byte body/padding vector (not a valid STATUS operation body);
* a structural OriginRecord containing opaque discovery bytes;
* empty-snapshot and one-record inventory/snapshot SHA-256 values.

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

The initial nine Zig checks passed with rebuilt local zidl; subsequent metadata/endpoint
and rejection additions bring the recorded suite to 12 checks and 13 independent vectors. Frame emission in the fixture
explicitly appends terminal padding and adjusts options: CdrWriter.writeEncapHeader
alone initializes those option bytes to zero and does not finalize the entire sample.
Production must implement and validate this finalization at the sample boundary.
The small borrowed Frame checker is fixture code, not a production admission parser.

## Remaining wire review

Metadata value grammars, feature/version rules and RTPS endpoint roles now have
[concrete proposals and fixtures](broker-wire-details.md). Complete authenticated
admission transcript/continuity rules and full presence/error/state-machine validation. The framing/digest assignments above
are now concrete reviewable proposals, not remaining unnamed placeholders. Changing a
proposal requires updating its independent vectors and reviewing compatibility before
freeze; no existing deployed broker interoperability is claimed.

Current review baseline: 20 codec tests and 49 independent vectors (2026-09-23).
Earlier counts above record chronology. See [closure ledger](broker-spec-closure.md)
for the distinction between behavioral completion and wire-freeze blockers.
