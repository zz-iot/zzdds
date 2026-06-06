//! StatefulReader model tests.
//!
//! A small independent receive-window model is driven beside StatefulReader.
//! The model tracks only protocol-visible behavior: received sequence numbers,
//! out-of-order pending samples, delivered samples, heartbeat count suppression,
//! and sample-lost accounting for explicit GAPs.

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;

const StatefulReader = rtps.StatefulReader;
const WriterProxy = rtps.WriterProxy;
const CacheChange = rtps.CacheChange;
const Guid = rtps.Guid;
const SequenceNumber = rtps.SequenceNumber;
const SequenceNumberSet = msg.SequenceNumberSet;
const MessageIterator = msg.MessageIterator;
const InlineQosParam = msg.InlineQosParam;
const Locator = rtps.Locator;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const Transport = zzdds.transport.Transport;
const ReceiveHandler = zzdds.transport.ReceiveHandler;
const LocatorChangeHandler = zzdds.transport.LocatorChangeHandler;

const testing = std.testing;

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes([16]u8);
const NIL_KH = std.mem.zeroes([16]u8);

const WRITER_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xC1} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_publications_writer };
const READER_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xD1} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_publications_reader };
const WRITER_LOC = Locator.udp4(.{ 127, 0, 0, 20 }, 7411);

const MAX_CAPS = 32;
const MAX_BYTES = 512;
const MAX_SN = 16;

const Capture = struct {
    buf: [MAX_BYTES]u8,
    len: usize,
};

const Recording = struct {
    caps: [MAX_CAPS]Capture = undefined,
    n: usize = 0,

    fn reset(self: *@This()) void {
        self.n = 0;
    }

    fn transport(self: *@This()) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn sendFn(ctx: *anyopaque, _: *const Locator, data: []const u8) anyerror!void {
        const self: *Recording = @ptrCast(@alignCast(ctx));
        if (self.n >= MAX_CAPS) return error.TooManySends;
        const cap = &self.caps[self.n];
        cap.len = @min(data.len, MAX_BYTES);
        @memcpy(cap.buf[0..cap.len], data[0..cap.len]);
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

const Collector = struct {
    delivered: std.ArrayListUnmanaged(SequenceNumber) = .empty,
    lost_count: i32 = 0,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.delivered.deinit(alloc);
    }

    fn callback(self: *@This()) rtps.DataCallback {
        return .{ .ctx = self, .on_data = onData, .on_sample_lost = onSampleLost };
    }

    fn onData(ctx: *anyopaque, ch: *const CacheChange) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.delivered.append(testing.allocator, ch.sequence_number) catch {};
    }

    fn onSampleLost(ctx: *anyopaque, count: i32) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.lost_count += count;
    }
};

const ReaderModel = struct {
    received: [MAX_SN + 1]bool = [_]bool{false} ** (MAX_SN + 1),
    pending: [MAX_SN + 1]bool = [_]bool{false} ** (MAX_SN + 1),
    delivered: std.ArrayListUnmanaged(SequenceNumber) = .empty,
    last_hb_count: ?i32 = null,
    lost_count: i32 = 0,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.delivered.deinit(alloc);
    }

    fn data(self: *@This(), alloc: std.mem.Allocator, sn: SequenceNumber) !void {
        if (self.isReceived(sn)) return;
        const prev_highest = self.cumulativeAck();
        self.setReceived(sn);
        if (sn == prev_highest + 1) {
            try self.deliverIfPendingOrCurrent(alloc, sn, true);
            try self.deliverContiguousPending(alloc);
        } else {
            self.setPending(sn);
        }
    }

    fn gap(self: *@This(), alloc: std.mem.Allocator, gap_start: SequenceNumber, gap_list: SequenceNumberSet) !void {
        const prev = self.cumulativeAck();
        const bitmap_end = gap_list.base + @as(i64, gap_list.num_bits);
        var sn = gap_start;
        while (sn < gap_list.base) : (sn += 1) {
            if (!self.isReceived(sn)) self.lost_count += 1;
            self.setReceived(sn);
        }
        while (sn < bitmap_end) : (sn += 1) {
            if (gap_list.contains(sn)) {
                if (!self.isReceived(sn)) self.lost_count += 1;
                self.setReceived(sn);
            }
        }
        if (self.cumulativeAck() > prev) try self.deliverContiguousPending(alloc);
    }

    fn heartbeat(self: *@This(), alloc: std.mem.Allocator, first_sn: SequenceNumber, count: i32) !bool {
        if (self.last_hb_count) |last| {
            const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
            if (diff <= 0) return false;
        }
        self.last_hb_count = count;
        if (first_sn > self.cumulativeAck() + 1) {
            var sn = self.cumulativeAck() + 1;
            while (sn < first_sn) : (sn += 1) self.setReceived(sn);
            try self.deliverContiguousPending(alloc);
        }
        return true;
    }

    fn cumulativeAck(self: *const @This()) SequenceNumber {
        var sn: SequenceNumber = 1;
        while (sn <= MAX_SN) : (sn += 1) {
            if (!self.isReceived(sn)) return sn - 1;
        }
        return MAX_SN;
    }

    fn deliverContiguousPending(self: *@This(), alloc: std.mem.Allocator) !void {
        var sn: SequenceNumber = 1;
        while (sn <= self.cumulativeAck()) : (sn += 1) {
            if (self.isPending(sn)) {
                self.clearPending(sn);
                try self.delivered.append(alloc, sn);
            }
        }
    }

    fn deliverIfPendingOrCurrent(self: *@This(), alloc: std.mem.Allocator, sn: SequenceNumber, current: bool) !void {
        if (current) {
            try self.delivered.append(alloc, sn);
            return;
        }
        if (self.isPending(sn)) {
            self.clearPending(sn);
            try self.delivered.append(alloc, sn);
        }
    }

    fn isReceived(self: *const @This(), sn: SequenceNumber) bool {
        if (sn < 0 or sn > MAX_SN) return false;
        return self.received[@intCast(sn)];
    }

    fn setReceived(self: *@This(), sn: SequenceNumber) void {
        if (sn > 0 and sn <= MAX_SN) self.received[@intCast(sn)] = true;
    }

    fn isPending(self: *const @This(), sn: SequenceNumber) bool {
        if (sn < 0 or sn > MAX_SN) return false;
        return self.pending[@intCast(sn)];
    }

    fn setPending(self: *@This(), sn: SequenceNumber) void {
        if (sn > 0 and sn <= MAX_SN) self.pending[@intCast(sn)] = true;
    }

    fn clearPending(self: *@This(), sn: SequenceNumber) void {
        if (sn > 0 and sn <= MAX_SN) self.pending[@intCast(sn)] = false;
    }
};

fn makeReader(alloc: std.mem.Allocator, rec: *Recording, col: *Collector) !*StatefulReader {
    const reader = try StatefulReader.init(alloc, READER_GUID, rec.transport(), .keep_all, 0, true);
    const wp = try WriterProxy.init(alloc, WRITER_GUID, &.{WRITER_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);
    reader.setCallback(col.callback());
    rec.reset();
    return reader;
}

fn change(sn: SequenceNumber) CacheChange {
    return .{
        .kind = .alive,
        .writer_guid = WRITER_GUID,
        .sequence_number = sn,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "x",
    };
}

fn expectDelivered(model: *const ReaderModel, col: *const Collector) !void {
    try testing.expectEqualSlices(SequenceNumber, model.delivered.items, col.delivered.items);
    try testing.expectEqual(model.lost_count, col.lost_count);
}

fn countAckNacks(rec: *const Recording) usize {
    var n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            if (sm == .acknack) n += 1;
        }
    }
    return n;
}

const ReaderScriptOp = enum {
    data1,
    data2,
    data3,
    gap1,
    gap2,
    heartbeat3,
};

fn gapRange(base: SequenceNumber) SequenceNumberSet {
    return .{ .base = base, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
}

fn runReaderScript(alloc: std.mem.Allocator, ops: []const ReaderScriptOp) !void {
    errdefer std.debug.print("reader script failed: {any}\n", .{ops});

    var rec: Recording = .{};
    var col = Collector{};
    defer col.deinit(alloc);
    const reader = try makeReader(alloc, &rec, &col);
    defer reader.deinit();
    var model = ReaderModel{};
    defer model.deinit(alloc);
    var hb_count: i32 = 1;

    for (ops) |op| {
        switch (op) {
            .data1 => {
                try reader.handleData(WRITER_GUID, change(1));
                try model.data(alloc, 1);
                try expectDelivered(&model, &col);
            },
            .data2 => {
                try reader.handleData(WRITER_GUID, change(2));
                try model.data(alloc, 2);
                try expectDelivered(&model, &col);
            },
            .data3 => {
                try reader.handleData(WRITER_GUID, change(3));
                try model.data(alloc, 3);
                try expectDelivered(&model, &col);
            },
            .gap1 => {
                const gaps = gapRange(2);
                reader.handleGap(WRITER_GUID, 1, gaps);
                try model.gap(alloc, 1, gaps);
                try expectDelivered(&model, &col);
            },
            .gap2 => {
                const gaps = gapRange(3);
                reader.handleGap(WRITER_GUID, 2, gaps);
                try model.gap(alloc, 2, gaps);
                try expectDelivered(&model, &col);
            },
            .heartbeat3 => {
                rec.reset();
                reader.handleHeartbeat(WRITER_GUID, 1, 3, hb_count, false);
                const accepted = try model.heartbeat(alloc, 1, hb_count);
                try testing.expectEqual(@as(usize, if (accepted) 1 else 0), countAckNacks(&rec));
                try expectDelivered(&model, &col);
                hb_count += 1;
            },
        }
    }
}

test "reader model: out-of-order data then virtual gap delivers contiguous pending samples" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    var col = Collector{};
    defer col.deinit(alloc);
    const reader = try makeReader(alloc, &rec, &col);
    defer reader.deinit();
    var model = ReaderModel{};
    defer model.deinit(alloc);

    try reader.handleData(WRITER_GUID, change(2));
    try model.data(alloc, 2);
    try reader.handleData(WRITER_GUID, change(2));
    try model.data(alloc, 2);
    try reader.handleData(WRITER_GUID, change(4));
    try model.data(alloc, 4);
    try expectDelivered(&model, &col);

    const gap_list = SequenceNumberSet{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    reader.handleGap(WRITER_GUID, 3, gap_list);
    try model.gap(alloc, 3, gap_list);
    try expectDelivered(&model, &col);

    reader.handleHeartbeat(WRITER_GUID, 2, 4, 1, false);
    _ = try model.heartbeat(alloc, 2, 1);
    try expectDelivered(&model, &col);
    try testing.expectEqual(@as(usize, 1), countAckNacks(&rec));
}

test "reader model: explicit gap reports sample lost and unblocks pending data" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    var col = Collector{};
    defer col.deinit(alloc);
    const reader = try makeReader(alloc, &rec, &col);
    defer reader.deinit();
    var model = ReaderModel{};
    defer model.deinit(alloc);

    try reader.handleData(WRITER_GUID, change(1));
    try model.data(alloc, 1);
    try reader.handleData(WRITER_GUID, change(3));
    try model.data(alloc, 3);
    try expectDelivered(&model, &col);

    const gap_list = SequenceNumberSet{ .base = 3, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    reader.handleGap(WRITER_GUID, 2, gap_list);
    try model.gap(alloc, 2, gap_list);
    try expectDelivered(&model, &col);
}

test "reader model: duplicate and stale heartbeats do not send new AckNacks" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    var col = Collector{};
    defer col.deinit(alloc);
    const reader = try makeReader(alloc, &rec, &col);
    defer reader.deinit();
    var model = ReaderModel{};
    defer model.deinit(alloc);

    reader.handleHeartbeat(WRITER_GUID, 1, 3, 5, false);
    try testing.expect(try model.heartbeat(alloc, 1, 5));
    try testing.expectEqual(@as(usize, 1), countAckNacks(&rec));

    rec.reset();
    reader.handleHeartbeat(WRITER_GUID, 1, 3, 5, false);
    try testing.expect(!(try model.heartbeat(alloc, 1, 5)));
    try testing.expectEqual(@as(usize, 0), countAckNacks(&rec));

    reader.handleHeartbeat(WRITER_GUID, 1, 3, 4, false);
    try testing.expect(!(try model.heartbeat(alloc, 1, 4)));
    try testing.expectEqual(@as(usize, 0), countAckNacks(&rec));
}

test "reader model: heartbeat count rollover is accepted once" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    var col = Collector{};
    defer col.deinit(alloc);
    const reader = try makeReader(alloc, &rec, &col);
    defer reader.deinit();
    var model = ReaderModel{};
    defer model.deinit(alloc);

    reader.writer_proxies.items[0].last_hb_count = std.math.maxInt(i32);
    model.last_hb_count = std.math.maxInt(i32);

    reader.handleHeartbeat(WRITER_GUID, 1, 3, std.math.minInt(i32), false);
    try testing.expect(try model.heartbeat(alloc, 1, std.math.minInt(i32)));
    try testing.expectEqual(@as(usize, 1), countAckNacks(&rec));

    rec.reset();
    reader.handleHeartbeat(WRITER_GUID, 1, 3, std.math.minInt(i32), false);
    try testing.expect(!(try model.heartbeat(alloc, 1, std.math.minInt(i32))));
    try testing.expectEqual(@as(usize, 0), countAckNacks(&rec));
}

test "reader model: bounded data/GAP/Heartbeat scripts match implementation" {
    const alloc = testing.allocator;
    const alphabet = [_]ReaderScriptOp{
        .data1,
        .data2,
        .data3,
        .gap1,
        .gap2,
        .heartbeat3,
    };

    for (alphabet) |a| {
        for (alphabet) |b| {
            for (alphabet) |c| {
                for (alphabet) |d| {
                    const script = [_]ReaderScriptOp{ a, b, c, d };
                    try runReaderScript(alloc, &script);
                }
            }
        }
    }
}
