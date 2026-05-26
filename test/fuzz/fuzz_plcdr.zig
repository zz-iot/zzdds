//! Fuzz target: SPDP PL-CDR/PID deserializer.
//!
//! Invariant: decodeSpdpParticipant() must never panic or access out-of-bounds
//! memory for any input. Malformed payloads must return an error or produce a
//! valid (possibly default-valued) KnownParticipant — never a crash.
//!
//! Uses a FixedBufferAllocator so each fuzzOne() call is stack-contained with
//! zero heap overhead. Allocations beyond the buffer return OutOfMemory, which
//! the decoder propagates as an error — a valid outcome.
//!
//! To run with libFuzzer (after building with clang -fsanitize=fuzzer,address):
//!   ./fuzz_plcdr test/fuzz/corpus/plcdr/

const std = @import("std");
const zzdds = @import("zzdds");

const spdp_mod = zzdds.spdp_discovery;
const rtps = zzdds.rtps;
const GuidPrefix = rtps.GuidPrefix;

const FAKE_PREFIX = GuidPrefix{ .bytes = [_]u8{0xAA} ** 12 };

pub fn fuzzOne(data: []const u8) void {
    var buf: [8192]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();
    var kp = spdp_mod.decodeSpdpParticipant(alloc, FAKE_PREFIX, 0, data) catch return;
    kp.deinit();
}

export fn LLVMFuzzerTestOneInput(data: [*]const u8, size: usize) i32 {
    fuzzOne(data[0..size]);
    return 0;
}

// ── Payload building helpers ──────────────────────────────────────────────────

// PL_CDR_LE encapsulation header
const LE_ENCAP = [_]u8{ 0x00, 0x03, 0x00, 0x00 };
// PL_CDR_BE encapsulation header
const BE_ENCAP = [_]u8{ 0x00, 0x02, 0x00, 0x00 };
// PID_SENTINEL
const SENTINEL = [_]u8{ 0x01, 0x00, 0x00, 0x00 };

// PID_PARTICIPANT_GUID (0x0050), length=16, with FAKE_PREFIX + participant entity_id
const PID_GUID = [_]u8{
    0x50, 0x00, 0x10, 0x00, // PID + length
} ++ [_]u8{0xAA} ** 12 ++ [_]u8{ 0x00, 0x00, 0x01, 0xC1 };

// PID_PARTICIPANT_LEASE_DURATION (0x0002), length=8, 10 seconds
const PID_LEASE_10S = [_]u8{
    0x02, 0x00, 0x08, 0x00, // PID + length
    0x0A, 0x00, 0x00, 0x00, // seconds=10 LE
    0x00, 0x00, 0x00, 0x00, // fraction=0
};

// PID_BUILTIN_ENDPOINT_SET (0x0058), length=4
const PID_BES = [_]u8{
    0x58, 0x00, 0x04, 0x00,
    0x3F, 0x0C, 0x00, 0x00, // SPDP+SEDP endpoint bits
};

// ── Corpus regression tests ───────────────────────────────────────────────────

test "empty payload returns TooShort" {
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const err = spdp_mod.decodeSpdpParticipant(fba.allocator(), FAKE_PREFIX, 0, &.{});
    try std.testing.expectError(error.TooShort, err);
}

test "encap header + sentinel only: succeeds with defaults" {
    const payload = LE_ENCAP ++ SENTINEL;
    var buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var kp = try spdp_mod.decodeSpdpParticipant(fba.allocator(), FAKE_PREFIX, 0, &payload);
    kp.deinit();
    // Default lease = 10_000 ms
    try std.testing.expectEqual(@as(u32, 10_000), kp.data.lease_duration_ms);
}

test "minimal valid SPDP payload: GUID + lease + sentinel" {
    const payload = LE_ENCAP ++ PID_GUID ++ PID_LEASE_10S ++ SENTINEL;
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var kp = try spdp_mod.decodeSpdpParticipant(fba.allocator(), FAKE_PREFIX, 0, &payload);
    kp.deinit();
    try std.testing.expectEqual(@as(u32, 10_000), kp.data.lease_duration_ms);
}

test "full SPDP payload: GUID + lease + BES + sentinel" {
    const payload = LE_ENCAP ++ PID_GUID ++ PID_LEASE_10S ++ PID_BES ++ SENTINEL;
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var kp = try spdp_mod.decodeSpdpParticipant(fba.allocator(), FAKE_PREFIX, 0, &payload);
    kp.deinit();
}

test "big-endian encapsulation: parsed without crash" {
    const payload = BE_ENCAP ++ SENTINEL;
    fuzzOne(&payload);
}

test "PID length exceeds remaining bytes: loop breaks safely" {
    // PID 0x0050, length=0xFFFF — far beyond the buffer
    const payload = LE_ENCAP ++ [_]u8{ 0x50, 0x00, 0xFF, 0xFF } ++ SENTINEL;
    fuzzOne(&payload);
}

test "PID length = 0: handled without crash" {
    const payload = LE_ENCAP ++ [_]u8{ 0x50, 0x00, 0x00, 0x00 } ++ SENTINEL;
    fuzzOne(&payload);
}

test "truncated after PID header: handled" {
    // Only 2 bytes after encap — not enough for a full PID header
    const payload = LE_ENCAP ++ [_]u8{ 0x50, 0x00 };
    fuzzOne(&payload);
}

test "unknown PID: ignored without crash" {
    // PID 0xFEFE (unknown), length=4, 4 bytes of data
    const payload = LE_ENCAP ++ [_]u8{ 0xFE, 0xFE, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00 } ++ SENTINEL;
    fuzzOne(&payload);
}

test "repeated known PIDs: last value wins, no crash" {
    const payload = LE_ENCAP ++ PID_LEASE_10S ++ PID_LEASE_10S ++ SENTINEL;
    fuzzOne(&payload);
}

test "all-zeros payload: no crash" {
    fuzzOne(&([_]u8{0} ** 64));
}

test "all-ones payload: no crash" {
    fuzzOne(&([_]u8{0xFF} ** 64));
}
