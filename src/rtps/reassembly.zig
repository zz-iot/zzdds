//! Fragment reassembly for one sample: its DATA_FRAG submessages are collected
//! here until every fragment has arrived.

const std = @import("std");
const msg = @import("message/root.zig");
const sn_mod = @import("sequence_number.zig");
const time_mod = @import("../util/time.zig");

const SequenceNumber = sn_mod.SequenceNumber;

/// The PID_KEY_HASH of a DATA or DATA_FRAG's inline QoS, or all zeroes when
/// it carries none.
pub fn keyHashFromInlineQos(inline_qos: ?msg.submessage.InlineQos) [16]u8 {
    if (inline_qos) |iq| {
        if (iq.get(.key_hash)) |bytes| {
            if (bytes.len == 16) return bytes[0..16].*;
        }
    }
    return std.mem.zeroes([16]u8);
}

// ── ReassemblyEntry ───────────────────────────────────────────────────────────

/// In-progress fragment reassembly for one (writer, sequence_number) pair.
/// Allocated when the first DATA_FRAG fragment arrives; freed on completion or
/// when the WriterProxy is removed.
pub const ReassemblyEntry = struct {
    data: []u8,
    data_size: u32,
    fragment_size: u16,
    total_frags: u32,
    received: std.DynamicBitSet,
    /// Source timestamp from the INFO_TS submessage preceding the first DATA_FRAG
    /// fragment. Carried forward to the assembled CacheChange for BY_SOURCE_TIMESTAMP
    /// destination-order QoS and history-cache ordering.
    source_timestamp: time_mod.RtpsTimestamp,
    /// MD5 key hash from PID_KEY_HASH inline QoS, if present in the first fragment.
    key_hash: [16]u8,
    /// Coherent-set inline QoS, which only fragment 1 carries (RTPS 2.5 §8.7.6).
    /// Fragments can arrive in any order, so these are captured whenever
    /// fragment 1 does.
    coherent_set_sn: ?SequenceNumber = null,
    group_seq_num: ?SequenceNumber = null,
    group_coherent_sn: ?SequenceNumber = null,

    /// An empty reassembly for the sample `df` is a fragment of, or null when
    /// `df` declares no fragments.
    pub fn init(alloc: std.mem.Allocator, df: msg.submessage.DataFragSubmessage, source_timestamp: time_mod.RtpsTimestamp) !?ReassemblyEntry {
        if (df.fragment_size == 0 or df.data_size == 0) return null;
        const total_frags: u32 = (df.data_size + df.fragment_size - 1) / df.fragment_size;
        const data = try alloc.alloc(u8, df.data_size);
        errdefer alloc.free(data);
        return .{
            .data = data,
            .data_size = df.data_size,
            .fragment_size = df.fragment_size,
            .total_frags = total_frags,
            .received = try std.DynamicBitSet.initEmpty(alloc, total_frags),
            .source_timestamp = source_timestamp,
            .key_hash = keyHashFromInlineQos(df.inline_qos),
        };
    }

    pub fn clone(self: *const ReassemblyEntry, alloc: std.mem.Allocator) !ReassemblyEntry {
        var copy = self.*;
        copy.data = try alloc.dupe(u8, self.data);
        errdefer alloc.free(copy.data);
        copy.received = try self.received.clone(alloc);
        return copy;
    }

    pub fn deinit(self: *ReassemblyEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.received.deinit();
    }

    pub fn isComplete(self: *const ReassemblyEntry) bool {
        return self.received.count() == self.total_frags;
    }

    /// Record fragment 1's coherent-set inline QoS, if `df` carries fragment 1.
    pub fn captureInlineQos(self: *ReassemblyEntry, df: msg.submessage.DataFragSubmessage) void {
        if (df.fragment_starting_num != 1) return;
        const iq = df.inline_qos orelse return;
        const le = df.isLittleEndian();
        // Non-positive PID_COHERENT_SET values (SEQUENCENUMBER_UNKNOWN) mark
        // the end of a set, not membership: same rule as a DATA's.
        if (iq.getSequenceNumber(.coherent_set, le)) |cs| {
            if (cs >= 1) self.coherent_set_sn = cs;
        }
        self.group_seq_num = iq.getSequenceNumber(.group_seq_num, le);
        if (iq.getSequenceNumber(.group_coherent_set, le)) |gcs| {
            if (gcs >= 1) self.group_coherent_sn = gcs;
        }
    }

    /// Copy fragment bytes into the buffer and mark received.
    /// Handles fragments_in_submessage > 1 (multiple fragments per DATA_FRAG).
    pub fn receiveFrag(
        self: *ReassemblyEntry,
        fragment_starting_num: u32,
        fragments_in_submessage: u16,
        payload: []const u8,
    ) void {
        var i: u32 = 0;
        while (i < fragments_in_submessage) : (i += 1) {
            const frag_idx = fragment_starting_num - 1 + i; // 0-based
            if (frag_idx >= self.total_frags) break;
            if (self.received.isSet(frag_idx)) continue;

            const data_offset: usize = @as(usize, frag_idx) * @as(usize, self.fragment_size);
            const src_offset: usize = @as(usize, i) * @as(usize, self.fragment_size);
            const frag_len = @min(
                @as(usize, self.fragment_size),
                @as(usize, self.data_size) - data_offset,
            );
            if (src_offset + frag_len <= payload.len) {
                @memcpy(self.data[data_offset..][0..frag_len], payload[src_offset..][0..frag_len]);
            }
            self.received.set(frag_idx);
        }
    }
};
