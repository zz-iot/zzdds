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

/// An I/O source a readiness backend waits on and services: a socket the
/// transport has set up, with the transport's handler for it
/// (docs/design/concurrency/transport-adapters.md#socket-setup-and-data-path).
pub const Source = struct {
    /// The OS handle to wait on.
    handle: std.posix.socket_t,
    ctx: *anyopaque,
    /// Nonblocking: handles at most `budget` inputs that are ready now and
    /// returns how many it handled, 0 once none is ready. Not called for a
    /// source without `input`.
    service: *const fn (ctx: *anyopaque, budget: u32) u32,
    /// Whether the backend waits on `handle` for input. False for a socket
    /// that is only written: the backend then waits on it only while output
    /// is armed.
    input: bool = true,
    /// Runs once per `armOutput`, from `service`, when `handle` can take
    /// output, or reports an error the next send will see
    /// (docs/design/concurrency/transport-adapters.md#output-submission).
    /// Never runs DDS work: it hands the event to whoever waits for it.
    writable: ?*const fn (ctx: *anyopaque) void = null,
    /// The backend's: output is armed and `writable` has not run since.
    output_armed: bool = false,
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
        /// Readiness backends only (null otherwise): waits on and services
        /// `source` from now on. It stays valid until `unregister` returns.
        register: ?*const fn (ctx: *anyopaque, source: *Source) error{OutOfMemory}!void = null,
        /// Stops waiting on `source`, returning once no `service` of it is
        /// running. From inside a `service` of this backend (a source's
        /// `service` or `writable` closing it) it returns at once, and that
        /// service does not touch `source` again.
        unregister: ?*const fn (ctx: *anyopaque, source: *Source) void = null,
        /// Readiness backends only: runs `source.writable` once, the next
        /// time its handle can take output. `source` is registered and has
        /// `writable`. Callable from any thread; arming an armed source
        /// does nothing.
        arm_output: ?*const fn (ctx: *anyopaque, source: *Source) void = null,
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
    /// Whether the backend waits on I/O sources.
    pub fn hasSources(self: ProgressBackend) bool {
        return self.vtable.register != null;
    }
    pub fn register(self: ProgressBackend, source: *Source) error{ OutOfMemory, NoSources }!void {
        const f = self.vtable.register orelse return error.NoSources;
        return f(self.ctx, source);
    }
    pub fn unregister(self: ProgressBackend, source: *Source) void {
        self.vtable.unregister.?(self.ctx, source);
    }
    pub fn armOutput(self: ProgressBackend, source: *Source) void {
        self.vtable.arm_output.?(self.ctx, source);
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
