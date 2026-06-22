const std = @import("std");
const zidl_rt = @import("zidl_rt");
const dds = @import("dds");
const smoke = @import("binding_smoke");

pub fn main() !void {
    defer dds.reset();

    var sample = smoke.BindingSmokeStatus{
        .id = 7,
        .count = 42,
        .label = try zidl_rt.BoundedArray(u8, 32).fromSlice("zig-smoke"),
    };

    const expected_hash = smoke.BindingSmokeStatus.computeKeyHash(sample);
    const writer = smoke.BindingSmokeStatusDataWriter.init(1, std.heap.page_allocator, false);
    try writer.write(sample);

    try std.testing.expectEqual(dds.WriteKind.alive, dds.capturedKind().?);
    try std.testing.expectEqualSlices(u8, &expected_hash, &dds.capturedKeyHash());

    const reader = smoke.BindingSmokeStatusDataReader.init(1);
    const taken = (try reader.take(std.heap.page_allocator)) orelse return error.NoSample;

    try std.testing.expectEqual(sample.id, taken.value.id);
    try std.testing.expectEqual(sample.count, taken.value.count);
    try std.testing.expectEqualStrings(sample.label.slice(), taken.value.label.slice());
    try std.testing.expectEqual(@as(dds.DDS.InstanceStateKind, 1), taken.instance_state);
    try std.testing.expectEqual(@as(dds.DDS.InstanceHandle_t, 7), taken.instance_handle);

    sample.count += 1;
    try writer.dispose(sample);
    try std.testing.expectEqual(dds.WriteKind.dispose, dds.capturedKind().?);

    try writer.unregister(sample);
    try std.testing.expectEqual(dds.WriteKind.unregister, dds.capturedKind().?);
}
