//! GUID prefix generation strategies.
//!
//! Three strategies are available (selected via Config.participant.guid_strategy):
//!
//!   .spec_random  (default) — VendorId[2] + random[10].
//!                             Complies with RTPS §9.3.1.5 (guidPrefix[0..2] = VendorId).
//!                             Wireshark and DDS analyzers can identify the implementation
//!                             from any GUID in a capture. No host information leaked.
//!
//!   .host_based              — VendorId[2] + StartTime[4] + PID[4] + counter[2].
//!                             Deterministic and Wireshark-friendly. Useful for debugging
//!                             and test fixtures that need stable GUIDs from the same
//!                             process. Reveals start time and PID.
//!
//!   .fully_random            — 12 cryptographically-random bytes. No vendor stamp.
//!                             Use when exposing the vendor identity is undesirable.
//!
//! All strategies guarantee uniqueness in practice.

const std = @import("std");
const builtin = @import("builtin");
const GuidPrefix = @import("../rtps/guid.zig").GuidPrefix;
const GuidStrategy = @import("../config/schema.zig").GuidStrategy;
const VENDOR_ID = @import("../rtps/pid.zig").ZZDDS_VENDOR_ID;

/// Generate a GUID prefix using the given strategy.
pub fn generate(strategy: GuidStrategy) GuidPrefix {
    return switch (strategy) {
        .spec_random => generateSpecRandom(),
        .host_based => generateHostBased(),
        .fully_random => generateFullyRandom(),
    };
}

// ── spec_random strategy ──────────────────────────────────────────────────────

fn generateSpecRandom() GuidPrefix {
    var prefix: GuidPrefix = undefined;
    prefix.bytes[0] = VENDOR_ID[0];
    prefix.bytes[1] = VENDOR_ID[1];
    fillOsRandom(prefix.bytes[2..]);
    return prefix;
}

// ── fully_random strategy ─────────────────────────────────────────────────────

fn generateFullyRandom() GuidPrefix {
    var prefix: GuidPrefix = undefined;
    fillOsRandom(&prefix.bytes);
    return prefix;
}

/// Fill `buf` with OS-provided entropy.
/// Falls back to a PRNG seeded from the system clock on unsupported platforms.
fn fillOsRandom(buf: []u8) void {
    if (tryOsEntropy(buf)) {
        return;
    }
    // Fallback: ChaCha seeded from clock + counter. The counter ensures uniqueness
    // even when two calls happen within the same nanosecond (common in tests).
    var seed: [std.Random.DefaultCsprng.secret_seed_length]u8 = undefined;
    const ns = monoNs();
    const ctr = nextCounter();
    for (&seed, 0..) |*b, i| b.* = @truncate(ns >> @intCast((i % 8) * 8));
    seed[0] ^= @truncate(ctr);
    seed[1] ^= @truncate(ctr >> 8);
    seed[2] ^= @truncate(ctr >> 16);
    seed[3] ^= @truncate(ctr >> 24);
    var prng = std.Random.DefaultCsprng.init(seed);
    prng.random().bytes(buf);
}

/// Platform-specific OS entropy. Returns true on success.
fn tryOsEntropy(buf: []u8) bool {
    switch (builtin.os.tag) {
        .linux => {
            const n = std.os.linux.getrandom(buf.ptr, buf.len, 0);
            return n == buf.len;
        },
        .macos, .ios, .watchos, .tvos, .freebsd, .openbsd, .netbsd, .dragonfly => {
            std.c.arc4random_buf(buf.ptr, buf.len);
            return true;
        },
        else => return false,
    }
}

// ── host_based strategy ───────────────────────────────────────────────────────

/// Monotonic counter — shared across all generate() calls in this process.
var counter_state: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

fn nextCounter() u32 {
    return counter_state.fetchAdd(1, .monotonic);
}

/// Process start timestamp captured once at module init via a lazy atomic flag.
var start_ns: u64 = 0;
var start_captured: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn startNs() u64 {
    if (start_captured.load(.acquire)) return start_ns;
    // Capture is idempotent — a race here just means two threads both write the
    // same approximate value; the counter ensures uniqueness regardless.
    start_ns = monoNs();
    start_captured.store(true, .release);
    return start_ns;
}

/// Platform monotonic nanosecond clock.
fn monoNs() u64 {
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
                @as(u64, @intCast(ts.nsec));
        },
        .macos, .ios, .watchos, .tvos => {
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
                @as(u64, @intCast(ts.nsec));
        },
        .windows => {
            var counter: std.os.windows.LARGE_INTEGER = undefined;
            _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
            return @bitCast(counter);
        },
        else => return 0xdeadbeefcafe0000,
    }
}

/// Platform PID. Returns 0 on unsupported platforms.
fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos, .ios, .watchos, .tvos, .freebsd, .openbsd, .netbsd, .dragonfly => @intCast(std.c.getpid()),
        else => 0,
    };
}

fn generateHostBased() GuidPrefix {
    var prefix: GuidPrefix = undefined;

    // [0..2]: VendorId — identifies this implementation per RTPS §9.3.1.5.
    prefix.bytes[0] = VENDOR_ID[0];
    prefix.bytes[1] = VENDOR_ID[1];

    // [2..6]: lower 32 bits of process start monotonic timestamp.
    std.mem.writeInt(u32, prefix.bytes[2..6], @truncate(startNs()), .little);

    // [6..10]: OS process ID.
    std.mem.writeInt(u32, prefix.bytes[6..10], currentPid(), .little);

    // [10..12]: monotonic counter — unique even when start_time + PID collide.
    // 16-bit range (65 535) is more than sufficient for participants per process.
    std.mem.writeInt(u16, prefix.bytes[10..12], @truncate(nextCounter()), .little);

    return prefix;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "spec_random prefix has correct vendor bytes" {
    const p = generate(.spec_random);
    try std.testing.expectEqual(VENDOR_ID[0], p.bytes[0]);
    try std.testing.expectEqual(VENDOR_ID[1], p.bytes[1]);
}

test "spec_random strategy produces unique prefixes" {
    const a = generate(.spec_random);
    const b = generate(.spec_random);
    try std.testing.expect(!std.mem.eql(u8, &a.bytes, &b.bytes));
}

test "fully_random strategy produces non-zero prefix" {
    const p = generate(.fully_random);
    var all_zero = true;
    for (p.bytes) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}

test "fully_random strategy produces unique prefixes" {
    const a = generate(.fully_random);
    const b = generate(.fully_random);
    try std.testing.expect(!std.mem.eql(u8, &a.bytes, &b.bytes));
}

test "host_based prefix has correct vendor bytes" {
    const p = generate(.host_based);
    try std.testing.expectEqual(VENDOR_ID[0], p.bytes[0]);
    try std.testing.expectEqual(VENDOR_ID[1], p.bytes[1]);
}

test "host_based counter increments between calls" {
    const a = generate(.host_based);
    const b = generate(.host_based);
    const ca = std.mem.readInt(u16, a.bytes[10..12], .little);
    const cb = std.mem.readInt(u16, b.bytes[10..12], .little);
    try std.testing.expect(cb > ca);
}

test "host_based PID bytes are consistent within process" {
    const a = generate(.host_based);
    const b = generate(.host_based);
    try std.testing.expectEqual(a.bytes[6..10].*, b.bytes[6..10].*);
}

test "host_based start-timestamp bytes are consistent within process" {
    const a = generate(.host_based);
    const b = generate(.host_based);
    try std.testing.expectEqual(a.bytes[2..6].*, b.bytes[2..6].*);
}
