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
