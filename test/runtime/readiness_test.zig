//! The readiness backend and the UDP transport on it, in the
//! `-Dshared-runtime` migration build
//! (docs/design/concurrency/transport-adapters.md): a wake racing a wait,
//! the poller handing over to another waiter, round-robin servicing within a
//! budget, and unregistering a source while it is being serviced
//! (#progress-backend); then a reliable pair over loopback UDP under a manual
//! driver, with no thread started by zzdds, and under hosted workers
//! (#validation); and output: gather lists, sends that do not block on the
//! runtime, and a send that would block counted and repaired
//! (#output-submission).

const std = @import("std");
const builtin = @import("builtin");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const rt = zzdds.runtime;

const posix = std.posix;
const c = std.c;
const UdpTransport = zzdds.udp_transport.UdpTransport;
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history = zzdds.rtps.history;
const noop_security = zzdds.noop_security.noop_security_plugins;
const nil_participant = zzdds.dcps.nil_participant;

const testing = std.testing;
const alloc = testing.allocator;

comptime {
    if (!rt.enabled) @compileError("built against the library with -Dshared-runtime off");
}

// Every test is skipped where the platform has no readiness backend.

const SEC: i64 = std.time.ns_per_s;

/// A loopback UDP socket bound to an ephemeral port, and a counting
/// `Source` over it.
const Sock = struct {
    fd: posix.socket_t,
    port: u16,
    source: rt.Source = undefined,
    received: u32 = 0,

    fn init(self: *Sock) !void {
        const fd = c.socket(posix.AF.INET, posix.SOCK.DGRAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var addr: posix.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.BindFailed;
        self.* = .{ .fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
        self.source = .{ .handle = fd, .ctx = self, .service = service };
    }

    fn deinit(self: *Sock) void {
        _ = c.close(self.fd);
    }

    fn sendTo(self: *Sock, to: *const Sock) !void {
        const addr: posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, to.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (c.sendto(self.fd, "x", 1, 0, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 1) return error.SendFailed;
    }

    fn service(ctx: *anyopaque, budget: u32) u32 {
        const self: *Sock = @ptrCast(@alignCast(ctx));
        var handled: u32 = 0;
        var buf: [16]u8 = undefined;
        while (handled < budget) : (handled += 1) {
            if (c.recv(self.fd, &buf, buf.len, posix.MSG.DONTWAIT) < 0) break;
        }
        self.received += handled;
        return handled;
    }
};

const Backend = struct {
    threaded: std.Io.Threaded,
    pb: rt.PollBackend,

    fn init(self: *Backend) !void {
        self.threaded = .init(alloc, .{});
        self.pb = rt.PollBackend.init(alloc, self.threaded.io()) catch |err| {
            self.threaded.deinit();
            return err;
        };
    }

    fn deinit(self: *Backend) void {
        self.pb.deinit();
        self.threaded.deinit();
    }

    fn backend(self: *Backend) rt.ProgressBackend {
        return self.pb.backend();
    }

    fn now(self: *Backend) i64 {
        return self.pb.clock().nowNs();
    }
};

/// Waits until `sock` has input queued. Loopback delivery is complete when
/// `sendto` returns, so every datagram sent to it before is then queued.
fn awaitReadable(sock: *Sock) !void {
    var fds = [1]posix.pollfd{.{ .fd = sock.fd, .events = posix.POLL.IN, .revents = 0 }};
    if (try posix.poll(&fds, 10_000) == 0) return error.Timeout;
}

// ── The backend ───────────────────────────────────────────────────────────────

test "a wake from another thread ends the poller's and a follower's waits, however it races them" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();

    const Waiter = struct {
        returned_at: i64 = 0,
        fn run(self: *@This(), bk: *Backend, token: u32, deadline: i64) void {
            bk.backend().wait(deadline, token);
            self.returned_at = bk.now();
        }
    };
    for (0..200) |_| {
        const token = b.backend().prepareWait();
        const deadline = b.now() + 10 * SEC;
        var w: [2]Waiter = .{ .{}, .{} };
        const t0 = try std.Thread.spawn(.{}, Waiter.run, .{ &w[0], &b, token, deadline });
        const t1 = try std.Thread.spawn(.{}, Waiter.run, .{ &w[1], &b, token, deadline });
        b.backend().wakeAll();
        t0.join();
        t1.join();
        try testing.expect(w[0].returned_at < deadline);
        try testing.expect(w[1].returned_at < deadline);
    }
    try testing.expectEqual(@as(u32, 0), b.pb.waiters.load(.acquire));
}

test "when input ends the poller's wait, another waiter takes over polling" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var rx: Sock = undefined;
    try rx.init();
    defer rx.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();
    try b.backend().register(&rx.source);
    defer b.backend().unregister(&rx.source);

    const Waiter = struct {
        returned_at: i64 = 0,
        fn run(self: *@This(), bk: *Backend, token: u32, deadline: i64) void {
            bk.backend().wait(deadline, token);
            self.returned_at = bk.now();
        }
    };
    const deadline = b.now() + 10 * SEC;
    const token = b.backend().prepareWait();
    var w: [2]Waiter = .{ .{}, .{} };
    const t0 = try std.Thread.spawn(.{}, Waiter.run, .{ &w[0], &b, token, deadline });
    const t1 = try std.Thread.spawn(.{}, Waiter.run, .{ &w[1], &b, token, deadline });
    // Once both wait, one polls and one waits on the futex.
    while (b.pb.waiters.load(.acquire) < 2) try std.Thread.yield();
    try tx.sendTo(&rx);
    t0.join();
    t1.join();
    // Neither waited out its deadline: the poller saw the datagram, and the
    // other was woken to poll in its place.
    try testing.expect(w[0].returned_at < deadline);
    try testing.expect(w[1].returned_at < deadline);
}

test "a waiter that has yet to sleep when the poller stops still takes over polling" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var rx: Sock = undefined;
    try rx.init();
    defer rx.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();
    try b.backend().register(&rx.source);
    defer b.backend().unregister(&rx.source);

    // Holds the waiter that found the other polling just before it sleeps.
    const Gate = struct {
        var arrived: std.atomic.Value(bool) = .init(false);
        var release: std.atomic.Value(bool) = .init(false);
        fn hook(_: *rt.PollBackend) void {
            arrived.store(true, .release);
            while (!release.load(.acquire)) std.Thread.yield() catch {};
        }
    };
    const Waiter = struct {
        returned_at: std.atomic.Value(i64) = .init(0),
        fn run(self: *@This(), bk: *Backend, token: u32, deadline: i64) void {
            bk.backend().wait(deadline, token);
            self.returned_at.store(bk.now(), .release);
        }
    };
    b.pb.test_hooks.before_futex_wait = Gate.hook;
    const deadline = b.now() + 10 * SEC;
    const token = b.backend().prepareWait();
    var w: [2]Waiter = .{ .{}, .{} };
    const t0 = try std.Thread.spawn(.{}, Waiter.run, .{ &w[0], &b, token, deadline });
    const t1 = try std.Thread.spawn(.{}, Waiter.run, .{ &w[1], &b, token, deadline });
    while (!Gate.arrived.load(.acquire) or !b.pb.polling.load(.acquire)) try std.Thread.yield();
    try tx.sendTo(&rx);
    // The poller has stopped polling before the other waiter sleeps.
    while (w[0].returned_at.load(.acquire) == 0 and w[1].returned_at.load(.acquire) == 0) try std.Thread.yield();
    Gate.release.store(true, .release);
    t0.join();
    t1.join();
    try testing.expect(w[0].returned_at.load(.acquire) < deadline);
    try testing.expect(w[1].returned_at.load(.acquire) < deadline);
}

test "a source registered while a waiter polls is polled from then on" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var rx: Sock = undefined;
    try rx.init();
    defer rx.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();

    const Waiter = struct {
        returned_at: i64 = 0,
        fn run(self: *@This(), bk: *Backend, token: u32, deadline: i64) void {
            bk.backend().wait(deadline, token);
            self.returned_at = bk.now();
        }
    };
    const deadline = b.now() + 10 * SEC;
    var w: Waiter = .{};
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ &w, &b, b.backend().prepareWait(), deadline });
    while (b.pb.waiters.load(.acquire) < 1) try std.Thread.yield();
    try b.backend().register(&rx.source);
    defer b.backend().unregister(&rx.source);
    try tx.sendTo(&rx);
    t.join();
    try testing.expect(w.returned_at < deadline);
}

test "service handles ready sources round robin, within its budget" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var socks: [2]Sock = undefined;
    for (&socks) |*s| try s.init();
    defer for (&socks) |*s| s.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();
    for (&socks) |*s| try b.backend().register(&s.source);
    defer for (&socks) |*s| b.backend().unregister(&s.source);

    for (&socks) |*s| for (0..3) |_| try tx.sendTo(s);
    for (&socks) |*s| try awaitReadable(s);

    const first = b.backend().service(4);
    try testing.expectEqual(@as(u32, 4), first.serviced);
    try testing.expect(first.more);
    // Neither socket's backlog kept the other waiting.
    try testing.expectEqual(@as(u32, 2), socks[0].received);
    try testing.expectEqual(@as(u32, 2), socks[1].received);

    const rest = b.backend().service(4);
    try testing.expectEqual(@as(u32, 2), rest.serviced);
    try testing.expect(!rest.more);
    try testing.expectEqual(@as(u32, 0), b.backend().service(4).serviced);
}

/// A connected pair of Unix datagram sockets whose sender's output stops
/// being writable once the receiver's queue fills: a UDP socket over
/// loopback never fills that way. Linux only: elsewhere a full queue is
/// reported differently.
const FullPair = struct {
    tx: posix.socket_t,
    rx: posix.socket_t,
    source: rt.Source = undefined,
    writable: u32 = 0,

    fn init(self: *FullPair) !void {
        var fds: [2]posix.socket_t = undefined;
        if (c.socketpair(posix.AF.UNIX, posix.SOCK.DGRAM, 0, &fds) != 0) return error.SocketFailed;
        self.* = .{ .tx = fds[0], .rx = fds[1] };
        self.source = .{ .handle = self.tx, .ctx = self, .service = noInput, .input = false, .writable = onWritable };
    }

    fn deinit(self: *FullPair) void {
        _ = c.close(self.tx);
        _ = c.close(self.rx);
    }

    /// Sends until the sender would block.
    fn fill(self: *FullPair) !void {
        var sent: usize = 0;
        while (sent < 100_000) : (sent += 1) {
            if (c.send(self.tx, "x", 1, posix.MSG.DONTWAIT) < 0) return;
        }
        return error.NeverFull;
    }

    fn drain(self: *FullPair) void {
        var buf: [16]u8 = undefined;
        while (c.recv(self.rx, &buf, buf.len, posix.MSG.DONTWAIT) >= 0) {}
    }

    fn noInput(_: *anyopaque, _: u32) u32 {
        unreachable;
    }

    fn onWritable(ctx: *anyopaque) void {
        const self: *FullPair = @ptrCast(@alignCast(ctx));
        self.writable += 1;
    }
};

test "an output-only source is waited on only while armed, and writable runs once per arming" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var pair: FullPair = undefined;
    try pair.init();
    defer pair.deinit();
    try b.backend().register(&pair.source);
    defer b.backend().unregister(&pair.source);

    // Writable but not armed: nothing to wait for, and service never takes
    // input from it.
    try testing.expectEqual(@as(u32, 0), b.backend().service(4).serviced);
    try testing.expectEqual(@as(u32, 0), pair.writable);

    // Armed while full: no output yet.
    try pair.fill();
    b.backend().armOutput(&pair.source);
    b.backend().armOutput(&pair.source);
    try testing.expectEqual(@as(u32, 0), b.backend().service(4).serviced);

    // Once drained, writable runs once, however often it was armed and
    // however often service runs after.
    pair.drain();
    try testing.expectEqual(@as(u32, 1), b.backend().service(4).serviced);
    try testing.expectEqual(@as(u32, 1), pair.writable);
    try testing.expectEqual(@as(u32, 0), b.backend().service(4).serviced);
    try testing.expectEqual(@as(u32, 1), pair.writable);

    // Armed while writable: it runs on the next service.
    b.backend().armOutput(&pair.source);
    try testing.expectEqual(@as(u32, 1), b.backend().service(4).serviced);
    try testing.expectEqual(@as(u32, 2), pair.writable);
}

test "a poller waits for armed output, and the socket draining ends its wait" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var pair: FullPair = undefined;
    try pair.init();
    defer pair.deinit();
    try b.backend().register(&pair.source);
    defer b.backend().unregister(&pair.source);
    try pair.fill();
    b.backend().armOutput(&pair.source);

    const Waiter = struct {
        fn run(backend: rt.ProgressBackend, deadline_ns: i64) void {
            backend.wait(deadline_ns, backend.prepareWait());
        }
    };
    const deadline = b.now() + 30 * SEC;
    const t = try std.Thread.spawn(.{}, Waiter.run, .{ b.backend(), deadline });
    // Nothing wakes the poller: only the output it waits for can end its wait.
    while (!b.pb.polling.load(.seq_cst)) std.Thread.yield() catch {};
    pair.drain();
    t.join();
    try testing.expect(b.now() < deadline);
    try testing.expectEqual(@as(u32, 1), b.backend().service(4).serviced);
    try testing.expectEqual(@as(u32, 1), pair.writable);
}

test "unregistering a source returns only once a running service of it has" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();

    const Held = struct {
        sock: Sock = undefined,
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        unregistered: std.atomic.Value(bool) = .init(false),

        fn service(ctx: *anyopaque, budget: u32) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
            return Sock.service(&self.sock, budget);
        }

        fn serve(bk: *Backend) void {
            _ = bk.backend().service(1);
        }

        fn unregister(self: *@This(), bk: *Backend) void {
            bk.backend().unregister(&self.sock.source);
            self.unregistered.store(true, .release);
        }
    };
    var h: Held = .{};
    try h.sock.init();
    defer h.sock.deinit();
    h.sock.source.ctx = &h;
    h.sock.source.service = Held.service;
    try b.backend().register(&h.sock.source);
    try tx.sendTo(&h.sock);
    try awaitReadable(&h.sock);

    const server = try std.Thread.spawn(.{}, Held.serve, .{&b});
    while (!h.entered.load(.acquire)) try std.Thread.yield();
    const unregisterer = try std.Thread.spawn(.{}, Held.unregister, .{ &h, &b });
    // The source is gone from the backend, but its service is still running.
    while (b.pb.sourceCount() != 0) try std.Thread.yield();
    try testing.expect(!h.unregistered.load(.acquire));
    h.release.store(true, .release);
    server.join();
    unregisterer.join();
    try testing.expect(h.unregistered.load(.acquire));
}

test "a source's own service may unregister it, and is not called on it again, also for two in one service" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();

    const Closing = struct {
        sock: Sock = undefined,
        bk: *Backend,
        calls: u32 = 0,

        fn service(ctx: *anyopaque, budget: u32) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            const n = Sock.service(&self.sock, @min(budget, 1));
            self.bk.backend().unregister(&self.sock.source);
            // As freed: the backend must not read it again.
            self.sock.source = undefined;
            return n;
        }
    };
    // The second to unregister passes the first's place in the service's
    // list, which must not be read either.
    var closing: [2]Closing = .{ .{ .bk = &b }, .{ .bk = &b } };
    for (&closing) |*cl| {
        try cl.sock.init();
        cl.sock.source.ctx = cl;
        cl.sock.source.service = Closing.service;
    }
    defer for (&closing) |*cl| cl.sock.deinit();
    // Another ready source keeps the service going round after the first.
    var other: Sock = undefined;
    try other.init();
    defer other.deinit();
    for (&closing) |*cl| try b.backend().register(&cl.sock.source);
    try b.backend().register(&other.source);
    for (0..3) |_| {
        for (&closing) |*cl| try tx.sendTo(&cl.sock);
        try tx.sendTo(&other);
    }
    for (&closing) |*cl| try awaitReadable(&cl.sock);
    try awaitReadable(&other);

    // Returns at once, rather than waiting for the service it runs in.
    _ = b.backend().service(16);
    for (&closing) |*cl| try testing.expectEqual(@as(u32, 1), cl.calls);
    try testing.expectEqual(@as(u32, 3), other.received);
    try testing.expectEqual(@as(usize, 1), b.pb.sourceCount());
    _ = b.backend().service(16);
    for (&closing) |*cl| try testing.expectEqual(@as(u32, 1), cl.calls);
    b.backend().unregister(&other.source);
}

test "a source whose input is paused is not serviced, and once resumed is serviced at once, input or not" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var tx: Sock = undefined;
    try tx.init();
    defer tx.deinit();
    var s: Sock = undefined;
    try s.init();
    defer s.deinit();
    const Counted = struct {
        var calls: u32 = 0;
        fn service(ctx: *anyopaque, budget: u32) u32 {
            calls += 1;
            return Sock.service(ctx, budget);
        }
    };
    Counted.calls = 0;
    s.source.service = Counted.service;
    try b.backend().register(&s.source);
    defer b.backend().unregister(&s.source);

    try tx.sendTo(&s);
    try awaitReadable(&s);
    b.backend().pauseInput(&s.source);
    try testing.expectEqual(@as(u32, 0), b.backend().service(16).serviced);
    try testing.expectEqual(@as(u32, 0), Counted.calls);

    b.backend().resumeInput(&s.source);
    try testing.expectEqual(@as(u32, 1), b.backend().service(16).serviced);
    try testing.expectEqual(@as(u32, 1), s.received);

    // Its owner may hold input already read: serviced with none on the socket.
    b.backend().pauseInput(&s.source);
    b.backend().resumeInput(&s.source);
    const calls = Counted.calls;
    _ = b.backend().service(16);
    try testing.expectEqual(calls + 1, Counted.calls);
    _ = b.backend().service(16);
    try testing.expectEqual(calls + 1, Counted.calls);
}

test "resumed sources past the service's budget keep their wakeup for the next service" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    // Each holds input already read, so a service always handles one.
    const Held = struct {
        sock: Sock = undefined,
        calls: u32 = 0,
        fn service(ctx: *anyopaque, _: u32) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return 1;
        }
    };
    var held: [2]Held = .{ .{}, .{} };
    for (&held) |*h| {
        try h.sock.init();
        h.sock.source.ctx = h;
        h.sock.source.service = Held.service;
        try b.backend().register(&h.sock.source);
    }
    defer for (&held) |*h| {
        b.backend().unregister(&h.sock.source);
        h.sock.deinit();
    };
    for (&held) |*h| {
        b.backend().pauseInput(&h.sock.source);
        b.backend().resumeInput(&h.sock.source);
    }

    // Budget for one: one is serviced, then the other, then neither.
    try testing.expectEqual(@as(u32, 1), b.backend().service(1).serviced);
    try testing.expectEqual(@as(u32, 1), held[0].calls + held[1].calls);
    try testing.expectEqual(@as(u32, 1), b.backend().service(1).serviced);
    try testing.expectEqual(@as(u32, 1), held[0].calls);
    try testing.expectEqual(@as(u32, 1), held[1].calls);
    try testing.expectEqual(@as(u32, 0), b.backend().service(1).serviced);
}

// ── UDP on the runtime ────────────────────────────────────────────────────────

/// Threads in this process, where the platform reports it.
fn threadCount() ?usize {
    if (builtin.os.tag != .linux) return null;
    const fd = c.open("/proc/self/status", .{}, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    var lines = std.mem.splitScalar(u8, buf[0..@intCast(n)], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Threads:")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line["Threads:".len..], " \t"), 10) catch null;
    }
    return null;
}

const samples_n = 20;

/// Two participants, each with its own UDP transport; discovery is
/// in-process, so every RTPS message between them crosses loopback UDP, or
/// loopback TCP when the participants' user data goes over TCP.
const NetPair = struct {
    delivery: IntraProcessDelivery,
    udp: [2]*UdpTransport,
    disc: [2]*DirectDiscovery,
    factory: [2]*DomainParticipantFactoryImpl,
    dp: [2]DDS.DomainParticipant,
    dw: *DataWriterImpl,
    dr: *DataReaderImpl,

    const Options = struct {
        /// Of both endpoints.
        reliability: DDS.ReliabilityQosPolicyKind = .RELIABLE_RELIABILITY_QOS,
        /// User data over loopback TCP.
        tcp: bool = false,
    };

    /// The participants take `runtime`'s only owner references. A null
    /// `runtime`: they resolve the default.
    fn init(self: *NetPair, runtime: ?*rt.Runtime, pid_base: u32) !void {
        return self.initWith(runtime, pid_base, .{});
    }

    fn initWith(self: *NetPair, runtime: ?*rt.Runtime, pid_base: u32, opts: Options) !void {
        self.delivery = try IntraProcessDelivery.init(alloc);
        var config: zzdds.config.Config = .{};
        if (opts.tcp) config.transport.tcp = .{ .enabled = true, .bind_address = "127.0.0.1" };
        for (0..2) |i| {
            self.udp[i] = try UdpTransport.init(alloc, .{ .participant_id = pid_base + @as(u32, @intCast(i)) }, test_domain.get(), null);
            self.disc[i] = try self.delivery.newDiscovery();
            self.factory[i] = try DomainParticipantFactoryImpl.init(alloc, self.udp[i].transport(), self.disc[i].toDiscovery(), noop_security, .spec_random, .{});
            if (runtime) |r| try self.factory[i].selectRuntime(r);
            self.dp[i] = self.factory[i].createParticipantWithConfig(test_domain.get(), &.{}, null, 0, config);
            try self.factory[i].selectRuntime(null);
            try testing.expect(self.dp[i].ptr != nil_participant.ptr);
        }
        if (runtime) |r| r.releaseOwner();

        const reliability = opts.reliability;
        var dw_qos: DDS.DataWriterQos = .{};
        dw_qos.reliability.kind = reliability;
        dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        var dr_qos: DDS.DataReaderQos = .{};
        dr_qos.reliability.kind = reliability;
        dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        const topic_w = self.dp[0].create_topic("UdpTopic", "UdpType", .{}, null, 0);
        const topic_r = self.dp[1].create_topic("UdpTopic", "UdpType", .{}, null, 0);
        const sub = self.dp[1].create_subscriber(.{}, null, 0);
        const desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
        self.dr = @ptrCast(@alignCast(sub.create_datareader(desc_r, dr_qos, null, 0).ptr));
        const publisher = self.dp[0].create_publisher(.{}, null, 0);
        self.dw = @ptrCast(@alignCast(publisher.create_datawriter(topic_w, dw_qos, null, 0).ptr));
    }

    fn write(self: *NetPair, i: usize) !void {
        const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, @truncate(i) };
        _ = try self.dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &payload);
    }

    /// Sample `i` padded to `len` bytes.
    fn writeSized(self: *NetPair, i: usize, len: usize) !void {
        const payload = try alloc.alloc(u8, len);
        defer alloc.free(payload);
        @memset(payload, @truncate(i));
        payload[0..5].* = .{ 0x00, 0x01, 0x00, 0x00, @truncate(i) };
        _ = try self.dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), payload);
    }

    /// The participants' TCP transports, when their user data uses TCP.
    fn tcp(self: *NetPair, i: usize) *TcpTransport {
        return @as(*zzdds.dcps.DomainParticipantImpl, @ptrCast(@alignCast(self.dp[i].ptr))).owned_tcp_transport.?;
    }

    fn takeInto(self: *NetPair, got: *std.ArrayListUnmanaged(u8)) !void {
        while (self.dr.takeRaw()) |sample| {
            defer alloc.free(sample.data);
            if (sample.info.valid_data) try got.append(alloc, sample.data[4]);
        }
    }

    /// Deletes both participants, the runtime's last owners.
    fn deleteParticipants(self: *NetPair) !void {
        for (0..2) |i| {
            try testing.expectEqual(DDS.RETCODE_OK, self.dp[i].delete_contained_entities());
            try testing.expectEqual(DDS.RETCODE_OK, self.factory[i].toDDSFactory().delete_participant(self.dp[i]));
        }
    }

    fn deinit(self: *NetPair) void {
        for (0..2) |i| {
            self.factory[i].deinit();
            self.disc[i].deinit();
            self.udp[i].deinit();
        }
        self.delivery.deinit();
    }
};

fn expectInOrder(got: []const u8) !void {
    try testing.expectEqual(@as(usize, samples_n), got.len);
    for (got, 0..) |v, i| try testing.expectEqual(@as(u8, @truncate(i)), v);
}

test "a reliable pair over loopback UDP runs on a manual runtime driven by drive() alone, with no thread started by zzdds" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    const threads_before = threadCount();
    var pair: NetPair = undefined;
    try pair.init(&runtime, 40);
    defer pair.deinit();
    try testing.expect(b.pb.sourceCount() > 0);

    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const deadline = b.now() + 10 * SEC;
    while (got.items.len < samples_n and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    try expectInOrder(got.items);
    // No more than before: a thread an earlier test joined may still be
    // listed in the first count.
    if (threads_before) |n| try testing.expect(threadCount().? <= n);

    try pair.deleteParticipants();
    // Their sockets left the backend with them.
    try testing.expectEqual(@as(usize, 0), b.pb.sourceCount());
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

test "a reliable pair over loopback UDP runs on the default runtime, whose hosted workers service the sockets" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    const registry = &rt.default_registry.global;
    defer {
        registry.clear();
        registry.reap(true);
    }
    var pair: NetPair = undefined;
    try pair.init(null, 42);
    defer pair.deinit();
    const runtime = @as(*zzdds.dcps.DomainParticipantImpl, @ptrCast(@alignCast(pair.dp[0].ptr))).runtime.?;
    try testing.expect(runtime.backend.hasSources());

    const ws = try zzdds.dcps.WaitSetImpl.init(alloc);
    defer ws.deinit();
    const waitset = ws.toDDSWaitSet();
    const cond = pair.dr.toDDSDataReader().get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, cond.set_enabled_statuses(DDS.DATA_AVAILABLE_STATUS));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(cond.as_Condition()));
    var active: DDS.ConditionSeq = .{};
    defer if (active._buffer) |buf| alloc.free(buf[0..active._maximum]);

    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    while (got.items.len < samples_n) {
        try testing.expectEqual(DDS.RETCODE_OK, waitset.wait(&active, .{ .sec = 10, .nanosec = 0 }));
        try pair.takeInto(&got);
    }
    try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(cond.as_Condition()));
    try expectInOrder(got.items);
    try pair.deleteParticipants();
}

test "a UDP transport refuses a runtime whose backend waits on no sockets, and a second runtime while its sockets are open" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    const prev = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev;

    var sb = rt.ScriptedBackend.init(1_000);
    var scripted = rt.Runtime.init(sb.clock(), sb.backend(), .{ .mode = .manual });
    defer scripted.deinit();
    var backends: [2]Backend = undefined;
    var polled: [2]rt.Runtime = undefined;
    for (&backends, &polled) |*b, *r| {
        try b.init();
        r.* = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    }
    defer for (&backends, &polled) |*b, *r| {
        r.deinit();
        b.deinit();
    };

    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var udp: [2]*UdpTransport = undefined;
    var factory: [2]*DomainParticipantFactoryImpl = undefined;
    var disc: [2]*DirectDiscovery = undefined;
    for (0..2) |i| {
        udp[i] = try UdpTransport.init(alloc, .{ .participant_id = 44 + @as(u32, @intCast(i)) }, test_domain.get(), null);
        disc[i] = try delivery.newDiscovery();
        factory[i] = try DomainParticipantFactoryImpl.init(alloc, udp[i].transport(), disc[i].toDiscovery(), noop_security, .spec_random, .{});
    }
    defer for (0..2) |i| {
        factory[i].deinit();
        disc[i].deinit();
        udp[i].deinit();
    };

    // A backend that waits on no sockets cannot service UDP.
    try factory[0].selectRuntime(&scripted);
    try testing.expectEqual(nil_participant.ptr, factory[0].toDDSFactory().create_participant(test_domain.get(), .{}, null, 0).ptr);

    // Once a transport's sockets are one backend's, another runtime's
    // participant cannot use it.
    try factory[1].selectRuntime(&polled[0]);
    const dp = factory[1].toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
    try testing.expect(dp.ptr != nil_participant.ptr);
    try factory[1].selectRuntime(&polled[1]);
    try testing.expectEqual(nil_participant.ptr, factory[1].toDDSFactory().create_participant(test_domain.get(), .{}, null, 0).ptr);

    // Once they are closed, the next participant's runtime takes over.
    try testing.expectEqual(DDS.RETCODE_OK, factory[1].toDDSFactory().delete_participant(dp));
    const next = factory[1].toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
    try testing.expect(next.ptr != nil_participant.ptr);
    try testing.expect(backends[1].pb.sourceCount() > 0);

    for (factory) |f| try f.selectRuntime(null);
    try testing.expectEqual(DDS.RETCODE_OK, factory[1].toDDSFactory().delete_participant(next));
    scripted.releaseOwner();
    for (&polled) |*r| {
        r.releaseOwner();
        while (r.getState() != .backend_stopped) _ = try r.drive(64, 0);
    }
}

// ── Output on the runtime ─────────────────────────────────────────────────────

const transport_iface = zzdds.transport;
const IoVec = transport_iface.IoVec;
const SendOutcome = transport_iface.SendOutcome;

/// What `before_send` saw, and the outcome it substitutes for the next
/// sends (null: the send goes ahead).
const SendSpy = struct {
    var calls: u32 = 0;
    var last_flags: u32 = 0;
    var last_iovecs: usize = 0;
    var substitute: [4]?SendOutcome = @splat(null);

    fn reset() void {
        calls = 0;
        last_flags = 0;
        last_iovecs = 0;
        substitute = @splat(null);
    }

    fn hook(_: *UdpTransport, iovecs: []const IoVec, flags: u32) ?SendOutcome {
        defer calls += 1;
        last_flags = flags;
        last_iovecs = iovecs.len;
        return if (calls < substitute.len) substitute[calls] else null;
    }
};

const gather = [_]IoVec{
    .{ .base = "ab", .len = 2 },
    .{ .base = "c", .len = 1 },
    .{ .base = "de", .len = 2 },
};

test "a UDP transport sends a gather list as one datagram without flattening it, and once on a runtime it does not block" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var sock: Sock = undefined;
    try sock.init();
    defer sock.deinit();
    const to = transport_iface.Locator.udp4(.{ 127, 0, 0, 1 }, sock.port);

    const udp = try UdpTransport.init(alloc, .{ .participant_id = 46 }, test_domain.get(), null);
    defer udp.deinit();
    const t = udp.transport();
    SendSpy.reset();
    udp.test_hooks.before_send = SendSpy.hook;

    // Not on a runtime: a blocking send, as on the threaded path.
    try testing.expectEqual(SendOutcome.completed, try t.sendGather(&to, &gather));
    try testing.expectEqual(@as(u32, 0), SendSpy.last_flags & posix.MSG.DONTWAIT);

    try t.attachBackend(b.backend());
    try testing.expectEqual(SendOutcome.completed, try t.sendGather(&to, &gather));
    try testing.expect(SendSpy.last_flags & posix.MSG.DONTWAIT != 0);
    // The list reached the syscall as given.
    try testing.expectEqual(gather.len, SendSpy.last_iovecs);
    try awaitReadable(&sock);
    var buf: [16]u8 = undefined;
    for (0..2) |_| {
        const n = c.recv(sock.fd, &buf, buf.len, posix.MSG.DONTWAIT);
        try testing.expectEqualStrings("abcde", buf[0..@intCast(n)]);
    }
    try testing.expectEqual(@as(u64, 0), udp.sends_would_block.load(.monotonic));

    // A full send buffer: the datagram is dropped and counted, and not
    // retried on another socket.
    SendSpy.reset();
    SendSpy.substitute[0] = .would_block;
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&to, &gather));
    try testing.expectEqual(@as(u32, 1), SendSpy.calls);
    try testing.expectEqual(@as(u64, 1), udp.sends_would_block.load(.monotonic));
    // The flat send reports it as an error.
    SendSpy.reset();
    SendSpy.substitute[0] = .would_block;
    try testing.expectError(error.WouldBlock, t.send(&to, "abcde"));
    try testing.expectEqual(@as(u64, 2), udp.sends_would_block.load(.monotonic));
}

fn ignoreReceive(_: *anyopaque, _: []const u8, _: transport_iface.Locator, _: transport_iface.Channel) void {}

test "a multicast datagram that would block on one interface is not reported sent, though the others carried it" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 47 }, test_domain.get(), null);
    defer udp.deinit();
    const t = udp.transport();
    try t.attachBackend(b.backend());

    var ctx: u8 = 0;
    const handler: transport_iface.ReceiveHandler = .{ .ctx = &ctx, .on_receive = ignoreReceive };
    const port: u16 = @intCast(7400 + 250 * test_domain.get() + 1);
    const any = transport_iface.Locator.udp4(.{ 0, 0, 0, 0 }, port);
    const group = transport_iface.Locator.udp4(.{ 239, 255, 0, 1 }, port);
    try t.listen(&any, handler);
    defer t.unlisten(&any, handler);
    t.joinMulticast(&group) catch return error.SkipZigTest; // no multicast-capable interface
    defer t.leaveMulticast(&group);
    const ifaces = (udp.mc_send_ifaces orelse return error.SkipZigTest).ifaces.len;

    SendSpy.reset();
    udp.test_hooks.before_send = SendSpy.hook;
    // Nothing goes out: every interface's send is substituted.
    SendSpy.substitute = .{ .would_block, .completed, .completed, .completed };
    if (ifaces > SendSpy.substitute.len) return error.SkipZigTest;
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&group, &gather));
    try testing.expectEqual(@as(u32, @intCast(ifaces)), SendSpy.calls);
    try testing.expectEqual(@as(u64, 1), udp.sends_would_block.load(.monotonic));
}

/// Interfaces as the system reports them, plus one more once `extra` is set.
const Interfaces = struct {
    var extra = false;
    var polls: u32 = 0;
    const added: zzdds.transport.IfAddr = .{
        .kind = zzdds.transport.LocatorKind.udp_v4,
        .ip = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 192, 0, 2, 77 },
        .name = std.mem.zeroes([16]u8),
        .flags = 0,
    };

    fn enumerate(udp: *UdpTransport, out: *std.ArrayListUnmanaged(zzdds.transport.IfAddr)) anyerror!void {
        polls += 1;
        try udp.monitor.enumerate(out, alloc);
        if (extra) try out.append(alloc, added);
    }

    fn changed(ctx: *anyopaque) void {
        const n: *u32 = @ptrCast(@alignCast(ctx));
        n.* += 1;
    }
};

fn advertises(udp: *UdpTransport, ip: [4]u8) !bool {
    var locs: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs.deinit(alloc);
    try udp.transport().unicastLocators(&locs, alloc);
    for (locs.items) |loc| {
        if (loc == .udp_v4 and std.mem.eql(u8, &loc.udp_v4.addr, &ip)) return true;
    }
    return false;
}

test "on a runtime, a UDP transport re-polls its interfaces on a timer while a port is listened, and reports only a change" {
    if (!rt.poll_backend.supported or !UdpTransport.repolls_interfaces) return error.SkipZigTest;
    // Binding to the added address fails, as it is not this host's: expected.
    const prev = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    const udp = try UdpTransport.init(alloc, .{ .participant_id = 53, .interface_poll_interval_ms = 20 }, test_domain.get(), null);
    defer udp.deinit();
    const t = udp.transport();
    try t.attachBackend(b.backend());
    t.attachRuntime(&runtime);
    Interfaces.extra = false;
    Interfaces.polls = 0;
    udp.test_hooks.enumerate = Interfaces.enumerate;
    var changes: u32 = 0;
    t.setLocatorChangeHandler(.{ .ctx = &changes, .on_change = Interfaces.changed });

    // Nothing is polled until a port is listened.
    try testing.expectEqual(@as(?i64, null), runtime.nextDeadline());
    var ctx: u8 = 0;
    const handler: transport_iface.ReceiveHandler = .{ .ctx = &ctx, .on_receive = ignoreReceive };
    const port: u16 = @intCast(7400 + 250 * test_domain.get() + 5);
    const any = transport_iface.Locator.udp4(.{ 0, 0, 0, 0 }, port);
    try t.listen(&any, handler);
    try testing.expect(runtime.nextDeadline() != null);

    // Polls that find nothing new report nothing.
    const deadline = b.now() + 10 * SEC;
    while (Interfaces.polls < 2 and b.now() < deadline) _ = try runtime.drive(64, 50 * std.time.ns_per_ms);
    try testing.expect(Interfaces.polls >= 2);
    try testing.expectEqual(@as(u32, 0), changes);

    // An interface that appears is found by the next poll and advertised.
    Interfaces.extra = true;
    while (changes == 0 and b.now() < deadline) _ = try runtime.drive(64, 50 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), changes);
    try testing.expect(try advertises(udp, .{ 192, 0, 2, 77 }));
    const polls = Interfaces.polls;
    while (Interfaces.polls < polls + 2 and b.now() < deadline) _ = try runtime.drive(64, 50 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 1), changes);

    // With the last port, polling stops.
    t.unlisten(&any, handler);
    try testing.expectEqual(@as(?i64, null), runtime.nextDeadline());
    runtime.releaseOwner();
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

/// Counts the runs of its waiter.
const Waited = struct {
    waiter: transport_iface.WritableWaiter = .{ .on_writable = run },
    runs: u32 = 0,

    fn run(w: *transport_iface.WritableWaiter) void {
        const self: *Waited = @fieldParentPtr("waiter", w);
        self.runs += 1;
    }
};

test "a waiter queued after a send would block runs once the send socket can take output, and at once when none blocked" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var sock: Sock = undefined;
    try sock.init();
    defer sock.deinit();
    const to = transport_iface.Locator.udp4(.{ 127, 0, 0, 1 }, sock.port);
    const udp = try UdpTransport.init(alloc, .{ .participant_id = 49 }, test_domain.get(), null);
    defer udp.deinit();
    const t = udp.transport();
    try t.attachBackend(b.backend());
    try testing.expect(t.canNotifyWritable());

    var ctx: u8 = 0;
    const handler: transport_iface.ReceiveHandler = .{ .ctx = &ctx, .on_receive = ignoreReceive };
    const port: u16 = @intCast(7400 + 250 * test_domain.get() + 3);
    const any = transport_iface.Locator.udp4(.{ 0, 0, 0, 0 }, port);
    try t.listen(&any, handler);
    const receiving = b.pb.sourceCount();

    // Nothing has blocked: it runs at once.
    var w: Waited = .{};
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 1), w.runs);
    try testing.expectEqual(receiving, b.pb.sourceCount());

    // After a send that would block, it waits for the backend to find the
    // send socket writable, which it is, and runs once, however often queued.
    SendSpy.reset();
    udp.test_hooks.before_send = SendSpy.hook;
    SendSpy.substitute[0] = .would_block;
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&to, &gather));
    t.notifyWritable(&w.waiter);
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 1), w.runs);
    // The send socket joined the backend to be waited for.
    try testing.expectEqual(receiving + 1, b.pb.sourceCount());
    try testing.expectEqual(@as(u32, 1), b.backend().service(16).serviced);
    try testing.expectEqual(@as(u32, 2), w.runs);
    try testing.expectEqual(@as(u32, 0), b.backend().service(16).serviced);

    // Cancelled before the socket drains: it does not run.
    SendSpy.reset();
    SendSpy.substitute[0] = .would_block;
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&to, &gather));
    t.notifyWritable(&w.waiter);
    t.cancelWritable(&w.waiter);
    _ = b.backend().service(16);
    try testing.expectEqual(@as(u32, 2), w.runs);

    // The send socket leaves the backend with the last port.
    t.unlisten(&any, handler);
    try testing.expectEqual(@as(usize, 0), b.pb.sourceCount());
}

/// Substitutes `would_block` for the first `drop_limit` datagrams carrying
/// user DATA, as a full send buffer would.
const DataDropper = struct {
    var dropped: u32 = 0;
    var drop_limit: u32 = 0;

    fn hook(_: *UdpTransport, iovecs: []const IoVec, _: u32) ?SendOutcome {
        if (dropped >= drop_limit or !carriesUserData(iovecs)) return null;
        dropped += 1;
        return .would_block;
    }

    fn carriesUserData(iovecs: []const IoVec) bool {
        var buf: [transport_iface.Transport.max_flattened_send]u8 = undefined;
        var len: usize = 0;
        for (iovecs) |iov| {
            @memcpy(buf[len..][0..iov.len], iov.base[0..iov.len]);
            len += iov.len;
        }
        const msg = buf[0..len];
        if (msg.len < 20 or !std.mem.eql(u8, msg[0..4], "RTPS")) return false;
        var o: usize = 20;
        while (o + 4 <= msg.len) {
            const id = msg[o];
            const little = msg[o + 1] & 1 != 0;
            const sub_len: usize = std.mem.readInt(u16, msg[o + 2 ..][0..2], if (little) .little else .big);
            // DATA or DATA_FRAG: the writer's entity kind ends its id.
            if ((id == 0x15 or id == 0x16) and o + 16 <= msg.len) {
                const kind = msg[o + 15];
                if (kind == 0x02 or kind == 0x03) return true;
            }
            if (sub_len == 0) break;
            o += 4 + sub_len;
        }
        return false;
    }
};

test "reliable user data whose sends would block still arrives in order, and the write still succeeds" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    var pair: NetPair = undefined;
    try pair.init(&runtime, 48);
    defer pair.deinit();
    DataDropper.dropped = 0;
    DataDropper.drop_limit = 5;
    pair.udp[0].test_hooks.before_send = DataDropper.hook;

    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const deadline = b.now() + 10 * SEC;
    while (got.items.len < samples_n and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    try expectInOrder(got.items);
    try testing.expectEqual(@as(u32, 5), DataDropper.dropped);
    try testing.expectEqual(@as(u64, 5), pair.udp[0].sends_would_block.load(.monotonic));

    try pair.deleteParticipants();
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

test "best-effort user data whose sends would block waits for the socket and arrives in order, with nothing lost" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    var pair: NetPair = undefined;
    try pair.initWith(&runtime, 50, .{ .reliability = .BEST_EFFORT_RELIABILITY_QOS });
    defer pair.deinit();
    // Best effort has no repair: what a send that would block did not carry
    // arrives only because the writer waits for the socket and sends it
    // again. More would-blocks than samples: the writer waits several times.
    DataDropper.dropped = 0;
    DataDropper.drop_limit = 30;
    pair.udp[0].test_hooks.before_send = DataDropper.hook;

    // Matched both ways before writing: a best-effort writer sends nothing
    // to a reader it has yet to match.
    const deadline = b.now() + 10 * SEC;
    while (pair.dw.matchedReaderCount() == 0 and b.now() < deadline) _ = try runtime.drive(64, 10 * std.time.ns_per_ms);
    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    while (got.items.len < samples_n and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    try expectInOrder(got.items);
    try testing.expectEqual(@as(u32, 30), DataDropper.dropped);

    try pair.deleteParticipants();
    try testing.expectEqual(@as(usize, 0), b.pb.sourceCount());
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

// ── TCP on the runtime ────────────────────────────────────────────────────────

const TcpTransport = zzdds.tcp_transport.TcpTransport;
const TcpConnection = zzdds.tcp_transport.TcpConnection;
const Locator = transport_iface.Locator;
const Channel = transport_iface.Channel;

test "a reliable pair over loopback TCP runs on a manual runtime driven by drive() alone, with no thread started by zzdds" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    const threads_before = threadCount();
    var pair: NetPair = undefined;
    try pair.initWith(&runtime, 52, .{ .tcp = true });
    defer pair.deinit();
    // Each participant's TCP listener is a source.
    for (0..2) |i| try testing.expect(pair.tcp(i).listener != null);

    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const deadline = b.now() + 10 * SEC;
    while (got.items.len < samples_n and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    try expectInOrder(got.items);
    // The data came over a connection the writer dialed and the reader
    // accepted.
    try testing.expect(pair.tcp(0).channels.liveCount() >= 1);
    try testing.expect(pair.tcp(1).channels.liveCount() >= 1);
    if (threads_before) |n| try testing.expect(threadCount().? <= n);

    try pair.deleteParticipants();
    // The listeners and connections left the backend with them.
    try testing.expectEqual(@as(usize, 0), b.pb.sourceCount());
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

test "a reliable pair over loopback TCP runs on the default runtime, whose hosted workers service the connections" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    const registry = &rt.default_registry.global;
    defer {
        registry.clear();
        registry.reap(true);
    }
    var pair: NetPair = undefined;
    try pair.initWith(null, 54, .{ .tcp = true });
    defer pair.deinit();
    try testing.expect(pair.tcp(0).backend != null);

    const ws = try zzdds.dcps.WaitSetImpl.init(alloc);
    defer ws.deinit();
    const waitset = ws.toDDSWaitSet();
    const cond = pair.dr.toDDSDataReader().get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, cond.set_enabled_statuses(DDS.DATA_AVAILABLE_STATUS));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(cond.as_Condition()));
    var active: DDS.ConditionSeq = .{};
    defer if (active._buffer) |buf| alloc.free(buf[0..active._maximum]);

    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    while (got.items.len < samples_n) {
        try testing.expectEqual(DDS.RETCODE_OK, waitset.wait(&active, .{ .sec = 10, .nanosec = 0 }));
        try pair.takeInto(&got);
    }
    try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(cond.as_Condition()));
    try expectInOrder(got.items);
    try pair.deleteParticipants();
}

test "reliable user data over TCP that fills the connection waits for it to drain and arrives in order" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    var pair: NetPair = undefined;
    try pair.initWith(&runtime, 56, .{ .tcp = true });
    defer pair.deinit();

    // Written before anything is driven: far more than the socket buffers
    // hold, so sends block, and the writer holds the reader until the
    // connection drains.
    for (0..samples_n) |i| try pair.writeSized(i, 300 * 1024);
    try testing.expect(pair.tcp(0).sends_would_block.load(.monotonic) > 0);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const deadline = b.now() + 20 * SEC;
    while (got.items.len < samples_n and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    try expectInOrder(got.items);

    try pair.deleteParticipants();
    try testing.expectEqual(@as(usize, 0), b.pb.sourceCount());
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

test "best-effort user data over TCP past the reader's ingress bounds waits for room, arrives in order, and none is dropped" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var b: Backend = undefined;
    try b.init();
    defer b.deinit();
    var runtime = rt.Runtime.init(b.pb.clock(), b.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    var pair: NetPair = undefined;
    try pair.initWith(&runtime, 58, .{ .tcp = true, .reliability = .BEST_EFFORT_RELIABILITY_QOS });
    defer pair.deinit();
    const deadline = b.now() + 20 * SEC;
    while (pair.dw.matchedReaderCount() == 0 and b.now() < deadline) _ = try runtime.drive(64, 10 * std.time.ns_per_ms);

    // The first dials the connection, so the rest go straight to it.
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    try pair.write(0);
    while (got.items.len < 1 and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    // Written before the reader runs again: one read takes far more frames
    // than its ingress queues, and best effort would not repair a dropped one.
    const n = 1000;
    comptime std.debug.assert(n > zzdds.dcps.DomainParticipantImpl.ingress_pending_limit * 2);
    for (1..n) |i| try pair.write(i);
    while (got.items.len < n and b.now() < deadline) {
        _ = try runtime.drive(64, 100 * std.time.ns_per_ms);
        try pair.takeInto(&got);
    }
    try testing.expectEqual(@as(usize, n), got.items.len);
    for (got.items, 0..) |v, i| try testing.expectEqual(@as(u8, @truncate(i)), v);
    const reader: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(pair.dp[1].ptr));
    try testing.expectEqual(@as(u64, 0), reader.ingress_drops.load(.monotonic));

    try pair.deleteParticipants();
    try testing.expectEqual(@as(usize, 0), b.pb.sourceCount());
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

/// What a TCP transport delivered: each frame, and the channels it closed.
const Frames = struct {
    got: std.ArrayListUnmanaged([]u8) = .empty,
    channel: Channel = Channel.none,
    closed: u32 = 0,
    /// Frames it takes before it has no room; null for no bound.
    room: ?usize = null,
    refused: u32 = 0,
    waiter: ?*transport_iface.RoomWaiter = null,
    /// Unlistened: nothing may call it.
    gone: bool = false,

    fn onReceive(ctx: *anyopaque, data: []const u8, _: Locator, channel: Channel) void {
        const self: *Frames = @ptrCast(@alignCast(ctx));
        const copy = alloc.dupe(u8, data) catch @panic("OOM");
        self.got.append(alloc, copy) catch @panic("OOM");
        self.channel = channel;
    }

    fn onClosed(ctx: *anyopaque, _: Channel) void {
        const self: *Frames = @ptrCast(@alignCast(ctx));
        self.closed += 1;
    }

    fn tryReceive(ctx: *anyopaque, data: []const u8, src: Locator, channel: Channel) bool {
        const self: *Frames = @ptrCast(@alignCast(ctx));
        if (self.gone) @panic("handler called after unlisten");
        if (self.room) |*r| {
            if (r.* == 0) {
                self.refused += 1;
                return false;
            }
            r.* -= 1;
        }
        onReceive(ctx, data, src, channel);
        return true;
    }

    fn notifyRoom(ctx: *anyopaque, w: *transport_iface.RoomWaiter, _: []const u8, _: Locator) void {
        const self: *Frames = @ptrCast(@alignCast(ctx));
        if (self.gone) @panic("handler called after unlisten");
        if (self.room == null or self.room.? > 0) return w.on_room(w);
        self.waiter = w;
        w.queued = true;
    }

    fn cancelRoom(ctx: *anyopaque, w: *transport_iface.RoomWaiter) void {
        const self: *Frames = @ptrCast(@alignCast(ctx));
        if (self.gone) @panic("handler called after unlisten");
        if (self.waiter == w) self.waiter = null;
        w.queued = false;
    }

    /// Makes room for `n` more frames, or any number, and wakes the
    /// connection waiting for it.
    fn give(self: *Frames, n: ?usize) void {
        self.room = if (n) |k| (self.room orelse 0) + k else null;
        const w = self.waiter orelse return;
        self.waiter = null;
        w.queued = false;
        w.on_room(w);
    }

    fn handler(self: *Frames) transport_iface.ReceiveHandler {
        return .{
            .ctx = self,
            .on_receive = onReceive,
            .on_channel_closed = onClosed,
            .try_receive = tryReceive,
            .notify_room = notifyRoom,
            .cancel_room = cancelRoom,
        };
    }

    fn deinit(self: *Frames) void {
        for (self.got.items) |f| alloc.free(f);
        self.got.deinit(alloc);
    }
};

/// A TCP transport listening on loopback, on a backend the test services.
const TcpNode = struct {
    b: Backend,
    tr: *TcpTransport,
    frames: Frames = .{},
    port: u16,

    fn init(self: *TcpNode) !void {
        try self.b.init();
        errdefer self.b.deinit();
        self.frames = .{};
        self.tr = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
        errdefer self.tr.deinit();
        const t = self.tr.transport();
        try t.attachBackend(self.b.backend());
        try t.listen(&Locator.tcp4(.{ 127, 0, 0, 1 }, 0), self.frames.handler());
        self.port = self.tr.listen_port;
    }

    fn deinit(self: *TcpNode) void {
        self.tr.deinit();
        self.b.deinit();
        self.frames.deinit();
    }

    /// Services the backend until `done(ctx)`, for at most 10 s.
    fn serviceUntil(self: *TcpNode, ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
        const bk = self.b.backend();
        const deadline = self.b.now() + 10 * SEC;
        while (!done(ctx)) {
            if (self.b.now() > deadline) return error.Timeout;
            const token = bk.prepareWait();
            if (bk.service(64).serviced > 0 or done(ctx)) continue;
            bk.wait(self.b.now() + 20 * std.time.ns_per_ms, token);
        }
    }

    fn live(self: *TcpNode) usize {
        return self.tr.channels.liveCount();
    }

    /// The one connection.
    fn conn(self: *TcpNode) *TcpConnection {
        std.debug.assert(self.tr.live_connections.items.len == 1);
        return self.tr.live_connections.items[0];
    }
};

/// A plain loopback TCP socket the test drives itself.
const Raw = struct {
    fn socket() !posix.socket_t {
        const fd = c.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        return fd;
    }

    /// A listener on an ephemeral port, with a receive buffer of
    /// `rcvbuf` bytes for the connections it accepts, if set.
    fn listen(port: *u16, rcvbuf: ?c_int) !posix.socket_t {
        const fd = try socket();
        errdefer _ = c.close(fd);
        if (rcvbuf) |n| _ = c.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&n), @sizeOf(c_int));
        var addr: posix.sockaddr.in = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (c.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.BindFailed;
        if (c.listen(fd, 4) != 0) return error.ListenFailed;
        var len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        if (c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.BindFailed;
        port.* = std.mem.bigToNative(u16, addr.port);
        return fd;
    }

    /// A loopback port nothing listens on.
    fn closedPort() !u16 {
        var port: u16 = 0;
        const fd = try listen(&port, null);
        _ = c.close(fd);
        return port;
    }

    fn connect(port: u16) !posix.socket_t {
        const fd = try socket();
        errdefer _ = c.close(fd);
        const addr: posix.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) != 0) return error.ConnectFailed;
        return fd;
    }

    /// Accepts the connection queued on `fd`.
    fn accept(fd: posix.socket_t) !posix.socket_t {
        var fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        if (try posix.poll(&fds, 10_000) == 0) return error.Timeout;
        const conn = c.accept(fd, null, null);
        if (conn < 0) return error.AcceptFailed;
        return conn;
    }

    fn writeAll(fd: posix.socket_t, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.send(fd, bytes[off..].ptr, bytes.len - off, 0);
            if (n <= 0) return error.SendFailed;
            off += @intCast(n);
        }
    }

    /// Appends to `out` what `fd` has queued now.
    fn readAvailable(fd: posix.socket_t, out: *std.ArrayListUnmanaged(u8)) !void {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = c.recv(fd, &buf, buf.len, posix.MSG.DONTWAIT);
            if (n <= 0) return;
            try out.appendSlice(alloc, buf[0..@intCast(n)]);
        }
    }

    /// The frame carrying `payload`.
    fn frame(payload: []const u8) ![]u8 {
        const f = try alloc.alloc(u8, 4 + payload.len);
        std.mem.writeInt(u32, f[0..4], @intCast(payload.len), .big);
        @memcpy(f[4..], payload);
        return f;
    }
};

test "a frame its handler has no room for is held and reading stops, until the handler has room, and every frame arrives in order" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    const peer = try Raw.connect(n.port);
    defer _ = c.close(peer);

    // Three frames in one write, then one longer than a read.
    const big = try alloc.alloc(u8, 100_000);
    defer alloc.free(big);
    for (big, 0..) |*b, i| b.* = @truncate(i);
    const payloads = [_][]const u8{ "one", "two", "three", big };
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(alloc);
    for (payloads) |p| {
        const f = try Raw.frame(p);
        defer alloc.free(f);
        try stream.appendSlice(alloc, f);
    }
    n.frames.room = 1;
    try Raw.writeAll(peer, stream.items);

    // The second is held, with what was read after it.
    try n.serviceUntil(&n.frames, struct {
        fn f(fr: *Frames) bool {
            return fr.refused == 1;
        }
    }.f);
    try testing.expectEqual(@as(usize, 1), n.frames.got.items.len);
    try testing.expectEqualStrings("two", n.conn().held);
    try testing.expect(n.conn().backlog.len > 0);
    // Paused: nothing more is read or offered.
    try testing.expect(n.conn().source.input_paused);
    for (0..5) |_| _ = n.b.backend().service(64);
    try testing.expectEqual(@as(usize, 1), n.frames.got.items.len);
    try testing.expectEqual(@as(u32, 1), n.frames.refused);

    // Room for two: the held frame and the next go, and the long one,
    // read whole, is held in turn.
    n.frames.give(2);
    try n.serviceUntil(&n.frames, struct {
        fn f(fr: *Frames) bool {
            return fr.refused == 2;
        }
    }.f);
    try testing.expectEqual(@as(usize, 3), n.frames.got.items.len);
    try testing.expectEqual(big.len, n.conn().held.len);

    n.frames.give(null);
    try n.serviceUntil(&n.frames, struct {
        fn f(fr: *Frames) bool {
            return fr.got.items.len == 4;
        }
    }.f);
    for (payloads, n.frames.got.items) |want, got| try testing.expectEqualSlices(u8, want, got);
    try testing.expectEqual(@as(usize, 0), n.conn().held.len);
}

/// Sends `payload` as one frame on `peer`.
fn sendFrame(peer: posix.socket_t, payload: []const u8) !void {
    const f = try Raw.frame(payload);
    defer alloc.free(f);
    try Raw.writeAll(peer, f);
}

test "a held frame goes once to each handler that has not taken it, though the handlers change meanwhile" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    var b: Frames = .{ .room = 0 };
    defer b.deinit();
    const t = n.tr.transport();
    const at_node = Locator.tcp4(.{ 127, 0, 0, 1 }, n.port);
    try t.listen(&at_node, b.handler());
    const peer = try Raw.connect(n.port);
    defer _ = c.close(peer);

    // The first handler takes it; the second has no room.
    try sendFrame(peer, "one");
    try n.serviceUntil(&b, struct {
        fn f(fr: *Frames) bool {
            return fr.refused == 1;
        }
    }.f);
    b.give(1);
    try n.serviceUntil(&b, struct {
        fn f(fr: *Frames) bool {
            return fr.got.items.len == 1;
        }
    }.f);
    try testing.expectEqual(@as(usize, 1), n.frames.got.items.len);
    try testing.expect(n.conn().room_handler == null);

    // Held again, and the first handler is unlistened meanwhile, so the
    // second moves to its place in the list.
    try sendFrame(peer, "two");
    try n.serviceUntil(&b, struct {
        fn f(fr: *Frames) bool {
            return fr.refused == 2;
        }
    }.f);
    t.unlisten(&at_node, n.frames.handler());
    b.give(null);
    try n.serviceUntil(&b, struct {
        fn f(fr: *Frames) bool {
            return fr.got.items.len == 2;
        }
    }.f);
    try testing.expectEqual(@as(usize, 2), n.frames.got.items.len);
    try testing.expectEqualStrings("two", b.got.items[1]);
}

test "unlistening the handler a held frame waits on cancels the wait, and the handler is not called again" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    var b: Frames = .{ .room = 0 };
    defer b.deinit();
    const t = n.tr.transport();
    const at_node = Locator.tcp4(.{ 127, 0, 0, 1 }, n.port);
    try t.listen(&at_node, b.handler());
    const peer = try Raw.connect(n.port);

    try sendFrame(peer, "one");
    try n.serviceUntil(&b, struct {
        fn f(fr: *Frames) bool {
            return fr.refused == 1;
        }
    }.f);
    try testing.expect(b.waiter != null);

    // Unlistened: its wait is cancelled before unlisten returns, and the
    // frame, which the other handler has, is done with.
    t.unlisten(&at_node, b.handler());
    try testing.expect(b.waiter == null);
    b.gone = true;
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.conn().held.len == 0;
        }
    }.f);
    try testing.expectEqual(@as(usize, 1), n.frames.got.items.len);
    try testing.expectEqual(@as(usize, 0), b.got.items.len);

    // Reading went on, and the connection closes without calling it.
    try sendFrame(peer, "two");
    _ = c.close(peer);
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.live() == 0;
        }
    }.f);
    try testing.expectEqual(@as(usize, 2), n.frames.got.items.len);
}

test "a TCP connection on a backend reassembles frames split across reads and several in one, and closes on a bad length" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    const peer = try Raw.connect(n.port);
    defer _ = c.close(peer);
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.live() == 1;
        }
    }.f);

    // One byte at a time, each read before the next is written.
    const a = try Raw.frame("hello");
    defer alloc.free(a);
    const Consumed = struct {
        node: *TcpNode,
        want: usize,
        fn f(self: *const @This()) bool {
            const conn = self.node.conn();
            const had = if (conn.frame.len > 0) 4 + conn.frame_off else conn.hdr_len;
            return had == self.want or self.node.frames.got.items.len == 1;
        }
    };
    for (a, 1..) |byte, i| {
        try Raw.writeAll(peer, &.{byte});
        try n.serviceUntil(&Consumed{ .node = &n, .want = i }, Consumed.f);
    }
    try testing.expectEqual(@as(usize, 1), n.frames.got.items.len);
    try testing.expectEqualStrings("hello", n.frames.got.items[0]);

    // Two in one write, the second longer than one read takes.
    const big = try alloc.alloc(u8, 150 * 1024);
    defer alloc.free(big);
    for (big, 0..) |*v, i| v.* = @truncate(i);
    const fb = try Raw.frame("ab");
    defer alloc.free(fb);
    const fc = try Raw.frame(big);
    defer alloc.free(fc);
    const bc = try std.mem.concat(alloc, u8, &.{ fb, fc });
    defer alloc.free(bc);
    try Raw.writeAll(peer, bc);
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.frames.got.items.len == 3;
        }
    }.f);
    try testing.expectEqualStrings("ab", n.frames.got.items[1]);
    try testing.expectEqualSlices(u8, big, n.frames.got.items[2]);
    // Every frame on the connection's channel.
    try testing.expect(!n.frames.channel.isNone());

    // A zero length cannot be framed: the connection closes and is freed.
    try Raw.writeAll(peer, &.{ 0, 0, 0, 0 });
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.live() == 0;
        }
    }.f);
    try testing.expectEqual(@as(u32, 1), n.frames.closed);
    var buf: [1]u8 = undefined;
    try testing.expectEqual(@as(isize, 0), c.recv(peer, &buf, 1, 0));
    try testing.expectError(error.ChannelClosed, n.tr.transport().sendOnChannel(n.frames.channel, &Locator.tcp4(.{ 127, 0, 0, 1 }, 1), "x"));
}

const loopback = Locator.tcp4(.{ 127, 0, 0, 1 }, 0);

fn at(port: u16) Locator {
    return Locator.tcp4(.{ 127, 0, 0, 1 }, port);
}

fn noLongerConnecting(node: *TcpNode) bool {
    node.conn().send_mu.lock();
    defer node.conn().send_mu.unlock();
    return !node.conn().connecting and node.conn().tail.len == 0;
}

test "a send while its dial is in progress is kept, and written once the dial completes, and the end of the stream frees it" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    var port: u16 = 0;
    const l = try Raw.listen(&port, null);
    defer _ = c.close(l);

    // Completed at once, though the dial has yet to: the frame waits for it.
    try testing.expectEqual(SendOutcome.completed, try n.tr.transport().sendGather(&at(port), &gather));
    const conn = n.conn();
    if (conn.connecting) try testing.expectEqual(@as(usize, 4 + 5), conn.tail.len);
    try n.serviceUntil(&n, noLongerConnecting);

    const peer = try Raw.accept(l);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    while (got.items.len < 9) try Raw.readAvailable(peer, &got);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 5, 'a', 'b', 'c', 'd', 'e' }, got.items);

    // The peer hangs up: the end of the stream closes and frees it.
    _ = c.close(peer);
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.live() == 0;
        }
    }.f);
    try testing.expectEqual(@as(u32, 1), n.frames.closed);
}

test "a dial that fails with a frame waiting closes the connection, runs its waiters and frees it" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    const t = n.tr.transport();
    const to = at(try Raw.closedPort());

    const first = t.sendGather(&to, &gather) catch |err| {
        // Refused before the dial could be in progress: nothing waits.
        try testing.expectEqual(error.ConnectFailed, err);
        return error.SkipZigTest;
    };
    try testing.expectEqual(SendOutcome.completed, first);
    try testing.expect(n.conn().connecting);
    // The connection has room for one frame until it is connected.
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&to, &gather));
    var w: Waited = .{};
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 0), w.runs);

    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.live() == 0;
        }
    }.f);
    try testing.expectEqual(@as(u32, 1), w.runs);
    try testing.expectEqual(@as(u32, 1), n.frames.closed);
    try testing.expectEqual(@as(usize, 0), n.tr.connections.count());
    // Nothing is blocked now, so a waiter runs at once.
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 2), w.runs);
}

/// A connection from `n` to a peer that does not read, with small buffers
/// on both ends, so that it fills after a few frames.
const Stalled = struct {
    listener: posix.socket_t,
    peer: posix.socket_t,
    to: Locator,
    conn: *TcpConnection,
    /// Every frame sent, as the peer should read them.
    sent: std.ArrayListUnmanaged(u8) = .empty,

    fn init(self: *Stalled, n: *TcpNode) !void {
        var port: u16 = 0;
        self.listener = try Raw.listen(&port, 4096);
        errdefer _ = c.close(self.listener);
        self.to = at(port);
        self.sent = .empty;
        const t = n.tr.transport();
        const first = [_]IoVec{.{ .base = "hi", .len = 2 }};
        _ = try t.sendGather(&self.to, &first);
        try self.record(&first);
        self.conn = n.tr.live_connections.items[n.tr.live_connections.items.len - 1];
        try n.serviceUntil(self, dialed);
        self.peer = try Raw.accept(self.listener);
        const small: c_int = 4096;
        _ = c.setsockopt(self.conn.fd, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&small), @sizeOf(c_int));
    }

    fn dialed(self: *Stalled) bool {
        self.conn.send_mu.lock();
        defer self.conn.send_mu.unlock();
        return !self.conn.connecting and self.conn.tail.len == 0;
    }

    fn deinit(self: *Stalled) void {
        _ = c.close(self.peer);
        _ = c.close(self.listener);
        self.sent.deinit(alloc);
    }

    fn record(self: *Stalled, iovecs: []const IoVec) !void {
        var len: u32 = 0;
        for (iovecs) |iov| len += @intCast(iov.len);
        var hdr: [4]u8 = undefined;
        std.mem.writeInt(u32, &hdr, len, .big);
        try self.sent.appendSlice(alloc, &hdr);
        for (iovecs) |iov| try self.sent.appendSlice(alloc, iov.base[0..iov.len]);
    }

    /// Sends distinct frames of three pieces until one is only partly
    /// written. Returns how many were sent.
    fn fill(self: *Stalled, n: *TcpNode, scratch: []u8) !usize {
        const t = n.tr.transport();
        var i: usize = 0;
        while (i < 1000) : (i += 1) {
            @memset(scratch, @truncate(i));
            const parts = [_]IoVec{
                .{ .base = scratch.ptr, .len = 1000 },
                .{ .base = scratch.ptr + 1000, .len = scratch.len - 2000 },
                .{ .base = scratch.ptr + scratch.len - 1000, .len = 1000 },
            };
            switch (try t.sendGather(&self.to, &parts)) {
                .completed => try self.record(&parts),
                .would_block => return error.BlockedWithoutTail,
            }
            if (self.conn.tail.len > 0) return i + 1;
        }
        return error.NeverFull;
    }
};

test "a frame the socket takes only part of is finished once it drains, before any other" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    var s: Stalled = undefined;
    try s.init(&n);
    defer s.deinit();
    const scratch = try alloc.alloc(u8, 60_001);
    defer alloc.free(scratch);
    const t = n.tr.transport();

    _ = try s.fill(&n, scratch);
    // The rest of that frame comes first: nothing else is written meanwhile.
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&s.to, &gather));
    var w: Waited = .{};
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 0), w.runs);

    // The peer reads; the connection drains, and the waiter runs.
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const Drain = struct {
        node: *TcpNode,
        peer: posix.socket_t,
        got: *std.ArrayListUnmanaged(u8),
        want: usize,
        w: *Waited,
        fn f(self: *const @This()) bool {
            Raw.readAvailable(self.peer, self.got) catch return true;
            return self.got.items.len >= self.want and self.w.runs == 1;
        }
    };
    try n.serviceUntil(&Drain{ .node = &n, .peer = s.peer, .got = &got, .want = s.sent.items.len, .w = &w }, Drain.f);
    try testing.expectEqualSlices(u8, s.sent.items, got.items);
    try testing.expectEqual(@as(usize, 0), n.conn().tail.len);
    try testing.expectEqual(@as(usize, 0), n.tr.blocked_count);
    // Sends go ahead again.
    try testing.expectEqual(SendOutcome.completed, try t.sendGather(&s.to, &gather));
}

test "a waiter registered after its connection drained runs at once, though another connection stays blocked" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    var a: Stalled = undefined;
    try a.init(&n);
    defer a.deinit();
    var b: Stalled = undefined;
    try b.init(&n);
    defer b.deinit();
    const scratch = try alloc.alloc(u8, 60_001);
    defer alloc.free(scratch);
    const t = n.tr.transport();

    _ = try a.fill(&n, scratch);
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&a.to, &gather));

    // a's peer reads, and a drains before its writer waits: no waiter runs.
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const Drain = struct {
        node: *TcpNode,
        peer: posix.socket_t,
        got: *std.ArrayListUnmanaged(u8),
        want: usize,
        fn f(self: *const @This()) bool {
            Raw.readAvailable(self.peer, self.got) catch return true;
            return self.got.items.len >= self.want and self.node.tr.blocked_count == 0;
        }
    };
    try n.serviceUntil(&Drain{ .node = &n, .peer = a.peer, .got = &got, .want = a.sent.items.len }, Drain.f);
    try testing.expectEqualSlices(u8, a.sent.items, got.items);

    // Meanwhile b blocks, with nothing serviced before the waiter registers,
    // so b cannot drain first, however much its peer's buffers grow.
    _ = try b.fill(&n, scratch);
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&b.to, &gather));
    try testing.expectEqual(@as(usize, 1), n.tr.blocked_count);

    // The waiter, registered now, runs at once rather than waiting for b.
    var w: Waited = .{};
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 1), w.runs);
    // Tried again, a takes the frame and b still blocks: now it waits.
    try testing.expectEqual(SendOutcome.completed, try t.sendGather(&a.to, &gather));
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&b.to, &gather));
    t.notifyWritable(&w.waiter);
    try testing.expectEqual(@as(u32, 1), w.runs);
    t.cancelWritable(&w.waiter);
}

test "a connection that closes with part of a frame unwritten frees it, runs its waiters, and its channel fails" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var n: TcpNode = undefined;
    try n.init();
    defer n.deinit();
    var s: Stalled = undefined;
    try s.init(&n);
    defer s.deinit();
    const scratch = try alloc.alloc(u8, 60_001);
    defer alloc.free(scratch);
    const t = n.tr.transport();

    _ = try s.fill(&n, scratch);
    const channel = n.conn().channel;
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&s.to, &gather));
    var w: Waited = .{};
    t.notifyWritable(&w.waiter);

    // The peer goes away without reading: its unread data resets the
    // connection.
    _ = c.close(s.peer);
    s.peer = try Raw.socket();
    try n.serviceUntil(&n, struct {
        fn f(node: *TcpNode) bool {
            return node.live() == 0;
        }
    }.f);
    try testing.expectEqual(@as(u32, 1), w.runs);
    try testing.expectEqual(@as(u32, 1), n.frames.closed);
    try testing.expectEqual(@as(usize, 0), n.tr.blocked_count);
    try testing.expectError(error.ChannelClosed, t.sendOnChannel(channel, &s.to, "x"));
}

test "a TCP transport refuses a backend that waits on no sockets, a second backend, and one once it listens" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var sb = rt.ScriptedBackend.init(1_000);
    var backends: [2]Backend = undefined;
    for (&backends) |*b| try b.init();
    defer for (&backends) |*b| b.deinit();

    const tr = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer tr.deinit();
    const t = tr.transport();
    try testing.expectError(error.BackendHasNoSources, t.attachBackend(sb.backend()));
    try t.attachBackend(backends[0].backend());
    try t.attachBackend(backends[0].backend());
    try testing.expectError(error.AttachedElsewhere, t.attachBackend(backends[1].backend()));

    // Listening on its own thread already.
    var frames: Frames = .{};
    defer frames.deinit();
    const threaded = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer threaded.deinit();
    try threaded.transport().listen(&loopback, frames.handler());
    defer threaded.transport().unlisten(&loopback, frames.handler());
    try testing.expectError(error.AlreadyListening, threaded.transport().attachBackend(backends[1].backend()));
}
