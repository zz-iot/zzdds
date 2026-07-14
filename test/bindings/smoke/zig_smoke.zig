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

    // Batched take()/read() grow their `out` list with the *caller's* allocator
    // (see src/raw_ops.zig's caller_alloc parameter) while each sample's payload
    // is freed by the adapter's own page_allocator — using a separate
    // DebugAllocator here for the reader means any mismatch between those two
    // (the exact bug this parameter was added to fix) trips an immediate
    // "Invalid free" panic on the mismatched .free() call, not just a leak.
    var batch_gpa = std.heap.DebugAllocator(.{}){};
    defer std.debug.assert(batch_gpa.deinit() == .ok);
    const batch_alloc = batch_gpa.allocator();

    try writer.write(sample, 0);
    const batch_reader = smoke.BindingSmokeStatusDataReader.init(1, batch_alloc);

    // BindingSmokeStatus has no heap-owning fields (label is a fixed-size
    // BoundedArray), so the generator omits SampledValue.deinit() — only the
    // container itself needs freeing.
    var taken: std.ArrayListUnmanaged(smoke.BindingSmokeStatusDataReader.SampledValue) = .empty;
    defer taken.deinit(batch_alloc);
    const got_batch = try batch_reader.take(&taken, -1, 0xFFFF, 0xFFFF, 0xFFFF);
    if (!got_batch or taken.items.len != 1) return error.UnexpectedBatchResult;
    try std.testing.expectEqual(sample.id, taken.items[0].value.id);
    try std.testing.expectEqual(sample.count, taken.items[0].value.count);

    sample.count += 1;
    try writer.dispose(sample, 0);
    try std.testing.expectEqual(zzdds.WriteKind.dispose, zzdds.capturedKind().?);

    try writer.unregister_instance(sample, 0);
    try std.testing.expectEqual(zzdds.WriteKind.unregister, zzdds.capturedKind().?);
}
