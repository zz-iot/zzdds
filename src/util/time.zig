//! Time and duration types.
//!
//! Three representations are used:
//!
//!   Time_t / Duration_t  — DDS DCPS §2.2.1 (sec: i32, nanosec: u32).
//!                          Used in QoS policies and the DCPS API.
//!
//!   RtpsTimestamp        — RTPS 2.5 §9.3.2 (seconds: u32, fraction: u32).
//!                          Fraction is 1/2^32 seconds (not nanoseconds!).
//!                          Used in INFO_TS submessages.
//!
//!   RtpsDuration         — RTPS 2.5 §9.3.2 (seconds: i32, fraction: u32).
//!                          Used by RTPS ParameterList Duration_t values.

const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("mutex.zig").Mutex;
const Condvar = @import("condvar.zig").Condvar;

// ── DCPS time types ───────────────────────────────────────────────────────────

/// DDS Duration_t (DDS v1.4 §2.2.1).
pub const Duration = extern struct {
    sec: i32,
    nanosec: u32,

    pub const infinite: Duration = .{ .sec = 0x7fff_ffff, .nanosec = 0xffff_ffff };
    pub const zero: Duration = .{ .sec = 0, .nanosec = 0 };

    /// True if this duration represents DDS "infinity".
    pub fn isInfinite(self: Duration) bool {
        return self.sec == infinite.sec and self.nanosec == infinite.nanosec;
    }

    /// Convert to nanoseconds. Returns null for infinite.
    pub fn toNs(self: Duration) ?i64 {
        if (self.isInfinite()) return null;
        return @as(i64, self.sec) * std.time.ns_per_s + @as(i64, self.nanosec);
    }

    /// Compare: returns .lt, .eq, or .gt. Infinite is always the greatest.
    pub fn order(a: Duration, b: Duration) std.math.Order {
        if (a.isInfinite() and b.isInfinite()) return .eq;
        if (a.isInfinite()) return .gt;
        if (b.isInfinite()) return .lt;
        const ans = std.math.order(a.sec, b.sec);
        if (ans != .eq) return ans;
        return std.math.order(a.nanosec, b.nanosec);
    }
};

/// DDS Time_t (DDS v1.4 §2.2.1).
pub const Time = extern struct {
    sec: i32,
    nanosec: u32,

    pub const invalid: Time = .{ .sec = -1, .nanosec = 0xffff_ffff };

    pub fn isInvalid(self: Time) bool {
        return self.sec == invalid.sec and self.nanosec == invalid.nanosec;
    }

    /// Current wall-clock time (CLOCK_REALTIME).
    pub fn now() Time {
        if (comptime builtin.os.tag == .windows) {
            const ticks = WinTime.RtlGetSystemTimePrecise() - WinTime.epoch_offset;
            return .{
                .sec = @intCast(@divTrunc(ticks, 10_000_000)),
                .nanosec = @intCast(@mod(ticks, 10_000_000) * 100),
            };
        }
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &ts);
        return .{
            .sec = @intCast(ts.sec),
            .nanosec = @intCast(ts.nsec),
        };
    }

    pub fn toNs(self: Time) i64 {
        return @as(i64, self.sec) * std.time.ns_per_s + @as(i64, self.nanosec);
    }

    /// Difference: returns (self - other) as a Duration.
    /// Negative result is clamped to Duration.zero.
    pub fn sub(self: Time, other: Time) Duration {
        const diff_ns = self.toNs() - other.toNs();
        if (diff_ns <= 0) return Duration.zero;
        return .{
            .sec = @intCast(@divTrunc(diff_ns, std.time.ns_per_s)),
            .nanosec = @intCast(@mod(diff_ns, std.time.ns_per_s)),
        };
    }
};

// ── RTPS timestamp ────────────────────────────────────────────────────────────

/// RTPS Timestamp (RTPS §9.3.2 Table 9.12).
/// seconds: seconds since epoch (Unix epoch in practice).
/// fraction: sub-second time, units of 1/2^32 seconds (NOT nanoseconds).
pub const RtpsTimestamp = extern struct {
    seconds: u32,
    fraction: u32,

    /// RTPS §9.3.2: TIME_ZERO
    pub const zero: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
    /// RTPS §9.3.2: TIME_INVALID
    pub const invalid: RtpsTimestamp = .{ .seconds = 0xffff_ffff, .fraction = 0xffff_ffff };
    /// RTPS §9.3.2: TIME_INFINITE
    pub const infinite: RtpsTimestamp = .{ .seconds = 0xffff_ffff, .fraction = 0xffff_fffe };

    pub fn isInvalid(self: RtpsTimestamp) bool {
        return self.seconds == invalid.seconds and self.fraction == invalid.fraction;
    }

    /// Convert a DCPS Time to an RTPS Timestamp.
    pub fn fromTime(t: Time) RtpsTimestamp {
        // fraction = nanosec * 2^32 / 1e9 ≈ nanosec * 4.295
        const frac: u64 = @as(u64, t.nanosec) * 0x1_0000_0000 / std.time.ns_per_s;
        return .{
            .seconds = @intCast(t.sec),
            .fraction = @intCast(frac),
        };
    }

    /// Convert an RTPS Timestamp to a DCPS Time.
    pub fn toTime(self: RtpsTimestamp) Time {
        const ns: u32 = @intCast(@as(u64, self.fraction) * std.time.ns_per_s / 0x1_0000_0000);
        return .{
            .sec = @intCast(self.seconds),
            .nanosec = ns,
        };
    }

    /// Current wall-clock time as an RTPS Timestamp.
    pub fn now() RtpsTimestamp {
        return fromTime(Time.now());
    }
};

/// RTPS Duration_t (RTPS §9.3.2).
/// seconds: signed seconds.
/// fraction: sub-second duration, units of 1/2^32 seconds (NOT nanoseconds).
pub const RtpsDuration = extern struct {
    seconds: i32,
    fraction: u32,

    /// RTPS §9.3.2: DURATION_ZERO
    pub const zero: RtpsDuration = .{ .seconds = 0, .fraction = 0 };
    /// RTPS §9.3.2: DURATION_INFINITE
    pub const infinite: RtpsDuration = .{ .seconds = 0x7fff_ffff, .fraction = 0xffff_ffff };

    pub fn isInfinite(self: RtpsDuration) bool {
        return self.seconds == infinite.seconds and self.fraction == infinite.fraction;
    }

    /// Convert a DDS/DCPS Duration to an RTPS wire Duration.
    pub fn fromDuration(d: Duration) RtpsDuration {
        if (d.isInfinite()) return infinite;
        const frac: u64 = @as(u64, d.nanosec) * 0x1_0000_0000 / std.time.ns_per_s;
        return .{
            .seconds = d.sec,
            .fraction = @intCast(frac),
        };
    }

    /// Convert an RTPS wire Duration to a DDS/DCPS Duration.
    pub fn toDuration(self: RtpsDuration) Duration {
        if (self.isInfinite()) return Duration.infinite;
        var sec = self.seconds;
        var ns: u32 = @intCast((@as(u64, self.fraction) * std.time.ns_per_s + 0x8000_0000) / 0x1_0000_0000);
        if (ns == std.time.ns_per_s) {
            sec += 1;
            ns = 0;
        }
        return .{
            .sec = sec,
            .nanosec = ns,
        };
    }

    /// Append the RTPS wire encoding (seconds LE i32, fraction LE u32) to buf.
    pub fn appendLE(self: RtpsDuration, alloc: std.mem.Allocator, buf: *std.ArrayList(u8)) !void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(i32, &tmp, self.seconds, .little);
        try buf.appendSlice(alloc, &tmp);
        std.mem.writeInt(u32, &tmp, self.fraction, .little);
        try buf.appendSlice(alloc, &tmp);
    }
};

// ── Monotonic / boottime helpers ──────────────────────────────────────────────

/// Nanoseconds from an arbitrary monotonic epoch (CLOCK_MONOTONIC on POSIX,
/// QueryPerformanceCounter on Windows). Suitable only for measuring elapsed
/// intervals — the epoch is unspecified and not comparable across processes.
pub fn monotonicNs() i64 {
    if (comptime builtin.os.tag == .windows) {
        var freq: i64 = undefined;
        _ = WinTime.QueryPerformanceFrequency(&freq);
        var count: i64 = undefined;
        _ = WinTime.QueryPerformanceCounter(&count);
        // Split to avoid overflow: count can be large; multiply before divide.
        const sec_count = @divTrunc(count, freq);
        const rem_count = @mod(count, freq);
        return sec_count * std.time.ns_per_s + @divTrunc(rem_count * std.time.ns_per_s, freq);
    }
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
}

/// Like monotonicNs() but includes time the system spent suspended
/// (CLOCK_BOOTTIME on Linux; falls back to CLOCK_MONOTONIC elsewhere).
/// Use this for liveliness timers on systems that may suspend/resume.
pub fn boottimeNs() i64 {
    if (comptime builtin.os.tag == .linux) {
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.BOOTTIME, &ts);
        return @as(i64, ts.sec) * std.time.ns_per_s + @as(i64, ts.nsec);
    }
    return monotonicNs();
}

// ── Clock interface ───────────────────────────────────────────────────────────

/// Pluggable clock interface for internal interval timers and wire timestamps.
///
/// Two clock slots live in participant config:
///   wire_clock  — wall time (CLOCK_REALTIME) for RtpsTimestamp source stamps.
///   timer_clock — monotonic time (CLOCK_MONOTONIC) for deadline/liveliness
///                 timers. RTOS users substitute a tick-counter-backed Clock.
///
/// Tests substitute ManualClock for deterministic, sleep-free time control.
pub const Clock = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        now_ns: *const fn (ctx: *anyopaque) i64,
        /// Block for at least duration_ns nanoseconds. Implementations may
        /// return early (e.g. when interrupted); callers must recheck condition.
        sleep_ns: *const fn (ctx: *anyopaque, duration_ns: i64) void,
    };

    pub fn nowNs(self: Clock) i64 {
        return self.vtable.now_ns(self.ctx);
    }

    pub fn sleepNs(self: Clock, duration_ns: i64) void {
        self.vtable.sleep_ns(self.ctx, duration_ns);
    }
};

/// Clock backed by CLOCK_REALTIME (nanosecond precision). Use as wire_clock.
pub fn realtimeClock() Clock {
    const S = struct {
        var sentinel: u8 = 0;
        const vt: Clock.Vtable = .{ .now_ns = vtNow, .sleep_ns = vtSleep };
        fn vtNow(_: *anyopaque) i64 {
            return nanoTimestamp();
        }
        fn vtSleep(_: *anyopaque, duration_ns: i64) void {
            if (duration_ns > 0) sleepNs(@intCast(duration_ns));
        }
    };
    return .{ .ctx = &S.sentinel, .vtable = &S.vt };
}

/// Clock backed by CLOCK_MONOTONIC (QPC on Windows). Use as timer_clock.
/// Does not go backwards; unaffected by NTP steps or leap seconds.
pub fn monotonicClock() Clock {
    const S = struct {
        var sentinel: u8 = 0;
        const vt: Clock.Vtable = .{ .now_ns = vtNow, .sleep_ns = vtSleep };
        fn vtNow(_: *anyopaque) i64 {
            return monotonicNs();
        }
        fn vtSleep(_: *anyopaque, duration_ns: i64) void {
            if (duration_ns > 0) sleepNs(@intCast(duration_ns));
        }
    };
    return .{ .ctx = &S.sentinel, .vtable = &S.vt };
}

/// Clock backed by CLOCK_BOOTTIME on Linux (falls back to CLOCK_MONOTONIC
/// elsewhere). Use as timer_clock on systems that may suspend/resume and where
/// liveliness leases must expire during the suspended period.
pub fn boottimeClock() Clock {
    const S = struct {
        var sentinel: u8 = 0;
        const vt: Clock.Vtable = .{ .now_ns = vtNow, .sleep_ns = vtSleep };
        fn vtNow(_: *anyopaque) i64 {
            return boottimeNs();
        }
        fn vtSleep(_: *anyopaque, duration_ns: i64) void {
            if (duration_ns > 0) sleepNs(@intCast(duration_ns));
        }
    };
    return .{ .ctx = &S.sentinel, .vtable = &S.vt };
}

/// Manually-advanced clock for deterministic tests. Concurrent-safe.
///
/// `sleepNs` blocks until the logical clock has advanced past the sleep
/// deadline, waking immediately when `advance()` or `set()` is called.
/// It also wakes on a 10 ms real-time timeout so that timer threads shut
/// down promptly when the owning component sets its shutdown flag.
pub const ManualClock = struct {
    ns: std.atomic.Value(i64),
    mu: Mutex = .{},
    cv: Condvar = .{},

    const vt: Clock.Vtable = .{ .now_ns = ManualClock.nowNs, .sleep_ns = ManualClock.sleepNs };

    pub fn init(start_ns: i64) ManualClock {
        return .{ .ns = std.atomic.Value(i64).init(start_ns) };
    }

    /// Advance by delta_ns nanoseconds and wake any sleeping callers.
    pub fn advance(self: *ManualClock, delta_ns: i64) void {
        _ = self.ns.fetchAdd(delta_ns, .monotonic);
        self.cv.broadcast();
    }

    /// Set to an absolute nanosecond value and wake any sleeping callers.
    pub fn set(self: *ManualClock, ns_val: i64) void {
        self.ns.store(ns_val, .monotonic);
        self.cv.broadcast();
    }

    pub fn clock(self: *ManualClock) Clock {
        return .{ .ctx = self, .vtable = &vt };
    }

    fn nowNs(ctx: *anyopaque) i64 {
        const self: *ManualClock = @ptrCast(@alignCast(ctx));
        return self.ns.load(.monotonic);
    }

    fn sleepNs(ctx: *anyopaque, duration_ns: i64) void {
        const self: *ManualClock = @ptrCast(@alignCast(ctx));
        const target = self.ns.load(.monotonic) + duration_ns;
        self.mu.lock();
        defer self.mu.unlock();
        // Wake on advance()/set() or on a 10 ms real-time timeout so that
        // owning threads (e.g. SPDP timer) can check their shutdown flag and
        // exit promptly without the test having to advance the clock.
        while (self.ns.load(.monotonic) < target) {
            self.cv.timedWaitNs(&self.mu, 10 * std.time.ns_per_ms) catch break;
        }
    }
};

// ── Windows time helpers ──────────────────────────────────────────────────────

// Declared inside a comptime-conditional struct so they are only compiled in
// (and linked) when targeting Windows. On other platforms the struct is empty.
const WinTime = if (builtin.os.tag == .windows) struct {
    // Returns 100-ns intervals since 1601-01-01 (Windows FILETIME epoch).
    extern "ntdll" fn RtlGetSystemTimePrecise() callconv(.winapi) i64;
    // Negative interval = relative sleep in 100-ns units.
    extern "ntdll" fn NtDelayExecution(Alertable: u8, DelayInterval: *i64) callconv(.winapi) u32;
    // Monotonic performance counter and its frequency (ticks/second).
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) i32;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) i32;

    const epoch_offset: i64 = 116_444_736_000_000_000; // 100-ns ticks from 1601 to Unix epoch
} else struct {};

// ── Platform helpers ──────────────────────────────────────────────────────────

/// Current wall-clock time in nanoseconds (i64, like the old std.time.nanoTimestamp).
pub fn nanoTimestamp() i64 {
    return Time.now().toNs();
}

/// Current wall-clock time in milliseconds (i64, like the old std.time.milliTimestamp).
pub fn milliTimestamp() i64 {
    const t = Time.now();
    return @as(i64, t.sec) * 1000 + @divTrunc(@as(i64, t.nanosec), 1_000_000);
}

/// Blocking sleep for `ns` nanoseconds (replaces std.Thread.sleep / std.time.sleep).
pub fn sleepNs(ns: u64) void {
    if (comptime builtin.os.tag == .windows) {
        // NtDelayExecution uses negative 100-ns intervals for relative delay.
        var interval: i64 = -@as(i64, @intCast(ns / 100));
        _ = WinTime.NtDelayExecution(0, &interval);
        return;
    }
    const ts = std.c.timespec{
        .sec = @intCast(ns / @as(u64, std.time.ns_per_s)),
        .nsec = @intCast(ns % @as(u64, std.time.ns_per_s)),
    };
    _ = std.c.nanosleep(&ts, null);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "Duration.infinite is infinite" {
    try std.testing.expect(Duration.infinite.isInfinite());
}

test "Duration.zero is not infinite" {
    try std.testing.expect(!Duration.zero.isInfinite());
}

test "Duration.toNs zero" {
    try std.testing.expectEqual(@as(?i64, 0), Duration.zero.toNs());
}

test "Duration.toNs 1.5 seconds" {
    const d = Duration{ .sec = 1, .nanosec = 500_000_000 };
    try std.testing.expectEqual(@as(?i64, 1_500_000_000), d.toNs());
}

test "Duration.toNs infinite returns null" {
    try std.testing.expectEqual(@as(?i64, null), Duration.infinite.toNs());
}

test "Duration order" {
    const a = Duration{ .sec = 1, .nanosec = 0 };
    const b = Duration{ .sec = 2, .nanosec = 0 };
    try std.testing.expectEqual(std.math.Order.lt, a.order(b));
    try std.testing.expectEqual(std.math.Order.gt, Duration.infinite.order(b));
    try std.testing.expectEqual(std.math.Order.eq, Duration.infinite.order(Duration.infinite));
}

test "RtpsTimestamp size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(RtpsTimestamp));
}

test "RtpsTimestamp.fromTime round-trip approximate" {
    const t = Time{ .sec = 1_700_000_000, .nanosec = 500_000_000 };
    const rt = RtpsTimestamp.fromTime(t);
    const t2 = rt.toTime();
    try std.testing.expectEqual(t.sec, t2.sec);
    // Fraction conversion loses < 1ns; accept up to 1ns error.
    const diff: i64 = @as(i64, t.nanosec) - @as(i64, t2.nanosec);
    try std.testing.expect(diff >= -1 and diff <= 1);
}

test "RtpsDuration size is 8 bytes" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(RtpsDuration));
}

test "RtpsDuration infinite uses RTPS max fraction" {
    const rt = RtpsDuration.fromDuration(Duration.infinite);
    try std.testing.expectEqual(@as(i32, 0x7fff_ffff), rt.seconds);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), rt.fraction);
    try std.testing.expect(rt.toDuration().isInfinite());
}

test "RtpsDuration fromDuration round-trip approximate" {
    const d = Duration{ .sec = 3, .nanosec = 500_000_000 };
    const rt = RtpsDuration.fromDuration(d);
    const d2 = rt.toDuration();
    try std.testing.expectEqual(d.sec, d2.sec);
    const diff: i64 = @as(i64, d.nanosec) - @as(i64, d2.nanosec);
    try std.testing.expect(diff >= -1 and diff <= 1);
}

test "Time.sub positive" {
    const a = Time{ .sec = 10, .nanosec = 0 };
    const b = Time{ .sec = 8, .nanosec = 500_000_000 };
    const d = a.sub(b);
    try std.testing.expectEqual(@as(i32, 1), d.sec);
    try std.testing.expectEqual(@as(u32, 500_000_000), d.nanosec);
}

test "Time.sub negative clamped to zero" {
    const a = Time{ .sec = 1, .nanosec = 0 };
    const b = Time{ .sec = 2, .nanosec = 0 };
    try std.testing.expectEqual(Duration.zero, a.sub(b));
}

test "ManualClock: init and nowNs" {
    var c = ManualClock.init(1_000);
    try std.testing.expectEqual(@as(i64, 1_000), c.clock().nowNs());
}

test "ManualClock: advance" {
    var c = ManualClock.init(0);
    c.advance(500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i64, 500 * std.time.ns_per_ms), c.clock().nowNs());
}

test "ManualClock: set" {
    var c = ManualClock.init(0);
    c.set(9_999 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i64, 9_999 * std.time.ns_per_ms), c.clock().nowNs());
}
