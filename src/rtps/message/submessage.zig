//! RTPS Submessage types (RTPS 2.5 §8.3.3, §9.4.2–9.4.6).
//!
//! Wire layout: each submessage starts with a 4-byte SubMessageHeader, followed
//! by submessage-kind-specific content.
//!
//! SubMessageHeader (4 bytes):
//!   submessageId   u8
//!   flags          u8   — bit 0 = endianness (0=BE, 1=LE), other bits vary
//!   octetsToNextHeader u16  — length of remaining content in bytes
//!
//! Endianness is per-submessage. Multi-byte fields within a submessage are in
//! the byte order indicated by that submessage's endianness flag.

const std = @import("std");
const SequenceNumber = @import("../sequence_number.zig").SequenceNumber;
const SequenceNumberWire = @import("../sequence_number.zig").SequenceNumberWire;
const Guid = @import("../guid.zig").Guid;
const EntityId = @import("../guid.zig").EntityId;
const GuidPrefix = @import("../guid.zig").GuidPrefix;
const Locator = @import("../../transport/interface.zig").Locator;
const RtpsTimestamp = @import("../../util/time.zig").RtpsTimestamp;

// ── Submessage IDs (RTPS §9.4.5.1.1) ─────────────────────────────────────────

pub const SubMessageId = enum(u8) {
    pad = 0x01,
    acknack = 0x06,
    heartbeat = 0x07,
    gap = 0x08,
    info_ts = 0x09,
    info_src = 0x0c,
    info_reply_ip4 = 0x0d,
    info_dst = 0x0e,
    info_reply = 0x0f,
    nack_frag = 0x12,
    heartbeat_frag = 0x13,
    data = 0x15,
    data_frag = 0x16,
    // DDS Security v1.2 §7.3.7
    sec_body = 0x30,
    sec_prefix = 0x31,
    sec_postfix = 0x32,
    sec_hb_prefix = 0x33,
    sec_hb_postfix = 0x34,
    _, // unknown IDs are parsed as raw bytes
};

// ── Flags ─────────────────────────────────────────────────────────────────────

/// Bit 0 of any submessage's flags byte.
pub const FLAG_ENDIANNESS: u8 = 0x01; // 1 = little-endian

/// DATA submessage flag bits (§9.4.5.3).
pub const DataFlags = struct {
    pub const endianness: u8 = 0x01;
    pub const inline_qos: u8 = 0x02;
    pub const data_present: u8 = 0x04;
    pub const key_flag: u8 = 0x08;
};

/// DATA_FRAG submessage flag bits (§9.4.5.4).
pub const DataFragFlags = struct {
    pub const endianness: u8 = 0x01;
    pub const inline_qos: u8 = 0x02;
    pub const key_flag: u8 = 0x04;
};

/// HEARTBEAT submessage flag bits (§9.4.5.7).
pub const HeartbeatFlags = struct {
    pub const endianness: u8 = 0x01;
    pub const final: u8 = 0x02; // no response required if set
    pub const liveliness: u8 = 0x04;
};

/// ACKNACK submessage flag bits (§9.4.5.1).
pub const AckNackFlags = struct {
    pub const endianness: u8 = 0x01;
    pub const final: u8 = 0x02; // no further NACKs expected
};

/// GAP submessage flag bits (§9.4.5.6).
pub const GapFlags = struct {
    pub const endianness: u8 = 0x01;
};

/// INFO_TS submessage flag bits (§9.4.5.9).
pub const InfoTsFlags = struct {
    pub const endianness: u8 = 0x01;
    /// Timestamp not present when set.
    pub const invalidate_ts: u8 = 0x02;
};

// ── SubMessage Header ─────────────────────────────────────────────────────────

/// 4-byte header that precedes every submessage (§9.4.2).
pub const SubMessageHeader = extern struct {
    submessage_id: u8,
    flags: u8,
    /// Length of content following this header, in bytes.
    /// Special case: 0 means "extends to end of RTPS message".
    octets_to_next_header: u16,

    comptime {
        std.debug.assert(@sizeOf(SubMessageHeader) == 4);
    }

    pub fn id(self: SubMessageHeader) SubMessageId {
        return @enumFromInt(self.submessage_id);
    }

    pub fn isLittleEndian(self: SubMessageHeader) bool {
        return (self.flags & FLAG_ENDIANNESS) != 0;
    }

    /// octets_to_next_header in host byte order.
    pub fn contentLen(self: SubMessageHeader) u16 {
        // The field itself is always LE according to RTPS §9.4.2 Table 9.6.
        return std.mem.littleToNative(u16, self.octets_to_next_header);
    }
};

// ── SequenceNumberSet ────────────────────────────────────────────────────────

/// RTPS SequenceNumberSet (§9.4.2.6) — used in ACKNACK and GAP.
/// Represents a base sequence number and a bitmask of up to 256 sequence numbers.
pub const SequenceNumberSet = struct {
    /// First sequence number referenced by this set.
    base: SequenceNumber,
    /// Number of bits in the bitmap (0–256).
    num_bits: u32,
    /// Bitmap: bit i corresponds to base+i (MSB of bitmap[0] = bit 0 = base+0).
    /// Up to 8 u32 words = 256 bits.
    bitmap: [8]u32,

    /// True if sequence number `sn` is in the set.
    pub fn contains(self: SequenceNumberSet, sn: SequenceNumber) bool {
        if (sn < self.base) return false;
        const offset: u64 = @intCast(sn - self.base);
        if (offset >= self.num_bits) return false;
        const word: u32 = @intCast(offset / 32);
        const bit: u5 = @intCast(31 - (offset % 32)); // MSB first
        return (self.bitmap[word] >> bit) & 1 == 1;
    }

    /// Set the bit for sequence number `sn`. No-op if out of range.
    pub fn set(self: *SequenceNumberSet, sn: SequenceNumber) void {
        if (sn < self.base) return;
        const offset: u64 = @intCast(sn - self.base);
        if (offset >= self.num_bits) return;
        const word: u32 = @intCast(offset / 32);
        const bit: u5 = @intCast(31 - (offset % 32));
        self.bitmap[word] |= @as(u32, 1) << bit;
    }

    /// Wire size in bytes: 8 (base SN wire) + 4 (numBits) + ceil(numBits/32)*4.
    pub fn wireSize(self: SequenceNumberSet) usize {
        const num_words = (self.num_bits + 31) / 32;
        return 8 + 4 + num_words * 4;
    }
};

// ── FragmentNumber / FragmentNumberSet ────────────────────────────────────────

pub const FragmentNumber = u32; // RTPS §9.3.2

pub const FragmentNumberSet = struct {
    base: FragmentNumber,
    num_bits: u32,
    bitmap: [8]u32,

    pub fn contains(self: FragmentNumberSet, fn_: FragmentNumber) bool {
        if (fn_ < self.base) return false;
        const offset = fn_ - self.base;
        if (offset >= self.num_bits) return false;
        const word = offset / 32;
        const bit: u5 = @intCast(31 - (offset % 32));
        return (self.bitmap[word] >> bit) & 1 == 1;
    }
};

// ── Inline QoS parameters ─────────────────────────────────────────────────────

/// PID values for inline QoS parameters (RTPS §9.6.2).
pub const ParameterId = enum(u16) {
    sentinel = 0x0001,
    topic_name = 0x0005,
    type_name = 0x0007,
    durability = 0x001d,
    deadline = 0x0023,
    latency_budget = 0x0027,
    liveliness = 0x001b,
    reliability = 0x001a,
    lifespan = 0x002b,
    destination_order = 0x0025,
    history = 0x0040,
    resource_limits = 0x0041,
    ownership = 0x001f,
    ownership_strength = 0x0006,
    presentation = 0x0021,
    partition = 0x0029,
    time_based_filter = 0x0004,
    transport_priority = 0x0049,
    content_filter_info = 0x0055,
    coherent_set = 0x0056,
    directed_write = 0x0057,
    original_writer_info = 0x0061,
    group_coherent_set = 0x0063,
    group_seq_num = 0x0064,
    writer_group_info = 0x0065,
    secure_writer_group_info = 0x0066,
    key_hash = 0x0070,
    status_info = 0x0071,
    type_max_size_serialized = 0x0060,
    entity_name = 0x0062,
    // Vendor-specific IDs use the 0x8000+ range and remain unmodeled unless
    // a future extension explicitly claims them.
    _,
};

/// A single inline QoS parameter (PID + value bytes).
/// The value slice borrows from the surrounding parse buffer.
pub const InlineQosParam = struct {
    pid: ParameterId,
    value: []const u8,
};

/// Parsed collection of inline QoS parameters.
/// Backed by a caller-supplied buffer to avoid allocation.
pub const InlineQos = struct {
    params: []InlineQosParam,

    /// Look up a parameter by PID. Returns the first match or null.
    pub fn get(self: InlineQos, pid: ParameterId) ?[]const u8 {
        for (self.params) |p| {
            if (p.pid == pid) return p.value;
        }
        return null;
    }
};

// ── Parsed submessage payloads ────────────────────────────────────────────────

/// Parsed DATA submessage (§9.4.5.3).
pub const DataSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    writer_sn: SequenceNumber,
    /// Present when flags & DataFlags.inline_qos != 0.
    inline_qos: ?InlineQos,
    /// Serialized payload bytes (encap header + CDR data).
    /// Present when flags & DataFlags.data_present != 0.
    /// Borrowed from the parse buffer.
    serialized_payload: []const u8,

    pub fn isLittleEndian(self: DataSubmessage) bool {
        return (self.flags & DataFlags.endianness) != 0;
    }

    pub fn hasInlineQos(self: DataSubmessage) bool {
        return (self.flags & DataFlags.inline_qos) != 0;
    }

    pub fn hasData(self: DataSubmessage) bool {
        return (self.flags & DataFlags.data_present) != 0;
    }

    pub fn isKey(self: DataSubmessage) bool {
        return (self.flags & DataFlags.key_flag) != 0;
    }
};

/// Parsed DATA_FRAG submessage (§9.4.5.4).
pub const DataFragSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    writer_sn: SequenceNumber,
    fragment_starting_num: FragmentNumber,
    fragments_in_submessage: u16,
    fragment_size: u16,
    data_size: u32, // total unfragmented sample size
    inline_qos: ?InlineQos,
    /// Fragment data bytes (borrowing from parse buffer).
    serialized_payload: []const u8,
};

/// Parsed HEARTBEAT submessage (§9.4.5.7).
pub const HeartbeatSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    first_sn: SequenceNumber,
    last_sn: SequenceNumber,
    count: i32,

    pub fn isFinal(self: HeartbeatSubmessage) bool {
        return (self.flags & HeartbeatFlags.final) != 0;
    }

    pub fn isLiveliness(self: HeartbeatSubmessage) bool {
        return (self.flags & HeartbeatFlags.liveliness) != 0;
    }
};

/// Parsed ACKNACK submessage (§9.4.5.1).
pub const AckNackSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    reader_sn_state: SequenceNumberSet,
    count: i32,

    pub fn isFinal(self: AckNackSubmessage) bool {
        return (self.flags & AckNackFlags.final) != 0;
    }
};

/// Parsed GAP submessage (§9.4.5.6).
pub const GapSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    gap_start: SequenceNumber,
    gap_list: SequenceNumberSet,
};

/// Parsed INFO_TS submessage (§9.4.5.9).
pub const InfoTsSubmessage = struct {
    flags: u8,
    /// Present when invalidate_ts flag is NOT set.
    timestamp: ?RtpsTimestamp,

    pub fn invalidates(self: InfoTsSubmessage) bool {
        return (self.flags & InfoTsFlags.invalidate_ts) != 0;
    }
};

/// Parsed INFO_DST submessage (§9.4.5.8).
pub const InfoDstSubmessage = struct {
    guid_prefix: GuidPrefix,
};

/// Parsed INFO_SRC submessage (§9.4.5.10).
pub const InfoSrcSubmessage = struct {
    protocol_version: [2]u8,
    vendor_id: [2]u8,
    guid_prefix: GuidPrefix,
};

/// Parsed HEARTBEAT_FRAG submessage (§9.4.5.5).
pub const HeartbeatFragSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    writer_sn: SequenceNumber,
    last_fragment_num: FragmentNumber,
    count: i32,
};

/// Parsed NACK_FRAG submessage (§9.4.5.11).
pub const NackFragSubmessage = struct {
    flags: u8,
    reader_entity_id: EntityId,
    writer_entity_id: EntityId,
    writer_sn: SequenceNumber,
    fragment_number_state: FragmentNumberSet,
    count: i32,
};

/// Tag for SubMessage — mirrors SubMessageId but is exhaustive so it can be
/// used as a tagged union discriminant. Unknown/future submessage IDs map to
/// `.unknown`.
pub const SubMessageKind = enum {
    pad,
    acknack,
    heartbeat,
    gap,
    info_ts,
    info_src,
    info_reply_ip4,
    info_dst,
    info_reply,
    nack_frag,
    heartbeat_frag,
    data,
    data_frag,
    sec_body,
    sec_prefix,
    sec_postfix,
    sec_hb_prefix,
    sec_hb_postfix,
    /// Any submessage ID not listed above; raw content bytes.
    unknown,
};

/// A single parsed submessage.
pub const SubMessage = union(SubMessageKind) {
    pad: void,
    acknack: AckNackSubmessage,
    heartbeat: HeartbeatSubmessage,
    gap: GapSubmessage,
    info_ts: InfoTsSubmessage,
    info_src: InfoSrcSubmessage,
    info_reply_ip4: void, // rare; not parsed
    info_dst: InfoDstSubmessage,
    info_reply: void, // rare; not parsed
    nack_frag: NackFragSubmessage,
    heartbeat_frag: HeartbeatFragSubmessage,
    data: DataSubmessage,
    data_frag: DataFragSubmessage,
    sec_body: []const u8,
    sec_prefix: []const u8,
    sec_postfix: []const u8,
    sec_hb_prefix: []const u8,
    sec_hb_postfix: []const u8,
    /// Raw content bytes for unrecognized submessage IDs.
    unknown: []const u8,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "SubMessageHeader size is 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(SubMessageHeader));
}

test "SubMessageHeader.isLittleEndian" {
    const le = SubMessageHeader{ .submessage_id = 0x15, .flags = 0x01, .octets_to_next_header = 0 };
    const be = SubMessageHeader{ .submessage_id = 0x15, .flags = 0x00, .octets_to_next_header = 0 };
    try std.testing.expect(le.isLittleEndian());
    try std.testing.expect(!be.isLittleEndian());
}

test "SubMessageHeader.id maps to SubMessageId" {
    const h = SubMessageHeader{ .submessage_id = 0x15, .flags = 0x05, .octets_to_next_header = 0 };
    try std.testing.expectEqual(SubMessageId.data, h.id());
}

test "SequenceNumberSet.contains and set" {
    var sns = SequenceNumberSet{
        .base = 10,
        .num_bits = 32,
        .bitmap = .{0} ** 8,
    };
    sns.set(10); // bit 0
    sns.set(13); // bit 3
    try std.testing.expect(sns.contains(10));
    try std.testing.expect(!sns.contains(11));
    try std.testing.expect(sns.contains(13));
    try std.testing.expect(!sns.contains(9)); // before base
    try std.testing.expect(!sns.contains(42)); // out of range
}

test "SequenceNumberSet.wireSize" {
    const sns = SequenceNumberSet{ .base = 1, .num_bits = 32, .bitmap = .{0} ** 8 };
    // 8 (SN wire) + 4 (numBits) + 1*4 (one 32-bit word) = 16
    try std.testing.expectEqual(@as(usize, 16), sns.wireSize());
}
