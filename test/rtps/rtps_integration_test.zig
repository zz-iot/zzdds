//! RTPS integration tests: multi-endpoint and loss-recovery scenarios.
//!
//! These tests sit below the DCPS layer. Writer and reader state machines are
//! wired manually through MockTransport (and optionally LossyTransport), then
//! driven by net.deliverAll() calls — one per network round trip.
//!
//! Each test targets a scenario that mock_transport_test.zig does not cover:
//!
//!   fan_out_*  — one writer, multiple readers
//!   fan_in_*   — multiple writers, one reader (per-proxy ReceivedSet isolation)
//!   late_join_* — reader joins after writer has already been publishing
//!   loss_*     — LossyTransport injects directional packet drops

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;

const StatefulWriter = rtps.StatefulWriter;
const StatefulReader = rtps.StatefulReader;
const ReaderProxy = rtps.ReaderProxy;
const WriterProxy = rtps.WriterProxy;
const CacheChange = rtps.CacheChange;
const Guid = rtps.Guid;
const GuidPrefix = rtps.GuidPrefix;
const EntityId = rtps.EntityId;
const EntityIds = rtps.EntityIds;
const SequenceNumber = rtps.SequenceNumber;
const HistoryKind = rtps.HistoryKind;
const ChangeKind = rtps.ChangeKind;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;

const MockNetwork = zzdds.mock_transport.MockNetwork;
const MockTransport = zzdds.mock_transport.MockTransport;
const LossyTransport = zzdds.lossy_transport.LossyTransport;
const DropFirst = zzdds.lossy_transport.DropFirst;
const DropEveryNth = zzdds.lossy_transport.DropEveryNth;
const Transport = zzdds.transport.Transport;
const Locator = zzdds.transport.Locator;
const ReceiveHandler = zzdds.transport.ReceiveHandler;

const MessageIterator = msg.MessageIterator;
const InlineQosParam = msg.InlineQosParam;

const testing = std.testing;

// ── GUIDs ─────────────────────────────────────────────────────────────────────

fn prefix(b: u8) GuidPrefix {
    return .{ .bytes = [_]u8{b} ** 12 };
}

const W1_GUID = Guid{ .prefix = prefix(0xAA), .entity_id = EntityIds.sedp_builtin_publications_writer };
const W2_GUID = Guid{ .prefix = prefix(0xDD), .entity_id = EntityIds.sedp_builtin_publications_writer };
const R1_GUID = Guid{ .prefix = prefix(0xBB), .entity_id = EntityIds.sedp_builtin_publications_reader };
const R2_GUID = Guid{ .prefix = prefix(0xCC), .entity_id = EntityIds.sedp_builtin_publications_reader };

// Locators: each participant gets a unique IP; ports can be shared across IPs.
const W1_LOC = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7411 } };
const W2_LOC = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 4 }, .port = 7411 } };
const R1_LOC = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 2 }, .port = 7413 } };
const R2_LOC = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 3 }, .port = 7413 } };

const NIL_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes([16]u8);
const NIL_KH = std.mem.zeroes([16]u8);

// ── RTPS message dispatch ─────────────────────────────────────────────────────
//
// Parses raw RTPS bytes and routes submessages to the appropriate state
// machine — the same job a DCPS participant's receive loop does in production.

const ReaderDispatch = struct {
    reader: *StatefulReader,

    fn makeHandler(self: *ReaderDispatch) ReceiveHandler {
        return .{ .ctx = self, .on_receive = recv };
    }

    fn recv(ctx: *anyopaque, data: []const u8, _: Locator) void {
        const self: *ReaderDispatch = @ptrCast(@alignCast(ctx));
        var params: [32]InlineQosParam = undefined;
        var it = MessageIterator.init(data) catch return;
        const src = it.header.guid_prefix;
        while (it.next(&params) catch null) |sub| switch (sub) {
            .data => |d| {
                const wguid = Guid{ .prefix = src, .entity_id = d.writer_entity_id };
                const ch = CacheChange{
                    .kind = .alive,
                    .writer_guid = wguid,
                    .sequence_number = d.writer_sn,
                    .source_timestamp = NIL_TS,
                    .instance_handle = NIL_IH,
                    .key_hash = NIL_KH,
                    .data = d.serialized_payload,
                };
                self.reader.handleData(wguid, ch) catch {};
            },
            .heartbeat => |hb| {
                const wguid = Guid{ .prefix = src, .entity_id = hb.writer_entity_id };
                self.reader.handleHeartbeat(wguid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
            },
            else => {},
        };
    }
};

const WriterDispatch = struct {
    writer: *StatefulWriter,

    fn makeHandler(self: *WriterDispatch) ReceiveHandler {
        return .{ .ctx = self, .on_receive = recv };
    }

    fn recv(ctx: *anyopaque, data: []const u8, _: Locator) void {
        const self: *WriterDispatch = @ptrCast(@alignCast(ctx));
        var params: [32]InlineQosParam = undefined;
        var it = MessageIterator.init(data) catch return;
        const src = it.header.guid_prefix;
        while (it.next(&params) catch null) |sub| switch (sub) {
            .acknack => |an| {
                const rguid = Guid{ .prefix = src, .entity_id = an.reader_entity_id };
                self.writer.handleAckNack(rguid, an.reader_sn_state.base - 1, an.reader_sn_state, an.count, an.isFinal());
            },
            else => {},
        };
    }
};

// ── Sample collector ──────────────────────────────────────────────────────────

const Collector = struct {
    alloc: std.mem.Allocator,
    samples: std.ArrayListUnmanaged([]u8),

    fn init(alloc: std.mem.Allocator) Collector {
        return .{ .alloc = alloc, .samples = .empty };
    }

    fn deinit(self: *Collector) void {
        for (self.samples.items) |s| self.alloc.free(s);
        self.samples.deinit(self.alloc);
    }

    fn callback(self: *Collector) rtps.DataCallback {
        return .{ .ctx = self, .on_data = onData };
    }

    fn onData(ctx: *anyopaque, ch: *const CacheChange) void {
        const self: *Collector = @ptrCast(@alignCast(ctx));
        const copy = self.alloc.dupe(u8, ch.data) catch return;
        self.samples.append(self.alloc, copy) catch self.alloc.free(copy);
    }
};

// ── Write helper ──────────────────────────────────────────────────────────────

fn write(writer: *StatefulWriter, payload: []const u8) !void {
    _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, payload);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "fan_out: one writer, two readers — both receive all samples" {
    // Verifies that a writer correctly maintains two independent ReaderProxy
    // entries and replays its full history to each on match.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();
    const mt_r1 = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r1.deinit();
    const mt_r2 = try MockTransport.init(alloc, net, &.{R2_LOC});
    defer mt_r2.deinit();

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader1 = try StatefulReader.init(alloc, R1_GUID, mt_r1.transport(), .keep_all, 0, true);
    defer reader1.deinit();
    const reader2 = try StatefulReader.init(alloc, R2_GUID, mt_r2.transport(), .keep_all, 0, true);
    defer reader2.deinit();

    var col1 = Collector.init(alloc);
    defer col1.deinit();
    var col2 = Collector.init(alloc);
    defer col2.deinit();
    reader1.setCallback(col1.callback());
    reader2.setCallback(col2.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd1 = ReaderDispatch{ .reader = reader1 };
    var rd2 = ReaderDispatch{ .reader = reader2 };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r1.transport().listen(&R1_LOC, rd1.makeHandler());
    try mt_r2.transport().listen(&R2_LOC, rd2.makeHandler());

    // Write before matching so both readers get identical replays.
    try write(writer, "alpha");
    try write(writer, "beta");
    try write(writer, "gamma");

    // Match reader 1 then reader 2; each triggers an independent replay.
    const rp1 = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp1);
    const wp1 = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader1.addMatchedWriter(wp1);

    const rp2 = try ReaderProxy.init(alloc, R2_GUID, &.{R2_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp2);
    const wp2 = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader2.addMatchedWriter(wp2);

    // One round: both readers' queues drain (DATA + HEARTBEAT per reader).
    net.deliverAll();

    try testing.expectEqual(@as(usize, 3), col1.samples.items.len);
    try testing.expectEqual(@as(usize, 3), col2.samples.items.len);
    try testing.expectEqualSlices(u8, "alpha", col1.samples.items[0]);
    try testing.expectEqualSlices(u8, "gamma", col1.samples.items[2]);
    try testing.expectEqualSlices(u8, "alpha", col2.samples.items[0]);
    try testing.expectEqualSlices(u8, "gamma", col2.samples.items[2]);
}

test "fan_in: two writers, one reader — per-proxy ReceivedSet independent" {
    // Each writer has its own WriterProxy and ReceivedSet on the reader.
    // Verifies that sequence numbers from writer A and writer B are tracked
    // independently — no cross-contamination between proxies.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w1 = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w1.deinit();
    const mt_w2 = try MockTransport.init(alloc, net, &.{W2_LOC});
    defer mt_w2.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();

    const writer1 = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w1.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer1.deinit();
    const writer2 = try StatefulWriter.init(
        alloc,
        W2_GUID,
        mt_w2.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer2.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd1 = WriterDispatch{ .writer = writer1 };
    var wd2 = WriterDispatch{ .writer = writer2 };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w1.transport().listen(&W1_LOC, wd1.makeHandler());
    try mt_w2.transport().listen(&W2_LOC, wd2.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    // Each writer produces 3 samples with distinct payloads.
    try write(writer1, "w1-one");
    try write(writer1, "w1-two");
    try write(writer1, "w1-three");

    try write(writer2, "w2-one");
    try write(writer2, "w2-two");
    try write(writer2, "w2-three");

    // Match both writers; each replays its own history.
    const rp1 = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer1.addMatchedReader(rp1);
    const wp1 = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp1);

    const rp2 = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer2.addMatchedReader(rp2);
    const wp2 = try WriterProxy.init(alloc, W2_GUID, &.{W2_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp2);

    // Both replays arrive in one round.
    net.deliverAll();

    // Reader must receive all 6 samples (3 from each writer).
    try testing.expectEqual(@as(usize, 6), col.samples.items.len);
}

test "late_join: KEEP_LAST-2 writer fills firstSN virtual gap on HEARTBEAT" {
    // A TRANSIENT_LOCAL writer has published 5 samples but the cache only
    // retains the last 2 (SNs 4 and 5).  When the reader joins late:
    //   1. Writer replays cached DATA(4) and DATA(5).
    //   2. Writer sends HEARTBEAT(firstSN=4, lastSN=5).
    //   3. Reader's handleHeartbeat sees firstSN=4 > cumulativeAck(0)+1=1 and
    //      inserts virtual GAPs for SNs 1-3, coalescing with the already-received
    //      [4,5] range to produce ReceivedSet=[1,5].
    //   4. deliverPendingLocked then delivers the buffered SNs 4 and 5.
    //
    // This exercises the evicted-history path: reader never NACKs for SNs 1-3
    // (they're gone from the cache) and still converges to cumulativeAck=5.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w.transport(),
        .keep_last,
        2,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    // Writer publishes 5 samples; KEEP_LAST 2 retains only SNs 4 and 5.
    try write(writer, "sn1");
    try write(writer, "sn2");
    try write(writer, "sn3");
    try write(writer, "sn4");
    try write(writer, "sn5");

    // Late reader joins. Writer replays {SN4, SN5} then sends HEARTBEAT(4, 5).
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Round 1: DATA(4), DATA(5) — buffered (out-of-order from empty ReceivedSet).
    //          HEARTBEAT(4,5)   — firstSN gap triggers virtual fill of SNs 1-3,
    //                             ReceivedSet coalesces to [1,5], pending SNs 4-5
    //                             are delivered.
    net.deliverAll();

    // Only the two live samples should arrive; evicted SNs 1-3 are never delivered.
    try testing.expectEqual(@as(usize, 2), col.samples.items.len);
    try testing.expectEqualSlices(u8, "sn4", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "sn5", col.samples.items[1]);
}

test "loss_recovery: initial HB dropped, initial NACK from addMatchedWriter triggers retransmit" {
    // Reliable history replay is NACK-driven: addMatchedReader sends only a
    // HEARTBEAT (announcing the range); DATA follows when the reader NACKs.
    // Here the initial HB is dropped by LossyTransport(1), so the reader
    // never learns the range from the HB.  addMatchedWriter fires an initial
    // NACK(base=1, num_bits=0, final=false) which is enough to trigger the
    // writer's non-final NACK handler to send HB+DATA(1,2,3).
    //
    // addMatchedReader : HB(c=1) dropped (seq 1).  suppress_live_data=true.
    // addMatchedWriter : initial NACK(base=1, empty bitmap) → mt_w queue.
    // Round 1          : NACK (empty bitmap) → non-final tail loop sends DATA(1,2,3)
    //                    + trailing HB(c=2) capped at floor=3; pre-burst HB skipped
    //                    (suppress_live_data=true). suppress_live_data unchanged
    //                    (highest_sn=0 < floor=3).
    // Round 2          : DATA(1,2,3) arrive → all three delivered.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // mt_r first so deliverAll processes reader before writer each round,
    // ensuring NACK responses generated in the reader slot reach the writer
    // in the same round.
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop = DropFirst.init(1);
    const lossy = try LossyTransport.init(alloc, mt_w.transport(), drop.packetPolicy());
    defer lossy.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    // WriterDispatch listens on mt_w directly so ACKNACKs bypass the lossy shim.
    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    try write(writer, "one");
    try write(writer, "two");
    try write(writer, "three");

    // addMatchedReader sends HB(c=1) → dropped. No DATA (NACK-driven replay).
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);

    try testing.expectEqual(@as(usize, 0), col.samples.items.len);
    try testing.expectEqual(@as(u64, 1), lossy.dropped.load(.monotonic));

    // addMatchedWriter sends initial NACK(base=1, empty bitmap, non-final) → mt_w.
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Round 1: NACK (empty bitmap) → tail loop sends DATA(1,2,3) + trailing HB(c=2).
    //          (pre-burst HB skipped: suppress_live_data=true). No delivery yet.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 2: reader gets DATA(1,2,3) + trailing HB → all three delivered.
    net.deliverAll();

    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);

    // Exactly 1 drop: the initial HB from replay.
    try testing.expectEqual(@as(u64, 1), lossy.dropped.load(.monotonic));
}

test "loss_nack_drop: initial NACK dropped, HB-triggered NACK recovers data" {
    // Verifies that a dropped NACK does not cause a permanent stall.
    // The reader re-derives the missing SNs from its received set on every
    // non-final heartbeat, so recovery succeeds as soon as one gets through.
    //
    // Writer→reader: DropFirst(1) — drops the initial HB from addMatchedReader.
    // Reader→writer: DropFirst(1) — drops the initial NACK from addMatchedWriter.
    //
    // deliverAll() delivers member transports sequentially (mt_r then mt_w), so a
    // packet generated in mt_r's delivery slot (e.g. a NACK sent in response to a
    // HB) can be processed by mt_w in the same round.
    //
    //   addMatchedReader : HB(c=1) dropped (seq 1). suppress_live_data=true.
    //   addMatchedWriter : NACK-1 dropped by lossy_r.
    //   Round 1          : nothing arrives at reader or writer.
    //   sendHeartbeat    : HB(c=2) forwarded (DropFirst(1) exhausted).
    //   Round 2          : mt_r delivers HB → reader sees missing SNs 1,2,3,
    //                      sends NACK(1,2,3); DropFirst(1) exhausted → passes to mt_w;
    //                      mt_w delivers NACK → bitmap loop sends DATA(1,2,3)
    //                      + trailing HB(c=3) capped at floor=3.
    //                      (suppress_live_data unchanged: highest_sn=0 < floor=3)
    //   Round 3          : DATA(1,2,3) arrive → all three delivered.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop_data = DropFirst.init(1);
    const lossy_w = try LossyTransport.init(alloc, mt_w.transport(), drop_data.packetPolicy());
    defer lossy_w.deinit(alloc);

    var drop_nack = DropFirst.init(1);
    const lossy_r = try LossyTransport.init(alloc, mt_r.transport(), drop_nack.packetPolicy());
    defer lossy_r.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, lossy_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    // Receive handlers on the raw transports, bypassing the lossy shims.
    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    try write(writer, "one");
    try write(writer, "two");
    try write(writer, "three");

    // addMatchedReader sends HB(c=1) → dropped (seq 1). suppress_live_data=true.
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);

    // addMatchedWriter sends an initial NACK → dropped by lossy_r (seq 1).
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    try testing.expectEqual(@as(u64, 1), lossy_w.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), lossy_r.dropped.load(.monotonic));

    // Round 1: nothing arrives at reader or writer (both HB and NACK dropped).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Simulate the writer's periodic heartbeat.
    // Forwarded by lossy_w (DropFirst(1) exhausted after seq 1).
    writer.sendHeartbeat(false);

    // Round 2: HB(c=2) → reader sees missing SNs 1,2,3, sends NACK(1,2,3);
    //          DropFirst(1) exhausted → passes to mt_w; mt_w delivers NACK →
    //          bitmap loop sends DATA(1,2,3) + trailing HB(c=3) capped at floor=3.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 3: DATA(1,2,3) arrive → deliver "one","two","three".
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);

    // 1 writer-side drop (initial HB) and 1 reader-side drop (initial NACK).
    try testing.expectEqual(@as(u64, 1), lossy_w.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), lossy_r.dropped.load(.monotonic));
}

test "loss_nack_drop_two: two NACKs dropped; periodic HB re-triggers recovery" {
    // Extends loss_nack_drop: both the initial NACK and the first HB-triggered
    // NACK are dropped.  After two silent rounds the writer's periodic heartbeat
    // fires (simulated via sendHeartbeat then a direct handleHeartbeat call).  The
    // reader re-derives the same missing-SN bitmap from its unchanged received set
    // and the third NACK reaches the writer, completing recovery.
    //
    // Writer→reader: DropFirst(1) — drops the initial HB from addMatchedReader.
    // Reader→writer: DropFirst(2) — drops the first two NACKs.
    //
    //   addMatchedReader : HB(c=1) dropped (seq 1). suppress_live_data=true.
    //   addMatchedWriter : NACK-1 dropped.
    //   Round 1          : nothing arrives at reader or writer.
    //   sendHeartbeat    : HB(c=2) forwarded (DropFirst(1) exhausted).
    //   Round 2          : HB(c=2) → reader sees missing SNs 1,2,3, sends NACK(1,2,3);
    //                      NACK-2 dropped.
    //   [periodic HB]    : handleHeartbeat(c=3) called directly → NACK-3 passes.
    //   Round 3          : NACK-3 → bitmap loop sends DATA(1,2,3) + trailing HB(c=3)
    //                      capped at floor=3. (suppress_live_data unchanged: highest_sn=0 < floor=3)
    //   Round 4          : DATA(1,2,3) arrive → all 3 samples delivered.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop_data = DropFirst.init(1);
    const lossy_w = try LossyTransport.init(alloc, mt_w.transport(), drop_data.packetPolicy());
    defer lossy_w.deinit(alloc);

    var drop_nack = DropFirst.init(2);
    const lossy_r = try LossyTransport.init(alloc, mt_r.transport(), drop_nack.packetPolicy());
    defer lossy_r.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, lossy_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    try write(writer, "one");
    try write(writer, "two");
    try write(writer, "three");

    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);

    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Round 1: nothing arrives at reader or writer (both HB and NACK-1 dropped).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);
    try testing.expectEqual(@as(u64, 1), lossy_r.dropped.load(.monotonic));

    // Simulate writer periodic heartbeat #1 (initial HB was dropped).
    // Forwarded (DropFirst(1) exhausted after seq 1).
    writer.sendHeartbeat(false);

    // Round 2: HB(c=2) → reader sees missing SNs 1,2,3, sends NACK(1,2,3) → dropped by
    //          lossy_r (DropFirst(2) seq 2); writer stays silent.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);
    try testing.expectEqual(@as(u64, 2), lossy_r.dropped.load(.monotonic));

    // Simulate writer periodic heartbeat #2 directly on the reader.
    // DropFirst(2) is exhausted so NACK-3 is forwarded into mt_w.
    reader.handleHeartbeat(W1_GUID, 1, 3, 3, false);

    // Round 3: NACK-3 → bitmap loop sends DATA(1,2,3) + trailing HB(c=3) capped at floor=3.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 4: DATA(1,2,3) arrive → deliver "one","two","three".
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);

    try testing.expectEqual(@as(u64, 1), lossy_w.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 2), lossy_r.dropped.load(.monotonic));
}

test "loss_keep_last_eviction: NACKed SN evicted from cache; HB virtual GAP unblocks pending" {
    // Writer: KEEP_LAST-2, DropEveryNth(3) on lossy_w.
    //
    // Each write sends two packets through lossy_w: DATA and a trailing non-final
    // HEARTBEAT (required so the reader learns [first_sn, last_sn]).  To land
    // DATA(SN2) at seq 6 (the second multiple of 3), two extra heartbeats are
    // sent after addMatchedReader to shift the sequence counter by 2.
    //
    // lossy_w send sequence (D=DATA, H=HEARTBEAT):
    //   seq  1  H(1,0,c=1)   addMatchedReader              → pass
    //   seq  2  H(1,0,c=2)   manual sendHeartbeat          → pass
    //   seq  3  H(1,0,c=3)   manual sendHeartbeat  3%3=0   → DROP
    //   seq  4  D(SN1)       write "one"                   → pass
    //   seq  5  H(1,1,c=4)   write "one"                   → pass
    //   seq  6  D(SN2)       write "two"          6%3=0    → DROP
    //   seq  7  H(1,2,c=5)   write "two"                   → pass
    //   seq  8  D(SN3)       write "three"                 → pass
    //   seq  9  H(2,3,c=6)   write "three"        9%3=0    → DROP
    //   seq 10  D(SN4)       write "four"                  → pass
    //   seq 11  H(3,4,c=7)   write "four"                  → pass
    //
    // After write "four": KEEP_LAST-2 cache = [SN3, SN4]; SN1 and SN2 evicted.
    //
    // mt_r.q before Round 1 (8 items):
    //   H(c=1), H(c=2), D(SN1), H(c=4), H(c=5), D(SN3), D(SN4), H(3,4,c=7)
    //
    // Round 1 mt_r (left-to-right through the 8 items):
    //   H(c=1)      → no virtual GAP (empty writer); NACK → mt_w
    //   H(c=2)      → same; NACK → mt_w
    //   D(SN1)      → in-order (cumAck 0→1); delivered immediately
    //   H(c=4,1,1)  → cumAck=last=1; pure ACK → mt_w
    //   H(c=5,1,2)  → SN2 missing; NACK(SN2) → mt_w
    //   D(SN3)      → out-of-order (cumAck=1); buffered in pending_changes
    //   D(SN4)      → out-of-order; buffered
    //   H(3,4,c=7)  → first_sn=3 > cumAck+1=2 → virtual GAP marks SN2 received
    //                  → cumAck jumps to 4 → deliverPendingLocked delivers SN3, SN4
    //
    // After Round 1: 3 samples [SN1, SN3, SN4] delivered; SN2 never arrives.
    // Round 1 mt_w processes queued NACKs; retransmit sends are duplicates the
    // reader silently ignores (received.contains check in handleData).
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop = DropEveryNth.init(3);
    const lossy_w = try LossyTransport.init(alloc, mt_w.transport(), drop.packetPolicy());
    defer lossy_w.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy_w.transport(),
        .keep_last,
        2,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp); // seq 1: H(1,0,c=1) → pass

    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp); // initial NACK → mt_w.q

    // Shift the lossy_w sequence counter by 2 so DATA(SN2) falls at seq 6.
    writer.sendHeartbeat(false); // seq 2: H(1,0,c=2) → pass
    writer.sendHeartbeat(false); // seq 3: H(1,0,c=3) → DROP

    try write(writer, "one"); // seq  4: D(SN1)    → pass
    // seq  5: H(1,1,c=4) → pass
    try write(writer, "two"); // seq  6: D(SN2)    → DROP  (evicted after write "four")
    // seq  7: H(1,2,c=5) → pass
    try write(writer, "three"); // seq  8: D(SN3)    → pass
    // seq  9: H(2,3,c=6) → DROP
    try write(writer, "four"); // seq 10: D(SN4)    → pass
    // seq 11: H(3,4,c=7) → pass
    // KEEP_LAST-2 cache = [SN3, SN4]; SN1 and SN2 evicted.

    // Sanity-check the pre-delivery drop count.
    try testing.expectEqual(@as(u64, 3), lossy_w.dropped.load(.monotonic));

    // Round 1: reader delivers SN1, buffers SN3/SN4, then H(3,4,c=7) fires the
    // virtual GAP for SN2 (first_sn=3 > cumAck+1=2), which unblocks SN3 and SN4.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "four", col.samples.items[2]);
}

test "suppress_live_data: live write during history replay is ordered after history" {
    // A live sample written while suppress_live_data=true is skipped by
    // sendChangeToAllLocked but accumulates in the cache.  Once the periodic HB
    // fires and the reader NACKs for the live SN (non-final, cumAck >= floor),
    // suppress is cleared and the live sample is delivered — after the 3 history
    // samples, not before.
    //
    // Writer (KEEP_ALL): "one","two","three" written before reader joins (floor=3).
    // addMatchedReader : suppress=true. HB(1,3,c=1) dropped.
    // addMatchedWriter : NACK-1(base=1, empty, non-final) queued.
    // write("four")   : SN=4 added to cache; suppressed for the reader.
    // Round 1         : NACK-1 → non-final tail sends DATA(1,2,3) + capped HB(1,3,c=2).
    //                   SN=4 skipped by Guard 2 (4 > floor=3).
    // Round 2         : reader gets DATA(1,2,3)+HB → delivers "one","two","three";
    //                   sends FINAL NACK(base=4) → suppress not cleared (final).
    // Round 3         : writer gets FINAL NACK → no DATA (suppress, final, nothing sent).
    // sendHeartbeat   : HB(1,4,c=3) to reader (periodic HB reveals live range).
    // Round 4         : reader gets HB(1,4) → missing {4}; sends NON-FINAL NACK(base=4,{4}).
    //                   Writer: !is_final, highest_sn=3 >= floor=3 → suppress cleared.
    //                   Bitmap sends DATA(4); trailing HB uncapped.
    // Round 5         : reader gets DATA(4) → delivers "four".
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop = DropFirst.init(1);
    const lossy_w = try LossyTransport.init(alloc, mt_w.transport(), drop.packetPolicy());
    defer lossy_w.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    try write(writer, "one");
    try write(writer, "two");
    try write(writer, "three");

    // addMatchedReader: HB(1,3,c=1) dropped; suppress_live_data=true, floor=3.
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    try testing.expectEqual(@as(u64, 1), lossy_w.dropped.load(.monotonic));

    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Live write while suppress is active; sendChangeToAllLocked skips the reader.
    try write(writer, "four");

    // Round 1: NACK-1 → tail loop sends DATA(1,2,3) + capped HB(1,3). SN=4 blocked.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 2: reader delivers "one","two","three"; sends FINAL NACK(base=4).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);

    // Round 3: FINAL NACK → suppress not cleared, nothing sent.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);

    // Periodic HB reveals live range; reader NACKs non-finally for SN=4.
    writer.sendHeartbeat(false);

    // Round 4: NON-FINAL NACK(base=4) → highest_sn=3 >= floor=3 → suppress cleared;
    //          DATA(4) sent via bitmap.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);

    // Round 5: DATA(4) arrives → "four" delivered.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 4), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);
    try testing.expectEqualSlices(u8, "four", col.samples.items[3]);
}

test "suppress_live_data: KEEP_LAST eviction past floor clears flag, no malformed HB" {
    // Verifies the fix for writer_sm.zig: when KEEP_LAST eviction moves cache_first
    // past history_floor_sn, suppress_live_data is cleared on the next NACK so
    // the trailing HB uses the full (uncapped) range and is well-formed.
    //
    // Writer (KEEP_LAST-1): "old" written → floor=1, suppress=true, cache={SN=1}.
    // HB(1,1,c=1) dropped.
    // addMatchedWriter: NACK-1(base=1, empty, non-final) queued.
    // write("new"): KEEP_LAST-1 evicts SN=1 → cache={SN=2}. cache_first=2 > floor=1.
    // Round 1: NACK-1 arrives → evicted_past_floor=true → suppress cleared.
    //          Non-final tail sends DATA(SN=2); trailing HB is uncapped (first=2,last=2).
    // Round 2: reader gets DATA(2) → delivers "new".
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop = DropFirst.init(1);
    const lossy_w = try LossyTransport.init(alloc, mt_w.transport(), drop.packetPolicy());
    defer lossy_w.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy_w.transport(),
        .keep_last,
        1,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    try write(writer, "old");

    // addMatchedReader: suppress=true, floor=1. HB(1,1,c=1) dropped.
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    try testing.expectEqual(@as(u64, 1), lossy_w.dropped.load(.monotonic));

    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Evict the history sample: cache_first moves to SN=2, past floor=1.
    try write(writer, "new");

    // Round 1: NACK(base=1, non-final) → evicted_past_floor → suppress cleared.
    //          DATA(SN=2) sent (tail loop, SN=2 > base=1, not in empty bitmap).
    //          Trailing HB uses uncapped last_sn=2 (well-formed: first=2, last=2).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 2: DATA(2) arrives → delivers "new". "old" (SN=1) was evicted and lost.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), col.samples.items.len);
    try testing.expectEqualSlices(u8, "new", col.samples.items[0]);
}

test "dispose_survives_nack_replay: not_alive_disposed replayed with correct STATUS_INFO" {
    // Verifies that non-alive ChangeKind values are stored in the cache, flow
    // through the NACK-driven replay path, and arrive at the reader with the
    // correct STATUS_INFO inline QoS (bit 0 set = DISPOSE).
    //
    // Writer: "data"(alive), ""(disposed), "more"(alive).
    // Reader joins late; receives all three via NACK-driven replay.
    const alloc = testing.allocator;

    // Kind-aware collector: records (kind, data) for each received change.
    const KindItem = struct { kind: ChangeKind, data: []u8 };
    const KindCollector = struct {
        alloc: std.mem.Allocator,
        items: std.ArrayListUnmanaged(KindItem),

        fn init(a: std.mem.Allocator) @This() {
            return .{ .alloc = a, .items = .empty };
        }
        fn deinit(self: *@This()) void {
            for (self.items.items) |it| self.alloc.free(it.data);
            self.items.deinit(self.alloc);
        }
        fn onData(ctx: *anyopaque, ch: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            const copy = self.alloc.dupe(u8, ch.data) catch return;
            self.items.append(self.alloc, .{ .kind = ch.kind, .data = copy }) catch {
                self.alloc.free(copy);
            };
        }
        fn callback(self: *@This()) rtps.DataCallback {
            return .{ .ctx = self, .on_data = onData };
        }
    };

    // Kind-aware reader dispatch: decodes STATUS_INFO inline QoS → ChangeKind.
    const KindReaderDispatch = struct {
        reader: *StatefulReader,

        fn makeHandler(self: *@This()) ReceiveHandler {
            return .{ .ctx = self, .on_receive = recv };
        }
        fn recv(ctx: *anyopaque, data: []const u8, _: Locator) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            var params: [32]InlineQosParam = undefined;
            var it = MessageIterator.init(data) catch return;
            const src = it.header.guid_prefix;
            while (it.next(&params) catch null) |sub| switch (sub) {
                .data => |d| {
                    const wguid = Guid{ .prefix = src, .entity_id = d.writer_entity_id };
                    const kind: ChangeKind = if (d.inline_qos) |iq|
                        if (iq.get(.status_info)) |si| blk: {
                            if (si.len >= 4) {
                                // StatusInfo_t is {unused,unused,unused,status} (RTPS §9.4.5.11):
                                // an octet array, always big-endian regardless of message endianness.
                                const v = std.mem.readInt(u32, si[0..4], .big);
                                if (v & 0x1 != 0) break :blk ChangeKind.not_alive_disposed;
                                if (v & 0x2 != 0) break :blk ChangeKind.not_alive_unregistered;
                            }
                            break :blk ChangeKind.alive;
                        } else ChangeKind.alive
                    else
                        ChangeKind.alive;
                    const ch = CacheChange{
                        .kind = kind,
                        .writer_guid = wguid,
                        .sequence_number = d.writer_sn,
                        .source_timestamp = NIL_TS,
                        .instance_handle = NIL_IH,
                        .key_hash = NIL_KH,
                        .data = d.serialized_payload,
                    };
                    self.reader.handleData(wguid, ch) catch {};
                },
                .heartbeat => |hb| {
                    const wguid = Guid{ .prefix = src, .entity_id = hb.writer_entity_id };
                    self.reader.handleHeartbeat(wguid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
                },
                else => {},
            };
        }
    };

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop = DropFirst.init(1);
    const lossy_w = try LossyTransport.init(alloc, mt_w.transport(), drop.packetPolicy());
    defer lossy_w.deinit(alloc);

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        lossy_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = KindCollector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var krd = KindReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, krd.makeHandler());

    // Write three changes: alive, disposed, alive.
    _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, "data");
    _ = try writer.write(.not_alive_disposed, NIL_TS, NIL_IH, NIL_KH, "");
    _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, "more");

    // Reader joins late; suppress=true, floor=3. Initial HB dropped.
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Round 1: NACK-1(empty bitmap) → tail sends DATA(1,2,3) + capped HB(1,3).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.items.items.len);

    // Round 2: all three arrive and are delivered.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.items.items.len);
    try testing.expect(col.items.items[0].kind == .alive);
    try testing.expectEqualSlices(u8, "data", col.items.items[0].data);
    try testing.expect(col.items.items[1].kind == .not_alive_disposed);
    try testing.expectEqualSlices(u8, "", col.items.items[1].data);
    try testing.expect(col.items.items[2].kind == .alive);
    try testing.expectEqualSlices(u8, "more", col.items.items[2].data);
}

test "acknack_dedup: same count after retransmit is suppressed; new count is processed" {
    // Verifies last_ack_nack_count deduplication in handleAckNack.
    //
    // All 3 history samples are written before matching so suppress_live_data=true
    // and start_sn=1 (replay_on_match=true).  The reader's outgoing transport uses
    // DropEveryNth(1) (drops 100%) so the writer only sees NACKs from manual
    // handleAckNack calls — no dispatch-originated NACKs interfere.
    //
    // FINAL NACKs are used to exercise only the bitmap path (no tail loop), giving
    // precise control over which SN each NACK triggers.
    //
    // Phase 1: FINAL NACK(count=42, {SN1}) → DATA(1) delivered; last_ack_nack_count=42.
    // Phase 2 (dedup): FINAL NACK(count=42, {SN2}) → ignored; col stays at 1.
    //          SN2 is not yet in ReceivedSet, so only dedup can explain col=1.
    // Phase 3: FINAL NACK(count=43, {SN2}) → DATA(2) delivered; col grows to 2.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // mt_r first so deliverAll processes reader before writer.
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    // Reader's outgoing transport drops every packet so the writer never sees
    // any dispatch-originated NACK — only the manual handleAckNack calls land.
    var drop_all = DropEveryNth.init(1);
    const lossy_r = try LossyTransport.init(alloc, mt_r.transport(), drop_all.packetPolicy());
    defer lossy_r.deinit(alloc);

    // Writer uses the direct transport so DATA sent via handleAckNack reach mt_r.
    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        true,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, lossy_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    // Write all 3 history samples before matching: suppress=true, floor=3, start_sn=1.
    try write(writer, "one");
    try write(writer, "two");
    try write(writer, "three");

    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    // Give the reader a WriterProxy so handleData can deliver received changes.
    // The reader's initial NACK (and all future NACKs) are dropped by lossy_r.
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Drain the initial HB from addMatchedReader; reader's NACK response is dropped.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // snSet: build a SequenceNumberSet with `n` consecutive bits starting at `base`.
    const snSet = struct {
        fn make(base: SequenceNumber, n: u32) msg.submessage.SequenceNumberSet {
            var sns = msg.submessage.SequenceNumberSet{
                .base = base,
                .num_bits = n,
                .bitmap = std.mem.zeroes([8]u32),
            };
            var i: u32 = 0;
            while (i < n) : (i += 1) sns.set(base + @as(SequenceNumber, i));
            return sns;
        }
    }.make;

    // Clear suppress_live_data before testing dedup: dedup is intentionally disabled
    // while suppress is active (duplicate NACKs during replay give RTI's DataReader
    // extra time to flush history).  A non-final NACK with highest_sn >= floor=3 and
    // base=4 (beyond the cache) clears suppress without triggering retransmit or
    // updating last_ack_nack_count (retransmit_count=0 — no SNs >= base=4 in cache).
    writer.handleAckNack(R1_GUID, 3, snSet(4, 0), 1, false);
    // suppress_live_data is now false; last_ack_nack_count is still null.

    // Phase 1: FINAL NACK(count=42, {SN1}) → bitmap sends DATA(1); col=1.
    //          is_final=true skips the tail loop so only the requested SN is sent.
    writer.handleAckNack(R1_GUID, 0, snSet(1, 1), 42, true);
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);

    // Phase 2 (dedup): FINAL NACK(count=42, {SN2}) → dropped (suppress=false, same count).
    // SN2 is not yet in ReceivedSet, so only dedup explains col staying at 1.
    writer.handleAckNack(R1_GUID, 1, snSet(2, 1), 42, true);
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), col.samples.items.len);

    // Phase 3: FINAL NACK(count=43, {SN2}) → processed; DATA(2) delivered; col=2.
    writer.handleAckNack(R1_GUID, 1, snSet(2, 1), 43, true);
    net.deliverAll();
    try testing.expectEqual(@as(usize, 2), col.samples.items.len);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
}

test "coherent_set: writes deferred until endCoherentSet" {
    // Verifies that writes during a coherent set are not sent until
    // endCoherentSet() is called, and that coherent_set_sn is patched
    // on each CacheChange to the last SN in the set.
    //
    // A RELIABLE reader proxy is matched before the coherent window opens.
    // During the window: addMatchedReader sends an initial HB (no DATA).
    // Each writer.write() call accumulates the SN without calling sendChangeToAllLocked.
    // After endCoherentSet(.full): all 3 DATAs are flushed with coherent_set_sn=3.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();

    // replay_on_match=false (VOLATILE): no history replay; start_sn = next_sn at match.
    // This avoids the suppress_live_data machinery which complicates the test.
    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    // Match reader and writer.
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Drain the initial HB (from VOLATILE addMatchedReader sending an empty range HB).
    net.deliverAll();
    net.deliverAll(); // second round for the reader's ACKNACK response

    // Begin coherent set: writes are now deferred.
    writer.beginCoherentSet(true);
    try write(writer, "alpha");
    try write(writer, "beta");
    try write(writer, "gamma");

    // No DATA should have been sent yet — all are pending in coherent_pending_sns.
    // Any packets in the queue are at most HBs from the RELIABLE send path
    // (sendChangeToAllLocked is not called during coherent mode).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Verify coherent_set_sn is null before end (changes are still deferred).
    writer.mu.lock();
    for (writer.cache.changes.items) |*ch| {
        try testing.expectEqual(@as(?SequenceNumber, null), ch.coherent_set_sn);
    }
    writer.mu.unlock();

    // End coherent set with .full: patch all 3 changes and flush DATA.
    writer.endCoherentSet(.full, false, null, 0, false);

    // Verify coherent_set_sn is patched to first SN (1) on all 3 changes.
    writer.mu.lock();
    for (writer.cache.changes.items) |*ch| {
        try testing.expectEqual(@as(?SequenceNumber, 1), ch.coherent_set_sn);
    }
    writer.mu.unlock();

    // Deliver the 3 DATA packets (plus HBs); reader should receive all 3 samples.
    net.deliverAll();
    net.deliverAll(); // second round for HB/NACK/retransmit exchange
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "alpha", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "beta", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "gamma", col.samples.items[2]);
}

test "coherent_set: mode=none sends without PID_COHERENT_SET" {
    // Verifies that endCoherentSet(.none) flushes pending writes but does NOT
    // patch coherent_set_sn on the CacheChanges (used for suspend_publications).
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);
    net.deliverAll();
    net.deliverAll();

    writer.beginCoherentSet(true);
    try write(writer, "x");
    try write(writer, "y");

    // End with .none: changes sent but coherent_set_sn stays null.
    writer.endCoherentSet(.none, false, null, 0, false);

    writer.mu.lock();
    for (writer.cache.changes.items) |*ch| {
        try testing.expectEqual(@as(?SequenceNumber, null), ch.coherent_set_sn);
    }
    writer.mu.unlock();

    net.deliverAll();
    net.deliverAll();
    try testing.expectEqual(@as(usize, 2), col.samples.items.len);
}

test "coherent_set: mode=group_seq_only emits group_seq_num but not coherent_set_sn" {
    // Verifies that endCoherentSet(.group_seq_only) assigns group_seq_num but
    // NOT coherent_set_sn or group_coherent_sn (ordered_access without coherent_access).
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();

    const writer = try StatefulWriter.init(
        alloc,
        W1_GUID,
        mt_w.transport(),
        .keep_all,
        0,
        EntityIds.unknown,
        rtps.writer_sm.DEFAULT_FRAG_SIZE,
        false,
    );
    defer writer.deinit();

    const reader = try StatefulReader.init(alloc, R1_GUID, mt_r.transport(), .keep_all, 0, true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);
    net.deliverAll();
    net.deliverAll();

    writer.beginCoherentSet(true);
    try write(writer, "x");
    try write(writer, "y");

    // .group_seq_only: group_seq_num is assigned, coherent_set_sn stays null.
    writer.endCoherentSet(.group_seq_only, false, null, 0, false);

    writer.mu.lock();
    for (writer.cache.changes.items) |*ch| {
        try testing.expectEqual(@as(?SequenceNumber, null), ch.coherent_set_sn);
        try testing.expect(ch.group_seq_num != null);
        try testing.expectEqual(@as(?SequenceNumber, null), ch.group_coherent_sn);
    }
    writer.mu.unlock();

    net.deliverAll();
    net.deliverAll();
    try testing.expectEqual(@as(usize, 2), col.samples.items.len);
}

test "coherent_set: multi-writer publisher shares GSN counter for global ordering" {
    // Regression for per-writer group_seq_num_counter bug.  Without the fix,
    // two writers in the same publisher both start from their own counter (both
    // assign GSN=1 to their first sample), making group order undefined.
    // With the fix, the publisher passes a shared counter pointer to each writer's
    // endCoherentSet so GSNs are globally unique across the coherent set.
    //
    // Writer 1 has samples A(SN=1) and C(SN=2); writer 2 has sample B(SN=1).
    // Simulated publisher flushes W1 first, then W2.
    // Expected GSNs: A=1, C=2 (W1), B=3 (W2).
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w1 = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w1.deinit();
    const mt_w2 = try MockTransport.init(alloc, net, &.{W2_LOC});
    defer mt_w2.deinit();

    const w1 = try StatefulWriter.init(alloc, W1_GUID, mt_w1.transport(), .keep_all, 0, EntityIds.unknown, rtps.writer_sm.DEFAULT_FRAG_SIZE, false);
    defer w1.deinit();
    const w2 = try StatefulWriter.init(alloc, W2_GUID, mt_w2.transport(), .keep_all, 0, EntityIds.unknown, rtps.writer_sm.DEFAULT_FRAG_SIZE, false);
    defer w2.deinit();

    // Add a reader proxy to each writer so GSNs are actually assigned.
    const rp1 = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try w1.addMatchedReader(rp1);
    const rp2 = try ReaderProxy.init(alloc, R2_GUID, &.{R2_LOC}, &.{}, false, true);
    try w2.addMatchedReader(rp2);

    // Open coherent windows on both writers (simulating publisher beginCoherentSet).
    w1.beginCoherentSet(true);
    w2.beginCoherentSet(true);

    // W1 writes A and C; W2 writes B (interleaved to reflect real multi-writer usage).
    _ = try w1.write(.alive, NIL_TS, NIL_IH, NIL_KH, "A");
    _ = try w2.write(.alive, NIL_TS, NIL_IH, NIL_KH, "B");
    _ = try w1.write(.alive, NIL_TS, NIL_IH, NIL_KH, "C");

    // Pre-count total pending samples across both writers to compute global_last_gsn,
    // mirroring what the publisher's vtEndCoherent does.
    const total_n: i64 = @intCast(w1.coherentWindowPendingCount() + w2.coherentWindowPendingCount());
    const global_last_gsn: i64 = 0 + total_n; // shared_gsn starts at 0

    // Flush both writers with a shared publisher counter (simulating vtEndCoherent).
    var shared_gsn: i64 = 0;
    w1.endCoherentSet(.full, false, &shared_gsn, global_last_gsn, false); // W1: A=GSN1, C=GSN2; shared_gsn=2
    w2.endCoherentSet(.full, false, &shared_gsn, global_last_gsn, false); // W2: B=GSN3; shared_gsn=3

    // Verify W1's samples got globally-unique GSNs 1 and 2.
    w1.mu.lock();
    var gsns_w1: [2]?i64 = .{ null, null };
    var group_coherent_w1: ?i64 = null;
    for (w1.cache.changes.items, 0..) |*ch, i| {
        if (i < 2) gsns_w1[i] = ch.group_seq_num;
        if (ch.group_coherent_sn != null) group_coherent_w1 = ch.group_coherent_sn;
    }
    w1.mu.unlock();
    try testing.expectEqual(@as(?i64, 1), gsns_w1[0]);
    try testing.expectEqual(@as(?i64, 2), gsns_w1[1]);
    // W1's last sample must carry the GROUP-WIDE last GSN (3), not just its own (2).
    try testing.expectEqual(@as(?i64, 3), group_coherent_w1);

    // Verify W2's sample got GSN 3 (continuing from W1's range, not restarting at 1).
    w2.mu.lock();
    const gsn_w2 = w2.cache.changes.items[0].group_seq_num;
    const group_coherent_w2 = w2.cache.changes.items[0].group_coherent_sn;
    w2.mu.unlock();
    try testing.expectEqual(@as(?i64, 3), gsn_w2);
    // W2's last sample also carries the group-wide last GSN.
    try testing.expectEqual(@as(?i64, 3), group_coherent_w2);
}
