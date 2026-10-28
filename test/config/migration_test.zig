const std = @import("std");
const dds = @import("zzdds");
const resolve = dds.resolve_config;
const testing = std.testing;
const io = std.Io.Threaded.global_single_threaded.io();
const path = "zzdds_migration_test.toml";
fn write(bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}
fn equalValue(comptime T: type, a: T, b: T) !void {
    switch (@typeInfo(T)) {
        .@"struct" => {
            if (@hasField(T, "_buffer") and @hasField(T, "_length")) {
                try testing.expectEqual(a._length, b._length);
                if (a._length != 0) {
                    for (a._buffer.?[0..a._length], b._buffer.?[0..b._length]) |x, y|
                        try equalValue(@TypeOf(x), x, y);
                }
            } else {
                inline for (@typeInfo(T).@"struct".field_names) |name| {
                    if (comptime !std.mem.eql(u8, name, "_toml_applied")) try equalValue(@FieldType(T, name), @field(a, name), @field(b, name));
                }
            }
        },
        .optional => |o| {
            try testing.expectEqual(a == null, b == null);
            if (a) |x| try equalValue(o.child, x, b.?);
        },
        .pointer => |p| if (p.size == .slice) {
            try testing.expectEqualStrings(a, b);
        } else try testing.expectEqualStrings(std.mem.span(a), std.mem.span(b)),
        else => try testing.expectEqual(a, b),
    }
}

test "existing configuration files retain their values" {
    const paths = [_][]const u8{
        "examples/config/ipv4-only.toml",           "examples/config/ipv6-only.toml",
        "examples/config/unicast-only.toml",        "examples/config/tcp-non-discovery.toml",
        "examples/config/short-lease.toml",         "examples/config/custom-ports.toml",
        "examples/c/custom-allocator/zzdds.toml",   "examples/cpp/custom-allocator/zzdds.toml",
        "examples/java/listener-pubsub/zzdds.toml",
    };
    for (paths) |p| {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, p, arena.allocator(), .limited(256 * 1024));
        const table = try dds.toml.parse(arena.allocator(), bytes);
        var old: resolve.ProcessConfig = .{};
        try old.applyToml(testing.allocator, table);
        defer old.deinit(testing.allocator);
        var fresh = try resolve.resolveProcessConfigFrom(testing.allocator, p);
        defer fresh.deinit(testing.allocator);
        try equalValue(resolve.ProcessConfig, old, fresh);
    }
}
test "conditional settings apply or report a skip; ordinary unknowns fail" {
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try write("[transport.udp]\n_port_base=8000\n_future={enabled=true}\n");
    var diagnostic: resolve.ReadDiagnostics = .{};
    defer diagnostic.deinit();
    var value = try resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{}, &diagnostic);
    defer value.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 8000), value.transport.udp.port_base);
    try testing.expectEqual(@as(usize, 1), diagnostic.skipped.len);
    try testing.expectEqualStrings("future", diagnostic.skipped[0].path[2]);
    try testing.expectEqualStrings("_future", diagnostic.skipped[0].input_path[2]);
    try testing.expect(diagnostic.skipped_complete);
    try write("future=true");
    try testing.expectError(error.UnknownField, resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{}, &diagnostic));
    var compatible = try resolve.resolveParticipantConfigFrom(testing.allocator, path);
    defer compatible.deinit(testing.allocator);
    try write("[transport.udp]\n_port_base=999999");
    try testing.expectError(error.InvalidValue, resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{}, &diagnostic));
    try testing.expectEqual(error.OutOfRange, diagnostic.code.?);
    try testing.expectEqualStrings("transport.udp._port_base", diagnostic.fieldPath());
}
test "configuration result and report release every failed allocation" {
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try write("[participant]\nname='owned'\n_future=true\n");
    const Run = struct {
        fn run(a: std.mem.Allocator) !void {
            var diagnostic: resolve.ReadDiagnostics = .{};
            defer diagnostic.deinit();
            var value = try resolve.resolveParticipantConfigFromWithOptions(a, path, .{}, &diagnostic);
            defer value.deinit(a);
            try testing.expectEqualStrings("owned", value.participant.name);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

test "runtime files retain long strings and dense arrays within the file limit" {
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, "[participant]\nname='");
    try bytes.appendNTimes(testing.allocator, 'a', 5000);
    try bytes.appendSlice(testing.allocator, "'\n[transport.udp]\ninterfaces=[");
    for (0..70000) |i| {
        if (i != 0) try bytes.append(testing.allocator, ',');
        try bytes.appendSlice(testing.allocator, "''");
    }
    try bytes.append(testing.allocator, ']');
    try write(bytes.items);
    var diagnostic: resolve.ReadDiagnostics = .{};
    defer diagnostic.deinit();
    var value = try resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{}, &diagnostic);
    defer value.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 5000), value.participant.name.len);
    try testing.expectEqual(@as(u32, 70000), value.transport.udp.interfaces._length);
    var compatible = try resolve.resolveParticipantConfigFrom(testing.allocator, path);
    defer compatible.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 70000), compatible.transport.udp.interfaces._length);
}

test "runtime compatibility enum spelling remains distinct from canonical mode" {
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try write("[participant]\nguid_strategy='guid_spec_random'\n[transport.udp]\nipv6_enabled=false\nparticipant_id=0\ninterfaces=[]\n");
    var compatible = try resolve.resolveParticipantConfigFrom(testing.allocator, path);
    defer compatible.deinit(testing.allocator);
    try testing.expect(!compatible.transport.udp.ipv6_enabled);
    try testing.expectEqual(@as(u32, 0), compatible.transport.udp.participant_id);
    try testing.expectEqual(@as(u32, 0), compatible.transport.udp.interfaces._length);
    var diagnostic: resolve.ReadDiagnostics = .{};
    defer diagnostic.deinit();
    try testing.expectError(error.InvalidValue, resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{ .enum_matching = .canonical }, &diagnostic));
    try testing.expectEqual(error.InvalidEnum, diagnostic.code.?);
}

// Model the shipped custom allocator's per-allocation limit without a C binding.
const SmallBlocks = struct {
    child: std.mem.Allocator,
    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > 4096) return null;
        return self.child.rawAlloc(len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return len <= 4096 and self.child.rawResize(bytes, alignment, len, ra);
    }
    fn remap(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (len > 4096) return null;
        return self.child.rawRemap(bytes, alignment, len, ra);
    }
    fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.child.rawFree(bytes, alignment, ra);
    }
};
test "shipped bootstrap configuration still accepts a 4 KiB block allocator" {
    var blocks = SmallBlocks{ .child = testing.allocator };
    const a = blocks.allocator();
    var value = try resolve.resolveProcessConfigFrom(a, "examples/c/custom-allocator/zzdds.toml");
    defer value.deinit(a);
    try testing.expectEqual(@as(u32, 20000), value.default_participant_config.participant.lease_duration_ms);
    try testing.expectEqual(@as(u32, 0), value.default_participant_config.transport.udp.interface_poll_interval_ms);
}

test "custom nesting limits also constrain skipped conditional sections" {
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};
    try write("_future={ nested={ value=true } }");
    var diagnostic: resolve.ReadDiagnostics = .{};
    defer diagnostic.deinit();
    try testing.expectError(error.LimitExceeded, resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{ .max_depth = 2 }, &diagnostic));
    try testing.expectEqual(error.LimitExceeded, diagnostic.code.?);
    var value = try resolve.resolveParticipantConfigFromWithOptions(testing.allocator, path, .{}, &diagnostic);
    defer value.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), diagnostic.skipped.len);
}
