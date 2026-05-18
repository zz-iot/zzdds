// Interop tests: cross-validate zidl-rt CdrReader/CdrWriter against
// Cyclone DDS 11.0.1 byte-level CDR output.
//
// Each test pair:
//   "cyclone → zig":  expected bytes (from cyclone_dump) fed to CdrReader
//   "zig → cyclone":  CdrWriter output compared byte-for-byte with expected bytes
//
// Expected bytes were captured by running:
//   make -C interop   (or: make all from within interop/)
// They encode the fixed test fixtures defined in cyclone_dump.c.
//
// Run from the project root:
//   zig test interop/zig_interop_test.zig \
//       --dep zidl_rt -Mzidl_rt=packages/zidl-rt/src/root.zig

const std = @import("std");
const rt = @import("zidl_rt");
const CdrReader = rt.CdrReader;
const CdrWriter = rt.CdrWriter;

const testing = std.testing;
const alloc = testing.allocator;

// ── Expected bytes (from cyclone_dump, committed) ─────────────────────────

// Interop_Primitives { x=42, y=1.5f, flag=true, b=0xAB, d=3.14, s=-7, ll=9_000_000_000 }
//   Field order: x(i32) y(f32) flag(bool) b(u8) d(f64) s(i16) ll(i64)
//   XCDR2: alignment capped at 4; d pads 2 bytes (pos 10→12), ll pads 2 bytes (pos 26→28)
const PRIMITIVES_XCDR2 = [_]u8{
    0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
    0x2a, 0x00, 0x00, 0x00, // x = 42
    0x00, 0x00, 0xc0, 0x3f, // y = 1.5f
    0x01, // flag = true
    0xab, // b = 0xAB
    0x00, 0x00, // pad (10→12 for f64 align-4)
    0x1f, 0x85, 0xeb, 0x51, 0xb8, 0x1e, 0x09, 0x40, // d = 3.14
    0xf9, 0xff, // s = -7
    0x00, 0x00, // pad (26→28 for i64 align-4)
    0x00, 0x1a, 0x71, 0x18, 0x02, 0x00, 0x00, 0x00, // ll = 9_000_000_000
};

// Same struct, XCDR1: alignment capped at 8; d pads 6 bytes (pos 10→16), ll pads 6 bytes (pos 26→32)
const PRIMITIVES_XCDR1 = [_]u8{
    0x00, 0x01, 0x00, 0x00, // encap: XCDR1 LE
    0x2a, 0x00, 0x00, 0x00, // x = 42
    0x00, 0x00, 0xc0, 0x3f, // y = 1.5f
    0x01, // flag = true
    0xab, // b = 0xAB
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pad (10→16 for f64 align-8)
    0x1f, 0x85, 0xeb, 0x51, 0xb8, 0x1e, 0x09, 0x40, // d = 3.14
    0xf9, 0xff, // s = -7
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // pad (26→32 for i64 align-8)
    0x00, 0x1a, 0x71, 0x18, 0x02, 0x00, 0x00, 0x00, // ll = 9_000_000_000
};

// Interop_Message { sensor_id=7, label="hello", values=[10, 20, 30] }
//   sensor_id(i32) label(string) values(seq<i32>)
//   XCDR2: string "hello" = len=6 + 6 chars; padding 2 bytes (pos 14→16) before seq length
const MESSAGE_XCDR2 = [_]u8{
    0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
    0x07, 0x00, 0x00, 0x00, // sensor_id = 7
    0x06, 0x00, 0x00, 0x00, // string length = 6 (5 chars + NUL)
    'h', 'e', 'l', 'l', 'o', 0x00, // "hello\0"
    0x00, 0x00, // pad (14→16 for u32 seq-length alignment)
    0x03, 0x00, 0x00, 0x00, // sequence length = 3
    0x0a, 0x00, 0x00, 0x00, // values[0] = 10
    0x14, 0x00, 0x00, 0x00, // values[1] = 20
    0x1e, 0x00, 0x00, 0x00, // values[2] = 30
};

// Same struct XCDR1: identical layout (no 8-byte fields)
const MESSAGE_XCDR1 = [_]u8{
    0x00, 0x01, 0x00, 0x00, // encap: XCDR1 LE
    0x07, 0x00, 0x00, 0x00, // sensor_id = 7
    0x06, 0x00, 0x00, 0x00, // string length = 6
    'h', 'e', 'l', 'l', 'o', 0x00, // "hello\0"
    0x00, 0x00, // pad
    0x03, 0x00, 0x00, 0x00, // sequence length = 3
    0x0a, 0x00, 0x00, 0x00, // values[0] = 10
    0x14, 0x00, 0x00, 0x00, // values[1] = 20
    0x1e, 0x00, 0x00, 0x00, // values[2] = 30
};

// Interop_Point { x=100, y=-200 } — @appendable, XCDR2 with DHEADER
//   DHEADER = 8 (payload size: x(4) + y(4) = 8)
const POINT_XCDR2 = [_]u8{
    0x00, 0x07, 0x00, 0x00, // encap: XCDR2 LE
    0x08, 0x00, 0x00, 0x00, // DHEADER = 8
    0x64, 0x00, 0x00, 0x00, // x = 100
    0x38, 0xff, 0xff, 0xff, // y = -200
};

// ── Helpers ───────────────────────────────────────────────────────────────

fn mkWriter(comptime xver: rt.XcdrVersion, buf: *std.ArrayListUnmanaged(u8)) CdrWriter(xver) {
    return CdrWriter(xver).init(buf, alloc);
}

// ── Direction 1: Cyclone → Zig (CdrReader parsing Cyclone bytes) ──────────

test "cyclone→zig: primitives xcdr2 le" {
    var r = try CdrReader.init(&PRIMITIVES_XCDR2);
    try testing.expectEqual(rt.XcdrVersion.xcdr2, r.xcdr_version);
    try testing.expectEqual(rt.ByteOrder.little, r.byte_order);
    try testing.expectEqual(@as(i32, 42), try r.readI32());
    try testing.expectEqual(@as(f32, 1.5), try r.readF32());
    try testing.expectEqual(true, try r.readBool());
    try testing.expectEqual(@as(u8, 0xAB), try r.readU8());
    try testing.expectApproxEqAbs(@as(f64, 3.14), try r.readF64(), 1e-10);
    try testing.expectEqual(@as(i16, -7), try r.readI16());
    try testing.expectEqual(@as(i64, 9_000_000_000), try r.readI64());
}

test "cyclone→zig: primitives xcdr1 le" {
    var r = try CdrReader.init(&PRIMITIVES_XCDR1);
    try testing.expectEqual(rt.XcdrVersion.xcdr1, r.xcdr_version);
    try testing.expectEqual(rt.ByteOrder.little, r.byte_order);
    try testing.expectEqual(@as(i32, 42), try r.readI32());
    try testing.expectEqual(@as(f32, 1.5), try r.readF32());
    try testing.expectEqual(true, try r.readBool());
    try testing.expectEqual(@as(u8, 0xAB), try r.readU8());
    try testing.expectApproxEqAbs(@as(f64, 3.14), try r.readF64(), 1e-10);
    try testing.expectEqual(@as(i16, -7), try r.readI16());
    try testing.expectEqual(@as(i64, 9_000_000_000), try r.readI64());
}

test "cyclone→zig: message xcdr2 le (string + sequence)" {
    var r = try CdrReader.init(&MESSAGE_XCDR2);
    try testing.expectEqual(@as(i32, 7), try r.readI32()); // sensor_id
    const label = try r.readStringZeroCopy();
    try testing.expectEqualStrings("hello", label);
    const seq_len = try r.readU32();
    try testing.expectEqual(@as(u32, 3), seq_len);
    try testing.expectEqual(@as(i32, 10), try r.readI32());
    try testing.expectEqual(@as(i32, 20), try r.readI32());
    try testing.expectEqual(@as(i32, 30), try r.readI32());
}

test "cyclone→zig: message xcdr1 le (string + sequence)" {
    var r = try CdrReader.init(&MESSAGE_XCDR1);
    try testing.expectEqual(@as(i32, 7), try r.readI32()); // sensor_id
    const label = try r.readStringZeroCopy();
    try testing.expectEqualStrings("hello", label);
    const seq_len = try r.readU32();
    try testing.expectEqual(@as(u32, 3), seq_len);
    try testing.expectEqual(@as(i32, 10), try r.readI32());
    try testing.expectEqual(@as(i32, 20), try r.readI32());
    try testing.expectEqual(@as(i32, 30), try r.readI32());
}

test "cyclone→zig: point xcdr2 le (@appendable with DHEADER)" {
    var r = try CdrReader.init(&POINT_XCDR2);
    const dheader = try r.readDheader();
    try testing.expectEqual(@as(u32, 8), dheader); // 2 × i32
    try testing.expectEqual(@as(i32, 100), try r.readI32());
    try testing.expectEqual(@as(i32, -200), try r.readI32());
}

// ── Direction 2: Zig → Cyclone (CdrWriter output matches Cyclone bytes) ───

test "zig→cyclone: primitives xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(42);
    try w.writeF32(1.5);
    try w.writeBool(true);
    try w.writeU8(0xAB);
    try w.writeF64(3.14);
    try w.writeI16(-7);
    try w.writeI64(9_000_000_000);
    try testing.expectEqualSlices(u8, &PRIMITIVES_XCDR2, buf.items);
}

test "zig→cyclone: primitives xcdr1 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeI32(42);
    try w.writeF32(1.5);
    try w.writeBool(true);
    try w.writeU8(0xAB);
    try w.writeF64(3.14);
    try w.writeI16(-7);
    try w.writeI64(9_000_000_000);
    try testing.expectEqualSlices(u8, &PRIMITIVES_XCDR1, buf.items);
}

test "zig→cyclone: message xcdr2 le (string + sequence)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(7); // sensor_id
    try w.writeString("hello"); // label
    try w.writeU32(3); // sequence length
    try w.writeI32(10);
    try w.writeI32(20);
    try w.writeI32(30);
    try testing.expectEqualSlices(u8, &MESSAGE_XCDR2, buf.items);
}

test "zig→cyclone: message xcdr1 le (string + sequence)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeI32(7); // sensor_id
    try w.writeString("hello"); // label
    try w.writeU32(3); // sequence length
    try w.writeI32(10);
    try w.writeI32(20);
    try w.writeI32(30);
    try testing.expectEqualSlices(u8, &MESSAGE_XCDR1, buf.items);
}

test "zig→cyclone: point xcdr2 le (@appendable with DHEADER)" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(alloc);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeI32(100);
    try w.writeI32(-200);
    w.patchDheader(dh);
    try testing.expectEqualSlices(u8, &POINT_XCDR2, buf.items);
}
