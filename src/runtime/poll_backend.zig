//! The readiness progress backend for hosted POSIX platforms: waits on the
//! registered I/O sources (for input, and for output where armed) and a wake
//! descriptor with `poll`, and services the ready sources
//! (docs/design/concurrency/transport-adapters.md#progress-backend).
//!
//! One waiter at a time polls. The others wait on a futex, and a poller that
//! stops polling wakes one of them, so the sources are polled whenever anyone
//! waits. `service` runs in one thread at a time; a thread that finds it
//! taken returns, since the one running it handles what is ready.
//!
//! Hosted-platform adapter only: the runtime core does not import it. Like
//! `IoBackend`, its `Io` must be callable from every thread that wakes or
//! waits, which holds for `std.Io.Threaded`.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const Clock = @import("../util/time.zig").Clock;
const Mutex = @import("../util/mutex.zig").Mutex;
const backend_mod = @import("backend.zig");
const ProgressBackend = backend_mod.ProgressBackend;
const ServiceResult = backend_mod.ServiceResult;
const Source = backend_mod.Source;

/// Whether this platform has the backend.
pub const supported = switch (builtin.os.tag) {
    .windows, .wasi, .freestanding => false,
    else => true,
};

/// The backend whose `service` is running on this thread.
threadlocal var servicing: ?*const PollBackend = null;

pub const PollBackend = struct {
    io: std.Io,
    alloc: std.mem.Allocator,
    /// Wake sequence, as in `IoBackend`: waiting means waiting for it to
    /// differ from the token taken by `prepare_wait`.
    seq: std.atomic.Value(u32) = .init(0),
    /// A waiter is polling, so a wake must also signal the wake descriptor.
    polling: std.atomic.Value(bool) = .init(false),
    /// Threads inside `wait`, for diagnostics and tests.
    waiters: std.atomic.Value(u32) = .init(0),
    /// Read end and write end of the wake descriptor (the same eventfd on
    /// Linux, a pipe elsewhere). Both nonblocking.
    wake_rd: posix.fd_t,
    wake_wr: posix.fd_t,

    mu: Mutex = .{},
    // Guarded by `mu`, with each source's `output_armed`.
    sources: std.ArrayListUnmanaged(*Source) = .empty,
    /// Advances on every change to `sources` or to what they wait for.
    version: u64 = 0,

    // The poller's: rebuilt from `sources` when `version` moves.
    wait_fds: std.ArrayListUnmanaged(posix.pollfd) = .empty,
    wait_version: u64 = std.math.maxInt(u64),

    service_mu: Mutex = .{},
    // Guarded by `service_mu`: the sources as of `service_version`, and where
    // the next round starts, so one busy source cannot starve the others.
    service_sources: std.ArrayListUnmanaged(*Source) = .empty,
    service_fds: std.ArrayListUnmanaged(posix.pollfd) = .empty,
    service_version: u64 = std.math.maxInt(u64),
    next: usize = 0,

    test_hooks: if (builtin.is_test) TestHooks else void = if (builtin.is_test) .{} else {},

    /// Seams for deterministic tests of races; absent outside test builds.
    pub const TestHooks = struct {
        /// Runs once in `wait`, on a waiter that found another polling,
        /// before it waits on the futex.
        before_futex_wait: ?*const fn (backend: *PollBackend) void = null,
    };

    pub fn init(alloc: std.mem.Allocator, io: std.Io) error{SystemResources}!PollBackend {
        comptime std.debug.assert(supported);
        var fds: [2]posix.fd_t = undefined;
        if (builtin.os.tag == .linux) {
            const fd = c.eventfd(0, std.os.linux.EFD.CLOEXEC | std.os.linux.EFD.NONBLOCK);
            if (fd < 0) return error.SystemResources;
            fds = .{ fd, fd };
        } else {
            if (c.pipe(&fds) != 0) return error.SystemResources;
            for (fds) |fd| {
                const fl = c.fcntl(fd, c.F.GETFL);
                const nonblock: c_int = @bitCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true })));
                if (fl < 0 or c.fcntl(fd, c.F.SETFL, fl | nonblock) < 0 or
                    c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC)) < 0)
                {
                    _ = c.close(fds[0]);
                    _ = c.close(fds[1]);
                    return error.SystemResources;
                }
            }
        }
        return .{ .io = io, .alloc = alloc, .wake_rd = fds[0], .wake_wr = fds[1] };
    }

    /// Once no thread waits or services, and every source is unregistered.
    pub fn deinit(self: *PollBackend) void {
        std.debug.assert(self.sources.items.len == 0);
        _ = c.close(self.wake_rd);
        if (self.wake_wr != self.wake_rd) _ = c.close(self.wake_wr);
        self.sources.deinit(self.alloc);
        self.wait_fds.deinit(self.alloc);
        self.service_sources.deinit(self.alloc);
        self.service_fds.deinit(self.alloc);
        self.mu.deinit();
        self.service_mu.deinit();
    }

    pub fn backend(self: *PollBackend) ProgressBackend {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// The runtime scheduling clock this backend's deadlines are in. A runtime
    /// using this backend must use this clock.
    pub fn clock(self: *PollBackend) Clock {
        return .{ .ctx = self, .vtable = &clock_vtable };
    }

    /// Sources registered now, for tests.
    pub fn sourceCount(self: *PollBackend) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.sources.items.len;
    }

    const vtable: ProgressBackend.Vtable = .{
        .wake = vtWake,
        .wake_all = vtWakeAll,
        .prepare_wait = vtPrepareWait,
        .wait = vtWait,
        .service = vtService,
        .register = vtRegister,
        .unregister = vtUnregister,
        .arm_output = vtArmOutput,
    };

    const clock_vtable: Clock.Vtable = .{ .now_ns = vtNow, .sleep_ns = vtSleep };

    fn of(ctx: *anyopaque) *PollBackend {
        return @ptrCast(@alignCast(ctx));
    }

    // ── Waking and waiting ───────────────────────────────────────────────────

    fn vtWake(ctx: *anyopaque) void {
        of(ctx).wakeN(1);
    }

    fn vtWakeAll(ctx: *anyopaque) void {
        of(ctx).wakeN(std.math.maxInt(u32));
    }

    /// The sequence advances before `polling` is read, and a poller sets
    /// `polling` before it reads the sequence, so either the poller sees
    /// this wake or this wake signals the descriptor it polls.
    fn wakeN(self: *PollBackend, n: u32) void {
        _ = self.seq.fetchAdd(1, .seq_cst);
        self.io.futexWake(u32, &self.seq.raw, n);
        if (self.polling.load(.seq_cst)) self.signal();
    }

    fn signal(self: *PollBackend) void {
        const one: u64 = 1;
        // A full counter or pipe is already signaled.
        if (builtin.os.tag == .linux) {
            _ = c.write(self.wake_wr, std.mem.asBytes(&one), 8);
        } else {
            _ = c.write(self.wake_wr, std.mem.asBytes(&one), 1);
        }
    }

    fn drain(self: *PollBackend) void {
        var buf: [64]u8 = undefined;
        while (c.read(self.wake_rd, &buf, buf.len) > 0) {}
    }

    fn vtPrepareWait(ctx: *anyopaque) u32 {
        return of(ctx).seq.load(.acquire);
    }

    fn vtWait(ctx: *anyopaque, deadline_ns: ?i64, token: u32) void {
        const self = of(ctx);
        if (self.seq.load(.acquire) != token) return;
        _ = self.waiters.fetchAdd(1, .seq_cst);
        defer _ = self.waiters.fetchSub(1, .seq_cst);
        if (self.polling.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) {
            if (builtin.is_test) {
                if (self.test_hooks.before_futex_wait) |hook| {
                    self.test_hooks.before_futex_wait = null;
                    hook(self);
                }
            }
            const timeout: std.Io.Timeout = if (deadline_ns) |d|
                .{ .deadline = .{ .raw = .{ .nanoseconds = d }, .clock = .awake } }
            else
                .none;
            // Cancelation only ends the wait early, which callers already allow.
            self.io.futexWaitTimeout(u32, &self.seq.raw, token, timeout) catch {};
            return;
        }
        defer {
            self.drain();
            self.polling.store(false, .seq_cst);
            // Another waiter polls in this one's place. The sequence moves
            // so that one about to wait on the futex returns instead; one
            // that starts waiting after `polling` cleared polls itself.
            if (self.waiters.load(.seq_cst) > 1) {
                _ = self.seq.fetchAdd(1, .seq_cst);
                self.io.futexWake(u32, &self.seq.raw, 1);
            }
        }
        if (self.seq.load(.seq_cst) != token) return;
        const timeout = self.timeoutMs(deadline_ns);
        // Without memory for the descriptors, wait a moment and retry.
        const fds = self.waitFds() orelse return vtSleep(self, std.time.ns_per_ms);
        _ = posix.poll(fds, timeout) catch {};
    }

    /// The poller's descriptors: the wake descriptor, then every source.
    fn waitFds(self: *PollBackend) ?[]posix.pollfd {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.wait_version != self.version) {
            self.wait_fds.ensureTotalCapacity(self.alloc, self.sources.items.len + 1) catch return null;
            self.wait_fds.clearRetainingCapacity();
            self.wait_fds.appendAssumeCapacity(.{ .fd = self.wake_rd, .events = posix.POLL.IN, .revents = 0 });
            for (self.sources.items) |s| {
                const events = waitEvents(s);
                if (events != 0) self.wait_fds.appendAssumeCapacity(.{ .fd = s.handle, .events = events, .revents = 0 });
            }
            self.wait_version = self.version;
        }
        return self.wait_fds.items;
    }

    /// What to wait on `s` for, under `mu`. A source waiting for nothing is
    /// left out, since poll would still report its errors.
    fn waitEvents(s: *const Source) i16 {
        var events: i16 = 0;
        if (s.input) events |= posix.POLL.IN;
        if (s.output_armed) events |= posix.POLL.OUT;
        return events;
    }

    /// Milliseconds until `deadline_ns`, rounded up so a wait never ends
    /// before it; -1 without one.
    fn timeoutMs(self: *PollBackend, deadline_ns: ?i64) i32 {
        const d = deadline_ns orelse return -1;
        const left = d - vtNow(self);
        if (left <= 0) return 0;
        const ms = @divFloor(left + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, std.math.maxInt(i32)));
    }

    // ── Sources ──────────────────────────────────────────────────────────────

    fn vtRegister(ctx: *anyopaque, source: *Source) error{OutOfMemory}!void {
        const self = of(ctx);
        {
            self.mu.lock();
            defer self.mu.unlock();
            try self.sources.append(self.alloc, source);
            self.version += 1;
        }
        // A poller already waiting starts polling the new source.
        if (self.polling.load(.seq_cst)) self.signal();
    }

    fn vtArmOutput(ctx: *anyopaque, source: *Source) void {
        const self = of(ctx);
        std.debug.assert(source.writable != null);
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (source.output_armed) return;
            source.output_armed = true;
            self.version += 1;
        }
        // A poller already waiting starts waiting for the output.
        if (self.polling.load(.seq_cst)) self.signal();
    }

    /// Under `service_mu`: whether `s` was armed, disarming it.
    fn disarmOutput(self: *PollBackend, s: *Source) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (!s.output_armed) return false;
        s.output_armed = false;
        self.version += 1;
        return true;
    }

    fn vtUnregister(ctx: *anyopaque, source: *Source) void {
        const self = of(ctx);
        {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.sources.items, 0..) |s, i| {
                if (s == source) {
                    _ = self.sources.orderedRemove(i);
                    self.version += 1;
                    break;
                }
            }
        }
        if (self.polling.load(.seq_cst)) self.signal();
        if (servicing == self) {
            // This thread runs the service: once out of its list, `source`
            // is not touched again, so its owner may free it at once.
            for (self.service_sources.items, self.service_fds.items) |*s, *fd| {
                // A place already taken out holds no source.
                if (fd.fd == -1) continue;
                if (s.* == source) {
                    s.* = undefined;
                    fd.revents = 0;
                    fd.fd = -1;
                }
            }
            return;
        }
        // A service that saw `source` began before the removal: wait for it.
        // One that begins later rebuilds its list without it.
        self.service_mu.lock();
        self.service_mu.unlock();
    }

    // ── Servicing ────────────────────────────────────────────────────────────

    fn vtService(ctx: *anyopaque, budget: u32) ServiceResult {
        const self = of(ctx);
        if (budget == 0) return .{};
        if (!self.service_mu.tryLock()) return .{};
        defer self.service_mu.unlock();
        servicing = self;
        defer servicing = null;

        if (!self.rebuildServiceList()) return .{};
        const fds = self.service_fds.items;
        if (fds.len == 0) return .{};
        const ready = posix.poll(fds, 0) catch return .{};
        if (ready == 0) return .{};

        // Round robin: one input from each ready source per round, starting
        // one source later each call.
        var result: ServiceResult = .{};
        const n = fds.len;
        const start = self.next % n;
        self.next = start + 1;
        var progressed = true;
        while (progressed) {
            progressed = false;
            for (0..n) |k| {
                const i = (start + k) % n;
                if (fds[i].revents == 0) continue;
                if (result.serviced == budget) {
                    result.more = true;
                    return result;
                }
                const s = self.service_sources.items[i];
                // Without input, an error or hangup also ends the wait for
                // output: the next send reports it.
                if (fds[i].revents & posix.POLL.OUT != 0 or !s.input) {
                    fds[i].revents = if (s.input) fds[i].revents & ~@as(i16, posix.POLL.OUT) else 0;
                    if (self.disarmOutput(s)) s.writable.?(s.ctx);
                    result.serviced += 1;
                    progressed = true;
                    continue;
                }
                if (fds[i].revents & posix.POLL.NVAL != 0 or s.service(s.ctx, 1) == 0) {
                    fds[i].revents = 0;
                    continue;
                }
                result.serviced += 1;
                progressed = true;
            }
        }
        return result;
    }

    /// Under `service_mu`: the service list as of the current sources. False
    /// when it could not be built.
    fn rebuildServiceList(self: *PollBackend) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.service_version == self.version) return true;
        const n = self.sources.items.len;
        self.service_sources.ensureTotalCapacity(self.alloc, n) catch return false;
        self.service_fds.ensureTotalCapacity(self.alloc, n) catch return false;
        self.service_sources.clearRetainingCapacity();
        self.service_fds.clearRetainingCapacity();
        for (self.sources.items) |s| {
            const events = waitEvents(s);
            if (events == 0) continue;
            self.service_sources.appendAssumeCapacity(s);
            self.service_fds.appendAssumeCapacity(.{ .fd = s.handle, .events = events, .revents = 0 });
        }
        self.service_version = self.version;
        return true;
    }

    // ── Clock ────────────────────────────────────────────────────────────────

    fn vtNow(ctx: *anyopaque) i64 {
        return @intCast(std.Io.Clock.awake.now(of(ctx).io).nanoseconds);
    }

    fn vtSleep(ctx: *anyopaque, duration_ns: i64) void {
        if (duration_ns <= 0) return;
        std.Io.sleep(of(ctx).io, .{ .nanoseconds = duration_ns }, .awake) catch {};
    }
};
