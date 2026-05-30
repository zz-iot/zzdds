const std = @import("std");
const zzdds = @import("zzdds");
const lossy_mod = zzdds.lossy_transport;
const iface = zzdds.transport;

const LossyTransport = lossy_mod.LossyTransport;
const DropEveryNth = lossy_mod.DropEveryNth;
const DropFirst = lossy_mod.DropFirst;
const DropNone = lossy_mod.DropNone;
const Locator = iface.Locator;
const Transport = iface.Transport;
const ReceiveHandler = iface.ReceiveHandler;
const LocatorChangeHandler = iface.LocatorChangeHandler;

const testing = std.testing;

// ── Stub inner transport ──────────────────────────────────────────────────────
//
// Records every vtable call so tests can assert which methods were invoked.

const StubCtx = struct {
    sends: usize = 0,
    listens: usize = 0,
    unlistens: usize = 0,
    joins: usize = 0,
    leaves: usize = 0,
    unicast_queries: usize = 0,
    handler_sets: usize = 0,
    closes: usize = 0,

    fn vtCanReach(_: *anyopaque, _: *const Locator) bool {
        return true;
    }
    fn vtSend(ctx: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {
        cast(ctx).sends += 1;
    }
    fn vtListen(ctx: *anyopaque, _: *const Locator, _: ReceiveHandler) anyerror!void {
        cast(ctx).listens += 1;
    }
    fn vtJoinMulticast(ctx: *anyopaque, _: *const Locator) anyerror!void {
        cast(ctx).joins += 1;
    }
    fn vtLeaveMulticast(ctx: *anyopaque, _: *const Locator) void {
        cast(ctx).leaves += 1;
    }
    fn vtUnlisten(ctx: *anyopaque, _: *const Locator, _: ReceiveHandler) void {
        cast(ctx).unlistens += 1;
    }
    fn vtUnicastLocators(ctx: *anyopaque, _: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
        cast(ctx).unicast_queries += 1;
    }
    fn vtSetLocatorChangeHandler(ctx: *anyopaque, _: ?LocatorChangeHandler) void {
        cast(ctx).handler_sets += 1;
    }
    fn vtClose(ctx: *anyopaque) void {
        cast(ctx).closes += 1;
    }

    fn cast(ctx: *anyopaque) *StubCtx {
        return @ptrCast(@alignCast(ctx));
    }

    const vtable = Transport.Vtable{
        .capabilities = .{},
        .can_reach = vtCanReach,
        .send = vtSend,
        .listen = vtListen,
        .join_multicast = vtJoinMulticast,
        .leave_multicast = vtLeaveMulticast,
        .unlisten = vtUnlisten,
        .unicast_locators = vtUnicastLocators,
        .set_locator_change_handler = vtSetLocatorChangeHandler,
        .close = vtClose,
    };

    pub fn transport(self: *StubCtx) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const dummy_loc = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 1234 } };
const dummy_handler = ReceiveHandler{ .ctx = @ptrFromInt(1), .on_receive = struct {
    fn f(_: *anyopaque, _: []const u8, _: Locator) void {}
}.f };

// ── DropFirst ─────────────────────────────────────────────────────────────────

test "DropFirst: drops first N then forwards all subsequent" {
    var stub = StubCtx{};
    var policy = DropFirst.init(3);
    const lossy = try LossyTransport.init(testing.allocator, stub.transport(), policy.packetPolicy());
    defer lossy.deinit(testing.allocator);
    const t = lossy.transport();

    // Send 6 packets; first 3 dropped (seq 1,2,3), next 3 forwarded (seq 4,5,6).
    for (0..6) |_| try t.send(&dummy_loc, &[_]u8{0xAA});

    try testing.expectEqual(@as(usize, 3), stub.sends);
    try testing.expectEqual(@as(u64, 3), lossy.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), lossy.sent.load(.monotonic));
}

test "DropFirst: n=0 forwards all" {
    var stub = StubCtx{};
    var policy = DropFirst.init(0);
    const lossy = try LossyTransport.init(testing.allocator, stub.transport(), policy.packetPolicy());
    defer lossy.deinit(testing.allocator);
    const t = lossy.transport();

    for (0..4) |_| try t.send(&dummy_loc, &[_]u8{0xBB});

    try testing.expectEqual(@as(usize, 4), stub.sends);
    try testing.expectEqual(@as(u64, 0), lossy.dropped.load(.monotonic));
}

// ── Pass-through vtable methods ───────────────────────────────────────────────

test "LossyTransport: pass-through vtable methods reach inner transport" {
    var stub = StubCtx{};
    var policy = DropNone{};
    const lossy = try LossyTransport.init(testing.allocator, stub.transport(), policy.packetPolicy());
    defer lossy.deinit(testing.allocator);
    const t = lossy.transport();

    // canReach passes through.
    try testing.expect(t.canReach(&dummy_loc));

    // listen passes through.
    try t.listen(&dummy_loc, dummy_handler);
    try testing.expectEqual(@as(usize, 1), stub.listens);

    // joinMulticast passes through.
    const mc_loc = Locator{ .udp_v4 = .{ .addr = .{ 239, 255, 0, 1 }, .port = 7400 } };
    try t.joinMulticast(&mc_loc);
    try testing.expectEqual(@as(usize, 1), stub.joins);

    // leaveMulticast passes through.
    t.leaveMulticast(&mc_loc);
    try testing.expectEqual(@as(usize, 1), stub.leaves);

    // unlisten passes through.
    t.unlisten(&dummy_loc, dummy_handler);
    try testing.expectEqual(@as(usize, 1), stub.unlistens);

    // unicastLocators passes through.
    var out: std.ArrayListUnmanaged(Locator) = .empty;
    defer out.deinit(testing.allocator);
    try t.unicastLocators(&out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), stub.unicast_queries);

    // setLocatorChangeHandler passes through.
    t.setLocatorChangeHandler(null);
    try testing.expectEqual(@as(usize, 1), stub.handler_sets);

    // close passes through.
    t.close();
    try testing.expectEqual(@as(usize, 1), stub.closes);
}
