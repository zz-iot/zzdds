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
/// in-process, so every RTPS message between them crosses loopback UDP.
const UdpPair = struct {
    delivery: IntraProcessDelivery,
    udp: [2]*UdpTransport,
    disc: [2]*DirectDiscovery,
    factory: [2]*DomainParticipantFactoryImpl,
    dp: [2]DDS.DomainParticipant,
    dw: *DataWriterImpl,
    dr: *DataReaderImpl,

    /// The participants take `runtime`'s only owner references. A null
    /// `runtime`: they resolve the default.
    fn init(self: *UdpPair, runtime: ?*rt.Runtime, pid_base: u32) !void {
        return self.initWith(runtime, pid_base, .RELIABLE_RELIABILITY_QOS);
    }

    /// With both endpoints of `reliability`.
    fn initWith(self: *UdpPair, runtime: ?*rt.Runtime, pid_base: u32, reliability: DDS.ReliabilityQosPolicyKind) !void {
        self.delivery = try IntraProcessDelivery.init(alloc);
        for (0..2) |i| {
            self.udp[i] = try UdpTransport.init(alloc, .{ .participant_id = pid_base + @as(u32, @intCast(i)) }, test_domain.get(), null);
            self.disc[i] = try self.delivery.newDiscovery();
            self.factory[i] = try DomainParticipantFactoryImpl.init(alloc, self.udp[i].transport(), self.disc[i].toDiscovery(), noop_security, .spec_random, .{});
            if (runtime) |r| try self.factory[i].selectRuntime(r);
            self.dp[i] = self.factory[i].toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
            try self.factory[i].selectRuntime(null);
            try testing.expect(self.dp[i].ptr != nil_participant.ptr);
        }
        if (runtime) |r| r.releaseOwner();

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

    fn write(self: *UdpPair, i: usize) !void {
        const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, @truncate(i) };
        _ = try self.dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &payload);
    }

    fn takeInto(self: *UdpPair, got: *std.ArrayListUnmanaged(u8)) !void {
        while (self.dr.takeRaw()) |sample| {
            defer alloc.free(sample.data);
            if (sample.info.valid_data) try got.append(alloc, sample.data[4]);
        }
    }

    /// Deletes both participants, the runtime's last owners.
    fn deleteParticipants(self: *UdpPair) !void {
        for (0..2) |i| {
            try testing.expectEqual(DDS.RETCODE_OK, self.dp[i].delete_contained_entities());
            try testing.expectEqual(DDS.RETCODE_OK, self.factory[i].toDDSFactory().delete_participant(self.dp[i]));
        }
    }

    fn deinit(self: *UdpPair) void {
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
    var pair: UdpPair = undefined;
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
    var pair: UdpPair = undefined;
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
    const ifaces = (udp.mc_send_ifaces.load(.acquire) orelse return error.SkipZigTest).ifaces.len;

    SendSpy.reset();
    udp.test_hooks.before_send = SendSpy.hook;
    // Nothing goes out: every interface's send is substituted.
    SendSpy.substitute = .{ .would_block, .completed, .completed, .completed };
    if (ifaces > SendSpy.substitute.len) return error.SkipZigTest;
    try testing.expectEqual(SendOutcome.would_block, try t.sendGather(&group, &gather));
    try testing.expectEqual(@as(u32, @intCast(ifaces)), SendSpy.calls);
    try testing.expectEqual(@as(u64, 1), udp.sends_would_block.load(.monotonic));
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

    var pair: UdpPair = undefined;
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

    var pair: UdpPair = undefined;
    try pair.initWith(&runtime, 50, .BEST_EFFORT_RELIABILITY_QOS);
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
