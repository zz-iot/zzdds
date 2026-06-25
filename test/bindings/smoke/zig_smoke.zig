const std = @import("std");
const zidl_rt = @import("zidl_rt");
const zzdds = @import("zzdds");
const smoke = @import("binding_smoke");

pub fn main() !void {
    defer zzdds.reset();

    var sample = smoke.BindingSmokeStatus{
        .id = 7,
        .count = 42,
        .label = try zidl_rt.BoundedArray(u8, 32).fromSlice("zig-smoke"),
    };

    const expected_hash = smoke.BindingSmokeStatus.computeKeyHash(sample);
    const writer = smoke.BindingSmokeStatusDataWriter.init(1, std.heap.page_allocator);
    try writer.write(sample, 0);

    try std.testing.expectEqual(zzdds.WriteKind.alive, zzdds.capturedKind().?);
    try std.testing.expectEqualSlices(u8, &expected_hash, &zzdds.capturedKeyHash());

    const reader = smoke.BindingSmokeStatusDataReader.init(1, std.heap.page_allocator);
    var taken_value: smoke.BindingSmokeStatus = .{};
    var taken_info: zzdds.DDS.SampleInfo = .{};
    const got = try reader.take_next_sample(&taken_value, &taken_info);
    if (!got) return error.NoSample;

    try std.testing.expectEqual(sample.id, taken_value.id);
    try std.testing.expectEqual(sample.count, taken_value.count);
    try std.testing.expectEqualStrings(sample.label.slice(), taken_value.label.slice());
    try std.testing.expectEqual(@as(u32, 1), taken_info.instance_state);
    try std.testing.expectEqual(@as(zzdds.DDS.InstanceHandle_t, 7), taken_info.instance_handle);

    sample.count += 1;
    try writer.dispose(sample, 0);
    try std.testing.expectEqual(zzdds.WriteKind.dispose, zzdds.capturedKind().?);

    try writer.unregister_instance(sample, 0);
    try std.testing.expectEqual(zzdds.WriteKind.unregister, zzdds.capturedKind().?);
}
