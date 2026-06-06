//! RTPS History Cache (RTPS 2.5 §8.4.1).
//!
//! Stores CacheChange records for writer and reader state machines.
//!
//!   Writer side: call `addWriterChange` — the cache assigns the next SN.
//!   Reader side: call `addReaderChange` — uses the remote writer's SN.
//!
//!   KEEP_LAST (depth N): retains at most N changes; oldest is freed when full.
//!   KEEP_ALL: retains all changes until explicitly removed.
//!
//! Not thread-safe — callers must hold a lock.

const std = @import("std");
const guid_mod = @import("guid.zig");
const sn_mod = @import("sequence_number.zig");
const time_mod = @import("../util/time.zig");

pub const Guid = guid_mod.Guid;
pub const SequenceNumber = sn_mod.SequenceNumber;
pub const RtpsTimestamp = time_mod.RtpsTimestamp;

// ── CacheChange ───────────────────────────────────────────────────────────────

/// Opaque 16-byte instance handle.
/// For keyed types: MD5 of serialized key fields (§9.6.3.3).
/// For keyless types: all zeros.
pub const InstanceHandle = [16]u8;
pub const INSTANCE_HANDLE_NIL: InstanceHandle = std.mem.zeroes([16]u8);

pub const ChangeKind = enum(u8) {
    alive = 0,
    not_alive_disposed = 1,
    not_alive_unregistered = 2,
};

/// One change stored in the history cache.
///
/// `data` contains the full serialized payload: 4-byte CDR encapsulation header
/// followed by CDR-encoded data bytes. The slice is owned by the HistoryCache
/// that produced it; do not free externally.
pub const CacheChange = struct {
    kind: ChangeKind,
    writer_guid: Guid,
    sequence_number: SequenceNumber,
    source_timestamp: RtpsTimestamp,
    instance_handle: InstanceHandle,
    /// MD5 of serialized key fields. All zeros for keyless types.
    key_hash: [16]u8,
    /// Serialized payload (encap header + CDR). Empty for NOT_ALIVE_* changes.
    data: []const u8,
    /// When non-null, this change is part of a coherent set.
    /// Value = last writer SN in the coherent set; emitted as PID_COHERENT_SET.
    coherent_set_sn: ?SequenceNumber = null,
    /// Per-publisher monotonically-increasing group sequence number for this
    /// sample; emitted as PID_GROUP_SEQ_NUM.  null = not part of a group coherent set.
    group_seq_num: ?SequenceNumber = null,
    /// Last group sequence number in this group coherent set; emitted as
    /// PID_GROUP_COHERENT_SET.  Equals group_seq_num for the last sample in the set.
    group_coherent_sn: ?SequenceNumber = null,
};

// ── HistoryCache ──────────────────────────────────────────────────────────────

pub const HistoryKind = enum { keep_last, keep_all };

/// Controls which inline QoS PIDs are emitted when a deferred coherent/ordered
/// batch is flushed.
pub const CoherentFlushMode = enum(u2) {
    /// resume_publications: flush as ordinary data, no inline QoS.
    none,
    /// ordered_access without coherent_access: emit PID_GROUP_SEQ_NUM only.
    group_seq_only,
    /// coherent_access: emit PID_COHERENT_SET + PID_GROUP_SEQ_NUM + PID_GROUP_COHERENT_SET.
    full,
};

pub const HistoryCache = struct {
    alloc: std.mem.Allocator,
    kind: HistoryKind,
    /// For KEEP_LAST: maximum number of changes to retain.
    /// For KEEP_ALL: ignored.
    depth: u32,
    changes: std.ArrayListUnmanaged(CacheChange),
    /// Writer-side: next sequence number to assign (starts at 1).
    next_sn: SequenceNumber,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, kind: HistoryKind, depth: u32) Self {
        return .{
            .alloc = alloc,
            .kind = kind,
            // Clamp depth to ≥1 for KEEP_LAST so the cache always holds at least one.
            .depth = if (kind == .keep_last and depth == 0) 1 else depth,
            .changes = .empty,
            .next_sn = 1,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.changes.items) |*ch| self.alloc.free(ch.data);
        self.changes.deinit(self.alloc);
    }

    // ── Writer-side ───────────────────────────────────────────────────────────

    /// Add a new change, copying `data`. Returns the assigned sequence number.
    /// For KEEP_LAST, trims the oldest entry for `instance_handle` when that
    /// instance's count reaches `depth`, leaving other instances untouched.
    pub fn addWriterChange(
        self: *Self,
        kind: ChangeKind,
        writer_guid: Guid,
        source_timestamp: RtpsTimestamp,
        instance_handle: InstanceHandle,
        key_hash: [16]u8,
        data: []const u8,
    ) !SequenceNumber {
        const sn = self.next_sn;
        self.next_sn += 1;

        const data_copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(data_copy);

        const ch = CacheChange{
            .kind = kind,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = source_timestamp,
            .instance_handle = instance_handle,
            .key_hash = key_hash,
            .data = data_copy,
        };

        self.trimForKeepLast(instance_handle);
        try self.changes.append(self.alloc, ch);
        return sn;
    }

    // ── Reader-side ───────────────────────────────────────────────────────────

    /// Add a change received from the wire. `ch.data` is copied into the cache.
    /// Silently ignores duplicate (same writer_guid + sequence_number).
    pub fn addReaderChange(self: *Self, ch: CacheChange) !void {
        // Deduplication check.
        for (self.changes.items) |*existing| {
            if (existing.sequence_number == ch.sequence_number and
                existing.writer_guid.eql(ch.writer_guid)) return;
        }

        const data_copy = try self.alloc.dupe(u8, ch.data);
        errdefer self.alloc.free(data_copy);

        var owned = ch;
        owned.data = data_copy;

        self.trimForKeepLast(ch.instance_handle);
        try self.changes.append(self.alloc, owned);
    }

    // ── Lookup ────────────────────────────────────────────────────────────────

    /// Find a change by sequence number. Returns null if not in cache.
    pub fn getChange(self: *const Self, sn: SequenceNumber) ?*const CacheChange {
        for (self.changes.items) |*ch| {
            if (ch.sequence_number == sn) return ch;
        }
        return null;
    }

    /// Find a change by writer GUID and sequence number.
    /// Use this on the reader side where multiple writers may share the same SN.
    pub fn getChangeForWriter(self: *const Self, writer_guid: Guid, sn: SequenceNumber) ?*const CacheChange {
        for (self.changes.items) |*ch| {
            if (ch.sequence_number == sn and ch.writer_guid.eql(writer_guid)) return ch;
        }
        return null;
    }

    /// Remove and free the change with the given sequence number.
    pub fn removeChange(self: *Self, sn: SequenceNumber) void {
        var i: usize = 0;
        while (i < self.changes.items.len) {
            if (self.changes.items[i].sequence_number == sn) {
                const ch = self.changes.orderedRemove(i);
                self.alloc.free(ch.data);
                return;
            }
            i += 1;
        }
    }

    /// Remove and free all changes with SN ≤ `up_to_sn`.
    /// Called by StatefulWriter when readers acknowledge.
    pub fn removeChangesUpTo(self: *Self, up_to_sn: SequenceNumber) void {
        var i: usize = 0;
        while (i < self.changes.items.len) {
            if (self.changes.items[i].sequence_number <= up_to_sn) {
                const ch = self.changes.orderedRemove(i);
                self.alloc.free(ch.data);
            } else {
                i += 1;
            }
        }
    }

    // ── SN range queries ──────────────────────────────────────────────────────

    /// Smallest SN in the cache, or 0 if empty.
    pub fn minSn(self: *const Self) SequenceNumber {
        var min: SequenceNumber = std.math.maxInt(i64);
        for (self.changes.items) |*ch| {
            if (ch.sequence_number < min) min = ch.sequence_number;
        }
        return if (min == std.math.maxInt(i64)) 0 else min;
    }

    /// Largest SN in the cache, or 0 if empty.
    pub fn maxSn(self: *const Self) SequenceNumber {
        var max: SequenceNumber = 0;
        for (self.changes.items) |*ch| {
            if (ch.sequence_number > max) max = ch.sequence_number;
        }
        return max;
    }

    /// Number of changes currently in the cache.
    pub fn len(self: *const Self) usize {
        return self.changes.items.len;
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    fn trimForKeepLast(self: *Self, ih: InstanceHandle) void {
        if (self.kind != .keep_last) return;
        if (self.depth == 0) return;
        // Count how many changes we already have for this instance.
        var count: usize = 0;
        for (self.changes.items) |*ch| {
            if (std.mem.eql(u8, &ch.instance_handle, &ih)) count += 1;
        }
        // Evict the oldest entry for this instance until count < depth.
        while (count >= self.depth) {
            var i: usize = 0;
            while (i < self.changes.items.len) : (i += 1) {
                if (std.mem.eql(u8, &self.changes.items[i].instance_handle, &ih)) {
                    const evicted = self.changes.orderedRemove(i);
                    self.alloc.free(evicted.data);
                    count -= 1;
                    break;
                }
            }
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeGuid(b: u8) Guid {
    return .{
        .prefix = .{ .bytes = [_]u8{b} ** 12 },
        .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0xC1 },
    };
}

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH: InstanceHandle = INSTANCE_HANDLE_NIL;
const NIL_KH: [16]u8 = std.mem.zeroes([16]u8);

test "HistoryCache KEEP_LAST depth=1 evicts oldest" {
    var cache = HistoryCache.init(testing.allocator, .keep_last, 1);
    defer cache.deinit();

    const g = makeGuid(1);
    const sn1 = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "hello");
    try testing.expectEqual(@as(usize, 1), cache.len());
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "world");
    // After second add, first was evicted.
    try testing.expectEqual(@as(usize, 1), cache.len());
    try testing.expectEqual(@as(?*const CacheChange, null), cache.getChange(sn1));
}

test "HistoryCache KEEP_ALL retains all" {
    var cache = HistoryCache.init(testing.allocator, .keep_all, 0);
    defer cache.deinit();

    const g = makeGuid(2);
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "b");
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "c");
    try testing.expectEqual(@as(usize, 3), cache.len());
}

test "HistoryCache getChange and removeChange" {
    var cache = HistoryCache.init(testing.allocator, .keep_all, 0);
    defer cache.deinit();

    const g = makeGuid(3);
    const sn1 = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "data1");
    const sn2 = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "data2");

    const ch = cache.getChange(sn1).?;
    try testing.expectEqualStrings("data1", ch.data);
    try testing.expectEqual(sn1, ch.sequence_number);

    cache.removeChange(sn1);
    try testing.expectEqual(@as(?*const CacheChange, null), cache.getChange(sn1));
    try testing.expect(cache.getChange(sn2) != null);
}

test "HistoryCache removeChangesUpTo" {
    var cache = HistoryCache.init(testing.allocator, .keep_all, 0);
    defer cache.deinit();

    const g = makeGuid(4);
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "b");
    const sn3 = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "c");

    cache.removeChangesUpTo(2);
    try testing.expectEqual(@as(usize, 1), cache.len());
    try testing.expect(cache.getChange(sn3) != null);
}

test "HistoryCache minSn maxSn" {
    var cache = HistoryCache.init(testing.allocator, .keep_all, 0);
    defer cache.deinit();

    try testing.expectEqual(@as(SequenceNumber, 0), cache.minSn());
    try testing.expectEqual(@as(SequenceNumber, 0), cache.maxSn());

    const g = makeGuid(5);
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "x");
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, NIL_IH, NIL_KH, "y");

    try testing.expectEqual(@as(SequenceNumber, 1), cache.minSn());
    try testing.expectEqual(@as(SequenceNumber, 2), cache.maxSn());
}

test "HistoryCache KEEP_LAST per-instance: depth=1 evicts per-instance not globally" {
    var cache = HistoryCache.init(testing.allocator, .keep_last, 1);
    defer cache.deinit();

    const g = makeGuid(7);
    var ih_a: InstanceHandle = std.mem.zeroes([16]u8);
    var ih_b: InstanceHandle = std.mem.zeroes([16]u8);
    ih_a[0] = 0xAA;
    ih_b[0] = 0xBB;

    // Write one change for instance A, one for instance B.
    const sn_a1 = try cache.addWriterChange(.alive, g, ZERO_TS, ih_a, NIL_KH, "a1");
    const sn_b1 = try cache.addWriterChange(.alive, g, ZERO_TS, ih_b, NIL_KH, "b1");
    try testing.expectEqual(@as(usize, 2), cache.len()); // both retained

    // Write a second change for instance A — should evict a1 but not b1.
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, ih_a, NIL_KH, "a2");
    try testing.expectEqual(@as(usize, 2), cache.len());
    try testing.expectEqual(@as(?*const CacheChange, null), cache.getChange(sn_a1));
    try testing.expect(cache.getChange(sn_b1) != null);
}

test "HistoryCache KEEP_LAST per-instance: depth=2 independent per instance" {
    var cache = HistoryCache.init(testing.allocator, .keep_last, 2);
    defer cache.deinit();

    const g = makeGuid(8);
    var ih_a: InstanceHandle = std.mem.zeroes([16]u8);
    ih_a[0] = 0xAA;

    const sn1 = try cache.addWriterChange(.alive, g, ZERO_TS, ih_a, NIL_KH, "1");
    const sn2 = try cache.addWriterChange(.alive, g, ZERO_TS, ih_a, NIL_KH, "2");
    try testing.expectEqual(@as(usize, 2), cache.len());
    // Third write: evicts sn1 (oldest for ih_a), keeps sn2 and new.
    _ = try cache.addWriterChange(.alive, g, ZERO_TS, ih_a, NIL_KH, "3");
    try testing.expectEqual(@as(usize, 2), cache.len());
    try testing.expectEqual(@as(?*const CacheChange, null), cache.getChange(sn1));
    try testing.expect(cache.getChange(sn2) != null);
}

test "HistoryCache addReaderChange deduplication" {
    var cache = HistoryCache.init(testing.allocator, .keep_all, 0);
    defer cache.deinit();

    const g = makeGuid(6);
    var payload = [_]u8{ 0x00, 0x07, 0x00, 0x00 };
    const ch = CacheChange{
        .kind = .alive,
        .writer_guid = g,
        .sequence_number = 42,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &payload,
    };
    try cache.addReaderChange(ch);
    try cache.addReaderChange(ch); // duplicate — should be ignored
    try testing.expectEqual(@as(usize, 1), cache.len());
}
