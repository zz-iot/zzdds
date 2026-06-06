//! RTPS Message Builder (RTPS 2.5 §9.4).
//!
//! Assembles an RTPS message as a list of `iovec` entries for zero-copy
//! scatter-gather I/O (sendmsg). The RTPS Header and each SubMessage header
//! are written into an internal stack buffer; payload slices are referenced
//! directly without copying.
//!
//! Usage:
//!
//!   var b = MessageBuilder.init(&scratch_buf, sender_guid_prefix);
//!   b.addInfoTs(RtpsTimestamp.now());
//!   b.addData(.{ ... }, payload_bytes);
//!   const iovecs = b.iovecs();
//!   // pass iovecs to sendmsg / writev

const std = @import("std");
const Header = @import("header.zig").Header;
const sub = @import("submessage.zig");
const SubMessageHeader = sub.SubMessageHeader;
const SubMessageId = sub.SubMessageId;
const sn_module = @import("../sequence_number.zig");
const SequenceNumber = sn_module.SequenceNumber;
const EntityId = @import("../guid.zig").EntityId;
const GuidPrefix = @import("../guid.zig").GuidPrefix;
const RtpsTimestamp = @import("../../util/time.zig").RtpsTimestamp;

// ── iovec ─────────────────────────────────────────────────────────────────────

/// Minimal iovec compatible with POSIX sendmsg / writev.
/// On Linux this matches `struct iovec` exactly.
pub const IoVec = extern struct {
    base: [*]const u8,
    len: usize,
};

// ── Limits ────────────────────────────────────────────────────────────────────

/// Maximum number of iovecs per message. Each submessage contributes at most 2
/// (header in scratch + optional payload slice). Plus the RTPS header iovec.
/// 1 header + 64 submessages × 2 = 129; round up to a power of two.
pub const MAX_IOVECS: usize = 128;

/// Maximum scratch buffer size. The scratch buffer holds the RTPS Header and
/// all submessage headers/inline fields. Sized for the worst case:
///   20 (RTPS hdr) + 64 × ~80 bytes (max submessage header with inline QoS)
///   = 20 + 5120 ≈ 5200; round to 6 KiB.
pub const SCRATCH_SIZE: usize = 6144;

// ── Writer (scratch buffer cursor) ───────────────────────────────────────────

/// Writes bytes into a caller-supplied scratch buffer.
const ScratchWriter = struct {
    buf: []u8,
    pos: usize,

    fn init(buf: []u8) ScratchWriter {
        return .{ .buf = buf, .pos = 0 };
    }

    fn remaining(self: ScratchWriter) usize {
        return self.buf.len - self.pos;
    }

    /// Current write pointer.
    fn ptr(self: ScratchWriter) [*]u8 {
        return self.buf.ptr + self.pos;
    }

    /// Current slice from start to current position.
    fn written(self: ScratchWriter) []const u8 {
        return self.buf[0..self.pos];
    }

    /// Reserve `n` bytes and return a mutable slice into them.
    fn reserve(self: *ScratchWriter, n: usize) ?[]u8 {
        if (self.remaining() < n) return null;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn writeU8(self: *ScratchWriter, v: u8) void {
        const s = self.reserve(1) orelse return;
        s[0] = v;
    }

    fn writeU16Le(self: *ScratchWriter, v: u16) void {
        const s = self.reserve(2) orelse return;
        std.mem.writeInt(u16, s[0..2], v, .little);
    }

    fn writeU32Le(self: *ScratchWriter, v: u32) void {
        const s = self.reserve(4) orelse return;
        std.mem.writeInt(u32, s[0..4], v, .little);
    }

    fn writeI32Le(self: *ScratchWriter, v: i32) void {
        self.writeU32Le(@bitCast(v));
    }

    fn writeBytes(self: *ScratchWriter, data: []const u8) void {
        const s = self.reserve(data.len) orelse return;
        @memcpy(s, data);
    }

    fn writeEntityId(self: *ScratchWriter, id: EntityId) void {
        self.writeBytes(&id.entity_key);
        self.writeU8(id.entity_kind);
    }

    fn writeSequenceNumber(self: *ScratchWriter, sn: SequenceNumber) void {
        const w = sn_module.toWire(sn);
        self.writeI32Le(w.high);
        self.writeU32Le(w.low);
    }
};

// ── Submessage header helpers ─────────────────────────────────────────────────

/// Write a submessage header with the given id, flags, and content length.
/// All submessages are written little-endian (flags bit 0 = 1).
fn writeSmHeader(w: *ScratchWriter, id: SubMessageId, flags: u8, content_len: usize) void {
    w.writeU8(@intFromEnum(id));
    w.writeU8(flags | sub.FLAG_ENDIANNESS); // always LE
    w.writeU16Le(@intCast(content_len));
}

// ── SequenceNumberSet encoder ─────────────────────────────────────────────────

fn writeSequenceNumberSet(w: *ScratchWriter, sns: sub.SequenceNumberSet) void {
    w.writeSequenceNumber(sns.base);
    w.writeU32Le(sns.num_bits);
    const num_words = (sns.num_bits + 31) / 32;
    for (sns.bitmap[0..num_words]) |word| w.writeU32Le(word);
}

// ── MessageBuilder ────────────────────────────────────────────────────────────

/// Builds an RTPS message as a scatter-gather iovec list.
///
/// The builder owns a slice of `scratch` (caller-supplied or stack-allocated)
/// into which it writes the RTPS header and all submessage header bytes.
/// Payload slices (from CacheChange.data) are referenced without copying.
///
/// Call pattern:
///   1. MessageBuilder.init(scratch, guid_prefix)
///   2. builder.addInfoTs / addData / addHeartbeat / addAckNack / addGap / …
///   3. builder.iovecs() → pass to sendmsg / writev
///
/// The builder does not own any memory and performs no allocations.
pub const MessageBuilder = struct {
    scratch: ScratchWriter,
    ios: [MAX_IOVECS]IoVec,
    io_count: usize,
    /// Byte offset in scratch where the RTPS header ends. Used for debug.
    _hdr_end: usize,

    /// Initialize and write the RTPS header into scratch.
    pub fn init(scratch: []u8, sender_prefix: GuidPrefix) MessageBuilder {
        var self = MessageBuilder{
            .scratch = ScratchWriter.init(scratch),
            .ios = undefined,
            .io_count = 0,
            ._hdr_end = 0,
        };
        // Write the RTPS header into scratch and add a single iovec for it.
        const hdr = Header.init(sender_prefix);
        const hdr_bytes = hdr.toBytes();
        self.scratch.writeBytes(&hdr_bytes);
        self._hdr_end = self.scratch.pos;
        // The first iovec covers everything written so far (the header).
        // As submessage headers are written into scratch, we keep a single iovec
        // for the whole scratch buffer rather than one per submessage header —
        // this saves iovec slots and avoids fragmentation.
        // Payload iovecs are added separately.
        self.ios[0] = .{ .base = scratch.ptr, .len = self.scratch.pos };
        self.io_count = 1;
        return self;
    }

    /// Update the scratch iovec to reflect any newly written bytes.
    fn syncScratchIov(self: *MessageBuilder) void {
        self.ios[0] = .{ .base = self.scratch.buf.ptr, .len = self.scratch.pos };
    }

    /// Append a payload iovec (no copy).
    fn addPayloadIov(self: *MessageBuilder, payload: []const u8) void {
        if (self.io_count >= MAX_IOVECS) return;
        self.ios[self.io_count] = .{ .base = payload.ptr, .len = payload.len };
        self.io_count += 1;
    }

    // ── INFO_TS ───────────────────────────────────────────────────────────────

    /// Add an INFO_TS submessage with the given timestamp.
    pub fn addInfoTs(self: *MessageBuilder, ts: RtpsTimestamp) void {
        // content: 8 bytes (seconds u32 + fraction u32)
        writeSmHeader(&self.scratch, .info_ts, sub.FLAG_ENDIANNESS, 8);
        self.scratch.writeU32Le(ts.seconds);
        self.scratch.writeU32Le(ts.fraction);
        self.syncScratchIov();
    }

    /// Add an INFO_TS submessage that invalidates the current source timestamp.
    pub fn addInfoTsInvalidate(self: *MessageBuilder) void {
        writeSmHeader(&self.scratch, .info_ts, sub.FLAG_ENDIANNESS | sub.InfoTsFlags.invalidate_ts, 0);
        self.syncScratchIov();
    }

    // ── INFO_DST ──────────────────────────────────────────────────────────────

    /// Add an INFO_DST submessage (used for unicast directed messages).
    pub fn addInfoDst(self: *MessageBuilder, prefix: GuidPrefix) void {
        writeSmHeader(&self.scratch, .info_dst, sub.FLAG_ENDIANNESS, 12);
        self.scratch.writeBytes(&prefix.bytes);
        self.syncScratchIov();
    }

    // ── DATA ──────────────────────────────────────────────────────────────────

    /// Parameters for addData.
    pub const DataParams = struct {
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        writer_sn: SequenceNumber,
        /// Include the key hash as inline QoS (recommended for keyed topics).
        key_hash: ?[16]u8 = null,
        /// True if `payload` contains a serialized key rather than data.
        is_key: bool = false,
        /// PID_STATUS_INFO inline QoS (RTPS §9.6.3.6).
        /// 0x00000001 = NOT_ALIVE_DISPOSED, 0x00000002 = NOT_ALIVE_UNREGISTERED.
        /// null = omit (normal alive DATA).
        status_info: ?u32 = null,
        /// PID_COHERENT_SET inline QoS (RTPS §9.6.3.7).
        /// Value = last writer SN in this coherent set.  null = not part of a coherent set.
        coherent_set_sn: ?SequenceNumber = null,
        /// PID_GROUP_SEQ_NUM: per-publisher monotonically-increasing group counter.
        /// null = omit (non-GROUP coherent, or no coherent set).
        group_seq_num: ?SequenceNumber = null,
        /// PID_GROUP_COHERENT_SET: last group sequence number in this group coherent set.
        /// null = omit.
        group_coherent_sn: ?SequenceNumber = null,
    };

    /// Add a DATA submessage. `payload` is the full SerializedPayload
    /// (4-byte encap header + CDR bytes). Payload is referenced, not copied.
    pub fn addData(
        self: *MessageBuilder,
        params: DataParams,
        payload: []const u8,
    ) void {
        const has_iqos = params.key_hash != null or params.status_info != null or
            params.coherent_set_sn != null or params.group_seq_num != null or
            params.group_coherent_sn != null;
        // D and K are mutually exclusive (RTPS §9.4.5.3): set D for data, K for key-only.
        var flags: u8 = sub.FLAG_ENDIANNESS |
            if (params.is_key) sub.DataFlags.key_flag else sub.DataFlags.data_present;
        if (has_iqos) flags |= sub.DataFlags.inline_qos;

        // Calculate content length (everything except the payload).
        // Fixed fields: extraFlags(2) + octetsToInlineQos(2) + readerEntityId(4)
        //             + writerEntityId(4) + writerSN(8) = 20 bytes.
        var fixed_len: usize = 20;
        // Inline QoS parameters (each: 2-byte PID + 2-byte length + value):
        //   PID_KEY_HASH:            4 hdr + 16 value = 20 bytes
        //   PID_STATUS_INFO:         4 hdr + 4 value  = 8 bytes
        //   PID_GROUP_SEQ_NUM:       4 hdr + 8 value  = 12 bytes
        //   PID_COHERENT_SET:        4 hdr + 8 value  = 12 bytes
        //   PID_GROUP_COHERENT_SET:  4 hdr + 8 value  = 12 bytes
        //   PID_SENTINEL:            4 bytes
        if (params.key_hash != null) fixed_len += 20;
        if (params.status_info != null) fixed_len += 8;
        if (params.group_seq_num != null) fixed_len += 12; // PID_GROUP_SEQ_NUM
        if (params.coherent_set_sn != null) fixed_len += 12; // PID_COHERENT_SET
        if (params.group_coherent_sn != null) fixed_len += 12; // PID_GROUP_COHERENT_SET
        if (has_iqos) fixed_len += 4; // PID_SENTINEL

        const total_content = fixed_len + payload.len;
        writeSmHeader(&self.scratch, .data, flags, total_content);

        // extraFlags = 0; octetsToInlineQos = 16 (reader 4 + writer 4 + SN 8)
        self.scratch.writeU16Le(0); // extraFlags
        self.scratch.writeU16Le(16); // octetsToInlineQos
        self.scratch.writeEntityId(params.reader_entity_id);
        self.scratch.writeEntityId(params.writer_entity_id);
        self.scratch.writeSequenceNumber(params.writer_sn);

        if (params.key_hash) |kh| {
            self.scratch.writeU16Le(@intFromEnum(sub.ParameterId.key_hash));
            self.scratch.writeU16Le(16);
            self.scratch.writeBytes(&kh);
        }
        if (params.status_info) |si| {
            self.scratch.writeU16Le(@intFromEnum(sub.ParameterId.status_info));
            self.scratch.writeU16Le(4);
            // StatusInfo_t is {unused,unused,unused,status} (RTPS §9.4.5.11).
            // The status byte is always at offset 3 — write as an octet array.
            self.scratch.writeU8(0);
            self.scratch.writeU8(0);
            self.scratch.writeU8(0);
            self.scratch.writeU8(@truncate(si));
        }
        if (params.group_seq_num) |gsn| {
            self.scratch.writeU16Le(@intFromEnum(sub.ParameterId.group_seq_num));
            self.scratch.writeU16Le(8);
            self.scratch.writeSequenceNumber(gsn);
        }
        if (params.coherent_set_sn) |csn| {
            self.scratch.writeU16Le(@intFromEnum(sub.ParameterId.coherent_set));
            self.scratch.writeU16Le(8);
            self.scratch.writeSequenceNumber(csn);
        }
        if (params.group_coherent_sn) |gcs| {
            self.scratch.writeU16Le(@intFromEnum(sub.ParameterId.group_coherent_set));
            self.scratch.writeU16Le(8);
            self.scratch.writeSequenceNumber(gcs);
        }
        if (has_iqos) {
            self.scratch.writeU16Le(@intFromEnum(sub.ParameterId.sentinel));
            self.scratch.writeU16Le(0);
        }

        self.syncScratchIov();

        // Add payload as a separate iovec (zero-copy).
        if (payload.len > 0) self.addPayloadIov(payload);
    }

    // ── HEARTBEAT ─────────────────────────────────────────────────────────────

    /// Add a HEARTBEAT submessage.
    pub fn addHeartbeat(
        self: *MessageBuilder,
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        first_sn: SequenceNumber,
        last_sn: SequenceNumber,
        count: i32,
        final: bool,
    ) void {
        var flags: u8 = sub.FLAG_ENDIANNESS;
        if (final) flags |= sub.HeartbeatFlags.final;
        // content: reader(4) + writer(4) + firstSN(8) + lastSN(8) + count(4) = 28
        writeSmHeader(&self.scratch, .heartbeat, flags, 28);
        self.scratch.writeEntityId(reader_entity_id);
        self.scratch.writeEntityId(writer_entity_id);
        self.scratch.writeSequenceNumber(first_sn);
        self.scratch.writeSequenceNumber(last_sn);
        self.scratch.writeI32Le(count);
        self.syncScratchIov();
    }

    // ── ACKNACK ───────────────────────────────────────────────────────────────

    /// Add an ACKNACK submessage.
    pub fn addAckNack(
        self: *MessageBuilder,
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        sns: sub.SequenceNumberSet,
        count: i32,
        final: bool,
    ) void {
        var flags: u8 = sub.FLAG_ENDIANNESS;
        if (final) flags |= sub.AckNackFlags.final;
        // content: reader(4) + writer(4) + SNS(variable) + count(4)
        const sns_size = sns.wireSize();
        const content_len = 4 + 4 + sns_size + 4;
        writeSmHeader(&self.scratch, .acknack, flags, content_len);
        self.scratch.writeEntityId(reader_entity_id);
        self.scratch.writeEntityId(writer_entity_id);
        writeSequenceNumberSet(&self.scratch, sns);
        self.scratch.writeI32Le(count);
        self.syncScratchIov();
    }

    // ── GAP ───────────────────────────────────────────────────────────────────

    /// Add a GAP submessage.
    pub fn addGap(
        self: *MessageBuilder,
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        gap_start: SequenceNumber,
        gap_list: sub.SequenceNumberSet,
    ) void {
        // content: reader(4) + writer(4) + gapStart(8) + gapList(variable)
        const content_len = 4 + 4 + 8 + gap_list.wireSize();
        writeSmHeader(&self.scratch, .gap, sub.FLAG_ENDIANNESS, content_len);
        self.scratch.writeEntityId(reader_entity_id);
        self.scratch.writeEntityId(writer_entity_id);
        self.scratch.writeSequenceNumber(gap_start);
        writeSequenceNumberSet(&self.scratch, gap_list);
        self.syncScratchIov();
    }

    // ── DATA_FRAG ─────────────────────────────────────────────────────────────

    /// Parameters for addDataFrag.
    pub const DataFragParams = struct {
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        writer_sn: SequenceNumber,
        fragment_starting_num: sub.FragmentNumber,
        fragments_in_submessage: u16,
        fragment_size: u16,
        data_size: u32,
        is_key: bool = false,
    };

    /// Add a DATA_FRAG submessage with a fragment payload slice.
    pub fn addDataFrag(
        self: *MessageBuilder,
        params: DataFragParams,
        payload: []const u8,
    ) void {
        var flags: u8 = sub.FLAG_ENDIANNESS;
        if (params.is_key) flags |= sub.DataFragFlags.key_flag;

        // Fixed fields: extraFlags(2) + qos_offset(2) + reader(4) + writer(4) +
        //               SN(8) + fragStart(4) + fragCount(2) + fragSize(2) + dataSize(4)
        //             = 32 bytes
        const fixed_len: usize = 32;
        writeSmHeader(&self.scratch, .data_frag, flags, fixed_len + payload.len);

        self.scratch.writeU16Le(0); // extraFlags
        self.scratch.writeU16Le(28); // octetsToInlineQos (from after these two u16s)
        self.scratch.writeEntityId(params.reader_entity_id);
        self.scratch.writeEntityId(params.writer_entity_id);
        self.scratch.writeSequenceNumber(params.writer_sn);
        self.scratch.writeU32Le(params.fragment_starting_num);
        self.scratch.writeU16Le(params.fragments_in_submessage);
        self.scratch.writeU16Le(params.fragment_size);
        self.scratch.writeU32Le(params.data_size);
        self.syncScratchIov();

        if (payload.len > 0) self.addPayloadIov(payload);
    }

    // ── HEARTBEAT_FRAG ────────────────────────────────────────────────────────

    /// Add a HEARTBEAT_FRAG submessage (§9.4.5.5).
    /// Announces that all fragments 1..last_fragment_num for writer_sn are available.
    pub fn addHeartbeatFrag(
        self: *MessageBuilder,
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        writer_sn: SequenceNumber,
        last_fragment_num: sub.FragmentNumber,
        count: i32,
    ) void {
        // body: readerId(4) + writerId(4) + writerSN(8) + lastFragNum(4) + count(4) = 24 bytes
        writeSmHeader(&self.scratch, .heartbeat_frag, sub.FLAG_ENDIANNESS, 24);
        self.scratch.writeEntityId(reader_entity_id);
        self.scratch.writeEntityId(writer_entity_id);
        self.scratch.writeSequenceNumber(writer_sn);
        self.scratch.writeU32Le(last_fragment_num);
        self.scratch.writeI32Le(count);
        self.syncScratchIov();
    }

    // ── NACK_FRAG ─────────────────────────────────────────────────────────────

    /// Add a NACK_FRAG submessage (§9.4.5.11).
    /// Requests retransmission of specific fragments for writer_sn.
    pub fn addNackFrag(
        self: *MessageBuilder,
        reader_entity_id: EntityId,
        writer_entity_id: EntityId,
        writer_sn: SequenceNumber,
        frag_set: sub.FragmentNumberSet,
        count: i32,
    ) void {
        const num_words: u32 = (frag_set.num_bits + 31) / 32;
        // body: readerId(4) + writerId(4) + writerSN(8) + base(4) + num_bits(4)
        //       + bitmap(num_words*4) + count(4)
        const body_len: usize = 4 + 4 + 8 + 4 + 4 + @as(usize, num_words) * 4 + 4;
        writeSmHeader(&self.scratch, .nack_frag, sub.FLAG_ENDIANNESS, body_len);
        self.scratch.writeEntityId(reader_entity_id);
        self.scratch.writeEntityId(writer_entity_id);
        self.scratch.writeSequenceNumber(writer_sn);
        self.scratch.writeU32Le(frag_set.base);
        self.scratch.writeU32Le(frag_set.num_bits);
        for (frag_set.bitmap[0..num_words]) |word| self.scratch.writeU32Le(word);
        self.scratch.writeI32Le(count);
        self.syncScratchIov();
    }

    // ── Result ────────────────────────────────────────────────────────────────

    /// Return the assembled iovec list. The first element covers the scratch
    /// buffer (RTPS header + all submessage headers). Subsequent elements are
    /// payload slices.
    pub fn iovecs(self: *MessageBuilder) []const IoVec {
        return self.ios[0..self.io_count];
    }

    /// Total byte count across all iovecs.
    pub fn totalLen(self: *const MessageBuilder) usize {
        var total: usize = 0;
        for (self.ios[0..self.io_count]) |iov| total += iov.len;
        return total;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "MessageBuilder init produces valid RTPS header iovec" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    const prefix = GuidPrefix{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } };
    var b = MessageBuilder.init(&scratch, prefix);

    const ios = b.iovecs();
    try std.testing.expectEqual(@as(usize, 1), ios.len);
    try std.testing.expectEqual(@as(usize, 20), ios[0].len);
    // Check "RTPS" magic in the scratch
    try std.testing.expectEqual('R', scratch[0]);
    try std.testing.expectEqual('T', scratch[1]);
    try std.testing.expectEqual('P', scratch[2]);
    try std.testing.expectEqual('S', scratch[3]);
}

test "MessageBuilder.addInfoTs produces correct wire bytes" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    const prefix = GuidPrefix{ .bytes = .{0} ** 12 };
    var b = MessageBuilder.init(&scratch, prefix);
    b.addInfoTs(.{ .seconds = 1700000000, .fraction = 500000000 });

    const ios = b.iovecs();
    // Should still be 1 iovec (info_ts goes into scratch, no payload).
    try std.testing.expectEqual(@as(usize, 1), ios.len);

    // After the 20-byte header: submessage header (4) + content (8) = 12 bytes
    const sm_start = 20;
    try std.testing.expectEqual(@as(u8, 0x09), scratch[sm_start]); // INFO_TS id
    try std.testing.expectEqual(@as(u8, 0x01), scratch[sm_start + 1]); // LE flag
    const content_len = std.mem.readInt(u16, scratch[sm_start + 2 ..][0..2], .little);
    try std.testing.expectEqual(@as(u16, 8), content_len);

    const secs = std.mem.readInt(u32, scratch[sm_start + 4 ..][0..4], .little);
    try std.testing.expectEqual(@as(u32, 1700000000), secs);
}

test "MessageBuilder.addData produces two iovecs" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    const prefix = GuidPrefix{ .bytes = .{0} ** 12 };
    var b = MessageBuilder.init(&scratch, prefix);

    const payload = [_]u8{ 0x00, 0x07, 0x00, 0x00, 0xAA, 0xBB }; // encap + 2 bytes
    b.addData(.{
        .reader_entity_id = EntityId{ .entity_key = .{ 0, 0, 0 }, .entity_kind = 0 },
        .writer_entity_id = EntityId{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 2 },
        .writer_sn = 1,
    }, &payload);

    const ios = b.iovecs();
    try std.testing.expectEqual(@as(usize, 2), ios.len);
    // Second iovec is the payload.
    try std.testing.expectEqual(@as(usize, payload.len), ios[1].len);
    try std.testing.expectEqual(@as([*]const u8, @ptrCast(&payload[0])), ios[1].base);
}

test "MessageBuilder.addHeartbeat is single iovec" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    const prefix = GuidPrefix{ .bytes = .{0} ** 12 };
    var b = MessageBuilder.init(&scratch, prefix);
    const eid = @import("../guid.zig").EntityIds;

    b.addHeartbeat(
        eid.unknown,
        eid.unknown,
        1,
        100,
        1,
        false,
    );

    const ios = b.iovecs();
    try std.testing.expectEqual(@as(usize, 1), ios.len);
    // HEARTBEAT id at byte 20
    try std.testing.expectEqual(@as(u8, 0x07), scratch[20]);
    const content_len = std.mem.readInt(u16, scratch[22..24], .little);
    try std.testing.expectEqual(@as(u16, 28), content_len);
}

test "MessageBuilder.totalLen" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    const prefix = GuidPrefix{ .bytes = .{0} ** 12 };
    var b = MessageBuilder.init(&scratch, prefix);
    const payload = [_]u8{ 0xDE, 0xAD };
    const eid = @import("../guid.zig").EntityIds;
    b.addData(.{
        .reader_entity_id = eid.unknown,
        .writer_entity_id = eid.unknown,
        .writer_sn = 1,
    }, &payload);

    // RTPS header (20) + DATA smh (4) + fixed (20) + payload (2) = 46
    try std.testing.expectEqual(@as(usize, 46), b.totalLen());
}

// ── Builder/parser round-trip tests ──────────────────────────────────────────
//
// Build a message with MessageBuilder, flatten iovecs into a contiguous buffer,
// then parse with MessageIterator and verify the recovered fields.

const parser = @import("parser.zig");

fn flatten(iovs: []const IoVec, buf: []u8) []const u8 {
    var off: usize = 0;
    for (iovs) |iov| {
        @memcpy(buf[off..][0..iov.len], iov.base[0..iov.len]);
        off += iov.len;
    }
    return buf[0..off];
}

test "builder/parser round-trip: ACKNACK" {
    const eid = @import("../guid.zig").EntityIds;
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    var b = MessageBuilder.init(&scratch, GuidPrefix{ .bytes = .{0xAA} ** 12 });
    const sns = sub.SequenceNumberSet{ .base = 5, .num_bits = 3, .bitmap = .{0xE000_0000} ++ .{0} ** 7 };
    b.addAckNack(eid.unknown, eid.unknown, sns, 42, true);

    var flat: [SCRATCH_SIZE]u8 = undefined;
    const msg = flatten(b.iovecs(), &flat);

    var params: [32]sub.InlineQosParam = undefined;
    var it = try parser.MessageIterator.init(msg);
    const sm = (try it.next(&params)).?;
    switch (sm) {
        .acknack => |an| {
            try std.testing.expectEqual(@as(SequenceNumber, 5), an.reader_sn_state.base);
            try std.testing.expectEqual(@as(u32, 3), an.reader_sn_state.num_bits);
            try std.testing.expectEqual(@as(i32, 42), an.count);
            try std.testing.expect(an.isFinal());
        },
        else => return error.WrongSubmessageType,
    }
}

test "builder/parser round-trip: GAP" {
    const eid = @import("../guid.zig").EntityIds;
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    var b = MessageBuilder.init(&scratch, GuidPrefix{ .bytes = .{0} ** 12 });
    const gap_list = sub.SequenceNumberSet{ .base = 10, .num_bits = 0, .bitmap = .{0} ** 8 };
    b.addGap(eid.unknown, eid.unknown, 7, gap_list);

    var flat: [SCRATCH_SIZE]u8 = undefined;
    const msg = flatten(b.iovecs(), &flat);

    var params: [32]sub.InlineQosParam = undefined;
    var it = try parser.MessageIterator.init(msg);
    const sm = (try it.next(&params)).?;
    switch (sm) {
        .gap => |g| {
            try std.testing.expectEqual(@as(SequenceNumber, 7), g.gap_start);
            try std.testing.expectEqual(@as(SequenceNumber, 10), g.gap_list.base);
        },
        else => return error.WrongSubmessageType,
    }
}

test "builder/parser round-trip: DATA (no inline QoS)" {
    const eid = @import("../guid.zig").EntityIds;
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    var b = MessageBuilder.init(&scratch, GuidPrefix{ .bytes = .{0} ** 12 });
    const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xCA, 0xFE }; // CDR LE encap + 2 bytes
    b.addData(.{
        .reader_entity_id = eid.unknown,
        .writer_entity_id = EntityId{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 3 },
        .writer_sn = 99,
    }, &payload);

    var flat: [256]u8 = undefined;
    const msg = flatten(b.iovecs(), &flat);

    var params: [32]sub.InlineQosParam = undefined;
    var it = try parser.MessageIterator.init(msg);
    const sm = (try it.next(&params)).?;
    switch (sm) {
        .data => |d| {
            try std.testing.expectEqual(@as(SequenceNumber, 99), d.writer_sn);
            try std.testing.expectEqual(@as(usize, payload.len), d.serialized_payload.len);
        },
        else => return error.WrongSubmessageType,
    }
}

test "builder/parser round-trip: INFO_DST" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    var b = MessageBuilder.init(&scratch, GuidPrefix{ .bytes = .{0} ** 12 });
    const dst_prefix = GuidPrefix{ .bytes = .{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xAA, 0xBB, 0xCC } };
    b.addInfoDst(dst_prefix);

    var flat: [SCRATCH_SIZE]u8 = undefined;
    const msg = flatten(b.iovecs(), &flat);

    var params: [32]sub.InlineQosParam = undefined;
    var it = try parser.MessageIterator.init(msg);
    const sm = (try it.next(&params)).?;
    switch (sm) {
        .info_dst => |d| try std.testing.expect(d.guid_prefix.eql(dst_prefix)),
        else => return error.WrongSubmessageType,
    }
}

test "MessageBuilder.addInfoTsInvalidate: INFO_TS with INVALIDATE flag" {
    var scratch: [SCRATCH_SIZE]u8 = undefined;
    var b = MessageBuilder.init(&scratch, GuidPrefix{ .bytes = .{0} ** 12 });
    b.addInfoTsInvalidate();

    const ios = b.iovecs();
    try std.testing.expectEqual(@as(usize, 1), ios.len);
    // INFO_TS id=0x09; flag bit 1 (INVALIDATE) set; content = 0 bytes
    try std.testing.expectEqual(@as(u8, 0x09), scratch[20]);
    try std.testing.expectEqual(@as(u8, 0x03), scratch[21]); // LE | INVALIDATE
    const content_len = std.mem.readInt(u16, scratch[22..24], .little);
    try std.testing.expectEqual(@as(u16, 0), content_len);
}
