# Broker wire assignment and compatibility review

Specification audit, 2026-09-24. Retain current proposed assignments; no renumbering or
schema change resulted. This is not a production allocation or compatibility freeze.

## Assignment disposition

`schema/broker-control-draft.idl` remains the numeric source. The mechanical checker
`probes/check_broker_registry.py` verifies 27 opcode/name mappings against the registry
and operation table, 30 mutable types' member-ID uniqueness, and 17 discriminator
namespaces. It also checks the draft PIDs against current native PID declarations.

| Namespace | Disposition |
| --- | --- |
| Operations | 4–22 and 25–32 active; 1–3 and 23/24 reserved and unsupported |
| Vendor discovery PIDs | Native locator assignments 0x8001/0x8002 unchanged; draft origin version 0x8003 and service fields 0x8004–0x8006 distinct |
| Bootstrap endpoints | Key 7a0001, writer kind 43 and reader kind 44 retained; allocator must reserve these identities and exclude standard/native endpoints |
| Established endpoints | Dynamically allocated per owner with lifetime fencing; not a global fixed pair |
| Features | 1/2 optional supported capabilities; 3–5 reserved, not selectable in v1 |
| Profiles/channels | CACHED and CONTROL/STATE supported; OPAQUE_PEER and peer-metatraffic remain unsupported |
| Mutable member IDs | Scoped to their containing type; never renumber or reuse retired members |

Same numeric values in different discriminator namespaces are intentional. In particular,
SERVICE_BROKER_DISCOVERY=1 does not activate RESERVED_SERVICE_WLP=1: the latter belongs
to the retired forwarding service namespace, with no active v1 field interpreting it.
Vendor PIDs are interpreted in the applicable vendor/profile context, not globally by
number alone. The source's zzdds vendor identifier is 01:1b; no new OMG allocation is
claimed here. No standard BuiltinEndpointSet bit or service port is allocated by this work.
Actual allocator exclusion and other implementation-specific assignments need integration
checks; a literal source scan cannot prove runtime identity non-collision.

## Version boundaries

There are separate version domains: RTPS protocol, service descriptor, bootstrap Frame,
established broker protocol, zzdds release and generated ABI. One cannot stand in for another.

* Service descriptor/context grammar remains descriptor_version=1. Unknown versions must
  not be parsed by guessing the v1 layout. Unsupported service introductions create no
  admission state; normal discovery follows its independent rules.
* All five bootstrap opcodes (ACCEPT, ADMISSION_REJECT, PATH_CHALLENGE, PATH_RESPONSE,
  REGISTER) always use Frame version 1.0 and encoding 1, including result retries after
  admission. REGISTER/ACCEPT body selections describe the established protocol.
* Established Envelopes use exactly the selected version/encoding for that session.
  No per-message renegotiation or optimistic acceptance of a higher minor. Initial
  implementations advertise only 1.0; future versions require actually implemented support.
* Selection must agree with both immutable introductions and policy. Unsupported required
  behavior fails; it never silently downgrades. Reconnect negotiates afresh.
* An incompatible bootstrap grammar needs its own explicitly distinguishable bootstrap
  revision. Changing an established major alone cannot change the fixed bootstrap parser.

## Extension rules

The existing minor-extension rule applies to **mutable** structures, not arbitrary IDL
structures. A new optional mutable member must have safe absence semantics and a new ID;
it cannot smuggle in unnegotiated behavior. Existing IDs keep their types and meanings.
An unknown member with the on-wire must-understand bit set rejects the containing message.
Unknown optional members may be skipped semantically, but retain exact bytes wherever
hashing, duplicate comparison or immutable record forwarding requires them.

Final structures have positional layouts. Do not append fields to Frame, ReceiveLimits,
ScopeValue, ResumeCursor, OriginRecord or other final types and call that a compatible
minor addition. A future feature needing a different shape uses a separately identified
versioned type/body/member under an explicit compatibility rule, or an incompatible major.
Changing descriptor_version likewise needs a defined introduction compatibility path.

Must-understand and required presence are different checks. In this broker profile every
non-optional mutable field must occur exactly once, even if a generated decoder would
supply a zero/default value. Known optional fields occur at most once. Reject duplicate
member IDs, including unknown IDs, within each mutable object; skipping an unknown field
does not permit ambiguous duplicate representations. Validate nested objects as well as
Envelope and Frame. A sender clearing a must-understand bit cannot make a required known
field optional or bypass its semantic validation.

Known-but-reserved values are not ordinary unknown optional extensions. For example,
ACCEPT continuity_credential remains absent in v1 and cannot establish ownership; reserved
features cannot be selected. Unknown offered features may be omitted, but unknown required
features fail. Unknown operations are never acknowledged as applied state or successful
work. Use the operation table's authorized bounded error/recovery rules; do not manufacture
an established ERROR for bootstrap or reply to an unvalidated source.

Native discovery ParameterLists, service CDR1 values, broker XCDR2 mutable members and
opaque metadata tags each retain their own extension/framing rules. Their numeric tags
and must-understand mechanisms are not interchangeable. Bytes retained from native
announcements are not rewritten into the broker's little-endian encoding.

## Evidence and remaining work

The checker passes against the current checkout. This review changed documentation and
added that checker only; existing codec/golden tests were not rerun because no encoded
layout changed. The checker does not validate parser behavior, cryptography, interoperability,
all cross-message semantics or production allocator behavior.

Assignment/version policy is now reviewed at specification level. Remaining freeze gates
are the named inline/path integration evidence and schema/native-storage agreement, plus
an explicit publication decision. Next specification pass should settle bounded decoding
and retained-byte ownership so large schema ceilings do not imply megabyte stack objects.
No additional feature or broad concurrency investigation is needed for that pass.
