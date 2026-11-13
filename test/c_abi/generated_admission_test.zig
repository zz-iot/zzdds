const std = @import("std");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const Fixture = @import("typesupport_test.zig").Fixture;
extern fn Ingress_Keyed_process_sample_from_cdr([*]const u8, usize, c_int, *[16]u8) callconv(.c) c_int;
extern fn Ingress_Keyless_process_sample_from_cdr([*]const u8, usize, c_int, *[16]u8) callconv(.c) c_int;
extern fn Ingress_Evolving_process_sample_from_cdr([*]const u8, usize, c_int, *[16]u8) callconv(.c) c_int;
const good = [_]u8{ 0, 7, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 0xa0, 0, 0, 0, 0, 10, 0, 0, 0x20, 42, 0, 0, 0 };
const bad = [_]u8{ 0, 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
const bad_keyless = [_]u8{ 0, 7, 0, 0, 0, 0, 0, 0 };
fn makeGuid(value: u8, kind: u8) zzdds.rtps.Guid {
    return .{ .prefix = .{ .bytes = @splat(value) }, .entity_id = .{ .entity_key = .{ 0, 0, value }, .entity_kind = kind } };
}

test "generated checked callbacks validate keyed and keyless samples before actual reader history" {
    const Case = struct { name: [:0]const u8, callback: zzdds.c_abi.typesupport.ZzddsProcessSampleFn, keyed: c_int, invalid: []const u8, valid: []const u8 };
    var keyless_good: [24]u8 = undefined;
    @memcpy(keyless_good[0..4], good[0..4]);
    @memcpy(keyless_good[4..24], good[8..28]);
    for ([_]Case{ .{ .name = "CheckedKeyed", .callback = Ingress_Keyed_process_sample_from_cdr, .keyed = 1, .invalid = &bad, .valid = &good }, .{ .name = "CheckedKeyless", .callback = Ingress_Keyless_process_sample_from_cdr, .keyed = 0, .invalid = &bad_keyless, .valid = &keyless_good } }) |case| {
        var fx = try Fixture.init(testing.allocator);
        defer fx.deinit();
        try testing.expectEqual(@as(c_int, 0), zzdds.c_abi.typesupport.zzdds_register_type_support_checked(fx.dp_boxed, case.name, case.callback, case.keyed, null));
        const topic = fx.dp.create_topic("WireAdmission", case.name, .{}, null, 0);
        const sub = fx.dp.create_subscriber(.{}, null, 0);
        const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
        const dr = sub.create_datareader(td, .{}, null, 0);
        const impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(dr.ptr));
        var it = fx.impl().active_readers.valueIterator();
        var protocol: ?zzdds.protocol.ProtocolReader = null;
        while (it.next()) |entry| if (std.mem.eql(u8, entry.type_name, case.name)) {
            try testing.expectEqual(@as(u8, if (case.keyed == 1) 7 else 4), entry.guid.entity_id.entity_kind);
            protocol = entry.proto;
        };
        const publisher = fx.dp.create_publisher(.{}, null, 0);
        const dw = publisher.create_datawriter(topic, .{}, null, 0);
        try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
        var writers = fx.impl().active_writers.valueIterator();
        var found_writer = false;
        while (writers.next()) |entry| if (std.mem.eql(u8, entry.type_name, case.name)) {
            try testing.expectEqual(@as(u8, if (case.keyed == 1) 2 else 3), entry.guid.entity_id.entity_kind);
            found_writer = true;
        };
        try testing.expect(found_writer);
        const pr = protocol.?;
        const writer = makeGuid(66, if (case.keyed == 1) 2 else 3);
        _ = try pr.addMatchedWriter(&.{ .guid = writer, .unicast_locators = &.{}, .multicast_locators = &.{}, .reliability = .best_effort });
        pr.handleIncomingChange(writer, 1, .zero, @splat(0xcc), case.invalid, .alive, null, null, null, null);
        try testing.expectEqual(@as(usize, 0), impl.pending.items.len);
        pr.handleIncomingChange(writer, 1, .zero, @splat(0xcc), case.valid, .alive, null, null, null, null);
        try testing.expectEqual(@as(usize, 1), impl.pending.items.len);
    }
}
test "generated admission keeps evolution defaults and validates genuine key-only shapes" {
    var hash: [16]u8 = @splat(0xa5);
    const empty_mutable = [_]u8{ 0, 11, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(c_int, 0), Ingress_Evolving_process_sample_from_cdr(&empty_mutable, empty_mutable.len, 0, &hash));
    try testing.expect(std.mem.allEqual(u8, &hash, 0));
    const key_only = [_]u8{ 0, 7, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(c_int, 0), Ingress_Keyed_process_sample_from_cdr(&key_only, key_only.len, 1, &hash));
    @memset(&hash, 0xa5);
    try testing.expect(Ingress_Keyed_process_sample_from_cdr(&key_only, key_only.len, 0, &hash) != 0);
    try testing.expect(std.mem.allEqual(u8, &hash, 0xa5));
    var unknown_mu = good;
    unknown_mu[20] = 50;
    unknown_mu[23] = 0xa0;
    try testing.expect(Ingress_Keyed_process_sample_from_cdr(&unknown_mu, unknown_mu.len, 0, &hash) != 0);
}
