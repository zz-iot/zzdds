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
        .prefix = .{ .bytes = [_]u8{prefix_byte} ** 12 },
        .entity_id = eid,
    };
}

// ── Recording transport ───────────────────────────────────────────────────────

/// Captures every send() call so tests can assert on what was transmitted.
/// One Capture per send() invocation; stores the destination locator and raw bytes.
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

test "handleAckNack: non-final + empty bitmap retransmits all changes >= base" {
    const writer_guid = makeGuid(0x01, WRITER_EID);
    const reader_guid = makeGuid(0x02, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Non-final AckNack, empty bitmap (base=1, num_bits=0).
    // §8.3.7.1.2: non-final → writer MUST send all changes with SN >= base.
    const nack_set = SequenceNumberSet{ .base = 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
    w.handleAckNack(reader_guid, 0, nack_set, 1, false);

    var sns_buf: [8]SequenceNumber = undefined;
    const sent = collectDataSNsSorted(&rec, &sns_buf);
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, sent);
}

// ── AckNack: non-final + bitmap ──────────────────────────────────────────────

test "handleAckNack: non-final + bitmap retransmits NACKed and all >= base not in bitmap" {
    const writer_guid = makeGuid(0x03, WRITER_EID);
    const reader_guid = makeGuid(0x04, READER_EID);
    const loc_a = Locator.udp4(.{ 127, 0, 0, 1 }, 7100);

    var rec: Recording = .{};
    const w = try makeWriterWithReader(&rec, loc_a, reader_guid, writer_guid);
    defer w.deinit();

    // Bitmap: only SN 2 is explicitly NACKed (bit set).
    // Non-final → loop 1 sends SN 2 (explicit NACK).
    //           → loop 2 sends SN 1 and SN 3 (in-range, not in NACK bitmap).
    var nack_set = SequenceNumberSet{ .base = 1, .num_bits = 3, .bitmap = std.mem.zeroes([8]u32) };
    nack_set.set(2); // NACK SN 2

    w.handleAckNack(reader_guid, 0, nack_set, 1, false);

    var sns_buf: [8]SequenceNumber = undefined;
    const sent = collectDataSNsSorted(&rec, &sns_buf);
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, sent);
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

    w.sendHeartbeat(true);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 1), hb.first_sn);
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
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

    w.sendHeartbeat(true);

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

    w.sendHeartbeat(true);
    try testing.expectEqual(hb_base + 1, w.hb_count);

    w.sendHeartbeat(false);
    try testing.expectEqual(hb_base + 2, w.hb_count);

    w.sendHeartbeat(true);
    try testing.expectEqual(hb_base + 3, w.hb_count);
}

// ── Liveness probe ────────────────────────────────────────────────────────────

const GuidPrefix = rtps.GuidPrefix;

const ProbeResult = struct {
    prefix: ?GuidPrefix = null,
    alive: ?bool = null,
    fn callback(ctx: *anyopaque, pfx: GuidPrefix, a: bool) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.prefix = pfx;
        self.alive = a;
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

test "checkProbeDeadlines: evicts expired proxy and fires dead callback" {
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

    // Proxy should be evicted and callback fired with alive=false.
    try testing.expect(pr.prefix != null);
    try testing.expect(pr.prefix.?.eql(reader_guid.prefix));
    try testing.expect(pr.alive == false);

    // Proxy is gone: no more reader proxies.
    w.mu.lock();
    const proxy_count = w.reader_proxies.items.len;
    w.mu.unlock();
    try testing.expectEqual(@as(usize, 0), proxy_count);
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
    try testing.expectEqual(@as(usize, 0), remaining);
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

// ── Coherent HB cap ───────────────────────────────────────────────────────────

test "sendHeartbeat: coherent_active caps last_sn to last_flushed_sn" {
    // During an active coherent set, write() buffers SNs in coherent_pending_sns
    // without sending them.  The background HB must not advertise these unsent SNs
    // or subscriber WIPs will record an unachievable flush_target_sn.
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
    w.sendHeartbeat(true);

    const hb = findHeartbeat(&rec) orelse return error.NoHeartbeatFound;
    try testing.expectEqual(@as(SequenceNumber, 3), hb.last_sn);
}

// ── EOC GAP in periodic HB ────────────────────────────────────────────────────

test "sendHeartbeat: EOC GAP included for allocated-but-uncached SNs" {
    // After endCoherentSet, the EOC SN is allocated (cache.next_sn advances) but
    // not stored in the cache.  The next HB must include a GAP for that SN so
    // reliable readers can retire it without perpetually NACKing it.
    // Covers writer_sm.zig lines 779-785.
    const writer_guid = makeGuid(0x52, WRITER_EID);
    const reader_guid = makeGuid(0x53, READER_EID);
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

    // Write 2 coherent samples then end the set.
    // endCoherentSet allocates EOC SN=3 (via allocSn) — not stored in cache.
    // After: cache_last=2, cache.next_sn=4, coherent_active=false.
    w.beginCoherentSet(true);
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "a");
    _ = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "b");
    w.endCoherentSet(.coherent_only, false, null, 0, false);
    rec.reset();

    // Periodic HB must include a GAP for the EOC SN range [3, 4).
    w.sendHeartbeat(true);

    const gap = findGap(&rec) orelse return error.NoGapFound;
    try testing.expectEqual(@as(SequenceNumber, 3), gap.gap_start);
}
