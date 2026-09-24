# Standard domain identity replaces broker realm

Status: accepted direction, 2026-09-18. This decision supersedes broker-only realm in
all earlier design prose and experimental schemas. The joint experimental wire-fixture migration is complete; native domain-tag
implementation remains required work, not completed support.

## Standard basis

OMG DDSI-RTPS 2.5 defines domainTag in SPDPdiscoveredParticipantData (Table 8.78).
Section 8.5.5.1 checks both domainId and domainTag before configuring ordinary SEDP
associations. Table 9.18 assigns PID_DOMAIN_TAG=0x4014, type string<256>; Table 9.19
defaults an absent tag to the empty string. PID_DOMAIN_ID=0x000f defaults, when absent,
to the receiving participant's domain ID. These are OMG RTPS definitions, not an
RTI-specific extension. Source: https://www.omg.org/spec/DDSI-RTPS/2.5/PDF

The tag is an exact, case-sensitive string, not a wildcard partition expression.
No normalization, truncation, domain translation or broker-local alias is permitted.
The native CDR string encoding includes its length and terminating NUL; the old realm
sequence-of-octets encoding is not a compatible substitute. Validate the standard bound
and termination through the generated codec and public configuration conversion.
The 0x4000 flag in the PID requires correct handling by a receiver that does not
understand it. An older implementation cannot be assumed to support nonempty tags.
Neither domain IDs/tags nor Partition QoS are authentication or access control.

## Public configuration

Add `@default("") string<256> tag;` to zzdds::DomainConfig alongside id, and carry it
through native configuration, generated bindings and TOML. Example proposed syntax:

```toml
[domain]
id = 0
tag = "production"

[discovery]
kind = "broker"

[discovery.broker]
addresses = ["tcp://discovery.example.net:7443"]
security = "authenticated"
credential_ref = "workload-identity"
```

The same domain tag applies with ordinary multicast, directed SPDP, mixed discovery,
or broker-only discovery. No broker realm field remains. Empty-tag defaults preserve
existing untagged deployments. Configuration is immutable for participant lifetime;
factory default changes affect future participants. Keep configuration on zzdds.idl
because the existing DomainConfig is its public configuration surface; do not invent
a new DCPS operation solely to expose an RTPS participant property.

## Native implementation requirement

Inspection found no domainTag/domain_tag/PID_DOMAIN_TAG support in src, idl or tests.
At inspection, the generated SPDP schema lacked both domainTag and domainId, and the
wrapper assigned its local domain_id argument irrespective of input. The first native
change now adds optional domainId decoding, unconditional outgoing domainId and rejection
of explicit foreign domains before SPDP cache/locator updates. Domain-tag support remains
pending; this partial change does not complete the domain-identity requirement.
Native support is therefore a broker prerequisite:

1. Add standard optional domainId/domainTag parameters to rtps_discovery.idl and regenerate.
   Always emit our domain ID, including domain zero, regardless of port/address selection.
   Decode absence using the specified defaults; preserve an explicit remote domain ID.
   This fallback is receiver-domain context, not reverse mapping from a source port.
2. Propagate configured tag through participant construction, announcements, owned remote
   data and cleanup. Emit nonempty tags; omission of empty tags retains default-wire
   interoperability. Keep codec decoding distinct from local association eligibility.
3. Check resolved domain identity before remote cache installation, locator learning,
   lease refresh, SEDP/WLP association and application notification. Review early SEDP
   receive paths so an excluded participant cannot create endpoint matches anyway.
4. Apply the same domain rule to other native discovery paths (including direct/in-process
   discovery), without changing the guaranteed same-participant matching path.
5. Cover absent/empty/equal/unequal tags, explicit domain mismatch, both byte orders,
   malformed/duplicate strings, upper bounds and unknown must-understand behavior.
   Test two participants sharing sockets/network/domain ID with different tags, plus
   default untagged compatibility and configuration/binding roundtrips.

Do not call support complete merely because the codec can retain an unknown PID.

## Broker reconciliation requirement

Scope becomes `(domain_id, domain_tag)` within the configured broker authority. Partition
matching continues within that scope. Admission authorization can restrict these standard
identifiers without inventing another discovery namespace. Multi-tenant administrative
isolation remains deferred; choosing a tag is not authorization to join that scope.

Derive the requested scope from the immutable client SPDP introduction. Remove
requested_realm from ServiceRequestContext: it need not repeat the participant's domain.
Replace ScopeValue.realm with a standard-bounded string domain_tag, retaining domain_id;
all registration/envelope scope fields must agree with the retained introduction. Broker
cache, ownership, view, digest and resume handling must use this resolved scope consistently.
A nonempty tag must not disappear on retransmission, broker reannouncement or local graph
installation. Missing domain IDs need explicit resolution against the configured contacted
service/domain context; a multi-domain broker must not guess an absent origin domain.
The zzdds broker profile should require an explicit origin domain ID in its introduction.

A broker service administers configured domain identities using a distinct logical RTPS
participant per scope, with shared listeners/runtime. Client and selected broker participant
must agree on domain ID/tag. Service ingress selects the identity before ordinary peer
installation; it does not authorize cross-domain associations. See the accepted
[multi-domain service arrangement](broker-multidomain-service.md).

The experimental ScopeValue now uses string<256> domain_tag followed by domain_id;
ServiceRequestContext no longer carries requested_realm. Independent fixtures use CDR
string length including its NUL terminator, not the old realm octet sequence. Service SPDP
fixtures include explicit domain ID and domain tag in both byte orders. Native admission
and interoperability tests remain implementation gates.

Validation of the domain-ID increment: `zig build test-discovery` passes 47/47 tests
with pinned zidl 0.3.17. Coverage includes unconditional domain-zero wire emission,
explicit LE/BE remote IDs, missing-ID receiver fallback, and foreign-domain rejection
without installation or refresh. This does not validate domainTag, full-suite behavior,
live cross-vendor interoperability or the remaining early-SEDP admission boundary.
