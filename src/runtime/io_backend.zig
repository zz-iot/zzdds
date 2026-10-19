//! A progress backend for hosted platforms with no I/O sources registered,
//! built on a `std.Io` futex and its monotonic ("awake") clock
//! (docs/design/concurrency/transport-adapters.md#adapter-model).
//!
//! Hosted-platform adapter only: the runtime core does not import it. The
//! `Io` must be callable from every thread that wakes or waits, which holds
//! for `std.Io.Threaded` but not for an Evented `Io`
//! (docs/design/concurrency/transport-adapters.md#adopting-other-std-io-backends).

const std = @import("std");
const Clock = @import("../util/time.zig").Clock;
const backend_mod = @import("backend.zig");
const ProgressBackend = backend_mod.ProgressBackend;
const ServiceResult = backend_mod.ServiceResult;

pub const IoBackend = struct {
    io: std.Io,
    /// Wake sequence: every wake advances it, and waiting means waiting for it
    /// to differ from the token taken by `prepare_wait`.
    seq: std.atomic.Value(u32) = .init(0),
    /// Threads inside `wait`, for diagnostics and tests.
    waiters: std.atomic.Value(u32) = .init(0),

    pub fn init(io: std.Io) IoBackend {
        return .{ .io = io };
    }

    pub fn backend(self: *IoBackend) ProgressBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// The runtime scheduling clock this backend's deadlines are in. A runtime
    /// using this backend must use this clock.
    pub fn clock(self: *IoBackend) Clock {
        return .{ .ctx = self, .vtable = &clock_vtable };
    }

    const vtable: ProgressBackend.Vtable = .{
        .wake = vtWake,
        .wake_all = vtWakeAll,
        .prepare_wait = vtPrepareWait,
        .wait = vtWait,
        .service = vtService,
    };

    const clock_vtable: Clock.Vtable = .{ .now_ns = vtNow, .sleep_ns = vtSleep };

    fn of(ctx: *anyopaque) *IoBackend {
        return @ptrCast(@alignCast(ctx));
    }

    fn vtWake(ctx: *anyopaque) void {
        const self = of(ctx);
        _ = self.seq.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.seq.raw, 1);
    }

    fn vtWakeAll(ctx: *anyopaque) void {
        const self = of(ctx);
        _ = self.seq.fetchAdd(1, .release);
        self.io.futexWake(u32, &self.seq.raw, std.math.maxInt(u32));
    }

    fn vtPrepareWait(ctx: *anyopaque) u32 {
        return of(ctx).seq.load(.acquire);
    }

    fn vtWait(ctx: *anyopaque, deadline_ns: ?i64, token: u32) void {
        const self = of(ctx);
        if (self.seq.load(.acquire) != token) return;
        const timeout: std.Io.Timeout = if (deadline_ns) |d|
            .{ .deadline = .{ .raw = .{ .nanoseconds = d }, .clock = .awake } }
        else
            .none;
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        // Cancelation only ends the wait early, which callers already allow.
        self.io.futexWaitTimeout(u32, &self.seq.raw, token, timeout) catch {};
    }

    fn vtService(_: *anyopaque, _: u32) ServiceResult {
        return .{};
    }

    fn vtNow(ctx: *anyopaque) i64 {
        return @intCast(std.Io.Clock.awake.now(of(ctx).io).nanoseconds);
    }

    fn vtSleep(ctx: *anyopaque, duration_ns: i64) void {
        if (duration_ns <= 0) return;
        std.Io.sleep(of(ctx).io, .{ .nanoseconds = duration_ns }, .awake) catch {};
    }
};
