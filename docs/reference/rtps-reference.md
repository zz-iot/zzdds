# RTPS 2.5 Quick Reference

> **Not authoritative for implementation constants.** This is a contributor quick-reference
> extracted from the spec and source to avoid re-opening the PDF. For values actually used
> in code, see `src/rtps/pid.zig` (PIDs), `src/rtps/guid.zig` (entity IDs), and
> `docs/architecture.md` (encoding identifiers). If this file and source disagree, source
> wins.

Extracted from [formal/22-04-01](https://www.omg.org/spec/DDSI-RTPS/2.5/PDF) (OMG RTPS 2.5).
Section numbers reference the PDF directly.

---

## §9.6.2 — Port Formula

```
Discovery multicast port  = PB + DG×domainId + d0
Discovery unicast port    = PB + DG×domainId + d1 + PG×participantId
User multicast port       = PB + DG×domainId + d2
User unicast port         = PB + DG×domainId + d3 + PG×participantId
```

Default values (Table 9.24):

| Symbol | Name                  | Default |
|--------|-----------------------|---------|
| PB     | portBase              | 7400    |
| DG     | domainGain            | 250     |
| PG     | participantGain       | 2       |
| d0     | additionalOffset (d0) | 0       |
| d1     | additionalOffset (d1) | 10      |
| d2     | additionalOffset (d2) | 1       |
| d3     | additionalOffset (d3) | 11      |

Domain 0 example:
- Discovery multicast: 7400
- Discovery unicast participant 0: 7410
- User multicast: 7401
- User unicast participant 0: 7411

### §9.6.2.4 — Default multicast group and SPDP rate

- Default SPDP multicast address: **239.255.0.1** (for domain 0; fourth octet = domainId + 1 by convention)
- Spec default SPDP announcement period: **30 seconds**. Zenzen DDS currently defaults to
  `participant.announcement_period_ms = 3000` (3 seconds).

---

## §9.3.1.3 — Predefined EntityId Values (Table 9.2)

```zig
// All entries with entity_key and entity_kind:
unknown:                              { key={00,00,00}, kind=0x00 }
participant:                          { key={00,00,01}, kind=0xC1 }
sedp_builtin_topics_writer:           { key={00,00,02}, kind=0xC2 }
sedp_builtin_topics_reader:           { key={00,00,02}, kind=0xC7 }
sedp_builtin_publications_writer:     { key={00,00,03}, kind=0xC2 }
sedp_builtin_publications_reader:     { key={00,00,03}, kind=0xC7 }
sedp_builtin_subscriptions_writer:    { key={00,00,04}, kind=0xC2 }
sedp_builtin_subscriptions_reader:    { key={00,00,04}, kind=0xC7 }
spdp_builtin_participant_writer:      { key={00,01,00}, kind=0xC2 }
spdp_builtin_participant_reader:      { key={00,01,00}, kind=0xC7 }
p2p_builtin_participant_msg_writer:   { key={00,02,00}, kind=0xC2 }
p2p_builtin_participant_msg_reader:   { key={00,02,00}, kind=0xC7 }
```

These entity IDs are defined in `src/rtps/guid.zig`. The `p2p_builtin_participant_message_writer/reader`
endpoints are used by the Writer Liveliness Protocol (§8.4.13); the entity IDs are defined
but the WLP endpoint is not yet instantiated (see `docs/roadmap.md`).

---

## §9.3.2.12 — BuiltinEndpointSet_t Bitmask

Each bit represents a builtin endpoint. A participant advertises which builtin endpoints
it has instantiated. The field appears in `SPDPdiscoveredParticipantData.availableBuiltinEndpoints`.

| Bit | Constant name                              | Endpoint                          |
|-----|--------------------------------------------|-----------------------------------|
|   0 | DISC_BUILTIN_ENDPOINT_PARTICIPANT_ANNOUNCER | SPDP writer                      |
|   1 | DISC_BUILTIN_ENDPOINT_PARTICIPANT_DETECTOR  | SPDP reader                      |
|   2 | DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER| SEDP publications writer         |
|   3 | DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR | SEDP publications reader         |
|   4 | DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER| SEDP subscriptions writer       |
|   5 | DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR | SEDP subscriptions reader       |
|  10 | BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_WRITER | P2P liveliness writer       |
|  11 | BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_READER | P2P liveliness reader       |

Zenzen DDS currently advertises bits 0-5 (`0x0000003F`). The P2P liveliness bits are
defined in source but not set because the WLP endpoint is not instantiated.

---

## §9.6.3.2 — Discovery Type IDL

RTPS 2.5 defines logical discovery data types, then maps their serialized form to
ParameterList records. The checked-in `idl/rtps_discovery.idl` is a project-local
derived schema for zidl PL_CDR generation; it is not copied normative IDL. The
normative pieces to keep aligned are the RTPS primitive types, PID values, and
PID-to-field mappings in §9.3.2 and §9.6.3.2.

Important duration distinction:
- DDS/DCPS `Duration_t` is `sec + nanosec`; DDS infinite is `{0x7fffffff, 0x7fffffff}`.
- RTPS wire `Duration_t` is `seconds + fraction`, where `fraction` is in units of `1/2^32` seconds; RTPS infinite is `{0x7fffffff, 0xffffffff}`.
- `PID_DEADLINE`, `PID_PARTICIPANT_LEASE_DURATION`, and other RTPS ParameterList duration values use the RTPS wire representation. Convert to DDS duration semantics before QoS matching.
- If `PID_DEADLINE` is omitted, DDS default deadline is infinite. If it is explicitly present as `{0,0}`, that is RTPS `DURATION_ZERO`, not infinite.

### SPDPdiscoveredParticipantData

```idl
struct SPDPdiscoveredParticipantData {
    // From DDS::ParticipantBuiltinTopicData
    DDS::BuiltinTopicKey_t          key;              // == guidPrefix
    DDS::UserDataQosPolicy          user_data;

    // From ParticipantProxy
    ProtocolVersion_t               protocolVersion;
    GuidPrefix_t                    guidPrefix;       // OMIT in DATA (derived from header)
    VendorId_t                      vendorId;
    boolean                         expectsInlineQos;
    LocatorList_t                   metatrafficUnicastLocatorList;
    LocatorList_t                   metatrafficMulticastLocatorList;
    LocatorList_t                   defaultUnicastLocatorList;
    LocatorList_t                   defaultMulticastLocatorList;
    BuiltinEndpointSet_t            availableBuiltinEndpoints;
    Count_t                         manualLivelinessCount;

    // Lease
    Duration_t                      leaseDuration;
};
```

### DiscoveredWriterData

```idl
struct DiscoveredWriterData {
    // From DDS::PublicationBuiltinTopicData
    DDS::BuiltinTopicKey_t          key;              // writerGUID; OMIT remoteWriterGuid
    DDS::BuiltinTopicKey_t          participant_key;
    string                          topic_name;
    string                          type_name;
    // + all writer QoS policies

    // From WriterProxy
    LocatorList_t                   unicastLocatorList;
    LocatorList_t                   multicastLocatorList;
};
```

### DiscoveredReaderData

```idl
struct DiscoveredReaderData {
    // From DDS::SubscriptionBuiltinTopicData
    DDS::BuiltinTopicKey_t          key;              // readerGUID; OMIT remoteReaderGuid
    DDS::BuiltinTopicKey_t          participant_key;
    string                          topic_name;
    string                          type_name;
    // + all reader QoS policies

    // From ReaderProxy
    LocatorList_t                   unicastLocatorList;
    LocatorList_t                   multicastLocatorList;
    boolean                         expectsInlineQos;
    ContentFilterProperty_t         contentFilter;
};
```

### Table 9.17 — Omitted parameters in DATA submessages

When serializing discovery data into DATA submessages, these fields are omitted because
they are derivable from the surrounding RTPS framing:

- `ParticipantProxy::guidPrefix` → derived from RTPS message header GuidPrefix
- `WriterProxy::remoteWriterGuid` → derived from PublicationBuiltinTopicData::key
- `ReaderProxy::remoteReaderGuid` → derived from SubscriptionBuiltinTopicData::key

---

## §9.6.3.2.1 — PID Table (Tables 9.18 + 9.19)

Discovery data is serialized as a **ParameterList** (PL_CDR_LE encoding): a sequence of
`{ PID: u16_le, length: u16_le, value: [length]u8 }` records, terminated by PID_SENTINEL.

### Current implementation PIDs (`src/rtps/pid.zig`)

| PID    | Name                              | Type / Notes                                    |
|--------|-----------------------------------|-------------------------------------------------|
| 0x0000 | PID_PAD                           | Padding                                         |
| 0x0001 | PID_SENTINEL                      | End of ParameterList; length = 0                |
| 0x0002 | PID_PARTICIPANT_LEASE_DURATION    | RTPS Duration_t (`seconds` + `fraction`)        |
| 0x0004 | PID_TIME_BASED_FILTER             | RTPS Duration_t (`seconds` + `fraction`)        |
| 0x0005 | PID_TOPIC_NAME                    | string                                          |
| 0x0006 | PID_OWNERSHIP_STRENGTH            | i32                                             |
| 0x0007 | PID_TYPE_NAME                     | string                                          |
| 0x0015 | PID_PROTOCOL_VERSION              | ProtocolVersion_t (2 bytes + 2 pad)             |
| 0x0016 | PID_VENDORID                      | VendorId_t (2 bytes + 2 pad)                    |
| 0x001A | PID_RELIABILITY                   | ReliabilityQosPolicyKind + max_blocking_time    |
| 0x001B | PID_LIVELINESS                    | LivelinessQosPolicyKind + RTPS Duration_t       |
| 0x001D | PID_DURABILITY                    | DurabilityQosPolicyKind                         |
| 0x001E | PID_DURABILITY_SERVICE            | DurabilityServiceQosPolicy                      |
| 0x001F | PID_OWNERSHIP                     | OwnershipQosPolicyKind                          |
| 0x0021 | PID_PRESENTATION                  | PresentationQosPolicy                           |
| 0x0023 | PID_DEADLINE                      | DeadlineQosPolicy / RTPS Duration_t             |
| 0x0025 | PID_DESTINATION_ORDER             | DestinationOrderQosPolicyKind                   |
| 0x0027 | PID_LATENCY_BUDGET                | RTPS Duration_t (`seconds` + `fraction`)        |
| 0x002B | PID_LIFESPAN                      | RTPS Duration_t (`seconds` + `fraction`)        |
| 0x002C | PID_USER_DATA                     | OctetSeq                                        |
| 0x002E | PID_TOPIC_DATA                    | OctetSeq                                        |
| 0x002F | PID_UNICAST_LOCATOR               | Locator_t                                       |
| 0x0030 | PID_MULTICAST_LOCATOR             | Locator_t                                       |
| 0x0031 | PID_DEFAULT_UNICAST_LOCATOR       | Locator_t                                       |
| 0x0032 | PID_METATRAFFIC_UNICAST_LOCATOR   | Locator_t                                       |
| 0x0033 | PID_METATRAFFIC_MULTICAST_LOCATOR | Locator_t                                       |
| 0x0034 | PID_PARTICIPANT_MANUAL_LIVELINESS_COUNT | Count_t                                  |
| 0x0035 | PID_PARTITION                     | StringSeq                                       |
| 0x0040 | PID_HISTORY                       | HistoryQosPolicyKind + depth                    |
| 0x0041 | PID_RESOURCE_LIMITS               | ResourceLimitsQosPolicy                         |
| 0x0043 | PID_EXPECTS_INLINE_QOS            | boolean                                         |
| 0x0044 | PID_PARTICIPANT_BUILTIN_ENDPOINTS | u32                                             |
| 0x0048 | PID_DEFAULT_MULTICAST_LOCATOR     | Locator_t                                       |
| 0x0049 | PID_TRANSPORT_PRIORITY            | i32                                             |
| 0x0050 | PID_PARTICIPANT_GUID              | GUID_t                                          |
| 0x0052 | PID_GROUP_GUID                    | GUID_t                                          |
| 0x0055 | PID_CONTENT_FILTER_INFO           | ContentFilterInfo_t                             |
| 0x0056 | PID_GROUP_DATA / PID_COHERENT_SET | Spec-version conflict; code currently defines both |
| 0x0058 | PID_BUILTIN_ENDPOINT_SET          | BuiltinEndpointSet_t bitmask                    |
| 0x005A | PID_ENDPOINT_GUID                 | GUID_t                                          |
| 0x0062 | PID_ENTITY_NAME                   | string                                          |
| 0x0073 | PID_DATA_REPRESENTATION           | sequence of XTypes data representation IDs      |
| 0x0075 | PID_TYPE_INFORMATION              | CDR-encoded XTypes TypeInformation blob         |
| 0x0077 | PID_BUILTIN_ENDPOINT_QOS          | Builtin endpoint QoS                            |

Vendor-specific Zenzen DDS PIDs use the vendor range: `0x8001`
(`ZZDDS_SHMEM_UNICAST_LOCATOR`) and `0x8002` (`ZZDDS_SHMEM_ZC_LOCATOR`).

Locator_t wire format (Table 9.19, 24 bytes, **big-endian** for kind and port):
```
kind:    i32  (4 bytes, big-endian)
port:    u32  (4 bytes, big-endian)
address: [16]u8
```

### Inline QoS PIDs (Table 9.20)

These PIDs appear in the inlineQos of DATA/DATA_FRAG submessages:

| PID    | Name                    | Type / Notes                              |
|--------|-------------------------|-------------------------------------------|
| 0x0055 | PID_CONTENT_FILTER_INFO | ContentFilterInfo_t (for filtered writers)|
| 0x0057 | PID_DIRECTED_WRITE      | GUID_t (targeted reader GUID)             |
| 0x0061 | PID_ORIGINAL_WRITER_INFO| OriginalWriterInfo_t                      |
| 0x0063 | PID_GROUP_COHERENT_SET  | Group coherent set marker                 |
| 0x0064 | PID_GROUP_SEQ_NUM       | Group sequence number                     |
| 0x0065 | PID_WRITER_GROUP_INFO   | Writer group info                         |
| 0x0066 | PID_SECURE_WRITER_GROUP_INFO | Secure writer group info             |
| 0x0070 | PID_KEY_HASH            | [16]u8 (MD5 key hash or padded key)       |
| 0x0071 | PID_STATUS_INFO         | StatusInfo_t (u32, 4 bytes)               |

---

## §9.6.4.8 — KeyHash Computation

The `PID_KEY_HASH` inline QoS value is a 16-byte opaque identifier for a data instance.

Algorithm:
1. Serialize **key fields only** in PLAIN_CDR2 Big Endian (`0x00 0x06`) format.
   - This uses XCDR2 serialization of the key-only version of the type.
2. If max serialized key size ≤ 16 bytes:
   - Copy the serialized bytes into the 16-byte hash field, zero-pad the rest.
3. If max serialized key size > 16 bytes:
   - Compute MD5 of the serialized bytes, use the 16-byte MD5 digest as the hash.
4. For keyless types: all 16 bytes are zero.

---

## §9.6.4.9 — StatusInfo_t Layout

`StatusInfo_t` is a 4-byte value sent in `PID_STATUS_INFO` inline QoS.

```
Byte 0: reserved
Byte 1: reserved
Byte 2: reserved
Byte 3 (LSB):
    bit 0 = D (Disposed)    — writer called dispose()
    bit 1 = U (Unregistered) — writer called unregister_instance()
    bit 2 = F (Filtered)     — sample was filtered (for virtual writers, future use)
```

All other bits are reserved and must be zero.

Typical values:
- `0x00000000` — ALIVE (no flags set; also: inline QoS omitted entirely)
- `0x00000001` — NOT_ALIVE_DISPOSED (D=1)
- `0x00000002` — NOT_ALIVE_UNREGISTERED (U=1)
- `0x00000003` — NOT_ALIVE_DISPOSED | NOT_ALIVE_UNREGISTERED (D=1, U=1)

---

## §10 — Serialized Payload Encoding Identifiers

The 4-byte serialized payload header (`encapsulation_identifier`, `encapsulation_options`):

| Identifier | Bytes        | Meaning                                      |
|------------|--------------|----------------------------------------------|
| CDR_BE     | 0x00, 0x00   | XCDR1 Big Endian (DDS v1.0 CDR)              |
| CDR_LE     | 0x00, 0x01   | XCDR1 Little Endian                          |
| PL_CDR_BE  | 0x00, 0x02   | ParameterList CDR Big Endian (discovery)     |
| PL_CDR_LE  | 0x00, 0x03   | ParameterList CDR Little Endian (discovery)  |
| CDR2_BE    | 0x00, 0x10   | XCDR2 Big Endian                             |
| CDR2_LE    | 0x00, 0x11   | XCDR2 Little Endian (Zenzen writer default)  |
| PL_CDR2_BE | 0x00, 0x12   | ParameterList CDR2 Big Endian                |
| PL_CDR2_LE | 0x00, 0x13   | ParameterList CDR2 Little Endian             |

Bytes 2-3: `encapsulation_options` = 0x00, 0x00 (always zero in current spec).

Usage rules:
- **Discovery endpoints** (SPDP, SEDP): PL_CDR_LE (`0x00 0x03`) — serialized as ParameterList.
- **User data writers** (Zenzen DDS): CDR2_LE (`0x00 0x11`) — XCDR2 little-endian.
- **Reader cache**: may contain any of the above (whatever the remote writer sent).

---

## §8.4.8–8.4.12 — State Machine Summary

### StatelessWriter

- Maintains a **ReaderLocator** list (known reader locators, no per-reader state).
- On write: sends DATA to all ReaderLocators.
- No reliability; no HEARTBEAT/ACKNACK exchange.
- Used for: SPDP announcements.

### StatefulWriter (Reliable)

- Maintains a **ReaderProxy** per matched reader (tracks seqnum, requested changes).
- Periodically sends HEARTBEAT (contains firstSN + lastSN of writer history).
- On receiving ACKNACK: adds missing seqnums to requested-changes set → retransmit.
- HEARTBEAT period: configurable; typically 200ms for user data, 1s for discovery.
- `HEARTBEAT.FinalFlag` (F bit): if set, no immediate response expected.
- `HEARTBEAT.LivelinessFlag` (L bit): used by Writer Liveliness Protocol.

### StatelessReader

- Accepts DATA from any writer matching the topic/type.
- No seqnum tracking; no duplicate detection.
- Used for: SPDP listener.

### StatefulReader (Reliable)

- Maintains a **WriterProxy** per matched writer (tracks expected seqnum, missing seqnums).
- Sends ACKNACK in response to HEARTBEAT.
- ACKNACK `FinalFlag` (F bit): if set, writer should not respond with more data.
- On receiving GAP: marks those seqnums as irrelevant (removes from missing set).
- On receiving DATA: if seqnum matches next expected → deliver; else → buffer.

### §8.4.13 — Writer Liveliness Protocol

- Participant P sends MANUAL_BY_PARTICIPANT liveliness via the **ParticipantMessageWriter**
  (entity `{00,02,00}/0xC2`) to the **ParticipantMessageReader** (`{00,02,00}/0xC7`).
- The payload is a `ParticipantMessageData` struct (builtin topic).
- AUTOMATIC liveliness: participant heartbeat sent on the SPDP writer.
- This is separate from SEDP endpoint discovery.

---

## §8.5.3–8.5.5 — SPDP and SEDP Wiring Pseudocode

### SPDP Structure

- Each participant has one **SPDPbuiltinParticipantWriter** (StatelessWriter, best-effort).
- Each participant has one **SPDPbuiltinParticipantReader** (StatelessReader, best-effort).
- Writer sends `SPDPdiscoveredParticipantData` to the SPDP multicast locator every 30s.
- Reader listens on the SPDP multicast locator.

### §8.5.5.1 — SEDP Wiring on Participant Discovery

When the SPDP reader discovers a new remote participant P_remote:

```
if P_remote.availableBuiltinEndpoints & DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER:
    create ReaderProxy for remote publications writer → local SEDP publications reader
    (connect to P_remote.metatrafficUnicastLocatorList or metatrafficMulticastLocatorList)

if P_remote.availableBuiltinEndpoints & DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR:
    create WriterProxy for local publications writer → remote SEDP publications reader

if P_remote.availableBuiltinEndpoints & DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER:
    create ReaderProxy for remote subscriptions writer → local SEDP subscriptions reader

if P_remote.availableBuiltinEndpoints & DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR:
    create WriterProxy for local subscriptions writer → remote SEDP subscriptions reader
```

Locator selection for SEDP connections:
- Use `metatrafficUnicastLocatorList` for unicast SEDP.
- Fallback to `metatrafficMulticastLocatorList` if unicast list is empty.
- If both lists are empty: use the locator the SPDP announcement arrived from.

### §8.5.4 — SEDP Data Flow

Each SEDP writer (publications, subscriptions) sends one DATA message per local endpoint:
- **Announce**: DATA with `DiscoveredWriterData` / `DiscoveredReaderData`.
- **Retract**: DATA with `PID_STATUS_INFO` D=1 (disposed) + endpoint GUID as key.

SEDP readers deliver matched-writer/reader notifications to the DCPS layer, which
triggers QoS matching and endpoint wiring.

### §8.5.7.1 — QoS Matching (Summary)

A writer and reader match if:
- Topic names are equal
- Type names are equal
- Requested QoS is compatible with offered QoS (per the compatibility matrix in §2.2.3)

Key compatibility rules:
- RELIABILITY: `requested ≤ offered` (BEST_EFFORT < RELIABLE)
- DURABILITY: `requested ≤ offered` (VOLATILE < TRANSIENT_LOCAL < TRANSIENT < PERSISTENT)
- DEADLINE: `requested.period ≥ offered.period`
- LATENCY_BUDGET: `requested.duration ≥ offered.duration`
- OWNERSHIP: kinds must match exactly
- LIVELINESS: `requested ≤ offered` (AUTOMATIC < MANUAL_BY_PARTICIPANT < MANUAL_BY_TOPIC); `requested.lease_duration ≥ offered.lease_duration`
- PRESENTATION: `requested ≤ offered`

---

## §9.3.1.5 — GuidPrefix Requirement

The RTPS spec requires the first two bytes of a GuidPrefix to equal the participant's
VendorId bytes.

Current implementation status:
- `src/rtps/message/header.zig` uses header `VENDOR_ID = {0x01, 0x23}`.
- `src/rtps/pid.zig` uses SPDP `ZZDDS_VENDOR_ID = {0x99, 0x99}`.
- `src/util/guid_gen.zig` does not currently force either value into `guidPrefix[0..2]`.

Before publishing interop results, register a permanent vendor ID with OMG, make the header
and SPDP vendor IDs agree, and update GUID-prefix generation to preserve that value.

---

## Wire Format Quick Notes

### Submessage Header (§9.4.1)

```
submessage_id: u8
flags:         u8   (bit 0 = EndiannessFlag: 0=big-endian, 1=little-endian)
octets_to_next_header: u16 (in flag endianness; 0 = extends to end of message)
```

### DATA submessage flags (§9.4.5.3)

```
bit 0 = E (Endianness): 1=LE
bit 1 = Q (InlineQoS):  1=inlineQos present
bit 2 = D (Data):       1=serializedPayload present and contains data
bit 3 = K (Key):        1=serializedPayload contains key (dispose/unregister)
bit 4 = N (NonStandard): reserved
```

D and K are mutually exclusive. If both 0: no payload (used for pure-key operations).

### HEARTBEAT submessage flags

```
bit 0 = E (Endianness)
bit 1 = F (Final):      1=no ack required
bit 2 = L (Liveliness): 1=this is a liveliness heartbeat
```

### ACKNACK submessage flags

```
bit 0 = E (Endianness)
bit 1 = F (Final):      1=no more data available; writer should not send data
```

### INFO_TS submessage flags

```
bit 0 = E (Endianness)
bit 1 = I (Invalidate): 1=timestamp is invalid (no timestamp field present)
```

---

## §9.3.2 — Key Type Sizes

| Type                 | Size (bytes) | Notes                                    |
|----------------------|--------------|------------------------------------------|
| GuidPrefix_t         | 12           | extern struct                            |
| EntityId_t           | 4            | 3-byte key + 1-byte kind                 |
| GUID_t               | 16           | GuidPrefix + EntityId                    |
| SequenceNumber_t     | 8            | i32 high + u32 low                       |
| Locator_t            | 24           | i32 kind + u32 port + [16]u8 address     |
| ProtocolVersion_t    | 2            | major u8 + minor u8                      |
| VendorId_t           | 2            | [2]u8                                    |
| RtpsTimestamp        | 8            | u32 seconds + u32 fraction (1/2^32 s)    |
| Duration_t (DCPS)    | 8            | i32 sec + u32 nanosec                    |
| RtpsDuration         | 8            | i32 seconds + u32 fraction (1/2^32 s)    |
| BuiltinEndpointSet_t | 4            | u32 bitmask                              |
| StatusInfo_t         | 4            | u32 flags                                |
| Header               | 20           | PROTOCOL_ID[4] + version[2] + vendor[2] + prefix[12] |
| Submessage header    | 4            | id[1] + flags[1] + length[2]             |
| SequenceNumberSet    | variable     | bitmapBase(8) + numBits(4) + bitmap(⌈numBits/32⌉×4) |

---

## Locator Kind Values (§9.3.2 Table 9.19)

| Kind value  | Name             |
|-------------|------------------|
| -1 (0xFFFF) | LOCATOR_KIND_INVALID |
| 0           | LOCATOR_KIND_RESERVED |
| 1           | LOCATOR_KIND_UDPv4 |
| 2           | LOCATOR_KIND_UDPv6 |

UDPv4 address encoding in Locator_t: bytes 0–11 = zero, bytes 12–15 = IPv4 address.
UDPv6 address encoding: all 16 bytes = IPv6 address.
