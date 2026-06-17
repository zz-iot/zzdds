//! Presentation/coherent model tests.
//!
//! These tests exercise the write-side presentation contract without SPDP/SEDP,
//! sockets, timer threads, or sleeps.  A tiny independent model is driven with
//! the same operations as the real StatefulWriter instances, then cache metadata
//! and emitted DATA sequence numbers are compared at each boundary.

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;

const StatefulWriter = rtps.StatefulWriter;
const ReaderProxy = rtps.ReaderProxy;
const CoherentFlushMode = rtps.history.CoherentFlushMode;
const Guid = rtps.Guid;
const SequenceNumber = rtps.SequenceNumber;
const Locator = rtps.Locator;
const ChangeKind = rtps.ChangeKind;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const Transport = zzdds.transport.Transport;
const ReceiveHandler = zzdds.transport.ReceiveHandler;
const LocatorChangeHandler = zzdds.transport.LocatorChangeHandler;
const MessageIterator = msg.MessageIterator;
const InlineQosParam = msg.InlineQosParam;

const testing = std.testing;

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes([16]u8);
const NIL_KH = std.mem.zeroes([16]u8);

const W1_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xA1} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_publications_writer };
const W2_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xA2} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_subscriptions_writer };
const R1_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xB1} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_publications_reader };
const R2_GUID = Guid{ .prefix = .{ .bytes = [_]u8{0xB2} ** 12 }, .entity_id = rtps.EntityIds.sedp_builtin_subscriptions_reader };

const W1_LOC = Locator.udp4(.{ 127, 0, 0, 10 }, 7411);
const W2_LOC = Locator.udp4(.{ 127, 0, 0, 11 }, 7411);
const R1_LOC = Locator.udp4(.{ 127, 0, 0, 12 }, 7413);
const R2_LOC = Locator.udp4(.{ 127, 0, 0, 13 }, 7413);

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

const ModelChange = struct {
    sn: SequenceNumber,
    sent: bool = false,
    coherent_set_sn: ?SequenceNumber = null,
    group_seq_num: ?i64 = null,
    group_coherent_sn: ?i64 = null,
};

const ModelWriter = struct {
    next_sn: SequenceNumber = 1,
    coherent_active: bool = false,
    coherent_window_start: usize = 0,
    pending_sns: std.ArrayListUnmanaged(SequenceNumber) = .empty,
    changes: std.ArrayListUnmanaged(ModelChange) = .empty,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.pending_sns.deinit(alloc);
        self.changes.deinit(alloc);
    }

    fn begin(self: *@This(), is_coherent_window: bool) void {
        if (is_coherent_window and self.coherent_active) {
            self.coherent_window_start = self.pending_sns.items.len;
        } else {
            self.coherent_active = true;
        }
    }

    fn write(self: *@This(), alloc: std.mem.Allocator) !SequenceNumber {
        const sn = self.next_sn;
        self.next_sn += 1;
        try self.changes.append(alloc, .{ .sn = sn, .sent = !self.coherent_active });
        if (self.coherent_active) try self.pending_sns.append(alloc, sn);
        return sn;
    }

    fn coherentWindowCount(self: *const @This()) usize {
        if (self.pending_sns.items.len < self.coherent_window_start) return 0;
        return self.pending_sns.items.len - self.coherent_window_start;
    }

    fn end(
        self: *@This(),
        mode: CoherentFlushMode,
        resuspend: bool,
        shared_gsn: ?*i64,
        global_last_gsn: i64,
    ) void {
        self.coherent_active = false;
        defer if (resuspend) {
            self.coherent_active = true;
        };

        const window_start = self.coherent_window_start;
        self.coherent_window_start = 0;
        const all_sns = self.pending_sns.items;
        if (all_sns.len == 0) return;

        for (all_sns[0..window_start]) |sn| self.markSent(sn);
        const coherent_sns = all_sns[window_start..];
        if (coherent_sns.len == 0) {
            self.pending_sns.clearRetainingCapacity();
            return;
        }

        if (mode != .none) {
            const base_gsn = if (shared_gsn) |g| g.* else 0;
            const last_gsn = base_gsn + @as(i64, @intCast(coherent_sns.len));
            const group_end_gsn = if (global_last_gsn != 0) global_last_gsn else last_gsn;
            const last_sn = coherent_sns[coherent_sns.len - 1];
            const first_sn = coherent_sns[0];
            for (coherent_sns, 1..) |sn, i| {
                const gsn = base_gsn + @as(i64, @intCast(i));
                if (self.changePtr(sn)) |ch| {
                    if (mode == .full) {
                        ch.coherent_set_sn = first_sn;
                        if (sn == last_sn) ch.group_coherent_sn = group_end_gsn;
                    }
                    ch.group_seq_num = gsn;
                }
            }
            if (shared_gsn) |g| g.* += @intCast(coherent_sns.len);
        }
        for (coherent_sns) |sn| self.markSent(sn);
        self.pending_sns.clearRetainingCapacity();
    }

    fn markSent(self: *@This(), sn: SequenceNumber) void {
        if (self.changePtr(sn)) |ch| ch.sent = true;
    }

    fn changePtr(self: *@This(), sn: SequenceNumber) ?*ModelChange {
        for (self.changes.items) |*ch| {
            if (ch.sn == sn) return ch;
        }
        return null;
    }
};

fn makeWriter(
    alloc: std.mem.Allocator,
    rec: *Recording,
    writer_guid: Guid,
    reader_guid: Guid,
    reader_loc: Locator,
) !*StatefulWriter {
    const writer = try StatefulWriter.init(
        alloc,
        writer_guid,
        rec.transport(),
        .keep_all,
        0,
        rtps.EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    const rp = try ReaderProxy.init(alloc, reader_guid, &.{reader_loc}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    rec.reset();
    return writer;
}

fn makeUnmatchedWriter(alloc: std.mem.Allocator, rec: *Recording, writer_guid: Guid) !*StatefulWriter {
    const writer = try StatefulWriter.init(
        alloc,
        writer_guid,
        rec.transport(),
        .keep_all,
        0,
        rtps.EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    rec.reset();
    return writer;
}

fn writeImpl(writer: *StatefulWriter, payload: []const u8) !SequenceNumber {
    return writer.write(.alive, ZERO_TS, NIL_IH, NIL_KH, payload);
}

fn expectModelMatchesImpl(model: *const ModelWriter, writer: *StatefulWriter) !void {
    writer.mu.lock();
    defer writer.mu.unlock();
    try testing.expectEqual(model.changes.items.len, writer.cache.changes.items.len);
    for (model.changes.items, writer.cache.changes.items) |exp, got| {
        try testing.expectEqual(exp.sn, got.sequence_number);
        try testing.expectEqual(exp.coherent_set_sn, got.coherent_set_sn);
        try testing.expectEqual(exp.group_seq_num, got.group_seq_num);
        try testing.expectEqual(exp.group_coherent_sn, got.group_coherent_sn);
    }
}

fn expectDataSns(rec: *const Recording, expected: []const SequenceNumber) !void {
    var got_buf: [16]SequenceNumber = undefined;
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
    try testing.expectEqualSlices(SequenceNumber, expected, got_buf[0..got_n]);
}

test "presentation model: suspend before coherent keeps pre-window write out of coherent set" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec, W1_GUID, R1_GUID, R1_LOC);
    defer writer.deinit();
    var model = ModelWriter{};
    defer model.deinit(alloc);

    writer.beginCoherentSet(false);
    model.begin(false);
    _ = try writeImpl(writer, "A");
    _ = try model.write(alloc);

    writer.beginCoherentSet(true);
    model.begin(true);
    _ = try writeImpl(writer, "B");
    _ = try model.write(alloc);
    try testing.expectEqual(@as(usize, 1), writer.coherentWindowPendingCount());
    try testing.expectEqual(@as(usize, 1), model.coherentWindowCount());
    try expectDataSns(&rec, &.{});

    writer.endCoherentSet(.full, true, null, 0);
    model.end(.full, true, null, 0);
    try expectModelMatchesImpl(&model, writer);
    try expectDataSns(&rec, &.{ 1, 2 });

    rec.reset();
    _ = try writeImpl(writer, "C");
    _ = try model.write(alloc);
    try expectDataSns(&rec, &.{});

    writer.endCoherentSet(.none, false, null, 0);
    model.end(.none, false, null, 0);
    try expectModelMatchesImpl(&model, writer);
    try expectDataSns(&rec, &.{3});
}

test "presentation model: ordered-only flush assigns GSN without coherent markers" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec, W1_GUID, R1_GUID, R1_LOC);
    defer writer.deinit();
    var model = ModelWriter{};
    defer model.deinit(alloc);

    writer.beginCoherentSet(true);
    model.begin(true);
    _ = try writeImpl(writer, "A");
    _ = try model.write(alloc);
    _ = try writeImpl(writer, "B");
    _ = try model.write(alloc);
    try expectDataSns(&rec, &.{});

    writer.endCoherentSet(.group_seq_only, false, null, 0);
    model.end(.group_seq_only, false, null, 0);
    try expectModelMatchesImpl(&model, writer);
    try expectDataSns(&rec, &.{ 1, 2 });
}

test "presentation model: empty coherent window flushes pre-window samples only" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeWriter(alloc, &rec, W1_GUID, R1_GUID, R1_LOC);
    defer writer.deinit();
    var model = ModelWriter{};
    defer model.deinit(alloc);

    writer.beginCoherentSet(false);
    model.begin(false);
    _ = try writeImpl(writer, "A");
    _ = try model.write(alloc);

    writer.beginCoherentSet(true);
    model.begin(true);
    try testing.expectEqual(@as(usize, 0), writer.coherentWindowPendingCount());
    try testing.expectEqual(@as(usize, 0), model.coherentWindowCount());
    try expectDataSns(&rec, &.{});

    writer.endCoherentSet(.full, false, null, 0);
    model.end(.full, false, null, 0);
    try expectModelMatchesImpl(&model, writer);
    try expectDataSns(&rec, &.{1});
}

test "presentation model: readerless coherent set records metadata without DATA sends" {
    const alloc = testing.allocator;
    var rec: Recording = .{};
    const writer = try makeUnmatchedWriter(alloc, &rec, W1_GUID);
    defer writer.deinit();

    writer.beginCoherentSet(true);
    _ = try writeImpl(writer, "A");
    _ = try writeImpl(writer, "B");
    try expectDataSns(&rec, &.{});

    writer.endCoherentSet(.full, false, null, 0);
    try expectDataSns(&rec, &.{});

    writer.mu.lock();
    defer writer.mu.unlock();
    try testing.expectEqual(@as(usize, 2), writer.cache.changes.items.len);
    try testing.expectEqual(@as(?SequenceNumber, 1), writer.cache.changes.items[0].coherent_set_sn);
    try testing.expectEqual(@as(?SequenceNumber, 1), writer.cache.changes.items[1].coherent_set_sn);
    try testing.expectEqual(@as(?i64, 1), writer.cache.changes.items[0].group_seq_num);
    try testing.expectEqual(@as(?i64, 2), writer.cache.changes.items[1].group_seq_num);
    try testing.expectEqual(@as(?i64, null), writer.cache.changes.items[0].group_coherent_sn);
    try testing.expectEqual(@as(?i64, 2), writer.cache.changes.items[1].group_coherent_sn);
}

test "presentation model: shared publisher GSN gives group-wide coherent end marker" {
    const alloc = testing.allocator;
    var rec1: Recording = .{};
    var rec2: Recording = .{};
    const w1 = try makeWriter(alloc, &rec1, W1_GUID, R1_GUID, R1_LOC);
    defer w1.deinit();
    const w2 = try makeWriter(alloc, &rec2, W2_GUID, R2_GUID, R2_LOC);
    defer w2.deinit();
    var m1 = ModelWriter{};
    defer m1.deinit(alloc);
    var m2 = ModelWriter{};
    defer m2.deinit(alloc);

    w1.beginCoherentSet(true);
    m1.begin(true);
    w2.beginCoherentSet(true);
    m2.begin(true);

    _ = try writeImpl(w1, "A");
    _ = try m1.write(alloc);
    _ = try writeImpl(w2, "B");
    _ = try m2.write(alloc);
    _ = try writeImpl(w1, "C");
    _ = try m1.write(alloc);

    const total_n: i64 = @intCast(w1.coherentWindowPendingCount() + w2.coherentWindowPendingCount());
    const model_total_n: i64 = @intCast(m1.coherentWindowCount() + m2.coherentWindowCount());
    try testing.expectEqual(model_total_n, total_n);

    var impl_shared_gsn: i64 = 0;
    var model_shared_gsn: i64 = 0;
    w1.endCoherentSet(.full, false, &impl_shared_gsn, total_n);
    m1.end(.full, false, &model_shared_gsn, model_total_n);
    w2.endCoherentSet(.full, false, &impl_shared_gsn, total_n);
    m2.end(.full, false, &model_shared_gsn, model_total_n);

    try testing.expectEqual(model_shared_gsn, impl_shared_gsn);
    try expectModelMatchesImpl(&m1, w1);
    try expectModelMatchesImpl(&m2, w2);
    try expectDataSns(&rec1, &.{ 1, 2 });
    try expectDataSns(&rec2, &.{1});
}
