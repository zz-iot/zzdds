//! The `policies` of a DataReader's RequestedIncompatibleQosStatus or a
//! DataWriter's OfferedIncompatibleQosStatus (DDS 1.4 §2.2.4.1): for each
//! policy, how many times a remote endpoint was found incompatible on it.
//! Kept with the entity's other incompatible-QoS counters, under its lock.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;

/// QosPolicyId_t values counted: every policy DDS 1.4 and DDS-XTypes number
/// fits below this. An id at or above it is counted in the totals only.
pub const id_limit = 32;

pub const Counts = struct {
    by_id: [id_limit]i32 = @splat(0),

    pub fn record(self: *Counts, policy_id: DDS.QosPolicyId_t) void {
        if (policy_id < 0 or policy_id >= id_limit) return;
        self.by_id[@intCast(policy_id)] += 1;
    }

    /// The policies counted so far, in policy-id order, written into `out`.
    pub fn view(self: *const Counts, out: *[id_limit]DDS.QosPolicyCount) []DDS.QosPolicyCount {
        var n: usize = 0;
        for (self.by_id, 0..) |count, id| {
            if (count == 0) continue;
            out[n] = .{ .policy_id = @intCast(id), .count = count };
            n += 1;
        }
        return out[0..n];
    }

    /// A sequence over `out` for a listener: it borrows `out`, so it is valid
    /// only while `out` is.
    pub fn borrowed(self: *const Counts, out: *[id_limit]DDS.QosPolicyCount) DDS.QosPolicyCountSeq {
        const v = self.view(out);
        const n: u32 = @intCast(v.len);
        return .{ ._buffer = if (n == 0) null else v.ptr, ._length = n, ._maximum = n, ._release = false };
    }

    /// Writes the counts into a getter's inout `seq`, as other inout
    /// sequences are: into its buffer when that has room, otherwise into one
    /// allocated from `alloc` (`_release` set, for the caller to free),
    /// freeing a buffer the caller passed with `_release` set. On failure
    /// `seq` is unchanged.
    pub fn fill(self: *const Counts, alloc: std.mem.Allocator, seq: *DDS.QosPolicyCountSeq) error{OutOfMemory}!void {
        var buf: [id_limit]DDS.QosPolicyCount = undefined;
        const v = self.view(&buf);
        const n: u32 = @intCast(v.len);
        if (seq._buffer) |b| if (seq._maximum >= n) {
            @memcpy(b[0..n], v);
            seq._length = n;
            return;
        };
        if (n == 0) {
            seq.* = .{};
            return;
        }
        const owned = try alloc.alloc(DDS.QosPolicyCount, n);
        @memcpy(owned, v);
        if (seq._release) if (seq._buffer) |b| alloc.free(b[0..seq._maximum]);
        seq.* = .{ ._buffer = owned.ptr, ._length = n, ._maximum = n, ._release = true };
    }
};

const testing = std.testing;

test "counts each policy, in id order, and ignores ids outside the range" {
    var c: Counts = .{};
    c.record(11);
    c.record(2);
    c.record(11);
    c.record(-1);
    c.record(id_limit);
    var buf: [id_limit]DDS.QosPolicyCount = undefined;
    const v = c.view(&buf);
    try testing.expectEqual(@as(usize, 2), v.len);
    try testing.expectEqual(DDS.QosPolicyCount{ .policy_id = 2, .count = 1 }, v[0]);
    try testing.expectEqual(DDS.QosPolicyCount{ .policy_id = 11, .count = 2 }, v[1]);
}

test "fill allocates when the caller's sequence has no room, and reuses one that does" {
    var c: Counts = .{};
    c.record(4);
    var seq: DDS.QosPolicyCountSeq = .{};
    try c.fill(testing.allocator, &seq);
    try testing.expect(seq._release);
    try testing.expectEqual(@as(u32, 1), seq._length);
    try testing.expectEqual(@as(i32, 4), seq._buffer.?[0].policy_id);

    // Room for two: grown, the old buffer freed.
    c.record(8);
    const old = seq._buffer;
    try c.fill(testing.allocator, &seq);
    try testing.expect(seq._buffer != old);
    try testing.expectEqual(@as(u32, 2), seq._length);
    try testing.expectEqual(@as(u32, 2), seq._maximum);

    // Enough room already: filled in place.
    const kept = seq._buffer;
    try c.fill(testing.allocator, &seq);
    try testing.expectEqual(kept, seq._buffer);
    seq.deinit(testing.allocator);

    // A caller's own buffer is filled, never freed or replaced.
    var mine: [4]DDS.QosPolicyCount = undefined;
    var borrowed: DDS.QosPolicyCountSeq = .{ ._buffer = &mine, ._maximum = mine.len };
    try c.fill(testing.allocator, &borrowed);
    try testing.expectEqual(@as(?[*]DDS.QosPolicyCount, &mine), borrowed._buffer);
    try testing.expectEqual(@as(u32, 2), borrowed._length);
    try testing.expect(!borrowed._release);
}

test "fill leaves the sequence as it was when it cannot allocate" {
    var c: Counts = .{};
    c.record(4);
    var seq: DDS.QosPolicyCountSeq = .{};
    try testing.expectError(error.OutOfMemory, c.fill(testing.failing_allocator, &seq));
    try testing.expectEqual(DDS.QosPolicyCountSeq{}, seq);
}
