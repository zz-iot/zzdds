//! StatefulWriter behavioral tests (RTPS 2.5 §8.3.7.1, §8.4.9).
//!
//! Focus: AckNack handling (retransmission logic) and Heartbeat emission.
//! These tests use a recording transport to capture every send() call, then
//! parse the raw RTPS bytes to assert on submessage content.

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;
const sub = msg.submessage;

const StatefulWriter = rtps.StatefulWriter;
const ReaderProxy = rtps.ReaderProxy;
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
        .prefix = .{ .bytes = @as([12]u8, @splat(prefix_byte)) },
        .entity_id = eid,
    };
}

// ── Recording transport ───────────────────────────────────────────────────────

/// Captures every send() call so tests can assert on what was transmitted.
/// One Capture per send() invocation; stores the destination locator and raw bytes.
const MAX_CAPS = 64;
const MAX_BYTES = 512;

const Capture = struct {
    locator: Locator,
    buf: [MAX_BYTES]u8,
    len: usize,
};

const Recording = struct {
    caps: [MAX_CAPS]Capture = undefined,
    n: usize = 0,
    /// Test-controlled connection generation, returned uniformly for every
    /// locator via connectionGeneration(). Defaults to 0 (never changes,
    /// matching a connectionless transport); tests bump it to simulate a
    /// transport-level reconnect.
    connection_generation: u32 = 0,
    /// When set, every send() call fails with this error instead of
    /// recording -- used to exercise the writer's `catch |err| switch (err)`
    /// send-error handling (UnsupportedLocatorKind silently ignored as
    /// defence-in-depth vs. any other error logged and otherwise swallowed).
    send_error: ?anyerror = null,
    /// When set, the next send() writes one sample to this writer (once),
    /// as another thread could while the writer has released its lock to
    /// send.
    write_on_send: ?*StatefulWriter = null,

    pub fn reset(self: *@This()) void {
        self.n = 0;
    }

    pub fn makeTransport(self: *@This()) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn sendFn(ctx: *anyopaque, loc: *const Locator, data: []const u8) anyerror!void {
        const self: *Recording = @ptrCast(@alignCast(ctx));
        if (self.send_error) |e| return e;
        if (self.n >= MAX_CAPS) return error.TooManySends;
        const c = &self.caps[self.n];
        c.locator = loc.*;
        c.len = @min(data.len, MAX_BYTES);
        @memcpy(c.buf[0..c.len], data[0..c.len]);
        self.n += 1;
        if (self.write_on_send) |w| {
            self.write_on_send = null;
            _ = w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "written mid-send") catch {};
        }
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
    fn connectionGenerationFn(ctx: *anyopaque, _: *const Locator) u32 {
        const self: *Recording = @ptrCast(@alignCast(ctx));
        return self.connection_generation;
    }

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
        .connection_generation = connectionGenerationFn,
    };
};

// ── Parse helpers ─────────────────────────────────────────────────────────────

/// Collect all DATA writer_sn values from all captures, sorted ascending.
/// Returns a slice into `buf`.
fn collectDataSNsSorted(rec: *const Recording, buf: []SequenceNumber) []SequenceNumber {
    var n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            switch (sm) {
                .data => |d| {
                    if (n < buf.len) {
                        buf[n] = d.writer_sn;
                        n += 1;
                    }
                },
                else => {},
            }
        }
    }
    std.mem.sort(SequenceNumber, buf[0..n], {}, std.sort.asc(SequenceNumber));
    return buf[0..n];
}

/// The writer_sn of each DATA and DATA_FRAG sent, in send order, with a
/// fragmented sample's run of DATA_FRAGs counted once.  Returns a slice into
/// `buf`.
fn collectSentSnsInOrder(rec: *const Recording, buf: []SequenceNumber) []SequenceNumber {
    var n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            const sn = switch (sm) {
                .data => |d| d.writer_sn,
                .data_frag => |df| df.writer_sn,
                else => continue,
            };
            if (sm == .data_frag and n > 0 and buf[n - 1] == sn) continue;
            if (n < buf.len) {
                buf[n] = sn;
                n += 1;
            }
        }
    }
    return buf[0..n];
}

/// Count total DATA submessages in all captures.
fn countAllData(rec: *const Recording) usize {
    var n: usize = 0;
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            if (sm == .data) n += 1;
        }
    }
    return n;
}

/// Find the first GAP submessage in captures.
fn findGap(rec: *const Recording) ?msg.submessage.GapSubmessage {
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            switch (sm) {
                .gap => |g| return g,
                else => {},
            }
        }
    }
    return null;
}

/// Find the first HEARTBEAT submessage in captures.
fn findHeartbeat(rec: *const Recording) ?msg.submessage.HeartbeatSubmessage {
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            switch (sm) {
                .heartbeat => |hb| return hb,
                else => {},
            }
        }
    }
    return null;
}

/// Find the first DATA_FRAG submessage in captures.
fn findDataFrag(rec: *const Recording) ?msg.submessage.DataFragSubmessage {
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            switch (sm) {
                .data_frag => |df| return df,
                else => {},
            }
        }
    }
    return null;
}

/// Count captures sent to locator with the given port.
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

// ── Shared writer setup ───────────────────────────────────────────────────────

/// Set up a StatefulWriter with 3 cached changes and one reader proxy added
/// before any writes (so the proxy gets the initial sends, which we then reset).
fn makeWriterWithReader(
    rec: *Recording,
    reader_loc: Locator,
    reader_guid: Guid,
    writer_guid: Guid,
) !*StatefulWriter {
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    // Add reader proxy first (no history yet — no replay sends).
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{reader_loc}, &.{}, false, true);
    try w.addMatchedReader(rp);
    // Write 3 changes. Each triggers an immediate send to the reader proxy.
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "three");
    // Reset so the following test assertions only see retransmit sends.
    rec.reset();
    return w;
}

// ── AckNack: non-final + empty bitmap ────────────────────────────────────────

// ── addOrRefreshMatchedReader reports whether the match is new ────────────────
//
// The DCPS matched status counts only new matches: discovery can report an
// already matched reader again, which just refreshes its proxy.

test "addOrRefreshMatchedReader: true for a new match, false for a refresh, true again after removal" {
    const reader_guid = makeGuid(0x02, READER_EID);
    const writer_guid = makeGuid(0x01, WRITER_EID);
    const reader_loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7410);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(testing.allocator, writer_guid, rec.makeTransport(), .keep_all, 0, READER_EID, rtps.writer_sm.DEFAULT_FRAG_SIZE, false);
    defer w.deinit();

    try testing.expect(try w.addOrRefreshMatchedReader(try ReaderProxy.init(testing.allocator, reader_guid, &.{reader_loc}, &.{}, false, true)));
    try testing.expect(!try w.addOrRefreshMatchedReader(try ReaderProxy.init(testing.allocator, reader_guid, &.{reader_loc}, &.{}, false, true)));
    try testing.expectEqual(@as(usize, 1), w.reader_proxies.items.len);
    w.removeMatchedReader(reader_guid);
    try testing.expect(try w.addOrRefreshMatchedReader(try ReaderProxy.init(testing.allocator, reader_guid, &.{reader_loc}, &.{}, false, true)));
}

test "handleAckNack: non-final + empty bitmap resends nothing and draws a HEARTBEAT" {
    const writer_guid = makeGuid(0x01, WRITER_EID);
    const reader_guid = makeGuid(0x02, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Non-final AckNack, empty bitmap (base=1, num_bits=0): it requests no
    // SN, so nothing is resent; it asks for a HEARTBEAT, which offers 1-3.
    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 0, nack_set, 1, false);

    var sns_buf: [8]SequenceNumber = undefined;
    try testing.expectEqual(@as(usize, 0), collectDataSNsSorted(&rec, &sns_buf).len);
    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 1), hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
}

// ── AckNack: non-final + bitmap ──────────────────────────────────────────────

test "handleAckNack: non-final + bitmap retransmits only NACKed SNs" {
    const writer_guid = makeGuid(0x03, WRITER_EID);
    const reader_guid = makeGuid(0x04, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Bitmap: only SN 2 is NACKed. SN 1 and SN 3 are in the bitmap's range
    // but not requested, so the reader has them: only SN 2 is resent.
    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 3, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2); // NACK SN 2

    w.handleAckNack(reader_guid, 0, nack_set, 1, false);

    var sns_buf: [8]SequenceNumber = undefined;
    const sent = collectDataSNsSorted(&rec, &sns_buf);
    try testing.expectEqualSlices(SequenceNumber, &.{2}, sent);
}

// ── AckNack: final + bitmap ───────────────────────────────────────────────────

test "handleAckNack: final + bitmap retransmits only NACKed SNs" {
    const writer_guid = makeGuid(0x05, WRITER_EID);
    const reader_guid = makeGuid(0x06, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Final AckNack: only explicitly NACKed bits are retransmitted.
    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 3, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2); // NACK only SN 2

    w.handleAckNack(reader_guid, 0, nack_set, 1, true);

    var sns_buf: [8]SequenceNumber = undefined;
    const sent = collectDataSNsSorted(&rec, &sns_buf);
    try testing.expectEqualSlices(SequenceNumber, &.{2}, sent);
}

// ── AckNack: final + empty bitmap (pure ACK) ─────────────────────────────────

test "handleAckNack: final + empty bitmap (pure ACK) sends nothing" {
    const writer_guid = makeGuid(0x07, WRITER_EID);
    const reader_guid = makeGuid(0x08, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Pure ACK (base = lastSN + 1, num_bits = 0, final = true).
    const nack_set = SequenceNumberSet{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 3, nack_set, 1, true);

    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── AckNack: base beyond writer's last SN ────────────────────────────────────

test "handleAckNack: base > lastSN sends nothing and does not crash" {
    const writer_guid = makeGuid(0x09, WRITER_EID);
    const reader_guid = makeGuid(0x0a, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // All 3 cached SNs are below base=10; nothing to retransmit.
    const nack_set = SequenceNumberSet{ .base = 10, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 9, nack_set, 1, false);

    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── AckNack: unknown reader GUID ─────────────────────────────────────────────

test "handleAckNack: unknown reader GUID is ignored" {
    const writer_guid = makeGuid(0x0b, WRITER_EID);
    const reader_guid = makeGuid(0x0c, READER_EID);
    const unknown_guid = makeGuid(0xff, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // AckNack is from a GUID that has no matching proxy.
    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(unknown_guid, 0, nack_set, 1, false);

    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── AckNack: multiple reader proxies isolation ────────────────────────────────

test "handleAckNack: only the matching proxy receives retransmissions" {
    const writer_guid = makeGuid(0x0d, WRITER_EID);
    const reader_a_guid = makeGuid(0x0e, READER_EID);
    const reader_b_guid = makeGuid(0x0f, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);
    const loc_b = Locator.udp4(.{ 127, 0, 0, 1 }, 7200);

    var rec: Recording = .{};
    const t = rec.makeTransport();

    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        t,
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // Add two reader proxies before writing (no replay).
    const rp_a = try ReaderProxy.init(testing.allocator, reader_a_guid, &.{loc_a}, &.{}, false, true);
    const rp_b = try ReaderProxy.init(testing.allocator, reader_b_guid, &.{loc_b}, &.{}, false, true);
    try w.addMatchedReader(rp_a);
    try w.addMatchedReader(rp_b);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "data");
    rec.reset();

    // AckNack from reader A only.
    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_a_guid, 0, nack_set, 1, false);

    // All retransmit sends must go to A's locator (port 7100), none to B (7200).
    try testing.expect(countSendsToPort(&rec, 7100) > 0);
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7200));
}

// ── Heartbeat: firstSN / lastSN reflect cache ─────────────────────────────────

test "sendHeartbeat: firstSN and lastSN reflect cache min/max" {
    const writer_guid = makeGuid(0x10, WRITER_EID);
    const reader_guid = makeGuid(0x11, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    w.sendHeartbeat(true, false);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 1), hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
}

// ── sendLivelinessHeartbeat: RTPS §8.7.2.2.3 MANUAL_BY_TOPIC assert ─────────

test "sendLivelinessHeartbeat sets the RTPS LIVELINESS flag" {
    const writer_guid = makeGuid(0x12, WRITER_EID);
    const reader_guid = makeGuid(0x13, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    w.sendLivelinessHeartbeat();

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expect(hb.isLiveliness());
    try testing.expect(hb.isFinal());
}

test "sendHeartbeat without the liveliness path does not set the LIVELINESS flag" {
    const writer_guid = makeGuid(0x14, WRITER_EID);
    const reader_guid = makeGuid(0x15, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    w.sendHeartbeat(true, false);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expect(!hb.isLiveliness());
}

// ── is_local: same-participant self-matches skip the periodic keepalive ──────
//
// BuiltinPair.matchRemote (builtin_endpoint.zig) sets ReaderProxy.is_local when
// remote.guid.prefix equals the writer's own prefix -- exactly what happens when
// combined.zig's `self_data` call bootstraps same-participant builtin-endpoint
// matching. That proxy can't lose data to a lossy network, so there's nothing
// for the periodic keepalive/re-offer HB to recover -- only a self-addressed
// send to repeat every HB_INTERVAL_MS forever.

test "sendHeartbeat: is_local proxy is excluded from the periodic keepalive" {
    const writer_guid = makeGuid(0x20, WRITER_EID);
    const reader_guid = makeGuid(0x20, READER_EID); // same prefix as the writer
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    var rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, true);
    rp.is_local = true;
    try w.addMatchedReader(rp);
    rec.reset(); // discard the match-time replay send (none expected, but be explicit)

    w.sendHeartbeat(false, false);

    try testing.expectEqual(@as(usize, 0), rec.n);
}

test "sendHeartbeat: is_local proxy with unacked data still gets the periodic keepalive" {
    // Regression for a real gap found via Greptile review: an earlier version of
    // this gate skipped is_local proxies unconditionally, which would leave a
    // same-participant match hung forever if the one real DATA/trailing-HB send
    // (over the real transport, unchanged by is_local) was ever lost -- with no
    // periodic heartbeat, there was no remaining recovery path at all. The gate
    // must only skip once the proxy has actually caught up.
    const writer_guid = makeGuid(0x21, WRITER_EID);
    const reader_guid = makeGuid(0x21, READER_EID); // same prefix as the writer
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    var rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, true);
    rp.is_local = true;
    try w.addMatchedReader(rp);
    // Simulate the proxy's one real DATA send having been lost: write a sample
    // (advances the writer's cache/adj_last) without ever recording an ACKNACK
    // from this proxy (highest_acked_sn stays 0, as ReaderProxy.init leaves it).
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "lost");
    rec.reset();

    w.sendHeartbeat(false, false);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 1), hb.last_sn);
}

test "beginProbe: does not set deadline on is_local proxy" {
    const writer_guid = makeGuid(0x20, WRITER_EID);
    const reader_guid = makeGuid(0x20, READER_EID); // same prefix as the writer
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    var rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, true);
    rp.is_local = true;
    try w.addMatchedReader(rp);

    const far_future: i64 = std.math.maxInt(i64);
    w.beginProbe(reader_guid.prefix, far_future);

    w.mu.lock();
    const deadline = for (w.reader_proxies.items) |rp2| {
        if (rp2.guid.eql(reader_guid)) break rp2.probe_deadline_ns;
    } else -1;
    w.mu.unlock();
    try testing.expectEqual(@as(i64, 0), deadline);
}

// ── Heartbeat: empty cache ────────────────────────────────────────────────────

test "sendHeartbeat: empty cache → firstSN=1, lastSN=0 (spec-legal empty range)" {
    const writer_guid = makeGuid(0x12, WRITER_EID);
    const reader_guid = makeGuid(0x13, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const t = rec.makeTransport();

    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        t,
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, true);
    try w.addMatchedReader(rp);
    rec.reset();

    w.sendHeartbeat(true, false);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    // §8.3.8.6 Example 4: empty writer → first=1, last=0.
    try testing.expectEqual(@as(SequenceNumber, 1), hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 0), hb.last_sn);
}

// ── Heartbeat: count increments ───────────────────────────────────────────────

test "sendHeartbeat: count increments monotonically" {
    const writer_guid = makeGuid(0x14, WRITER_EID);
    const reader_guid = makeGuid(0x15, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // addMatchedReader sends one Heartbeat; capture the count before explicit calls.
    const hb_base = w.hb_count;

    w.sendHeartbeat(true, false);
    try testing.expectEqual(hb_base + 1, w.hb_count);

    w.sendHeartbeat(false, false);
    try testing.expectEqual(hb_base + 2, w.hb_count);

    w.sendHeartbeat(true, false);
    try testing.expectEqual(hb_base + 3, w.hb_count);
}

// ── Liveness probe ────────────────────────────────────────────────────────────

const GuidPrefix = rtps.GuidPrefix;

const ProbeResult = struct {
    prefix: ?GuidPrefix = null,
    alive: ?bool = null,
    calls: usize = 0,
    fn callback(ctx: *anyopaque, pfx: GuidPrefix, a: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.prefix = pfx;
        self.alive = a;
        self.calls += 1;
    }
};

test "beginProbe: sets deadline on matching reliable proxy" {
    const writer_guid = makeGuid(0x20, WRITER_EID);
    const reader_guid = makeGuid(0x21, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // beginProbe with a far-future deadline so checkProbeDeadlines won't fire now.
    const far_future: i64 = std.math.maxInt(i64);
    w.beginProbe(reader_guid.prefix, far_future);

    // Verify the deadline is set (proxy still present, no eviction yet).
    w.mu.lock();
    const found = for (w.reader_proxies.items) |rp| {
        if (rp.guid.eql(reader_guid)) break rp.probe_deadline_ns == far_future;
    } else false;
    w.mu.unlock();
    try testing.expect(found);
}

test "checkProbeDeadlines: reports an expired probe once and keeps the proxy" {
    const writer_guid = makeGuid(0x22, WRITER_EID);
    const reader_guid = makeGuid(0x23, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    var pr = ProbeResult{};
    w.setProbeResult(&pr, ProbeResult.callback);

    // Set probe deadline to 1ns (past) so checkProbeDeadlines fires immediately.
    w.beginProbe(reader_guid.prefix, 1);
    w.checkProbeDeadlines();

    try testing.expect(pr.prefix != null);
    try testing.expect(pr.prefix.?.eql(reader_guid.prefix));
    try testing.expect(pr.alive == false);

    // The proxy stays: whether its participant is lost is the callback's
    // decision, and a re-announcement may already have answered the probe.
    w.mu.lock();
    const proxy_count = w.reader_proxies.items.len;
    const deadline: ?i64 = if (proxy_count > 0) w.reader_proxies.items[0].probe_deadline_ns else null;
    w.mu.unlock();
    try testing.expectEqual(@as(usize, 1), proxy_count);
    try testing.expectEqual(@as(?i64, 0), deadline);

    // The probe is over: a later check doesn't report it again.
    w.checkProbeDeadlines();
    try testing.expectEqual(@as(usize, 1), pr.calls);
}

test "checkProbeDeadlines: all proxies beyond original 8-slot cap fire dead callback" {
    // Regression for the fixed-size [8]GuidPrefix evicted array.  With the old
    // code, proxies beyond index 8 were removed but probe_result_fn was never
    // called for them — their KnownParticipant.probe_active stayed true forever.
    const alloc = testing.allocator;
    const writer_guid = makeGuid(0x30, WRITER_EID);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        alloc,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    const N = 9;
    for (0..N) |i| {
        const rg = makeGuid(@intCast(0x40 + i), READER_EID);
        const loc = Locator.udp4(.{ 127, 0, 0, 1 }, @intCast(7200 + i));
        const rp = try ReaderProxy.init(alloc, rg, &.{loc}, &.{}, false, true);
        try w.addMatchedReader(rp);
    }

    const CallState = struct {
        count: usize = 0,
        fn cb(ctx: *anyopaque, _: GuidPrefix, alive: bool) void {
            if (!alive) @as(*@This(), @ptrCast(@alignCast(ctx))).count += 1;
        }
    };
    var cs = CallState{};
    w.setProbeResult(&cs, CallState.cb);

    for (0..N) |i| {
        const rg = makeGuid(@intCast(0x40 + i), READER_EID);
        w.beginProbe(rg.prefix, 1); // expired deadline
    }
    w.checkProbeDeadlines();

    try testing.expectEqual(@as(usize, N), cs.count);
    w.mu.lock();
    const remaining = w.reader_proxies.items.len;
    w.mu.unlock();
    try testing.expectEqual(@as(usize, N), remaining);
}

test "handleAckNack: ACKNACK clears probe and fires alive callback" {
    const writer_guid = makeGuid(0x24, WRITER_EID);
    const reader_guid = makeGuid(0x25, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    var pr = ProbeResult{};
    w.setProbeResult(&pr, ProbeResult.callback);

    // Set a far-future probe so the proxy is not evicted by checkProbeDeadlines.
    w.beginProbe(reader_guid.prefix, std.math.maxInt(i64));

    // ACKNACK from the reader should clear the probe and fire alive=true.
    const nack_set = SequenceNumberSet{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 3, nack_set, 1, true);

    try testing.expect(pr.alive == true);
    try testing.expect(pr.prefix.?.eql(reader_guid.prefix));

    // Probe deadline should be cleared (proxy still alive).
    w.mu.lock();
    const deadline = for (w.reader_proxies.items) |rp| {
        if (rp.guid.eql(reader_guid)) break rp.probe_deadline_ns;
    } else -1;
    w.mu.unlock();
    try testing.expectEqual(@as(i64, 0), deadline);
}

// ── Protocol-ready readiness (RELIABLE readiness handshake) ──────────────────

const ProtocolReadyResult = struct {
    guid: ?Guid = null,
    ready: ?bool = null,
    calls: usize = 0,
    fn callback(ctx: *anyopaque, g: Guid, r: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.guid = g;
        self.ready = r;
        self.calls += 1;
    }
};

test "protocol_ready: RELIABLE proxy is not ready at match time" {
    const writer_guid = makeGuid(0x60, WRITER_EID);
    const reader_guid = makeGuid(0x61, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    w.mu.lock();
    const ready = for (w.reader_proxies.items) |rp| {
        if (rp.guid.eql(reader_guid)) break rp.protocol_ready;
    } else true;
    w.mu.unlock();
    try testing.expect(!ready);
}

test "protocol_ready: RELIABLE proxy becomes ready when AckNack reaches the HB floor, fires once" {
    // Uses a custom setup (not makeWriterWithReader) so the floor is
    // meaningfully non-trivial: 3 changes are written BEFORE the VOLATILE
    // match, so the late-joining reader's start_sn (4) skips that history —
    // hbFirstSn(cache_first=1, start_sn=4) = 4. (makeWriterWithReader matches
    // against an empty cache, giving the empty-HB-convention floor of 1,
    // which any valid ACKNACK base satisfies immediately — not useful for
    // testing the "not yet at the floor" case.)
    const alloc = testing.allocator;
    const writer_guid = makeGuid(0x62, WRITER_EID);
    const reader_guid = makeGuid(0x63, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        alloc,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false, // replay_on_match=false (VOLATILE)
    );
    defer w.deinit();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "three");

    var pr = ProtocolReadyResult{};
    w.setProtocolReadyCallback(&pr, ProtocolReadyResult.callback);

    const rp = try ReaderProxy.init(alloc, reader_guid, &.{loc_a}, &.{}, false, true);
    try w.addMatchedReader(rp);
    try testing.expectEqual(@as(usize, 0), pr.calls);

    // ACKNACK below the floor (start_sn=4): reader hasn't caught up yet.
    const nack_below = SequenceNumberSet{ .base = 3, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 2, nack_below, 1, true);
    try testing.expectEqual(@as(usize, 0), pr.calls);

    // ACKNACK whose base reaches the floor fires readiness exactly once.
    const nack_at = SequenceNumberSet{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 3, nack_at, 2, true);
    try testing.expectEqual(@as(usize, 1), pr.calls);
    try testing.expect(pr.ready == true);
    try testing.expect(pr.guid.?.eql(reader_guid));

    // A later ACKNACK must not refire (sticky).
    const nack_later = SequenceNumberSet{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 3, nack_later, 3, true);
    try testing.expectEqual(@as(usize, 1), pr.calls);
}

test "protocol_ready: BEST_EFFORT proxy fires ready immediately at match" {
    const alloc = testing.allocator;
    const writer_guid = makeGuid(0x64, WRITER_EID);
    const reader_guid = makeGuid(0x65, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        alloc,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    var pr = ProtocolReadyResult{};
    w.setProtocolReadyCallback(&pr, ProtocolReadyResult.callback);

    // reliable=false: BEST_EFFORT never AckNacks, so it must become ready
    // immediately at match rather than waiting for a handshake that never comes.
    const rp = try ReaderProxy.init(alloc, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);

    try testing.expectEqual(@as(usize, 1), pr.calls);
    try testing.expect(pr.ready == true);
    try testing.expect(pr.guid.?.eql(reader_guid));
}

test "protocol_ready: removing a ready proxy fires ready=false" {
    const writer_guid = makeGuid(0x66, WRITER_EID);
    const reader_guid = makeGuid(0x67, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    var pr = ProtocolReadyResult{};
    w.setProtocolReadyCallback(&pr, ProtocolReadyResult.callback);

    const nack_at = SequenceNumberSet{ .base = 2, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 1, nack_at, 2, true);
    try testing.expect(pr.ready == true);

    w.removeMatchedReader(reader_guid);
    try testing.expectEqual(@as(usize, 2), pr.calls);
    try testing.expect(pr.ready == false);
    try testing.expect(pr.guid.?.eql(reader_guid));
}

test "protocol_ready: removing a never-ready proxy does not fire" {
    const writer_guid = makeGuid(0x68, WRITER_EID);
    const reader_guid = makeGuid(0x69, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    var pr = ProtocolReadyResult{};
    w.setProtocolReadyCallback(&pr, ProtocolReadyResult.callback);

    w.removeMatchedReader(reader_guid);
    try testing.expectEqual(@as(usize, 0), pr.calls);
}

test "protocol_ready: a second RELIABLE proxy added after the first is already ready gets its own initial heartbeat and becomes ready" {
    // Reproduces a real rmw_zzdds scenario (two service clients matching the
    // same response writer, added sequentially, with real writes to the
    // first proxy in between) that showed the second proxy's
    // on_reliable_writer_ready never firing within a 10s deadline.
    const alloc = testing.allocator;
    const writer_guid = makeGuid(0x6a, WRITER_EID);
    const reader_a_guid = makeGuid(0x6b, READER_EID);
    const reader_b_guid = makeGuid(0x6c, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7605);
    const loc_b = Locator.udp4(.{ 127, 0, 0, 1 }, 7606);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        alloc,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    var pr = ProtocolReadyResult{};
    w.setProtocolReadyCallback(&pr, ProtocolReadyResult.callback);

    // Reader A matches, writer writes data for it, A ACKNACKs and becomes ready --
    // mirrors client A's full round trip completing before client B exists.
    const rp_a = try ReaderProxy.init(alloc, reader_a_guid, &.{loc_a}, &.{}, false, true);
    try w.addMatchedReader(rp_a);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    const nack_a = SequenceNumberSet{ .base = 2, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_a_guid, 1, nack_a, 1, true);
    try testing.expectEqual(@as(usize, 1), pr.calls);
    try testing.expect(pr.ready == true);
    try testing.expect(pr.guid.?.eql(reader_a_guid));
    rec.reset();

    // Reader B matches afterward -- must get its own initial targeted
    // Heartbeat (addMatchedReader's sendInitialHeartbeatUnlocked), just like
    // A did when it was the only proxy.
    const rp_b = try ReaderProxy.init(alloc, reader_b_guid, &.{loc_b}, &.{}, false, true);
    try w.addMatchedReader(rp_b);

    const hb = findHeartbeat(&rec);
    try testing.expect(hb != null);
    try testing.expect(hb.?.reader_entity_id.eql(reader_b_guid.entity_id));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7606));

    // B ACKNACKs and must become ready too, independently of A.
    const nack_b = SequenceNumberSet{ .base = 2, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_b_guid, 1, nack_b, 1, true);
    try testing.expectEqual(@as(usize, 2), pr.calls);
    try testing.expect(pr.ready == true);
    try testing.expect(pr.guid.?.eql(reader_b_guid));
}

// ── Coherent HB cap ───────────────────────────────────────────────────────────

test "sendHeartbeat: coherent_active caps last_sn to last_flushed_sn" {
    // During an active coherent set, write() buffers SNs in coherent_pending_sns
    // without sending them.  The background HB must not advertise these unsent SNs,
    // which readers would NACK.
    // Covers writer_sm.zig lines 747-750.
    const writer_guid = makeGuid(0x50, WRITER_EID);
    const reader_guid = makeGuid(0x51, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    // makeWriterWithReader writes SNs 1-3 (all flushed → last_flushed_sn=3).
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Begin coherent set; write SN 4 — buffered, not sent, last_flushed_sn stays 3.
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "coherent");
    rec.reset();

    // Periodic HB must cap last_sn to last_flushed_sn (3), not cache max (4).
    w.sendHeartbeat(true, false);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
}

// ── End-of-coherent-set markers ───────────────────────────────────────────────

/// What the writer sent in one DATA: whether it carried a payload, and its
/// coherent-set inline QoS.
const SentData = struct {
    has_payload: bool,
    coherent_set: ?SequenceNumber = null,
    group_seq_num: ?SequenceNumber = null,
    group_coherent_set: ?SequenceNumber = null,
    writer_group_info: ?[4]u8 = null,
};

fn findSentData(rec: *const Recording, sn: SequenceNumber) ?SentData {
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            if (sm != .data or sm.data.writer_sn != sn) continue;
            const d = sm.data;
            var out = SentData{ .has_payload = d.serialized_payload.len > 0 };
            if (d.inline_qos) |q| {
                const le = d.isLittleEndian();
                out.coherent_set = q.getSequenceNumber(.coherent_set, le);
                out.group_seq_num = q.getSequenceNumber(.group_seq_num, le);
                out.group_coherent_set = q.getSequenceNumber(.group_coherent_set, le);
                if (q.get(.writer_group_info)) |v| {
                    if (v.len == 4) out.writer_group_info = v[0..4].*;
                }
            }
            return out;
        }
    }
    return null;
}

fn makeCoherentWriter(rec: *Recording, kind: rtps.history.HistoryKind, depth: u32, reader_guid: Guid) !*StatefulWriter {
    const w = try StatefulWriter.init(
        testing.allocator,
        makeGuid(0x52, WRITER_EID),
        rec.makeTransport(),
        kind,
        depth,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    errdefer w.deinit();
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7100)}, &.{}, false, true);
    try w.addMatchedReader(rp);
    // The periodic HEARTBEAT thread would send into `rec` while the test does;
    // tests send their HEARTBEATs explicitly.
    w.stopHeartbeat();
    rec.reset();
    return w;
}

test "endCoherentSet: the end marker is announced, not GAPed" {
    // The set's end marker (SN 3) is a DATA without a payload.  The HEARTBEAT
    // after the set announces it, and nothing GAPs it: a reader that GAPs a
    // marker can't tell whether the set before it is complete.
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_all, 0, reader_guid);
    defer w.deinit();

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    w.endCoherentSet(.coherent_only, false, null, null, false);

    const marker = findSentData(&rec, 3) orelse return error.NoMarker;
    try testing.expect(!marker.has_payload);
    try testing.expectEqual(@as(?SequenceNumber, null), marker.coherent_set);
    try testing.expectEqual(@as(?SequenceNumber, 1), findSentData(&rec, 1).?.coherent_set);
    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
    try testing.expectEqual(null, findGap(&rec));

    // The periodic HEARTBEAT announces it too.
    rec.reset();
    w.sendHeartbeat(true, false);
    try testing.expectEqual(@as(SequenceNumber, 3), (findHeartbeat(&rec) orelse return error.NoHeartbeatFound).last_sn);
    try testing.expectEqual(null, findGap(&rec));
}

test "handleAckNack: a NACKed end marker is sent again, not GAPed" {
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_all, 0, reader_guid);
    defer w.deinit();

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    w.endCoherentSet(.coherent_only, false, null, null, false);
    rec.reset();

    // The reader has SNs 1-2 and asks for the marker.
    var nack_set = SequenceNumberSet{ .base = 3, .num_bits = 1, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(3);
    w.handleAckNack(reader_guid, 2, nack_set, 1, true);

    const marker = findSentData(&rec, 3) orelse return error.MarkerNotResent;
    try testing.expect(!marker.has_payload);
    try testing.expectEqual(null, findGap(&rec));
}

test "handleAckNack: a non-final NACK for the end marker resends it" {
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_all, 0, reader_guid);
    defer w.deinit();

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    w.endCoherentSet(.coherent_only, false, null, null, false);
    rec.reset();

    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 2, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(1);
    nack_set.set(2);
    w.handleAckNack(reader_guid, 0, nack_set, 1, false);

    var sns_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2 }, collectDataSNsSorted(&rec, &sns_buf));
    try testing.expect(!findSentData(&rec, 2).?.has_payload);
}

test "end marker: retired once its set's samples are gone and every reader acknowledged it" {
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_last, 1, reader_guid);
    defer w.deinit();

    // Set {SN 1}, marker SN 2; then SN 3 replaces SN 1 (KEEP_LAST depth 1).
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    w.endCoherentSet(.coherent_only, false, null, null, false);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    rec.reset();

    // Not yet acknowledged: still sent on NACK, though its set is gone.
    var nack_set = SequenceNumberSet{ .base = 2, .num_bits = 1, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2);
    w.handleAckNack(reader_guid, 1, nack_set, 1, true);
    try testing.expect(findSentData(&rec, 2) != null);

    // Acknowledged: retired, so a later NACK gets a GAP.
    const ack = SequenceNumberSet{ .base = 4, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 3, ack, 2, true);
    rec.reset();
    w.handleAckNack(reader_guid, 3, nack_set, 3, true);
    try testing.expectEqual(null, findSentData(&rec, 2));
    try testing.expect(findGap(&rec) != null);
}

test "end marker: the cap never drops a marker whose set is still cached" {
    // A KEEP_ALL writer keeps every set, so a reader replayed the oldest one
    // still needs its marker (SN 2) to tell that set is complete.
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_all, 0, reader_guid);
    defer w.deinit();

    const max = rtps.writer_sm.MAX_END_MARKERS;
    for (0..max + 1) |_| {
        w.beginCoherentSet(true);
        _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
        w.endCoherentSet(.coherent_only, false, null, null, false);
        rec.reset();
    }
    try testing.expectEqual(max + 1, w.end_markers.items.len);

    var nack_set = SequenceNumberSet{ .base = 2, .num_bits = 1, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2);
    w.handleAckNack(reader_guid, 1, nack_set, 1, true);
    const marker = findSentData(&rec, 2) orelse return error.NoMarker;
    try testing.expect(!marker.has_payload);
}

test "end marker: the cap drops the oldest markers whose sets are gone" {
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_last, 1, reader_guid);
    defer w.deinit();

    // KEEP_LAST depth 1: each set's sample replaces the one before, so only
    // the last set is cached and the reader never acknowledges.
    const max = rtps.writer_sm.MAX_END_MARKERS;
    for (0..max + 5) |_| {
        w.beginCoherentSet(true);
        _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
        w.endCoherentSet(.coherent_only, false, null, null, false);
        rec.reset();
    }
    try testing.expectEqual(max, w.end_markers.items.len);
    // The oldest went: set n is SN 2n-1, its marker SN 2n.
    try testing.expectEqual(@as(SequenceNumber, 2 * 6), w.end_markers.items[0].sn);
}

test "endCoherentSet: a GROUP writer with nothing in the set still ends it" {
    // RTPS 2.5 §8.7.6: every writer of the publisher sends an End Coherent Set
    // marker: PID_GROUP_SEQ_NUM one past the set's last sample,
    // PID_GROUP_COHERENT_SET the set's id, and PID_WRITER_GROUP_INFO.
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_all, 0, reader_guid);
    defer w.deinit();

    const group_set = rtps.history.GroupCoherentSet{ .first_gsn = 11, .end_gsn = 14, .writer_group_info = .{ 1, 2, 3, 4 } };
    var publisher_gsn: i64 = 13;
    w.beginCoherentSet(true);
    w.endCoherentSet(.full, false, &publisher_gsn, group_set, false);

    const ecs = findSentData(&rec, 1) orelse return error.NoEndCoherentSet;
    try testing.expect(!ecs.has_payload);
    try testing.expectEqual(@as(?SequenceNumber, null), ecs.coherent_set);
    try testing.expectEqual(@as(?SequenceNumber, 14), ecs.group_seq_num);
    try testing.expectEqual(@as(?SequenceNumber, 11), ecs.group_coherent_set);
    try testing.expectEqual(@as(?[4]u8, .{ 1, 2, 3, 4 }), ecs.writer_group_info);
    try testing.expectEqual(@as(i64, 13), publisher_gsn);
}

test "endCoherentSet: a reader that rejects bare markers gets SEQUENCENUMBER_UNKNOWN on TOPIC-scope ones only" {
    // A TOPIC/INSTANCE-scope marker is otherwise a DATA with neither payload
    // nor inline QoS (RTPS 2.5 §9.6.4.2 Table 9.22, Example 3); such a reader
    // gets the equivalent PID_COHERENT_SET=SEQUENCENUMBER_UNKNOWN form.  A GROUP
    // End Coherent Set marker carries the §8.7.6 group parameters, so it is
    // never bare and keeps the plain form.
    const reader_guid = makeGuid(0x53, READER_EID);
    var rec: Recording = .{};
    const w = try makeCoherentWriter(&rec, .keep_all, 0, reader_guid);
    defer w.deinit();
    w.reader_proxies.items[0].needs_pid_coherent_set_marker = true;

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    w.endCoherentSet(.coherent_only, false, null, null, false);
    const topic_marker = findSentData(&rec, 2) orelse return error.NoEndMarker;
    try testing.expect(!topic_marker.has_payload);
    // SEQUENCENUMBER_UNKNOWN on the wire is {high = -1, low = 0}; findSentData
    // reads the raw value.
    try testing.expectEqual(@as(?SequenceNumber, -1 << 32), topic_marker.coherent_set);

    rec.reset();
    const group_set = rtps.history.GroupCoherentSet{ .first_gsn = 11, .end_gsn = 12, .writer_group_info = .{ 1, 2, 3, 4 } };
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    w.endCoherentSet(.full, false, null, group_set, false);
    const ecs = findSentData(&rec, 4) orelse return error.NoEndCoherentSet;
    try testing.expect(!ecs.has_payload);
    try testing.expectEqual(@as(?SequenceNumber, null), ecs.coherent_set);
    try testing.expectEqual(@as(?SequenceNumber, 11), ecs.group_coherent_set);
}

test "endCoherentSet: an empty GROUP writer's marker waits for the combined send" {
    // The publisher sends every writer's End Coherent Set marker together:
    // takeEOCProxyInfos looks each one up for its group fields.  A writer that
    // wrote nothing in the set, with only best-effort readers, has nothing to
    // wait for before retiring its marker -- except that send.
    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        makeGuid(0x52, WRITER_EID),
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();
    const rp = try ReaderProxy.init(testing.allocator, makeGuid(0x53, READER_EID), &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7100)}, &.{}, false, false);
    try w.addMatchedReader(rp);
    w.stopHeartbeat();

    const group_set = rtps.history.GroupCoherentSet{ .first_gsn = 11, .end_gsn = 14, .writer_group_info = .{ 1, 2, 3, 4 } };
    w.beginCoherentSet(true);
    w.endCoherentSet(.full, false, null, group_set, true);

    const pending = w.pending_eoc_sn orelse return error.NoPendingMarker;
    const marker = for (w.end_markers.items) |m| {
        if (m.sn == pending) break m;
    } else return error.MarkerRetired;
    try testing.expectEqual(@as(?rtps.history.GroupCoherentSet, group_set), marker.group);

    // Once sent, it retires like any other.
    w.flushGroupEOCHBOnly();
    w.beginCoherentSet(true);
    w.endCoherentSet(.full, false, null, group_set, false);
    for (w.end_markers.items) |m| try testing.expect(m.sn != pending);
}

test "replay: a best-effort late joiner gets coherent sets with their inline QoS and end markers" {
    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        makeGuid(0x52, WRITER_EID),
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer w.deinit();

    // Set {1, 2} + marker 3, then the set {4} + marker 5, before any reader.
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    w.endCoherentSet(.coherent_only, false, null, null, false);
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "c");
    w.endCoherentSet(.coherent_only, false, null, null, false);

    const rp = try ReaderProxy.init(testing.allocator, makeGuid(0x53, READER_EID), &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7100)}, &.{}, false, false);
    try w.addMatchedReader(rp);

    var sns_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3, 4, 5 }, collectDataSNsSorted(&rec, &sns_buf));
    try testing.expectEqual(@as(?SequenceNumber, 1), findSentData(&rec, 2).?.coherent_set);
    try testing.expectEqual(@as(?SequenceNumber, 4), findSentData(&rec, 4).?.coherent_set);
    try testing.expect(!findSentData(&rec, 3).?.has_payload);
    try testing.expect(!findSentData(&rec, 5).?.has_payload);
}

// ── A reader matching while a coherent set is open ────────────────────────────

const LATE_READER_GUID = makeGuid(0x53, READER_EID);

/// A KEEP_ALL writer, TRANSIENT_LOCAL (`replay_on_match`) or VOLATILE, with no
/// reader yet.
fn makeLateMatchWriter(rec: *Recording, replay_on_match: bool) !*StatefulWriter {
    return StatefulWriter.init(
        testing.allocator,
        makeGuid(0x52, WRITER_EID),
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        replay_on_match,
    );
}

/// Match a reliable reader at 127.0.0.1:7100, then stop the periodic
/// HEARTBEAT thread, which would otherwise send into `rec` as the test does.
fn matchLateReader(w: *StatefulWriter) !void {
    const rp = try ReaderProxy.init(testing.allocator, LATE_READER_GUID, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7100)}, &.{}, false, true);
    try w.addMatchedReader(rp);
    w.stopHeartbeat();
}

/// The last HEARTBEAT in captures.
fn findLastHeartbeat(rec: *const Recording) ?msg.submessage.HeartbeatSubmessage {
    var last: ?msg.submessage.HeartbeatSubmessage = null;
    for (rec.caps[0..rec.n]) |*cap| {
        var it = MessageIterator.init(cap.buf[0..cap.len]) catch continue;
        var params: [32]InlineQosParam = undefined;
        while (it.next(&params) catch null) |sm| {
            if (sm == .heartbeat) last = sm.heartbeat;
        }
    }
    return last;
}

test "late match: a TRANSIENT_LOCAL reader matching mid-set gets the set live" {
    // An open coherent set is not history: the reader isn't held back for it,
    // and gets its samples, end marker and HEARTBEAT when it ends, with no
    // ACKNACK round-trip.
    var rec: Recording = .{};
    const w = try makeLateMatchWriter(&rec, true);
    defer w.deinit();

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    try matchLateReader(w);
    try testing.expect(!w.reader_proxies.items[0].suppress_live_data);
    // The match HEARTBEAT doesn't announce the open set: the writer would
    // refuse the NACK it drew.
    try testing.expectEqual(@as(SequenceNumber, 0), (findHeartbeat(&rec) orelse return error.NoHeartbeatFound).last_sn);

    rec.reset();
    w.endCoherentSet(.full, false, null, null, false);
    var sns_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, collectDataSNsSorted(&rec, &sns_buf));
    try testing.expectEqual(@as(SequenceNumber, 3), (findLastHeartbeat(&rec) orelse return error.NoHeartbeatFound).last_sn);
}

test "late match: ACKNACKs while the set is open draw no HEARTBEAT announcing it" {
    // A HEARTBEAT offering the open set's SNs draws NACKs the writer refuses
    // while the set is open, each answered by the same HEARTBEAT: a
    // HEARTBEAT/NACK loop until the set ends.
    var rec: Recording = .{};
    const w = try makeLateMatchWriter(&rec, true);
    defer w.deinit();

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    try matchLateReader(w);

    // The reader's initial ACKNACK: nothing received, next expected SN 1.
    rec.reset();
    const empty = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(LATE_READER_GUID, 0, empty, 1, false);
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
    try testing.expect(findHeartbeat(&rec) == null);

    // A NACK naming the set's SNs.
    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 2, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(1);
    nack_set.set(2);
    w.handleAckNack(LATE_READER_GUID, 0, nack_set, 2, false);
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
    try testing.expect(findHeartbeat(&rec) == null);
}

test "late match: a TRANSIENT_LOCAL reader with history before the open set is re-prompted at set end" {
    // Committed history (SN 1) is protected as before: the reader is held back
    // until it has it.  The set-end HEARTBEAT reaches it too, so its NACK
    // releases it and repairs the set without waiting for the periodic one.
    var rec: Recording = .{};
    const w = try makeLateMatchWriter(&rec, true);
    defer w.deinit();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "h");
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    try matchLateReader(w);
    try testing.expect(w.reader_proxies.items[0].suppress_live_data);
    try testing.expectEqual(@as(SequenceNumber, 1), w.reader_proxies.items[0].history_floor_sn);
    try testing.expectEqual(@as(SequenceNumber, 1), (findHeartbeat(&rec) orelse return error.NoHeartbeatFound).last_sn);

    // The GROUP flush: marker deferred to the publisher's combined send.
    rec.reset();
    w.endCoherentSet(.full, false, null, null, true);
    w.flushGroupEOCHBOnly();
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
    try testing.expectEqual(@as(SequenceNumber, 3), (findHeartbeat(&rec) orelse return error.NoHeartbeatFound).last_sn);

    // The reader holds SN 1 and NACKs the set.
    rec.reset();
    var nack_set = SequenceNumberSet{ .base = 2, .num_bits = 2, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2);
    nack_set.set(3);
    w.handleAckNack(LATE_READER_GUID, 1, nack_set, 1, false);
    try testing.expect(!w.reader_proxies.items[0].suppress_live_data);
    var sns_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 2, 3 }, collectDataSNsSorted(&rec, &sns_buf));
}

test "late match: a VOLATILE reader matching mid-set gets the set whole" {
    // SN 1 was sent before the match: not for this reader.  The open set {2, 3}
    // is published when it ends, after the match, so the reader starts at 2 and
    // gets it whole: samples, end marker, and a HEARTBEAT whose firstSN is the
    // set's first SN, not one inside it.
    var rec: Recording = .{};
    const w = try makeLateMatchWriter(&rec, false);
    defer w.deinit();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "h");
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    try matchLateReader(w);
    try testing.expectEqual(@as(SequenceNumber, 2), w.reader_proxies.items[0].start_sn);
    // The match HEARTBEAT offers nothing yet: [2, 1].
    const match_hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 2), match_hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 1), match_hb.last_sn);

    rec.reset();
    w.endCoherentSet(.full, false, null, null, false);
    var sns_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 2, 3, 4 }, collectDataSNsSorted(&rec, &sns_buf));
    const set_hb = findLastHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 2), set_hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 4), set_hb.last_sn);

    // A reader that missed the set NACKs it and gets it again; SN 1 never.
    rec.reset();
    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 4, .bitmap = std.mem.zeroes([8]u32) };
    for (1..5) |sn| nack_set.set(@intCast(sn));
    w.handleAckNack(LATE_READER_GUID, 0, nack_set, 1, false);
    try testing.expectEqualSlices(SequenceNumber, &.{ 2, 3, 4 }, collectDataSNsSorted(&rec, &sns_buf));
}

// ── LocatorSelector: effectiveLocators ranking (via ReaderProxy) ──────────────

fn v6Public(last: u8) [16]u8 {
    var addr = @as([16]u8, @splat(0));
    addr[0] = 0x20;
    addr[1] = 0x01;
    addr[15] = last;
    return addr;
}

test "effectiveLocators: dual-stack proxy collapses to a single family" {
    const writer_guid = makeGuid(0x60, WRITER_EID);
    const reader_guid = makeGuid(0x61, READER_EID);
    const loc_v4 = Locator.udp4(.{ 8, 8, 8, 8 }, 7500);
    const loc_v6 = Locator.udp6(v6Public(1), 7501);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{ loc_v4, loc_v6 }, &.{}, false, true);
    try w.addMatchedReader(rp);
    rec.reset();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "x");

    const v4_sends = countSendsToPort(&rec, 7500);
    const v6_sends = countSendsToV6Port(&rec, 7501);
    // Exactly one family should receive the sample, never both.
    try testing.expect((v4_sends > 0) != (v6_sends > 0));
}

test "effectiveLocators: loopback preferred over public at same family" {
    const writer_guid = makeGuid(0x62, WRITER_EID);
    const reader_guid = makeGuid(0x63, READER_EID);
    const loc_pub = Locator.udp4(.{ 8, 8, 8, 8 }, 7502);
    const loc_lo = Locator.udp4(.{ 127, 0, 0, 1 }, 7503);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // BEST_EFFORT so write() sends exactly one DATA capture (no trailing HB) per
    // locator, keeping the capture count a direct proxy for locator selection.
    // Public listed first so a naive "first-wins" bug (ignoring tier) would fail this.
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{ loc_pub, loc_lo }, &.{}, false, false);
    try w.addMatchedReader(rp);
    rec.reset();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "x");

    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7502));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7503));
}

test "effectiveLocators: private preferred over public at same family" {
    const writer_guid = makeGuid(0x64, WRITER_EID);
    const reader_guid = makeGuid(0x65, READER_EID);
    const loc_pub = Locator.udp4(.{ 8, 8, 8, 8 }, 7504);
    const loc_priv = Locator.udp4(.{ 10, 0, 0, 5 }, 7505);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // BEST_EFFORT so write() sends exactly one DATA capture (no trailing HB).
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{ loc_pub, loc_priv }, &.{}, false, false);
    try w.addMatchedReader(rp);
    rec.reset();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "x");

    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7504));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7505));
}

test "effectiveLocators: unicast-over-multicast preference unchanged when only multicast present" {
    const writer_guid = makeGuid(0x66, WRITER_EID);
    const reader_guid = makeGuid(0x67, READER_EID);
    const loc_mc = Locator.udp4(.{ 239, 255, 0, 1 }, 7506);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // BEST_EFFORT so write() sends exactly one DATA capture (no trailing HB).
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{}, &.{loc_mc}, false, false);
    try w.addMatchedReader(rp);
    rec.reset();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "x");

    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7506));
}

test "effectiveLocators: same-tier same-family ties are all kept" {
    const writer_guid = makeGuid(0x68, WRITER_EID);
    const reader_guid = makeGuid(0x69, READER_EID);
    const loc_a = Locator.udp4(.{ 10, 0, 0, 1 }, 7507);
    const loc_b = Locator.udp4(.{ 10, 0, 0, 2 }, 7508);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // BEST_EFFORT so write() sends exactly one DATA capture per locator (no trailing HB).
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{ loc_a, loc_b }, &.{}, false, false);
    try w.addMatchedReader(rp);
    rec.reset();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "x");

    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7507));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7508));
}

test "addMatchedReader: lease refresh recomputes cached selection when locators change" {
    const writer_guid = makeGuid(0x6a, WRITER_EID);
    const reader_guid = makeGuid(0x6b, READER_EID);
    const loc_pub = Locator.udp4(.{ 8, 8, 8, 8 }, 7509);
    const loc_lo = Locator.udp4(.{ 127, 0, 0, 1 }, 7510);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // BEST_EFFORT so write() sends exactly one DATA capture (no trailing HB).
    // First match: only the public locator is offered.
    const rp1 = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_pub}, &.{}, false, false);
    try w.addMatchedReader(rp1);
    rec.reset();
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7509));
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7510));
    rec.reset();

    // Lease refresh: same GUID, now also offers loopback — selection must
    // switch to it, not keep serving the stale public-only selection.
    const rp2 = try ReaderProxy.init(testing.allocator, reader_guid, &.{ loc_pub, loc_lo }, &.{}, false, false);
    try w.addMatchedReader(rp2);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");
    try testing.expectEqual(@as(usize, 0), countSendsToPort(&rec, 7509));
    try testing.expectEqual(@as(usize, 1), countSendsToPort(&rec, 7510));
}

// ── addMatchedReader: discovery/write race (docs/design/discovery-association-race-testing.md) ──

test "addMatchedReader: a write made before the proxy is registered is correctly excluded for a VOLATILE reader" {
    // Investigated 2026-09-18 via an rmw_zzdds CI flake, initially suspected
    // as a zzdds writer_sm.zig bug: an application can observe a reader as
    // "matched" (via a signal on the *reader's own* side, asymmetric with
    // this writer's addMatchedReader processing) and write before this
    // writer has actually processed that reader's SEDP subscription-data.
    //
    // Working through the fix surfaced that this is *not* a bug: VOLATILE
    // durability's only principled floor is "whatever the writer itself
    // knows at the moment it processes the match" -- there is no other
    // authoritative reference point available to the writer (a reader's own
    // SEDP-announcement INFO_TS is a per-message timestamp, RTPS §8.3.3, not
    // an entity-creation time -- it doesn't answer "when did this reader
    // legitimately start existing"). So start_sn = self.cache.next_sn at
    // addMatchedReader-time is correct, if nondeterministically timed
    // relative to an application's own (asymmetric) readiness signal.
    //
    // The real fix for the motivating bug is a *reader-side* signal
    // (`on_reliable_writer_ready`, see reader_sm_test.zig) that lets an
    // application wait for proof the writer has actually registered it
    // before writing/requesting, rather than trying to make the writer
    // guess retroactively. See docs/design/discovery-association-race-testing.md.
    const writer_guid = makeGuid(0x80, WRITER_EID);
    const reader_guid = makeGuid(0x81, READER_EID);
    const loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7530);

    var rec: Recording = .{};
    // replay_on_match=false (VOLATILE): matches the real bug's QoS shape
    // (ROS2's rmw_qos_profile_services_default).
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_last,
        1,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    const sn = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "race-sample");

    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc}, &.{}, false, true);
    try w.addMatchedReader(rp);

    var sns_buf: [8]SequenceNumber = undefined;
    const sent = collectDataSNsSorted(&rec, &sns_buf);
    // Correct: the sample written before this proxy existed is never sent
    // to it -- VOLATILE readers are not entitled to pre-match data.
    try testing.expect(std.mem.indexOfScalar(SequenceNumber, sent, sn) == null);
}

test "addMatchedReader: a write made after the proxy is registered is always delivered (baseline)" {
    const writer_guid = makeGuid(0x82, WRITER_EID);
    const reader_guid = makeGuid(0x83, READER_EID);
    const loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7531);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_last,
        1,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc}, &.{}, false, true);
    try w.addMatchedReader(rp);

    const sn = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "baseline-sample");

    var sns_buf: [8]SequenceNumber = undefined;
    const sent = collectDataSNsSorted(&rec, &sns_buf);
    try testing.expect(std.mem.indexOfScalar(SequenceNumber, sent, sn) != null);
}

test "checkConnectionGenerations: replays to a proxy whose connection generation changed" {
    const writer_guid = makeGuid(0x70, WRITER_EID);
    const reader_guid = makeGuid(0x71, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7520);

    var rec: Recording = .{};
    // replay_on_match=false (VOLATILE): reconnect-triggered replay must NOT
    // depend on durability-driven replay-on-match — recovering an ongoing
    // pairing's connection gap is a different concern from late-join replay.
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    // BEST_EFFORT proxy: this is the case with no other recovery path at all
    // for data lost during a connection gap, so it must also get replayed to.
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");
    rec.reset();

    // Generation unchanged (still 0, matching a connectionless/UDP locator
    // or a TCP connection that never dropped): no replay.
    w.checkConnectionGenerations();
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));

    // Simulate a transport-level reconnect (e.g. TCP dropped and re-dialed).
    rec.connection_generation = 1;
    w.checkConnectionGenerations();
    try testing.expectEqual(@as(usize, 2), countAllData(&rec));

    // Generation unchanged since the last check: no further replay.
    rec.reset();
    w.checkConnectionGenerations();
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

test "addMatchedReader: lease refresh landing after a reconnect still replays (not silently absorbed)" {
    // Regression test: a lease refresh (e.g. a repeated SEDP announcement)
    // arriving for an already-matched proxy between two heartbeat-thread
    // ticks must not be able to record a reconnect's new generation without
    // the corresponding replay actually happening — that would silently and
    // permanently lose whatever data the reconnect gap dropped.
    const writer_guid = makeGuid(0x72, WRITER_EID);
    const reader_guid = makeGuid(0x73, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7521);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer w.deinit();

    const rp1 = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp1);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");
    rec.reset();

    // Reconnect happens, but no heartbeat-thread tick has run yet.
    rec.connection_generation = 1;

    // A lease refresh for the same proxy (same locators) lands first.
    const rp2 = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp2);

    // The refresh itself must have replayed — this is the assertion that
    // fails under the bug (old code recorded the new generation directly,
    // without calling replayHistoryToProxyLocked, so this would see 0).
    try testing.expectEqual(@as(usize, 2), countAllData(&rec));

    // A subsequent periodic check finds nothing new to do — already resynced.
    rec.reset();
    w.checkConnectionGenerations();
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── OOM fallback: sendChangeToAllLocked's allocation-failure path ───────────
//
// Regression test for Greptile PR #64 review: an earlier version of the OOM
// fallback here sent synchronously while still holding self.mu, reintroducing
// the writer.mu/reader.mu lock-order-inversion the unlock-before-send
// restructuring elsewhere in write() exists to close. The fix removes the
// send entirely on this rare path -- this test proves that structurally (no
// send is attempted when the snapshot allocation fails), which is what
// makes the deadlock impossible, rather than trying to reproduce a live
// deadlock in a single-threaded test harness.
test "write: snapshot-allocation OOM skips the live send instead of sending under self.mu" {
    const writer_guid = makeGuid(0x01, WRITER_EID);
    const reader_guid = makeGuid(0x02, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Confirm the normal (non-OOM) path still sends, as a control.
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "normal");
    try testing.expect(countAllData(&rec) > 0);
    rec.reset();

    // Force the very next allocation through w.alloc (the snapshot array in
    // sendChangeToAllLocked's non-fragmented branch) to fail. w.write()
    // itself must still succeed (the sample lands in the cache regardless;
    // only the immediate live push is skipped), and no DATA send may occur.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    w.alloc = fa.allocator();
    defer w.alloc = testing.allocator;

    // The OOM fallback logs a warning -- expected here, not a real error.
    // Suppress it so it doesn't read as a test failure in build output.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "oom");
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── OOM fallback: replayHistoryToProxyUnlocked's allocation-failure path ────
//
// Regression test for Greptile PR #64 review (round 2): an earlier version of
// this OOM fallback called replayHistoryToProxyLocked (a fully-locked
// synchronous replay) when the unlocked-replay snapshot allocation failed,
// reintroducing the same writer.mu/reader.mu lock-order-inversion described
// above. The fix removes the send entirely on this rare path -- for a
// BEST_EFFORT proxy (its only history-delivery path, since it never
// ACKNACKs) this does mean the initial replay is genuinely lost on OOM,
// which is the documented, accepted tradeoff. This test proves the "no send"
// behavior structurally, matching the style of the write() OOM test above.
test "addMatchedReader: replay-snapshot OOM skips history replay instead of sending under self.mu" {
    const writer_guid = makeGuid(0x74, WRITER_EID);
    const reader_guid = makeGuid(0x75, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7522);

    var rec: Recording = .{};
    // replay_on_match=true (TRANSIENT_LOCAL+): a newly-matched proxy that
    // wants replay (ReaderProxy.wants_replay defaults to true) triggers
    // replayHistoryToProxyUnlocked -- the path under test.
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer w.deinit();

    // Write history before any reader is matched, using the real allocator.
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");

    // Force the second allocation through w.alloc to fail: the first
    // (alloc_index 0) is reader_proxies.append growing from empty, which
    // must succeed for the proxy to be matched at all; the second
    // (alloc_index 1) is the first allocation of the replay snapshot in
    // replayBatchUnlocked.
    var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    w.alloc = fa.allocator();
    defer w.alloc = testing.allocator;

    // The OOM fallback logs a warning -- expected here, not a real error.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // BEST_EFFORT proxy (reliable=false): its only history-delivery path.
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);

    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

test "checkConnectionGenerations: retries a BEST_EFFORT proxy's OOM-skipped initial replay" {
    // Regression test for Greptile PR #64 review (round 2): the OOM
    // fallback above used to leave the initial replay permanently lost --
    // the proxy's only history-delivery path, since BEST_EFFORT never
    // ACKNACKs. It now sets pending_replay_retry, which
    // checkConnectionGenerations (already polled periodically from
    // heartbeatThread) retries. This proves the retry actually delivers
    // once the transient OOM clears, not just that the flag gets set.
    const writer_guid = makeGuid(0x82, WRITER_EID);
    const reader_guid = makeGuid(0x83, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7530);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true, // replay_on_match
    );
    defer w.deinit();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    {
        // Same calibration as the OOM test above: alloc_index 0 is
        // reader_proxies.append, alloc_index 1 is the replay snapshot.
        // Live data to the proxy is held until the retry, so a sample
        // written now must not reach it ahead of the history.
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
        w.alloc = fa.allocator();
        defer w.alloc = testing.allocator;

        const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
        try w.addMatchedReader(rp);
        try testing.expectEqual(@as(usize, 0), countAllData(&rec));
    }
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "three");
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));

    // w.alloc is back to the real allocator now -- the retry should succeed,
    // and send the history, then the held sample, in SN order.
    w.checkConnectionGenerations();
    var sn_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, collectSentSnsInOrder(&rec, &sn_buf));

    // A second tick with nothing pending must not resend.
    rec.reset();
    w.checkConnectionGenerations();
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── BEST_EFFORT history replay order ─────────────────────────────────────────
//
// A BEST_EFFORT reader drops any SN at or below the highest it has received
// (RTPS 2.5 §8.4.12.1.4, T2), so a replayed history must reach it in SN order
// and ahead of any live sample.

test "BEST_EFFORT replay: a sample written while the history goes out follows it" {
    const writer_guid = makeGuid(0x84, WRITER_EID);
    const reader_guid = makeGuid(0x85, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7531);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(testing.allocator, writer_guid, rec.makeTransport(), .keep_all, 0, READER_EID, rtps.writer_sm.DEFAULT_FRAG_SIZE, true);
    defer w.deinit();
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");

    // The first replay send writes SN 3 while the writer's lock is released.
    rec.write_on_send = w;
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);

    var sn_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, collectSentSnsInOrder(&rec, &sn_buf));

    // Once the replay is done, live data flows again.
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "four");
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3, 4 }, collectSentSnsInOrder(&rec, &sn_buf));
}

test "BEST_EFFORT replay: a fragmented sample goes out in its place in SN order" {
    const writer_guid = makeGuid(0x86, WRITER_EID);
    const reader_guid = makeGuid(0x87, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7532);

    var rec: Recording = .{};
    const frag_size = 64;
    const w = try StatefulWriter.init(testing.allocator, writer_guid, rec.makeTransport(), .keep_all, 0, READER_EID, frag_size, true);
    defer w.deinit();
    const big = @as([(frag_size * 2 + 1)]u8, @splat(0xAB));
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, &big);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "three");

    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);

    var sn_buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, collectSentSnsInOrder(&rec, &sn_buf));
}

test "BEST_EFFORT replay: the retained history goes out whole, however many batches it takes" {
    const writer_guid = makeGuid(0x8a, WRITER_EID);
    const reader_guid = makeGuid(0x8b, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7534);

    var rec: Recording = .{};
    const frag_size = 64;
    const w = try StatefulWriter.init(testing.allocator, writer_guid, rec.makeTransport(), .keep_all, 0, READER_EID, frag_size, true);
    defer w.deinit();
    // Small and fragmented samples alternate, so each is a batch of its own:
    // more batches than the catch-up bound, with nothing written meanwhile.
    const pairs = rtps.writer_sm.MAX_BEST_EFFORT_REPLAY_ROUNDS / 2 + 1;
    comptime std.debug.assert(pairs * 4 <= MAX_CAPS); // a DATA, 2 DATA_FRAGs and a HEARTBEAT_FRAG a pair
    const big = @as([(frag_size + 1)]u8, @splat(0xAB));
    for (0..pairs) |_| {
        _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "small");
        _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, &big);
    }

    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);

    var expected: [pairs * 2]SequenceNumber = undefined;
    for (&expected, 1..) |*sn, i| sn.* = @intCast(i);
    var sn_buf: [pairs * 2 + 1]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &expected, collectSentSnsInOrder(&rec, &sn_buf));
}

test "handleAckNack: an ACKNACK from a BEST_EFFORT reader is ignored" {
    const writer_guid = makeGuid(0x88, WRITER_EID);
    const reader_guid = makeGuid(0x89, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7533);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(testing.allocator, writer_guid, rec.makeTransport(), .keep_all, 0, READER_EID, rtps.writer_sm.DEFAULT_FRAG_SIZE, true);
    defer w.deinit();
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
    try w.addMatchedReader(rp);
    rec.reset();

    // Non-final, requesting both SNs: a RELIABLE reader would get both again
    // and a HEARTBEAT.
    var set = SequenceNumberSet{ .base = 1, .num_bits = 2, .bitmap = std.mem.zeroes([8]u32) };
    set.bitmap[0] = 0xC000_0000;
    w.handleAckNack(reader_guid, 0, set, 1, false);
    try testing.expectEqual(@as(usize, 0), rec.n);
}

// ── Transport send-error handling ────────────────────────────────────────────
//
// write()'s unlocked send loop wraps every transport send in
// `catch |err| switch (err) { error.UnsupportedLocatorKind => {}, else =>
// log.rtps.warn(...) }` -- SEDP already filters proxy locators down to ones
// the transport itself reports canReach(), so this is defence-in-depth, not
// a path expected to fire in normal operation. Neither arm had a test.

test "write: UnsupportedLocatorKind send error is silently ignored" {
    const writer_guid = makeGuid(0x76, WRITER_EID);
    const reader_guid = makeGuid(0x77, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7523);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    rec.send_error = error.UnsupportedLocatorKind;
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "unsupported-locator");
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

test "write: a non-UnsupportedLocatorKind send error is logged and swallowed" {
    const writer_guid = makeGuid(0x78, WRITER_EID);
    const reader_guid = makeGuid(0x79, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7524);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // A warning is logged here -- expected, not a real test failure.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    rec.send_error = error.ConnectionResetByPeer;
    // write() must not propagate the transport's send failure -- the sample
    // still lands in the cache and can be retransmitted later via ACKNACK.
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "send-fails");
    try testing.expectEqual(@as(usize, 0), countAllData(&rec));
}

// ── Replay: large-fragment priming ───────────────────────────────────────────

test "addMatchedReader: replay primes a RELIABLE proxy with DATA_FRAG for an already-fragmented cached change" {
    // replayHistoryToProxyUnlocked's RELIABLE branch: a cached change larger
    // than frag_size gets its first fragment sent directly ("priming") so
    // the reader has something to NACK against immediately, rather than
    // waiting for the writer's regular heartbeat/retransmission cycle to be
    // the first thing that reveals the change is fragmented. Previously
    // untested -- only the non-fragmented replay path had coverage.
    const writer_guid = makeGuid(0x80, WRITER_EID);
    const reader_guid = makeGuid(0x81, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7529);
    const small_frag_size: u16 = 32;

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        small_frag_size,
        true, // replay_on_match
    );
    defer w.deinit();

    // Larger than small_frag_size, written before any reader is matched so
    // it's already sitting in the cache when addMatchedReader triggers replay.
    const big_payload = @as([64]u8, @splat(0xAB));
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, &big_payload);

    // RELIABLE proxy: only the RELIABLE branch of replayHistoryToProxyUnlocked
    // does large-fragment priming.
    const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, true);
    try w.addMatchedReader(rp);

    const df = findDataFrag(&rec) orelse return error.TestExpectedDataFrag;
    try testing.expectEqual(@as(u32, 1), df.fragment_starting_num);
}

test "checkConnectionGenerations: retries after a mid-loop per-change copy OOM during replay" {
    // Regression test for Greptile PR #64 review (round 3): unlike the
    // snapshot-array allocation failure (tested above, fails before this
    // loop even starts), a failure copying one INDIVIDUAL change's data
    // mid-loop used to just `continue` past it silently, with no retry
    // scheduled -- permanently dropping that one sample even though the
    // rest of the replay otherwise "succeeded".
    const writer_guid = makeGuid(0x84, WRITER_EID);
    const reader_guid = makeGuid(0x85, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7531);

    var rec: Recording = .{};
    const w = try StatefulWriter.init(
        testing.allocator,
        writer_guid,
        rec.makeTransport(),
        .keep_all,
        0,
        READER_EID,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true, // replay_on_match
    );
    defer w.deinit();

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "one");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "two");

    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    {
        // alloc_index 0: reader_proxies.append. 1: the snapshot array
        // (must succeed to reach the per-change copy loop at all). 2: the
        // first change's dupe() -- made to fail here, mid-loop.
        var fa = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 2 });
        w.alloc = fa.allocator();
        defer w.alloc = testing.allocator;

        const rp = try ReaderProxy.init(testing.allocator, reader_guid, &.{loc_a}, &.{}, false, false);
        try w.addMatchedReader(rp);
        // Only the change(s) after the failed one made it out this pass.
        try testing.expect(countAllData(&rec) < 2);
    }

    rec.reset();
    w.checkConnectionGenerations();
    // The retry re-copies everything from scratch -- both changes arrive.
    try testing.expectEqual(@as(usize, 2), countAllData(&rec));
}

// ── Dropping acknowledged changes ─────────────────────────────────────────────
//
// A RELIABLE VOLATILE writer (`drop_acked`) keeps a change only until every
// reliable reader has acknowledged it, so RESOURCE_LIMITS count what is still
// unacknowledged.

fn pureAck(w: *StatefulWriter, reader: Guid, through: SequenceNumber, count: i32) void {
    const nack_set = SequenceNumberSet{ .base = through + 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader, through, nack_set, count, true);
}

fn cacheLen(w: *StatefulWriter) usize {
    w.mu.lock();
    defer w.mu.unlock();
    return w.cache.len();
}

/// A VOLATILE writer with two reliable readers matched and three changes sent.
fn makeDroppingWriter(rec: *Recording, a: Guid, b: Guid, drop: bool) !*StatefulWriter {
    const w = try StatefulWriter.init(testing.allocator, makeGuid(0x60, WRITER_EID), rec.makeTransport(), .keep_all, 0, READER_EID, rtps.writer_sm.DEFAULT_FRAG_SIZE, false);
    errdefer w.deinit();
    w.drop_acked = drop;
    try w.addMatchedReader(try ReaderProxy.init(testing.allocator, a, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7100)}, &.{}, false, true));
    try w.addMatchedReader(try ReaderProxy.init(testing.allocator, b, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7101)}, &.{}, false, true));
    for ([_][]const u8{ "one", "two", "three" }) |d| _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, d);
    rec.reset();
    return w;
}

test "drop_acked: a change leaves the cache once every reliable reader has acknowledged it" {
    const a = makeGuid(0x61, READER_EID);
    const b = makeGuid(0x62, READER_EID);
    var rec: Recording = .{};
    const w = try makeDroppingWriter(&rec, a, b, true);
    defer w.deinit();

    pureAck(w, a, 3, 1);
    try testing.expectEqual(@as(usize, 3), cacheLen(w));
    pureAck(w, b, 2, 1);
    try testing.expectEqual(@as(usize, 1), cacheLen(w));
    pureAck(w, b, 3, 2);
    try testing.expectEqual(@as(usize, 0), cacheLen(w));

    // An empty cache still announces what was written: nothing is available
    // below the next SN.
    w.sendHeartbeat(true, false);
    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 4), hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
}

test "drop_acked: removing the reader that had not acknowledged drops what the others had" {
    const a = makeGuid(0x63, READER_EID);
    const b = makeGuid(0x64, READER_EID);
    var rec: Recording = .{};
    const w = try makeDroppingWriter(&rec, a, b, true);
    defer w.deinit();

    pureAck(w, a, 3, 1);
    w.removeMatchedReader(b);
    try testing.expectEqual(@as(usize, 0), cacheLen(w));
}

test "drop_acked: unset, acknowledged changes stay" {
    const a = makeGuid(0x65, READER_EID);
    const b = makeGuid(0x66, READER_EID);
    var rec: Recording = .{};
    const w = try makeDroppingWriter(&rec, a, b, false);
    defer w.deinit();

    pureAck(w, a, 3, 1);
    pureAck(w, b, 3, 1);
    try testing.expectEqual(@as(usize, 3), cacheLen(w));
}

test "drop_acked: with no reliable reader a sent change goes at once, and an open coherent set's when it ends" {
    var rec: Recording = .{};
    const w = try StatefulWriter.init(testing.allocator, makeGuid(0x67, WRITER_EID), rec.makeTransport(), .keep_all, 0, READER_EID, rtps.writer_sm.DEFAULT_FRAG_SIZE, false);
    defer w.deinit();
    w.drop_acked = true;
    const best_effort = makeGuid(0x68, READER_EID);
    try w.addMatchedReader(try ReaderProxy.init(testing.allocator, best_effort, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7100)}, &.{}, false, false));

    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "sent");
    try testing.expectEqual(@as(usize, 0), cacheLen(w));

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    // Nothing unsent goes, whatever drops the rest.
    w.removeMatchedReader(best_effort);
    try testing.expectEqual(@as(usize, 2), cacheLen(w));
    w.endCoherentSet(.coherent_only, false, null, null, false);
    try testing.expectEqual(@as(usize, 0), cacheLen(w));
}

test "drop_acked: space freed by a coherent set's end wakes a wait helping a manual runtime" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var backend = zzdds.runtime.IoBackend.init(threaded.io());
    var runtime = zzdds.runtime.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .manual });
    var rec: Recording = .{};
    const w = try StatefulWriter.init(testing.allocator, makeGuid(0x6B, WRITER_EID), rec.makeTransport(), .keep_all, 0, READER_EID, rtps.writer_sm.DEFAULT_FRAG_SIZE, false);
    w.drop_acked = true;
    w.attachRuntime(&runtime);

    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    const Waiter = struct {
        fn run(writer: *StatefulWriter, freed: *bool) void {
            // Gives up after 10 s rather than hanging.
            freed.* = writer.waitCacheBelow(2, 10 * std.time.ns_per_s);
        }
    };
    var freed = false;
    const start = runtime.clock.nowNs();
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ w, &freed });
    while (backend.waiters.load(.seq_cst) == 0) std.Thread.yield() catch {};
    w.endCoherentSet(.coherent_only, false, null, null, false);
    waiter.join();
    try testing.expect(freed);
    // Woken by the end of the set, not ended by the deadline.
    try testing.expect(runtime.clock.nowNs() - start < 10 * std.time.ns_per_s);

    w.deinit();
    runtime.releaseOwner();
    try testing.expectEqual(zzdds.runtime.State.backend_stopped, (try runtime.drive(1, 0)).state);
    runtime.deinit();
}

test "waitCacheBelow: true once acknowledgments free space, false at its timeout otherwise" {
    const a = makeGuid(0x69, READER_EID);
    const b = makeGuid(0x6A, READER_EID);
    var rec: Recording = .{};
    const w = try makeDroppingWriter(&rec, a, b, true);
    defer w.deinit();

    try testing.expect(!w.waitCacheBelow(3, 0));
    pureAck(w, a, 1, 1);
    pureAck(w, b, 1, 1);
    try testing.expect(w.waitCacheBelow(3, 0));
}
