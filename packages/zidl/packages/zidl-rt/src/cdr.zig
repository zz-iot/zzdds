//! CDR (Common Data Representation) writer and reader for zidl-rt.
//!
//! Implements OMG XCDR1 and XCDR2 encoding, little-endian output, per:
//!   - DDS-XTYPES spec formal-20-02-04 §7.3
//!   - RTPS spec formal-22-04-01 §9.6
//!
//! ## CdrWriter
//!
//! Comptime-parameterised on XCDR version; writes into a caller-owned
//! `std.ArrayListUnmanaged(u8)` buffer.  Using a concrete buffer type (rather
//! than a generic streaming writer) supports DHEADER patching for @appendable
//! and @mutable types — streaming writers cannot seek back to patch previously
//! written bytes.
//!
//!   ```zig
//!   var buf = std.ArrayListUnmanaged(u8).empty;
//!   defer buf.deinit(alloc);
//!   var w = CdrWriter(.xcdr2).init(&buf, alloc);
//!   try w.writeEncapHeader();
//!   try w.writeI32(42);
//!   // buf.items now contains the CDR stream
//!   ```
//!
//! Generated serialize functions use `anytype` duck-typing, so any CdrWriter
//! variant is accepted without code-gen changes:
//!   `pub fn serialize(writer: anytype, value: T) !void { ... }`
//!
//! ## CdrReader
//!
//! Runtime endianness and XCDR version, parsed from the encapsulation header:
//!
//!   ```zig
//!   var r = try CdrReader.init(cdr_bytes);
//!   const x = try r.readI32();
//!   ```
//!
//! Every read validates bounds; returns `error.EndOfStream` on truncation.

const std = @import("std");

// ── Encoding version and byte order ──────────────────────────────────────────

pub const XcdrVersion = enum {
    /// XCDR version 1 — CDR v1, used with RTPS 2.x and legacy DDS.
    xcdr1,
    /// XCDR version 2 — CDR v2, used with DDS-XTYPES (XCDR2_DATA_REPRESENTATION).
    xcdr2,
};

pub const ByteOrder = enum { little, big };

// ── Encapsulation identifier constants (written as big-endian u16) ────────────

/// XCDR1 little-endian encap ID → header bytes [0x00, 0x01, 0x00, 0x00]
pub const ENCAP_CDR1_LE: u16 = 0x0001;
/// XCDR1 big-endian encap ID → header bytes [0x00, 0x00, 0x00, 0x00]
pub const ENCAP_CDR1_BE: u16 = 0x0000;
/// XCDR2 little-endian encap ID → header bytes [0x00, 0x07, 0x00, 0x00]
pub const ENCAP_CDR2_LE: u16 = 0x0007;
/// XCDR2 big-endian encap ID → header bytes [0x00, 0x06, 0x00, 0x00]
pub const ENCAP_CDR2_BE: u16 = 0x0006;
/// PL_CDR (XCDR1 ParameterList) little-endian → header bytes [0x00, 0x03, 0x00, 0x00]
pub const ENCAP_PL_CDR_LE: u16 = 0x0003;
/// PL_CDR (XCDR1 ParameterList) big-endian → header bytes [0x00, 0x02, 0x00, 0x00]
pub const ENCAP_PL_CDR_BE: u16 = 0x0002;

// ── BoundedArray ─────────────────────────────────────────────────────────────
//
// std.BoundedArray was removed in Zig 0.16.0.  We define a minimal
// compatible replacement here so generated code can use `zidl_rt.BoundedArray`.

/// A fixed-capacity array that tracks its own length.
/// Compatible with the std.BoundedArray API used by zidl-generated code.
pub fn BoundedArray(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        len: usize = 0,

        const Self = @This();

        /// Initialize from a slice; returns error.Overflow if s.len > capacity.
        pub fn fromSlice(s: []const T) error{Overflow}!Self {
            if (s.len > capacity) return error.Overflow;
            var self = Self{};
            @memcpy(self.buf[0..s.len], s);
            self.len = s.len;
            return self;
        }

        /// Return a slice of the valid elements.
        pub fn slice(self: *const Self) []const T {
            return self.buf[0..self.len];
        }

        /// Return a mutable slice of the valid elements.
        pub fn sliceMut(self: *Self) []T {
            return self.buf[0..self.len];
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: std.mem.Allocator, new_capacity: usize) error{Overflow}!void {
            _ = allocator;
            if (new_capacity > capacity) return error.Overflow;
            _ = self;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.buf[self.len] = item;
            self.len += 1;
        }

        pub fn append(self: *Self, item: T) error{Overflow}!void {
            if (self.len >= capacity) return error.Overflow;
            self.appendAssumeCapacity(item);
        }
    };
}

// ── CdrWriter ─────────────────────────────────────────────────────────────────

/// CDR writer, comptime-parameterised on XCDR version.
///
/// Writes into a caller-owned `std.ArrayListUnmanaged(u8)` buffer.  Always
/// emits little-endian bytes.  Tracks the running byte offset for CDR
/// alignment padding (padding bytes are zeros).
///
/// Alignment caps: XCDR1 → 8 bytes max; XCDR2 → 4 bytes max.
pub fn CdrWriter(comptime xcdr_version: XcdrVersion) type {
    return struct {
        buf: *std.ArrayListUnmanaged(u8),
        alloc: std.mem.Allocator,
        /// Running byte count; used only for CDR alignment arithmetic.
        pos: usize = 0,

        const Self = @This();

        pub fn init(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) Self {
            return .{ .buf = buf, .alloc = alloc };
        }

        // ── Internal helpers ──────────────────────────────────────────────

        fn writeBytes(self: *Self, bytes: []const u8) !void {
            try self.buf.appendSlice(self.alloc, bytes);
            self.pos += bytes.len;
        }

        /// Emit zero-padding to reach the given alignment boundary.
        fn writePad(self: *Self, boundary: usize) !void {
            const rem = self.pos % boundary;
            if (rem == 0) return;
            const pad = boundary - rem;
            const z: [8]u8 = .{0} ** 8;
            try self.writeBytes(z[0..pad]);
        }

        /// CDR alignment for a primitive of the given wire size (bytes).
        /// XCDR1: min(size, 8).  XCDR2: min(size, 4).
        inline fn align_(wire_size: usize) usize {
            const cap: usize = if (xcdr_version == .xcdr1) 8 else 4;
            return @min(wire_size, cap);
        }

        // ── Encapsulation header ──────────────────────────────────────────

        /// Emit the 4-byte CDR encapsulation header for this writer's XCDR
        /// version and little-endian byte order.
        ///
        /// The representation identifier is written big-endian (per RTPS spec),
        /// followed by two zero option bytes.
        pub fn writeEncapHeader(self: *Self) !void {
            const id: u16 = switch (xcdr_version) {
                .xcdr1 => ENCAP_CDR1_LE,
                .xcdr2 => ENCAP_CDR2_LE,
            };
            try self.writeBytes(&[_]u8{
                @truncate(id >> 8), // high byte first (big-endian representation ID)
                @truncate(id),
                0x00, // options (unused)
                0x00,
            });
            // Reset pos to 0: CDR alignment is from the start of the CDR payload
            // (after the 4-byte encap header), not from the start of the buffer.
            // Without this, 8-byte XCDR1 alignment calculations would be off by 4.
            self.pos = 0;
        }

        // ── Primitive writes ──────────────────────────────────────────────

        pub fn writeU8(self: *Self, v: u8) !void {
            try self.writeBytes(&[_]u8{v});
        }

        pub fn writeI8(self: *Self, v: i8) !void {
            try self.writeU8(@bitCast(v));
        }

        pub fn writeBool(self: *Self, v: bool) !void {
            try self.writeU8(if (v) 1 else 0);
        }

        /// IDL `char` → one byte on the wire.
        pub fn writeChar(self: *Self, v: u8) !void {
            try self.writeU8(v);
        }

        /// IDL `wchar` → two bytes on the wire (same as writeU16).
        pub fn writeWchar(self: *Self, v: u16) !void {
            try self.writeU16(v);
        }

        pub fn writeU16(self: *Self, v: u16) !void {
            try self.writePad(align_(2));
            try self.writeBytes(&[_]u8{ @truncate(v), @truncate(v >> 8) });
        }

        pub fn writeI16(self: *Self, v: i16) !void {
            try self.writeU16(@bitCast(v));
        }

        pub fn writeU32(self: *Self, v: u32) !void {
            try self.writePad(align_(4));
            try self.writeBytes(&[_]u8{
                @truncate(v),
                @truncate(v >> 8),
                @truncate(v >> 16),
                @truncate(v >> 24),
            });
        }

        pub fn writeI32(self: *Self, v: i32) !void {
            try self.writeU32(@bitCast(v));
        }

        pub fn writeF32(self: *Self, v: f32) !void {
            try self.writeU32(@bitCast(v));
        }

        pub fn writeU64(self: *Self, v: u64) !void {
            try self.writePad(align_(8));
            try self.writeBytes(&[_]u8{
                @truncate(v),
                @truncate(v >> 8),
                @truncate(v >> 16),
                @truncate(v >> 24),
                @truncate(v >> 32),
                @truncate(v >> 40),
                @truncate(v >> 48),
                @truncate(v >> 56),
            });
        }

        pub fn writeI64(self: *Self, v: i64) !void {
            try self.writeU64(@bitCast(v));
        }

        pub fn writeF64(self: *Self, v: f64) !void {
            try self.writeU64(@bitCast(v));
        }

        /// Write a `fixed<D,S>` value as packed BCD (alignment 1).
        /// N = (D/2)+1 bytes; sign nibble: 0xC positive/zero, 0xD negative.
        pub fn writeFixed(self: *Self, comptime D: u8, comptime S: u8, value: f64) !void {
            comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
            comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
            const N = comptime (D / 2) + 1;

            const negative = value < 0.0;
            // Compute 10^S at comptime for scaling.
            const scale: f64 = comptime blk: {
                var f: f64 = 1.0;
                var i: u8 = 0;
                while (i < S) : (i += 1) f *= 10.0;
                break :blk f;
            };
            // Round to nearest integer and clamp to max representable (D digits).
            const abs_v = @abs(value) * scale + 0.5;
            const max_int: u64 = comptime blk: {
                var m: u64 = 1;
                var i: u8 = 0;
                while (i < D) : (i += 1) m *= 10;
                break :blk m - 1;
            };
            var int_val: u64 = if (abs_v >= @as(f64, @floatFromInt(max_int)) + 1.0)
                max_int
            else
                @intFromFloat(abs_v);

            // Extract D digits MSB-first.
            var digits: [31]u8 = @splat(0);
            {
                var i: usize = D;
                while (i > 0) {
                    i -= 1;
                    digits[i] = @intCast(int_val % 10);
                    int_val /= 10;
                }
            }

            // Pack nibbles: 2N nibbles = (2N-D-1) leading zeros + D digits + sign.
            const n2 = comptime 2 * N;
            const pad = comptime n2 - D - 1; // 0 if D odd, 1 if D even
            var nibbles: [n2]u8 = @splat(0);
            @memcpy(nibbles[pad .. pad + D], digits[0..D]);
            nibbles[n2 - 1] = if (negative) 0xD else 0xC;

            var buf: [N]u8 = undefined;
            for (0..N) |j| buf[j] = (nibbles[2 * j] << 4) | nibbles[2 * j + 1];
            try self.writeBytes(&buf);
        }

        // ── String / wstring writes ───────────────────────────────────────

        /// CDR string: u32 length (byte count including NUL), then the chars,
        /// then a NUL byte.
        pub fn writeString(self: *Self, v: []const u8) !void {
            try self.writeU32(@intCast(v.len + 1));
            try self.writeBytes(v);
            try self.writeBytes(&[_]u8{0});
        }

        /// CDR wstring: u32 length (wchar count including the NUL wchar),
        /// then the wchars as u16 LE, then a u16 NUL.
        pub fn writeWstring(self: *Self, v: []const u16) !void {
            try self.writeU32(@intCast(v.len + 1));
            for (v) |wc| try self.writeU16(wc);
            try self.writeU16(0);
        }

        // ── XCDR2 framing ─────────────────────────────────────────────────

        /// Write a DHEADER (u32 byte count of the payload that follows).
        ///
        /// XCDR2 §7.3.3.2: required before every @appendable or @mutable type.
        /// Caller provides the payload size in advance.  For @final types,
        /// DHEADER is not emitted.
        pub fn writeDheader(self: *Self, payload_size: u32) !void {
            try self.writeU32(payload_size);
        }

        /// Reserve a DHEADER slot (writes placeholder 0) and return the buffer
        /// offset so the caller can patch it after writing the payload.
        ///
        /// Usage:
        ///   ```zig
        ///   const dh = try w.reserveDheader();
        ///   // ... write payload ...
        ///   w.patchDheader(dh);
        ///   ```
        pub fn reserveDheader(self: *Self) !usize {
            const off = self.buf.items.len;
            try self.writeU32(0);
            return off;
        }

        /// Patch a previously reserved DHEADER with the byte count of everything
        /// written after the 4-byte DHEADER field at `dheader_offset`.
        pub fn patchDheader(self: *Self, dheader_offset: usize) void {
            const payload: u32 = @intCast(self.buf.items.len - dheader_offset - 4);
            const p = self.buf.items[dheader_offset..][0..4];
            p[0] = @truncate(payload);
            p[1] = @truncate(payload >> 8);
            p[2] = @truncate(payload >> 16);
            p[3] = @truncate(payload >> 24);
        }

        /// For generated @appendable/@mutable types: reserve a DHEADER on XCDR2,
        /// return null on XCDR1 (no DHEADER in XCDR1).
        pub fn reserveDheaderMaybe(self: *Self) !?usize {
            if (xcdr_version == .xcdr1) return null;
            return try self.reserveDheader();
        }

        /// Patch a DHEADER reserved by reserveDheaderMaybe.  No-op when null.
        pub fn patchDheaderMaybe(self: *Self, offset: ?usize) void {
            if (offset) |off| self.patchDheader(off);
        }

        // ── EMHEADER (for @mutable types) ────────────────────────────────────

        /// Returned by reserveEmheader; passed to patchEmheader.
        pub const EmheaderPlaceholder = struct {
            /// Offset in buf of the NEXTINT word (4 bytes reserved for payload size).
            nextint_offset: usize,
            /// buf.items.len right after the NEXTINT was written; first byte of payload.
            payload_start: usize,
        };

        /// Write a fixed-size EMHEADER for a member whose payload is exactly
        /// 1, 2, 4, or 8 bytes (LC 0–3).  No NEXTINT is written.
        ///
        /// LC values: 0 → 1 byte, 1 → 2 bytes, 2 → 4 bytes, 3 → 8 bytes.
        pub fn writeEmheaderFixed(self: *Self, member_id: u28, must_understand: bool, lc: u2) !void {
            const mu_bit: u32 = if (must_understand) 0x8000_0000 else 0;
            const word: u32 = mu_bit | (@as(u32, lc) << 28) | @as(u32, member_id);
            try self.writeU32(word);
        }

        /// Reserve an EMHEADER + NEXTINT placeholder for a variable-length member
        /// (LC=4: NEXTINT = byte count).  Call patchEmheader after writing the payload.
        pub fn reserveEmheader(self: *Self, member_id: u28, must_understand: bool) !EmheaderPlaceholder {
            const mu_bit: u32 = if (must_understand) 0x8000_0000 else 0;
            // LC=4: NEXTINT present, encodes payload byte count directly.
            const word: u32 = mu_bit | (4 << 28) | @as(u32, member_id);
            try self.writeU32(word);
            const nextint_offset = self.buf.items.len;
            try self.writeU32(0); // placeholder NEXTINT
            return .{ .nextint_offset = nextint_offset, .payload_start = self.buf.items.len };
        }

        /// Patch the NEXTINT of a reserved EMHEADER with the actual payload byte count.
        pub fn patchEmheader(self: *Self, ph: EmheaderPlaceholder) void {
            const payload: u32 = @intCast(self.buf.items.len - ph.payload_start);
            const p = self.buf.items[ph.nextint_offset..][0..4];
            p[0] = @truncate(payload);
            p[1] = @truncate(payload >> 8);
            p[2] = @truncate(payload >> 16);
            p[3] = @truncate(payload >> 24);
        }
    };
}

// ── KeyHashWriter ────────────────────────────────────────────────────────────

/// Canonical RTPS key-hash writer.
///
/// RTPS §9.6.4.8 computes PID_KEY_HASH from the key fields serialized as
/// PLAIN_CDR2 big-endian.  This writer implements the same duck-typed write
/// API used by generated `serializeKey` methods, but it does not store the
/// whole stream.  It keeps the first 16 bytes and streams every byte into MD5.
pub const KeyHashWriter = struct {
    first16: [16]u8 = .{0} ** 16,
    len: usize = 0,
    pos: usize = 0,
    md5: std.crypto.hash.Md5 = std.crypto.hash.Md5.init(.{}),

    pub fn init() KeyHashWriter {
        return .{};
    }

    fn writeBytes(self: *KeyHashWriter, bytes: []const u8) !void {
        const dst_start = @min(self.len, self.first16.len);
        const dst_avail = self.first16.len - dst_start;
        const copy_len = @min(dst_avail, bytes.len);
        if (copy_len > 0) {
            @memcpy(self.first16[dst_start..][0..copy_len], bytes[0..copy_len]);
        }
        self.md5.update(bytes);
        self.len += bytes.len;
        self.pos += bytes.len;
    }

    fn writePad(self: *KeyHashWriter, boundary: usize) !void {
        const rem = self.pos % boundary;
        if (rem == 0) return;
        const pad = boundary - rem;
        const z: [4]u8 = .{0} ** 4;
        try self.writeBytes(z[0..pad]);
    }

    inline fn align_(wire_size: usize) usize {
        return @min(wire_size, 4); // PLAIN_CDR2 caps primitive alignment at 4.
    }

    pub fn writeU8(self: *KeyHashWriter, v: u8) !void {
        try self.writeBytes(&[_]u8{v});
    }

    pub fn writeI8(self: *KeyHashWriter, v: i8) !void {
        try self.writeU8(@bitCast(v));
    }

    pub fn writeBool(self: *KeyHashWriter, v: bool) !void {
        try self.writeU8(if (v) 1 else 0);
    }

    pub fn writeChar(self: *KeyHashWriter, v: u8) !void {
        try self.writeU8(v);
    }

    pub fn writeWchar(self: *KeyHashWriter, v: u16) !void {
        try self.writeU16(v);
    }

    pub fn writeU16(self: *KeyHashWriter, v: u16) !void {
        try self.writePad(align_(2));
        try self.writeBytes(&[_]u8{ @truncate(v >> 8), @truncate(v) });
    }

    pub fn writeI16(self: *KeyHashWriter, v: i16) !void {
        try self.writeU16(@bitCast(v));
    }

    pub fn writeU32(self: *KeyHashWriter, v: u32) !void {
        try self.writePad(align_(4));
        try self.writeBytes(&[_]u8{
            @truncate(v >> 24),
            @truncate(v >> 16),
            @truncate(v >> 8),
            @truncate(v),
        });
    }

    pub fn writeI32(self: *KeyHashWriter, v: i32) !void {
        try self.writeU32(@bitCast(v));
    }

    pub fn writeF32(self: *KeyHashWriter, v: f32) !void {
        try self.writeU32(@bitCast(v));
    }

    pub fn writeU64(self: *KeyHashWriter, v: u64) !void {
        try self.writePad(align_(8));
        try self.writeBytes(&[_]u8{
            @truncate(v >> 56),
            @truncate(v >> 48),
            @truncate(v >> 40),
            @truncate(v >> 32),
            @truncate(v >> 24),
            @truncate(v >> 16),
            @truncate(v >> 8),
            @truncate(v),
        });
    }

    pub fn writeI64(self: *KeyHashWriter, v: i64) !void {
        try self.writeU64(@bitCast(v));
    }

    pub fn writeF64(self: *KeyHashWriter, v: f64) !void {
        try self.writeU64(@bitCast(v));
    }

    pub fn writeFixed(self: *KeyHashWriter, comptime D: u8, comptime S: u8, value: f64) !void {
        comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
        comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
        const N = comptime (D / 2) + 1;

        const negative = value < 0.0;
        const scale: f64 = comptime blk: {
            var f: f64 = 1.0;
            var i: u8 = 0;
            while (i < S) : (i += 1) f *= 10.0;
            break :blk f;
        };
        const abs_v = @abs(value) * scale + 0.5;
        const max_int: u64 = comptime blk: {
            var m: u64 = 1;
            var i: u8 = 0;
            while (i < D) : (i += 1) m *= 10;
            break :blk m - 1;
        };
        var int_val: u64 = if (abs_v >= @as(f64, @floatFromInt(max_int)) + 1.0)
            max_int
        else
            @intFromFloat(abs_v);

        var digits: [31]u8 = @splat(0);
        {
            var i: usize = D;
            while (i > 0) {
                i -= 1;
                digits[i] = @intCast(int_val % 10);
                int_val /= 10;
            }
        }

        const n2 = comptime 2 * N;
        const pad = comptime n2 - D - 1;
        var nibbles: [n2]u8 = @splat(0);
        @memcpy(nibbles[pad .. pad + D], digits[0..D]);
        nibbles[n2 - 1] = if (negative) 0xD else 0xC;

        var buf: [N]u8 = undefined;
        for (0..N) |j| buf[j] = (nibbles[2 * j] << 4) | nibbles[2 * j + 1];
        try self.writeBytes(&buf);
    }

    pub fn writeString(self: *KeyHashWriter, v: []const u8) !void {
        try self.writeU32(@intCast(v.len + 1));
        try self.writeBytes(v);
        try self.writeBytes(&[_]u8{0});
    }

    pub fn writeWstring(self: *KeyHashWriter, v: []const u16) !void {
        try self.writeU32(@intCast(v.len + 1));
        for (v) |wc| try self.writeU16(wc);
        try self.writeU16(0);
    }

    pub fn final(self: *KeyHashWriter) [16]u8 {
        if (self.len <= self.first16.len) return self.first16;
        var digest: [16]u8 = undefined;
        self.md5.final(&digest);
        return digest;
    }
};

// ── PlCdrWriter ───────────────────────────────────────────────────────────────

/// PL_CDR (ParameterList CDR) writer for RTPS discovery types.
///
/// Wraps `CdrWriter(.xcdr1)` but emits a PL_CDR_LE encapsulation header.
/// Each member is framed with a 4-byte `(pid: u16 LE, len: u16 LE)` header
/// followed by the CDR-encoded value padded to a multiple of 4 bytes.
/// The stream ends with a `PID_SENTINEL (0x0001, 0)` word.
///
/// Alignment is XCDR1 (max 8 bytes), continuous across the entire payload.
pub const PlCdrWriter = struct {
    inner: CdrWriter(.xcdr1),

    pub fn init(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) PlCdrWriter {
        return .{ .inner = CdrWriter(.xcdr1).init(buf, alloc) };
    }

    /// Write the 4-byte PL_CDR_LE encapsulation header.
    /// Must be the first call; resets CDR position to 0.
    pub fn writeEncapHeader(self: *PlCdrWriter) !void {
        try self.inner.buf.appendSlice(self.inner.alloc, &[_]u8{ 0x00, 0x03, 0x00, 0x00 });
        self.inner.pos = 0;
    }

    /// Handle returned by `reservePlParam`; pass to `patchPlParam` after writing value.
    pub const PlParamHandle = struct {
        /// Offset of the u16 length field in `buf`.
        len_offset: usize,
        /// Offset of the first value byte in `buf`.
        buf_value_start: usize,
    };

    /// Write the `(pid, 0)` header placeholder and return a handle.
    /// Write the member value after this call, then call `patchPlParam`.
    pub fn reservePlParam(self: *PlCdrWriter, pid: u16) !PlParamHandle {
        // pid and length fields are raw LE u16; we're always at a 4-byte CDR boundary
        // so writeU16 will add no padding.
        try self.inner.writeU16(pid);
        const len_offset = self.inner.buf.items.len;
        try self.inner.writeU16(0); // placeholder length
        return .{ .len_offset = len_offset, .buf_value_start = self.inner.buf.items.len };
    }

    /// Pad the current value to a 4-byte boundary and patch the length field.
    pub fn patchPlParam(self: *PlCdrWriter, h: PlParamHandle) !void {
        const raw_bytes = self.inner.buf.items.len - h.buf_value_start;
        const pad: usize = (4 - raw_bytes % 4) % 4;
        if (pad > 0) {
            const zeros = [4]u8{ 0, 0, 0, 0 };
            try self.inner.buf.appendSlice(self.inner.alloc, zeros[0..pad]);
            self.inner.pos += pad;
        }
        const padded: u16 = @intCast(raw_bytes + pad);
        self.inner.buf.items[h.len_offset] = @truncate(padded);
        self.inner.buf.items[h.len_offset + 1] = @truncate(padded >> 8);
    }

    /// Write the PID_SENTINEL (0x0001, 0) to terminate the parameter list.
    pub fn writePlSentinel(self: *PlCdrWriter) !void {
        try self.inner.buf.appendSlice(self.inner.alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 });
        self.inner.pos += 4;
    }

    /// Return the raw bytes written so far (including encap header).
    pub fn bytes(self: *const PlCdrWriter) []const u8 {
        return self.inner.buf.items;
    }

    // ── Forwarded primitive writes ─────────────────────────────────────────
    pub fn writeU8(self: *PlCdrWriter, v: u8) !void {
        try self.inner.writeU8(v);
    }
    pub fn writeI8(self: *PlCdrWriter, v: i8) !void {
        try self.inner.writeI8(v);
    }
    pub fn writeBool(self: *PlCdrWriter, v: bool) !void {
        try self.inner.writeBool(v);
    }
    pub fn writeChar(self: *PlCdrWriter, v: u8) !void {
        try self.inner.writeChar(v);
    }
    pub fn writeWchar(self: *PlCdrWriter, v: u16) !void {
        try self.inner.writeWchar(v);
    }
    pub fn writeU16(self: *PlCdrWriter, v: u16) !void {
        try self.inner.writeU16(v);
    }
    pub fn writeI16(self: *PlCdrWriter, v: i16) !void {
        try self.inner.writeI16(v);
    }
    pub fn writeU32(self: *PlCdrWriter, v: u32) !void {
        try self.inner.writeU32(v);
    }
    pub fn writeI32(self: *PlCdrWriter, v: i32) !void {
        try self.inner.writeI32(v);
    }
    pub fn writeF32(self: *PlCdrWriter, v: f32) !void {
        try self.inner.writeF32(v);
    }
    pub fn writeU64(self: *PlCdrWriter, v: u64) !void {
        try self.inner.writeU64(v);
    }
    pub fn writeI64(self: *PlCdrWriter, v: i64) !void {
        try self.inner.writeI64(v);
    }
    pub fn writeF64(self: *PlCdrWriter, v: f64) !void {
        try self.inner.writeF64(v);
    }
    pub fn writeFixed(self: *PlCdrWriter, comptime D: u8, comptime S: u8, v: f64) !void {
        try self.inner.writeFixed(D, S, v);
    }
    pub fn writeString(self: *PlCdrWriter, v: []const u8) !void {
        try self.inner.writeString(v);
    }
    pub fn writeWstring(self: *PlCdrWriter, v: []const u16) !void {
        try self.inner.writeWstring(v);
    }
};

// ── CdrReader ─────────────────────────────────────────────────────────────────

/// CDR reader with runtime endianness and XCDR version.
///
/// Constructed by parsing the 4-byte encapsulation header.  Subsequent reads
/// apply CDR alignment padding and byte-swap for big-endian streams.
///
/// All reads validate that enough bytes remain; `error.EndOfStream` is returned
/// on any truncation.
pub const CdrReader = struct {
    data: []const u8,
    /// Current read position.  Starts at 4 (after the 4-byte encap header).
    pos: usize,
    byte_order: ByteOrder,
    xcdr_version: XcdrVersion,
    /// True when the stream uses PL_CDR (ParameterList) framing.
    /// xcdr_version is .xcdr1 for PL_CDR; this flag distinguishes PL_CDR from plain XCDR1.
    is_pl_cdr: bool,

    // ── Construction ─────────────────────────────────────────────────────

    /// Parse the 4-byte CDR encapsulation header and return a ready reader.
    ///
    /// Supported encapsulation IDs (big-endian u16 in bytes [0..1]):
    ///   0x0000 → XCDR1 big-endian
    ///   0x0001 → XCDR1 little-endian
    ///   0x0002 → PL_CDR (ParameterList) big-endian   (is_pl_cdr=true, xcdr1 alignment)
    ///   0x0003 → PL_CDR (ParameterList) little-endian (is_pl_cdr=true, xcdr1 alignment)
    ///   0x0006 → XCDR2 big-endian
    ///   0x0007 → XCDR2 little-endian
    pub fn init(data: []const u8) !CdrReader {
        if (data.len < 4) return error.InvalidEncapsulation;
        const id: u16 = (@as(u16, data[0]) << 8) | @as(u16, data[1]);
        const byte_order: ByteOrder = switch (id) {
            ENCAP_CDR1_LE, ENCAP_CDR2_LE, ENCAP_PL_CDR_LE => .little,
            ENCAP_CDR1_BE, ENCAP_CDR2_BE, ENCAP_PL_CDR_BE => .big,
            else => return error.InvalidEncapsulation,
        };
        const xcdr_version: XcdrVersion = switch (id) {
            ENCAP_CDR1_LE, ENCAP_CDR1_BE, ENCAP_PL_CDR_LE, ENCAP_PL_CDR_BE => .xcdr1,
            ENCAP_CDR2_LE, ENCAP_CDR2_BE => .xcdr2,
            else => unreachable,
        };
        const is_pl_cdr = (id == ENCAP_PL_CDR_LE or id == ENCAP_PL_CDR_BE);
        return .{
            .data = data,
            .pos = 4,
            .byte_order = byte_order,
            .xcdr_version = xcdr_version,
            .is_pl_cdr = is_pl_cdr,
        };
    }

    // ── Internal helpers ──────────────────────────────────────────────────

    fn alignCap(self: *const CdrReader, wire_size: usize) usize {
        const cap: usize = if (self.xcdr_version == .xcdr1) 8 else 4;
        return @min(wire_size, cap);
    }

    fn alignPos(self: *CdrReader, boundary: usize) void {
        // CDR alignment is from the start of the CDR payload, which starts after
        // the 4-byte encap header (self.pos == 4 at the start of payload reads).
        const cdr_pos = self.pos - 4;
        const rem = cdr_pos % boundary;
        if (rem != 0) self.pos += boundary - rem;
    }

    fn readSlice(self: *CdrReader, n: usize) ![]const u8 {
        if (self.pos + n > self.data.len) return error.EndOfStream;
        const s = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    inline fn maybeSwap16(self: *const CdrReader, raw: u16) u16 {
        return if (self.byte_order == .little) raw else @byteSwap(raw);
    }
    inline fn maybeSwap32(self: *const CdrReader, raw: u32) u32 {
        return if (self.byte_order == .little) raw else @byteSwap(raw);
    }
    inline fn maybeSwap64(self: *const CdrReader, raw: u64) u64 {
        return if (self.byte_order == .little) raw else @byteSwap(raw);
    }

    // ── Status ────────────────────────────────────────────────────────────

    pub fn remaining(self: *const CdrReader) usize {
        return if (self.pos < self.data.len) self.data.len - self.pos else 0;
    }

    pub fn skip(self: *CdrReader, n: usize) !void {
        if (self.pos + n > self.data.len) return error.EndOfStream;
        self.pos += n;
    }

    // ── Primitive reads ───────────────────────────────────────────────────

    pub fn readU8(self: *CdrReader) !u8 {
        return (try self.readSlice(1))[0];
    }

    pub fn readI8(self: *CdrReader) !i8 {
        return @bitCast(try self.readU8());
    }

    pub fn readBool(self: *CdrReader) !bool {
        const v = try self.readU8();
        if (v > 1) return error.InvalidBool;
        return v == 1;
    }

    pub fn readChar(self: *CdrReader) !u8 {
        return self.readU8();
    }

    pub fn readWchar(self: *CdrReader) !u16 {
        return self.readU16();
    }

    pub fn readU16(self: *CdrReader) !u16 {
        self.alignPos(self.alignCap(2));
        const b = try self.readSlice(2);
        const raw: u16 = @as(u16, b[0]) | (@as(u16, b[1]) << 8);
        return self.maybeSwap16(raw);
    }

    pub fn readI16(self: *CdrReader) !i16 {
        return @bitCast(try self.readU16());
    }

    pub fn readU32(self: *CdrReader) !u32 {
        self.alignPos(self.alignCap(4));
        const b = try self.readSlice(4);
        const raw: u32 = @as(u32, b[0]) |
            (@as(u32, b[1]) << 8) |
            (@as(u32, b[2]) << 16) |
            (@as(u32, b[3]) << 24);
        return self.maybeSwap32(raw);
    }

    pub fn readI32(self: *CdrReader) !i32 {
        return @bitCast(try self.readU32());
    }

    pub fn readF32(self: *CdrReader) !f32 {
        return @bitCast(try self.readU32());
    }

    pub fn readU64(self: *CdrReader) !u64 {
        self.alignPos(self.alignCap(8));
        const b = try self.readSlice(8);
        const raw: u64 = @as(u64, b[0]) |
            (@as(u64, b[1]) << 8) |
            (@as(u64, b[2]) << 16) |
            (@as(u64, b[3]) << 24) |
            (@as(u64, b[4]) << 32) |
            (@as(u64, b[5]) << 40) |
            (@as(u64, b[6]) << 48) |
            (@as(u64, b[7]) << 56);
        return self.maybeSwap64(raw);
    }

    pub fn readI64(self: *CdrReader) !i64 {
        return @bitCast(try self.readU64());
    }

    pub fn readF64(self: *CdrReader) !f64 {
        return @bitCast(try self.readU64());
    }

    /// Read a `fixed<D,S>` value from packed BCD (alignment 1).
    pub fn readFixed(self: *CdrReader, comptime D: u8, comptime S: u8) !f64 {
        comptime if (D < 1 or D > 31) @compileError("fixed<D,S>: D must be 1..31");
        comptime if (S > D) @compileError("fixed<D,S>: S must be <= D");
        const N = comptime (D / 2) + 1;
        const n2 = comptime 2 * N;
        const pad = comptime n2 - D - 1; // leading zero nibbles

        const buf = try self.readSlice(N);

        // Unpack nibbles.
        var nibbles: [n2]u8 = undefined;
        for (0..N) |j| {
            nibbles[2 * j] = (buf[j] >> 4) & 0x0F;
            nibbles[2 * j + 1] = buf[j] & 0x0F;
        }

        // Reconstruct integer from D digit nibbles.
        var int_val: u64 = 0;
        for (0..D) |k| {
            const d = nibbles[pad + k];
            if (d > 9) return error.InvalidFixedPtDigit;
            int_val = int_val * 10 + d;
        }

        const sign_nib = nibbles[n2 - 1];
        const negative = (sign_nib == 0xD or sign_nib == 0xB);

        const scale: f64 = comptime blk: {
            var f: f64 = 1.0;
            var i: u8 = 0;
            while (i < S) : (i += 1) f *= 10.0;
            break :blk f;
        };
        const result = @as(f64, @floatFromInt(int_val)) / scale;
        return if (negative) -result else result;
    }

    // ── String / wstring reads ────────────────────────────────────────────

    /// Zero-copy string read: returns a slice pointing into the CDR buffer.
    ///
    /// The slice is valid as long as the buffer passed to `init` stays alive.
    /// Suitable for the DataReader loan pattern (no per-message allocation).
    pub fn readStringZeroCopy(self: *CdrReader) ![]const u8 {
        const len = try self.readU32(); // byte count including NUL
        if (len == 0) return error.InvalidString;
        const bytes = try self.readSlice(len);
        return bytes[0 .. len - 1]; // strip NUL
    }

    pub fn skipString(self: *CdrReader) !void {
        _ = try self.readStringZeroCopy();
    }

    /// Allocating string read; caller owns the returned slice.
    pub fn readString(self: *CdrReader, allocator: std.mem.Allocator) ![]u8 {
        return allocator.dupe(u8, try self.readStringZeroCopy());
    }

    /// Allocating wstring read; caller owns the returned slice.
    ///
    /// CDR wstring length field includes the trailing NUL wchar.
    pub fn readWstring(self: *CdrReader, allocator: std.mem.Allocator) ![]u16 {
        const len = try self.readU32(); // wchar count including NUL
        if (len == 0) return error.InvalidString;
        const char_count = len - 1;
        const buf = try allocator.alloc(u16, char_count);
        errdefer allocator.free(buf);
        for (buf) |*wc| wc.* = try self.readU16();
        _ = try self.readU16(); // discard NUL wchar
        return buf;
    }

    pub fn skipWstring(self: *CdrReader) !void {
        const len = try self.readU32(); // wchar count including NUL
        if (len == 0) return error.InvalidString;
        for (0..len) |_| _ = try self.readU16();
    }

    // ── XCDR2 framing ─────────────────────────────────────────────────────

    /// Read and return a DHEADER value (byte count of the following payload).
    pub fn readDheader(self: *CdrReader) !u32 {
        return self.readU32();
    }

    /// For generated @appendable/@mutable types: skip the DHEADER on XCDR2,
    /// no-op on XCDR1 (no DHEADER in XCDR1).
    pub fn skipDheaderIfXcdr2(self: *CdrReader) !void {
        if (self.xcdr_version == .xcdr2) _ = try self.readDheader();
    }

    /// Decoded EMHEADER for a @mutable type member.
    pub const EmHeader = struct {
        member_id: u28,
        must_understand: bool,
        /// Raw length code (0–6). 0=1B, 1=2B, 2=4B, 3=8B, 4–6=NEXTINT-encoded.
        lc: u3,
        /// Byte count of this member's payload.  Always set:
        ///   LC=0 → 1, LC=1 → 2, LC=2 → 4, LC=3 → 8, LC=4 → NEXTINT,
        ///   LC=5 → NEXTINT×4, LC=6 → NEXTINT×8.
        payload_bytes: u32,
    };

    /// Read an EMHEADER (+ optional NEXTINT) for a @mutable type member.
    ///
    /// XCDR2 §7.3.3.3 — EMHEADER bit layout:
    ///   bit 31: MUST_UNDERSTAND
    ///   bits 28–30: LC (length code)
    ///   bits 0–27: member-id
    ///
    /// LC < 4: no NEXTINT; inline length (0=1B, 1=2B, 2=4B, 3=8B).
    /// LC >= 4: NEXTINT follows; LC=4→bytes, 5→4×, 6→8×, 7→reserved(invalid).
    pub fn readEmheader(self: *CdrReader) !EmHeader {
        const word = try self.readU32();
        const must_understand = (word & 0x8000_0000) != 0;
        const lc: u3 = @truncate((word >> 28) & 0x7);
        const member_id: u28 = @truncate(word & 0x0FFF_FFFF);

        const payload_bytes: u32 = switch (lc) {
            0 => 1,
            1 => 2,
            2 => 4,
            3 => 8,
            4 => try self.readU32(),
            5 => blk: {
                const n = try self.readU32();
                break :blk n * 4;
            },
            6 => blk: {
                const n = try self.readU32();
                break :blk n * 8;
            },
            7 => return error.InvalidEmheader,
        };

        return .{
            .member_id = member_id,
            .must_understand = must_understand,
            .lc = lc,
            .payload_bytes = payload_bytes,
        };
    }

    /// For @mutable types: read the DHEADER and return the absolute reader
    /// position of the first byte *after* the mutable payload.
    ///
    /// Generated deserializers loop `while (reader.mutableHasMore(end))`.
    pub fn readMutableDheader(self: *CdrReader) !usize {
        const size = try self.readDheader();
        return self.pos + size;
    }

    /// True while there are more EMHEADER-framed members to consume.
    pub fn mutableHasMore(self: *const CdrReader, end_pos: usize) bool {
        return self.pos < end_pos;
    }

    /// Skip the payload of an EMHEADER whose member_id is not recognized.
    ///
    /// For LC < 4 the payload is a fixed-size primitive: align then skip.
    /// For LC >= 4 payload_bytes was read from NEXTINT; skip those bytes directly.
    pub fn skipEmheaderPayload(self: *CdrReader, emh: EmHeader) !void {
        if (emh.lc < 4) {
            // Align to the primitive's natural size before skipping it.
            self.alignPos(self.alignCap(emh.payload_bytes));
        }
        try self.skip(emh.payload_bytes);
    }

    // ── PL_CDR (ParameterList) framing ────────────────────────────────────

    /// Decoded PL_CDR parameter header.
    pub const PlParam = struct {
        /// Parameter ID (bits 13:0; bit 15=must_understand, bit 14=vendor).
        pid: u16,
        /// Raw value byte count from the length field (before padding).
        byte_len: u16,
        /// Absolute reader position of the first byte *after* this parameter
        /// (value bytes + padding to next 4-byte boundary).
        /// Always call `seekTo(p.end_pos)` after processing a parameter.
        end_pos: usize,
    };

    /// Read one PL_CDR parameter header.
    ///
    /// Returns `null` on `PID_SENTINEL (0x0001)` — the caller should break
    /// its loop.  For all other PIDs the caller reads the value and then
    /// calls `seekTo(p.end_pos)` to advance past any trailing padding.
    pub fn readPlParam(self: *CdrReader) !?PlParam {
        const pid = try self.readU16();
        const len = try self.readU16();
        if (pid == 0x0001) return null; // PID_SENTINEL
        const padded = ((@as(usize, len) + 3) / 4) * 4;
        return PlParam{ .pid = pid, .byte_len = len, .end_pos = self.pos + padded };
    }

    /// Seek to an absolute position in the data buffer.
    ///
    /// Used by generated deserializers to advance to `p.end_pos` after
    /// processing (or skipping) a PL_CDR parameter value.
    pub fn seekTo(self: *CdrReader, abs_pos: usize) !void {
        if (abs_pos > self.data.len) return error.EndOfStream;
        self.pos = abs_pos;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkWriter(comptime xver: XcdrVersion, buf: *std.ArrayListUnmanaged(u8)) CdrWriter(xver) {
    return CdrWriter(xver).init(buf, testing.allocator);
}

test "key hash writer: <=16 bytes are padded canonical CDR2 big-endian" {
    var w = KeyHashWriter.init();
    try w.writeI32(0x01020304);
    const got = w.final();
    try testing.expectEqualSlices(u8, &[_]u8{
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    }, &got);
}

test "key hash writer: CDR2 big-endian alignment" {
    var w = KeyHashWriter.init();
    try w.writeU8(0x12);
    try w.writeU32(0x01020304);
    const got = w.final();
    try testing.expectEqualSlices(u8, &[_]u8{
        0x12, 0x00, 0x00, 0x00,
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    }, &got);
}

test "key hash writer: >16 bytes returns MD5" {
    const s = "abcdefghijklmnop";
    var w = KeyHashWriter.init();
    try w.writeString(s);

    var bytes = std.ArrayListUnmanaged(u8).empty;
    defer bytes.deinit(testing.allocator);
    try bytes.appendSlice(testing.allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x11 });
    try bytes.appendSlice(testing.allocator, s);
    try bytes.append(testing.allocator, 0);

    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update(bytes.items);
    var expected: [16]u8 = undefined;
    md5.final(&expected);

    const got = w.final();
    try testing.expectEqualSlices(u8, &expected, &got);
}

// ── Encapsulation header ──────────────────────────────────────────────────────

test "encap header: xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00 }, buf.items);
}

test "encap header: xcdr1 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x00, 0x00 }, buf.items);
}

test "reader init: rejects unknown encap id" {
    const bad = [_]u8{ 0xFF, 0xFF, 0x00, 0x00 };
    try testing.expectError(error.InvalidEncapsulation, CdrReader.init(&bad));
}

test "reader init: rejects too-short data" {
    try testing.expectError(error.InvalidEncapsulation, CdrReader.init(&[_]u8{0x00}));
}

// ── Primitive roundtrips (XCDR2 LE) ──────────────────────────────────────────

fn writeAndRead(
    comptime T: type,
    value: T,
    comptime writeFn: fn (*CdrWriter(.xcdr2), T) anyerror!void,
    comptime readFn: fn (*CdrReader) anyerror!T,
) !void {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try writeFn(&w, value);
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(value, try readFn(&r));
}

test "roundtrip: u8" {
    try writeAndRead(u8, 0xAB, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u8) !void {
            try w.writeU8(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u8 {
            return r.readU8();
        }
    }.f);
}
test "roundtrip: i8" {
    try writeAndRead(i8, -42, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i8) !void {
            try w.writeI8(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i8 {
            return r.readI8();
        }
    }.f);
}
test "roundtrip: bool true" {
    try writeAndRead(bool, true, struct {
        fn f(w: *CdrWriter(.xcdr2), v: bool) !void {
            try w.writeBool(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !bool {
            return r.readBool();
        }
    }.f);
}
test "roundtrip: bool false" {
    try writeAndRead(bool, false, struct {
        fn f(w: *CdrWriter(.xcdr2), v: bool) !void {
            try w.writeBool(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !bool {
            return r.readBool();
        }
    }.f);
}
test "roundtrip: u16" {
    try writeAndRead(u16, 0x1234, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u16) !void {
            try w.writeU16(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u16 {
            return r.readU16();
        }
    }.f);
}
test "roundtrip: i16" {
    try writeAndRead(i16, -1000, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i16) !void {
            try w.writeI16(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i16 {
            return r.readI16();
        }
    }.f);
}
test "roundtrip: u32" {
    try writeAndRead(u32, 0xDEAD_BEEF, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u32) !void {
            try w.writeU32(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u32 {
            return r.readU32();
        }
    }.f);
}
test "roundtrip: i32" {
    try writeAndRead(i32, -2_000_000, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i32) !void {
            try w.writeI32(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i32 {
            return r.readI32();
        }
    }.f);
}
test "roundtrip: f32" {
    try writeAndRead(f32, 3.14, struct {
        fn f(w: *CdrWriter(.xcdr2), v: f32) !void {
            try w.writeF32(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !f32 {
            return r.readF32();
        }
    }.f);
}
test "roundtrip: u64" {
    try writeAndRead(u64, 0xCAFE_BABE_DEAD_BEEF, struct {
        fn f(w: *CdrWriter(.xcdr2), v: u64) !void {
            try w.writeU64(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !u64 {
            return r.readU64();
        }
    }.f);
}
test "roundtrip: i64" {
    try writeAndRead(i64, -9_000_000_000, struct {
        fn f(w: *CdrWriter(.xcdr2), v: i64) !void {
            try w.writeI64(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !i64 {
            return r.readI64();
        }
    }.f);
}
test "roundtrip: f64" {
    try writeAndRead(f64, 2.718281828, struct {
        fn f(w: *CdrWriter(.xcdr2), v: f64) !void {
            try w.writeF64(v);
        }
    }.f, struct {
        fn f(r: *CdrReader) !f64 {
            return r.readF64();
        }
    }.f);
}

test "reader: invalid bool byte" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU8(2); // invalid — CDR bool must be 0 or 1
    var r = try CdrReader.init(buf.items);
    try testing.expectError(error.InvalidBool, r.readBool());
}

// ── Alignment ─────────────────────────────────────────────────────────────────

test "alignment: xcdr2 u8 then u32 has 3-byte pad" {
    // CDR pos after u8 = 1; xcdr2 u32 needs align-4: pad 3 → CDR pos=4; +4=8.
    // buf.len = 4 (encap) + 1 (u8) + 3 (pad) + 4 (u32) = 12.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU8(0xAA); // CDR pos=1
    try w.writeU32(0x12345678); // xcdr2: align-4, pad 3 → CDR pos=4; +4=8
    try testing.expectEqual(@as(usize, 12), buf.items.len);
    try testing.expectEqual(@as(u8, 0xAA), buf.items[4]);
    try testing.expectEqual(@as(u8, 0x00), buf.items[5]); // pad
    try testing.expectEqual(@as(u8, 0x00), buf.items[6]); // pad
    try testing.expectEqual(@as(u8, 0x00), buf.items[7]); // pad
    try testing.expectEqual(@as(u8, 0x78), buf.items[8]);
    try testing.expectEqual(@as(u8, 0x56), buf.items[9]);
    try testing.expectEqual(@as(u8, 0x34), buf.items[10]);
    try testing.expectEqual(@as(u8, 0x12), buf.items[11]);
}

test "alignment: xcdr2 u64 capped at 4" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader(); // pos=4
    try w.writeU8(0x01); // pos=5
    try w.writeU64(1); // xcdr2: cap=4 → align=min(8,4)=4 → CDR pos=1 mod 4=1, pad 3 → CDR pos=4, +8=12
    try testing.expectEqual(@as(usize, 16), buf.items.len);
}

test "alignment: xcdr1 u64 after u8 uses 8-byte alignment" {
    // CDR pos after u8 = 1; xcdr1 u64 needs align-8: pad 7 → CDR pos=8, +8=16.
    // buf.len = 4 (encap) + 1 (u8) + 7 (pad) + 8 (u64) = 20.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU8(0x01); // CDR pos=1
    try w.writeU64(1); // xcdr1: cap=8 → align to 8 → CDR pos=8, +8→16
    try testing.expectEqual(@as(usize, 20), buf.items.len);
}

test "alignment: xcdr1 u64 after u32 pads to 8" {
    // CDR pos: u32(4) + u8(1) = 5; xcdr1 u64 needs align-8: pad 3 → CDR pos=8, +8=16.
    // buf.len = 4 (encap) + 4 (u32) + 1 (u8) + 3 (pad) + 8 (u64) = 20.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader(); // CDR pos reset to 0
    try w.writeU32(0); // CDR pos=4
    try w.writeU8(0x01); // CDR pos=5
    try w.writeU64(1); // xcdr1: align to 8 → pad 3 → CDR pos=8, +8=16
    try testing.expectEqual(@as(usize, 20), buf.items.len);
}

// ── Known byte sequences ──────────────────────────────────────────────────────

test "known bytes: i32(1) xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00 }, buf.items);
}

test "known bytes: i32(-1) xcdr2 le" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(-1);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF }, buf.items);
}

// ── String ────────────────────────────────────────────────────────────────────

test "string: known bytes for 'hi'" {
    // "hi": len=3 (2+NUL), then [h i 0x00]
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("hi");
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x07, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 'h', 'i', 0x00 }, buf.items);
}

test "string: roundtrip zero-copy" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("hello");
    var r = try CdrReader.init(buf.items);
    try testing.expectEqualStrings("hello", try r.readStringZeroCopy());
}

test "string: empty roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("");
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(usize, 0), (try r.readStringZeroCopy()).len);
}

test "string: allocating read matches zero-copy" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeString("test");
    var r1 = try CdrReader.init(buf.items);
    const zc = try r1.readStringZeroCopy();
    var r2 = try CdrReader.init(buf.items);
    const owned = try r2.readString(testing.allocator);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings(zc, owned);
}

// ── Wstring ───────────────────────────────────────────────────────────────────

test "wstring: roundtrip" {
    const wstr = [_]u16{ 'h', 'i' };
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeWstring(&wstr);
    var r = try CdrReader.init(buf.items);
    const got = try r.readWstring(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u16, &wstr, got);
}

// ── Big-endian reader ─────────────────────────────────────────────────────────

test "reader: xcdr2 big-endian i32(1)" {
    // XCDR2 BE encap = [00 06 00 00]; big-endian i32(1) = [00 00 00 01]
    const data = [_]u8{ 0x00, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01 };
    var r = try CdrReader.init(&data);
    try testing.expectEqual(ByteOrder.big, r.byte_order);
    try testing.expectEqual(@as(i32, 1), try r.readI32());
}

test "reader: xcdr1 big-endian u16(0x1234)" {
    const data = [_]u8{ 0x00, 0x00, 0x00, 0x00, 0x12, 0x34 };
    var r = try CdrReader.init(&data);
    try testing.expectEqual(@as(u16, 0x1234), try r.readU16());
}

// ── Error cases ───────────────────────────────────────────────────────────────

test "EndOfStream on truncated u32" {
    const data = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xAA }; // only 1 byte after header
    var r = try CdrReader.init(&data);
    try testing.expectError(error.EndOfStream, r.readU32());
}

// ── DHEADER ───────────────────────────────────────────────────────────────────

test "dheader: writeDheader and readDheader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeDheader(42);
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(u32, 42), try r.readDheader());
}

test "dheader: reserveDheader and patchDheader" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeI32(10); // 4 bytes of payload
    try w.writeI32(20); // 4 bytes
    w.patchDheader(dh);
    // DHEADER should now be 8 (two i32s)
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(u32, 8), try r.readDheader());
    try testing.expectEqual(@as(i32, 10), try r.readI32());
    try testing.expectEqual(@as(i32, 20), try r.readI32());
}

// ── EMHEADER ─────────────────────────────────────────────────────────────────

test "emheader: LC=4 must_understand=true member_id=5" {
    // EMHEADER = 0xC000_0005: MU=1 LC=4 id=5; NEXTINT=10
    // bit 31=MU, bits 30-28=LC, bits 27-0=member_id
    // 0xC000_0005 = 1100_0000...0000_0101 → MU=1 LC=4 id=5
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU32(0xC000_0005);
    try w.writeU32(10);
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 5), em.member_id);
    try testing.expect(em.must_understand);
    try testing.expectEqual(@as(u3, 4), em.lc);
    try testing.expectEqual(@as(u32, 10), em.payload_bytes);
}

test "emheader: LC=2 no nextint member_id=0" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeU32(0x2000_0000); // MU=0 LC=2 id=0
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 0), em.member_id);
    try testing.expect(!em.must_understand);
    try testing.expectEqual(@as(u3, 2), em.lc);
    try testing.expectEqual(@as(u32, 4), em.payload_bytes); // LC=2 → 4 bytes
}

test "emheader: writeEmheaderFixed + readEmheader round-trip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeEmheaderFixed(7, true, 3); // member_id=7, must_understand, LC=3 (8 bytes)
    try w.writeU64(0xDEAD_BEEF_1234_5678);
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 7), em.member_id);
    try testing.expect(em.must_understand);
    try testing.expectEqual(@as(u3, 3), em.lc);
    try testing.expectEqual(@as(u32, 8), em.payload_bytes);
    try testing.expectEqual(@as(u64, 0xDEAD_BEEF_1234_5678), try r.readU64());
}

test "emheader: reserveEmheader + patchEmheader + readEmheader round-trip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const ph = try w.reserveEmheader(3, false); // member_id=3, LC=4
    try w.writeString("hello"); // 4 (len) + 5 (bytes) + 1 (NUL) = 10 bytes
    w.patchEmheader(ph);
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 3), em.member_id);
    try testing.expect(!em.must_understand);
    try testing.expectEqual(@as(u3, 4), em.lc);
    try testing.expectEqual(@as(u32, 10), em.payload_bytes);
    const s = try r.readString(testing.allocator);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("hello", s);
}

test "emheader: skipEmheaderPayload for unknown fixed-size member" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeEmheaderFixed(99, false, 2); // unknown member_id=99, LC=2 (4 bytes)
    try w.writeI32(42);
    try w.writeI32(100); // sentinel after the skipped member
    var r = try CdrReader.init(buf.items);
    const em = try r.readEmheader();
    try testing.expectEqual(@as(u28, 99), em.member_id);
    try r.skipEmheaderPayload(em);
    try testing.expectEqual(@as(i32, 100), try r.readI32());
}

test "emheader: mutableHasMore + readMutableDheader loop" {
    // Encode a simple mutable struct: DHEADER + EMHEADER(0,LC=2) + i32 + EMHEADER(1,LC=2) + i32
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const dh = try w.reserveDheader();
    try w.writeEmheaderFixed(0, false, 2);
    try w.writeI32(11);
    try w.writeEmheaderFixed(1, false, 2);
    try w.writeI32(22);
    w.patchDheader(dh);

    var r = try CdrReader.init(buf.items);
    const em_end = try r.readMutableDheader();
    var x: i32 = 0;
    var y: i32 = 0;
    while (r.mutableHasMore(em_end)) {
        const emh = try r.readEmheader();
        switch (emh.member_id) {
            0 => x = try r.readI32(),
            1 => y = try r.readI32(),
            else => try r.skipEmheaderPayload(emh),
        }
    }
    try testing.expectEqual(@as(i32, 11), x);
    try testing.expectEqual(@as(i32, 22), y);
}

// ── Multi-field struct simulation ─────────────────────────────────────────────

test "Point { i32 x; i32 y; }" {
    const Point = struct { x: i32, y: i32 };
    const orig = Point{ .x = 10, .y = -20 };

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeI32(orig.x);
    try w.writeI32(orig.y);

    var r = try CdrReader.init(buf.items);
    const got = Point{ .x = try r.readI32(), .y = try r.readI32() };
    try testing.expectEqual(orig, got);
}

test "mixed struct: bool + u32 + f64" {
    const Msg = struct { flag: bool, id: u32, value: f64 };
    const orig = Msg{ .flag = true, .id = 0xDEAD, .value = 1.5 };

    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    try w.writeBool(orig.flag);
    try w.writeU32(orig.id);
    try w.writeF64(orig.value);

    var r = try CdrReader.init(buf.items);
    const got = Msg{
        .flag = try r.readBool(),
        .id = try r.readU32(),
        .value = try r.readF64(),
    };
    try testing.expectEqual(orig, got);
}

test "reserveDheaderMaybe: xcdr2 reserves and patches a DHEADER" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr2, &buf);
    try w.writeEncapHeader();
    const off = try w.reserveDheaderMaybe();
    try testing.expect(off != null);
    try w.writeI32(42);
    w.patchDheaderMaybe(off);
    // DHEADER at offset should be 4 (one i32 worth of payload)
    var r = try CdrReader.init(buf.items);
    const dh = try r.readDheader();
    try testing.expectEqual(@as(u32, 4), dh);
    try testing.expectEqual(@as(i32, 42), try r.readI32());
}

test "reserveDheaderMaybe: xcdr1 returns null, patchDheaderMaybe is no-op" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    const off = try w.reserveDheaderMaybe();
    try testing.expect(off == null);
    w.patchDheaderMaybe(off); // must not crash
    try w.writeI32(7);
    var r = try CdrReader.init(buf.items);
    try testing.expectEqual(@as(i32, 7), try r.readI32());
}

test "skipDheaderIfXcdr2: xcdr2 skips DHEADER, xcdr1 is no-op" {
    // xcdr2: writer emits DHEADER + payload; reader skips DHEADER
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(testing.allocator);
        var w = mkWriter(.xcdr2, &buf);
        try w.writeEncapHeader();
        const off = try w.reserveDheader();
        try w.writeI32(99);
        w.patchDheader(off);
        var r = try CdrReader.init(buf.items);
        try r.skipDheaderIfXcdr2(); // skip the DHEADER
        try testing.expectEqual(@as(i32, 99), try r.readI32());
    }
    // xcdr1: no DHEADER written, skipDheaderIfXcdr2 is a no-op
    {
        var buf = std.ArrayListUnmanaged(u8).empty;
        defer buf.deinit(testing.allocator);
        var w = mkWriter(.xcdr1, &buf);
        try w.writeEncapHeader();
        try w.writeI32(55);
        var r = try CdrReader.init(buf.items);
        try r.skipDheaderIfXcdr2(); // no-op on xcdr1
        try testing.expectEqual(@as(i32, 55), try r.readI32());
    }
}

// ── PL_CDR ────────────────────────────────────────────────────────────────────

test "pl_cdr: encap header bytes" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x03, 0x00, 0x00 }, buf.items);
}

test "pl_cdr: reader init accepts PL_CDR_LE" {
    const data = [_]u8{ 0x00, 0x03, 0x00, 0x00 }; // just the encap header
    const r = try CdrReader.init(&data);
    try testing.expect(r.is_pl_cdr);
    try testing.expectEqual(ByteOrder.little, r.byte_order);
    try testing.expectEqual(XcdrVersion.xcdr1, r.xcdr_version);
}

test "pl_cdr: single i32 param roundtrip" {
    // Encode: pid=5, value=i32(42); decode
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h = try w.reservePlParam(5);
    try w.writeI32(42);
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    try testing.expect(r.is_pl_cdr);
    var found: i32 = 0;
    while (try r.readPlParam()) |p| {
        switch (p.pid & 0x3FFF) {
            5 => found = try r.readI32(),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(i32, 42), found);
}

test "pl_cdr: multiple params with padding" {
    // Encode: pid=0x0010 → u8(0xAB), pid=0x0020 → u32(0xDEADBEEF); verify lengths + padding.
    // Note: pid=0x0001 is PID_SENTINEL, pid=0x0000 is PID_PAD — use safe values.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    // param pid=0x10, value=u8 (1 byte → padded to 4)
    const h1 = try w.reservePlParam(0x0010);
    try w.writeU8(0xAB);
    try w.patchPlParam(h1);
    // param pid=0x20, value=u32 (4 bytes → no extra padding)
    const h2 = try w.reservePlParam(0x0020);
    try w.writeU32(0xDEAD_BEEF);
    try w.patchPlParam(h2);
    try w.writePlSentinel();

    // Layout: [encap:4][pid1:2 len1:2 val:1 pad:3][pid2:2 len2:2 val:4][sentinel:4]
    try testing.expectEqual(@as(usize, 4 + 4 + 1 + 3 + 4 + 4 + 4), buf.items.len);

    var r = try CdrReader.init(buf.items);
    var v1: u8 = 0;
    var v2: u32 = 0;
    while (try r.readPlParam()) |p| {
        switch (p.pid & 0x3FFF) {
            0x0010 => v1 = try r.readU8(),
            0x0020 => v2 = try r.readU32(),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(u8, 0xAB), v1);
    try testing.expectEqual(@as(u32, 0xDEAD_BEEF), v2);
}

test "pl_cdr: unknown pid is skipped via seekTo" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h_unknown = try w.reservePlParam(99);
    try w.writeI32(0);
    try w.writeI32(0); // 8-byte unknown payload
    try w.patchPlParam(h_unknown);
    const h_known = try w.reservePlParam(7);
    try w.writeI32(777);
    try w.patchPlParam(h_known);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    var found: i32 = 0;
    while (try r.readPlParam()) |p| {
        switch (p.pid & 0x3FFF) {
            7 => found = try r.readI32(),
            else => {}, // unknown: seekTo advances past it
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(i32, 777), found);
}

test "pl_cdr: xcdr1 8-byte alignment within param" {
    // An f64 inside a param uses XCDR1 alignment (up to 8 bytes).
    // Layout: [encap:4][pid:2 len:2 u8:1 pad7:7 f64:8][sentinel:4] = 4+4+1+7+8+4 = 28
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    const h = try w.reservePlParam(10);
    try w.writeU8(0x01); // CDR pos=5 after encap+pid+len+u8
    try w.writeF64(1.5); // xcdr1: aligns to 8; CDR pos=5→align8→pad3? No wait...
    // After encap (pos=0), pid(u16→pos=2), len(u16→pos=4 in buf BUT inner pos tracks CDR)
    // Actually inner pos starts at 0 after encap, then writeU16(pid)→pos=2, writeU16(0)→pos=4
    // So value starts at CDR pos=4. writeU8→pos=5. writeF64 xcdr1 align=8 → CDR pos=5 needs
    // to go to 8, so pad=3. f64 at CDR pos=8, ends at CDR pos=16. Total value=1+3+8=12 bytes.
    // patchPlParam: raw_bytes=12, pad=0 (already multiple of 4). len=12.
    try w.patchPlParam(h);
    try w.writePlSentinel();

    var r = try CdrReader.init(buf.items);
    var val: f64 = 0;
    while (try r.readPlParam()) |p| {
        switch (p.pid & 0x3FFF) {
            10 => {
                _ = try r.readU8(); // skip the u8
                val = try r.readF64();
            },
            else => {},
        }
        try r.seekTo(p.end_pos);
    }
    try testing.expectEqual(@as(f64, 1.5), val);
}

test "pl_cdr: @pl_repeated round-trip: three i32 elements with same PID" {
    // Simulate what the generated @pl_repeated serializer emits: three separate
    // parameters with the same PID (0x0032), each carrying one i32.
    const pid: u16 = 0x0032;
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    for ([_]i32{ 10, 20, 30 }) |v| {
        const h = try w.reservePlParam(pid);
        try w.writeI32(v);
        try w.patchPlParam(h);
    }
    try w.writePlSentinel();

    // Deserialize: accumulate all occurrences of PID 0x0032 into a list.
    var items = std.ArrayListUnmanaged(i32).empty;
    defer items.deinit(testing.allocator);
    var r = try CdrReader.init(buf.items);
    try testing.expect(r.is_pl_cdr);
    while (try r.readPlParam()) |p| {
        switch (p.pid & 0x3FFF) {
            pid => try items.append(testing.allocator, try r.readI32()),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }

    try testing.expectEqual(@as(usize, 3), items.items.len);
    try testing.expectEqual(@as(i32, 10), items.items[0]);
    try testing.expectEqual(@as(i32, 20), items.items[1]);
    try testing.expectEqual(@as(i32, 30), items.items[2]);
}

// ── fixed<D,S> roundtrips ─────────────────────────────────────────────────────

test "fixed<5,2>: positive roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(5, 2, 123.45);
    // Expected BCD: digits=[1,2,3,4,5], sign=0xC → bytes [0x12,0x34,0x5C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x5C }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 123.45), try r.readFixed(5, 2), 0.001);
}

test "fixed<5,2>: negative roundtrip" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(5, 2, -123.45);
    // Sign nibble 0xD → bytes [0x12,0x34,0x5D]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x12, 0x34, 0x5D }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, -123.45), try r.readFixed(5, 2), 0.001);
}

test "fixed<4,2>: even-digit padding roundtrip" {
    // D=4 (even) → leading zero nibble; N=3 bytes
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(4, 2, 12.34);
    // Nibbles: [0,1,2,3,4,0xC] → bytes [0x01,0x23,0x4C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x23, 0x4C }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 12.34), try r.readFixed(4, 2), 0.001);
}

test "fixed<1,0>: single digit" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(1, 0, 7.0);
    // N=1 byte, nibbles [7,0xC] → 0x7C
    try testing.expectEqualSlices(u8, &[_]u8{0x7C}, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 7.0), try r.readFixed(1, 0), 0.001);
}

test "fixed<3,1>: zero value" {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = mkWriter(.xcdr1, &buf);
    try w.writeEncapHeader();
    try w.writeFixed(3, 1, 0.0);
    // digits=[0,0,0], sign=0xC → N=2 bytes, nibbles [0,0,0,0xC] → [0x00,0x0C]
    try testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x0C }, buf.items[4..]);
    var r = try CdrReader.init(buf.items);
    try testing.expectApproxEqAbs(@as(f64, 0.0), try r.readFixed(3, 1), 0.001);
}

test "pl_cdr: @pl_repeated round-trip: mixed PID types" {
    // Interleaved repeated params (PID_A = 0x0032, PID_B = 0x0033) to verify
    // that deserialization correctly routes each occurrence to the right sequence.
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(testing.allocator);
    var w = PlCdrWriter.init(&buf, testing.allocator);
    try w.writeEncapHeader();
    // Emit: A(1), B(100), A(2), B(200), A(3)
    const ha1 = try w.reservePlParam(0x0032);
    try w.writeI32(1);
    try w.patchPlParam(ha1);
    const hb1 = try w.reservePlParam(0x0033);
    try w.writeI32(100);
    try w.patchPlParam(hb1);
    const ha2 = try w.reservePlParam(0x0032);
    try w.writeI32(2);
    try w.patchPlParam(ha2);
    const hb2 = try w.reservePlParam(0x0033);
    try w.writeI32(200);
    try w.patchPlParam(hb2);
    const ha3 = try w.reservePlParam(0x0032);
    try w.writeI32(3);
    try w.patchPlParam(ha3);
    try w.writePlSentinel();

    var list_a = std.ArrayListUnmanaged(i32).empty;
    defer list_a.deinit(testing.allocator);
    var list_b = std.ArrayListUnmanaged(i32).empty;
    defer list_b.deinit(testing.allocator);

    var r = try CdrReader.init(buf.items);
    while (try r.readPlParam()) |p| {
        switch (p.pid & 0x3FFF) {
            0x0032 => try list_a.append(testing.allocator, try r.readI32()),
            0x0033 => try list_b.append(testing.allocator, try r.readI32()),
            else => {},
        }
        try r.seekTo(p.end_pos);
    }

    try testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, list_a.items);
    try testing.expectEqualSlices(i32, &[_]i32{ 100, 200 }, list_b.items);
}
