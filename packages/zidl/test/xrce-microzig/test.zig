const std = @import("std");
const zidl_rt = @import("zidl_rt");
const types = @import("types");

test "XRCE fixture round-trips bounded data on Zig 0.15.1" {
    const allocator = std.testing.allocator;

    const board = try zidl_rt.BoundedArray(u8, 16).fromSlice("pico-wh");
    const payload = try zidl_rt.BoundedArray(u8, 8).fromSlice(&.{ 1, 2, 3, 5 });
    const sample = types.CounterStatus{
        .counter = 42,
        .board = board,
        .payload = payload,
    };

    try std.testing.expect(types.CounterStatus.has_key);

    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(allocator);

    var writer = zidl_rt.CdrWriter(.xcdr1).init(&bytes, allocator);
    try writer.writeEncapHeader();
    try types.CounterStatus.serialize(&writer, sample);

    var reader = try zidl_rt.CdrReader.init(bytes.items);
    const decoded = try types.CounterStatus.deserialize(&reader, allocator);

    try std.testing.expectEqual(@as(u32, 42), decoded.counter);
    try std.testing.expectEqualSlices(u8, "pico-wh", decoded.board.slice());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 5 }, decoded.payload.slice());

    var key_reader = try zidl_rt.CdrReader.init(bytes.items);
    const key_only = try types.CounterStatus.deserializeKey(&key_reader, allocator);
    try std.testing.expectEqual(@as(u32, 42), key_only.counter);

    const key_hash = types.CounterStatus.computeKeyHash(sample);
    try std.testing.expectEqual(@as(usize, 16), key_hash.len);
}
