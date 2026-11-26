//! The readiness progress backend for hosted platforms: waits on the
//! registered I/O sources (for input, and for output where armed) and a wake
//! descriptor with `poll` (`WSAPoll` on Windows), and services the ready sources
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
const sock = @import("../util/sock.zig");
const backend_mod = @import("backend.zig");
const ProgressBackend = backend_mod.ProgressBackend;
const ServiceResult = backend_mod.ServiceResult;
const Source = backend_mod.Source;

/// Whether this platform has the backend.
pub const supported = switch (builtin.os.tag) {
    .wasi, .freestanding => false,
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
    /// Linux; on Windows, where WSAPoll waits only on sockets, the same
    /// loopback UDP socket, connected to itself; a pipe elsewhere). Both
    /// nonblocking.
    wake_rd: posix.socket_t,
    wake_wr: posix.socket_t,

    mu: Mutex = .{},
    // Guarded by `mu`, with each source's `output_armed`.
    sources: std.ArrayListUnmanaged(*Source) = .empty,
    /// Advances on every change to `sources` or to what they wait for.
    version: u64 = 0,

    // The poller's: rebuilt from `sources` when `version` moves.
    wait_fds: std.ArrayListUnmanaged(sock.PollFd) = .empty,
    wait_version: u64 = std.math.maxInt(u64),

    service_mu: Mutex = .{},
    // Guarded by `service_mu`: the sources as of `service_version`, and where
    // the next round starts, so one busy source cannot starve the others.
    service_sources: std.ArrayListUnmanaged(*Source) = .empty,
    service_fds: std.ArrayListUnmanaged(sock.PollFd) = .empty,
    service_version: u64 = std.math.maxInt(u64),
    next: usize = 0,
    /// Lent to each source's `service`, one at a time under `service_mu`.
    scratch: *[backend_mod.service_scratch_len]u8,

    /// An application's event loop, when one drives the runtime
    /// (docs/design/concurrency/runtime.md#external-loop-adapter). Set once,
    /// before the loop relies on it, and never cleared.
    external: ?External = null,
    /// The loop has prepared to wait and not been woken since: the next wake
    /// calls its hook. Woken once per wait, however many wakes arrive.
    external_armed: std.atomic.Value(bool) = .init(false),
    /// Serializes `watch` calls, so a socket's last report is its current
    /// interest. Taken before `mu`, never inside it.
    watch_mu: Mutex = .{},
    /// Guarded by `watch_mu`: each watched socket's last reported interest.
    watched: std.AutoHashMapUnmanaged(posix.socket_t, u32) = .empty,

    test_hooks: if (builtin.is_test) TestHooks else void = if (builtin.is_test) .{} else {},

    /// Interest a `watch` call reports: what the loop waits on a socket for.
    pub const watch_read: u32 = 1;
    pub const watch_write: u32 = 2;

    /// An application event loop's hooks: zzdds_c.h's `zzdds_ExternalLoop`.
    /// None may call into zzdds.
    pub const External = extern struct {
        ctx: ?*anyopaque = null,
        /// Ends the loop's current or next wait. Called from any thread.
        wake: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
        /// Starts, changes or (with 0) stops waiting on `handle` for
        /// `watch_read`/`watch_write`. Called from the thread that changed
        /// the socket, one call at a time, and with 0 before it closes.
        watch: ?*const fn (ctx: ?*anyopaque, handle: posix.socket_t, events: u32) callconv(.c) void = null,
        /// The runtime's scheduling clock, in monotonic nanoseconds; null
        /// for the backend's own.
        now_ns: ?*const fn (ctx: ?*anyopaque) callconv(.c) i64 = null,
        /// Once the runtime has stopped, before it is freed: the loop's
        /// last call from zzdds.
        release: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

        pub const watch_read_bit = watch_read;
        pub const watch_write_bit = watch_write;
    };

    /// Seams for deterministic tests of races; absent outside test builds.
    pub const TestHooks = struct {
        /// Runs once in `wait`, on a waiter that found another polling,
        /// before it waits on the futex.
        before_futex_wait: ?*const fn (backend: *PollBackend) void = null,
    };

    pub fn init(alloc: std.mem.Allocator, io: std.Io) error{ SystemResources, OutOfMemory }!PollBackend {
        comptime std.debug.assert(supported);
        var fds: [2]posix.socket_t = undefined;
        if (builtin.os.tag == .windows) {
            const fd = try openLoopbackWake();
            fds = .{ fd, fd };
        } else if (builtin.os.tag == .linux) {
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
        const scratch = alloc.create([backend_mod.service_scratch_len]u8) catch {
            closeWake(fds[0], fds[1]);
            return error.OutOfMemory;
        };
        return .{ .io = io, .alloc = alloc, .wake_rd = fds[0], .wake_wr = fds[1], .scratch = scratch };
    }

    fn closeWake(rd: posix.socket_t, wr: posix.socket_t) void {
        if (builtin.os.tag == .windows) {
            sock.close(rd);
        } else {
            _ = c.close(rd);
            if (wr != rd) _ = c.close(wr);
        }
    }

    /// A nonblocking UDP socket on 127.0.0.1 connected to itself: a datagram
    /// it sends makes it readable.
    fn openLoopbackWake() error{SystemResources}!posix.socket_t {
        const fd = sock.open(posix.AF.INET, posix.SOCK.DGRAM) catch return error.SystemResources;
        errdefer sock.close(fd);
        var addr = posix.sockaddr.in{ .family = posix.AF.INET, .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (c.bind(fd, @ptrCast(&addr), len) != 0 or
            c.getsockname(fd, @ptrCast(&addr), &len) != 0 or
            c.connect(fd, @ptrCast(&addr), len) != 0)
        {
            return error.SystemResources;
        }
        sock.setNonblocking(fd) catch return error.SystemResources;
        return fd;
    }

    /// Once no thread waits or services, and every source is unregistered.
    pub fn deinit(self: *PollBackend) void {
        std.debug.assert(self.sources.items.len == 0);
        closeWake(self.wake_rd, self.wake_wr);
        self.sources.deinit(self.alloc);
        self.wait_fds.deinit(self.alloc);
        self.service_sources.deinit(self.alloc);
        self.service_fds.deinit(self.alloc);
        self.alloc.destroy(self.scratch);
        std.debug.assert(self.watched.count() == 0);
        self.watched.deinit(self.alloc);
        self.mu.deinit();
        self.service_mu.deinit();
        self.watch_mu.deinit();
    }

    /// Hands the wait to an application's loop: from now on its hooks hear
    /// of wakes and of what to wait on. Every source registered so far is
    /// reported first. Before any participant runs on the runtime, and once.
    pub fn attachExternal(self: *PollBackend, ext: External) error{OutOfMemory}!void {
        std.debug.assert(self.external == null and ext.wake != null and ext.watch != null);
        self.watch_mu.lock();
        defer self.watch_mu.unlock();
        self.mu.lock();
        const n = self.sources.items.len;
        self.mu.unlock();
        try self.watched.ensureTotalCapacity(self.alloc, @intCast(n + 1));
        self.external = ext;
        self.mu.lock();
        const sources = self.alloc.dupe(*Source, self.sources.items) catch {
            self.mu.unlock();
            self.external = null;
            return error.OutOfMemory;
        };
        self.mu.unlock();
        defer self.alloc.free(sources);
        for (sources) |src| self.reportWatchLocked(src);
    }

    /// Arms the loop's wake for its next wait: the first wake from now on
    /// calls its hook. The caller rechecks for work after this.
    pub fn armExternal(self: *PollBackend) void {
        self.external_armed.store(true, .seq_cst);
    }

    /// Reports `src`'s current interest to the loop if it changed.
    fn reportWatch(self: *PollBackend, src: *Source) void {
        if (self.external == null) return;
        self.watch_mu.lock();
        defer self.watch_mu.unlock();
        self.reportWatchLocked(src);
    }

    /// Under `watch_mu`. A registered source keeps its entry in `watched`,
    /// reserved when it registered, whatever its interest, so a report
    /// never allocates. One no longer registered is reported once with 0
    /// and forgotten: a service still running when it was unregistered
    /// cannot watch it again.
    fn reportWatchLocked(self: *PollBackend, src: *Source) void {
        const ext = self.external orelse return;
        var events: u32 = 0;
        self.mu.lock();
        const registered = std.mem.indexOfScalar(*Source, self.sources.items, src) != null;
        if (registered) {
            const ev = waitEvents(src);
            if (ev & sock.POLL.IN != 0) events |= watch_read;
            if (ev & sock.POLL.OUT != 0) events |= watch_write;
        }
        self.mu.unlock();
        const entry = self.watched.getEntry(src.handle) orelse {
            // Unregistered and already reported.
            if (!registered) return;
            // Registered before the loop attached: `attachExternal`
            // reserved its place.
            self.watched.putAssumeCapacity(src.handle, events);
            if (events != 0) ext.watch.?(ext.ctx, src.handle, events);
            return;
        };
        const prev = entry.value_ptr.*;
        if (registered) entry.value_ptr.* = events else self.watched.removeByPtr(entry.key_ptr);
        if (prev != events) ext.watch.?(ext.ctx, src.handle, events);
    }

    /// Whether a resumed source waits to be serviced as if it had input: it
    /// may hold input already read, with nothing left on its socket.
    pub fn hasKicked(self: *PollBackend) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.sources.items) |src| if (src.kicked.load(.seq_cst)) return true;
        return false;
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
        .pause_input = vtPauseInput,
        .resume_input = vtResumeInput,
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
        if (self.external) |ext| {
            if (self.external_armed.swap(false, .seq_cst)) ext.wake.?(ext.ctx);
        }
    }

    fn signal(self: *PollBackend) void {
        const one: u64 = 1;
        // A full counter, pipe or socket buffer is already signaled.
        if (builtin.os.tag == .windows) {
            _ = c.send(self.wake_wr, std.mem.asBytes(&one), 1, 0);
        } else if (builtin.os.tag == .linux) {
            _ = c.write(self.wake_wr, std.mem.asBytes(&one), 8);
        } else {
            _ = c.write(self.wake_wr, std.mem.asBytes(&one), 1);
        }
    }

    fn drain(self: *PollBackend) void {
        var buf: [64]u8 = undefined;
        if (builtin.os.tag == .windows) {
            while (c.recv(self.wake_rd, &buf, buf.len, 0) > 0) {}
            return;
        }
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
            // Relative: an application loop's clock (`External.now_ns`) is
            // not the one the futex waits on.
            const timeout: std.Io.Timeout = if (deadline_ns) |d|
                .{ .duration = .{ .raw = .{ .nanoseconds = @max(d - vtNow(self), 0) }, .clock = .awake } }
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
        _ = sock.poll(fds, timeout);
    }

    /// The poller's descriptors: the wake descriptor, then every source.
    fn waitFds(self: *PollBackend) ?[]sock.PollFd {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.wait_version != self.version) {
            self.wait_fds.ensureTotalCapacity(self.alloc, self.sources.items.len + 1) catch return null;
            self.wait_fds.clearRetainingCapacity();
            self.wait_fds.appendAssumeCapacity(.{ .fd = sock.pollHandle(self.wake_rd), .events = sock.POLL.IN, .revents = 0 });
            for (self.sources.items) |s| {
                const events = waitEvents(s);
                if (events != 0) self.wait_fds.appendAssumeCapacity(.{ .fd = sock.pollHandle(s.handle), .events = events, .revents = 0 });
            }
            self.wait_version = self.version;
        }
        return self.wait_fds.items;
    }

    /// What to wait on `s` for, under `mu`. A source waiting for nothing is
    /// left out, since poll would still report its errors.
    fn waitEvents(s: *const Source) i16 {
        var events: i16 = 0;
        if (s.service != null and !s.input_paused) events |= sock.POLL.IN;
        if (s.output_armed) events |= sock.POLL.OUT;
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
        // An attached loop's place for the socket, reserved first: once the
        // source is registered, reporting it cannot fail.
        if (self.external != null) {
            self.watch_mu.lock();
            defer self.watch_mu.unlock();
            try self.watched.ensureUnusedCapacity(self.alloc, 1);
            {
                self.mu.lock();
                defer self.mu.unlock();
                try self.sources.append(self.alloc, source);
                self.version += 1;
            }
            self.reportWatchLocked(source);
        } else {
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
        self.reportWatch(source);
        // A poller already waiting starts waiting for the output.
        if (self.polling.load(.seq_cst)) self.signal();
    }

    fn vtPauseInput(ctx: *anyopaque, source: *Source) void {
        const self = of(ctx);
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (source.input_paused) return;
            source.input_paused = true;
            self.version += 1;
            // A poller still waiting on it finds it ready at most once more,
            // and its service holds the input.
        }
        self.reportWatch(source);
    }

    fn vtResumeInput(ctx: *anyopaque, source: *Source) void {
        const self = of(ctx);
        {
            self.mu.lock();
            defer self.mu.unlock();
            source.kicked.store(true, .seq_cst);
            if (source.input_paused) {
                source.input_paused = false;
                self.version += 1;
            }
        }
        self.reportWatch(source);
        // Whoever waits services next, whether or not the socket has input.
        self.wakeN(1);
    }

    /// Under `service_mu`: whether `s` was armed, disarming it.
    fn disarmOutput(self: *PollBackend, s: *Source) bool {
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (!s.output_armed) return false;
            s.output_armed = false;
            self.version += 1;
        }
        self.reportWatch(s);
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
        // Before its owner closes it, so the loop never waits on a reused
        // descriptor.
        self.reportWatch(source);
        if (self.polling.load(.seq_cst)) self.signal();
        if (servicing == self) {
            // This thread runs the service: once out of its list, `source`
            // is not touched again, so its owner may free it at once.
            for (self.service_sources.items, self.service_fds.items) |*s, *fd| {
                // A place already taken out holds no source.
                if (fd.fd == sock.no_poll_handle) continue;
                if (s.* == source) {
                    s.* = undefined;
                    fd.revents = 0;
                    fd.fd = sock.no_poll_handle;
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
        var ready = sock.poll(fds, 0);
        // A resumed source runs as if it had input, until it is serviced.
        // Others are only read.
        for (self.service_sources.items, fds) |s, *fd| {
            if (!s.kicked.load(.seq_cst)) continue;
            if (fd.revents == 0) ready += 1;
            fd.revents |= sock.POLL.IN;
        }
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
                if (fds[i].revents & sock.POLL.OUT != 0 or s.service == null) {
                    fds[i].revents = if (s.service != null) fds[i].revents & ~sock.POLL.OUT else 0;
                    if (self.disarmOutput(s)) s.writable.?(s.ctx);
                    result.serviced += 1;
                    progressed = true;
                    continue;
                }
                if (s.kicked.load(.seq_cst)) s.kicked.store(false, .seq_cst);
                if (fds[i].revents & sock.POLL.NVAL != 0 or s.service.?(s.ctx, 1, self.scratch) == 0) {
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
            self.service_fds.appendAssumeCapacity(.{ .fd = sock.pollHandle(s.handle), .events = events, .revents = 0 });
        }
        self.service_version = self.version;
        return true;
    }

    // ── Clock ────────────────────────────────────────────────────────────────

    fn vtNow(ctx: *anyopaque) i64 {
        const self = of(ctx);
        if (self.external) |ext| if (ext.now_ns) |now| return now(ext.ctx);
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }

    fn vtSleep(ctx: *anyopaque, duration_ns: i64) void {
        if (duration_ns <= 0) return;
        std.Io.sleep(of(ctx).io, .{ .nanoseconds = duration_ns }, .awake) catch {};
    }
};
