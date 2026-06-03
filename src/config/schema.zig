//! Zenzen DDS configuration schema.
//!
//! Config is resolved by merging (highest priority first):
//!   1. Programmatic — values set on Config before passing to factory
//!   2. Environment variables — ZZDDS_* prefix (see env.zig)
//!   3. Config file — TOML (see file.zig); searched at ZZDDS_CONFIG, ./zzdds.toml,
//!                    ~/.config/zzdds/config.toml
//!   4. Defaults — the zero/default values in this file
//!
//! All durations are in milliseconds unless noted.

/// Top-level configuration passed to DomainParticipantFactory.
pub const Config = struct {
    domain: DomainConfig = .{},
    participant: ParticipantConfig = .{},
    transport: TransportConfig = .{},
    rtps: RtpsConfig = .{},
    discovery: DiscoveryConfig = .{},
    qos: QosDefaults = .{},
};

pub const DomainConfig = struct {
    /// DDS domain identifier (0–232 per spec).
    id: u32 = 0,
};

pub const GuidStrategy = enum {
    /// VendorId[2] + random[10] (default). Spec-compliant per RTPS §9.3.1.5: first two
    /// bytes identify the vendor; remaining 10 bytes are OS entropy. Wireshark and DDS
    /// analyzers can identify the implementation from any GUID in a capture.
    spec_random,
    /// StartTime[4] + PID[4] + counter[2] with VendorId[2] prefix. Deterministic and
    /// Wireshark-friendly; useful for debugging. Reveals host information (start time, PID).
    host_based,
    /// 12 cryptographically-random bytes. No vendor stamp; maximises privacy at the cost
    /// of spec non-compliance. Use when exposing the vendor identity is undesirable.
    fully_random,
};

pub const ParticipantConfig = struct {
    /// Human-readable participant name. Empty = auto-generated.
    name: []const u8 = "",
    /// Lease duration in ms. Remote peers remove this participant
    /// if no announcement arrives within this window.
    lease_duration_ms: u32 = 10_000,
    /// How often to re-announce this participant to peers (ms).
    /// Should be << lease_duration_ms.
    announcement_period_ms: u32 = 3_000,
    /// Strategy for generating the 12-byte GUID prefix.
    guid_strategy: GuidStrategy = .spec_random,
    /// Name of the clock to use for internal interval timers (deadline,
    /// liveliness, SPDP lease). Must be registered in the factory's
    /// ClockRegistry. Built-in names: "default", "monotonic", "realtime",
    /// "boottime". Falls back to "default" (monotonic) on unknown names.
    timer_clock_name: []const u8 = "default",
};

pub const RtpsConfig = struct {
    /// DATA_FRAG fragment size in bytes.  Payloads larger than this are split
    /// into multiple DATA_FRAG submessages; each fragment is sent as a separate
    /// UDP datagram.  Set to (MTU − IP − UDP − RTPS − security header overhead)
    /// to avoid IP-level fragmentation; MTU-aware auto-calculation is a future
    /// feature.  Valid range: 1..65535 (fragment_size field is u16 in the spec).
    fragment_size: u16 = 16384,
};

pub const TransportConfig = struct {
    udp: UdpConfig = .{},
    tcp: TcpConfig = .{},
};

pub const TcpConfig = struct {
    /// Interface address to bind the listen socket to. "" = INADDR_ANY (all interfaces).
    bind_address: []const u8 = "",

    /// When true, attempt to reuse an existing connection to a remote host even if
    /// the locator port differs from the currently connected port. Allows a discovery
    /// connection (to meta port) to carry user data without opening a second stream.
    reuse_connection_by_host: bool = true,
};

pub const UdpConfig = struct {
    enabled: bool = true,

    // ── Address family enables ────────────────────────────────────────────────
    // Families are also auto-detected per interface from assigned addresses.
    // These are hard overrides: false = never use that family even if detected.

    /// Enable IPv4 sockets and multicast.
    ipv4_enabled: bool = true,
    /// Enable IPv6 sockets and multicast.
    ipv6_enabled: bool = true,

    // ── RTPS port formula (§9.6.1.1) ─────────────────────────────────────────
    //   metatraffic_multicast_port = PB + DG * domain_id + D0
    //   metatraffic_unicast_port   = PB + DG * domain_id + PG * participant_id + D1
    //   default_multicast_port     = PB + DG * domain_id + D2
    //   default_unicast_port       = PB + DG * domain_id + PG * participant_id + D3

    /// Port Base (PB). Default per RTPS spec.
    port_base: u16 = 7400,
    /// Domain gain (DG). Default per RTPS spec.
    domain_gain: u16 = 250,
    /// Participant gain (PG). Default per RTPS spec.
    participant_gain: u16 = 2,
    /// Metatraffic multicast offset (D0). Default per RTPS spec.
    meta_multicast_offset: u16 = 0,
    /// Metatraffic unicast offset (D1). Default per RTPS spec.
    meta_unicast_offset: u16 = 10,
    /// Default multicast offset (D2). Default per RTPS spec.
    data_multicast_offset: u16 = 1,
    /// Default unicast offset (D3). Default per RTPS spec.
    data_unicast_offset: u16 = 11,

    // ── Participant ID ────────────────────────────────────────────────────────

    /// Participant ID used in the unicast port formula.
    /// null = auto-assign: derive valid range [min, max] from the formula coefficients
    /// (ensuring no port < 1024 and no port overflows u16), then try IDs sequentially
    /// until a bind succeeds. Returns error if the entire range is exhausted.
    participant_id: ?u32 = null,

    // ── Interface selection ───────────────────────────────────────────────────

    /// List of interface names ("eth0") or specific IP addresses ("192.168.1.5").
    /// Each entry creates sockets for all matching addresses on that interface/IP.
    /// For IPv6, both link-local and global unicast addresses on an interface are used.
    /// Empty = all interfaces that have at least one assigned address.
    interfaces: []const []const u8 = &.{},

    // ── Multicast ─────────────────────────────────────────────────────────────

    /// IPv4 SPDP multicast group. "" disables IPv4 multicast.
    multicast_group_v4: []const u8 = "239.255.0.1",
    /// IPv6 SPDP multicast group. "" disables IPv6 multicast.
    /// ff02::1 = link-local all-nodes (Cyclone DDS default).
    multicast_group_v6: []const u8 = "ff02::1",
    /// IP TTL / IPv6 hop limit for multicast packets.
    multicast_ttl: u8 = 1,

    // ── Port overrides ────────────────────────────────────────────────────────

    /// Override the metatraffic unicast port. null = use RTPS §9.6.1.1 formula.
    /// When set, participant ID auto-assign still runs (needed for `data_unicast_port`
    /// unless also overridden), but the formula result for the meta port is ignored.
    meta_unicast_port: ?u16 = null,
    /// Override the default unicast (user data) port. null = use RTPS formula.
    data_unicast_port: ?u16 = null,
    /// Override the metatraffic multicast port. null = use RTPS formula.
    meta_multicast_port: ?u16 = null,
    /// Override the default multicast (user data) port. null = use RTPS formula.
    data_multicast_port: ?u16 = null,

    // ── Socket binding ────────────────────────────────────────────────────────

    /// false (default) = bind each unicast socket to its interface's IP address.
    ///   Cyclone-style: one socket per interface address; locator list accurately
    ///   reflects each reachable address. Required for correct locator announcements
    ///   on multi-homed hosts.
    /// true = bind unicast sockets to 0.0.0.0 / :: (wildcard).
    ///   Simpler; all interfaces share one socket per port; locator list less precise.
    bind_wildcard: bool = false,

    // ── Initial peers ─────────────────────────────────────────────────────────

    /// List of "ip:port" strings for unicast peers that should be contacted at
    /// startup regardless of multicast discovery.  Useful when multicast is
    /// disabled or unreliable.  Each entry is parsed and added as a reader
    /// locator on the SPDP StatelessWriter during participant.start().
    initial_peers: []const []const u8 = &.{},

    // ── Misc ──────────────────────────────────────────────────────────────────

    /// Receive buffer size hint (bytes). 0 = OS default.
    recv_buffer_size: u32 = 0,

    /// How often the polling InterfaceMonitor re-enumerates interfaces (ms).
    /// Ignored when a platform event-driven monitor is compiled in, or when
    /// interface_monitor = false (build option).
    interface_poll_interval_ms: u32 = 5_000,
};

pub const DiscoveryKind = enum {
    /// RTPS SPDP + SEDP built-in endpoints (default, interoperable).
    spdp,
    /// Read endpoints from a static config file; no network discovery traffic.
    static,
    /// Connect to a centralized discovery broker (future).
    broker,
};

pub const DiscoveryConfig = struct {
    kind: DiscoveryKind = .spdp,

    /// Additional unicast peers to contact directly (for networks without multicast).
    /// Format: "host:port" strings, e.g. "192.168.1.100:7400".
    initial_peers: []const []const u8 = &.{},

    /// Path to static peer config file. Only used when kind = .static.
    static_config_file: []const u8 = "",
};

/// Default QoS values for newly-created entities.
/// Individual entities can override these via the QoS APIs.
pub const QosDefaults = struct {
    reliability_kind: ReliabilityKind = .best_effort,
    durability_kind: DurabilityKind = .volatile_,
    history_kind: HistoryKind = .keep_last,
    history_depth: i32 = 1,
};

// ── Minimal QoS kind enums (full types will live in qos/policy.zig) ──────────

pub const ReliabilityKind = enum(u8) {
    best_effort = 1,
    reliable = 2,
};

pub const DurabilityKind = enum(u8) {
    volatile_ = 0,
    transient_local = 1,
    transient = 2,
    persistent = 3,
};

pub const HistoryKind = enum(u8) {
    keep_last = 0,
    keep_all = 1,
};

// ── Port formula helpers ──────────────────────────────────────────────────────

/// Compute a UDP port using the RTPS §9.6.1.1 formula.
pub fn rtpsPort(udp: *const UdpConfig, domain_id: u32, participant_id: u32, offset: u16) u16 {
    return udp.port_base +
        udp.domain_gain * @as(u16, @intCast(domain_id)) +
        udp.participant_gain * @as(u16, @intCast(participant_id)) +
        offset;
}

pub fn metatrafficMulticastPort(udp: *const UdpConfig, domain_id: u32) u16 {
    return udp.meta_multicast_port orelse
        rtpsPort(udp, domain_id, 0, udp.meta_multicast_offset);
}

pub fn metatrafficUnicastPort(udp: *const UdpConfig, domain_id: u32, participant_id: u32) u16 {
    return udp.meta_unicast_port orelse
        rtpsPort(udp, domain_id, participant_id, udp.meta_unicast_offset);
}

pub fn defaultMulticastPort(udp: *const UdpConfig, domain_id: u32) u16 {
    return udp.data_multicast_port orelse
        rtpsPort(udp, domain_id, 0, udp.data_multicast_offset);
}

pub fn defaultUnicastPort(udp: *const UdpConfig, domain_id: u32, participant_id: u32) u16 {
    return udp.data_unicast_port orelse
        rtpsPort(udp, domain_id, participant_id, udp.data_unicast_offset);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

const std = @import("std");

test "RTPS port formula defaults match spec §9.6.1.1 examples" {
    const udp = UdpConfig{};
    // Domain 0, participant 0: metatraffic multicast = 7400+250*0+0 = 7400
    try std.testing.expectEqual(@as(u16, 7400), metatrafficMulticastPort(&udp, 0));
    // Domain 0, participant 0: metatraffic unicast = 7400+250*0+2*0+10 = 7410
    try std.testing.expectEqual(@as(u16, 7410), metatrafficUnicastPort(&udp, 0, 0));
    // Domain 0, participant 1: metatraffic unicast = 7400+0+2+10 = 7412
    try std.testing.expectEqual(@as(u16, 7412), metatrafficUnicastPort(&udp, 0, 1));
    // Domain 1: metatraffic multicast = 7400+250 = 7650
    try std.testing.expectEqual(@as(u16, 7650), metatrafficMulticastPort(&udp, 1));
}

test "port overrides take precedence over formula" {
    var udp = UdpConfig{};
    udp.meta_multicast_port = 9000;
    udp.meta_unicast_port = 9001;
    udp.data_multicast_port = 9002;
    udp.data_unicast_port = 9003;
    try std.testing.expectEqual(@as(u16, 9000), metatrafficMulticastPort(&udp, 0));
    try std.testing.expectEqual(@as(u16, 9001), metatrafficUnicastPort(&udp, 0, 0));
    try std.testing.expectEqual(@as(u16, 9002), defaultMulticastPort(&udp, 0));
    try std.testing.expectEqual(@as(u16, 9003), defaultUnicastPort(&udp, 0, 0));
    // Overrides are domain/participant-agnostic.
    try std.testing.expectEqual(@as(u16, 9000), metatrafficMulticastPort(&udp, 5));
    try std.testing.expectEqual(@as(u16, 9001), metatrafficUnicastPort(&udp, 5, 3));
}

test "single-port collapse: all four overrides equal" {
    var udp = UdpConfig{};
    udp.meta_multicast_port = 7400;
    udp.meta_unicast_port = 7400;
    udp.data_multicast_port = 7400;
    udp.data_unicast_port = 7400;
    try std.testing.expectEqual(@as(u16, 7400), metatrafficMulticastPort(&udp, 0));
    try std.testing.expectEqual(@as(u16, 7400), metatrafficUnicastPort(&udp, 0, 0));
    try std.testing.expectEqual(@as(u16, 7400), defaultMulticastPort(&udp, 0));
    try std.testing.expectEqual(@as(u16, 7400), defaultUnicastPort(&udp, 0, 0));
}
