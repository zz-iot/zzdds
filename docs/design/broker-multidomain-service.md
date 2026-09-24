# Multi-domain broker service identities

Status: per-scope logical service participants accepted, 2026-09-18. No implementation or wire freeze.
Domain ID/tag replaces realm by accepted decision; the service identity arrangement here
preserves ordinary domain equality; it is not an exception to ordinary discovery rules.

## Choice

One configured broker address may serve many `(domain_id, domain_tag)` scopes. Two designs
can implement this without forwarding user data or translating participant domains:

| Design | Advantages | Costs |
| --- | --- | --- |
| One broker RTPS participant across all served scopes; custom endpoints explicitly permit cross-domain association | Fewest participant identities and canonical SPDP records; direct mapping to a central service | Requires a permanent exception for service associations; harder to align future domain-specific DDS Security governance; service identity and application domain identity differ |
| One logical broker RTPS participant per served scope, sharing service listeners/runtime | Client and broker service participant have identical domain identity; preserves ordinary domain eligibility and stable per-GUID SPDP; accommodates domain-specific governance more naturally | Per-active-scope GUID, SPDP sample and endpoint state; broker ingress must select the right participant; bounded creation/retirement policy required |

Use the second design. A logical participant is a protocol identity, not a required
thread, process, socket, independent store or full public DDS object. Implementation may
share runtime workers, network listeners, timers and storage while preserving identity and
per-scope accounting. Cost grows with served scopes, not one extra participant per client.

## Standard boundary

RTPS 2.5 §8.5.1 permits vendor-specific discovery protocols. Section 8.5.5.1 checks domain
ID/tag before ordinary SEDP associations. Neither section standardizes this broker service.
The recommendation keeps same-domain service associations rather than assuming the
vendor-extension permission proves arbitrary cross-domain DDS Security compatibility.
Source: https://www.omg.org/spec/DDSI-RTPS/2.5/PDF

Each broker participant has one immutable domain identity and distinct GUID prefix. It
never sends different domain IDs/tags under the same participant GUID depending on the
recipient. Its canonical SPDP describes itself; origin participant records in the broker
store retain their original GUIDs and domain identity. The broker service participant is
not inserted into the distributed application inventory merely because it serves clients.

## Shared ingress and bootstrap

1. A client sends its canonical SPDP plus directed service-request context to the configured
   address. Explicit PID_DOMAIN_ID is required for this broker profile; absent domainTag
   resolves to empty. There is no requested_realm and no port-to-domain inference.
2. A bounded service ingress parser obtains the requested standard domain identity. It
   checks framing, service kind, configured served-scope policy and path/resource limits.
   This is routing of a provisional introduction, not ordinary participant installation.
3. Plain UDP path validation uses the existing predefined introduction endpoints. Before
   advertising a service GUID, choose an existing configured scope identity; do not create
   an unbounded population of participants on unauthenticated requests. TCP/protected
   transport follows the already accepted validation sequence.
4. The broker responds using its logical participant for that exact scope. The offer binds
   the immutable client/server samples and existing introduction IDs/digests. The client
   checks the offered server domain identity as well as configured service authority,
   path binding, supported service and attempt correlation.
5. REGISTER/ACCEPT and established CONTROL/STATE endpoints belong to that same logical
   participant. Admission atomically binds authority, domain scope, both participant
   identities, introduction, session and owner generation. Established traffic cannot
   retarget the scope through an Envelope field or a different destination GUID.

Initial v1 policy: administratively configure a finite set of served scopes and
allocate their lightweight identities before accepting introductions. Do not auto-create a
scope merely because a client requests a new tag. Unknown/disallowed preadmission scope
gets bounded silence under existing response policy; local activity and finite client
startup behavior are unchanged. Dynamic scope provisioning is optional later work.

Different domains/tags may use the same UDP/TCP listen address. After bootstrap, route
using validated association plus destination endpoint identity, not GUID prefix alone or
an untrusted scope field. Introduction parsing and path-validation work have global as
well as per-scope budgets. Unknown scope must not allocate reliable endpoint/history state.
This proposal does not add an extra round trip or require applications to know the broker
participant GUID in advance.

## Isolation and lifecycle

Ordinary multicast/directed peer processing retains domain equality checks. A service
request does not enable native SEDP/WLP or user endpoint association with the broker,
even when its domain matches. Service capabilities alone do not authorize a client to
use an unsolicited broker. Authorization applies to the requested domain scope.

Cache lookup, participant ownership, inventory, downstream views, presence queries and
resume cursors are confined to the admitted scope. Same names or overlapping partitions
across scopes cannot merge their views. Identical GUID bytes in separate scopes must not
alias ingress/session tables; a client changing its immutable domain requires a new
participant lifetime. No domain-changing update exists within a registered session.

Share a broker epoch across scopes if desired; epoch alone is never a lookup or authority
key. If a logical service participant is recreated, use fresh identity/generation fencing,
retire old endpoint associations, and require fresh introduction/session establishment.
One scope's removal must not close sessions in another scope or remove independently
justified direct-discovery state. No ordinary SPDP lease refresh extends broker ownership.

Future DDS Security remains an integration gate: each logical participant must satisfy its
scope's governance and permissions, including identity/authentication endpoints and safe
bootstrap ordering. This arrangement allows domain-specific policy but does not prove
that future secure discovery can use today's plaintext service messages unchanged.
Transport credentials may be shared administratively; that does not grant cross-domain
DDS permissions or replace participant authentication.

## Specification traces and remaining work

* Domain 0/tag A and domain 0/tag B contact one address: offers have different broker
  participant GUIDs and matching tags; stores/views remain disjoint.
* Domain 0/tag A clients over UDP and TCP receive the same scope identity while live;
  transport selection does not create another discovery namespace.
* Correctly correlated offer with wrong server domain/tag is rejected before REGISTER.
* Unknown tag floods cannot create scopes, participant identities or reliable history.
* REGISTER/envelope scope mismatch cannot redirect an admitted session.
* Ordinary SPDP without service intent follows native discovery rules, not service ingress.
* Recreated scope identity cannot consume stale REGISTER or established endpoint traffic.

These are specification acceptance traces, not executable test claims. The accepted direction requires reconciling the service introduction and domain identity documents and the schema/fixtures with
standard string encoding. Public application configuration still has
only participant domain ID/tag and broker addresses; this choice affects broker internals
and administrative served-scope configuration.
