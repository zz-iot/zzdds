//! TOML config file parser.
//!
//! Parses the subset of TOML used by zzdds.toml and applies found values to
//! a *schema.Config, leaving all other fields at their current value (caller
//! initialises cfg to Config{} for defaults).
//!
//! Supported value types:
//!   string          "hello"         — basic quotes; \\, \", \n, \t escapes
//!   integer         42
//!   boolean         true | false
//!   null            null            — non-standard extension for participant_id
//!   string array    ["a", "b"]      — no embedded commas in element strings
//!
//! Unknown sections and keys are silently ignored (lenient parser).
//! Malformed values return Error.InvalidValue.

const std = @import("std");
const schema = @import("schema.zig");

pub const Error = error{
    InvalidSyntax,
    InvalidValue,
    OutOfMemory,
};

// ── Section state machine ─────────────────────────────────────────────────────

const Section = enum { root, domain, participant, transport_udp, discovery, qos_defaults };

fn parseSection(line: []const u8) ?Section {
    // line is already trimmed; starts with '[', must end with ']'
    if (line.len < 3 or line[line.len - 1] != ']') return null;
    const name = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
    if (eql(name, "domain")) return .domain;
    if (eql(name, "participant")) return .participant;
    if (eql(name, "transport.udp")) return .transport_udp;
    if (eql(name, "discovery")) return .discovery;
    if (eql(name, "qos.defaults")) return .qos_defaults;
    return null; // unknown section → skip
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Parse `src` (TOML) and apply found values to `cfg`.
/// Fields not mentioned in the TOML are left unchanged.
/// Strings are duped into `allocator`; use an arena so all strings share a lifetime.
pub fn apply(allocator: std.mem.Allocator, cfg: *schema.Config, src: []const u8) Error!void {
    var section = Section.root;
    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(std.mem.trim(u8, raw, " \t\r"));
        if (line.len == 0) continue;
        if (line[0] == '[') {
            if (parseSection(line)) |s| section = s;
            // unknown sections silently become .root; their keys will be skipped
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        applyField(allocator, cfg, section, key, val) catch |err| switch (err) {
            error.UnknownKey => {}, // silently skip
            else => |e| return e,
        };
    }
}

/// Read the file at `path` and apply it.
pub fn load(allocator: std.mem.Allocator, cfg: *schema.Config, path: []const u8) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const src = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        std.Io.Limit.limited(256 * 1024),
    );
    defer allocator.free(src);
    return apply(allocator, cfg, src);
}

// ── Field dispatch ────────────────────────────────────────────────────────────

const UnknownKey = error{UnknownKey};

fn applyField(
    allocator: std.mem.Allocator,
    cfg: *schema.Config,
    section: Section,
    key: []const u8,
    val: []const u8,
) (Error || UnknownKey)!void {
    switch (section) {
        .root => return error.UnknownKey,
        .domain => {
            if (eql(key, "id")) {
                cfg.domain.id = try parseU32(val);
            } else return error.UnknownKey;
        },
        .participant => {
            if (eql(key, "name")) {
                cfg.participant.name = try parseString(allocator, val);
            } else if (eql(key, "lease_duration_ms")) {
                cfg.participant.lease_duration_ms = try parseU32(val);
            } else if (eql(key, "announcement_period_ms")) {
                cfg.participant.announcement_period_ms = try parseU32(val);
            } else if (eql(key, "guid_strategy")) {
                cfg.participant.guid_strategy = try parseGuidStrategy(val);
            } else return error.UnknownKey;
        },
        .transport_udp => {
            if (eql(key, "enabled")) {
                cfg.transport.udp.enabled = try parseBool(val);
            } else if (eql(key, "ipv4_enabled")) {
                cfg.transport.udp.ipv4_enabled = try parseBool(val);
            } else if (eql(key, "ipv6_enabled")) {
                cfg.transport.udp.ipv6_enabled = try parseBool(val);
            } else if (eql(key, "port_base")) {
                cfg.transport.udp.port_base = try parseU16(val);
            } else if (eql(key, "domain_gain")) {
                cfg.transport.udp.domain_gain = try parseU16(val);
            } else if (eql(key, "participant_gain")) {
                cfg.transport.udp.participant_gain = try parseU16(val);
            } else if (eql(key, "meta_multicast_offset")) {
                cfg.transport.udp.meta_multicast_offset = try parseU16(val);
            } else if (eql(key, "meta_unicast_offset")) {
                cfg.transport.udp.meta_unicast_offset = try parseU16(val);
            } else if (eql(key, "data_multicast_offset")) {
                cfg.transport.udp.data_multicast_offset = try parseU16(val);
            } else if (eql(key, "data_unicast_offset")) {
                cfg.transport.udp.data_unicast_offset = try parseU16(val);
            } else if (eql(key, "meta_unicast_port")) {
                cfg.transport.udp.meta_unicast_port = try parseOptU16(val);
            } else if (eql(key, "data_unicast_port")) {
                cfg.transport.udp.data_unicast_port = try parseOptU16(val);
            } else if (eql(key, "meta_multicast_port")) {
                cfg.transport.udp.meta_multicast_port = try parseOptU16(val);
            } else if (eql(key, "data_multicast_port")) {
                cfg.transport.udp.data_multicast_port = try parseOptU16(val);
            } else if (eql(key, "participant_id")) {
                cfg.transport.udp.participant_id = try parseOptU32(val);
            } else if (eql(key, "interfaces")) {
                cfg.transport.udp.interfaces = try parseStringArray(allocator, val);
            } else if (eql(key, "multicast_group_v4")) {
                cfg.transport.udp.multicast_group_v4 = try parseString(allocator, val);
            } else if (eql(key, "multicast_group_v6")) {
                cfg.transport.udp.multicast_group_v6 = try parseString(allocator, val);
            } else if (eql(key, "multicast_ttl")) {
                cfg.transport.udp.multicast_ttl = try parseU8(val);
            } else if (eql(key, "bind_wildcard")) {
                cfg.transport.udp.bind_wildcard = try parseBool(val);
            } else if (eql(key, "recv_buffer_size")) {
                cfg.transport.udp.recv_buffer_size = try parseU32(val);
            } else if (eql(key, "interface_poll_interval_ms")) {
                cfg.transport.udp.interface_poll_interval_ms = try parseU32(val);
            } else return error.UnknownKey;
        },
        .discovery => {
            if (eql(key, "kind")) {
                cfg.discovery.kind = try parseDiscoveryKind(val);
            } else if (eql(key, "initial_peers")) {
                cfg.discovery.initial_peers = try parseStringArray(allocator, val);
            } else if (eql(key, "static_config_file")) {
                cfg.discovery.static_config_file = try parseString(allocator, val);
            } else return error.UnknownKey;
        },
        .qos_defaults => {
            if (eql(key, "reliability")) {
                cfg.qos.reliability_kind = try parseReliabilityKind(val);
            } else if (eql(key, "durability")) {
                cfg.qos.durability_kind = try parseDurabilityKind(val);
            } else if (eql(key, "history_kind")) {
                cfg.qos.history_kind = try parseHistoryKind(val);
            } else if (eql(key, "history_depth")) {
                cfg.qos.history_depth = try parseInt(i32, val);
            } else return error.UnknownKey;
        },
    }
}

// ── Value parsers ─────────────────────────────────────────────────────────────

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseU8(val: []const u8) Error!u8 {
    return std.fmt.parseInt(u8, val, 10) catch return Error.InvalidValue;
}

fn parseU16(val: []const u8) Error!u16 {
    return std.fmt.parseInt(u16, val, 10) catch return Error.InvalidValue;
}

fn parseU32(val: []const u8) Error!u32 {
    return std.fmt.parseInt(u32, val, 10) catch return Error.InvalidValue;
}

fn parseInt(comptime T: type, val: []const u8) Error!T {
    return std.fmt.parseInt(T, val, 10) catch return Error.InvalidValue;
}

fn parseOptU32(val: []const u8) Error!?u32 {
    if (eql(val, "null")) return null;
    return try parseU32(val);
}

fn parseOptU16(val: []const u8) Error!?u16 {
    if (eql(val, "null")) return null;
    return try parseU16(val);
}

fn parseBool(val: []const u8) Error!bool {
    if (eql(val, "true")) return true;
    if (eql(val, "false")) return false;
    return Error.InvalidValue;
}

/// Parse a TOML basic string (double-quoted). Handles \\, \", \n, \t, \r.
fn parseString(allocator: std.mem.Allocator, val: []const u8) Error![]const u8 {
    if (val.len < 2 or val[0] != '"' or val[val.len - 1] != '"')
        return Error.InvalidValue;
    const inner = val[1 .. val.len - 1];
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\') {
            if (i + 1 >= inner.len) return Error.InvalidValue;
            switch (inner[i + 1]) {
                '"' => {
                    try buf.append(allocator, '"');
                    i += 2;
                },
                '\\' => {
                    try buf.append(allocator, '\\');
                    i += 2;
                },
                'n' => {
                    try buf.append(allocator, '\n');
                    i += 2;
                },
                't' => {
                    try buf.append(allocator, '\t');
                    i += 2;
                },
                'r' => {
                    try buf.append(allocator, '\r');
                    i += 2;
                },
                else => return Error.InvalidValue,
            }
        } else {
            try buf.append(allocator, inner[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

/// Parse a TOML inline array of basic strings: ["a", "b"].
/// Elements must not contain commas.
fn parseStringArray(allocator: std.mem.Allocator, val: []const u8) Error![]const []const u8 {
    const trimmed = std.mem.trim(u8, val, " \t");
    if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']')
        return Error.InvalidValue;
    const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t");
    if (inner.len == 0) return &.{};

    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }
    var iter = std.mem.splitScalar(u8, inner, ',');
    while (iter.next()) |part| {
        const s = try parseString(allocator, std.mem.trim(u8, part, " \t"));
        try items.append(allocator, s);
    }
    return items.toOwnedSlice(allocator);
}

fn parseEnum(comptime T: type, val: []const u8, map: anytype) Error!T {
    if (val.len < 2 or val[0] != '"' or val[val.len - 1] != '"')
        return Error.InvalidValue;
    const s = val[1 .. val.len - 1];
    inline for (map) |pair| {
        if (eql(s, pair[0])) return pair[1];
    }
    return Error.InvalidValue;
}

fn parseGuidStrategy(val: []const u8) Error!schema.GuidStrategy {
    return parseEnum(schema.GuidStrategy, val, .{
        .{ "spec_random", schema.GuidStrategy.spec_random },
        .{ "host_based", schema.GuidStrategy.host_based },
        .{ "fully_random", schema.GuidStrategy.fully_random },
    });
}

fn parseDiscoveryKind(val: []const u8) Error!schema.DiscoveryKind {
    return parseEnum(schema.DiscoveryKind, val, .{
        .{ "spdp", schema.DiscoveryKind.spdp },
        .{ "static", schema.DiscoveryKind.static },
        .{ "broker", schema.DiscoveryKind.broker },
    });
}

fn parseReliabilityKind(val: []const u8) Error!schema.ReliabilityKind {
    return parseEnum(schema.ReliabilityKind, val, .{
        .{ "best_effort", schema.ReliabilityKind.best_effort },
        .{ "reliable", schema.ReliabilityKind.reliable },
    });
}

fn parseDurabilityKind(val: []const u8) Error!schema.DurabilityKind {
    return parseEnum(schema.DurabilityKind, val, .{
        .{ "volatile", schema.DurabilityKind.volatile_ },
        .{ "transient_local", schema.DurabilityKind.transient_local },
        .{ "transient", schema.DurabilityKind.transient },
        .{ "persistent", schema.DurabilityKind.persistent },
    });
}

fn parseHistoryKind(val: []const u8) Error!schema.HistoryKind {
    return parseEnum(schema.HistoryKind, val, .{
        .{ "keep_last", schema.HistoryKind.keep_last },
        .{ "keep_all", schema.HistoryKind.keep_all },
    });
}

// ── Comment stripping ─────────────────────────────────────────────────────────

/// Strip a TOML comment from a line.  Ignores '#' inside quoted strings.
fn stripComment(line: []const u8) []const u8 {
    var in_string = false;
    for (line, 0..) |c, i| {
        switch (c) {
            '"' => in_string = !in_string,
            '#' => if (!in_string) return trimTrailing(line[0..i], " \t"),
            else => {},
        }
    }
    return line;
}

fn trimTrailing(s: []const u8, chars: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and std.mem.indexOfScalar(u8, chars, s[end - 1]) != null) {
        end -= 1;
    }
    return s[0..end];
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "parse empty input" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg, "");
    try std.testing.expectEqual(schema.Config{}, cfg);
}

test "parse comments and blank lines" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\# This is a comment
        \\
        \\  # indented comment
        \\
    );
    try std.testing.expectEqual(schema.Config{}, cfg);
}

test "parse domain.id" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[domain]
        \\id = 7
    );
    try std.testing.expectEqual(@as(u32, 7), cfg.domain.id);
}

test "parse participant fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = schema.Config{};
    try apply(arena.allocator(), &cfg,
        \\[participant]
        \\name = "my-node"
        \\lease_duration_ms = 20000
        \\announcement_period_ms = 5000
        \\guid_strategy = "host_based"
    );
    try std.testing.expectEqualStrings("my-node", cfg.participant.name);
    try std.testing.expectEqual(@as(u32, 20000), cfg.participant.lease_duration_ms);
    try std.testing.expectEqual(@as(u32, 5000), cfg.participant.announcement_period_ms);
    try std.testing.expectEqual(schema.GuidStrategy.host_based, cfg.participant.guid_strategy);
}

test "parse transport.udp scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = schema.Config{};
    try apply(arena.allocator(), &cfg,
        \\[transport.udp]
        \\enabled = false
        \\ipv6_enabled = false
        \\port_base = 8400
        \\participant_id = 3
        \\multicast_ttl = 5
        \\bind_wildcard = true
        \\recv_buffer_size = 1048576
    );
    try std.testing.expectEqual(false, cfg.transport.udp.enabled);
    try std.testing.expectEqual(false, cfg.transport.udp.ipv6_enabled);
    try std.testing.expectEqual(@as(u16, 8400), cfg.transport.udp.port_base);
    try std.testing.expectEqual(@as(?u32, 3), cfg.transport.udp.participant_id);
    try std.testing.expectEqual(@as(u8, 5), cfg.transport.udp.multicast_ttl);
    try std.testing.expectEqual(true, cfg.transport.udp.bind_wildcard);
    try std.testing.expectEqual(@as(u32, 1048576), cfg.transport.udp.recv_buffer_size);
}

test "parse participant_id = null" {
    var cfg = schema.Config{ .transport = .{ .udp = .{ .participant_id = 99 } } };
    try apply(std.testing.allocator, &cfg,
        \\[transport.udp]
        \\participant_id = null
    );
    try std.testing.expectEqual(@as(?u32, null), cfg.transport.udp.participant_id);
}

test "parse interfaces array" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = schema.Config{};
    try apply(arena.allocator(), &cfg,
        \\[transport.udp]
        \\interfaces = ["eth0", "eth1"]
    );
    try std.testing.expectEqual(@as(usize, 2), cfg.transport.udp.interfaces.len);
    try std.testing.expectEqualStrings("eth0", cfg.transport.udp.interfaces[0]);
    try std.testing.expectEqualStrings("eth1", cfg.transport.udp.interfaces[1]);
}

test "parse empty array" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[transport.udp]
        \\interfaces = []
    );
    try std.testing.expectEqual(@as(usize, 0), cfg.transport.udp.interfaces.len);
}

test "parse discovery fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = schema.Config{};
    try apply(arena.allocator(), &cfg,
        \\[discovery]
        \\kind = "static"
        \\initial_peers = ["192.168.1.1:7400"]
        \\static_config_file = "/etc/zzdds/peers.toml"
    );
    try std.testing.expectEqual(schema.DiscoveryKind.static, cfg.discovery.kind);
    try std.testing.expectEqual(@as(usize, 1), cfg.discovery.initial_peers.len);
    try std.testing.expectEqualStrings("192.168.1.1:7400", cfg.discovery.initial_peers[0]);
    try std.testing.expectEqualStrings("/etc/zzdds/peers.toml", cfg.discovery.static_config_file);
}

test "parse qos.defaults" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[qos.defaults]
        \\reliability = "reliable"
        \\durability = "transient_local"
        \\history_kind = "keep_all"
        \\history_depth = 10
    );
    try std.testing.expectEqual(schema.ReliabilityKind.reliable, cfg.qos.reliability_kind);
    try std.testing.expectEqual(schema.DurabilityKind.transient_local, cfg.qos.durability_kind);
    try std.testing.expectEqual(schema.HistoryKind.keep_all, cfg.qos.history_kind);
    try std.testing.expectEqual(@as(i32, 10), cfg.qos.history_depth);
}

test "unknown sections are skipped" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[future_feature]
        \\some_key = 42
        \\[domain]
        \\id = 3
    );
    try std.testing.expectEqual(@as(u32, 3), cfg.domain.id);
}

test "unknown keys are skipped" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[domain]
        \\id = 2
        \\future_key = "ignored"
    );
    try std.testing.expectEqual(@as(u32, 2), cfg.domain.id);
}

test "unspecified fields keep current value" {
    var cfg = schema.Config{};
    cfg.domain.id = 42;
    try apply(std.testing.allocator, &cfg,
        \\[participant]
        \\lease_duration_ms = 5000
    );
    try std.testing.expectEqual(@as(u32, 42), cfg.domain.id); // unchanged
    try std.testing.expectEqual(@as(u32, 5000), cfg.participant.lease_duration_ms);
}

test "inline comment on value line" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[domain]
        \\id = 9  # nine
    );
    try std.testing.expectEqual(@as(u32, 9), cfg.domain.id);
}

test "string escape sequences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg = schema.Config{};
    try apply(arena.allocator(), &cfg,
        \\[participant]
        \\name = "hello \"world\""
    );
    try std.testing.expectEqualStrings("hello \"world\"", cfg.participant.name);
}

test "parse port overrides" {
    var cfg = schema.Config{};
    try apply(std.testing.allocator, &cfg,
        \\[transport.udp]
        \\meta_unicast_port = 9001
        \\data_unicast_port = 9002
        \\meta_multicast_port = 9003
        \\data_multicast_port = 9004
    );
    try std.testing.expectEqual(@as(?u16, 9001), cfg.transport.udp.meta_unicast_port);
    try std.testing.expectEqual(@as(?u16, 9002), cfg.transport.udp.data_unicast_port);
    try std.testing.expectEqual(@as(?u16, 9003), cfg.transport.udp.meta_multicast_port);
    try std.testing.expectEqual(@as(?u16, 9004), cfg.transport.udp.data_multicast_port);
}

test "parse port override null resets override" {
    var cfg = schema.Config{ .transport = .{ .udp = .{
        .meta_unicast_port = 9001,
        .data_unicast_port = 9002,
        .meta_multicast_port = 9003,
        .data_multicast_port = 9004,
    } } };
    try apply(std.testing.allocator, &cfg,
        \\[transport.udp]
        \\meta_unicast_port = null
        \\data_unicast_port = null
        \\meta_multicast_port = null
        \\data_multicast_port = null
    );
    try std.testing.expectEqual(@as(?u16, null), cfg.transport.udp.meta_unicast_port);
    try std.testing.expectEqual(@as(?u16, null), cfg.transport.udp.data_unicast_port);
    try std.testing.expectEqual(@as(?u16, null), cfg.transport.udp.meta_multicast_port);
    try std.testing.expectEqual(@as(?u16, null), cfg.transport.udp.data_multicast_port);
}
