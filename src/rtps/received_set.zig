//! Range-based disjoint sequence set for RTPS sequence number tracking.
//!
//! Tracks received sequence numbers as a compact list of non-overlapping [lo, hi]
//! ranges, sorted ascending by lo.  Adjacent ranges are coalesced on insertion, so
//! memory is O(number of gaps) rather than O(total SNs received — ideal for long-
//! lived subscriptions.
//!
//! Analogous to OpenDDS's DisjointSequence (dds/DCPS/DisjointSequence.h).

const std = @import("std");
const sn_mod = @import("sequence_number.zig");

pub const SequenceNumber = sn_mod.SequenceNumber;

pub const Range = struct { lo: SequenceNumber, hi: SequenceNumber };

pub const ReceivedSet = struct {
    /// Non-overlapping, non-adjacent ranges sorted ascending by lo.
    ranges: std.ArrayListUnmanaged(Range),

    pub const empty: ReceivedSet = .{ .ranges = .empty };

    pub fn deinit(self: *ReceivedSet, alloc: std.mem.Allocator) void {
        self.ranges.deinit(alloc);
    }

    /// Insert `sn`.  Returns true if it was new, false if already present or invalid.
    /// Coalesces with adjacent ranges after insertion.
    /// RTPS valid SNs are ≥ 1; negative values (including SEQUENCENUMBER_UNKNOWN) are rejected.
    pub fn insert(self: *ReceivedSet, alloc: std.mem.Allocator, sn: SequenceNumber) !bool {
        if (sn < 1) return false; // invalid SN (SEQUENCENUMBER_UNKNOWN = -1, etc.)
        if (self.contains(sn)) return false;

        // Find insertion index: first range whose lo > sn.
        var idx: usize = 0;
        while (idx < self.ranges.items.len and self.ranges.items[idx].lo <= sn) : (idx += 1) {}

        try self.ranges.insert(alloc, idx, .{ .lo = sn, .hi = sn });

        // Coalesce with predecessor if its hi is adjacent.
        if (idx > 0 and self.ranges.items[idx - 1].hi + 1 == sn) {
            self.ranges.items[idx - 1].hi = self.ranges.items[idx].hi;
            _ = self.ranges.orderedRemove(idx);
            idx -= 1;
        }

        // Coalesce with successor if its lo is adjacent.
        if (idx + 1 < self.ranges.items.len and self.ranges.items[idx].hi + 1 == self.ranges.items[idx + 1].lo) {
            self.ranges.items[idx].hi = self.ranges.items[idx + 1].hi;
            _ = self.ranges.orderedRemove(idx + 1);
        }

        return true;
    }

    /// True if `sn` has been inserted.
    pub fn contains(self: *const ReceivedSet, sn: SequenceNumber) bool {
        for (self.ranges.items) |r| {
            if (sn < r.lo) return false; // sorted: no later range can match
            if (sn <= r.hi) return true;
        }
        return false;
    }

    /// The highest SN in the contiguous prefix starting at 1.
    /// Returns 0 when SN 1 has not yet been received.
    pub fn cumulativeAck(self: *const ReceivedSet) SequenceNumber {
        if (self.ranges.items.len == 0) return 0;
        const first = self.ranges.items[0];
        if (first.lo > 1) return 0;
        return first.hi;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ReceivedSet empty" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    try testing.expect(!rs.contains(1));
    try testing.expectEqual(@as(SequenceNumber, 0), rs.cumulativeAck());
}

test "ReceivedSet in-order inserts coalesce to one range" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    try testing.expect(try rs.insert(testing.allocator, 1));
    try testing.expect(try rs.insert(testing.allocator, 2));
    try testing.expect(try rs.insert(testing.allocator, 3));
    try testing.expectEqual(@as(usize, 1), rs.ranges.items.len);
    try testing.expectEqual(@as(SequenceNumber, 3), rs.cumulativeAck());
}

test "ReceivedSet duplicate returns false" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    try testing.expect(try rs.insert(testing.allocator, 5));
    try testing.expect(!try rs.insert(testing.allocator, 5));
    try testing.expectEqual(@as(usize, 1), rs.ranges.items.len);
}

test "ReceivedSet out-of-order gap then fill coalesces" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    _ = try rs.insert(testing.allocator, 1);
    _ = try rs.insert(testing.allocator, 3); // gap at 2 → two ranges [1,1] [3,3]
    try testing.expectEqual(@as(usize, 2), rs.ranges.items.len);
    try testing.expectEqual(@as(SequenceNumber, 1), rs.cumulativeAck());

    _ = try rs.insert(testing.allocator, 2); // fill gap → coalesces to [1,3]
    try testing.expectEqual(@as(usize, 1), rs.ranges.items.len);
    try testing.expectEqual(@as(SequenceNumber, 3), rs.cumulativeAck());
}

test "ReceivedSet gap before SN 1 gives cumulativeAck 0" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    _ = try rs.insert(testing.allocator, 5);
    try testing.expectEqual(@as(SequenceNumber, 0), rs.cumulativeAck());
    try testing.expect(rs.contains(5));
    try testing.expect(!rs.contains(1));
}

test "ReceivedSet multiple gaps" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    // Insert 1, 3, 5 — three disjoint ranges.
    _ = try rs.insert(testing.allocator, 1);
    _ = try rs.insert(testing.allocator, 3);
    _ = try rs.insert(testing.allocator, 5);
    try testing.expectEqual(@as(usize, 3), rs.ranges.items.len);
    try testing.expectEqual(@as(SequenceNumber, 1), rs.cumulativeAck());

    // Fill 2 → [1,3] [5,5].
    _ = try rs.insert(testing.allocator, 2);
    try testing.expectEqual(@as(usize, 2), rs.ranges.items.len);
    try testing.expectEqual(@as(SequenceNumber, 3), rs.cumulativeAck());

    // Fill 4 → [1,5].
    _ = try rs.insert(testing.allocator, 4);
    try testing.expectEqual(@as(usize, 1), rs.ranges.items.len);
    try testing.expectEqual(@as(SequenceNumber, 5), rs.cumulativeAck());
}

test "ReceivedSet contains boundary cases" {
    var rs = ReceivedSet.empty;
    defer rs.deinit(testing.allocator);

    _ = try rs.insert(testing.allocator, 10);
    _ = try rs.insert(testing.allocator, 11);
    _ = try rs.insert(testing.allocator, 12);

    try testing.expect(!rs.contains(9));
    try testing.expect(rs.contains(10));
    try testing.expect(rs.contains(11));
    try testing.expect(rs.contains(12));
    try testing.expect(!rs.contains(13));
}
