# Direct metatraffic in v1; allocated relays later

Status: accepted scope correction, 2026-09-18. Supersedes the special broker ROUTE /
ROUTE_ERROR protocol and the unaccepted per-message routing recommendation.

## V1 behavior

The broker distributes participant and endpoint discovery state. Participants exchange
native WLP and user traffic directly over reachable configured transports. Broker presence
checks determine cache validity; they never assert native writer liveliness. No broker
payload forwarding, WLP proxy or allocated transport relay is implemented by this scope.

Feed installed broker participant information into native WLP association handling,
including advertised built-in endpoint capabilities/QoS and metatraffic locators. Preserve
WLP receive dispatch, timer/assertion semantics, reliability/repair, removal and lifetime
handling independently of whether peer SPDP/SEDP discovery exchanges are enabled.
Current combined.zig passes participant discovery to WLP; wlp.zig selects metatraffic
locators, while sedp.zig shares receive dispatch. Reuse that machinery without retaining
an accidental requirement to run SEDP discovery for broker clients.

RTPS defines WLP as communication between built-in participant-message endpoints, using
the ordinary RTPS endpoint protocol. Discovery establishes their association; discovery
transport need not carry their subsequent messages.
[RTPS 2.5 §8.4.13](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

Direct user-data reachability is not proof of direct metatraffic reachability: sockets,
ports and transport support may differ. Required paths must include native replies and
repair in both directions. Diagnose unsupported/unreachable paths without manufacturing
liveliness, silently selecting a relay or making broker READY imply peer reachability.

## Initial wire scope

Remove RouteMessage and RouteError from the draft schema. Operation IDs 23/24 remain
reserved and unsupported; no renumbering of later operations. Retain former peer-channel
and service numbers as explicitly reserved constants, not capabilities. TypeLookup/Security
routing feature numbers remain reserved and unselectable. No service routing is a baseline
requirement. HELLO/ACCEPT each advertise exactly two pairs: CONTROL and STATE. The separate
fixed bootstrap pair remains. Reject an offered peer-forwarding pair in initial v1.

There are 27 active operation bodies, with two holes in the opcode registry. Unknown or
reserved operations follow the existing bounded unsupported/phase handling; they never
forward bytes. Prior proposal documents are historical, not implementation requirements.

## Future allocated transport relay

The intended abstraction is a leased allocation owned by a participant's receiving
transport resource, reachable through an origin-advertised locator. An allocation can
serve several local endpoints sharing that resource; it is not a thread/process per
reader or writer. The owner creates/refreshes/releases the allocation. Peer access and
associations have separate permission/lifetime rules and must not indefinitely keep an
abandoned owner allocation alive.

The participant adds its own relay locator through normal discovery updates. The broker
preserves those announcements rather than rewriting another participant's protected
bytes. Choose a standard locator where an ordinary transport endpoint suffices; use a
zzdds-specific locator where allocation selection/association semantics require it.
Advertised allocation identifiers select resources; do not treat public locators as secret
access credentials. Relay access identity/authorization must match deployment policy.

The relay forwards opaque traffic and need not possess end-to-end payload decryption
keys. Payload protection depends on configured participant security. Shared worker pools
and transport multiplexing are compatible with this model; many-to-many fan-out and
recipient-specific encryption need separate design. Lease/association recovery, locator
encoding, access handshake, quotas, TCP/UDP behavior and standard TURN integration are
future contracts, not hidden v1 requirements.

Preserve policy space for direct-only, direct-preferred and explicit forced-relay use.
Apply relay allocation/access policy separately to metatraffic and user traffic where
needed. Discovery and allocation control may share a service deployment, but allocation
expiry must not be confused with discovery presence or native writer liveliness.

## Required v1 validation

Exercise WLP using broker-installed participant records while native SPDP/SEDP exchanges
are disabled. Check automatic and manual-by-participant assertions, native repairs and
peer removal, transport selection, blocked metatraffic with otherwise reachable data,
and same-participant local behavior during broker outage. MANUAL_BY_TOPIC stays on its
native writer/data path. No test may pass by synthesizing assertions from broker leases.
Later relay transport tests should reuse these native protocol checks over relay locators.
