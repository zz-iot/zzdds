//! In-process mock transport for deterministic RTPS testing.
//!
//! Replaces real UDP sockets with an in-memory packet queue. Tests drive
//! delivery explicitly via `deliver()` or `MockNetwork.deliverAll()` rather
//! than relying on background receive threads or wall-clock timing.
//!
//! Routing model:
//!   Unicast:   matched by IP address (not port). Port dispatch happens in
//!              deliver() via the registered handler map.
//!   Multicast: matched by full group locator (address + port), mirroring how
//!              join_multicast() subscribes to a specific (addr, port) pair.
//!              Senders also receive their own multicast (IP_MULTICAST_LOOP = on).
//!
//! Lock order: MockNetwork.mu -> MockTransport.mu. Never reversed.

const std = @import("std");
const iface = @import("interface.zig");
const mutex_mod = @import("../util/mutex.zig");

pub const Locator = iface.Locator;
pub const LocatorKind = iface.LocatorKind;
pub const Transport = iface.Transport;
pub const ReceiveHandler = iface.ReceiveHandler;
pub const LocatorChangeHandler = iface.LocatorChangeHandler;

// ── MockNetwork ───────────────────────────────────────────────────────────────

/// Shared routing fabric for a set of MockTransport instances.
/// Create one network per test scenario; create transports from it.
pub const MockNetwork = struct {
    alloc: std.mem.Allocator,
    mu: mutex_mod.Mutex,
    members: std.ArrayListUnmanaged(*MockTransport),
    config: Config,
    send_count: u64,

    pub const Config = struct {
        /// Drop every Nth packet sent through the network. 0 = never drop.
        drop_nth: u32 = 0,
        /// Deliver this many extra copies of each packet. 0 = single delivery.
        dupe_count: u32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator) !*MockNetwork {
        const self = try alloc.create(MockNetwork);
        self.* = .{
            .alloc = alloc,
            .mu = .{},
            .members = .empty,
            .config = .{},
            .send_count = 0,
        };
        return self;
    }

    pub fn deinit(self: *MockNetwork) void {
        self.members.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn setConfig(self: *MockNetwork, cfg: Config) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.config = cfg;
    }

    /// Deliver one round of queued packets across all member transports.
    /// Packets enqueued DURING this delivery (e.g. AckNack in response to HB)
    /// are NOT delivered until the next call — use a loop for multi-round exchanges.
    pub fn deliverAll(self: *MockNetwork) void {
        // Snapshot member list without holding the lock during deliver.
        // Transports are stable (test manages lifetimes explicitly).
        self.mu.lock();
        const count = self.members.items.len;
        var snapshot: [64]*MockTransport = undefined;
        const n = @min(count, snapshot.len);
        @memcpy(snapshot[0..n], self.members.items[0..n]);
        self.mu.unlock();

        for (snapshot[0..n]) |m| m.deliver();
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    fn join(self: *MockNetwork, t: *MockTransport) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.members.append(self.alloc, t);
    }

    fn leave(self: *MockNetwork, t: *MockTransport) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.members.items, 0..) |m, i| {
            if (m == t) {
                _ = self.members.swapRemove(i);
                return;
            }
        }
    }

    /// Route a packet to the appropriate transport(s).
    /// Holds network.mu while iterating; locks each member's mu briefly to check
    /// subscription state and enqueue. Lock order: network.mu → member.mu.
    fn route(self: *MockNetwork, locator: *const Locator, data: []const u8, src: Locator) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.config.drop_nth > 0) {
            self.send_count += 1;
            if (self.send_count % self.config.drop_nth == 0) return;
        }

        const copies: u32 = 1 + self.config.dupe_count;
        const is_mc = locator.isMulticast();

        for (self.members.items) |m| {
            m.mu.lock();
            const want = if (is_mc)
                m.hasJoinedGroupNoLock(locator)
            else
                m.ownsLocatorNoLock(locator);
            if (want) {
                for (0..copies) |_| m.enqueueNoLock(locator, data, src) catch {};
            }
            m.mu.unlock();
        }
    }
};

// ── MockTransport ─────────────────────────────────────────────────────────────

pub const MockTransport = struct {
    alloc: std.mem.Allocator,
    network: *MockNetwork,

    mu: mutex_mod.Mutex,
    handlers: std.AutoHashMapUnmanaged(u32, ReceiveHandler),
    mc_groups: std.ArrayListUnmanaged(Locator),
    queue: std.ArrayListUnmanaged(Packet),
    /// Locators reported to the RTPS layer via unicast_locators().
    /// The IP addresses in these locators are used for address-based routing.
    unicast_locs: std.ArrayListUnmanaged(Locator),
    locator_change_handler: ?LocatorChangeHandler,

    const Packet = struct {
        dest_port: u32,
        data: []u8, // heap-owned by MockTransport.alloc
        src: Locator,
    };

    /// Create a new MockTransport joined to `network` with the given unicast locators.
    /// The test is responsible for choosing locators that are unique across the network
    /// and consistent with the RTPS port formula used by the DCPS layer above.
    pub fn init(
        alloc: std.mem.Allocator,
        network: *MockNetwork,
        locators: []const Locator,
    ) !*MockTransport {
        const self = try alloc.create(MockTransport);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .network = network,
            .mu = .{},
            .handlers = .empty,
            .mc_groups = .empty,
            .queue = .empty,
            .unicast_locs = .empty,
            .locator_change_handler = null,
        };
        for (locators) |loc| try self.unicast_locs.append(alloc, loc);
        try network.join(self);
        return self;
    }

    pub fn deinit(self: *MockTransport) void {
        self.network.leave(self);
        for (self.queue.items) |pkt| self.alloc.free(pkt.data);
        self.queue.deinit(self.alloc);
        self.mc_groups.deinit(self.alloc);
        self.handlers.deinit(self.alloc);
        self.unicast_locs.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn transport(self: *MockTransport) Transport {
        return .{ .ctx = self, .vtable = &mock_vtable };
    }

    /// Deliver all packets currently in the queue to their registered handlers.
    /// Uses snapshot semantics: packets enqueued during this call (e.g. an AckNack
    /// sent in response to a received Heartbeat) are queued for the NEXT deliver().
    pub fn deliver(self: *MockTransport) void {
        self.mu.lock();
        var snap = self.queue;
        self.queue = .empty;
        self.mu.unlock();

        defer {
            for (snap.items) |pkt| self.alloc.free(pkt.data);
            snap.deinit(self.alloc);
        }

        for (snap.items) |pkt| {
            const h: ?ReceiveHandler = blk: {
                self.mu.lock();
                defer self.mu.unlock();
                break :blk self.handlers.get(pkt.dest_port);
            };
            if (h) |handler| handler.on_receive(handler.ctx, pkt.data, pkt.src);
        }
    }

    /// Number of packets waiting to be delivered. Useful for test assertions.
    pub fn queueLen(self: *MockTransport) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.queue.items.len;
    }

    // ── Internal helpers (caller must hold self.mu) ───────────────────────────

    fn ownsLocatorNoLock(self: *const MockTransport, loc: *const Locator) bool {
        for (self.unicast_locs.items) |ul| {
            switch (ul) {
                .udp_v4 => |mine| switch (loc.*) {
                    .udp_v4 => |theirs| if (std.mem.eql(u8, &mine.addr, &theirs.addr)) return true,
                    else => {},
                },
                .udp_v6 => |mine| switch (loc.*) {
                    .udp_v6 => |theirs| if (std.mem.eql(u8, &mine.addr, &theirs.addr)) return true,
                    else => {},
                },
                else => {},
            }
        }
        return false;
    }

    fn hasJoinedGroupNoLock(self: *const MockTransport, group: *const Locator) bool {
        for (self.mc_groups.items) |g| {
            if (g.eql(group.*)) return true;
        }
        return false;
    }

    fn enqueueNoLock(self: *MockTransport, dest: *const Locator, data: []const u8, src: Locator) !void {
        const port: u32 = switch (dest.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        const copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(copy);
        try self.queue.append(self.alloc, .{ .dest_port = port, .data = copy, .src = src });
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtCanReach(_: *anyopaque, loc: *const Locator) bool {
        return switch (loc.*) {
            .udp_v4, .udp_v6 => true,
            else => false,
        };
    }

    fn vtSend(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        const src: Locator = blk: {
            self.mu.lock();
            defer self.mu.unlock();
            break :blk if (self.unicast_locs.items.len > 0)
                self.unicast_locs.items[0]
            else
                .invalid;
        };
        self.network.route(loc, data, src);
    }

    fn vtListen(ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) anyerror!void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return error.UnsupportedLocatorKind,
        };
        self.mu.lock();
        defer self.mu.unlock();
        const r = try self.handlers.getOrPut(self.alloc, port);
        if (r.found_existing) return error.PortAlreadyListening;
        r.value_ptr.* = handler;
    }

    fn vtJoinMulticast(ctx: *anyopaque, group: *const Locator) anyerror!void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        try self.mc_groups.append(self.alloc, group.*);
    }

    fn vtLeaveMulticast(ctx: *anyopaque, group: *const Locator) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        var i = self.mc_groups.items.len;
        while (i > 0) {
            i -= 1;
            if (self.mc_groups.items[i].eql(group.*)) _ = self.mc_groups.swapRemove(i);
        }
    }

    fn vtUnlisten(ctx: *anyopaque, locator: *const Locator, _: ReceiveHandler) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        self.mu.lock();
        defer self.mu.unlock();
        _ = self.handlers.remove(port);
    }

    fn vtUnicastLocators(ctx: *anyopaque, out: *std.ArrayListUnmanaged(Locator), alloc: std.mem.Allocator) anyerror!void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        out.clearRetainingCapacity();
        try out.appendSlice(alloc, self.unicast_locs.items);
    }

    fn vtSetLocatorChangeHandler(ctx: *anyopaque, handler: ?LocatorChangeHandler) void {
        const self: *MockTransport = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        self.locator_change_handler = handler;
    }

    /// The mock transport's lifetime is managed by the test via deinit().
    /// vtClose is a no-op so the DCPS layer cannot destroy the transport from under the test.
    fn vtClose(_: *anyopaque) void {}
};

const mock_vtable = Transport.Vtable{
    .capabilities = .{ .unicast = true, .multicast = true },
    .can_reach = MockTransport.vtCanReach,
    .send = MockTransport.vtSend,
    .listen = MockTransport.vtListen,
    .join_multicast = MockTransport.vtJoinMulticast,
    .leave_multicast = MockTransport.vtLeaveMulticast,
    .unlisten = MockTransport.vtUnlisten,
    .unicast_locators = MockTransport.vtUnicastLocators,
    .set_locator_change_handler = MockTransport.vtSetLocatorChangeHandler,
    .close = MockTransport.vtClose,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const IP_A = [4]u8{ 127, 0, 0, 1 };
const IP_B = [4]u8{ 127, 0, 0, 2 };
const IP_C = [4]u8{ 127, 0, 0, 3 };
const MC_GROUP = Locator{ .udp_v4 = .{ .addr = .{ 239, 255, 0, 1 }, .port = 7400 } };

/// Simple receive-counting handler for tests.
const Counter = struct {
    count: usize = 0,
    last: [256]u8 = undefined,
    last_n: usize = 0,

    fn handler(self: *Counter) ReceiveHandler {
        return .{ .ctx = self, .on_receive = onRecv };
    }

    fn onRecv(ctx: *anyopaque, data: []const u8, _: Locator) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_n = @min(data.len, self.last.len);
        @memcpy(self.last[0..self.last_n], data[0..self.last_n]);
    }
};

test "unicast: send reaches only the addressed transport" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var ca = Counter{};
    var cb = Counter{};
    try ta.transport().listen(&Locator.udp4(IP_A, 7410), ca.handler());
    try tb.transport().listen(&Locator.udp4(IP_B, 7412), cb.handler());

    const dest = Locator.udp4(IP_B, 7412);
    try ta.transport().send(&dest, "hello");

    net.deliverAll();

    try testing.expectEqual(@as(usize, 0), ca.count);
    try testing.expectEqual(@as(usize, 1), cb.count);
    try testing.expectEqualSlices(u8, "hello", cb.last[0..cb.last_n]);
}

test "unicast: any port on same IP is delivered, dispatch by port" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // Transport A listens on two ports.
    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var c_meta = Counter{};
    var c_data = Counter{};
    try ta.transport().listen(&Locator.udp4(IP_A, 7410), c_meta.handler());
    try ta.transport().listen(&Locator.udp4(IP_A, 7411), c_data.handler());

    // B sends to A's data port.
    const dest = Locator.udp4(IP_A, 7411);
    try tb.transport().send(&dest, "data");
    net.deliverAll();

    try testing.expectEqual(@as(usize, 0), c_meta.count);
    try testing.expectEqual(@as(usize, 1), c_data.count);
}

test "multicast: delivered to all joined transports including sender" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();
    const tc = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_C, 7414)});
    defer tc.deinit();

    var ca = Counter{};
    var cb = Counter{};
    // ta and tb join the multicast group and register a handler on port 7400.
    // tc does not join.
    try ta.transport().listen(&.{ .udp_v4 = .{ .addr = .{ 0, 0, 0, 0 }, .port = 7400 } }, ca.handler());
    try tb.transport().listen(&.{ .udp_v4 = .{ .addr = .{ 0, 0, 0, 0 }, .port = 7400 } }, cb.handler());
    try ta.transport().joinMulticast(&MC_GROUP);
    try tb.transport().joinMulticast(&MC_GROUP);

    // ta broadcasts on multicast.
    try ta.transport().send(&MC_GROUP, "spdp");
    net.deliverAll();

    // Both ta (sender) and tb (other member) receive; tc does not.
    try testing.expectEqual(@as(usize, 1), ca.count); // sender receives own multicast
    try testing.expectEqual(@as(usize, 1), cb.count);
}

test "multicast: leave stops delivery" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var ca = Counter{};
    var cb = Counter{};
    try ta.transport().listen(&.{ .udp_v4 = .{ .addr = .{ 0, 0, 0, 0 }, .port = 7400 } }, ca.handler());
    try tb.transport().listen(&.{ .udp_v4 = .{ .addr = .{ 0, 0, 0, 0 }, .port = 7400 } }, cb.handler());
    try ta.transport().joinMulticast(&MC_GROUP);
    try tb.transport().joinMulticast(&MC_GROUP);

    try ta.transport().send(&MC_GROUP, "before");
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), cb.count);

    tb.transport().leaveMulticast(&MC_GROUP);

    try ta.transport().send(&MC_GROUP, "after");
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), cb.count); // no new delivery
}

test "drop_nth: every Nth packet is dropped" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    net.setConfig(.{ .drop_nth = 2 });

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var cb = Counter{};
    try tb.transport().listen(&Locator.udp4(IP_B, 7412), cb.handler());

    const dest = Locator.udp4(IP_B, 7412);
    for (0..4) |_| try ta.transport().send(&dest, "x");
    net.deliverAll();

    // Sends 1,2,3,4 → drops 2 and 4 → 2 delivered.
    try testing.expectEqual(@as(usize, 2), cb.count);
}

test "dupe_count: each packet delivered N+1 times" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();
    net.setConfig(.{ .dupe_count = 2 });

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var cb = Counter{};
    try tb.transport().listen(&Locator.udp4(IP_B, 7412), cb.handler());

    const dest = Locator.udp4(IP_B, 7412);
    try ta.transport().send(&dest, "x");
    net.deliverAll();

    try testing.expectEqual(@as(usize, 3), cb.count); // 1 original + 2 dupes
}

test "snapshot semantics: packets from this deliver() don't arrive until next" {
    // A sends to B. B's handler sends back to A. The reply should be in A's
    // queue AFTER this deliverAll() and arrive only on the NEXT deliverAll().
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var ca = Counter{};
    try ta.transport().listen(&Locator.udp4(IP_A, 7410), ca.handler());

    // B's handler sends a reply to A when it receives a packet.
    const ReplyCtx = struct {
        transport: Transport,
        dest: Locator,
    };
    var reply_ctx = ReplyCtx{
        .transport = tb.transport(),
        .dest = Locator.udp4(IP_A, 7410),
    };
    const reply_handler = ReceiveHandler{
        .ctx = &reply_ctx,
        .on_receive = struct {
            fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
                const rc: *ReplyCtx = @ptrCast(@alignCast(ctx));
                rc.transport.send(&rc.dest, "reply") catch {};
            }
        }.f,
    };
    try tb.transport().listen(&Locator.udp4(IP_B, 7412), reply_handler);

    // A sends to B.
    try ta.transport().send(&Locator.udp4(IP_B, 7412), "ping");

    // First deliverAll: B receives "ping", sends "reply" (enqueued for A).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), ca.count); // A has not received reply yet

    // Second deliverAll: A receives "reply".
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), ca.count);
    try testing.expectEqualSlices(u8, "reply", ca.last[0..ca.last_n]);
}

test "no handler: unregistered port is silently discarded" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    // No listen() call on tb. Send from ta should not crash.
    try ta.transport().send(&Locator.udp4(IP_B, 9999), "x");
    net.deliverAll(); // silently discards
}

test "queueLen reflects pending packet count" {
    const alloc = testing.allocator;
    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const ta = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_A, 7410)});
    defer ta.deinit();
    const tb = try MockTransport.init(alloc, net, &.{Locator.udp4(IP_B, 7412)});
    defer tb.deinit();

    var cb = Counter{};
    try tb.transport().listen(&Locator.udp4(IP_B, 7412), cb.handler());

    try ta.transport().send(&Locator.udp4(IP_B, 7412), "a");
    try ta.transport().send(&Locator.udp4(IP_B, 7412), "b");
    try testing.expectEqual(@as(usize, 2), tb.queueLen());

    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), tb.queueLen());
    try testing.expectEqual(@as(usize, 2), cb.count);
}
