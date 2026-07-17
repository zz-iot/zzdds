//! RTPS Parameter IDs (PIDs) used in PL_CDR serialization of discovery data.
//!
//! Source: RTPS 2.5 spec §9.6.2 Table 9.14 (Built-in endpoint parameters).
//! Zenzen DDS vendor-specific PIDs use the vendor range 0x8000–0x8FFF.
//!
//! PL_CDR sentinel: PID_SENTINEL (0x0001) — signals end of parameter list.
//! PIDs 0x0000 and 0x0001 are special; all others encode as (pid, length, value...).

/// RTPS built-in PIDs (Table 9.14).
pub const PidTable = struct {
    // ── Sentinel / padding ────────────────────────────────────────────────────
    pub const PAD: u16 = 0x0000;
    pub const SENTINEL: u16 = 0x0001;

    // ── Participant / endpoint identity ───────────────────────────────────────
    pub const PARTICIPANT_GUID: u16 = 0x0050;
    pub const GROUP_GUID: u16 = 0x0052;
    pub const BUILTIN_ENDPOINT_SET: u16 = 0x0058;
    pub const BUILTIN_ENDPOINT_QOS: u16 = 0x0077;

    // ── Discovery locators ────────────────────────────────────────────────────
    pub const METATRAFFIC_UNICAST_LOCATOR: u16 = 0x0032;
    pub const METATRAFFIC_MULTICAST_LOCATOR: u16 = 0x0033;
    /// PID used in SPDPdiscoveredParticipantData (participant default unicast locator).
    pub const DEFAULT_UNICAST_LOCATOR: u16 = 0x0031;
    pub const DEFAULT_MULTICAST_LOCATOR: u16 = 0x0048;

    // ── Participant lease ─────────────────────────────────────────────────────
    pub const PARTICIPANT_LEASE_DURATION: u16 = 0x0002;
    pub const PARTICIPANT_MANUAL_LIVELINESS_COUNT: u16 = 0x0034;

    // ── Protocol version / vendor ─────────────────────────────────────────────
    pub const PROTOCOL_VERSION: u16 = 0x0015;
    pub const VENDORID: u16 = 0x0016;

    // ── Endpoint QoS policies (Table 9.14) ───────────────────────────────────
    pub const RELIABILITY: u16 = 0x001A;
    pub const DURABILITY: u16 = 0x001D;
    pub const DURABILITY_SERVICE: u16 = 0x001E;
    pub const DEADLINE: u16 = 0x0023;
    pub const LATENCY_BUDGET: u16 = 0x0027;
    pub const LIVELINESS: u16 = 0x001B;
    pub const OWNERSHIP: u16 = 0x001F;
    pub const OWNERSHIP_STRENGTH: u16 = 0x0006;
    pub const DESTINATION_ORDER: u16 = 0x0025;
    pub const TIME_BASED_FILTER: u16 = 0x0004;
    pub const PRESENTATION: u16 = 0x0021;
    pub const PARTITION: u16 = 0x0029;
    /// Legacy value used by pre-RTPS-2.5 implementations (now PID_CONTENT_FILTER_PROPERTY).
    /// Accept on receive for backward compatibility; always emit PARTITION (0x0029).
    pub const PARTITION_LEGACY: u16 = 0x0035;
    pub const TOPIC_DATA: u16 = 0x002E;
    pub const GROUP_DATA: u16 = 0x002D;
    pub const USER_DATA: u16 = 0x002C;
    pub const HISTORY: u16 = 0x0040;
    pub const RESOURCE_LIMITS: u16 = 0x0041;
    pub const LIFESPAN: u16 = 0x002B;
    pub const TRANSPORT_PRIORITY: u16 = 0x0049;
    pub const DATA_REPRESENTATION: u16 = 0x0073; // DDS-XTypes §7.6.3

    // ── Endpoint information (Table 9.14) ─────────────────────────────────────
    pub const TOPIC_NAME: u16 = 0x0005;
    pub const TYPE_NAME: u16 = 0x0007;
    pub const ENDPOINT_GUID: u16 = 0x005A;
    /// PID used in DiscoveredWriter/ReaderData (endpoint-specific unicast locator).
    pub const UNICAST_LOCATOR: u16 = 0x002F;
    pub const MULTICAST_LOCATOR: u16 = 0x0030;
    pub const EXPECTS_INLINE_QOS: u16 = 0x0043;
    pub const PARTICIPANT_BUILTIN_ENDPOINTS: u16 = 0x0044;
    pub const CONTENT_FILTER_INFO: u16 = 0x0055;
    pub const COHERENT_SET: u16 = 0x0056;

    // ── Type identity (DDS-XTypes §7.6) ──────────────────────────────────────
    pub const TYPE_INFORMATION: u16 = 0x0075;

    // ── Entity name (Wireshark-visible participant/endpoint name) ─────────────
    pub const ENTITY_NAME: u16 = 0x0062;

    // ── Zenzen DDS vendor-specific PIDs (0x8000+ range, vendor bit set) ──────────
    /// SHMEM Mode-1 (RTPS-over-SHMEM) unicast locator for an endpoint.
    pub const ZZDDS_SHMEM_UNICAST_LOCATOR: u16 = 0x8001;
    /// SHMEM Mode-2 (zero-copy fast path) channel descriptor for a writer.
    pub const ZZDDS_SHMEM_ZC_LOCATOR: u16 = 0x8002;
};

// ── Built-in endpoint set bit flags ──────────────────────────────────────────

/// Bit flags used in PID_BUILTIN_ENDPOINT_SET (§8.5.4.2 Table 8.58).
pub const BuiltinEndpointSet = struct {
    pub const DISC_BUILTIN_ENDPOINT_PARTICIPANT_ANNOUNCER: u32 = 0x00000001;
    pub const DISC_BUILTIN_ENDPOINT_PARTICIPANT_DETECTOR: u32 = 0x00000002;
    pub const DISC_BUILTIN_ENDPOINT_PUBLICATIONS_ANNOUNCER: u32 = 0x00000004;
    pub const DISC_BUILTIN_ENDPOINT_PUBLICATIONS_DETECTOR: u32 = 0x00000008;
    pub const DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_ANNOUNCER: u32 = 0x00000010;
    pub const DISC_BUILTIN_ENDPOINT_SUBSCRIPTIONS_DETECTOR: u32 = 0x00000020;
    pub const BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_WRITER: u32 = 0x00000400;
    pub const BUILTIN_ENDPOINT_PARTICIPANT_MESSAGE_DATA_READER: u32 = 0x00000800;
};

// ── RTPS VendorId for Zenzen DDS ────────────────────────────────────────────────

/// RTPS VendorId_t (§8.3.3.1) for Zenzen DDS, officially registered with OMG.
/// Derived from `message/header.VENDOR_ID` so there is a single authoritative
/// definition of the two-byte value; this is just its raw-byte form for
/// appending directly into PL_CDR parameter buffers.
pub const ZZDDS_VENDOR_ID: [2]u8 = @import("message/header.zig").VENDOR_ID.bytes;
