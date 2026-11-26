//! Read view types over a live reader (zidl --generate-views), in Zig: a
//! writer and a reader in one participant on the real stack, a sample written
//! and taken with the generated take_view, whose view points into the loaned
//! payload until ViewSample.deinit ends the loan.

const std = @import("std");
const testing = std.testing;
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const gen = @import("view_smoke");
const time_mod = zzdds.util.time;

const TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;

fn within(loaned: []const u8, s: []const u8) bool {
    const p = @intFromPtr(s.ptr);
    return p >= @intFromPtr(loaned.ptr) and p + s.len <= @intFromPtr(loaned.ptr) + loaned.len;
}

test "take_view decodes a live sample in place, and its deinit ends the loan" {
    const alloc = testing.allocator;
    const dpf = DDS.DomainParticipantFactory.get_instance();
    try testing.expect(dpf.ptr != zzdds.dcps.NIL_PTR);
    defer testing.expectEqual(DDS.RETCODE_OK, DDS.DomainParticipantFactory.delete_instance()) catch unreachable;
    const dp = dpf.create_participant(test_domain.get(), .{}, null, 0);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    defer {
        testing.expectEqual(DDS.RETCODE_OK, dp.delete_contained_entities()) catch unreachable;
        testing.expectEqual(DDS.RETCODE_OK, dpf.delete_participant(dp)) catch unreachable;
    }
    try testing.expect(gen.ViewSmokeFrameTypeSupport.register(dp, "ViewSmokeFrame", alloc));
    const topic = dp.create_topic("ViewSmokeZig", "ViewSmokeFrame", .{}, null, 0);
    try testing.expect(topic.ptr != zzdds.dcps.NIL_PTR);

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const sub = dp.create_subscriber(.{}, null, 0);
    const dr = sub.create_datareader(dp.lookup_topicdescription("ViewSmokeZig"), dr_qos, null, 0);
    try testing.expect(dr.ptr != zzdds.dcps.NIL_PTR);

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const publisher = dp.create_publisher(.{}, null, 0);
    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);

    // The reader matches before anything is written.
    const match_deadline = time_mod.nanoTimestamp() + TIMEOUT_NS;
    while (true) {
        var status: DDS.PublicationMatchedStatus = undefined;
        try testing.expectEqual(DDS.RETCODE_OK, dw.get_publication_matched_status(&status));
        if (status.current_count >= 1) break;
        try testing.expect(time_mod.nanoTimestamp() < match_deadline);
        time_mod.sleepNs(10 * std.time.ns_per_ms);
    }

    var payload: [64]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast(i * 3);
    var samples = [_]f64{ 1.5, -2.25, 1e300 };
    try gen.ViewSmokeFrameDataWriter.init(dw, alloc).write(.{
        .id = 3,
        .label = "view smoke",
        .payload = .{ ._length = 64, ._maximum = 64, ._buffer = &payload },
        .samples = .{ ._length = 3, ._maximum = 3, ._buffer = &samples },
    }, 0);

    const reader = gen.ViewSmokeFrameDataReader.init(dr, alloc);
    const take_deadline = time_mod.nanoTimestamp() + TIMEOUT_NS;
    var sample = while (true) {
        if (try reader.take_view()) |s| break s;
        try testing.expect(time_mod.nanoTimestamp() < take_deadline);
        time_mod.sleepNs(10 * std.time.ns_per_ms);
    };
    try testing.expect(sample.info.valid_data);

    // Decoded in place: the string and sequences point into the loan.
    const loaned = sample.raw.data;
    try testing.expectEqual(@as(u32, 3), sample.view.id);
    try testing.expectEqualStrings("view smoke", sample.view.label);
    try testing.expect(within(loaned, sample.view.label));
    try testing.expect(within(loaned, sample.view.payload.bytes));
    try testing.expectEqualSlices(u8, &payload, sample.view.payload.asNative(u8).?);
    var samples_out: [3]f64 = undefined;
    try testing.expect(within(loaned, sample.view.samples.bytes));
    sample.view.samples.copyTo(std.mem.sliceAsBytes(&samples_out));
    try testing.expectEqualSlices(f64, &samples, &samples_out);
    sample.deinit();

    // Taken, so nothing is left.
    try testing.expect(try reader.take_view() == null);
}
