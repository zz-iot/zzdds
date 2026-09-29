# Broker: security and filtering

This is a current contract. Scope, decisions and implementation gates are in
[the single status index](../concurrency-broker-status.md). Validation results are maintained
only in [the evidence inventory](../../../test/design-models/README.md).
<a id="broker-security-and-filtering"></a>
## Broker security, profiles and disclosure

<a id="broker-security-and-filtering--shipping-and-future-modes"></a>
### Shipping and future modes

V1 is traditional insecure cached discovery over UDP or TCP. It provides no cryptographic
identity, confidentiality or access control; domain/tag, configured network paths, quotas
and disclosure policy are not substitutes. Preserve UDP return-path validation and bounded
admission. TCP return reachability is not authentication. No mandatory credential_ref or
separate BrokerSecurityPolicy remains in the application Config.

Future secure mode derives from participant DDS Security. The broker participates in its
standard authentication/access-control/crypto machinery. Validate UDP return reachability
before expensive authentication or large replies, with endpoint eligibility arranged so
ordinary SPDP processing cannot bypass that gate. Rate/storage/CPU limits remain necessary
for reachable attackers. Establish an explicit zzdds protection rule for vendor control
endpoints; do not assume governance automatically names them. Verify both UDP and TCP paths.
No secure-to-plaintext fallback is allowed.

Cached secure discovery treats the broker as a trusted metadata intermediary. It may decrypt,
store and protect disclosures for authorized observers, but its claims do not replace peer
identity, permissions or origin validation. Independent peer handshakes protect user data
according to configured policy. Assertions that a broker cannot read user data require
appropriate encryption and exclusion from those permissions/keys. A compromised broker can
withhold or falsify discovery assertions. Optional peer secure-SEDP confirmation is a later
hardening design, not an already-completed trust proof. Opaque_peer and transport relays are
later profiles; no DDS Security relay-plugin conformance is claimed by this document.

<a id="broker-security-and-filtering--disclosure-and-candidate-filtering"></a>
### Disclosure and candidate filtering

Scope by domain ID/tag first. Operators set the maximum disclosed graph per scope; clients
may request narrower topic/partition candidate views. Within the allowed graph, filtering
must conservatively retain possible matches. A policy may intentionally hide matches;
conservatism cannot override that policy. Traditional-mode endpoint declarations do not
prove identity or entitlement and must not be described as authenticated confidentiality.

Partition data belongs to Publisher/Subscriber endpoint QoS in SEDP. Re-evaluate both-sided
partition-expression matching and topic candidates on changes. Preserve parent participant
records required by visible endpoints. Use a tested DDS partition-matching implementation,
not a new ad hoc glob interpretation. Do not filter on type/QoS compatibility and thereby
suppress diagnostics. With DDS Security, integrate actual validated permissions and current
revocation policy rather than trusting an unvalidated permissions document.

The zzdds broker implements candidate filtering. A constrained client can require it and
refuse unsupported service; no silent VIEW_ALL fallback. Filtering does not guarantee any
workload fits: retain explicit record/byte limits and bounded failure. Whether every future
third-party broker must implement filters is not a v1 delivery prerequisite.

<a id="broker-security-and-filtering--constrained-broker-client-acceptance-profile"></a>
### Constrained broker client acceptance profile

Use one domain scope and authority, a required topic/partition candidate view, explicit
record/byte/frame/exception limits and bounded UDP bootstrap. No silent broad-view fallback.
A zero-endpoint client may receive an empty candidate graph and later receive retained
candidates when its interest changes. Parent participant dependencies remain accounted.
A graph that exceeds the declared limits fails or resynchronizes with bounded backoff;
filtering is not a guarantee of capacity under arbitrary workloads.

Measure this profile after the baseline cooperative runtime profile, with separate costs
for native inventory, installed candidate graph, replacement overlap, RTPS repair, retained
raw records and marker exceptions. An MCU may select TCP instead if available and UDP
introduction size is unsuitable; no automatic transport switch or field stripping follows.
Actual maximum peers/endpoints and target memory are measured implementation claims.

<a id="broker-security-and-filtering--optional-continuity-v11"></a>
### Optional continuity: v1.1

D2 authorizes a client-requested random single-use registration continuity capability in
REGISTER/ACCEPT, never SPDP. Bind scope, GUID, incarnation and the current registration;
atomically fence the old session and rotate the token on successful replacement. No
permanent ownership record or blacklist. Traditional deployments accept bearer-capability
risk; secure mode must additionally enforce authenticated context and permissions.

Retain prior same-incarnation inventory only under its existing freshness/authorization
bounds until fresh upload commits. Replacement alone cannot renew stale origin evidence.
Lost initial ACCEPT leaves the established short timeout/expiry recovery path. Specify lost
replacement ACCEPT and duplicate-token outcomes before v1.1 implementation. v1 still omits
the reserved continuity field and never grants replacement on an unimplemented token.
