# Origin-version placement and canonical discovery content

Status: placement and comparison direction accepted, 2026-09-18. Experimental
PID_ZZDDS_ORIGIN_VERSION = 0x8003 and OriginVersion type added to the design schema;
production discovery IDL and emission remain unchanged. The current broker bootstrap remains under
SPDP-based redesign; this extension applies to origin discovery independently of it.

## Placement

Use a vendor-specific, optional-to-legacy-readers origin-version parameter carrying
participant incarnation (16 octets) and per-entity origin_revision (unsigned 64-bit).
Both must be nonzero under the zzdds extension contract. Parameter body is CDR using
the containing ParameterList's byte order, with alignment origin at its value start:
incarnation at offset 0 and revision at offset 16, total 24 bytes. No nested encapsulation.
The key remains the standard participant/endpoint GUID; no GUID is duplicated here.
The provisional assignment 0x8003 avoids existing zzdds locator PIDs 0x8001/0x8002.
Its vendor bit is set and must-understand bit clear, allowing legacy readers to ignore
the extension. Interpretation is scoped to the zzdds vendor/profile, not arbitrary
vendors reusing the same vendor-specific PID. This is not an OMG allocation.

| Native announcement | Version parameter location |
| --- | --- |
| Full SPDP participant data | Serialized discovery ParameterList |
| Full SEDP publication/subscription data | Serialized discovery ParameterList |
| Key-only participant/endpoint dispose or unregister | DATA inline-QoS ParameterList; serialized key payload remains standard |
| Key-hash-only lifecycle message | Inline QoS, alongside existing native key/status information; resolve key unambiguously |

RTPS restricts key-only built-in discovery payloads to PID_PARTICIPANT_GUID or
PID_ENDPOINT_GUID, respectively. Its inline-QoS ParameterList has vendor extension
handling. The placement above is our extension design using those mechanisms, not an
OMG-defined origin-version field.
[RTPS 2.5 §§9.6.2.2, 9.6.3, 9.6.4](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF).

Use one semantic parameter definition in both allowed locations. For full messages,
inline-only metadata is not a substitute for the payload parameter in the initial
zzdds profile. If both locations contain it, require exact decoded agreement. Duplicate
singleton occurrences, wrong lengths, zero values or disagreement reject versioned
installation. A peer lacking the parameter remains a legacy peer; do not fabricate an
origin revision from arrival time or assume it is older than revision 1.

Fragmented full announcements retain version metadata within the reassembled payload;
key-only lifecycle messages are small and should not require fragmentation. If the native
transport supports a fragmented lifecycle form, its inline metadata must be validated
and retained through reassembly under the RTPS rules before installation. Fragment receipt
is not authorization to apply a deletion early.

A broker OriginRecord repeats incarnation/revision in its envelope fields for indexing
and ordering. Where native origin metadata is present, require equality. For retained
native deletions, preserve original inline QoS in change_metadata and validate its version
against the OriginRecord. A locally constructed broker removal without a native sample
still gets its version from the common local origin-update boundary. It must not invent
native status/sequence provenance. If direct deletion is also emitted, it uses that same
origin version, regardless of the relative transmission times.

## What the revision versions

Version canonical entity discovery content, not the serialized packet or an observation's
freshness. Define a typed comparison projection for each supported record kind:

* Participant: identity, protocol/vendor identity, domain/tag where present, built-in
  capabilities and QoS, metatraffic/default locators, advertised lease duration, user data,
  entity name and other recognized persistent discovery properties.
* Writer/reader: identity, parent/group identity, topic/type identity and type information,
  endpoint locators, advertised QoS, content-filter properties and other recognized
  persistent endpoint metadata.
* Lifecycle state: the origin's alive/remove transition and relevant native dispose/
  unregister meaning. A source withdrawal is never an origin lifecycle transition.

Exclude RTPS writer sequence, timestamps, transport headers, encapsulation representation,
legal serialization padding and ordering between distinct independent PIDs. Treat absent
recognized parameters according to their specified effective defaults; do not invent a
default where the applicable profile requires presence. Retain ordered sequences and
repeated parameter values in their defined order unless their specification explicitly
permits set-like equivalence. In particular, do not sort every locator/QoS sequence merely
to make comparison convenient. A conservative extra conflict is safer than hiding a change.

Exclude the version parameter itself from content comparison (compare it as provenance),
and separate directed broker-service request context from canonical origin content. The
exact list of excluded zzdds service PIDs will be assigned with the revised handshake.
An unknown vendor parameter is not automatically service context.

## Native operational fields

SPDP manualLivelinessCount is an operational assertion counter, not a persistent discovery
configuration revision. A changed counter can accompany the same origin revision. Process
it under native liveliness ordering/freshness rules on a direct source. Cached broker
replay of that value must not generate a fresh assertion. Likewise repeated SPDP reception
may refresh the direct participant lease without changing canonical content, while broker
freshness comes from the broker presence contract. Neither observation rewrites origin
revision or changes the other source's deadline.

This requires splitting operational receive handling from canonical entity installation.
Do not skip all processing just because an announcement has the already installed origin
revision. Conversely, accepting a new operational counter is not permission to roll back
persistent QoS/locators from an older origin revision. The native protocol's own acceptance
rules still apply. Exact field classification must be reflected in the implementation's
per-record comparator and tests; excluding arbitrary fields would be a correctness bug.

## Unknown fields and byte preservation

For recognized content, compare decoded effective values. For unknown optional content,
retain PID, multiplicity, order among repeats, value bytes and source encoding context.
Conservatively treat differing opaque values or encoding contexts as incomparable/conflict
at the same revision. Do not guess how to normalize an unknown structure or erase its
bytes to force equivalence. This may reject semantically equivalent opaque data encoded
in different byte orders; an extension-specific comparator can later remove that false
conflict. Unknown required semantics continue to prevent installation.

Keep three distinct rules:

1. Native/broker source bytes are retained unchanged for fidelity.
2. A retry of the same broker logical request retains exactly the same OriginRecord bytes.
3. Cross-source version equivalence uses the canonical projection above, not byte equality
   of entire packets and not arbitrary reserialization of unknown fields.

For each committed origin revision, the origin retains a stable broker representation
for retries and any inventory reupload needing that version. Later native reannouncements
may contain changed operational counters while preserving the same canonical content.
They do not replace the retained broker record under the same revision. If that retained
representation cannot be supplied after local reclamation, use a defined recovery contract;
do not silently send different record bytes at an existing revision. Representation
lifetime/accounting must be included in the origin implementation, not a broker-only cache.

## Expected validation

* Full SPDP/SEDP LE and BE versions decode to the same incarnation/revision.
* Key-only deletion retains only the standard key in its payload; inline version survives
  native decode and broker retention.
* Duplicate/conflicting payload/inline versions fail before graph changes.
* Same revision with changed persistent QoS, locators or opaque content conflicts.
* Same revision with a newer valid native liveliness counter processes the assertion
  without duplicate matches; broker replay never manufactures that assertion.
* Absent/default recognized QoS compare according to the applicable standard/profile;
  changed unknown data does not disappear during comparison.
* Changed packet padding/PID order cannot alone cause an endpoint lost/found cycle.

Source inspection: generated discovery structures retain unknown payload parameters, but
ordinary decode may project/deinitialize them. SEDP removal processing separately reads
inline key/status and built-in endpoint helpers use their own receive paths. Both paths
need deliberate version extraction/retention before callbacks; the current generated
payload codec alone does not implement this contract.

## Recorded fixture evidence

Eight independent vectors in probes/broker_golden/origin_version.py cover LE/BE value
bytes, structural full ParameterLists, key-only payloads and inline deletion metadata.
The Zig probe checks generated value decoding in both byte orders, LE emission agreement,
placement and truncated/invalid-length rejection through a fixture-only list parser.
All 17 codec checks pass. Full-list vectors are structural endpoint-key/version examples,
not complete semantically valid SEDP announcements. BE generated emission, production
receive integration, duplicate/cross-location conflict checks and semantic equivalence
remain implementation validation work. No production discovery behavior is changed.

Run the additional independent vectors with:
`python3 docs/design/probes/broker_golden/origin_version.py`.

Next reconcile the accepted origin-version extension with SPDP service-introduction
metadata: choose the directed request parameter and compact registration fields without
making service-specific values part of canonical entity state. The new bootstrap sequence
remains a proposal; old HELLO/OPEN size fixtures do not validate its eventual encoding.
