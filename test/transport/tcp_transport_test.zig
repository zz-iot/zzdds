const std = @import("std");
const zzdds = @import("zzdds");
const tcp_mod = zzdds.tcp_transport;
const TcpTransport = tcp_mod.TcpTransport;
const iface = zzdds.transport;
const Locator = iface.Locator;
const LocatorWire = iface.LocatorWire;
const LocatorKind = iface.LocatorKind;
const ReceiveHandler = iface.ReceiveHandler;
const time_mod = zzdds.util.time;

const testing = std.testing;

fn sleepMs(ms: u64) void {
    time_mod.sleepNs(ms * std.time.ns_per_ms);
}

/// Listen on port 0 (IPv4 loopback), return the OS-assigned port.
fn listenAndGetPort(t: iface.Transport, h: ReceiveHandler, alloc: std.mem.Allocator) !u16 {
    const loc = Locator.tcp4(.{ 127, 0, 0, 1 }, 0);
    try t.listen(&loc, h);
    var locs: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs.deinit(alloc);
    try t.unicastLocators(&locs, alloc);
    return locs.items[0].tcp_v4.port;
}

/// Listen on port 0 (IPv6 loopback ::1), return the OS-assigned port.
fn listenAndGetPortV6(t: iface.Transport, h: ReceiveHandler, alloc: std.mem.Allocator) !u16 {
    var lo6 = std.mem.zeroes([16]u8);
    lo6[15] = 1; // ::1
    const loc = Locator.tcp6(lo6, 0);
    try t.listen(&loc, h);
    var locs: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs.deinit(alloc);
    try t.unicastLocators(&locs, alloc);
    return locs.items[0].tcp_v6.port;
}

// ── LocatorWire round-trip for TCP locator kinds ──────────────────────────────

test "LocatorWire tcp_v4 round-trip" {
    const loc = Locator.tcp4(.{ 10, 0, 0, 1 }, 57000);
    const wire = loc.toRtpsWire();
    try testing.expectEqual(LocatorKind.tcp_v4, wire.kind);
    try testing.expectEqual(@as(u32, 57000), wire.port);
    try testing.expectEqual([4]u8{ 10, 0, 0, 1 }, wire.address[12..16].*);

    const back = wire.toLocator();
    try testing.expect(back.eql(loc));
}

test "LocatorWire tcp_v6 round-trip" {
    var addr: [16]u8 = std.mem.zeroes([16]u8);
    addr[15] = 1; // ::1
    const loc = Locator.tcp6(addr, 57001);
    const wire = loc.toRtpsWire();
    try testing.expectEqual(LocatorKind.tcp_v6, wire.kind);
    try testing.expectEqual(@as(u32, 57001), wire.port);
    try testing.expectEqualSlices(u8, &addr, &wire.address);

    const back = wire.toLocator();
    try testing.expect(back.eql(loc));
}

test "Locator.wireKind tcp_v4 and tcp_v6" {
    try testing.expectEqual(LocatorKind.tcp_v4, Locator.tcp4(.{ 1, 2, 3, 4 }, 100).wireKind());
    try testing.expectEqual(LocatorKind.tcp_v6, Locator.tcp6(std.mem.zeroes([16]u8), 200).wireKind());
}

test "TcpTransport.vtCanReach returns true for tcp, false for udp" {
    const alloc = testing.allocator;
    const t_ptr = try TcpTransport.init(alloc, .{});
    defer t_ptr.deinit();
    const t = t_ptr.transport();

    try testing.expect(t.canReach(&Locator.tcp4(.{ 127, 0, 0, 1 }, 0)));
    try testing.expect(t.canReach(&Locator.tcp6(std.mem.zeroes([16]u8), 0)));
    try testing.expect(!t.canReach(&Locator.udp4(.{ 127, 0, 0, 1 }, 7400)));
    try testing.expect(!t.canReach(&Locator{ .shmem = .{ .host_id = 0, .channel_id = 0 } }));
}

// ── RTPS-TCP framing: send + receive a message ────────────────────────────────

test "tcp transport: loopback send and receive" {
    const alloc = testing.allocator;

    const server = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer server.deinit();
    const st = server.transport();

    var received: []u8 = &.{};
    var recv_count: usize = 0;

    const Ctx = struct {
        buf: *[]u8,
        count: *usize,
        alloc: std.mem.Allocator,

        fn onRecv(ctx: *anyopaque, data: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.alloc.free(self.buf.*);
            self.buf.* = self.alloc.dupe(u8, data) catch &.{};
            self.count.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv };
        }
    };
    var ctx = Ctx{ .buf = &received, .count = &recv_count, .alloc = alloc };

    const port = try listenAndGetPort(st, ctx.handler(), alloc);
    defer st.unlisten(&Locator.tcp4(.{ 127, 0, 0, 1 }, port), ctx.handler());

    sleepMs(20);

    const client = try TcpTransport.init(alloc, .{});
    defer client.deinit();
    const ct = client.transport();

    const dest = Locator.tcp4(.{ 127, 0, 0, 1 }, port);
    const payload = "Hello RTPS-TCP";
    try ct.send(&dest, payload);

    sleepMs(100);

    try testing.expectEqual(@as(usize, 1), recv_count);
    try testing.expectEqualSlices(u8, payload, received);

    alloc.free(received);
}

// ── Multiple handlers on the same port (fan-out) ──────────────────────────────

test "tcp transport: fan-out to two handlers" {
    const alloc = testing.allocator;

    const server = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer server.deinit();
    const st = server.transport();

    var count_a: usize = 0;
    var count_b: usize = 0;

    const Counter = struct {
        n: *usize,
        fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
    };
    var ca = Counter{ .n = &count_a };
    var cb = Counter{ .n = &count_b };

    const port = try listenAndGetPort(st, ca.handler(), alloc);
    const listen_loc = Locator.tcp4(.{ 127, 0, 0, 1 }, port);
    defer st.unlisten(&listen_loc, ca.handler());

    // Second handler on the same port.
    try st.listen(&listen_loc, cb.handler());
    defer st.unlisten(&listen_loc, cb.handler());

    sleepMs(20);

    const client = try TcpTransport.init(alloc, .{});
    defer client.deinit();
    const ct = client.transport();

    const dest = Locator.tcp4(.{ 127, 0, 0, 1 }, port);
    try ct.send(&dest, "ping");
    sleepMs(100);

    try testing.expectEqual(@as(usize, 1), count_a);
    try testing.expectEqual(@as(usize, 1), count_b);

    // Unlisten A; only B receives subsequent messages.
    st.unlisten(&listen_loc, ca.handler());
    try ct.send(&dest, "pong");
    sleepMs(100);
    try testing.expectEqual(@as(usize, 1), count_a);
    try testing.expectEqual(@as(usize, 2), count_b);
}

// ── Connection reuse by host ──────────────────────────────────────────────────

test "tcp transport: connection reuse by host" {
    const alloc = testing.allocator;

    var count_b: usize = 0;
    const Counter = struct {
        n: *usize,
        fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
    };
    var cb = Counter{ .n = &count_b };

    // Two servers on different OS-assigned ports (simulating discovery vs data port).
    const server_a = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer server_a.deinit();
    const server_b = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer server_b.deinit();

    const port_a = try listenAndGetPort(server_a.transport(), cb.handler(), alloc);
    const port_b = try listenAndGetPort(server_b.transport(), cb.handler(), alloc);

    defer server_a.transport().unlisten(&Locator.tcp4(.{ 127, 0, 0, 1 }, port_a), cb.handler());
    defer server_b.transport().unlisten(&Locator.tcp4(.{ 127, 0, 0, 1 }, port_b), cb.handler());

    sleepMs(20);

    // Client with reuse_connection_by_host = true (default).
    const client = try TcpTransport.init(alloc, .{ .reuse_connection_by_host = true });
    defer client.deinit();
    const ct = client.transport();

    const loc_a = Locator.tcp4(.{ 127, 0, 0, 1 }, port_a);
    const loc_b = Locator.tcp4(.{ 127, 0, 0, 1 }, port_b);

    // First send: dials server_a → establishes one connection.
    try ct.send(&loc_a, "discovery");
    sleepMs(50);
    {
        client.conn_mu.lock();
        defer client.conn_mu.unlock();
        try testing.expectEqual(@as(usize, 1), client.connections.count());
    }

    // Second send to same host but different port: reuses the existing connection.
    try ct.send(&loc_b, "data");
    sleepMs(50);
    {
        client.conn_mu.lock();
        defer client.conn_mu.unlock();
        try testing.expectEqual(@as(usize, 1), client.connections.count());
    }
}

// ── vtListen: UnsupportedLocator for non-TCP locator ─────────────────────────

test "tcp transport: vtListen rejects non-TCP locator" {
    const alloc = testing.allocator;
    const t_ptr = try TcpTransport.init(alloc, .{});
    defer t_ptr.deinit();
    const t = t_ptr.transport();

    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    try testing.expectError(error.UnsupportedLocator, t.listen(&Locator.udp4(.{ 0, 0, 0, 0 }, 7400), h));
}

// ── vtUnicastLocators: empty before listen, populated after ──────────────────

test "tcp transport: unicastLocators before and after listen" {
    const alloc = testing.allocator;

    const tcp = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer tcp.deinit();
    const t = tcp.transport();

    var locs: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs.deinit(alloc);

    try t.unicastLocators(&locs, alloc);
    try testing.expectEqual(@as(usize, 0), locs.items.len);

    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    const listen_loc = Locator.tcp4(.{ 127, 0, 0, 1 }, 0);
    try t.listen(&listen_loc, h);

    try t.unicastLocators(&locs, alloc);
    try testing.expectEqual(@as(usize, 1), locs.items.len);
    try testing.expectEqual(@as(u8, 127), locs.items[0].tcp_v4.addr[0]);
    try testing.expect(locs.items[0].tcp_v4.port > 0);
}

// ── vtClose via Transport interface ──────────────────────────────────────────

test "tcp transport: vtClose tears down via vtable" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{});
    const t = tcp.transport();
    t.close(); // calls deinit(); do NOT call tcp.deinit() again
}

// ── vtJoinMulticast / vtLeaveMulticast ────────────────────────────────────────

test "tcp transport: joinMulticast returns UnsupportedOperation" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{});
    defer tcp.deinit();
    const t = tcp.transport();
    const mc = Locator.udp4(.{ 239, 255, 0, 1 }, 7400);
    try testing.expectError(error.UnsupportedOperation, t.joinMulticast(&mc));
}

test "tcp transport: leaveMulticast is a no-op" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{});
    defer tcp.deinit();
    const t = tcp.transport();
    const mc = Locator.udp4(.{ 239, 255, 0, 1 }, 7400);
    t.leaveMulticast(&mc); // must not crash
}

// ── vtSetLocatorChangeHandler ─────────────────────────────────────────────────

test "tcp transport: vtSetLocatorChangeHandler sets and clears" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{});
    defer tcp.deinit();
    const t = tcp.transport();

    var fired: bool = false;
    const h = iface.LocatorChangeHandler{
        .ctx = &fired,
        .on_change = struct {
            fn f(ctx: *anyopaque) void {
                const b: *bool = @ptrCast(@alignCast(ctx));
                b.* = true;
            }
        }.f,
    };
    t.setLocatorChangeHandler(h);
    try testing.expect(tcp.locator_change_handler != null);
    t.setLocatorChangeHandler(null);
    try testing.expect(tcp.locator_change_handler == null);
}

// ── vtListen PortConflict rolls back handler ──────────────────────────────────

test "tcp transport: vtListen PortConflict rolls back handler" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer tcp.deinit();
    const t = tcp.transport();

    var sentinel_a: u8 = 0;
    var sentinel_b: u8 = 0;
    const noop = struct {
        fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
    }.f;
    const ha = iface.ReceiveHandler{ .ctx = &sentinel_a, .on_receive = noop };
    const hb = iface.ReceiveHandler{ .ctx = &sentinel_b, .on_receive = noop };

    // First listen: binds to an OS-assigned port.
    const port = try listenAndGetPort(t, ha, alloc);
    defer t.unlisten(&Locator.tcp4(.{ 127, 0, 0, 1 }, port), ha);

    // Listen on a different port — must return PortConflict and NOT register hb.
    const conflict_loc = Locator.tcp4(.{ 127, 0, 0, 1 }, port +% 1);
    try testing.expectError(error.PortConflict, t.listen(&conflict_loc, hb));

    // handlers list must still contain only ha.
    tcp.handler_mu.lock();
    defer tcp.handler_mu.unlock();
    try testing.expectEqual(@as(usize, 1), tcp.handlers.items.len);
    try testing.expectEqual(sentinel_a, @as(*u8, @ptrCast(@alignCast(tcp.handlers.items[0].ctx))).*);
}

// ── MessageTooLarge on oversized send ─────────────────────────────────────────

test "tcp transport: vtSend rejects message larger than MAX_MSG_LEN" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{});
    defer tcp.deinit();
    const t = tcp.transport();

    // Fake oversized slice: size check fires before any I/O so the pointer is never read.
    const ptr: [*]const u8 = @ptrFromInt(0x1000);
    const huge: []const u8 = ptr[0 .. 4 * 1024 * 1024 + 1];
    const dest = Locator.tcp4(.{ 127, 0, 0, 1 }, 1);
    try testing.expectError(error.MessageTooLarge, t.send(&dest, huge));
}

// ── vtSend to non-listening port returns ConnectFailed ───────────────────────

test "tcp transport: vtSend returns ConnectFailed when no server" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{});
    defer tcp.deinit();
    const t = tcp.transport();
    // Port 1 is privileged and never has a listener in test environments.
    const dest = Locator.tcp4(.{ 127, 0, 0, 1 }, 1);
    try testing.expectError(error.ConnectFailed, t.send(&dest, "hello"));
}

// ── vtListen BindFailed rolls back handler ────────────────────────────────────

test "tcp transport: vtListen BindFailed rolls back registered handler" {
    const alloc = testing.allocator;
    // 192.0.2.x is TEST-NET-1 (RFC 5737): routable but never local, so bind fails.
    const tcp = try TcpTransport.init(alloc, .{ .bind_address = "192.0.2.1" });
    defer tcp.deinit();
    const t = tcp.transport();

    var sentinel: u8 = 0;
    const h = ReceiveHandler{
        .ctx = &sentinel,
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    };
    const loc = Locator.tcp4(.{ 192, 0, 2, 1 }, 0);
    try testing.expectError(error.BindFailed, t.listen(&loc, h));

    // Handler must have been rolled back — handlers list must be empty.
    tcp.handler_mu.lock();
    defer tcp.handler_mu.unlock();
    try testing.expectEqual(@as(usize, 0), tcp.handlers.items.len);
}

// ── IPv6 with empty bind_address defaults to ::1 for advertisement ────────────

test "tcp transport: IPv6 listen with empty bind_address advertises ::1" {
    const alloc = testing.allocator;
    const tcp = try TcpTransport.init(alloc, .{}); // bind_address = ""
    defer tcp.deinit();
    const st = tcp.transport();

    var lo6 = std.mem.zeroes([16]u8);
    lo6[15] = 1; // ::1
    const port = listenAndGetPortV6(st, (ReceiveHandler{
        .ctx = @as(*anyopaque, @ptrCast(&lo6)),
        .on_receive = struct {
            fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
        }.f,
    }), alloc) catch |err| switch (err) {
        error.BindFailed => return, // IPv6 not available on this host
        else => return err,
    };

    var locs: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs.deinit(alloc);
    try st.unicastLocators(&locs, alloc);
    try testing.expectEqual(@as(usize, 1), locs.items.len);
    try testing.expect(locs.items[0] == .tcp_v6);
    // empty bind_address → listen_addr defaults to ::1
    try testing.expectEqual(@as(u8, 1), locs.items[0].tcp_v6.addr[15]);
    try testing.expectEqual(port, locs.items[0].tcp_v6.port);
}

// ── Connection recovery: re-dial after connection close ──────────────────────

test "tcp transport: connection recovery after fd close" {
    const alloc = testing.allocator;

    const server = try TcpTransport.init(alloc, .{ .bind_address = "127.0.0.1" });
    defer server.deinit();
    const st = server.transport();

    var count: usize = 0;
    const Counter = struct {
        n: *usize,
        fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.n.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
    };
    var ctr = Counter{ .n = &count };

    const port = try listenAndGetPort(st, ctr.handler(), alloc);
    defer st.unlisten(&Locator.tcp4(.{ 127, 0, 0, 1 }, port), ctr.handler());

    sleepMs(20);

    const client = try TcpTransport.init(alloc, .{ .reuse_connection_by_host = false });
    defer client.deinit();
    const ct = client.transport();

    const dest = Locator.tcp4(.{ 127, 0, 0, 1 }, port);

    // Initial send establishes a connection.
    try ct.send(&dest, "first");
    sleepMs(100);
    try testing.expectEqual(@as(usize, 1), count);

    // Close the client-side connection fd to simulate network failure.
    // vtSend will detect the write failure on next send and re-dial.
    {
        client.conn_mu.lock();
        var key = tcp_mod.RemoteKey{ .addr = std.mem.zeroes([16]u8), .port = port, .family = .v4 };
        @memcpy(key.addr[0..4], &[_]u8{ 127, 0, 0, 1 });
        const conn = client.connections.get(key);
        if (conn) |co| _ = std.c.close(co.fd);
        client.conn_mu.unlock();
    }

    // Send again — vtSend detects the dead connection, re-dials, and succeeds.
    // (No sleep needed: vtSend retries on write failure.)
    try ct.send(&dest, "second");
    sleepMs(100);
    try testing.expectEqual(@as(usize, 2), count);
}

// ── IPv6 loopback send + receive ──────────────────────────────────────────────

test "tcp transport: IPv6 loopback send and receive" {
    const alloc = testing.allocator;

    var lo6 = std.mem.zeroes([16]u8);
    lo6[15] = 1; // ::1

    const server = try TcpTransport.init(alloc, .{ .bind_address = "::1" });
    defer server.deinit();
    const st = server.transport();

    var received: []u8 = &.{};
    var recv_count: usize = 0;

    const Ctx = struct {
        buf: *[]u8,
        count: *usize,
        alloc: std.mem.Allocator,

        fn onRecv(ctx: *anyopaque, data: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.alloc.free(self.buf.*);
            self.buf.* = self.alloc.dupe(u8, data) catch &.{};
            self.count.* += 1;
        }
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv };
        }
    };
    var ctx = Ctx{ .buf = &received, .count = &recv_count, .alloc = alloc };

    const port = listenAndGetPortV6(st, ctx.handler(), alloc) catch |err| switch (err) {
        error.BindFailed => return, // IPv6 loopback not available on this system
        else => return err,
    };
    defer st.unlisten(&Locator.tcp6(lo6, port), ctx.handler());

    // Verify vtUnicastLocators returns a tcp_v6 locator.
    {
        var locs: std.ArrayListUnmanaged(Locator) = .empty;
        defer locs.deinit(alloc);
        try st.unicastLocators(&locs, alloc);
        try testing.expectEqual(@as(usize, 1), locs.items.len);
        try testing.expect(locs.items[0] == .tcp_v6);
        try testing.expectEqual(lo6, locs.items[0].tcp_v6.addr);
        try testing.expectEqual(port, locs.items[0].tcp_v6.port);
    }

    sleepMs(20);

    const client = try TcpTransport.init(alloc, .{});
    defer client.deinit();
    const ct = client.transport();

    const dest = Locator.tcp6(lo6, port);
    try ct.send(&dest, "Hello IPv6 TCP");

    sleepMs(100);

    try testing.expectEqual(@as(usize, 1), recv_count);
    try testing.expectEqualSlices(u8, "Hello IPv6 TCP", received);

    alloc.free(received);
}
