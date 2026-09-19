//! Shared receive-sequence verification for discovery/association race
//! tests (`docs/design/discovery-association-race-testing.md`).
//!
//! Samples in these scenarios carry a big-endian u32 monotonic counter as
//! the first 4 bytes of their payload (the rest, if any, is scenario-
//! specific and ignored here). `Checker.verify` checks the same five
//! properties every scenario in this test category needs: first-sample
//! correctness, strict order, no duplicates, no unexpected mid-stream gaps,
//! and exact completeness -- so no scenario reimplements these checks.

const std = @import("std");

/// Encodes `counter` into `buf` as the wire payload a writer should send.
pub fn payloadFor(buf: *[4]u8, counter: u32) []const u8 {
    std.mem.writeInt(u32, buf, counter, .big);
    return buf;
}

pub const Checker = struct {
    /// Decodes the counter a `payloadFor`-encoded sample started with.
    pub fn counterOf(sample: []const u8) !u32 {
        if (sample.len < 4) return error.SampleTooShort;
        return std.mem.readInt(u32, sample[0..4], .big);
    }

    pub const Report = struct {
        first_mismatch: ?struct { expected: u32, got: u32 } = null,
        /// Any counter seen more than once, or seen out of increasing order
        /// (a reorder manifests as its later occurrence looking like a
        /// duplicate/regression here -- both are "not a clean forward
        /// sequence").
        duplicates: std.ArrayListUnmanaged(u32) = .empty,
        /// Every counter value skipped between the first and last received.
        gaps: std.ArrayListUnmanaged(u32) = .empty,
        /// The subset of `gaps` not present in the scenario's declared
        /// `allowed_gaps` -- these are the actual failures; `gaps` alone is
        /// diagnostic, not a verdict.
        unexpected_gaps: std.ArrayListUnmanaged(u32) = .empty,
        count_mismatch: ?struct { expected: usize, got: usize } = null,

        pub fn deinit(self: *Report, alloc: std.mem.Allocator) void {
            self.duplicates.deinit(alloc);
            self.gaps.deinit(alloc);
            self.unexpected_gaps.deinit(alloc);
        }

        pub fn ok(self: *const Report) bool {
            return self.first_mismatch == null and
                self.duplicates.items.len == 0 and
                self.unexpected_gaps.items.len == 0 and
                self.count_mismatch == null;
        }
    };

    /// `received`: counters in the order actually taken from the reader.
    /// `expected_first`: the counter the very first received sample must
    /// carry (catches silently-skipped leading samples).
    /// `expected_count`: exact number of samples the scenario expects to
    /// have received.
    /// `allowed_gaps`: counters this scenario deliberately expects to be
    /// missing (pass `&.{}` for "no gaps expected at all").
    pub fn verify(
        alloc: std.mem.Allocator,
        received: []const u32,
        expected_first: u32,
        expected_count: usize,
        allowed_gaps: []const u32,
    ) !Report {
        var report = Report{};
        errdefer report.deinit(alloc);

        if (received.len == 0) {
            if (expected_count != 0) {
                report.count_mismatch = .{ .expected = expected_count, .got = 0 };
            }
            return report;
        }

        if (received[0] != expected_first) {
            report.first_mismatch = .{ .expected = expected_first, .got = received[0] };
        }

        var seen: std.AutoHashMapUnmanaged(u32, void) = .empty;
        defer seen.deinit(alloc);
        var prev: ?u32 = null;
        for (received) |c| {
            if (seen.contains(c)) {
                try report.duplicates.append(alloc, c);
            } else {
                try seen.put(alloc, c, {});
            }
            if (prev) |p| {
                if (c <= p) {
                    try report.duplicates.append(alloc, c);
                } else if (c > p + 1) {
                    var missing = p + 1;
                    while (missing < c) : (missing += 1) {
                        try report.gaps.append(alloc, missing);
                        if (std.mem.indexOfScalar(u32, allowed_gaps, missing) == null) {
                            try report.unexpected_gaps.append(alloc, missing);
                        }
                    }
                }
            }
            prev = c;
        }

        if (received.len != expected_count) {
            report.count_mismatch = .{ .expected = expected_count, .got = received.len };
        }

        return report;
    }
};

test "Checker.verify: clean sequence passes" {
    const alloc = std.testing.allocator;
    var report = try Checker.verify(alloc, &.{ 0, 1, 2 }, 0, 3, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(report.ok());
}

test "Checker.verify: missing first sample is caught" {
    const alloc = std.testing.allocator;
    var report = try Checker.verify(alloc, &.{ 1, 2 }, 0, 2, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(!report.ok());
    try std.testing.expect(report.first_mismatch != null);
}

test "Checker.verify: unexpected mid-stream gap is caught" {
    const alloc = std.testing.allocator;
    var report = try Checker.verify(alloc, &.{ 0, 2 }, 0, 2, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.unexpected_gaps.items.len);
    try std.testing.expectEqual(@as(u32, 1), report.unexpected_gaps.items[0]);
}

test "Checker.verify: declared allowed gap does not fail" {
    const alloc = std.testing.allocator;
    var report = try Checker.verify(alloc, &.{ 0, 2 }, 0, 2, &.{1});
    defer report.deinit(alloc);
    try std.testing.expect(report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.gaps.items.len);
    try std.testing.expectEqual(@as(usize, 0), report.unexpected_gaps.items.len);
}

test "Checker.verify: duplicate sample is caught" {
    const alloc = std.testing.allocator;
    var report = try Checker.verify(alloc, &.{ 0, 1, 1, 2 }, 0, 4, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(!report.ok());
    try std.testing.expectEqual(@as(usize, 1), report.duplicates.items.len);
}

test "Checker.verify: missing-from-the-end is a count mismatch" {
    const alloc = std.testing.allocator;
    var report = try Checker.verify(alloc, &.{ 0, 1 }, 0, 3, &.{});
    defer report.deinit(alloc);
    try std.testing.expect(!report.ok());
    try std.testing.expect(report.count_mismatch != null);
}
