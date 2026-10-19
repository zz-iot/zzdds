//! The progress backend a runtime waits through
//! (docs/design/concurrency/transport-adapters.md#progress-backend).
//!
//! The backend supplies the runtime's wait, so the runtime never assumes that
//! waiting means a futex: a backend with sockets waits on them too.

const std = @import("std");
const Clock = @import("../util/time.zig").Clock;
const ManualClock = @import("../util/time.zig").ManualClock;

pub const ServiceResult = struct {
    /// I/O events and completions turned into runtime work.
    serviced: u32 = 0,
    /// More are ready than the budget allowed.
    more: bool = false,
};

pub const ProgressBackend = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Ends a current or the next wait of one waiter. Callable from any
        /// thread; never runs DDS work.
        wake: *const fn (ctx: *anyopaque) void,
        /// Ends current and next waits of every waiter.
        wake_all: *const fn (ctx: *anyopaque) void,
        /// Returns the token `wait` compares against. The caller rechecks for
        /// work after taking it, so a wake after this call is never lost.
        prepare_wait: *const fn (ctx: *anyopaque) u32,
        /// Blocks until a wake newer than `token`, ready I/O, or `deadline_ns`
        /// (the runtime clock's domain; null waits without a deadline). May
        /// return early; the caller rechecks.
        wait: *const fn (ctx: *anyopaque, deadline_ns: ?i64, token: u32) void,
        /// Nonblocking: turns ready I/O into runtime work, at most `budget`.
        service: *const fn (ctx: *anyopaque, budget: u32) ServiceResult,
    };

    pub fn wake(self: ProgressBackend) void {
        self.vtable.wake(self.ctx);
    }
    pub fn wakeAll(self: ProgressBackend) void {
        self.vtable.wake_all(self.ctx);
    }
    pub fn prepareWait(self: ProgressBackend) u32 {
        return self.vtable.prepare_wait(self.ctx);
    }
    pub fn wait(self: ProgressBackend, deadline_ns: ?i64, token: u32) void {
        self.vtable.wait(self.ctx, deadline_ns, token);
    }
    pub fn service(self: ProgressBackend, budget: u32) ServiceResult {
        return self.vtable.service(self.ctx, budget);
    }
};

/// A backend for deterministic single-threaded tests. Waiting with a
/// deadline advances its clock to the deadline instead of sleeping, so timers
/// fire through an ordinary `drive` without wall-clock time passing.
pub const ScriptedBackend = struct {
    clock_state: ManualClock,
    seq: u32 = 0,
    /// Waits that reached their deadline by advancing the clock.
    timed_waits: u32 = 0,
    /// Waits with no deadline and no pending wake. A real backend would block
    /// forever; this one returns so a test can assert it did not happen.
    unbounded_waits: u32 = 0,

    pub fn init(start_ns: i64) ScriptedBackend {
        return .{ .clock_state = ManualClock.init(start_ns) };
    }

    pub fn clock(self: *ScriptedBackend) Clock {
        return self.clock_state.clock();
    }

    pub fn backend(self: *ScriptedBackend) ProgressBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    const vtable: ProgressBackend.Vtable = .{
        .wake = vtWake,
        .wake_all = vtWake,
        .prepare_wait = vtPrepareWait,
        .wait = vtWait,
        .service = vtService,
    };

    fn of(ctx: *anyopaque) *ScriptedBackend {
        return @ptrCast(@alignCast(ctx));
    }
    fn vtWake(ctx: *anyopaque) void {
        of(ctx).seq +%= 1;
    }
    fn vtPrepareWait(ctx: *anyopaque) u32 {
        return of(ctx).seq;
    }
    fn vtWait(ctx: *anyopaque, deadline_ns: ?i64, token: u32) void {
        const self = of(ctx);
        if (self.seq != token) return;
        const deadline = deadline_ns orelse {
            self.unbounded_waits += 1;
            return;
        };
        const now = self.clock_state.ns.load(.acquire);
        if (deadline > now) self.clock_state.advance(deadline - now);
        self.timed_waits += 1;
    }
    fn vtService(_: *anyopaque, _: u32) ServiceResult {
        return .{};
    }
};
