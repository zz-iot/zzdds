//! Lossy transport shim for deterministic fault-injection testing.
//!
//! Wraps any Transport and applies a PacketPolicy to each outgoing send().
//! All other vtable calls pass through to the inner transport unchanged.
//!
//! The send sequence counter is 1-indexed and increments on every send()
//! regardless of whether the packet is dropped, making drop patterns
//! deterministic and reproducible across runs.
//!
//! Typical use:
//!   var policy = LossyTransport.DropEveryNth.init(3);
//!   var lossy = try LossyTransport.init(alloc, inner, policy.packetPolicy());
//!   defer lossy.deinit(alloc);
//!   const t = lossy.transport();

const std = @import("std");
const iface = @import("interface.zig");

pub const Locator = iface.Locator;
pub const Transport = iface.Transport;
pub const ReceiveHandler = iface.ReceiveHandler;
pub const LocatorChangeHandler = iface.LocatorChangeHandler;

// ── PacketPolicy ──────────────────────────────────────────────────────────────

/// Pluggable drop/transform decision for each outgoing packet.
/// Returning true drops the packet; false forwards it to the inner transport.
///
/// `seq` is the 1-indexed send sequence number for this LossyTransport instance.
/// `locator` and `data` allow content- or destination-aware policies.
pub const PacketPolicy = struct {
    ctx: *anyopaque,
    should_drop: *const fn (
        ctx: *anyopaque,
        locator: *const Locator,
        data: []const u8,
        seq: u64,
    ) bool,
};

// ── Built-in policies ─────────────────────────────────────────────────────────

/// Drop every Nth outgoing packet (1-indexed: first drop at seq == n).
pub const DropEveryNth = struct {
    n: u64,

    pub fn init(n: u64) DropEveryNth {
        return .{ .n = n };
    }

    pub fn packetPolicy(self: *DropEveryNth) PacketPolicy {
        return .{ .ctx = self, .should_drop = shouldDrop };
    }

    fn shouldDrop(ctx: *anyopaque, _: *const Locator, _: []const u8, seq: u64) bool {
        const self: *DropEveryNth = @ptrCast(@alignCast(ctx));
        return self.n > 0 and seq % self.n == 0;
    }
};

/// Drop only the first N outgoing packets (those with seq ≤ n).
/// All subsequent packets are forwarded.  Thread-safe: n is immutable after init.
pub const DropFirst = struct {
    n: u64,

    pub fn init(n: u64) DropFirst {
        return .{ .n = n };
    }

    pub fn packetPolicy(self: *DropFirst) PacketPolicy {
        return .{ .ctx = self, .should_drop = shouldDrop };
    }

    fn shouldDrop(ctx: *anyopaque, _: *const Locator, _: []const u8, seq: u64) bool {
        const self: *const DropFirst = @ptrCast(@alignCast(ctx));
        return seq <= self.n;
    }
};

/// Pass all packets through (useful for parameterised test scaffolding).
pub const DropNone = struct {
    pub fn packetPolicy(self: *DropNone) PacketPolicy {
        return .{ .ctx = self, .should_drop = shouldDrop };
    }

    fn shouldDrop(_: *anyopaque, _: *const Locator, _: []const u8, _: u64) bool {
        return false;
    }
};

// ── LossyTransport ────────────────────────────────────────────────────────────

pub const LossyTransport = struct {
    inner: Transport,
    policy: PacketPolicy,
    /// Monotonically increasing send sequence (1-indexed).
    send_seq: std.atomic.Value(u64),
    /// Total packets forwarded.
    sent: std.atomic.Value(u64),
    /// Total packets dropped.
    dropped: std.atomic.Value(u64),

    pub fn init(
        alloc: std.mem.Allocator,
        inner: Transport,
        policy: PacketPolicy,
    ) !*LossyTransport {
        const self = try alloc.create(LossyTransport);
        self.* = .{
            .inner = inner,
            .policy = policy,
            .send_seq = std.atomic.Value(u64).init(0),
            .sent = std.atomic.Value(u64).init(0),
            .dropped = std.atomic.Value(u64).init(0),
        };
        return self;
    }

    pub fn deinit(self: *LossyTransport, alloc: std.mem.Allocator) void {
        alloc.destroy(self);
    }

    pub fn transport(self: *LossyTransport) Transport {
        return .{ .ctx = self, .vtable = &lossy_vtable };
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtCanReach(ctx: *anyopaque, loc: *const Locator) bool {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.can_reach(self.inner.ctx, loc);
    }

    fn vtSend(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        const seq = self.send_seq.fetchAdd(1, .monotonic) + 1; // 1-indexed
        if (self.policy.should_drop(self.policy.ctx, loc, data, seq)) {
            _ = self.dropped.fetchAdd(1, .monotonic);
            return;
        }
        _ = self.sent.fetchAdd(1, .monotonic);
        return self.inner.vtable.send(self.inner.ctx, loc, data);
    }

    fn vtListen(ctx: *anyopaque, loc: *const Locator, h: ReceiveHandler) anyerror!void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.listen(self.inner.ctx, loc, h);
    }

    fn vtJoinMulticast(ctx: *anyopaque, loc: *const Locator) anyerror!void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.join_multicast(self.inner.ctx, loc);
    }

    fn vtLeaveMulticast(ctx: *anyopaque, loc: *const Locator) void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        self.inner.vtable.leave_multicast(self.inner.ctx, loc);
    }

    fn vtUnlisten(ctx: *anyopaque, loc: *const Locator, h: ReceiveHandler) void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        self.inner.vtable.unlisten(self.inner.ctx, loc, h);
    }

    fn vtUnicastLocators(
        ctx: *anyopaque,
        out: *std.ArrayListUnmanaged(Locator),
        alloc: std.mem.Allocator,
    ) anyerror!void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        return self.inner.vtable.unicast_locators(self.inner.ctx, out, alloc);
    }

    fn vtSetLocatorChangeHandler(ctx: *anyopaque, h: ?LocatorChangeHandler) void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        self.inner.vtable.set_locator_change_handler(self.inner.ctx, h);
    }

    fn vtClose(ctx: *anyopaque) void {
        const self: *LossyTransport = @ptrCast(@alignCast(ctx));
        self.inner.vtable.close(self.inner.ctx);
    }
};

const lossy_vtable = Transport.Vtable{
    .capabilities = .{},
    .can_reach = LossyTransport.vtCanReach,
    .send = LossyTransport.vtSend,
    .listen = LossyTransport.vtListen,
    .join_multicast = LossyTransport.vtJoinMulticast,
    .leave_multicast = LossyTransport.vtLeaveMulticast,
    .unlisten = LossyTransport.vtUnlisten,
    .unicast_locators = LossyTransport.vtUnicastLocators,
    .set_locator_change_handler = LossyTransport.vtSetLocatorChangeHandler,
    .close = LossyTransport.vtClose,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

// Minimal inner transport that records every send() call.
const RecordingCtx = struct {
    sends: std.ArrayListUnmanaged([]const u8) = .empty,

    fn deinit(self: *RecordingCtx, alloc: std.mem.Allocator) void {
        for (self.sends.items) |s| alloc.free(s);
        self.sends.deinit(alloc);
    }

    fn vtSend(ctx: *anyopaque, _: *const Locator, data: []const u8) anyerror!void {
        const self: *RecordingCtx = @ptrCast(@alignCast(ctx));
        // Store a copy so the test can inspect it after the call.
        const copy = try testing.allocator.dupe(u8, data);
        try self.sends.append(testing.allocator, copy);
    }

    fn vtCanReach(_: *anyopaque, _: *const Locator) bool {
        return true;
    }
    fn vtListen(_: *anyopaque, _: *const Locator, _: ReceiveHandler) anyerror!void {}
    fn vtJoinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
    fn vtLeaveMulticast(_: *anyopaque, _: *const Locator) void {}
    fn vtUnlisten(_: *anyopaque, _: *const Locator, _: ReceiveHandler) void {}
    fn vtUnicastLocators(_: *anyopaque, _: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {}
    fn vtSetLocatorChangeHandler(_: *anyopaque, _: ?LocatorChangeHandler) void {}
    fn vtClose(_: *anyopaque) void {}

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

    pub fn transport(self: *RecordingCtx) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

const dummy_locator = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 1234 } };

test "DropNone forwards all packets" {
    var rec = RecordingCtx{};
    defer rec.deinit(testing.allocator);

    var policy = DropNone{};
    const lossy = try LossyTransport.init(testing.allocator, rec.transport(), policy.packetPolicy());
    defer lossy.deinit(testing.allocator);
    const t = lossy.transport();

    for (0..5) |_| try t.send(&dummy_locator, &[_]u8{0xAA});

    try testing.expectEqual(@as(usize, 5), rec.sends.items.len);
    try testing.expectEqual(@as(u64, 5), lossy.sent.load(.monotonic));
    try testing.expectEqual(@as(u64, 0), lossy.dropped.load(.monotonic));
}

test "DropEveryNth drops every Nth packet" {
    var rec = RecordingCtx{};
    defer rec.deinit(testing.allocator);

    var policy = DropEveryNth.init(3);
    const lossy = try LossyTransport.init(testing.allocator, rec.transport(), policy.packetPolicy());
    defer lossy.deinit(testing.allocator);
    const t = lossy.transport();

    // Send 9 packets; expect drops at seq 3, 6, 9 → 6 forwarded, 3 dropped.
    for (0..9) |_| try t.send(&dummy_locator, &[_]u8{0xBB});

    try testing.expectEqual(@as(usize, 6), rec.sends.items.len);
    try testing.expectEqual(@as(u64, 6), lossy.sent.load(.monotonic));
    try testing.expectEqual(@as(u64, 3), lossy.dropped.load(.monotonic));
}

test "DropEveryNth send_seq increments even for dropped packets" {
    var rec = RecordingCtx{};
    defer rec.deinit(testing.allocator);

    var policy = DropEveryNth.init(2);
    const lossy = try LossyTransport.init(testing.allocator, rec.transport(), policy.packetPolicy());
    defer lossy.deinit(testing.allocator);
    const t = lossy.transport();

    for (0..4) |_| try t.send(&dummy_locator, &[_]u8{0xCC});

    // seq 1 → forward, 2 → drop, 3 → forward, 4 → drop
    try testing.expectEqual(@as(usize, 2), rec.sends.items.len);
    try testing.expectEqual(@as(u64, 4), lossy.send_seq.load(.monotonic));
}
