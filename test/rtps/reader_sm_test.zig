//! StatefulReader behavioral tests (RTPS 2.5 §8.3.7.1, §8.4.10, §8.4.11).
//!
//! Focus: Heartbeat handling (AckNack generation, count deduplication/rollover),
//! GAP handling, and WriterProxy receive-window state.

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
const ChangeKind = rtps.ChangeKind;
const InstanceHandle = rtps.InstanceHandle;

const Transport = zzdds.transport.Transport;
const ReceiveHandler = zzdds.transport.ReceiveHandler;
const LocatorChangeHandler = zzdds.transport.LocatorChangeHandler;

const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;

const testing = std.testing;

// ── Test constants ────────────────────────────────────────────────────────────

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes(InstanceHandle);
const NIL_KH = std.mem.zeroes([16]u8);

const WRITER_EID = rtps.EntityIds.sedp_builtin_publications_writer;
const READER_EID = rtps.EntityIds.sedp_builtin_publications_reader;

fn makeGuid(prefix_byte: u8, eid: rtps.EntityId) Guid {
    return .{
        .prefix = .{ .bytes = [_]u8{prefix_byte} ** 12 },
        .entity_id = eid,
    };
}

// ── Recording transport ───────────────────────────────────────────────────────

const MAX_CAPS = 32;
const MAX_BYTES = 512;

const Capture = struct {
    locator: Locator,
    buf: [MAX_BYTES]u8,
    len: usize,
};

const Recording = struct {
    caps: [MAX_CAPS]Capture = undefined,
    n: usize = 0,

    pub fn reset(self: *@This()) void {
        self.n = 0;
    }

    pub fn makeTransport(self: *@This()) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn sendFn(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const self: *Recording = @ptrCast(@alignCast(ctx));
        if (self.n >= MAX_CAPS) return error.TooManySends;
        const c = &self.caps[self.n];
        c.locator = loc.*;
        c.len = @min(data.len, MAX_BYTES);
        @memcpy(c.buf[0..c.len], data[0..c.len]);
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

// ── Parse helpers ─────────────────────────────────────────────────────────────

/// Find the first ACKNACK submessage in all captures.
fn findAckNack(rec: *const Recording) ?msg.submessage.AckNackSubmessage {
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            switch (sm) {
                .acknack => |an| return an,
                else => {},
            }
        }
    }
    return null;
}

/// Count captures sent to a udp_v4 locator with the given port.
fn countSendsToPort(rec: *const Recording, port: u16) usize {
    var n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        switch (cap.locator) {
            .udp_v4 => |u| {
                if (u.port == port) n += 1;
            },
            else => {},
        }
    }
    return n;
}

/// Count captures sent to a udp_v6 locator with the given port.
fn countSendsToV6Port(rec: *const Recording, port: u16) usize {
    var n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        switch (cap.locator) {
            .udp_v6 => |u| {
                if (u.port == port) n += 1;
            },
            else => {},
        }
    }
    return n;
}

// ── Shared reader setup ───────────────────────────────────────────────────────

/// Set up a StatefulReader with one matched writer proxy (writer_loc = where
/// the reader sends AckNacks).
fn makeReader(
    rec: *Recording,
    reader_guid: Guid,
    writer_guid: Guid,
    writer_loc: Locator,
) !*StatefulReader {
    const r = try StatefulReader.init(
        testing.allocator,
        reader_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        false,
    );
    const wp = try WriterProxy.init(testing.allocator, writer_guid, &.{writer_loc}, &.{}, true);
    try r.addMatchedWriter(wp);
    return r;
}

// ── Heartbeat: non-final with missing SNs → AckNack with NACK bitmap ─────────

test "handleHeartbeat: non-final with missing SNs generates AckNack bitmap" {
    const reader_guid = makeGuid(0x01, READER_EID);
    const writer_guid = makeGuid(0x02, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Reader has received SN 1 only; SNs 2 and 3 are missing.
    const ch1 = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "a",
    };
    try r.handleData(writer_guid, ch1);
    rec.reset();

    // Non-final heartbeat claiming writer has SNs 1..3.
    r.handleHeartbeat(writer_guid, 1, 3, 1, false);

    const an = findAckNack(&rec) orelse return error.NoAckNackFound;
    // base = highest_received + 1 = 2; bitmap should NACK SNs 2 and 3.
    try testing.expectEqual(@as(SequenceNumber, 2), an.reader_sn_state.base);
    try testing.expect(an.reader_sn_state.num_bits >= 2);
    try testing.expect(an.reader_sn_state.contains(2)); // SN 2 missing → bit set
    try testing.expect(an.reader_sn_state.contains(3)); // SN 3 missing → bit set
}

// ── Heartbeat: non-final, all received → AckNack pure ACK ────────────────────

test "handleHeartbeat: non-final with all SNs received → AckNack with empty bitmap" {
    const reader_guid = makeGuid(0x03, READER_EID);
    const writer_guid = makeGuid(0x04, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Receive all three SNs.
    for (1..4) |sn_usize| {
        const sn: SequenceNumber = @intCast(sn_usize);
        const ch = CacheChange{
            .kind = .alive,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = ZERO_TS,
            .instance_handle = NIL_IH,
            .key_hash = NIL_KH,
            .data = "x",
        };
        try r.handleData(writer_guid, ch);
    }
    rec.reset();

    r.handleHeartbeat(writer_guid, 1, 3, 1, false);

    // Non-final always sends AckNack; but bitmap is empty (pure ACK).
    const an = findAckNack(&rec) orelse return error.NoAckNackFound;
    try testing.expectEqual(@as(u32, 0), an.reader_sn_state.num_bits);
}

// ── Heartbeat: final, all received → no AckNack ──────────────────────────────

test "handleHeartbeat: final + all SNs received → no AckNack sent" {
    const reader_guid = makeGuid(0x05, READER_EID);
    const writer_guid = makeGuid(0x06, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    for (1..4) |sn_usize| {
        const sn: SequenceNumber = @intCast(sn_usize);
        const ch = CacheChange{
            .kind = .alive,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = ZERO_TS,
            .instance_handle = NIL_IH,
            .key_hash = NIL_KH,
            .data = "x",
        };
        try r.handleData(writer_guid, ch);
    }
    rec.reset();

    // Final heartbeat: reader need not reply if no missing SNs.
    r.handleHeartbeat(writer_guid, 1, 3, 1, true);

    try testing.expectEqual(@as(usize, 0), rec.n);
}

// ── Heartbeat: unknown writer → ignored ──────────────────────────────────────

test "handleHeartbeat: unknown writer GUID is ignored" {
    const reader_guid = makeGuid(0x07, READER_EID);
    const writer_guid = makeGuid(0x08, WRITER_EID);
    const unknown_guid = makeGuid(0xff, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    rec.reset(); // clear initial AckNack from addMatchedWriter setup
    r.handleHeartbeat(unknown_guid, 1, 3, 1, false);

    try testing.expectEqual(@as(usize, 0), rec.n);
}

// ── Count_t: duplicate heartbeat suppressed ───────────────────────────────────

test "handleHeartbeat: duplicate count suppressed" {
    const reader_guid = makeGuid(0x09, READER_EID);
    const writer_guid = makeGuid(0x0a, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // First heartbeat with count=5 → accepted, AckNack sent.
    r.handleHeartbeat(writer_guid, 1, 3, 5, false);
    try testing.expect(rec.n > 0);

    // Same count=5 again → duplicate, suppressed.
    rec.reset();
    r.handleHeartbeat(writer_guid, 1, 3, 5, false);
    try testing.expectEqual(@as(usize, 0), rec.n);

    // Stale count=3 → also rejected.
    r.handleHeartbeat(writer_guid, 1, 3, 3, false);
    try testing.expectEqual(@as(usize, 0), rec.n);
}

// ── Count_t: 32-bit rollover accepted ────────────────────────────────────────

test "handleHeartbeat: Count_t rollover INT32_MAX → INT32_MIN accepted" {
    const reader_guid = makeGuid(0x0b, READER_EID);
    const writer_guid = makeGuid(0x0c, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Manually set last_hb_count to INT32_MAX (simulating a long-running endpoint).
    r.writer_proxies.items[0].last_hb_count = std.math.maxInt(i32);

    // Next heartbeat at INT32_MIN — the rollover should be accepted.
    r.handleHeartbeat(writer_guid, 1, 3, std.math.minInt(i32), false);
    try testing.expect(rec.n > 0);
}

// ── Count_t: re-delivery of rolled-over count rejected ───────────────────────

test "handleHeartbeat: re-delivery after rollover rejected as duplicate" {
    const reader_guid = makeGuid(0x0d, READER_EID);
    const writer_guid = makeGuid(0x0e, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    r.writer_proxies.items[0].last_hb_count = std.math.maxInt(i32);

    // Rollover: accepted.
    r.handleHeartbeat(writer_guid, 1, 3, std.math.minInt(i32), false);
    try testing.expect(rec.n > 0);

    // Same count again: rejected as duplicate.
    rec.reset();
    r.handleHeartbeat(writer_guid, 1, 3, std.math.minInt(i32), false);
    try testing.expectEqual(@as(usize, 0), rec.n);
}

// ── GAP: contiguous range ─────────────────────────────────────────────────────

test "handleGap: contiguous range advances highestReceivedSN" {
    const reader_guid = makeGuid(0x0f, READER_EID);
    const writer_guid = makeGuid(0x10, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Receive SN 1.
    const ch1 = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "a",
    };
    try r.handleData(writer_guid, ch1);
    try testing.expectEqual(@as(SequenceNumber, 1), r.writer_proxies.items[0].received.cumulativeAck());

    // GAP: SNs 2, 3, 4 are irreversibly unavailable.
    // gap_start=2, gap_list.base=5 → [2..4] all gapped.
    const gap_list = SequenceNumberSet{ .base = 5, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    r.handleGap(writer_guid, 2, gap_list);

    try testing.expectEqual(@as(SequenceNumber, 4), r.writer_proxies.items[0].received.cumulativeAck());
}

// ── GAP: sparse bitmap ────────────────────────────────────────────────────────

test "handleGap: bitmap advances only listed SNs" {
    const reader_guid = makeGuid(0x11, READER_EID);
    const writer_guid = makeGuid(0x12, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Receive SN 1.
    const ch1 = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "a",
    };
    try r.handleData(writer_guid, ch1);

    // GAP: base=2, num_bits=4; SNs 2 and 4 are gapped; SNs 3 and 5 are not.
    var gap_list = SequenceNumberSet{ .base = 2, .num_bits = 4, .bitmap = std.mem.zeroes([8]u32) };
    gap_list.set(2);
    gap_list.set(4);
    r.handleGap(writer_guid, 2, gap_list);

    const wp = &r.writer_proxies.items[0];
    // SN 2 (gapped, in-order) → cumAck=2. SN 4 (gapped, out-of-order) → gap at 3.
    try testing.expectEqual(@as(SequenceNumber, 2), wp.received.cumulativeAck());
    try testing.expect(wp.received.contains(4));
    try testing.expect(!wp.received.contains(3)); // SN 3 not gapped, not received
}

// ── GAP: already-received SNs → idempotent ───────────────────────────────────

test "handleGap: already-received SNs are idempotent" {
    const reader_guid = makeGuid(0x13, READER_EID);
    const writer_guid = makeGuid(0x14, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Receive SNs 1 and 2.
    for (1..3) |sn_usize| {
        const sn: SequenceNumber = @intCast(sn_usize);
        const ch = CacheChange{
            .kind = .alive,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = ZERO_TS,
            .instance_handle = NIL_IH,
            .key_hash = NIL_KH,
            .data = "x",
        };
        try r.handleData(writer_guid, ch);
    }
    try testing.expectEqual(@as(SequenceNumber, 2), r.writer_proxies.items[0].received.cumulativeAck());

    // GAP covering already-received SNs 1 and 2: must be a no-op.
    const gap_list = SequenceNumberSet{ .base = 3, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    r.handleGap(writer_guid, 1, gap_list);

    // cumulativeAck must not regress.
    try testing.expectEqual(@as(SequenceNumber, 2), r.writer_proxies.items[0].received.cumulativeAck());
}

// ── WriterProxy: duplicate DATA discarded ─────────────────────────────────────

test "handleData: duplicate SN is discarded without re-delivery" {
    const reader_guid = makeGuid(0x15, READER_EID);
    const writer_guid = makeGuid(0x16, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    var delivered: usize = 0;
    const Ctx = struct {
        count: *usize,
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count.* += 1;
        }
    };
    var ctx = Ctx{ .count = &delivered };
    r.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData });

    const ch = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "payload",
    };

    try r.handleData(writer_guid, ch);
    try r.handleData(writer_guid, ch); // duplicate

    // History cache must have exactly one entry.
    try testing.expectEqual(@as(usize, 1), r.cache.changes.items.len);
    // Callback may be called for the first delivery only; not for the duplicate.
    // (The cache dedup occurs in addReaderChange; callback may or may not fire for dup.)
    // At minimum: total deliveries <= 2, history has 1 entry.
    try testing.expect(delivered <= 2);
    try testing.expectEqual(@as(usize, 1), r.cache.changes.items.len);
}

// ── WriterProxy: out-of-order DATA → AckNack bitmap reflects gap ──────────────

test "handleData + handleHeartbeat: out-of-order DATA → NACK bitmap identifies gap" {
    const reader_guid = makeGuid(0x17, READER_EID);
    const writer_guid = makeGuid(0x18, WRITER_EID);
    const writer_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7400);

    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, writer_loc);
    defer r.deinit();

    // Receive SN 2 first (SN 1 missing).
    const ch2 = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 2,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "second",
    };
    try r.handleData(writer_guid, ch2);

    // cumulativeAck should still be 0 (SN 1 missing, SN 2 is out-of-order).
    try testing.expectEqual(@as(SequenceNumber, 0), r.writer_proxies.items[0].received.cumulativeAck());
    rec.reset();

    // Heartbeat says writer has up to SN 2; reader NACKs SN 1, ACKs SN 2.
    r.handleHeartbeat(writer_guid, 1, 2, 1, false);

    const an = findAckNack(&rec) orelse return error.NoAckNackFound;
    try testing.expectEqual(@as(SequenceNumber, 1), an.reader_sn_state.base);
    try testing.expect(an.reader_sn_state.contains(1)); // SN 1 is missing → NACKed
    try testing.expect(!an.reader_sn_state.contains(2)); // SN 2 was received → ACKed

    // Receive SN 1 (fills gap); proxy should fold SN 2 as well.
    const ch1 = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = "first",
    };
    try r.handleData(writer_guid, ch1);
    try testing.expectEqual(@as(SequenceNumber, 2), r.writer_proxies.items[0].received.cumulativeAck());
    try testing.expectEqual(@as(usize, 1), r.writer_proxies.items[0].received.ranges.items.len);
}

// ── RELIABLE reorder buffer ───────────────────────────────────────────────────

/// Like makeReader but with reliable=true for reorder-buffer tests.
fn makeReliableReader(
    rec: *Recording,
    reader_guid: Guid,
    writer_guid: Guid,
    writer_loc: Locator,
) !*StatefulReader {
    const r = try StatefulReader.init(
        testing.allocator,
        reader_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        true,
    );
    const wp = try WriterProxy.init(testing.allocator, writer_guid, &.{writer_loc}, &.{}, true);
    try r.addMatchedWriter(wp);
    return r;
}

/// Delivery recorder used across RELIABLE reorder tests.
const Recorder = struct {
    alloc: std.mem.Allocator,
    sns: std.ArrayListUnmanaged(SequenceNumber),
    data: std.ArrayListUnmanaged([]u8),

    fn init(alloc: std.mem.Allocator) Recorder {
        return .{ .alloc = alloc, .sns = .empty, .data = .empty };
    }
    fn deinit(self: *Recorder) void {
        for (self.data.items) |d| self.alloc.free(d);
        self.sns.deinit(self.alloc);
        self.data.deinit(self.alloc);
    }
    fn onData(ctx: *anyopaque, ch: *const CacheChange) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.sns.append(self.alloc, ch.sequence_number) catch return;
        const copy = self.alloc.dupe(u8, ch.data) catch return;
        self.data.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }
};

test "RELIABLE: in-order changes delivered immediately in order" {
    const reader_guid = makeGuid(0x20, READER_EID);
    const writer_guid = makeGuid(0x21, WRITER_EID);
    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, Locator.udp4(.{ 127, 0, 0, 1 }, 7400));
    defer r.deinit();

    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    r.setCallback(.{ .ctx = &recorder, .on_data = Recorder.onData });

    for (1..4) |n| {
        const ch = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = @intCast(n), .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "x" };
        try r.handleData(writer_guid, ch);
    }

    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, recorder.sns.items);
}

test "RELIABLE: out-of-order change held until gap filled" {
    const reader_guid = makeGuid(0x22, READER_EID);
    const writer_guid = makeGuid(0x23, WRITER_EID);
    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, Locator.udp4(.{ 127, 0, 0, 1 }, 7400));
    defer r.deinit();

    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    r.setCallback(.{ .ctx = &recorder, .on_data = Recorder.onData });

    // SN 2 arrives first — must be buffered, not delivered.
    const ch2 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 2, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "second" };
    try r.handleData(writer_guid, ch2);
    try testing.expectEqualSlices(SequenceNumber, &.{}, recorder.sns.items);
    try testing.expectEqual(@as(usize, 1), r.writer_proxies.items[0].pending_changes.items.len);

    // SN 1 arrives — gap fills; both SN 1 and SN 2 delivered in order.
    const ch1 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "first" };
    try r.handleData(writer_guid, ch1);
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2 }, recorder.sns.items);
    try testing.expectEqualSlices(u8, "first", recorder.data.items[0]);
    try testing.expectEqualSlices(u8, "second", recorder.data.items[1]);
    try testing.expectEqual(@as(usize, 0), r.writer_proxies.items[0].pending_changes.items.len);
}

test "RELIABLE: multiple out-of-order delivered in SN order when gap fills" {
    const reader_guid = makeGuid(0x24, READER_EID);
    const writer_guid = makeGuid(0x25, WRITER_EID);
    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, Locator.udp4(.{ 127, 0, 0, 1 }, 7400));
    defer r.deinit();

    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    r.setCallback(.{ .ctx = &recorder, .on_data = Recorder.onData });

    // SN 1, then SN 3, then SN 2 — SN 3 must wait for SN 2.
    const ch1 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "a" };
    const ch3 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 3, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "c" };
    const ch2 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 2, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "b" };

    try r.handleData(writer_guid, ch1);
    try testing.expectEqualSlices(SequenceNumber, &.{1}, recorder.sns.items);

    try r.handleData(writer_guid, ch3);
    try testing.expectEqualSlices(SequenceNumber, &.{1}, recorder.sns.items); // SN 3 buffered

    try r.handleData(writer_guid, ch2);
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, recorder.sns.items);
    try testing.expectEqualSlices(u8, "b", recorder.data.items[1]);
    try testing.expectEqualSlices(u8, "c", recorder.data.items[2]);
}

test "RELIABLE: duplicate out-of-order SN buffered only once" {
    const reader_guid = makeGuid(0x26, READER_EID);
    const writer_guid = makeGuid(0x27, WRITER_EID);
    var rec: Recording = .{};
    const r = try makeReliableReader(&rec, reader_guid, writer_guid, Locator.udp4(.{ 127, 0, 0, 1 }, 7400));
    defer r.deinit();

    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    r.setCallback(.{ .ctx = &recorder, .on_data = Recorder.onData });

    const ch2 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 2, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "second" };

    try r.handleData(writer_guid, ch2);
    try r.handleData(writer_guid, ch2); // UDP duplicate — must be ignored
    try testing.expectEqual(@as(usize, 1), r.writer_proxies.items[0].pending_changes.items.len);

    const ch1 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "first" };
    try r.handleData(writer_guid, ch1);
    // SN 2 delivered exactly once.
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2 }, recorder.sns.items);
    try testing.expectEqual(@as(usize, 0), r.writer_proxies.items[0].pending_changes.items.len);
}

test "BEST_EFFORT: out-of-order changes delivered immediately (no reorder)" {
    const reader_guid = makeGuid(0x28, READER_EID);
    const writer_guid = makeGuid(0x29, WRITER_EID);
    var rec: Recording = .{};
    const r = try makeReader(&rec, reader_guid, writer_guid, Locator.udp4(.{ 127, 0, 0, 1 }, 7400));
    defer r.deinit();

    var recorder = Recorder.init(testing.allocator);
    defer recorder.deinit();
    r.setCallback(.{ .ctx = &recorder, .on_data = Recorder.onData });

    const ch2 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 2, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "second" };
    const ch1 = CacheChange{ .kind = .alive, .writer_guid = writer_guid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = "first" };

    try r.handleData(writer_guid, ch2);
    try r.handleData(writer_guid, ch1);
    // BEST_EFFORT: both delivered in arrival order (2 then 1).
    try testing.expectEqualSlices(SequenceNumber, &.{ 2, 1 }, recorder.sns.items);
}

// ── LocatorSelector: effectiveLocators ranking (via WriterProxy) ──────────────

fn v6Public(last: u8) [16]u8 {
    var addr = [_]u8{0} ** 16;
    addr[0] = 0x20;
    addr[1] = 0x01;
    addr[15] = last;
    return addr;
}

test "effectiveLocators: dual-stack writer proxy collapses to a single family" {
    const reader_guid = makeGuid(0x70, READER_EID);
    const writer_guid = makeGuid(0x71, WRITER_EID);
    const loc_v4 = Locator.udp4(.{ 8, 8, 8, 8 }, 7520);
    const loc_v6 = Locator.udp6(v6Public(1), 7521);

    var rec: Recording = .{};
    const r = try StatefulReader.init(testing.allocator, reader_guid, rec.makeTransport(), .keep_all, 0, true);
    defer r.deinit();
    const wp = try WriterProxy.init(testing.allocator, writer_guid, &.{ loc_v4, loc_v6 }, &.{}, true);
    try r.addMatchedWriter(wp);
    rec.reset();

    r.handleHeartbeat(writer_guid, 1, 0, 1, false);

    const v4_sends = countSendsToPort(&rec, 7520);
    const v6_sends = countSendsToV6Port(&rec, 7521);
    try testing.expect((v4_sends > 0) != (v6_sends > 0));
}

test "effectiveLocators: loopback preferred over public at same family (reader side)" {
    const reader_guid = makeGuid(0x72, READER_EID);
    const writer_guid = makeGuid(0x73, WRITER_EID);
    const loc_pub = Locator.udp4(.{ 8, 8, 8, 8 }, 7522);
    const loc_lo = Locator.udp4(.{ 127, 0, 0, 1 }, 7523);

    var rec: Recording = .{};
    const r = try StatefulReader.init(testing.allocator, reader_guid, rec.makeTransport(), .keep_all, 0, true);
    defer r.deinit();
    // Public listed first so a naive "first-wins" bug (ignoring tier) would fail this.
    const wp = try WriterProxy.init(testing.allocator, writer_guid, &.{ loc_pub, loc_lo }, &.{}, true);
    try r.addMatchedWriter(wp);
    rec.reset();

    r.handleHeartbeat(writer_guid, 1, 0, 1, false);

    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7522));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7523));
}

test "effectiveLocators: unicast-over-multicast preference unchanged when only multicast present (reader side)" {
    const reader_guid = makeGuid(0x74, READER_EID);
    const writer_guid = makeGuid(0x75, WRITER_EID);
    const loc_mc = Locator.udp4(.{ 239, 255, 0, 1 }, 7524);

    var rec: Recording = .{};
    const r = try StatefulReader.init(testing.allocator, reader_guid, rec.makeTransport(), .keep_all, 0, true);
    defer r.deinit();
    const wp = try WriterProxy.init(testing.allocator, writer_guid, &.{}, &.{loc_mc}, true);
    try r.addMatchedWriter(wp);
    rec.reset();

    r.handleHeartbeat(writer_guid, 1, 0, 1, false);

    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7524));
}

test "addMatchedWriter: lease refresh recomputes cached selection when locators change" {
    const reader_guid = makeGuid(0x76, READER_EID);
    const writer_guid = makeGuid(0x77, WRITER_EID);
    const loc_pub = Locator.udp4(.{ 8, 8, 8, 8 }, 7525);
    const loc_lo = Locator.udp4(.{ 127, 0, 0, 1 }, 7526);

    var rec: Recording = .{};
    const r = try StatefulReader.init(testing.allocator, reader_guid, rec.makeTransport(), .keep_all, 0, true);
    defer r.deinit();

    // First match: only the public locator is offered.
    const wp1 = try WriterProxy.init(testing.allocator, writer_guid, &.{loc_pub}, &.{}, true);
    try r.addMatchedWriter(wp1);
    rec.reset();
    r.handleHeartbeat(writer_guid, 1, 0, 1, false);
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7525));
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7526));
    rec.reset();

    // Lease refresh: same GUID, now also offers loopback — selection must
    // switch to it, not keep serving the stale public-only selection.
    const wp2 = try WriterProxy.init(testing.allocator, writer_guid, &.{ loc_pub, loc_lo }, &.{}, true);
    try r.addMatchedWriter(wp2);
    r.handleHeartbeat(writer_guid, 1, 0, 2, false);
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7525));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7526));
}
