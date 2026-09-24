# Directed SPDP inline-context feasibility

Source review, 2026-09-23, against the refreshed broker_spec checkout. This is a
feasibility disposition, not integration-test evidence or a wire freeze.

## Disposition

Retain the proposed ServiceRequestContext/ServiceOfferContext inline parameters.
The existing builder already separates DATA headers/inline QoS from the borrowed
serialized payload. A bounded internal extension can therefore preserve the canonical
participant bytes and writer sequence while varying directed transmission context.
Current discovery plumbing cannot yet carry that context end to end.

RTPS DATA provides a separate inline ParameterList and serialized payload; vendor
parameters provide an extension mechanism. This supports the proposed container, not
standardized broker semantics. See [DDSI-RTPS 2.5](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF),
§9.4.5.3 and §9.6.2. No claim is made that an unmodified vendor implements this exchange.
A dedicated introduction sample would be a separately reviewed wire revision, never an
implementation-selected fallback within the same advertised profile.

## Source findings and required internal changes

| Boundary | Current source | Required behavior |
| --- | --- | --- |
| DATA construction | `src/rtps/message/builder.zig`, DataParams/addData: fixed set of inline parameters; payload referenced separately | Checked bounded vendor-parameter construction, including sentinel, padding and full-message size preflight; retain immutable canonical payload |
| Directed SPDP send | `src/rtps/writer_sm.zig`, StatelessWriter.sendToLocator/sendChangesToLocked: cache-oriented send, no per-send context/channel argument; failures logged | Explicit service transmission over selected path using retained sample/sequence and per-attempt context, with errors returned to bootstrap state |
| Direct SPDP receive | `src/discovery/spdp.zig`, onReceive/processSpdpPayload: source locator/channel discarded; only disposal inline QoS used | Preserve context, source path and effective RTPS identity before ordinary cache/deduplication |
| Metatraffic SPDP receive | `src/discovery/sedp.zig`, SPDP relay callback and `spdp.zig`, handleRelayedData: payload-only forwarding | Same received-service view and validation as direct ingress; no second path that silently loses context |
| Inline parsing | `src/rtps/message/parser.zig`, parseInlineQos: parameters beyond caller capacity silently omitted | Never treat an incomplete parameter view as complete validation; bounded full scan or explicit overflow rejection for service admission |
| Channel affinity | `src/transport/interface.zig`, ReceiveHandler and sendOnChannel: channel token/generation available; send is contiguous | Preserve live channel/path association; bounded flattening is sufficient where scatter/gather is unavailable; do not infer authentication from a channel token |

The builder's scratch writes can currently return without recording an error when space
is exhausted. A broker send must establish checked capacity before writing, or use a
builder with sticky errors; a partial message is not a successful introduction. These
changes belong to internal transport/discovery interfaces, not generated application APIs.

The iterator returns INFO_SRC/INFO_DST submessages but does not maintain effective receiver
state for its callers. Existing SPDP dispatch uses the message-header prefix. Service
ingress must apply the RTPS source/destination state and destination filtering before
identity binding. The iterator also currently reads submessage lengths as little endian
unconditionally; cross-endian acceptance needs explicit verification/correction before
claiming the proposed LE/BE receive support. Payload encapsulation byte order is separate
from inline-parameter byte order.

## Admission and lifetime requirements

* Inspect directed service context independently of native sample deduplication. The same
  sample/sequence can carry a new attempt; exact repeats retain the defined retry behavior.
* Keep context out of canonical history and multicast sends. Capabilities remain canonical
  participant metadata. Directed transmission must not mutate the shared cached sample.
* Retain original serialized sample bytes and exact context bytes/representation needed
  by the transcript hash. Decode for validation without reserializing the hashed input.
* Validate parameter bounds, required/unique fields, padding/framing, source/destination,
  scope and expected service role before effects. Unknown optional parameters remain
  compatible; unknown must-understand parameters and malformed input follow RTPS rules.
  Overflow must not hide duplicates or required parameters later in the list.
* Receive views borrow packet storage and parameter scratch. Complete synchronous use or
  copy into bounded owned storage before scheduling work; retain/fence the channel lifetime
  independently. A stale channel cannot be replaced implicitly with a new connection.
* Shared service ingress selects configured scope before ordinary participant installation.
  It does not auto-provision a scope or turn a broker introduction into ordinary SEDP peering.
* Whole-message limits include RTPS, inline context and protection overhead. Bootstrap stays
  unfragmented; oversize is a defined failure, not field stripping or transport downgrade.

## Required integration evidence

Before freezing this path, exercise:

1. Two directed attempts and an ordinary multicast send reuse identical canonical payload
   and sequence, while only the directed sends carry their respective context.
2. Lost offer and repeated/new attempts traverse both SPDP ingress paths without being
   suppressed by canonical sample deduplication or creating duplicate admissions.
3. UDP replies use the validated path; TCP replies use the correct live channel; stale
   channel generations and unrelated connections cannot inherit an introduction.
4. Little- and big-endian DATA/inline parameters, independent payload encapsulation, and
   INFO_SRC/INFO_DST transitions preserve the correct bytes and effective identity.
5. Duplicate context, truncation, invalid offsets, missing sentinel, excessive parameter
   count and unknown required parameters cause no admission or ordinary-peer side effects.
6. Exact fit/one-byte-over limits and scratch exhaustion fail deterministically without a
   partial send; asynchronous handling remains valid after receive buffers are reused.

These are pending integration tests. Existing codec/hash fixtures do not exercise these
paths. The source review finds no architectural blocker and no need for a new user decision;
it leaves a concrete implementation gate rather than a competing handshake design.
