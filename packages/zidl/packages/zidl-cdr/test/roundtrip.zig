//! Cross-validation tests for zidl-cdr (C library) against zidl-rt (Zig).
//!
//! These tests call the C library via @cImport and verify that:
//!   1. The C library serializes identical bytes to zidl-rt for the same values.
//!   2. The C library correctly deserializes bytes produced by zidl-rt.
//!
//! Coverage:
//!   - XCDR1 LE and XCDR2 LE encapsulation headers
//!   - All primitive types (u8, i8, bool, char, u16/i16, u32/i32/f32, u64/i64/f64)
//!   - Strings and wstrings
//!   - DHEADER reservation/patching (XCDR2)
//!   - Reader round-trips for all types

const std = @import("std");
const zidl_rt = @import("zidl_rt");
const testing = std.testing;

const c = @cImport({
    @cInclude("zidl_cdr.h");
});

// ── Cross-validation helpers ──────────────────────────────────────────────────

/// Assert C write produces the same bytes as zidl-rt for XCDR2.
fn crossVal2(
    comptime T: type,
    value: T,
    comptime rt_write_fn: fn (*zidl_rt.CdrWriter(.xcdr2), T) anyerror!void,
    c_write_fn: *const fn (*c.ZidlCdrWriter, T) callconv(.c) c_int,
) !void {
    // zidl-rt side
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr2).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_write_fn(&rt_w, value);

    // C side
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c_write_fn(&cw, value));

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

/// Assert C write produces the same bytes as zidl-rt for XCDR1.
fn crossVal1(
    comptime T: type,
    value: T,
    comptime rt_write_fn: fn (*zidl_rt.CdrWriter(.xcdr1), T) anyerror!void,
    c_write_fn: *const fn (*c.ZidlCdrWriter, T) callconv(.c) c_int,
) !void {
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr1).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_write_fn(&rt_w, value);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR1);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c_write_fn(&cw, value));

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

// ── Encapsulation header ──────────────────────────────────────────────────────

test "encap: XCDR2 LE header" {
    var w: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&w, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&w);
    _ = c.zidl_cdr_write_encap(&w);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00 }, w.buf[0..w.len]);
}

test "encap: XCDR1 LE header" {
    var w: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&w, c.ZIDL_XCDR1);
    defer c.zidl_cdr_writer_deinit(&w);
    _ = c.zidl_cdr_write_encap(&w);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, w.buf[0..w.len]);
}

test "reader: rejects unknown encap id" {
    var r: c.ZidlCdrReader = undefined;
    const bad = [_]u8{ 0xFF, 0xFF, 0x00, 0x00 };
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_INVALID), c.zidl_cdr_reader_init(&r, &bad, bad.len));
}

test "reader: rejects too-short data" {
    var r: c.ZidlCdrReader = undefined;
    const short = [_]u8{0x00};
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_INVALID), c.zidl_cdr_reader_init(&r, &short, short.len));
}

test "key hash: short serialized key is zero padded" {
    const key = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var out: [16]u8 = undefined;
    c.zidl_cdr_compute_key_hash(&key, key.len, &out);
    const expected = [_]u8{
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try testing.expectEqualSlices(u8, expected[0..], out[0..]);
}

test "key hash: long serialized key uses MD5" {
    const key = "abcdefghijklmnopq";
    var out: [16]u8 = undefined;
    c.zidl_cdr_compute_key_hash(key.ptr, key.len, &out);
    const expected = [_]u8{
        0x9a, 0x8d, 0x98, 0x45,
        0xa6, 0xb4, 0xd8, 0x2d,
        0xfc, 0xb2, 0xc2, 0xe3,
        0x51, 0x62, 0xc8, 0x30,
    };
    try testing.expectEqualSlices(u8, expected[0..], out[0..]);
}

test "md5: known abc digest" {
    const data = "abc";
    var out: [16]u8 = undefined;
    c.zidl_md5(data.ptr, data.len, &out);
    const expected = [_]u8{
        0x90, 0x01, 0x50, 0x98,
        0x3c, 0xd2, 0x4f, 0xb0,
        0xd6, 0x96, 0x3f, 0x7d,
        0x28, 0xe1, 0x7f, 0x72,
    };
    try testing.expectEqualSlices(u8, expected[0..], out[0..]);
}

// ── XCDR2 primitive cross-validation ─────────────────────────────────────────

test "crossval xcdr2: u8" {
    try crossVal2(u8, 0xAB, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: u8) !void {
            try w.writeU8(v);
        }
    }.f, &c.zidl_cdr_write_u8);
}
test "crossval xcdr2: i8" {
    try crossVal2(i8, -42, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: i8) !void {
            try w.writeI8(v);
        }
    }.f, &c.zidl_cdr_write_i8);
}
test "crossval xcdr2: bool true" {
    try crossVal2(bool, true, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: bool) !void {
            try w.writeBool(v);
        }
    }.f, &c.zidl_cdr_write_bool);
}
test "crossval xcdr2: bool false" {
    try crossVal2(bool, false, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: bool) !void {
            try w.writeBool(v);
        }
    }.f, &c.zidl_cdr_write_bool);
}
test "crossval xcdr2: u16" {
    try crossVal2(u16, 0x1234, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: u16) !void {
            try w.writeU16(v);
        }
    }.f, &c.zidl_cdr_write_u16);
}
test "crossval xcdr2: i16" {
    try crossVal2(i16, -1000, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: i16) !void {
            try w.writeI16(v);
        }
    }.f, &c.zidl_cdr_write_i16);
}
test "crossval xcdr2: u32" {
    try crossVal2(u32, 0xDEADBEEF, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: u32) !void {
            try w.writeU32(v);
        }
    }.f, &c.zidl_cdr_write_u32);
}
test "crossval xcdr2: i32" {
    try crossVal2(i32, -123456, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: i32) !void {
            try w.writeI32(v);
        }
    }.f, &c.zidl_cdr_write_i32);
}
test "crossval xcdr2: f32" {
    try crossVal2(f32, 3.14159, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: f32) !void {
            try w.writeF32(v);
        }
    }.f, &c.zidl_cdr_write_f32);
}
test "crossval xcdr2: u64" {
    try crossVal2(u64, 0xCAFEBABE_DEADBEEF, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: u64) !void {
            try w.writeU64(v);
        }
    }.f, &c.zidl_cdr_write_u64);
}
test "crossval xcdr2: i64" {
    try crossVal2(i64, -9876543210, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: i64) !void {
            try w.writeI64(v);
        }
    }.f, &c.zidl_cdr_write_i64);
}
test "crossval xcdr2: f64" {
    try crossVal2(f64, 2.71828182845, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr2), v: f64) !void {
            try w.writeF64(v);
        }
    }.f, &c.zidl_cdr_write_f64);
}

// ── XCDR1 cross-validation (8-byte alignment differs from XCDR2) ─────────────

test "crossval xcdr1: u64 (8-byte alignment)" {
    try crossVal1(u64, 0x0102030405060708, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr1), v: u64) !void {
            try w.writeU64(v);
        }
    }.f, &c.zidl_cdr_write_u64);
}
test "crossval xcdr1: f64" {
    try crossVal1(f64, 1.0, struct {
        fn f(w: *zidl_rt.CdrWriter(.xcdr1), v: f64) !void {
            try w.writeF64(v);
        }
    }.f, &c.zidl_cdr_write_f64);
}

// ── Alignment padding: u8 then u32 ───────────────────────────────────────────

test "crossval xcdr2: u8 then u32 alignment" {
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr2).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_w.writeU8(0x11);
    try rt_w.writeU32(0x22334455);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_u8(&cw, 0x11);
    _ = c.zidl_cdr_write_u32(&cw, 0x22334455);

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

// ── String cross-validation ───────────────────────────────────────────────────

test "crossval xcdr2: string" {
    const s: []const u8 = "hello";
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr2).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_w.writeString(s);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_string(&cw, s.ptr, @intCast(s.len));

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

test "crossval xcdr2: empty string" {
    const s: []const u8 = "";
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr2).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_w.writeString(s);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_string(&cw, s.ptr, @intCast(s.len));

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

// ── DHEADER cross-validation (XCDR2) ─────────────────────────────────────────

test "crossval xcdr2: reserve+patch dheader" {
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr2).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    const rt_dh = try rt_w.reserveDheader();
    try rt_w.writeI32(42);
    rt_w.patchDheader(rt_dh);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    var c_dh: usize = undefined;
    _ = c.zidl_cdr_reserve_dheader(&cw, &c_dh);
    _ = c.zidl_cdr_write_i32(&cw, 42);
    c.zidl_cdr_patch_dheader(&cw, c_dh);

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

test "reserve_dheader_maybe: no-op on xcdr1" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR1);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    var off: usize = 0;
    _ = c.zidl_cdr_reserve_dheader_maybe(&cw, &off);
    // On XCDR1, reserve_maybe must NOT write any bytes.
    _ = c.zidl_cdr_write_i32(&cw, 99);
    // Expected: encap(4) + i32(4) = 8 bytes total.
    try testing.expectEqual(@as(usize, 8), cw.len);
}

// ── Reader round-trips ────────────────────────────────────────────────────────

test "reader xcdr2: u32 roundtrip" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_u32(&cw, 0x12345678);

    var r: c.ZidlCdrReader = undefined;
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c.zidl_cdr_reader_init(&r, cw.buf, cw.len));
    var v: u32 = 0;
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c.zidl_cdr_read_u32(&r, &v));
    try testing.expectEqual(@as(u32, 0x12345678), v);
}

test "reader xcdr2: i64 roundtrip" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_i64(&cw, -1234567890123);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var v: i64 = 0;
    _ = c.zidl_cdr_read_i64(&r, &v);
    try testing.expectEqual(@as(i64, -1234567890123), v);
}

test "reader xcdr2: string roundtrip" {
    const src: []const u8 = "world";
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_string(&cw, src.ptr, @intCast(src.len));

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var out_ptr: [*c]const u8 = null;
    var out_len: u32 = 0;
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c.zidl_cdr_read_string_zerocopy(&r, &out_ptr, &out_len));
    try testing.expectEqual(@as(u32, @intCast(src.len)), out_len);
    try testing.expectEqualStrings(src, out_ptr[0..out_len]);
}

test "reader xcdr2: bool roundtrip" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_bool(&cw, true);
    _ = c.zidl_cdr_write_bool(&cw, false);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var a: bool = false;
    var b: bool = true;
    _ = c.zidl_cdr_read_bool(&r, &a);
    _ = c.zidl_cdr_read_bool(&r, &b);
    try testing.expect(a == true);
    try testing.expect(b == false);
}

test "reader xcdr2: skip_dheader_if_xcdr2 skips" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    var dh_off: usize = 0;
    _ = c.zidl_cdr_reserve_dheader(&cw, &dh_off);
    _ = c.zidl_cdr_write_u32(&cw, 0xABCD1234);
    c.zidl_cdr_patch_dheader(&cw, dh_off);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    _ = c.zidl_cdr_skip_dheader_if_xcdr2(&r);
    var v: u32 = 0;
    _ = c.zidl_cdr_read_u32(&r, &v);
    try testing.expectEqual(@as(u32, 0xABCD1234), v);
}

test "reader: truncated returns TRUNCATED" {
    // encap(4) + 1 byte — too short for a u32
    const data = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0x01 };
    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, &data, data.len);
    var v: u32 = 0;
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_TRUNCATED), c.zidl_cdr_read_u32(&r, &v));
}

// ── Fixed-buffer writer ───────────────────────────────────────────────────────

test "fixed writer: overflow returns OVERFLOW" {
    var buf: [8]u8 = undefined; // 4 encap + 4 u32 = exactly full
    var cw: c.ZidlCdrWriter = undefined;
    c.zidl_cdr_writer_init_fixed(&cw, &buf, buf.len, c.ZIDL_XCDR2);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_u32(&cw, 99);
    // Buffer is now full; next write must overflow.
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OVERFLOW), c.zidl_cdr_write_u8(&cw, 0xFF));
}

// ── EMHEADER write / read (XCDR2 @mutable support) ───────────────────────────

test "emheader: write_emheader (fixed LC=2) + read_emheader" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    // LC=2: 4-byte member, member_id=7, must_understand=true
    _ = c.zidl_cdr_write_emheader(&cw, 7, true, 2);
    _ = c.zidl_cdr_write_i32(&cw, 0x1234);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var emh: c.ZidlEmHeader = undefined;
    _ = c.zidl_cdr_read_emheader(&r, &emh);
    try testing.expectEqual(@as(u32, 7), emh.member_id);
    try testing.expect(emh.must_understand);
    try testing.expectEqual(@as(u8, 2), emh.lc);
    try testing.expectEqual(@as(u32, 4), emh.payload_bytes);
    var v: i32 = 0;
    _ = c.zidl_cdr_read_i32(&r, &v);
    try testing.expectEqual(@as(i32, 0x1234), v);
}

test "emheader: reserve_emheader + patch_emheader + read_emheader" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    // Reserve EMHEADER for a variable-length member (string), member_id=3
    var nextint_off: usize = 0;
    _ = c.zidl_cdr_reserve_emheader(&cw, 3, false, &nextint_off);
    const payload_start = cw.len;
    _ = c.zidl_cdr_write_string(&cw, "hello", 5);
    c.zidl_cdr_patch_emheader(&cw, nextint_off, payload_start);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var emh: c.ZidlEmHeader = undefined;
    _ = c.zidl_cdr_read_emheader(&r, &emh);
    try testing.expectEqual(@as(u32, 3), emh.member_id);
    try testing.expect(!emh.must_understand);
    try testing.expectEqual(@as(u8, 4), emh.lc);
    // "hello" as CDR string = 4 (length u32) + 5 (bytes) + 1 (NUL) = 10 bytes
    try testing.expectEqual(@as(u32, 10), emh.payload_bytes);
    const str_ptr: [*c]const u8 = undefined;
    _ = str_ptr;
    var sptr: [*c]const u8 = null;
    var slen: u32 = 0;
    _ = c.zidl_cdr_read_string_zerocopy(&r, &sptr, &slen);
    try testing.expectEqual(@as(u32, 5), slen);
    try testing.expectEqualStrings("hello", sptr[0..slen]);
}

test "emheader: read_mutable_dheader + mutable_has_more loop + skip_emheader_payload" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    var dh_off: usize = 0;
    _ = c.zidl_cdr_reserve_dheader(&cw, &dh_off);
    // member 0: i32 (LC=2)
    _ = c.zidl_cdr_write_emheader(&cw, 0, false, 2);
    _ = c.zidl_cdr_write_i32(&cw, 42);
    // member 99: unknown i32 (will be skipped)
    _ = c.zidl_cdr_write_emheader(&cw, 99, false, 2);
    _ = c.zidl_cdr_write_i32(&cw, 999);
    // member 1: i32 (LC=2)
    _ = c.zidl_cdr_write_emheader(&cw, 1, false, 2);
    _ = c.zidl_cdr_write_i32(&cw, -7);
    c.zidl_cdr_patch_dheader(&cw, dh_off);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var em_end: usize = 0;
    _ = c.zidl_cdr_read_mutable_dheader(&r, &em_end);
    var x: i32 = 0;
    var y: i32 = 0;
    while (c.zidl_cdr_mutable_has_more(&r, em_end)) {
        var emh: c.ZidlEmHeader = undefined;
        _ = c.zidl_cdr_read_emheader(&r, &emh);
        switch (emh.member_id) {
            0 => _ = c.zidl_cdr_read_i32(&r, &x),
            1 => _ = c.zidl_cdr_read_i32(&r, &y),
            else => _ = c.zidl_cdr_skip_emheader_payload(&r, &emh),
        }
    }
    try testing.expectEqual(@as(i32, 42), x);
    try testing.expectEqual(@as(i32, -7), y);
}

test "emheader: read_emheader LC=0..3 payload_bytes" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR2);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    // LC=0 → 1 byte, LC=1 → 2 bytes, LC=3 → 8 bytes
    _ = c.zidl_cdr_write_emheader(&cw, 10, false, 0);
    _ = c.zidl_cdr_write_emheader(&cw, 11, false, 1);
    _ = c.zidl_cdr_write_emheader(&cw, 12, false, 3);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var emh: c.ZidlEmHeader = undefined;
    _ = c.zidl_cdr_read_emheader(&r, &emh);
    try testing.expectEqual(@as(u32, 1), emh.payload_bytes);
    _ = c.zidl_cdr_read_emheader(&r, &emh);
    try testing.expectEqual(@as(u32, 2), emh.payload_bytes);
    _ = c.zidl_cdr_read_emheader(&r, &emh);
    try testing.expectEqual(@as(u32, 8), emh.payload_bytes);
}

// ── fixed<D,S> cross-validation ──────────────────────────────────────────────

test "crossval: fixed<5,2> positive value" {
    // Zig: write fixed<5,2> = 123.45 → bytes [0x12, 0x34, 0x5C]
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr1).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_w.writeFixed(5, 2, 123.45);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR1);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c.zidl_cdr_write_fixed(&cw, 5, 2, 123.45));

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);

    // C reader reads back the Zig-written bytes.
    var cr: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&cr, rt_buf.items.ptr, rt_buf.items.len);
    var out_c: f64 = 0.0;
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), c.zidl_cdr_read_fixed(&cr, 5, 2, &out_c));
    try testing.expectApproxEqAbs(@as(f64, 123.45), out_c, 0.001);
}

test "crossval: fixed<5,2> negative value" {
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr1).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_w.writeFixed(5, 2, -123.45);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR1);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_fixed(&cw, 5, 2, -123.45);

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
}

test "crossval: fixed<4,2> even-digit padding" {
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.CdrWriter(.xcdr1).init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    try rt_w.writeFixed(4, 2, 12.34);

    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_XCDR1);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_write_encap(&cw);
    _ = c.zidl_cdr_write_fixed(&cw, 4, 2, 12.34);

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);

    var cr: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&cr, rt_buf.items.ptr, rt_buf.items.len);
    var out_c: f64 = 0.0;
    _ = c.zidl_cdr_read_fixed(&cr, 4, 2, &out_c);
    try testing.expectApproxEqAbs(@as(f64, 12.34), out_c, 0.001);
}

// ── PL_CDR cross-validation ───────────────────────────────────────────────────

test "pl_cdr: C encap header matches zidl-rt PlCdrWriter" {
    // C writer
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_PL_CDR);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_pl_write_encap(&cw);

    // Zig writer
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.PlCdrWriter.init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x03, 0x00, 0x00 }, cw.buf[0..cw.len]);
}

test "pl_cdr: C reader init accepts PL_CDR_LE" {
    const data = [_]u8{ 0x00, 0x03, 0x00, 0x00 };
    var r: c.ZidlCdrReader = undefined;
    const rc = c.zidl_cdr_reader_init(&r, &data, data.len);
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_OK), rc);
    try testing.expect(r.is_pl_cdr != 0);
    try testing.expectEqual(@as(c_int, c.ZIDL_CDR_LE), r.byte_order);
}

test "pl_cdr: C single i32 param roundtrip matches Zig" {
    // C side: encode pid=5, i32(42)
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_PL_CDR);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_pl_write_encap(&cw);
    var ch: c.ZidlPlParamHandle = undefined;
    _ = c.zidl_cdr_pl_reserve_param(&cw, 5, &ch);
    _ = c.zidl_cdr_write_i32(&cw, 42);
    _ = c.zidl_cdr_pl_patch_param(&cw, ch);
    _ = c.zidl_cdr_pl_write_sentinel(&cw);

    // Zig side: encode same
    var rt_buf = std.ArrayListUnmanaged(u8).empty;
    defer rt_buf.deinit(testing.allocator);
    var rt_w = zidl_rt.PlCdrWriter.init(&rt_buf, testing.allocator);
    try rt_w.writeEncapHeader();
    const h = try rt_w.reservePlParam(5);
    try rt_w.writeI32(42);
    try rt_w.patchPlParam(h);
    try rt_w.writePlSentinel();

    try testing.expectEqualSlices(u8, rt_buf.items, cw.buf[0..cw.len]);

    // C reader: decode
    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    try testing.expect(r.is_pl_cdr != 0);
    var found: i32 = 0;
    while (true) {
        var p: c.ZidlPlParam = undefined;
        _ = c.zidl_cdr_pl_read_param(&r, &p);
        if (p.pid == c.ZIDL_CDR_PID_SENTINEL) break;
        if ((p.pid & 0x3FFF) == 5) _ = c.zidl_cdr_read_i32(&r, &found);
        _ = c.zidl_cdr_seek_to(&r, p.end_pos);
    }
    try testing.expectEqual(@as(i32, 42), found);
}

test "pl_cdr: C multiple params with u8 padding" {
    var cw: c.ZidlCdrWriter = undefined;
    _ = c.zidl_cdr_writer_init(&cw, c.ZIDL_PL_CDR);
    defer c.zidl_cdr_writer_deinit(&cw);
    _ = c.zidl_cdr_pl_write_encap(&cw);
    var h1: c.ZidlPlParamHandle = undefined;
    _ = c.zidl_cdr_pl_reserve_param(&cw, 0x10, &h1);
    _ = c.zidl_cdr_write_u8(&cw, 0xAB);
    _ = c.zidl_cdr_pl_patch_param(&cw, h1);
    var h2: c.ZidlPlParamHandle = undefined;
    _ = c.zidl_cdr_pl_reserve_param(&cw, 0x20, &h2);
    _ = c.zidl_cdr_write_u32(&cw, 0xDEADBEEF);
    _ = c.zidl_cdr_pl_patch_param(&cw, h2);
    _ = c.zidl_cdr_pl_write_sentinel(&cw);

    // Layout: [encap:4][pid:2 len:2 val:1 pad:3][pid:2 len:2 val:4][sentinel:4] = 24
    try testing.expectEqual(@as(usize, 24), cw.len);

    var r: c.ZidlCdrReader = undefined;
    _ = c.zidl_cdr_reader_init(&r, cw.buf, cw.len);
    var v1: u8 = 0;
    var v2: u32 = 0;
    while (true) {
        var p: c.ZidlPlParam = undefined;
        _ = c.zidl_cdr_pl_read_param(&r, &p);
        if (p.pid == c.ZIDL_CDR_PID_SENTINEL) break;
        switch (p.pid & 0x3FFF) {
            0x10 => _ = c.zidl_cdr_read_u8(&r, &v1),
            0x20 => _ = c.zidl_cdr_read_u32(&r, &v2),
            else => {},
        }
        _ = c.zidl_cdr_seek_to(&r, p.end_pos);
    }
    try testing.expectEqual(@as(u8, 0xAB), v1);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), v2);
}
