# SPDP-based broker service establishment

Status: SPDP service sequence and bounded introduction-record direction accepted,
2026-09-18. Experimental schema now contains service descriptors/context, PATH_CHALLENGE/
RESPONSE and REGISTER. Exact wire/provider integration remains unfrozen; old handshake
fixtures are historical, not active protocol support.

## Common structure

Use ordinary SPDP participant information to introduce the client and configured broker.
A vendor parameter announces zzdds service roles, compatible versions and predefined
vendor service-introduction endpoints. A directed broker-service request parameter
identifies a client attempt/nonce and the requested service; treat it as relationship
context, never an alternate canonical participant capability record. Its exact parameter
IDs, encoding and cryptographic binding are a new wire-review deliverable.

Keep standard participant capabilities stable across recipients. Advertising support
never authorizes an association. Ordinary peers select SEDP; a configured broker service
relationship selects the vendor broker EDP and suppresses ordinary SEDP association on
that relationship. A broker service participant can consistently omit ordinary SEDP
endpoints. The configured service selects its logical participant with the client's domain ID/tag;
a mismatched offer or an unsolicited broker-capable peer is not selected
merely because it sends an advertisement. Bind service identity according to configuration
and any available authentication, not source address alone.

The introduction endpoint is best effort and bounded. It does not require ordinary SEDP
to discover itself, and receiving SPDP must not allocate full reliable broker streams or
publish a registered participant into the broker's distributed view. Keep provisional
introduction state separate from the admitted store. Capability-bearing advertisements
are parsed under strict size/CPU/rate limits before state allocation.

## Plain UDP sequence

1. Client sends directed SPDP to the configured broker service address using the bound
   local transport socket. Include normal participant capabilities and the vendor service
   request; continue separately configured multicast/direct-peer discovery independently.
2. Broker recognizes a supported service request. Before return validation, either send
   a compact challenge on the vendor introduction endpoint or drop within rate/budget
   limits. Do not respond with an arbitrarily larger full broker SPDP sample. Bind the
   challenge to the observed path, attempt, request content and expiry through a reviewed
   integrity mechanism; no admitted history/state allocation yet. Reserve bounded provisional
   request storage as specified in the [path provider contract](broker-path-provider-contract.md).
3. Client echoes the compact challenge in a service-validation message on that endpoint.
   Broker validates it, then returns its SPDP service advertisement on the validated
   path. The sender may cache only minimal provisional identification before this point.
4. Client sends REGISTER on the vendor introduction endpoint: exact service/version
   selection, scope/incarnation, requested limits/view/lease and proposed local control/
   state endpoint identities. Bind it to the validated attempt and both introductions.
5. Broker validates and reserves resources, checks identity conflict policy, and returns
   ACCEPT with session/generation, selected limits and broker endpoint identities. Retain
   bounded idempotent outcome/consumed-attempt protection before publishing admission.
6. Client installs the mappings and sends its first established control request. Then
   upload full origin participant/endpoint inventory, select downstream view and obtain
   freshness evidence using the existing contracts.

Steps 2–3 validate the path, not participant identity or origin liveliness. Exact anti-
amplification limits may require silence or an explicitly bounded retry, not a normal
large SPDP response. Because the broker advertisement is not yet known, the compact
challenge uses the agreed predefined introduction endpoint ID and correlates the directed
request. Its claimed GUID alone is not trusted authority. This is a zzdds extension
bootstrap carried over RTPS, not a claim of unmodified-SPDP challenge semantics.

This simple separation costs extra messages on plain UDP compared with an optimized
combined challenge/REGISTER exchange. It avoids carrying full offers twice and permits
transport-specific validation. Combining steps later is possible only if prevalidation
size and state bounds remain explicit; do not optimize round trips by quietly allocating
unbounded pending introductions.

## TCP sequence

1. Client opens the connection to the configured service and sends directed SPDP over
   that connection using existing RTPS/TCP framing. Apply connect/incomplete-frame bounds.
2. Broker replies with its SPDP service advertisement on the same accepted connection.
   TCP return reachability eliminates the UDP cookie exchange. It does not authenticate
   the participant or authorize the scope.
3. Client sends REGISTER, broker replies ACCEPT, and synchronization follows as above.

Do not redial locators from the client advertisement to deliver broker control traffic.
An established connection is the return path for this service association. Receiving
SPDP over TCP requires adapting current SPDP plumbing; the existing UDP-oriented listener
and initial-peer support do not establish that this sequence is already implemented.

## Protected transports and future DDS Security

Complete TLS/DTLS transport protection as configured before processing protected broker
service traffic. If the provider has validated the current return path, use the TCP-like
SPDP → REGISTER → ACCEPT sequence without an additional broker cookie round trip.
For DTLS, a changed tuple needs supported path revalidation; a connection ID or the mere
existence of an association is not evidence that its new address is validated. Never
fallback to an unsecured sequence when required protection fails.

Provider authentication of access to the broker is separate from DDS Security participant
authentication. When DDS Security is implemented, preserve its required participant
validation/permissions ordering and native authentication endpoints; secure discovery
bootstrap cannot require a broker endpoint to be authenticated using information obtainable
only after admission. Exact secure-service endpoint protection is a future integration
contract. This proposal does not grant plaintext cached discovery secure-peer authority.

## What replaces the old handshake

| Old element | Proposed disposition |
| --- | --- |
| HELLO as separate broker body | Participant introduction/capability discovery moves to SPDP vendor extension; admission-specific limits and choices move to REGISTER |
| Unconditional CHALLENGE | Transport-aware return-path validation; compact plain-UDP challenge only where validation is absent |
| OPEN embedding full HELLO and CHALLENGE | Replace with REGISTER bound to introductions/attempt; no wholesale repetition of both objects |
| ACCEPT | Retain its session/resource/endpoint role, adapting correlation and selected fields |
| ADMISSION_REJECT | Retain bounded diagnostic behavior; revise eligible request kinds and digest rules |
| Fixed magic/envelope and provisional endpoint IDs | Review for necessity and layering after service types settle; no automatic removal or reuse assumed |
| Inventory/view/presence/COMMIT protocols | Preserve accepted behavior; carry them on associated vendor service endpoints |

The old exact transcript hashes cannot remain unchanged when their source messages no
longer exist. Define bounded retained introduction/selection binding without silently
hashing a reserialized projection that loses unknown fields. Admission retry guards must
bind the actual path/association and new attempt capability; the old cookie retention
model applies only to paths using such a challenge. TCP/protected paths need bounded
association-scoped attempt retirement without pretending a nonexistent cookie expires.
That adaptation is part of the revised handshake, not resolved by TCP's reliability.

## Coexistence boundary

Separate ordinary initial peer addresses from broker-service addresses. Do not add
broker-introduced remote participants to ordinary SPDP/SEDP fan-out automatically.
Directly discovered peers follow configured normal discovery policy. Broker failure must
not erase independently valid direct discoveries. A peer appearing through both paths
needs shared identity with separately tracked provenance and freshness; authority/conflict
reconciliation is the next design task, not a simple last-packet-wins merge.

Broker configuration is a preset/collection of options, not a requirement for mutually
exclusive discovery. Internal adapters may remain modular. More than one configured
service address does not imply federation or multiple simultaneous authorities: preserve
v1's single-authority rule unless explicitly redesigned.

## Next review boundary

Recommend this functional split: SPDP introduces services; optional transport-aware path
validation precedes admission; compact REGISTER/ACCEPT selects and allocates the broker
session; existing state protocols synchronize it. The accepted sequence now has draft IDL; full native ParameterList and hash fixtures
remain to be added. In parallel, specify source reconciliation so adopting this
bootstrap does not accidentally trigger ordinary SEDP fan-out or double-count endpoints.


The [service field proposal](broker-service-introduction.md) refines directed request/offer
metadata into inline QoS, keeping capability descriptors in canonical SPDP. It proposes
bounded validated introduction state and compact REGISTER correlated by introduction ID.
This is the current candidate for reviewing the sequence before schema replacement.

The accepted [multi-domain arrangement](broker-multidomain-service.md) permits one service
address to serve multiple scopes with distinct logical participant identities. Explicit
PID_DOMAIN_ID is required in client broker introductions; no realm request or port inference
selects a scope. Domain tags use standard empty-default exact comparison.
