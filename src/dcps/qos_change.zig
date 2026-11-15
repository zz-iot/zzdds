//! What a `set_qos` changes: whether two QoS values are equal by content,
//! and whether a change touches a policy DDS makes immutable once the entity
//! is enabled (DDS v1.4 §2.2.3, the "Changeable" column).

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;

/// `a` and `b` hold the same QoS: sequences and strings compare by content.
pub fn eql(comptime T: type, a: *const T, b: *const T) bool {
    return eqlValue(T, a.*, b.*);
}

fn eqlValue(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            if (comptime isSequence(T)) {
                const len = seqLen(a);
                if (len != seqLen(b)) return false;
                const E = @typeInfo(@typeInfo(@FieldType(T, "_buffer")).optional.child).pointer.child;
                for (0..len) |i| if (!eqlValue(E, a._buffer.?[i], b._buffer.?[i])) return false;
                return true;
            }
            inline for (info.field_names) |name| {
                if (!eqlValue(@FieldType(T, name), @field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (a.len != b.len) return false;
                for (a, b) |x, y| if (!eqlValue(p.child, x, y)) return false;
                return true;
            }
            if (p.size == .many and p.child == u8 and p.sentinel() != null) {
                return std.mem.orderZ(u8, a, b) == .eq;
            }
            @compileError("no content comparison for " ++ @typeName(T));
        },
        .optional => |o| {
            if (a == null or b == null) return a == null and b == null;
            return eqlValue(o.child, a.?, b.?);
        },
        .array => |arr| {
            for (a, b) |x, y| if (!eqlValue(arr.child, x, y)) return false;
            return true;
        },
        else => return a == b,
    }
}

fn isSequence(comptime T: type) bool {
    return @hasField(T, "_buffer") and @hasField(T, "_length");
}

fn seqLen(s: anytype) usize {
    return if (s._buffer != null) s._length else 0;
}

/// Policies of a DataWriter that cannot change once it is enabled. zzdds
/// creates the protocol writer with them, so they cannot change before
/// either.
const writer_immutable = .{
    "durability",
    "durability_service",
    "liveliness",
    "reliability",
    "destination_order",
    "history",
    "resource_limits",
    "ownership",
    "data_representation",
};

/// `writer_immutable`, for a DataReader.
const reader_immutable = .{
    "durability",
    "liveliness",
    "reliability",
    "destination_order",
    "history",
    "resource_limits",
    "ownership",
    "data_representation",
};

/// `new` changes one of `old`'s immutable policies.
pub fn writerImmutableChanged(old: *const DDS.DataWriterQos, new: *const DDS.DataWriterQos) bool {
    return immutableChanged(DDS.DataWriterQos, writer_immutable, old, new);
}

/// `writerImmutableChanged`, for a DataReader.
pub fn readerImmutableChanged(old: *const DDS.DataReaderQos, new: *const DDS.DataReaderQos) bool {
    return immutableChanged(DDS.DataReaderQos, reader_immutable, old, new);
}

fn immutableChanged(comptime T: type, comptime names: anytype, old: *const T, new: *const T) bool {
    inline for (names) |name| {
        if (comptime !@hasField(T, name)) continue;
        if (!eql(@FieldType(T, name), &@field(old, name), &@field(new, name))) return true;
    }
    return false;
}

/// A DataWriter's, DataReader's or Topic's `qos` keeps the consistency rules
/// between its policies (DDS 1.4 §2.2.3): a KEEP_LAST HISTORY no deeper
/// than RESOURCE_LIMITS' max_samples_per_instance, which max_samples is no
/// smaller than; the same within DURABILITY_SERVICE; and a DEADLINE period
/// no shorter than the TIME_BASED_FILTER's minimum separation. Otherwise
/// creation fails and `set_qos` returns INCONSISTENT_POLICY.
pub fn consistent(comptime T: type, qos: *const T) bool {
    if (@hasField(T, "history") and @hasField(T, "resource_limits")) {
        const rl = qos.resource_limits;
        if (!limitsConsistent(qos.history.kind, qos.history.depth, rl.max_samples, rl.max_samples_per_instance)) return false;
    }
    if (@hasField(T, "durability_service")) {
        const ds = qos.durability_service;
        if (!limitsConsistent(ds.history_kind, ds.history_depth, ds.max_samples, ds.max_samples_per_instance)) return false;
    }
    if (@hasField(T, "deadline") and @hasField(T, "time_based_filter")) {
        const period = qos.deadline.period;
        // {0, 0} is the unset policy: no deadline, as INFINITE.
        const no_deadline = (period.sec == 0 and period.nanosec == 0) or
            (period.sec == DDS.DURATION_INFINITE_SEC and period.nanosec == DDS.DURATION_INFINITE_NSEC);
        if (!no_deadline and durationNs(period) < durationNs(qos.time_based_filter.minimum_separation)) return false;
    }
    return true;
}

/// Limits of zero or less are unlimited, and a depth of zero or less is 1.
fn limitsConsistent(kind: DDS.HistoryQosPolicyKind, depth: i32, max_samples: i32, max_per_instance: i32) bool {
    if (max_per_instance <= 0) return true;
    if (kind == .KEEP_LAST_HISTORY_QOS and @max(depth, 1) > max_per_instance) return false;
    return max_samples <= 0 or max_samples >= max_per_instance;
}

fn durationNs(d: DDS.Duration_t) i128 {
    return @as(i128, d.sec) * std.time.ns_per_s + d.nanosec;
}

test "QoS values compare by content, sequences and strings included" {
    var a: DDS.PublisherQos = .{};
    var b: DDS.PublisherQos = .{};
    try std.testing.expect(eql(DDS.PublisherQos, &a, &b));
    var names_a = [_][*:0]const u8{ "p1", "p2" };
    var names_b = [_][*:0]const u8{ "p1", "p2" };
    a.partition.name = .{ ._buffer = &names_a, ._length = 2, ._maximum = 2, ._release = false };
    try std.testing.expect(!eql(DDS.PublisherQos, &a, &b));
    b.partition.name = .{ ._buffer = &names_b, ._length = 2, ._maximum = 2, ._release = false };
    try std.testing.expect(eql(DDS.PublisherQos, &a, &b));
    names_b[1] = "p3";
    try std.testing.expect(!eql(DDS.PublisherQos, &a, &b));
}

test "a writer's mutable policies change freely, its immutable ones do not" {
    const old: DDS.DataWriterQos = .{};
    var new: DDS.DataWriterQos = .{};
    new.deadline.period = .{ .sec = 1, .nanosec = 0 };
    new.ownership_strength.value = 5;
    try std.testing.expect(!writerImmutableChanged(&old, &new));
    new.history.depth = 7;
    try std.testing.expect(writerImmutableChanged(&old, &new));
}

test "a KEEP_LAST history deeper than its per-instance limit, or a per-instance limit above max_samples, is inconsistent; unlimited ones never are" {
    var q: DDS.DataReaderQos = .{};
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.resource_limits.max_samples_per_instance = 4;
    q.history.depth = 4;
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.history.depth = 5;
    try std.testing.expect(!consistent(DDS.DataReaderQos, &q));
    q.history.kind = .KEEP_ALL_HISTORY_QOS;
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.resource_limits.max_samples = 3;
    try std.testing.expect(!consistent(DDS.DataReaderQos, &q));
    q.resource_limits.max_samples = DDS.LENGTH_UNLIMITED;
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.resource_limits.max_samples_per_instance = DDS.LENGTH_UNLIMITED;
    q.resource_limits.max_samples = 1;
    q.history = .{ .kind = .KEEP_LAST_HISTORY_QOS, .depth = 50 };
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
}

test "a writer's or Topic's DURABILITY_SERVICE keeps the same rules within itself" {
    var w: DDS.DataWriterQos = .{};
    w.durability_service.max_samples_per_instance = 2;
    w.durability_service.history_depth = 3;
    try std.testing.expect(!consistent(DDS.DataWriterQos, &w));
    w.durability_service.history_depth = 2;
    w.durability_service.max_samples = 1;
    try std.testing.expect(!consistent(DDS.DataWriterQos, &w));
    w.durability_service.max_samples = 2;
    try std.testing.expect(consistent(DDS.DataWriterQos, &w));
    var t: DDS.TopicQos = .{};
    t.durability_service.max_samples_per_instance = 1;
    t.durability_service.history_depth = 2;
    try std.testing.expect(!consistent(DDS.TopicQos, &t));
}

test "a reader's DEADLINE shorter than its TIME_BASED_FILTER is inconsistent, and no DEADLINE never is" {
    var q: DDS.DataReaderQos = .{};
    q.time_based_filter.minimum_separation = .{ .sec = 1, .nanosec = 0 };
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.deadline.period = .{ .sec = DDS.DURATION_INFINITE_SEC, .nanosec = DDS.DURATION_INFINITE_NSEC };
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.deadline.period = .{ .sec = 1, .nanosec = 0 };
    try std.testing.expect(consistent(DDS.DataReaderQos, &q));
    q.deadline.period = .{ .sec = 0, .nanosec = 999_999_999 };
    try std.testing.expect(!consistent(DDS.DataReaderQos, &q));
}
