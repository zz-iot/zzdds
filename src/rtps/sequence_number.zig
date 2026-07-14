//! RTPS SequenceNumber_t (RTPS 2.5 §9.3.2).
//!
//! On the wire: two consecutive 32-bit fields (big-endian within the struct
//! regardless of host byte order, because RTPS encodes them as signed i32 high
//! + unsigned u32 low). In Zig we represent the logical value as i64 for
//! arithmetic, converting to/from wire form at the serialization boundary.
//!
//! Valid range: 1 .. 2^63-1. Zero and negative values are reserved.
//! SEQUENCENUMBER_UNKNOWN = {high=-1, low=0} (RTPS 2.5 §9.3.2 IDL comment) →
//! logical value = -1 (sentinel).

const std = @import("std");

/// RTPS on-wire representation (§9.3.2 Table 9.11).
pub const SequenceNumberWire = extern struct {
    high: i32, // most-significant 32 bits (signed)
    low: u32, // least-significant 32 bits (unsigned)
};

/// Logical sequence number. Use i64 arithmetic throughout Zenzen DDS internals.
/// Convert to/from SequenceNumberWire only at the (de)serialization boundary.
pub const SequenceNumber = i64;

pub const SEQUENCENUMBER_UNKNOWN: SequenceNumber = -1;
pub const SEQUENCENUMBER_ZERO: SequenceNumber = 0;

/// Pack a logical sequence number into wire form.
pub fn toWire(sn: SequenceNumber) SequenceNumberWire {
    if (sn == SEQUENCENUMBER_UNKNOWN) {
        return .{ .high = -1, .low = 0 };
    }
    return .{
        .high = @intCast(sn >> 32),
        .low = @intCast(sn & 0xffff_ffff),
    };
}

/// Unpack wire form to logical sequence number.
pub fn fromWire(w: SequenceNumberWire) SequenceNumber {
    if (w.high == -1 and w.low == 0) {
        return SEQUENCENUMBER_UNKNOWN;
    }
    const h: i64 = @as(i64, w.high) << 32;
    const l: i64 = @as(i64, w.low);
    return h | l;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "SequenceNumberWire is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(SequenceNumberWire));
}

test "round-trip: small values" {
    for ([_]SequenceNumber{ 1, 2, 100, 1_000_000, std.math.maxInt(i32) }) |sn| {
        try std.testing.expectEqual(sn, fromWire(toWire(sn)));
    }
}

test "round-trip: large values spanning high word" {
    const large: SequenceNumber = (@as(i64, 1) << 32) + 7;
    try std.testing.expectEqual(large, fromWire(toWire(large)));
}

test "SEQUENCENUMBER_UNKNOWN round-trip" {
    try std.testing.expectEqual(SEQUENCENUMBER_UNKNOWN, fromWire(toWire(SEQUENCENUMBER_UNKNOWN)));
}

test "toWire zero" {
    const w = toWire(0);
    try std.testing.expectEqual(@as(i32, 0), w.high);
    try std.testing.expectEqual(@as(u32, 0), w.low);
}
