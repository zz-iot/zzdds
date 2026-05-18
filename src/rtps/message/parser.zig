//! RTPS message parser (RTPS 2.5 §9.4).
//!
//! Parses a raw UDP payload into a validated Header + a sequence of SubMessages.
//! All parsed data borrows from the input slice — no allocations.
//!
//! Usage:
//!   var it = try MessageIterator.init(raw_bytes);
//!   while (try it.next()) |sm| { ... }

const std = @import("std");
const Header = @import("header.zig").Header;
const sub = @import("submessage.zig");
const SubMessage = sub.SubMessage;
const SubMessageHeader = sub.SubMessageHeader;
const SubMessageId = sub.SubMessageId;
const SubMessageKind = sub.SubMessageKind;
const sn_module = @import("../sequence_number.zig");
const SequenceNumber = sn_module.SequenceNumber;
const SequenceNumberWire = sn_module.SequenceNumberWire;
const EntityId = @import("../guid.zig").EntityId;
const GuidPrefix = @import("../guid.zig").GuidPrefix;
const RtpsTimestamp = @import("../../util/time.zig").RtpsTimestamp;

pub const ParseError = error{
    TooShort,
    BadProtocolId,
    BadSubmessageLength,
    MalformedSubmessage,
};

// ── Low-level reader ──────────────────────────────────────────────────────────

/// Cursor over a byte slice. All read functions advance the position.
const Reader = struct {
    buf: []const u8,
    pos: usize,
    le: bool, // current endianness for multi-byte reads

    fn init(buf: []const u8, little_endian: bool) Reader {
        return .{ .buf = buf, .pos = 0, .le = little_endian };
    }

    fn remaining(self: Reader) usize {
        return self.buf.len - self.pos;
    }

    fn ensureAvailable(self: Reader, n: usize) ParseError!void {
        if (self.remaining() < n) return error.TooShort;
    }

    fn readU8(self: *Reader) ParseError!u8 {
        try self.ensureAvailable(1);
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    fn readU16(self: *Reader) ParseError!u16 {
        try self.ensureAvailable(2);
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], if (self.le) .little else .big);
        self.pos += 2;
        return v;
    }

    fn readU32(self: *Reader) ParseError!u32 {
        try self.ensureAvailable(4);
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], if (self.le) .little else .big);
        self.pos += 4;
        return v;
    }

    fn readI32(self: *Reader) ParseError!i32 {
        return @bitCast(try self.readU32());
    }

    fn readBytes(self: *Reader, n: usize) ParseError![]const u8 {
        try self.ensureAvailable(n);
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn readEntityId(self: *Reader) ParseError!EntityId {
        const bytes = try self.readBytes(4);
        return .{ .entity_key = bytes[0..3].*, .entity_kind = bytes[3] };
    }

    fn readSequenceNumber(self: *Reader) ParseError!SequenceNumber {
        const high = try self.readI32();
        const low = try self.readU32();
        return sn_module.fromWire(.{ .high = high, .low = low });
    }

    fn readGuidPrefix(self: *Reader) ParseError!GuidPrefix {
        const bytes = try self.readBytes(12);
        var gp: GuidPrefix = undefined;
        @memcpy(&gp.bytes, bytes);
        return gp;
    }

    fn readTimestamp(self: *Reader) ParseError!RtpsTimestamp {
        const seconds = try self.readU32();
        const fraction = try self.readU32();
        return .{ .seconds = seconds, .fraction = fraction };
    }

    // Align position to a 4-byte boundary (RTPS §9.4.2.11).
    fn align4(self: *Reader) void {
        const rem = self.pos % 4;
        if (rem != 0) self.pos += 4 - rem;
    }
};

// ── Inline QoS parser ─────────────────────────────────────────────────────────

/// Parse inline QoS parameters from `r` into `param_buf`.
/// Returns an InlineQos view over the filled slice.
/// Stops at PID_SENTINEL or when `r` runs out.
fn parseInlineQos(
    r: *Reader,
    param_buf: []sub.InlineQosParam,
) ParseError!sub.InlineQos {
    var count: usize = 0;
    while (true) {
        const pid_raw = try r.readU16();
        const pid: sub.ParameterId = @enumFromInt(pid_raw);
        const length = try r.readU16();
        if (pid == .sentinel) break;
        const value = try r.readBytes(length);
        if (count < param_buf.len) {
            param_buf[count] = .{ .pid = pid, .value = value };
            count += 1;
        }
        // Align to 4 bytes after each parameter.
        r.align4();
    }
    return .{ .params = param_buf[0..count] };
}

// ── SequenceNumberSet parser ──────────────────────────────────────────────────

fn parseSequenceNumberSet(r: *Reader) ParseError!sub.SequenceNumberSet {
    const base = try r.readSequenceNumber(); // 8 bytes
    const num_bits = try r.readU32();
    if (num_bits > 256) return error.MalformedSubmessage;
    var bitmap = [_]u32{0} ** 8;
    const num_words = (num_bits + 31) / 32;
    for (bitmap[0..num_words]) |*w| w.* = try r.readU32();
    return .{ .base = base, .num_bits = num_bits, .bitmap = bitmap };
}

// ── FragmentNumberSet parser ──────────────────────────────────────────────────

fn parseFragmentNumberSet(r: *Reader) ParseError!sub.FragmentNumberSet {
    const base = try r.readU32();
    const num_bits = try r.readU32();
    if (num_bits > 256) return error.MalformedSubmessage;
    var bitmap = [_]u32{0} ** 8;
    const num_words = (num_bits + 31) / 32;
    for (bitmap[0..num_words]) |*w| w.* = try r.readU32();
    return .{ .base = base, .num_bits = num_bits, .bitmap = bitmap };
}

// ── Per-submessage parsers ────────────────────────────────────────────────────

fn parseData(
    flags: u8,
    r: *Reader,
    content: []const u8,
    param_buf: []sub.InlineQosParam,
) ParseError!sub.DataSubmessage {
    _ = try r.readU16(); // extraFlags (reserved, always 0)
    const qos_offset = try r.readU16(); // octetsToInlineQos
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const sn = try r.readSequenceNumber();

    // Skip any fields between standard fields and inline QoS (future extensions).
    // qos_offset is measured from the byte after the two u16 fields above.
    // Standard value is 16 (reader_id 4 + writer_id 4 + sn 8).
    // Already consumed 16 bytes; skip extra if qos_offset > 16.
    if (qos_offset > 16) {
        const extra = qos_offset - 16;
        _ = try r.readBytes(extra);
    }

    var iqos: ?sub.InlineQos = null;
    if (flags & sub.DataFlags.inline_qos != 0) {
        iqos = try parseInlineQos(r, param_buf);
    }

    // Payload: everything remaining in this submessage's content window.
    const payload_start = r.pos;
    const payload: []const u8 = if (flags & sub.DataFlags.data_present != 0 or
        flags & sub.DataFlags.key_flag != 0)
        content[payload_start..]
    else
        &.{};

    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .writer_sn = sn,
        .inline_qos = iqos,
        .serialized_payload = payload,
    };
}

fn parseDataFrag(
    flags: u8,
    r: *Reader,
    content: []const u8,
    param_buf: []sub.InlineQosParam,
) ParseError!sub.DataFragSubmessage {
    _ = try r.readU16(); // extraFlags
    const qos_offset = try r.readU16();
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const sn = try r.readSequenceNumber();
    const frag_start = try r.readU32();
    const frag_count = try r.readU16();
    const frag_size = try r.readU16();
    const data_size = try r.readU32();

    if (qos_offset > 28) {
        _ = try r.readBytes(qos_offset - 28);
    }

    var iqos: ?sub.InlineQos = null;
    if (flags & sub.DataFragFlags.inline_qos != 0) {
        iqos = try parseInlineQos(r, param_buf);
    }

    const payload_start = r.pos;
    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .writer_sn = sn,
        .fragment_starting_num = frag_start,
        .fragments_in_submessage = frag_count,
        .fragment_size = frag_size,
        .data_size = data_size,
        .inline_qos = iqos,
        .serialized_payload = content[payload_start..],
    };
}

fn parseHeartbeat(flags: u8, r: *Reader) ParseError!sub.HeartbeatSubmessage {
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const first_sn = try r.readSequenceNumber();
    const last_sn = try r.readSequenceNumber();
    const count = try r.readI32();
    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .first_sn = first_sn,
        .last_sn = last_sn,
        .count = count,
    };
}

fn parseAckNack(flags: u8, r: *Reader) ParseError!sub.AckNackSubmessage {
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const sns = try parseSequenceNumberSet(r);
    const count = try r.readI32();
    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .reader_sn_state = sns,
        .count = count,
    };
}

fn parseGap(flags: u8, r: *Reader) ParseError!sub.GapSubmessage {
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const gap_start = try r.readSequenceNumber();
    const gap_list = try parseSequenceNumberSet(r);
    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .gap_start = gap_start,
        .gap_list = gap_list,
    };
}

fn parseInfoTs(flags: u8, r: *Reader) ParseError!sub.InfoTsSubmessage {
    if (flags & sub.InfoTsFlags.invalidate_ts != 0) {
        return .{ .flags = flags, .timestamp = null };
    }
    const ts = try r.readTimestamp();
    return .{ .flags = flags, .timestamp = ts };
}

fn parseInfoDst(r: *Reader) ParseError!sub.InfoDstSubmessage {
    const prefix = try r.readGuidPrefix();
    return .{ .guid_prefix = prefix };
}

fn parseInfoSrc(r: *Reader) ParseError!sub.InfoSrcSubmessage {
    _ = try r.readU32(); // unused (protocol version / vendor padding)
    const pv0 = try r.readU8();
    const pv1 = try r.readU8();
    const vi0 = try r.readU8();
    const vi1 = try r.readU8();
    const prefix = try r.readGuidPrefix();
    return .{
        .protocol_version = .{ pv0, pv1 },
        .vendor_id = .{ vi0, vi1 },
        .guid_prefix = prefix,
    };
}

fn parseHeartbeatFrag(flags: u8, r: *Reader) ParseError!sub.HeartbeatFragSubmessage {
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const sn = try r.readSequenceNumber();
    const last_frag = try r.readU32();
    const count = try r.readI32();
    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .writer_sn = sn,
        .last_fragment_num = last_frag,
        .count = count,
    };
}

fn parseNackFrag(flags: u8, r: *Reader) ParseError!sub.NackFragSubmessage {
    const reader_id = try r.readEntityId();
    const writer_id = try r.readEntityId();
    const sn = try r.readSequenceNumber();
    const fns_ = try parseFragmentNumberSet(r);
    const count = try r.readI32();
    return .{
        .flags = flags,
        .reader_entity_id = reader_id,
        .writer_entity_id = writer_id,
        .writer_sn = sn,
        .fragment_number_state = fns_,
        .count = count,
    };
}

// ── MessageIterator ───────────────────────────────────────────────────────────

/// Iterator over submessages in one RTPS message.
/// All data borrows from the original byte slice — do not free it while
/// the iterator or any returned SubMessage is live.
///
/// For inline QoS, the caller must supply an InlineQosParam scratch buffer.
/// A fixed-size stack buffer of 32 entries is more than enough for any real
/// RTPS message.
pub const MessageIterator = struct {
    buf: []const u8,
    pos: usize, // current offset into buf (after the 20-byte header)
    header: Header,

    pub fn init(buf: []const u8) ParseError!MessageIterator {
        if (buf.len < 20) return error.TooShort;
        const h = Header.fromBytes(buf[0..20]) orelse return error.BadProtocolId;
        return .{ .buf = buf, .pos = 20, .header = h };
    }

    /// Parse and return the next submessage, or null at end of message.
    /// `param_buf` is scratch space for inline QoS parameters — must live
    /// at least as long as the returned DataSubmessage/DataFragSubmessage.
    pub fn next(
        self: *MessageIterator,
        param_buf: []sub.InlineQosParam,
    ) ParseError!?SubMessage {
        if (self.pos >= self.buf.len) return null;
        if (self.buf.len - self.pos < 4) return error.BadSubmessageLength;

        // Read the 4-byte submessage header.
        // octetsToNextHeader is always little-endian per RTPS §9.4.2 note.
        const smh = SubMessageHeader{
            .submessage_id = self.buf[self.pos],
            .flags = self.buf[self.pos + 1],
            .octets_to_next_header = std.mem.readInt(u16, self.buf[self.pos + 2 ..][0..2], .little),
        };
        self.pos += 4;

        const le = smh.isLittleEndian();
        const id = smh.id();
        var clen = @as(usize, smh.contentLen());

        // octetsToNextHeader == 0 means "extends to end of RTPS message"
        // but only for the last submessage (§9.4.2).
        if (clen == 0) clen = self.buf.len - self.pos;

        if (self.pos + clen > self.buf.len) return error.BadSubmessageLength;

        const content = self.buf[self.pos .. self.pos + clen];
        self.pos += clen;

        var r = Reader.init(content, le);

        const sm: SubMessage = switch (id) {
            .data => .{ .data = try parseData(smh.flags, &r, content, param_buf) },
            .data_frag => .{ .data_frag = try parseDataFrag(smh.flags, &r, content, param_buf) },
            .heartbeat => .{ .heartbeat = try parseHeartbeat(smh.flags, &r) },
            .acknack => .{ .acknack = try parseAckNack(smh.flags, &r) },
            .gap => .{ .gap = try parseGap(smh.flags, &r) },
            .info_ts => .{ .info_ts = try parseInfoTs(smh.flags, &r) },
            .info_dst => .{ .info_dst = try parseInfoDst(&r) },
            .info_src => .{ .info_src = try parseInfoSrc(&r) },
            .heartbeat_frag => .{ .heartbeat_frag = try parseHeartbeatFrag(smh.flags, &r) },
            .nack_frag => .{ .nack_frag = try parseNackFrag(smh.flags, &r) },
            .sec_body => .{ .sec_body = content },
            .sec_prefix => .{ .sec_prefix = content },
            .sec_postfix => .{ .sec_postfix = content },
            .sec_hb_prefix => .{ .sec_hb_prefix = content },
            .sec_hb_postfix => .{ .sec_hb_postfix = content },
            .pad, .info_reply_ip4, .info_reply => return self.next(param_buf), // skip
            _ => .{ .unknown = content },
        };

        return sm;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "MessageIterator rejects short buffer" {
    const buf: [10]u8 = .{0} ** 10;
    try std.testing.expectError(error.TooShort, MessageIterator.init(&buf));
}

test "MessageIterator rejects bad magic" {
    var buf: [20]u8 = .{0} ** 20;
    buf[0] = 'X';
    try std.testing.expectError(error.BadProtocolId, MessageIterator.init(&buf));
}

test "MessageIterator parses header-only message (no submessages)" {
    // Build a valid RTPS header with no submessages.
    var buf: [20]u8 = .{0} ** 20;
    @memcpy(buf[0..4], "RTPS");
    buf[4] = 2;
    buf[5] = 5; // version 2.5
    buf[6] = 0x01;
    buf[7] = 0x23; // vendor id
    // guid prefix: zeros

    var it = try MessageIterator.init(&buf);
    var params: [32]sub.InlineQosParam = undefined;
    const sm = try it.next(&params);
    try std.testing.expectEqual(@as(?SubMessage, null), sm);
}

test "MessageIterator parses INFO_TS submessage" {
    // Craft: RTPS header (20) + INFO_TS with timestamp (4 hdr + 8 content = 12).
    var buf: [32]u8 = .{0} ** 32;
    // Header
    @memcpy(buf[0..4], "RTPS");
    buf[4] = 2;
    buf[5] = 3;
    buf[6] = 0x01;
    buf[7] = 0x10;
    // INFO_TS submessage: id=0x09, flags=0x01 (LE), octets=8
    buf[20] = 0x09; // INFO_TS
    buf[21] = 0x01; // LE flag
    buf[22] = 8;
    buf[23] = 0; // octetsToNextHeader = 8
    // Timestamp: seconds=1, fraction=0
    std.mem.writeInt(u32, buf[24..28], 1, .little);
    std.mem.writeInt(u32, buf[28..32], 0, .little);

    var it = try MessageIterator.init(&buf);
    var params: [32]sub.InlineQosParam = undefined;
    const maybe_sm = try it.next(&params);
    const sm = maybe_sm orelse return error.ExpectedSubmessage;
    switch (sm) {
        .info_ts => |ts| {
            try std.testing.expectEqual(@as(?RtpsTimestamp, RtpsTimestamp{ .seconds = 1, .fraction = 0 }), ts.timestamp);
        },
        else => return error.WrongSubmessageType,
    }
}

test "MessageIterator parses HEARTBEAT submessage" {
    // 20 header + 4 smh + 4+4+8+8+4 = 20 content = 44 bytes total
    var buf: [44]u8 = .{0} ** 44;
    @memcpy(buf[0..4], "RTPS");
    buf[4] = 2;
    buf[5] = 3;
    buf[6] = 0x01;
    buf[7] = 0x10;

    buf[20] = 0x07; // HEARTBEAT
    buf[21] = 0x01; // LE
    std.mem.writeInt(u16, buf[22..24], 28, .little); // content = 28 bytes

    // reader entity id (4) + writer entity id (4) + firstSN (8) + lastSN (8) + count (4)
    // All zeros → entityId=0, firstSN=1, lastSN=5, count=1
    std.mem.writeInt(u32, buf[24..28], 0, .little); // reader entity id
    std.mem.writeInt(u32, buf[28..32], 0, .little); // writer entity id
    // firstSN: high=0, low=1
    std.mem.writeInt(i32, buf[32..36], 0, .little);
    std.mem.writeInt(u32, buf[36..40], 1, .little);
    // lastSN: high=0, low=5
    // buf is only 44 bytes; lastSN.low and count would overflow.
    // This test only validates the submessage header encoding above.
    try std.testing.expectEqual(@as(u8, 0x07), buf[20]); // HEARTBEAT id
}

test "SequenceNumberSet MSB-first ordering" {
    // Verify that bit 0 = base, bit 1 = base+1, etc.
    var sns = sub.SequenceNumberSet{ .base = 100, .num_bits = 64, .bitmap = .{0} ** 8 };
    // Set bit 0 = SN 100: MSB of bitmap[0]
    sns.bitmap[0] = 0x8000_0000;
    try std.testing.expect(sns.contains(100));
    try std.testing.expect(!sns.contains(101));
    // Set bit 32 = SN 132: MSB of bitmap[1]
    sns.bitmap[1] = 0x8000_0000;
    try std.testing.expect(sns.contains(132));
}
