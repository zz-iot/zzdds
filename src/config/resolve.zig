//! Configuration resolution.
//!
//! Merges config from all sources in priority order (highest first):
//!   1. Programmatic — Overrides fields passed to resolve()
//!   2. Environment variables — ZZDDS_* prefix
//!   3. Config file — zzdds.toml (searched in order below)
//!   4. Built-in defaults — zero values in schema.Config
//!
//! Config file search order:
//!   $ZZDDS_CONFIG  (if set)
//!   ./zzdds.toml
//!   ~/.config/zzdds/config.toml  ($HOME env var)
//!
//! Usage:
//!   var arena = std.heap.ArenaAllocator.init(allocator);
//!   defer arena.deinit();
//!   const cfg = try resolve.resolve(arena.allocator(), .{
//!       .domain_id = 5,         // override domain ID
//!   });
//!   // cfg.* strings are valid until arena.deinit()
//!
//! Limitation: programmatic Overrides cannot express "override to the default value"
//! for fields that are also the default.  This is intentional — if you need that,
//! don't use an Overrides and instead modify the returned Config directly.

const std = @import("std");
const builtin = @import("builtin");
const schema = @import("schema.zig");
const file = @import("file.zig");

// ── Overrides ─────────────────────────────────────────────────────────────────

/// Programmatic overrides. Non-null fields override all lower-priority sources.
pub const Overrides = struct {
    // [domain]
    domain_id: ?u32 = null,

    // [participant]
    participant_name: ?[]const u8 = null,
    participant_lease_duration_ms: ?u32 = null,
    participant_announcement_period_ms: ?u32 = null,
    participant_guid_strategy: ?schema.GuidStrategy = null,

    // [transport.udp]
    udp_enabled: ?bool = null,
    udp_ipv4_enabled: ?bool = null,
    udp_ipv6_enabled: ?bool = null,
    udp_port_base: ?u16 = null,
    udp_domain_gain: ?u16 = null,
    udp_participant_gain: ?u16 = null,
    udp_meta_multicast_offset: ?u16 = null,
    udp_meta_unicast_offset: ?u16 = null,
    udp_data_multicast_offset: ?u16 = null,
    udp_data_unicast_offset: ?u16 = null,
    /// Override participant_id. null = do not override (NOT the same as auto-assign).
    udp_participant_id: ?u32 = null,
    udp_interfaces: ?[]const []const u8 = null,
    udp_multicast_group_v4: ?[]const u8 = null,
    udp_multicast_group_v6: ?[]const u8 = null,
    udp_multicast_ttl: ?u8 = null,
    udp_bind_wildcard: ?bool = null,
    udp_recv_buffer_size: ?u32 = null,
    udp_interface_poll_interval_ms: ?u32 = null,

    // [discovery]
    discovery_kind: ?schema.DiscoveryKind = null,
    discovery_initial_peers: ?[]const []const u8 = null,
    discovery_static_config_file: ?[]const u8 = null,

    // [qos.defaults]
    qos_reliability: ?schema.ReliabilityKind = null,
    qos_durability: ?schema.DurabilityKind = null,
    qos_history_kind: ?schema.HistoryKind = null,
    qos_history_depth: ?i32 = null,
};

// ── resolve() ─────────────────────────────────────────────────────────────────

/// Resolve config from all sources.  Pass an ArenaAllocator for simple lifetime management.
pub fn resolve(allocator: std.mem.Allocator, overrides: Overrides) !schema.Config {
    var cfg = schema.Config{};

    // Layer 1: config file
    var home_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    if (findConfigFile(&home_buf)) |path| {
        file.load(allocator, &cfg, path) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied => {}, // silently skip
            else => |e| return e,
        };
    }

    // Layer 2: environment variables
    applyEnv(allocator, &cfg);

    // Layer 3: programmatic overrides
    applyOverrides(&cfg, overrides);

    return cfg;
}

// ── Config file search ────────────────────────────────────────────────────────

fn findConfigFile(home_buf: []u8) ?[]const u8 {
    if (std.c.getenv("ZZDDS_CONFIG")) |p| return std.mem.span(p);

    const io = std.Io.Threaded.global_single_threaded.io();

    if (std.Io.Dir.cwd().openFile(io, "zzdds.toml", .{})) |f| {
        f.close(io);
        return "zzdds.toml";
    } else |_| {}

    if (std.c.getenv("HOME")) |home_ptr| {
        const home = std.mem.span(home_ptr);
        const path = std.fmt.bufPrint(home_buf, "{s}/.config/zzdds/config.toml", .{home}) catch return null;
        if (std.Io.Dir.cwd().openFile(io, path, .{})) |f| {
            f.close(io);
            return path;
        } else |_| {}
    }

    return null;
}

// ── Environment variables ─────────────────────────────────────────────────────

/// Apply ZZDDS_* env vars to cfg.  Invalid values are silently ignored.
/// Allocated strings (names, paths) are duped into allocator.
fn applyEnv(allocator: std.mem.Allocator, cfg: *schema.Config) void {
    // [domain]
    if (envU32("ZZDDS_DOMAIN_ID")) |v| cfg.domain.id = v;

    // [participant]
    if (envStr("ZZDDS_PARTICIPANT_NAME")) |v| cfg.participant.name = allocator.dupe(u8, v) catch return;
    if (envU32("ZZDDS_PARTICIPANT_LEASE_DURATION_MS")) |v| cfg.participant.lease_duration_ms = v;
    if (envU32("ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS")) |v| cfg.participant.announcement_period_ms = v;
    if (envStr("ZZDDS_PARTICIPANT_GUID_STRATEGY")) |v| {
        if (std.mem.eql(u8, v, "random")) cfg.participant.guid_strategy = .random else if (std.mem.eql(u8, v, "host_based")) cfg.participant.guid_strategy = .host_based;
    }

    // [transport.udp]
    if (envBool("ZZDDS_TRANSPORT_UDP_ENABLED")) |v| cfg.transport.udp.enabled = v;
    if (envBool("ZZDDS_TRANSPORT_UDP_IPV4_ENABLED")) |v| cfg.transport.udp.ipv4_enabled = v;
    if (envBool("ZZDDS_TRANSPORT_UDP_IPV6_ENABLED")) |v| cfg.transport.udp.ipv6_enabled = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_PORT_BASE")) |v| cfg.transport.udp.port_base = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_DOMAIN_GAIN")) |v| cfg.transport.udp.domain_gain = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_PARTICIPANT_GAIN")) |v| cfg.transport.udp.participant_gain = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_META_MULTICAST_OFFSET")) |v| cfg.transport.udp.meta_multicast_offset = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_META_UNICAST_OFFSET")) |v| cfg.transport.udp.meta_unicast_offset = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_DATA_MULTICAST_OFFSET")) |v| cfg.transport.udp.data_multicast_offset = v;
    if (envU16("ZZDDS_TRANSPORT_UDP_DATA_UNICAST_OFFSET")) |v| cfg.transport.udp.data_unicast_offset = v;
    if (envU32("ZZDDS_TRANSPORT_UDP_PARTICIPANT_ID")) |v| cfg.transport.udp.participant_id = v;
    if (envStr("ZZDDS_TRANSPORT_UDP_MULTICAST_GROUP_V4")) |v| cfg.transport.udp.multicast_group_v4 = allocator.dupe(u8, v) catch return;
    if (envStr("ZZDDS_TRANSPORT_UDP_MULTICAST_GROUP_V6")) |v| cfg.transport.udp.multicast_group_v6 = allocator.dupe(u8, v) catch return;
    if (envU8("ZZDDS_TRANSPORT_UDP_MULTICAST_TTL")) |v| cfg.transport.udp.multicast_ttl = v;
    if (envBool("ZZDDS_TRANSPORT_UDP_BIND_WILDCARD")) |v| cfg.transport.udp.bind_wildcard = v;
    if (envU32("ZZDDS_TRANSPORT_UDP_RECV_BUFFER_SIZE")) |v| cfg.transport.udp.recv_buffer_size = v;
    if (envU32("ZZDDS_TRANSPORT_UDP_INTERFACE_POLL_INTERVAL_MS")) |v| cfg.transport.udp.interface_poll_interval_ms = v;

    // [discovery]
    if (envStr("ZZDDS_DISCOVERY_KIND")) |v| {
        if (std.mem.eql(u8, v, "spdp")) cfg.discovery.kind = .spdp else if (std.mem.eql(u8, v, "static")) cfg.discovery.kind = .static else if (std.mem.eql(u8, v, "broker")) cfg.discovery.kind = .broker;
    }
    if (envStr("ZZDDS_DISCOVERY_STATIC_CONFIG_FILE")) |v| cfg.discovery.static_config_file = allocator.dupe(u8, v) catch return;

    // [qos.defaults]
    if (envStr("ZZDDS_QOS_RELIABILITY")) |v| {
        if (std.mem.eql(u8, v, "best_effort")) cfg.qos.reliability_kind = .best_effort else if (std.mem.eql(u8, v, "reliable")) cfg.qos.reliability_kind = .reliable;
    }
    if (envStr("ZZDDS_QOS_DURABILITY")) |v| {
        if (std.mem.eql(u8, v, "volatile")) cfg.qos.durability_kind = .volatile_ else if (std.mem.eql(u8, v, "transient_local")) cfg.qos.durability_kind = .transient_local else if (std.mem.eql(u8, v, "transient")) cfg.qos.durability_kind = .transient else if (std.mem.eql(u8, v, "persistent")) cfg.qos.durability_kind = .persistent;
    }
    if (envStr("ZZDDS_QOS_HISTORY_KIND")) |v| {
        if (std.mem.eql(u8, v, "keep_last")) cfg.qos.history_kind = .keep_last else if (std.mem.eql(u8, v, "keep_all")) cfg.qos.history_kind = .keep_all;
    }
    if (envI32("ZZDDS_QOS_HISTORY_DEPTH")) |v| cfg.qos.history_depth = v;
}

// ── Programmatic overrides ────────────────────────────────────────────────────

fn applyOverrides(cfg: *schema.Config, ov: Overrides) void {
    if (ov.domain_id) |v| cfg.domain.id = v;
    if (ov.participant_name) |v| cfg.participant.name = v;
    if (ov.participant_lease_duration_ms) |v| cfg.participant.lease_duration_ms = v;
    if (ov.participant_announcement_period_ms) |v| cfg.participant.announcement_period_ms = v;
    if (ov.participant_guid_strategy) |v| cfg.participant.guid_strategy = v;
    if (ov.udp_enabled) |v| cfg.transport.udp.enabled = v;
    if (ov.udp_ipv4_enabled) |v| cfg.transport.udp.ipv4_enabled = v;
    if (ov.udp_ipv6_enabled) |v| cfg.transport.udp.ipv6_enabled = v;
    if (ov.udp_port_base) |v| cfg.transport.udp.port_base = v;
    if (ov.udp_domain_gain) |v| cfg.transport.udp.domain_gain = v;
    if (ov.udp_participant_gain) |v| cfg.transport.udp.participant_gain = v;
    if (ov.udp_meta_multicast_offset) |v| cfg.transport.udp.meta_multicast_offset = v;
    if (ov.udp_meta_unicast_offset) |v| cfg.transport.udp.meta_unicast_offset = v;
    if (ov.udp_data_multicast_offset) |v| cfg.transport.udp.data_multicast_offset = v;
    if (ov.udp_data_unicast_offset) |v| cfg.transport.udp.data_unicast_offset = v;
    if (ov.udp_participant_id) |v| cfg.transport.udp.participant_id = v;
    if (ov.udp_interfaces) |v| cfg.transport.udp.interfaces = v;
    if (ov.udp_multicast_group_v4) |v| cfg.transport.udp.multicast_group_v4 = v;
    if (ov.udp_multicast_group_v6) |v| cfg.transport.udp.multicast_group_v6 = v;
    if (ov.udp_multicast_ttl) |v| cfg.transport.udp.multicast_ttl = v;
    if (ov.udp_bind_wildcard) |v| cfg.transport.udp.bind_wildcard = v;
    if (ov.udp_recv_buffer_size) |v| cfg.transport.udp.recv_buffer_size = v;
    if (ov.udp_interface_poll_interval_ms) |v| cfg.transport.udp.interface_poll_interval_ms = v;
    if (ov.discovery_kind) |v| cfg.discovery.kind = v;
    if (ov.discovery_initial_peers) |v| cfg.discovery.initial_peers = v;
    if (ov.discovery_static_config_file) |v| cfg.discovery.static_config_file = v;
    if (ov.qos_reliability) |v| cfg.qos.reliability_kind = v;
    if (ov.qos_durability) |v| cfg.qos.durability_kind = v;
    if (ov.qos_history_kind) |v| cfg.qos.history_kind = v;
    if (ov.qos_history_depth) |v| cfg.qos.history_depth = v;
}

// ── Env var helpers ───────────────────────────────────────────────────────────

fn envStr(comptime name: [:0]const u8) ?[]const u8 {
    const p = std.c.getenv(name) orelse return null;
    return std.mem.span(p);
}

fn envBool(comptime name: [:0]const u8) ?bool {
    const v = envStr(name) orelse return null;
    if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "1")) return true;
    if (std.mem.eql(u8, v, "false") or std.mem.eql(u8, v, "0")) return false;
    return null; // invalid → ignore
}

fn envU8(comptime name: [:0]const u8) ?u8 {
    const v = envStr(name) orelse return null;
    return std.fmt.parseInt(u8, v, 10) catch null;
}

fn envU16(comptime name: [:0]const u8) ?u16 {
    const v = envStr(name) orelse return null;
    return std.fmt.parseInt(u16, v, 10) catch null;
}

fn envU32(comptime name: [:0]const u8) ?u32 {
    const v = envStr(name) orelse return null;
    return std.fmt.parseInt(u32, v, 10) catch null;
}

fn envI32(comptime name: [:0]const u8) ?i32 {
    const v = envStr(name) orelse return null;
    return std.fmt.parseInt(i32, v, 10) catch null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "resolve pure defaults (no file, no env)" {
    // No config file in the test environment; env vars not set.
    // Should return the schema defaults.
    const cfg = try resolve(std.testing.allocator, .{});
    const expected = schema.Config{};
    try std.testing.expectEqual(expected.domain.id, cfg.domain.id);
    try std.testing.expectEqual(expected.participant.lease_duration_ms, cfg.participant.lease_duration_ms);
    try std.testing.expectEqual(expected.transport.udp.port_base, cfg.transport.udp.port_base);
    try std.testing.expectEqual(expected.discovery.kind, cfg.discovery.kind);
}

test "resolve programmatic overrides win" {
    var cfg = try resolve(std.testing.allocator, .{
        .domain_id = 42,
        .udp_port_base = 9000,
        .discovery_kind = .static,
    });
    _ = &cfg;
    try std.testing.expectEqual(@as(u32, 42), cfg.domain.id);
    try std.testing.expectEqual(@as(u16, 9000), cfg.transport.udp.port_base);
    try std.testing.expectEqual(schema.DiscoveryKind.static, cfg.discovery.kind);
    // non-overridden fields stay at defaults
    const defaults = schema.Config{};
    try std.testing.expectEqual(defaults.participant.lease_duration_ms, cfg.participant.lease_duration_ms);
}

test "resolve: file parse then programmatic override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Apply file directly and then override programmatically (simulating resolve internals)
    var cfg = schema.Config{};
    const toml =
        \\[domain]
        \\id = 5
        \\[participant]
        \\lease_duration_ms = 30000
    ;
    try file.apply(arena.allocator(), &cfg, toml);
    applyOverrides(&cfg, .{ .domain_id = 99 });

    try std.testing.expectEqual(@as(u32, 99), cfg.domain.id); // overridden
    try std.testing.expectEqual(@as(u32, 30000), cfg.participant.lease_duration_ms); // from file
}

test "applyOverrides: null fields leave cfg unchanged" {
    var cfg = schema.Config{};
    cfg.domain.id = 7;
    applyOverrides(&cfg, .{}); // all null
    try std.testing.expectEqual(@as(u32, 7), cfg.domain.id);
}

// ── Environment variable precedence tests ─────────────────────────────────────
//
// Use OS-specific APIs to mutate the process environment for tests.
// Tests are sequential (no parallelism in a single test binary) so
// env-var mutation is safe as long as each test cleans up with `defer TestEnv.unset`.

const TestEnv = if (builtin.os.tag == .windows) struct {
    // std.c.getenv reads the MSVC CRT's own env cache; SetEnvironmentVariableA
    // only updates the Win32 env block, which the CRT cache never sees.
    // _putenv_s updates the CRT cache directly so getenv() picks up the change.
    extern "c" fn _putenv_s(varname: [*:0]const u8, value_string: [*:0]const u8) c_int;

    fn set(name: [*:0]const u8, value: [*:0]const u8) void {
        _ = _putenv_s(name, value);
    }
    fn unset(name: [*:0]const u8) void {
        _ = _putenv_s(name, ""); // empty value removes the variable from the CRT cache
    }
} else struct {
    extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    extern "c" fn unsetenv(name: [*:0]const u8) c_int;

    fn set(name: [*:0]const u8, value: [*:0]const u8) void {
        _ = setenv(name, value, 1);
    }
    fn unset(name: [*:0]const u8) void {
        _ = unsetenv(name);
    }
};

test "applyEnv: ZZDDS_DOMAIN_ID sets domain.id" {
    TestEnv.set("ZZDDS_DOMAIN_ID", "77");
    defer TestEnv.unset("ZZDDS_DOMAIN_ID");
    var cfg = schema.Config{};
    applyEnv(std.testing.allocator, &cfg);
    try std.testing.expectEqual(@as(u32, 77), cfg.domain.id);
}

test "applyEnv: ZZDDS_DISCOVERY_KIND=static" {
    TestEnv.set("ZZDDS_DISCOVERY_KIND", "static");
    defer TestEnv.unset("ZZDDS_DISCOVERY_KIND");
    var cfg = schema.Config{};
    applyEnv(std.testing.allocator, &cfg);
    try std.testing.expectEqual(schema.DiscoveryKind.static, cfg.discovery.kind);
}

test "applyEnv: ZZDDS_QOS_RELIABILITY=reliable" {
    TestEnv.set("ZZDDS_QOS_RELIABILITY", "reliable");
    defer TestEnv.unset("ZZDDS_QOS_RELIABILITY");
    var cfg = schema.Config{};
    applyEnv(std.testing.allocator, &cfg);
    try std.testing.expectEqual(schema.ReliabilityKind.reliable, cfg.qos.reliability_kind);
}

test "applyEnv: ZZDDS_TRANSPORT_UDP_IPV6_ENABLED=false" {
    TestEnv.set("ZZDDS_TRANSPORT_UDP_IPV6_ENABLED", "false");
    defer TestEnv.unset("ZZDDS_TRANSPORT_UDP_IPV6_ENABLED");
    var cfg = schema.Config{};
    cfg.transport.udp.ipv6_enabled = true;
    applyEnv(std.testing.allocator, &cfg);
    try std.testing.expectEqual(false, cfg.transport.udp.ipv6_enabled);
}

test "applyEnv: invalid numeric value is silently ignored" {
    TestEnv.set("ZZDDS_DOMAIN_ID", "not_a_number");
    defer TestEnv.unset("ZZDDS_DOMAIN_ID");
    var cfg = schema.Config{};
    cfg.domain.id = 5;
    applyEnv(std.testing.allocator, &cfg);
    try std.testing.expectEqual(@as(u32, 5), cfg.domain.id); // unchanged
}

test "resolve: env overrides default; programmatic override wins over env" {
    TestEnv.set("ZZDDS_DOMAIN_ID", "15");
    defer TestEnv.unset("ZZDDS_DOMAIN_ID");
    {
        // env alone: should see 15
        const cfg = try resolve(std.testing.allocator, .{});
        try std.testing.expectEqual(@as(u32, 15), cfg.domain.id);
    }
    {
        // programmatic override beats env
        const cfg = try resolve(std.testing.allocator, .{ .domain_id = 99 });
        try std.testing.expectEqual(@as(u32, 99), cfg.domain.id);
    }
}
