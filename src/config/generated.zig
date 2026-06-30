//! Adapter between generated zzdds extension IDL config types and the internal
//! runtime configuration schema.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const ext = @import("zzdds_ext_generated").zzdds;
const schema = @import("schema.zig");

pub const DomainParticipantConfig = ext.DomainParticipantConfig;

pub fn toRuntimeConfig(allocator: std.mem.Allocator, cfg: *const ext.DomainParticipantConfig) !schema.Config {
    var runtime = schema.Config{};
    errdefer deinitRuntimeConfig(allocator, &runtime);

    runtime.domain.id = cfg.domain.id;
    runtime.participant = .{
        .name = cfg.participant.name,
        .lease_duration_ms = cfg.participant.lease_duration_ms,
        .announcement_period_ms = cfg.participant.announcement_period_ms,
        .guid_strategy = toGuidStrategy(cfg.participant.guid_strategy),
        .timer_clock_name = cfg.participant.timer_clock_name,
    };
    runtime.transport = .{
        .udp = try toUdpConfig(allocator, &cfg.transport.udp),
        .tcp = .{
            .bind_address = cfg.transport.tcp.bind_address,
            .reuse_connection_by_host = cfg.transport.tcp.reuse_connection_by_host,
        },
    };
    runtime.rtps.fragment_size = cfg.rtps.fragment_size;
    runtime.discovery = .{
        .kind = toDiscoveryKind(cfg.discovery.kind),
        .initial_peers = try stringSeqSlice(allocator, &cfg.discovery.initial_peers),
        .static_config_file = cfg.discovery.static_config_file,
    };
    runtime.qos = .{
        .reliability_kind = toReliabilityKind(cfg.qos.reliability_kind),
        .durability_kind = toDurabilityKind(cfg.qos.durability_kind),
        .history_kind = toHistoryKind(cfg.qos.history_kind),
        .history_depth = cfg.qos.history_depth,
    };
    return runtime;
}

pub fn deinitRuntimeConfig(allocator: std.mem.Allocator, cfg: *schema.Config) void {
    if (cfg.transport.udp.interfaces.len != 0) allocator.free(cfg.transport.udp.interfaces);
    if (cfg.transport.udp.initial_peers.len != 0) allocator.free(cfg.transport.udp.initial_peers);
    if (cfg.discovery.initial_peers.len != 0) allocator.free(cfg.discovery.initial_peers);
    cfg.* = .{};
}

fn toUdpConfig(allocator: std.mem.Allocator, udp: *const ext.UdpConfig) !schema.UdpConfig {
    return .{
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
        .interfaces = try stringSeqSlice(allocator, &udp.interfaces),
        .multicast_group_v4 = udp.multicast_group_v4,
        .multicast_group_v6 = udp.multicast_group_v6,
        .multicast_ttl = udp.multicast_ttl,
        .meta_unicast_port = udp.meta_unicast_port,
        .data_unicast_port = udp.data_unicast_port,
        .meta_multicast_port = udp.meta_multicast_port,
        .data_multicast_port = udp.data_multicast_port,
        .bind_wildcard = udp.bind_wildcard,
        .initial_peers = try stringSeqSlice(allocator, &udp.initial_peers),
        .recv_buffer_size = udp.recv_buffer_size,
        .interface_poll_interval_ms = udp.interface_poll_interval_ms,
    };
}

fn stringSeqSlice(allocator: std.mem.Allocator, seq: *const ext.StringSeq) ![]const []const u8 {
    if (seq._length == 0) return &.{};
    const buf = seq._buffer orelse return &.{};
    const out = try allocator.alloc([]const u8, seq._length);
    for (buf[0..seq._length], out) |item, *slot| {
        slot.* = std.mem.span(item);
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
