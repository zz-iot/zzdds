//! StatefulWriter model tests.
//!
//! The model here deliberately ignores packet encoding and transport details. It
//! predicts which DATA sequence numbers may be sent for ACKNACK inputs, including
//! final/non-final rules, stale count suppression, and coherent-pending skips.

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;

const StatefulWriter = rtps.StatefulWriter;
const ReaderProxy = rtps.ReaderProxy;
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
const MAX_SN = 16;

const WRITER_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xE1} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_publications_writer };
const READER_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xE2} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_publications_reader };
const READER_LOC = Locator.udp4(.{ 127, 0, 0, 30 }, 7413);

const MAX_CAPS = 64;
const MAX_BYTES = 1024;

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

const WriterModel = struct {
    cached: [MAX_SN + 1]bool = [_]bool{false} ** (MAX_SN + 1),
    coherent_pending: [MAX_SN + 1]bool = [_]bool{false} ** (MAX_SN + 1),
    next_sn: SequenceNumber = 1,
    coherent_active: bool = false,
    last_acknack_count: ?i32 = null,

    fn write(self: *@This()) SequenceNumber {
        const sn = self.next_sn;
        self.next_sn += 1;
        if (sn > 0 and sn <= MAX_SN) {
            self.cached[@intCast(sn)] = true;
            if (self.coherent_active) self.coherent_pending[@intCast(sn)] = true;
        }
        return sn;
    }

    fn beginCoherent(self: *@This()) void {
        self.coherent_active = true;
    }

    fn endCoherent(self: *@This()) void {
        self.coherent_active = false;
        self.coherent_pending = [_]bool{false} ** (MAX_SN + 1);
    }

    fn acknack(
        self: *@This(),
        alloc: std.mem.Allocator,
        nack_set: SequenceNumberSet,
        count: i32,
        final: bool,
    ) !std.ArrayListUnmanaged(SequenceNumber) {
        var sent: std.ArrayListUnmanaged(SequenceNumber) = .empty;
        if (self.last_acknack_count) |last| {
            const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
            if (diff <= 0) return sent;
        }

        var sn: SequenceNumber = nack_set.base;
        var bit: u32 = 0;
        while (bit < nack_set.num_bits) : ({
            sn += 1;
            bit += 1;
        }) {
            if (nack_set.contains(sn) and self.canSend(sn)) try sent.append(alloc, sn);
        }

        if (!final) {
            sn = nack_set.base;
            while (sn < self.next_sn) : (sn += 1) {
                if (!self.canSend(sn)) continue;
                const offset = sn - nack_set.base;
                if (offset >= 0 and offset < nack_set.num_bits and nack_set.contains(sn)) continue;
                try sent.append(alloc, sn);
            }
        }

        if (sent.items.len > 0) self.last_acknack_count = count;
        return sent;
    }

    fn canSend(self: *const @This(), sn: SequenceNumber) bool {
        if (sn <= 0 or sn > MAX_SN) return false;
        return self.cached[@intCast(sn)] and !self.coherent_pending[@intCast(sn)];
    }
};

fn makeWriter(alloc: std.mem.Allocator, rec: *Recording) !*StatefulWriter {
    const writer = try StatefulWriter.init(
        alloc,
        WRITER_GUID,
        rec.transport(),
        .keep_all,
        0,
        rtps.EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    const rp = try ReaderProxy.init(alloc, READER_GUID, &.{READER_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    rec.reset();
    return writer;
}

fn writeBoth(writer: *StatefulWriter, model: *WriterModel, payload: []const u8) !void {
    _ = try writer.write(.alive, ZERO_TS, NIL_IH, NIL_KH, payload);
    _ = model.write();
}

fn expectDataSns(rec: *const Recording, expected_unsorted: []const SequenceNumber) !void {
    var got_buf: [32]SequenceNumber = undefined;
    var got_n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            if (sm == .data) {
                if (got_n >= got_buf.len) return error.TooManyData;
                got_buf[got_n] = sm.data.writer_sn;
                got_n += 1;
            }
        }
    }

    var exp_buf: [32]SequenceNumber = undefined;
    try testing.expect(expected_unsorted.len <= exp_buf.len);
    @memcpy(exp_buf[0..expected_unsorted.len], expected_unsorted);
    std.mem.sort(SequenceNumber, got_buf[0..got_n], {}, std.sort.asc(SequenceNumber));
    std.mem.sort(SequenceNumber, exp_buf[0..expected_unsorted.len], {}, std.sort.asc(SequenceNumber));
    try testing.expectEqualSlices(SequenceNumber, exp_buf[0..expected_unsorted.len], got_buf[0..got_n]);
}

fn expectAckNackMatchesModel(
    alloc: std.mem.Allocator,
    writer: *StatefulWriter,
    model: *WriterModel,
    rec: *Recording,
    nack_set: SequenceNumberSet,
    highest_sn: SequenceNumber,
    count: i32,
    final: bool,
) !void {
    rec.reset();
    writer.handleAckNack(READER_GUID, highest_sn, nack_set, count, final);
    var expected = try model.acknack(alloc, nack_set, count, final);
    defer expected.deinit(alloc);
    try expectDataSns(rec, expected.items);
}

const WriterScriptOp = enum {
    write,
    begin_coherent,
    end_coherent,
    ack_nonfinal_empty,
    ack_final_first,
};

fn runWriterScript(alloc: std.mem.Allocator, ops: []const WriterScriptOp) !void {
    errdefer std.debug.print("writer script failed: {any}\n", .{ops});

    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};
    var ack_count: i32 = 1;

    for (ops) |op| {
        switch (op) {
            .write => {
                try writeBoth(writer, &model, "x");
                rec.reset();
            },
            .begin_coherent => {
                if (!model.coherent_active) {
                    writer.beginCoherentSet(true);
                    model.beginCoherent();
                }
                rec.reset();
            },
            .end_coherent => {
                if (model.coherent_active) {
                    writer.endCoherentSet(.full, false, null, 0);
                    model.endCoherent();
                }
                rec.reset();
            },
            .ack_nonfinal_empty => {
                const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
                try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, ack_count, false);
                ack_count += 1;
            },
            .ack_final_first => {
                var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 1, .bitmap = std.mem.zeroes([8]u32) };
                nack_set.set(1);
                try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, ack_count, true);
                ack_count += 1;
            },
        }
    }
}

test "writer model: non-final empty AckNack sends every cached change from base" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");
    try writeBoth(writer, &model, "two");
    try writeBoth(writer, &model, "three");

    const nack_set = SequenceNumberSet{ .base = 2, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 1, 1, false);
}

test "writer model: final AckNack sends only explicitly NACKed changes" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");
    try writeBoth(writer, &model, "two");
    try writeBoth(writer, &model, "three");

    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 3, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2);
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 1, true);
}

test "writer model: non-final sparse AckNack sends NACKed and implicit >= base changes" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");
    try writeBoth(writer, &model, "two");
    try writeBoth(writer, &model, "three");
    try writeBoth(writer, &model, "four");

    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 3, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2);
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 1, false);
    try expectDataSns(&rec, &.{ 1, 2, 3, 4 });
}

test "writer model: duplicate AckNack count is suppressed after a retransmit" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");
    try writeBoth(writer, &model, "two");
    try writeBoth(writer, &model, "three");

    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 7, false);
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 7, false);
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 6, false);
}

test "writer model: pure ACK does not stale-suppress later NACK with same count" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");
    try writeBoth(writer, &model, "two");

    const pure_ack = SequenceNumberSet{ .base = 3, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, pure_ack, 2, 10, true);

    var later_nack = SequenceNumberSet{ .base = 1, .num_bits = 2, .bitmap = std.mem.zeroes([8]u32) };
    later_nack.set(1);
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, later_nack, 0, 10, true);
}

test "writer model: AckNack count rollover is accepted then duplicate suppressed" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");

    writer.mu.lock();
    writer.reader_proxies.items[0].last_ack_nack_count = std.math.maxInt(i32);
    writer.mu.unlock();
    model.last_acknack_count = std.math.maxInt(i32);

    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, std.math.minInt(i32), false);
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, std.math.minInt(i32), false);
}

test "writer model: AckNack does not retransmit samples still inside coherent window" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec);
    defer writer.deinit();
    var model = WriterModel{};

    try writeBoth(writer, &model, "one");
    writer.beginCoherentSet(true);
    model.beginCoherent();
    try writeBoth(writer, &model, "two");
    try writeBoth(writer, &model, "three");

    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 1, false);

    writer.endCoherentSet(.full, false, null, 0);
    model.endCoherent();
    try expectAckNackMatchesModel(alloc, writer, &model, &rec, nack_set, 0, 2, false);
}

test "writer model: bounded write/coherent/AckNack scripts match implementation" {
    const alloc = testing.allocator;
    const alphabet = [_]WriterScriptOp{
        .write,
        .begin_coherent,
        .end_coherent,
        .ack_nonfinal_empty,
        .ack_final_first,
    };

    for (alphabet) |a| {
        for (alphabet) |b| {
            for (alphabet) |c| {
                for (alphabet) |d| {
                    const script = [_]WriterScriptOp{ a, b, c, d };
                    try runWriterScript(alloc, &script);
                }
            }
        }
    }
}
