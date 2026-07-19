//! StatelessWriter behavioral tests (RTPS 2.5 §8.4.8).
//!
//! Focus: sendAll() fan-out to every registered reader locator vs. sendToLocator()
//! targeting exactly one locator (used by SPDP's SEDP-traffic-seen heuristic for a
//! unicast retransmit without a full sendAll() burst).

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;

const StatelessWriter = rtps.StatelessWriter;
const ReaderLocator = rtps.ReaderLocator;
const Guid = rtps.Guid;
const Locator = rtps.Locator;
const InstanceHandle = rtps.InstanceHandle;

const Transport = zzdds.transport.Transport;
const ReceiveHandler = zzdds.transport.ReceiveHandler;
const LocatorChangeHandler = zzdds.transport.LocatorChangeHandler;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;

const testing = std.testing;

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes(InstanceHandle);
const NIL_KH = std.mem.zeroes([16]u8);

// ── Recording transport: captures the destination locator of every send() ──────

const MAX_CAPS = 16;

const Recording = struct {
    locators: [MAX_CAPS]Locator = undefined,
    n: usize = 0,

    fn makeTransport(self: *@This()) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn sendFn(ctx: *anyopaque, loc: *const Locator, _: []const u8) anyerror!void {
        const self: *Recording = @ptrCast(@alignCast(ctx));
        if (self.n >= MAX_CAPS) return error.TooManySends;
        self.locators[self.n] = loc.*;
        self.n += 1;
    }

    fn canReach(_: *anyopaque, _: *const Locator) bool {
        return true;
    }
    fn listenFn(_: *anyopaque, _: *const Locator, _: ReceiveHandler) anyerror!void {}
    fn joinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
    fn leaveMulticast(_: *anyopaque, _: *const Locator) void {}
    fn unlisten(_: *anyopaque, _: *const Locator, _: ReceiveHandler) void {}
    fn unicastLocators(_: *anyopaque, out: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
        out.clearRetainingCapacity();
    }
    fn setLocatorChangeHandler(_: *anyopaque, _: ?LocatorChangeHandler) void {}
    fn closeFn(_: *anyopaque) void {}

    const vtable: Transport.Vtable = .{
        .capabilities = .{},
        .can_reach = canReach,
        .send = sendFn,
        .listen = listenFn,
        .join_multicast = joinMulticast,
        .leave_multicast = leaveMulticast,
        .unlisten = unlisten,
        .unicast_locators = unicastLocators,
        .set_locator_change_handler = setLocatorChangeHandler,
        .close = closeFn,
    };
};

fn countSendsToPort(rec: *const Recording, port: u16) usize {
    var n: usize = 0;
    for (rec.locators[0..rec.n]) |loc| {
        switch (loc) {
            .udp_v4 => |u| if (u.port == port) {
                n += 1;
            },
            else => {},
        }
    }
    return n;
}

fn writerGuid() Guid {
    return .{
        .prefix = .{ .bytes = [_]u8{0x01} ** 12 },
        .entity_id = rtps.EntityIds.spdp_builtin_participant_writer,
    };
}

test "sendAll: fans out to every registered reader locator" {
    var rec = Recording{};
    const w = try StatelessWriter.init(
        testing.allocator,
        writerGuid(),
        rec.makeTransport(),
        1,
        rtps.EntityIds.spdp_builtin_participant_reader,
    );
    defer w.deinit();

    try w.addReaderLocator(.{ .locator = Locator.udp4(.{ 239, 255, 0, 1 }, 7400) });
    try w.addReaderLocator(.{ .locator = Locator.udp4(.{ 10, 0, 0, 2 }, 7411) });
    try w.addReaderLocator(.{ .locator = Locator.udp4(.{ 10, 0, 0, 3 }, 7412) });

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "hello");
    w.sendAll();

    try testing.expectEqual(@as(usize, 3), rec.n);
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7400));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7411));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7412));
}

test "sendToLocator: sends only to the given locator, not registered reader locators" {
    var rec = Recording{};
    const w = try StatelessWriter.init(
        testing.allocator,
        writerGuid(),
        rec.makeTransport(),
        1,
        rtps.EntityIds.spdp_builtin_participant_reader,
    );
    defer w.deinit();

    // Registered locators represent other, already-known peers.
    try w.addReaderLocator(.{ .locator = Locator.udp4(.{ 10, 0, 0, 2 }, 7411) });
    try w.addReaderLocator(.{ .locator = Locator.udp4(.{ 10, 0, 0, 3 }, 7412) });

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "hello");

    // Targeted retransmit to a peer that is NOT (necessarily) a registered
    // reader locator — mirrors SPDP's SEDP-traffic-seen heuristic use case.
    w.sendToLocator(Locator.udp4(.{ 10, 0, 0, 9 }, 7419));

    try testing.expectEqual(@as(usize, 1), rec.n);
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7419));
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7411));
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7412));
}

test "sendToLocator: sends every cached change, not just the latest" {
    var rec = Recording{};
    const w = try StatelessWriter.init(
        testing.allocator,
        writerGuid(),
        rec.makeTransport(),
        4, // keep_last depth 4 so both writes stay cached
        rtps.EntityIds.spdp_builtin_participant_reader,
    );
    defer w.deinit();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");

    w.sendToLocator(Locator.udp4(.{ 10, 0, 0, 9 }, 7419));

    try testing.expectEqual(@as(usize, 2), rec.n);
    try testing.expectEqual(@as(usize, 2), countSendsToPort(&rec, 7419));
}
