//! In-process memory transport for deterministic DCPS testing.
//!
//! Replaces real sockets with a shared in-process port-to-handler map.
//! Unlike MockTransport, send() delivers synchronously — no queue, no pump
//! needed. This makes test assertions immediate without a deliverAll() loop.
//!
//! Routing model:
//!   Each MemoryTransport has a unique fake udp_v4 address derived from its
//!   participant_id:
//!     address  = 10.(id>>16).(id>>8).(id+1) (wrapping, big-endian octets)
//!     meta port = 7410 + 2 * participant_id   (RTPS formula, domain 0)
//!   participant.zig derives data port = meta_port + 1 via the udp config
//!   port-offset delta and calls transport.listen() on that data port.
//!   send() routes by destination port via the shared MemoryBus handler map.
//!
//! RELIABLE caveat:
//!   StatefulWriter holds its mutex during write() and sends an inline
//!   HEARTBEAT only to RELIABLE reader proxies (writer_sm.zig guards the call
//!   with `if (rp.reliable)`). For BEST_EFFORT QoS, delivery is deadlock-free.
//!   RELIABLE QoS tests should use MockTransport until writer_sm locking is
//!   refactored to release the lock before calling transport.send().
//!
//! See also: discovery/direct.zig, delivery/intraprocess.zig

const std = @import("std");
const iface = @import("interface.zig");
const mutex_mod = @import("../util/mutex.zig");

pub const Locator = iface.Locator;
pub const Transport = iface.Transport;
pub const Capabilities = iface.Capabilities;
pub const ReceiveHandler = iface.ReceiveHandler;
pub const LocatorChangeHandler = iface.LocatorChangeHandler;

// ── MemoryBus ─────────────────────────────────────────────────────────────────

/// Shared in-process routing fabric for a set of MemoryTransport instances.
/// Maintains a port→handler map; send() looks up and calls handlers synchronously.
/// Create one bus per test scenario (or per IntraProcessDelivery instance);
/// create transports from it via createTransport().
pub const MemoryBus = struct {
    alloc: std.mem.Allocator,
    mu: mutex_mod.Mutex,
    next_id: u32,
    handlers: std.AutoHashMapUnmanaged(u32, ReceiveHandler),

    pub fn init(alloc: std.mem.Allocator) !*MemoryBus {
        const self = try alloc.create(MemoryBus);
        self.* = .{
            .alloc = alloc,
            .mu = .{},
            .next_id = 0,
            .handlers = .empty,
        };
        return self;
    }

    pub fn deinit(self: *MemoryBus) void {
        self.handlers.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Create a new MemoryTransport connected to this bus.
    /// Assigns a sequential participant_id for port and address computation.
    /// Caller owns the returned transport; call deinit() when done.
    pub fn createTransport(self: *MemoryBus) !*MemoryTransport {
        self.mu.lock();
        const id = self.next_id;
        self.next_id += 1;
        self.mu.unlock();
        return MemoryTransport.init(self.alloc, self, id);
    }
};

// ── MemoryTransport ───────────────────────────────────────────────────────────

pub const MemoryTransport = struct {
    alloc: std.mem.Allocator,
    bus: *MemoryBus,
    participant_id: u32,
    unicast_locs: std.ArrayListUnmanaged(Locator),
    locator_change_handler: ?LocatorChangeHandler,

    /// Base meta-unicast port for participant 0 on domain 0 (RTPS §9.6.1.1).
    const BASE_META_PORT: u16 = 7410;
    /// Port stride between participants (participant_gain = 2 in default config).
    const PORT_STRIDE: u16 = 2;

    pub fn init(
        alloc: std.mem.Allocator,
        bus: *MemoryBus,
        participant_id: u32,
    ) !*MemoryTransport {
        const self = try alloc.create(MemoryTransport);
        errdefer alloc.destroy(self);
        self.* = .{
            .alloc = alloc,
            .bus = bus,
            .participant_id = participant_id,
            .unicast_locs = .empty,
            .locator_change_handler = null,
        };
        // Fake address: 10.(id>>16 & 0xFF).(id>>8 & 0xFF).((id & 0xFF) + 1)
        const fake_ip = [4]u8{
            10,
            @as(u8, @intCast((participant_id >> 16) & 0xFF)),
            @as(u8, @intCast((participant_id >> 8) & 0xFF)),
            @as(u8, @intCast(participant_id & 0xFF)) +% 1,
        };
        const meta_port = BASE_META_PORT +% PORT_STRIDE *% @as(u16, @intCast(participant_id & 0x7FFF));
        try self.unicast_locs.append(alloc, Locator.udp4(fake_ip, meta_port));
        return self;
    }

    pub fn deinit(self: *MemoryTransport) void {
        self.unicast_locs.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn transport(self: *MemoryTransport) Transport {
        return .{ .ctx = self, .vtable = &mem_vtable };
    }

    // ── Vtable implementations ────────────────────────────────────────────────

    fn vtCanReach(_: *anyopaque, loc: *const Locator) bool {
        return switch (loc.*) {
            .udp_v4, .udp_v6 => true,
            else => false,
        };
    }

    /// Deliver synchronously: look up the destination port in the bus handler
    /// map, copy the handler reference (lock released before calling), then
    /// invoke on_receive. No queueing, no threads.
    fn vtSend(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (loc.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        // Copy handler under lock so we can release before calling on_receive.
        self.bus.mu.lock();
        const handler: ?ReceiveHandler = self.bus.handlers.get(port);
        self.bus.mu.unlock();

        if (handler) |h| {
            const src: Locator = blk: {
                if (self.unicast_locs.items.len > 0)
                    break :blk self.unicast_locs.items[0];
                break :blk .invalid;
            };
            h.on_receive(h.ctx, data, src);
        }
    }

    fn vtListen(ctx: *anyopaque, locator: *const Locator, handler: ReceiveHandler) anyerror!void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return error.UnsupportedLocatorKind,
        };
        self.bus.mu.lock();
        defer self.bus.mu.unlock();
        const r = try self.bus.handlers.getOrPut(self.bus.alloc, port);
        if (r.found_existing) return error.PortAlreadyListening;
        r.value_ptr.* = handler;
    }

    // No multicast groups tracked; in-process delivery uses unicast only.
    fn vtJoinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
    fn vtLeaveMulticast(_: *anyopaque, _: *const Locator) void {}

    fn vtUnlisten(ctx: *anyopaque, locator: *const Locator, _: ReceiveHandler) void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ctx));
        const port: u32 = switch (locator.*) {
            .udp_v4 => |u| u.port,
            .udp_v6 => |u| u.port,
            else => return,
        };
        self.bus.mu.lock();
        defer self.bus.mu.unlock();
        _ = self.bus.handlers.remove(port);
    }

    fn vtUnicastLocators(ctx: *anyopaque, out: *std.ArrayListUnmanaged(Locator), alloc: std.mem.Allocator) anyerror!void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ctx));
        out.clearRetainingCapacity();
        try out.appendSlice(alloc, self.unicast_locs.items);
    }

    fn vtSetLocatorChangeHandler(ctx: *anyopaque, handler: ?LocatorChangeHandler) void {
        const self: *MemoryTransport = @ptrCast(@alignCast(ctx));
        self.locator_change_handler = handler;
    }

    fn vtClose(_: *anyopaque) void {}
};

const mem_vtable = Transport.Vtable{
    .capabilities = .{ .unicast = true, .multicast = false },
    .can_reach = MemoryTransport.vtCanReach,
    .send = MemoryTransport.vtSend,
    .listen = MemoryTransport.vtListen,
    .join_multicast = MemoryTransport.vtJoinMulticast,
    .leave_multicast = MemoryTransport.vtLeaveMulticast,
    .unlisten = MemoryTransport.vtUnlisten,
    .unicast_locators = MemoryTransport.vtUnicastLocators,
    .set_locator_change_handler = MemoryTransport.vtSetLocatorChangeHandler,
    .close = MemoryTransport.vtClose,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "createTransport assigns sequential participant IDs and unique ports" {
    const alloc = testing.allocator;
    const bus = try MemoryBus.init(alloc);
    defer bus.deinit();

    const t0 = try bus.createTransport();
    defer t0.deinit();
    const t1 = try bus.createTransport();
    defer t1.deinit();

    var locs0: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs0.deinit(alloc);
    var locs1: std.ArrayListUnmanaged(Locator) = .empty;
    defer locs1.deinit(alloc);

    try t0.transport().unicastLocators(&locs0, alloc);
    try t1.transport().unicastLocators(&locs1, alloc);

    try testing.expectEqual(@as(usize, 1), locs0.items.len);
    try testing.expectEqual(@as(usize, 1), locs1.items.len);

    // Addresses and ports must differ.
    try testing.expect(!locs0.items[0].eql(locs1.items[0]));

    // Ports follow RTPS formula: 7410, 7412, ...
    try testing.expectEqual(
        @as(u16, 7410),
        locs0.items[0].udp_v4.port,
    );
    try testing.expectEqual(
        @as(u16, 7412),
        locs1.items[0].udp_v4.port,
    );
}

test "send delivers synchronously to registered handler" {
    const alloc = testing.allocator;
    const bus = try MemoryBus.init(alloc);
    defer bus.deinit();

    const sender = try bus.createTransport();
    defer sender.deinit();
    const receiver = try bus.createTransport();
    defer receiver.deinit();

    var recv_count: usize = 0;
    var recv_buf: [64]u8 = undefined;
    var recv_len: usize = 0;

    const Counter = struct {
        count: *usize,
        buf: *[64]u8,
        len: *usize,

        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = onRecv };
        }

        fn onRecv(ctx: *anyopaque, data: []const u8, _: Locator) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.count.* += 1;
            s.len.* = @min(data.len, s.buf.len);
            @memcpy(s.buf[0..s.len.*], data[0..s.len.*]);
        }
    };
    var ctr = Counter{ .count = &recv_count, .buf = &recv_buf, .len = &recv_len };

    // receiver listens on its data port (meta_port + 1 = 7413).
    const data_port: u16 = 7413;
    try receiver.transport().listen(
        &Locator.udp4(.{ 0, 0, 0, 0 }, data_port),
        ctr.handler(),
    );

    // sender sends to receiver's data locator.
    const dest = Locator.udp4(.{ 10, 0, 0, 2 }, data_port);
    try sender.transport().send(&dest, "hello");

    // Synchronous: already delivered.
    try testing.expectEqual(@as(usize, 1), recv_count);
    try testing.expectEqualSlices(u8, "hello", recv_buf[0..recv_len]);
}

test "unlisten stops delivery" {
    const alloc = testing.allocator;
    const bus = try MemoryBus.init(alloc);
    defer bus.deinit();

    const t0 = try bus.createTransport();
    defer t0.deinit();
    const t1 = try bus.createTransport();
    defer t1.deinit();

    var count: usize = 0;
    const Counter = struct {
        n: *usize,
        fn handler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = f };
        }
        fn f(ctx: *anyopaque, _: []const u8, _: Locator) void {
            const s: *@This() = @ptrCast(@alignCast(ctx));
            s.n.* += 1;
        }
    };
    var ctr = Counter{ .n = &count };

    const port: u16 = 7413;
    try t1.transport().listen(&Locator.udp4(.{ 0, 0, 0, 0 }, port), ctr.handler());
    try t0.transport().send(&Locator.udp4(.{ 10, 0, 0, 2 }, port), "a");
    try testing.expectEqual(@as(usize, 1), count);

    t1.transport().unlisten(&Locator.udp4(.{ 0, 0, 0, 0 }, port), ctr.handler());
    try t0.transport().send(&Locator.udp4(.{ 10, 0, 0, 2 }, port), "b");
    try testing.expectEqual(@as(usize, 1), count); // no new delivery
}

test "send to unregistered port is silently ignored" {
    const alloc = testing.allocator;
    const bus = try MemoryBus.init(alloc);
    defer bus.deinit();

    const t = try bus.createTransport();
    defer t.deinit();

    // No listen() call; send must not crash.
    try t.transport().send(&Locator.udp4(.{ 10, 0, 0, 1 }, 9999), "x");
}
