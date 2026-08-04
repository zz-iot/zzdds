//! Adapter between generated zzdds extension IDL config types and the internal
//! runtime configuration schema.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const ext = @import("zzdds_ext_generated").zzdds;
const schema = @import("schema.zig");

pub const DomainParticipantConfig = ext.DomainParticipantConfig;

pub fn toRuntimeConfig(allocator: std.mem.Allocator, cfg: *const ext.DomainParticipantConfig) !schema.Config {
    var runtime = schema.Config{};
    // Zero non-empty string defaults BEFORE errdefer so deinitRuntimeConfig
    // won't call free() on read-only literals if we fail early.
    runtime.participant.timer_clock_name = "";
    runtime.transport.udp.multicast_group_v4 = "";
    runtime.transport.udp.multicast_group_v6 = "";
    errdefer deinitRuntimeConfig(allocator, &runtime);

    runtime.domain.id = cfg.domain.id;
    // Assign sequentially so that errdefer sees each duped string as it lands.
    runtime.participant.name = try dupeString(allocator, cfg.participant.name);
    runtime.participant.lease_duration_ms = cfg.participant.lease_duration_ms;
    runtime.participant.announcement_period_ms = cfg.participant.announcement_period_ms;
    runtime.participant.guid_strategy = toGuidStrategy(cfg.participant.guid_strategy);
    runtime.participant.timer_clock_name = try dupeString(allocator, cfg.participant.timer_clock_name);
    runtime.transport.udp = try toUdpConfig(allocator, &cfg.transport.udp);
    runtime.transport.tcp.enabled = cfg.transport.tcp.enabled;
    runtime.transport.tcp.bind_address = try dupeString(allocator, cfg.transport.tcp.bind_address);
    runtime.transport.tcp.reuse_connection_by_host = cfg.transport.tcp.reuse_connection_by_host;
    runtime.rtps.fragment_size = cfg.rtps.fragment_size;
    runtime.discovery.kind = toDiscoveryKind(cfg.discovery.kind);
    runtime.discovery.initial_peers = try stringSeqSlice(allocator, &cfg.discovery.initial_peers);
    runtime.discovery.static_config_file = try dupeString(allocator, cfg.discovery.static_config_file);
    // Writer/reader creation (participant.zig's HistoryCache sizing) reads
    // this back as `@bitCast(qos.history.depth)` into a u32 -- a non-positive
    // signed depth reinterprets as a huge unsigned limit, silently disabling
    // KEEP_LAST eviction instead of erroring, so reject it here at the config
    // boundary rather than let a bad TOML value reach a live entity.
    if (cfg.qos.history_depth <= 0) return error.InvalidValue;
    runtime.qos = .{
        .reliability_kind = toReliabilityKind(cfg.qos.reliability_kind),
        .durability_kind = toDurabilityKind(cfg.qos.durability_kind),
        .history_kind = toHistoryKind(cfg.qos.history_kind),
        .history_depth = cfg.qos.history_depth,
    };
    return runtime;
}

pub fn deinitRuntimeConfig(allocator: std.mem.Allocator, cfg: *schema.Config) void {
    if (cfg.participant.name.len != 0) allocator.free(cfg.participant.name);
    if (cfg.participant.timer_clock_name.len != 0) allocator.free(cfg.participant.timer_clock_name);
    if (cfg.transport.tcp.bind_address.len != 0) allocator.free(cfg.transport.tcp.bind_address);
    if (cfg.transport.udp.multicast_group_v4.len != 0) allocator.free(cfg.transport.udp.multicast_group_v4);
    if (cfg.transport.udp.multicast_group_v6.len != 0) allocator.free(cfg.transport.udp.multicast_group_v6);
    if (cfg.transport.udp.interfaces.len != 0) freeStringSlice(allocator, cfg.transport.udp.interfaces);
    if (cfg.transport.udp.initial_peers.len != 0) freeStringSlice(allocator, cfg.transport.udp.initial_peers);
    if (cfg.discovery.initial_peers.len != 0) freeStringSlice(allocator, cfg.discovery.initial_peers);
    if (cfg.discovery.static_config_file.len != 0) allocator.free(cfg.discovery.static_config_file);
    // Zero only the heap-owning fields so a second deinit call is safe (len == 0
    // means the guards above skip the free).  Cannot use std.mem.zeroes(schema.Config)
    // because ReliabilityKind has no tag with value 0.
    cfg.participant.name = "";
    cfg.participant.timer_clock_name = "";
    cfg.transport.tcp.bind_address = "";
    cfg.transport.udp.multicast_group_v4 = "";
    cfg.transport.udp.multicast_group_v6 = "";
    cfg.transport.udp.interfaces = &.{};
    cfg.transport.udp.initial_peers = &.{};
    cfg.discovery.initial_peers = &.{};
    cfg.discovery.static_config_file = "";
}

fn freeStringSlice(allocator: std.mem.Allocator, slice: []const []const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

fn toUdpConfig(allocator: std.mem.Allocator, udp: *const ext.UdpConfig) !schema.UdpConfig {
    // Non-allocating fields in a struct literal; allocating fields start empty
    // so the errdefer below won't free literals on early failure.
    var result = schema.UdpConfig{
        .enabled = udp.enabled,
        .ipv4_enabled = udp.ipv4_enabled,
        .ipv6_enabled = udp.ipv6_enabled,
        .port_base = udp.port_base,
        .domain_gain = udp.domain_gain,
        .participant_gain = udp.participant_gain,
        .meta_multicast_offset = udp.meta_multicast_offset,
        .meta_unicast_offset = udp.meta_unicast_offset,
        .data_multicast_offset = udp.data_multicast_offset,
        .data_unicast_offset = udp.data_unicast_offset,
        .participant_id = udp.participant_id,
        .multicast_ttl = udp.multicast_ttl,
        .meta_unicast_port = udp.meta_unicast_port,
        .data_unicast_port = udp.data_unicast_port,
        .meta_multicast_port = udp.meta_multicast_port,
        .data_multicast_port = udp.data_multicast_port,
        .bind_wildcard = udp.bind_wildcard,
        .recv_buffer_size = udp.recv_buffer_size,
        .interface_poll_interval_ms = udp.interface_poll_interval_ms,
        .interfaces = &.{},
        .multicast_group_v4 = "",
        .multicast_group_v6 = "",
        .initial_peers = &.{},
    };
    errdefer {
        if (result.interfaces.len != 0) freeStringSlice(allocator, result.interfaces);
        if (result.multicast_group_v4.len != 0) allocator.free(result.multicast_group_v4);
        if (result.multicast_group_v6.len != 0) allocator.free(result.multicast_group_v6);
        if (result.initial_peers.len != 0) freeStringSlice(allocator, result.initial_peers);
    }
    result.interfaces = try stringSeqSlice(allocator, &udp.interfaces);
    result.multicast_group_v4 = try dupeString(allocator, udp.multicast_group_v4);
    result.multicast_group_v6 = try dupeString(allocator, udp.multicast_group_v6);
    result.initial_peers = try stringSeqSlice(allocator, &udp.initial_peers);
    return result;
}

fn dupeString(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (s.len == 0) return "";
    return allocator.dupe(u8, s);
}

fn stringSeqSlice(allocator: std.mem.Allocator, seq: *const ext.StringSeq) ![]const []const u8 {
    if (seq._length == 0) return &.{};
    const buf = seq._buffer orelse return error.NullBuffer;
    const out = try allocator.alloc([]const u8, seq._length);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (buf[0..seq._length], out) |item, *slot| {
        if (@intFromPtr(item) == 0) return error.NullBuffer;
        slot.* = try allocator.dupe(u8, std.mem.span(item));
        n += 1;
    }
    return out;
}

fn toGuidStrategy(kind: ext.GuidStrategy) schema.GuidStrategy {
    return switch (kind) {
        .GUID_SPEC_RANDOM => .spec_random,
        .GUID_HOST_BASED => .host_based,
        .GUID_FULLY_RANDOM => .fully_random,
        _ => .spec_random,
    };
}

fn toDiscoveryKind(kind: ext.DiscoveryKind) schema.DiscoveryKind {
    return switch (kind) {
        .DISCOVERY_SPDP => .spdp,
        .DISCOVERY_STATIC => .static,
        .DISCOVERY_BROKER => .broker,
        _ => .spdp,
    };
}

fn toReliabilityKind(kind: DDS.ReliabilityQosPolicyKind) schema.ReliabilityKind {
    return switch (kind) {
        .BEST_EFFORT_RELIABILITY_QOS => .best_effort,
        .RELIABLE_RELIABILITY_QOS => .reliable,
        _ => .best_effort,
    };
}

fn toDurabilityKind(kind: DDS.DurabilityQosPolicyKind) schema.DurabilityKind {
    return switch (kind) {
        .VOLATILE_DURABILITY_QOS => .volatile_,
        .TRANSIENT_LOCAL_DURABILITY_QOS => .transient_local,
        .TRANSIENT_DURABILITY_QOS => .transient,
        .PERSISTENT_DURABILITY_QOS => .persistent,
        _ => .volatile_,
    };
}

fn toHistoryKind(kind: DDS.HistoryQosPolicyKind) schema.HistoryKind {
    return switch (kind) {
        .KEEP_LAST_HISTORY_QOS => .keep_last,
        .KEEP_ALL_HISTORY_QOS => .keep_all,
        _ => .keep_last,
    };
}

// ── Reverse mapping: schema.QosDefaults -> real DDS QoS policy fields ────────
//
// Used at Topic/Publisher/Subscriber construction time to seed
// default_topic_qos/default_dw_qos/default_dr_qos from the participant's
// resolved config.qos. This is the only place a config-file QosDefaults value
// can reach a real entity: create_topic/create_datawriter/create_datareader
// always take a caller-supplied literal QoS value in this implementation
// (there is no DATAWRITER_QOS_DEFAULT-style sentinel the create call
// special-cases), so get_default_{topic,datawriter,datareader}_qos() -- which
// an application calls to fetch "the default" before overriding just the
// fields it cares about -- is what actually needs to reflect the config file.

pub fn fromReliabilityKind(kind: schema.ReliabilityKind) DDS.ReliabilityQosPolicyKind {
    return switch (kind) {
        .best_effort => .BEST_EFFORT_RELIABILITY_QOS,
        .reliable => .RELIABLE_RELIABILITY_QOS,
    };
}

pub fn fromDurabilityKind(kind: schema.DurabilityKind) DDS.DurabilityQosPolicyKind {
    return switch (kind) {
        .volatile_ => .VOLATILE_DURABILITY_QOS,
        .transient_local => .TRANSIENT_LOCAL_DURABILITY_QOS,
        .transient => .TRANSIENT_DURABILITY_QOS,
        .persistent => .PERSISTENT_DURABILITY_QOS,
    };
}

pub fn fromHistoryKind(kind: schema.HistoryKind) DDS.HistoryQosPolicyKind {
    return switch (kind) {
        .keep_last => .KEEP_LAST_HISTORY_QOS,
        .keep_all => .KEEP_ALL_HISTORY_QOS,
    };
}

/// Applies to any QoS struct with `.durability.kind`, `.reliability.kind`, and
/// `.history.{kind,depth}` fields -- DDS.TopicQos, DDS.DataWriterQos, and
/// DDS.DataReaderQos all qualify (see idl/dcps.idl); resolved via Zig's
/// comptime duck typing rather than one copy per concrete type.
pub fn applyQosDefaults(qos: anytype, defaults: *const schema.QosDefaults) void {
    qos.durability.kind = fromDurabilityKind(defaults.durability_kind);
    qos.reliability.kind = fromReliabilityKind(defaults.reliability_kind);
    qos.history.kind = fromHistoryKind(defaults.history_kind);
    qos.history.depth = defaults.history_depth;
}

test "generated DomainParticipantConfig defaults convert to runtime defaults" {
    const generated = ext.DomainParticipantConfig.default();
    var runtime = try toRuntimeConfig(std.testing.allocator, &generated);
    defer deinitRuntimeConfig(std.testing.allocator, &runtime);
    try std.testing.expectEqualDeep(schema.Config{}, runtime);
}

test "generated DomainParticipantConfig adapter maps overrides" {
    var generated = ext.DomainParticipantConfig.default();
    generated.domain.id = 42;
    generated.participant.guid_strategy = .GUID_HOST_BASED;
    generated.discovery.kind = .DISCOVERY_STATIC;
    generated.qos.reliability_kind = .RELIABLE_RELIABILITY_QOS;
    generated.qos.history_depth = 8;

    var runtime = try toRuntimeConfig(std.testing.allocator, &generated);
    defer deinitRuntimeConfig(std.testing.allocator, &runtime);
    try std.testing.expectEqual(@as(u32, 42), runtime.domain.id);
    try std.testing.expectEqual(schema.GuidStrategy.host_based, runtime.participant.guid_strategy);
    try std.testing.expectEqual(schema.DiscoveryKind.static, runtime.discovery.kind);
    try std.testing.expectEqual(schema.ReliabilityKind.reliable, runtime.qos.reliability_kind);
    try std.testing.expectEqual(@as(i32, 8), runtime.qos.history_depth);
}

test "generated DomainParticipantConfig adapter rejects non-positive history_depth" {
    // A negative depth fits fine in the schema's i32 field (unlike e.g. an
    // out-of-range port_base, which a natural integer-width overflow already
    // rejects at the TOML-decode layer), so this needs its own explicit
    // check here -- before it reaches a downstream @bitCast to u32 in
    // participant.zig/reader.zig, which would turn -1 into a ~4-billion
    // history limit and silently disable KEEP_LAST eviction.
    var generated = ext.DomainParticipantConfig.default();
    generated.qos.history_depth = -1;
    try std.testing.expectError(error.InvalidValue, toRuntimeConfig(std.testing.allocator, &generated));

    generated.qos.history_depth = 0;
    try std.testing.expectError(error.InvalidValue, toRuntimeConfig(std.testing.allocator, &generated));
}
