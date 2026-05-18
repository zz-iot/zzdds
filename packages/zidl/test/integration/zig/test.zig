// Integration tests for the generated Zig types + CDR serialization + vtable.
// These run as part of `zig build test`.

const std = @import("std");
const testing = std.testing;
const zidl_rt = @import("zidl_rt");
const types = @import("types");
const stub = @import("stub_impl");

// ── CDR round-trip: Sample (@final, with @key) ────────────────────────────────

test "roundtrip: Sample @final fields" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();

    const src = types.Sample{
        .id = 42,
        .b = true,
        .u8_val = 0xFF,
        .s16_val = -1000,
        .u16_val = 65000,
        .s32_val = -2_000_000,
        .u32_val = 4_000_000,
        .s64_val = -9_000_000_000,
        .u64_val = 18_000_000_000,
        .f32_val = 3.14,
        .f64_val = 2.718281828,
        .str = "hello world",
        .bstr = zidl_rt.BoundedArray(u8, 32).fromSlice("bounded") catch unreachable,
        .nums = .empty,
        .arr = .{ 10, 20, 30 },
        .clr = .GREEN,
        .nested = .{ .x = 7, .y = -3 },
    };

    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    const dst = try types.Sample.deserialize(&reader, testing.allocator);
    defer testing.allocator.free(dst.str);

    try testing.expectEqual(src.id, dst.id);
    try testing.expectEqual(src.b, dst.b);
    try testing.expectEqual(src.u8_val, dst.u8_val);
    try testing.expectEqual(src.s16_val, dst.s16_val);
    try testing.expectEqual(src.u16_val, dst.u16_val);
    try testing.expectEqual(src.s32_val, dst.s32_val);
    try testing.expectEqual(src.u32_val, dst.u32_val);
    try testing.expectEqual(src.s64_val, dst.s64_val);
    try testing.expectEqual(src.u64_val, dst.u64_val);
    try testing.expectApproxEqRel(src.f32_val, dst.f32_val, 1e-5);
    try testing.expectApproxEqRel(src.f64_val, dst.f64_val, 1e-12);
    try testing.expectEqualStrings(src.str, dst.str);
    try testing.expectEqualSlices(u8, src.bstr.slice(), dst.bstr.slice());
    try testing.expectEqualSlices(i32, src.arr[0..], dst.arr[0..]);
    try testing.expectEqual(src.clr, dst.clr);
    try testing.expectEqual(src.nested.x, dst.nested.x);
    try testing.expectEqual(src.nested.y, dst.nested.y);
}

test "roundtrip: Sample key serialization" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();

    const src = types.Sample{ .id = 99 };
    try types.Sample.serializeKey(&writer, src);

    // 4 encap + 4 bytes for the u32 key field
    try testing.expectEqual(@as(usize, 8), buf.items.len);
    try testing.expect(types.Sample.has_key);
    try testing.expect(!types.Frame.has_key);
}

test "roundtrip: Sample deserializeKey from full sample" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var nums = std.ArrayListUnmanaged(i32).empty;
    defer nums.deinit(testing.allocator);
    try nums.appendSlice(testing.allocator, &.{ 11, 22, 33 });

    const src = types.Sample{
        .id = 0x01020304,
        .b = true,
        .str = "non-key payload",
        .nums = nums,
        .arr = .{ 1, 2, 3 },
        .nested = .{ .x = 10, .y = 20 },
    };

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    const key = try types.Sample.deserializeKey(&reader, testing.allocator);

    try testing.expectEqual(src.id, key.id);
    try testing.expectEqual(false, key.b);
    try testing.expectEqualStrings("", key.str);
    try testing.expectEqual(@as(usize, 0), key.nums.items.len);
    try testing.expectEqual(@as(i32, 0), key.nested.x);
    try testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "roundtrip: Sample computeKeyHash pads short PLAIN_CDR2 BE key" {
    const hash = types.Sample.computeKeyHash(.{ .id = 0x01020304 });
    const expected = [_]u8{
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, expected[0..], hash[0..]);
}

test "roundtrip: Sample with sequence" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var nums = std.ArrayListUnmanaged(i32).empty;
    defer nums.deinit(testing.allocator);
    try nums.appendSlice(testing.allocator, &.{ 1, 2, 3, 4, 5 });

    var src = types.Sample{};
    src.nums = nums;

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();
    try types.Sample.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    var dst = types.Sample{};
    try types.Sample.deserializeInto(&dst, &reader, testing.allocator);
    defer {
        testing.allocator.free(dst.str);
        dst.nums.deinit(testing.allocator);
    }

    try testing.expectEqualSlices(i32, nums.items, dst.nums.items);
}

// ── CDR round-trip: Frame (@appendable, DHEADER) ──────────────────────────────

test "roundtrip: Frame @appendable DHEADER" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);

    var writer = zidl_rt.CdrWriter(.xcdr2).init(&buf, testing.allocator);
    try writer.writeEncapHeader();

    const src = types.Frame{ .seq_num = 7, .topic = "/sensors/imu" };
    try types.Frame.serialize(&writer, src);

    var reader = try zidl_rt.CdrReader.init(buf.items);
    const dst = try types.Frame.deserialize(&reader, testing.allocator);
    defer testing.allocator.free(dst.topic);

    try testing.expectEqual(src.seq_num, dst.seq_num);
    try testing.expectEqualStrings(src.topic, dst.topic);
}

// ── Vtable: Greeter ───────────────────────────────────────────────────────────

test "vtable: Greeter call forwarding" {
    var impl = stub.GreeterStub{};
    const g = impl.asGreeter();

    const greeting = g.greet("Alice");
    try testing.expectEqualStrings("hello", greeting);
    try testing.expectEqualStrings("Alice", impl.last_name);
    try testing.expectEqual(@as(i32, 1), g.get_count());

    _ = g.greet("Bob");
    try testing.expectEqual(@as(i32, 2), g.get_count());

    g.reset();
    try testing.expectEqual(@as(i32, 0), g.get_count());
}

test "vtable: Greeter deinit is safe" {
    var impl = stub.GreeterStub{};
    const g = impl.asGreeter();
    g.deinit(); // must not crash
}
