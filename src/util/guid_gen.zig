//! GUID prefix generation strategies.
//!
//! Two strategies are available (selected via Config.participant.guid_strategy):
//!
//!   .random      (default) — 12 random bytes from OS entropy.
//!                            Safe, simple, no host information leaked.
//!
//!   .host_based             — StartTime[4] + PID[4] + monotonic-counter[4].
//!                            Deterministic layout useful for Wireshark debugging
//!                            and test fixtures that need stable GUIDs from the
//!                            same process.
//!
//! Both strategies guarantee uniqueness in practice.

const std = @import("std");
const builtin = @import("builtin");
const GuidPrefix = @import("../rtps/guid.zig").GuidPrefix;
const GuidStrategy = @import("../config/schema.zig").GuidStrategy;

/// Generate a GUID prefix using the given strategy.
pub fn generate(strategy: GuidStrategy) GuidPrefix {
    return switch (strategy) {
        .random => generateRandom(),
        .host_based => generateHostBased(),
    };
}

// ── Random strategy ───────────────────────────────────────────────────────────

fn generateRandom() GuidPrefix {
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

// ── Host-based strategy ───────────────────────────────────────────────────────

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
            // clock_gettime(CLOCK_MONOTONIC) is available on Apple platforms.
            var ts: std.c.timespec = undefined;
            _ = std.c.clock_gettime(.MONOTONIC, &ts);
            return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
                @as(u64, @intCast(ts.nsec));
        },
        .windows => {
            // RtlQueryPerformanceCounter returns the QPC tick count — a
            // monotonic, high-resolution counter that increments on every call.
            // Using it as a seed source guarantees distinct seeds even when two
            // generate() calls happen within the same millisecond.
            var counter: std.os.windows.LARGE_INTEGER = undefined;
            _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
            return @bitCast(counter);
        },
        else => {
            // Platform not yet supported: return a non-zero constant so the
            // counter alone still provides uniqueness within the process.
            return 0xdeadbeefcafe0000;
        },
    }
}

/// Platform PID. Returns 0 on unsupported platforms; counter provides
/// uniqueness within a process regardless.
fn currentPid() u32 {
    return switch (builtin.os.tag) {
        .linux => @intCast(std.os.linux.getpid()),
        .macos, .ios, .watchos, .tvos, .freebsd, .openbsd, .netbsd, .dragonfly => @intCast(std.c.getpid()),
        else => 0,
    };
}

fn generateHostBased() GuidPrefix {
    var prefix: GuidPrefix = undefined;

    // [0..4]: lower 32 bits of process start monotonic timestamp.
    std.mem.writeInt(u32, prefix.bytes[0..4], @truncate(startNs()), .little);

    // [4..8]: OS process ID.
    std.mem.writeInt(u32, prefix.bytes[4..8], currentPid(), .little);

    // [8..12]: monotonic counter — unique even when start_time + PID collide.
    std.mem.writeInt(u32, prefix.bytes[8..12], nextCounter(), .little);

    return prefix;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "random strategy produces non-zero prefix" {
    const p = generate(.random);
    var all_zero = true;
    for (p.bytes) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}

test "random strategy produces unique prefixes" {
    const a = generate(.random);
    const b = generate(.random);
    try std.testing.expect(!std.mem.eql(u8, &a.bytes, &b.bytes));
}

test "host_based strategy produces non-zero prefix" {
    const p = generate(.host_based);
    var all_zero = true;
    for (p.bytes) |b| if (b != 0) {
        all_zero = false;
        break;
    };
    try std.testing.expect(!all_zero);
}

test "host_based counter increments between calls" {
    const a = generate(.host_based);
    const b = generate(.host_based);
    const ca = std.mem.readInt(u32, a.bytes[8..12], .little);
    const cb = std.mem.readInt(u32, b.bytes[8..12], .little);
    try std.testing.expect(cb > ca);
}

test "host_based PID bytes are consistent within process" {
    const a = generate(.host_based);
    const b = generate(.host_based);
    try std.testing.expectEqual(a.bytes[4..8].*, b.bytes[4..8].*);
}

test "host_based start-timestamp bytes are consistent within process" {
    const a = generate(.host_based);
    const b = generate(.host_based);
    try std.testing.expectEqual(a.bytes[0..4].*, b.bytes[0..4].*);
}
