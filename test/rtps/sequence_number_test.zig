//! SequenceNumber_t boundary-case tests (RTPS 2.5 §9.3.2, §9.3.2.1).
//!
//! Tests the arithmetic and comparison correctness at the 32-bit word boundary,
//! and verifies that SEQUENCENUMBER_UNKNOWN is not treated as a valid SN.

const std = @import("std");
const zzdds = @import("zzdds");

const sn_mod = zzdds.rtps.sequence_number;
const msg = zzdds.rtps.message;
const sub = msg.submessage;

const SequenceNumber = sn_mod.SequenceNumber;
const SequenceNumberSet = msg.SequenceNumberSet;
const WriterProxy = zzdds.rtps.WriterProxy;
const Guid = zzdds.rtps.Guid;

const UNKNOWN = sn_mod.SEQUENCENUMBER_UNKNOWN;

const testing = std.testing;

fn makeGuid(b: u8) Guid {
    return .{
        .prefix = .{ .bytes = [_]u8{b} ** 12 },
        .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0xC2 },
    };
}

// ── Wire arithmetic at the 32-bit word boundary ───────────────────────────────

test "SN toWire: {high=0, low=0xFFFFFFFF} is logical 0xFFFFFFFF" {
    const sn: SequenceNumber = 0xFFFF_FFFF;
    const w = sn_mod.toWire(sn);
    try testing.expectEqual(@as(i32, 0), w.high);
    try testing.expectEqual(@as(u32, 0xFFFF_FFFF), w.low);
}

test "SN toWire: crossing the word boundary — 0xFFFFFFFF + 1 → {high=1, low=0}" {
    const sn: SequenceNumber = @as(i64, 0xFFFF_FFFF) + 1; // = 0x1_0000_0000
    const w = sn_mod.toWire(sn);
    try testing.expectEqual(@as(i32, 1), w.high);
    try testing.expectEqual(@as(u32, 0), w.low);
}

test "SN round-trip at word boundary" {
    const sn: SequenceNumber = 0xFFFF_FFFF;
    try testing.expectEqual(sn, sn_mod.fromWire(sn_mod.toWire(sn)));
    try testing.expectEqual(sn + 1, sn_mod.fromWire(sn_mod.toWire(sn + 1)));
}

// ── SequenceNumberSet.contains near word boundary ────────────────────────────

test "SequenceNumberSet.contains with large base (near u32 max)" {
    // Use a base close to the wire u32 boundary.
    const base: SequenceNumber = 0xFFFF_0000;
    var sns = SequenceNumberSet{ .base = base, .num_bits = 256, .bitmap = std.mem.zeroes([8]u32) };

    // Set bit for the very first SN (offset 0).
    sns.set(base);
    try testing.expect(sns.contains(base));
    try testing.expect(!sns.contains(base + 1));

    // Set bit for SN at offset 255 (last possible bit).
    sns.set(base + 255);
    try testing.expect(sns.contains(base + 255));
    try testing.expect(!sns.contains(base + 256)); // beyond num_bits

    // SNs below base are never in the set.
    try testing.expect(!sns.contains(base - 1));
}

// ── SEQUENCENUMBER_UNKNOWN ────────────────────────────────────────────────────

test "SEQUENCENUMBER_UNKNOWN round-trips correctly" {
    try testing.expectEqual(UNKNOWN, sn_mod.fromWire(sn_mod.toWire(UNKNOWN)));
    try testing.expectEqual(@as(SequenceNumber, -1), UNKNOWN);
}

test "SequenceNumberSet.contains(UNKNOWN) is always false" {
    // Even with all bits set, UNKNOWN (-1) is below any valid base.
    const sns = SequenceNumberSet{
        .base = 1,
        .num_bits = 256,
        .bitmap = [_]u32{0xFFFF_FFFF} ** 8,
    };
    try testing.expect(!sns.contains(UNKNOWN)); // -1 < base=1
}

test "WriterProxy.received.insert(UNKNOWN) is a no-op" {
    var wp = try WriterProxy.init(testing.allocator, makeGuid(1), &.{}, &.{}, true);
    defer wp.deinit(testing.allocator);

    // UNKNOWN = -1 is a negative SN; ReceivedSet rejects it and cumulativeAck stays 0.
    const inserted = try wp.received.insert(testing.allocator, UNKNOWN);
    try testing.expect(!inserted);
    try testing.expectEqual(@as(SequenceNumber, 0), wp.received.cumulativeAck());
}
