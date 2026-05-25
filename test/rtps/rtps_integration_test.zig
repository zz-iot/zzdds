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

test "loss_recovery: DATA dropped, HEARTBEAT triggers NACK, retransmit delivers" {
    // LossyTransport drops the first 3 sends (DATA 1-3 during replay) but
    // forwards the 4th (HEARTBEAT).  The reader proxy is added AFTER the HB
    // has been ignored, so the initial NACK from addMatchedWriter drives
    // retransmit in the following rounds.
    //
    // Round 1: HEARTBEAT arrives; reader has no writer proxy → ignored.
    // addMatchedWriter: reader sends initial NACK(cumAck=0) → mt_w queue.
    // Round 2: NACK → writer retransmits DATA(1,2,3) + HEARTBEAT (seqs 5-8).
    // Round 3: retransmitted DATA arrives → reader delivers all three.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    // The lossy shim sits between the writer and the MockNetwork.
    // It drops the first 3 sends (DATA 1-3) and forwards everything after
    // (the HEARTBEAT at send seq 4, and all retransmits).
    //
    // mt_r is created first so it is first in the MockNetwork member list.
    // Delivery order [mt_r, mt_w] means mt_w→mt_r costs one extra round,
    // giving the deterministic three-round sequence asserted below.
    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop = DropFirst.init(3);
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

    // WriterDispatch listens on mt_w directly so ACKNACKs from the reader
    // bypass the lossy shim (loss is writer→reader only, not reader→writer).
    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&W1_LOC, wd.makeHandler());
    try mt_r.transport().listen(&R1_LOC, rd.makeHandler());

    // Write 3 samples before adding proxies; they will be replayed on match.
    try write(writer, "one");
    try write(writer, "two");
    try write(writer, "three");

    // addMatchedReader triggers replay: DATA(1,2,3) dropped by lossy shim (seqs 1-3),
    // HEARTBEAT forwarded (seq 4) → enqueued in mt_r.
    // The reader proxy is NOT added yet so the reader will ignore the HEARTBEAT.
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);

    try testing.expectEqual(@as(usize, 0), col.samples.items.len);
    try testing.expectEqual(@as(u64, 3), lossy.dropped.load(.monotonic));

    // Round 1: reader receives HEARTBEAT(1,3) but has no writer proxy → ignores it.
    //          Nothing queued in mt_w; 0 samples delivered.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Now wire the writer proxy. addMatchedWriter immediately sends an initial
    // NACK (cumAck=0) → enqueued in mt_w, to be processed next round.
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    // Round 2: writer processes NACK → retransmits DATA(1,2,3) + HEARTBEAT.
    //          (seqs 5-8, all > 3, none dropped.)
    //          mt_r was empty at round start so no samples yet.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 3: reader gets retransmitted DATA(1,2,3) → all three delivered.
    net.deliverAll();

    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);

    // Sanity: exactly 3 drops (the initial DATA packets), none thereafter.
    try testing.expectEqual(@as(u64, 3), lossy.dropped.load(.monotonic));
}

test "loss_nack_drop: initial NACK dropped, HB-triggered NACK recovers data" {
    // Verifies that a dropped NACK does not cause a permanent stall.
    // The reader re-derives the same NACK from its received set on every
    // non-final heartbeat, so recovery succeeds as soon as one gets through.
    //
    // Writer→reader: DropFirst(3) — with HEARTBEAT-before-DATA replay ordering,
    //   this drops HB(c=1)+DATA(1)+DATA(2); DATA(3) is forwarded (seq 4).
    // Reader→writer: DropFirst(1) — drops the initial NACK from addMatchedWriter.
    //
    // deliverAll() delivers member transports sequentially (mt_r then mt_w), so a
    // packet generated in mt_r's delivery slot (e.g. a NACK sent in response to a
    // HB) can be processed by mt_w in the same round.
    //
    //   addMatchedReader : HB(c=1) dropped (seq 1); DATA(1,2) dropped (seqs 2-3);
    //                      DATA(3) queued in mt_r (seq 4).  awaiting_first_ack=true.
    //   addMatchedWriter : NACK-1 dropped by lossy_r.
    //   Round 1          : mt_r delivers DATA(3) → buffered (SN3 out-of-order).
    //                      No HB arrives, so no re-NACK is generated.
    //   sendHeartbeat    : HB(1,3,c=2) forwarded (seq 5, DropFirst exhausted).
    //   Round 2          : mt_r delivers HB → reader re-derives NACK(1,2)
    //                      (DropFirst(1) exhausted → passes to mt_w); mt_w delivers
    //                      NACK → clears awaiting_first_ack, retransmits DATA(1,2).
    //   Round 3          : DATA(1,2) arrive → SN1,SN2 delivered; SN3 unblocked → 3 total.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop_data = DropFirst.init(3);
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

    // Replay: DATA(1-3) dropped (lossy_w seqs 1-3); HB(1,3) forwarded (seq 4).
    const rp = try ReaderProxy.init(alloc, R1_GUID, &.{R1_LOC}, &.{}, false, true);
    try writer.addMatchedReader(rp);

    // addMatchedWriter sends an initial NACK → dropped by lossy_r (seq 1).
    const wp = try WriterProxy.init(alloc, W1_GUID, &.{W1_LOC}, &.{}, true);
    try reader.addMatchedWriter(wp);

    try testing.expectEqual(@as(u64, 3), lossy_w.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), lossy_r.dropped.load(.monotonic));

    // Round 1: DATA(3) arrives at reader → buffered (SN3 out-of-order, cumAck=0).
    //          No HB arrived, so no re-NACK is generated.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Simulate the writer's periodic heartbeat (the replay HB was dropped).
    // seq 5: forwarded by lossy_w (DropFirst(3) exhausted after seq 3).
    writer.sendHeartbeat(false);

    // Round 2: HB(1,3,c=2) → reader re-derives NACK(1,2) (DropFirst(1) exhausted →
    //          passes to mt_w); mt_w delivers NACK → clears awaiting_first_ack,
    //          retransmits DATA(1,2) + trailing HB (seqs 6-8, all forwarded).
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 3: DATA(1,2) arrive → deliver "one","two"; SN3 already buffered → "three".
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);

    // Exactly 3 writer-side drops (HB+DATA(1,2) from replay) and 1 reader-side drop.
    try testing.expectEqual(@as(u64, 3), lossy_w.dropped.load(.monotonic));
    try testing.expectEqual(@as(u64, 1), lossy_r.dropped.load(.monotonic));
}

test "loss_nack_drop_two: two NACKs dropped; periodic HB re-triggers recovery" {
    // Extends loss_nack_drop: both the initial NACK and the first HB-triggered
    // NACK are dropped.  After two silent rounds the writer's periodic heartbeat
    // fires (simulated via sendHeartbeat then a direct handleHeartbeat call).  The
    // reader re-derives the same missing-SN bitmap from its unchanged received set
    // and the third NACK reaches the writer, completing recovery.
    //
    // Writer→reader: DropFirst(3) — with HEARTBEAT-before-DATA replay ordering,
    //   drops HB(c=1)+DATA(1)+DATA(2); DATA(3) is forwarded (seq 4).
    // Reader→writer: DropFirst(2) — drops the first two NACKs.
    //
    //   addMatchedReader : HB(c=1) dropped; DATA(1,2) dropped; DATA(3) queued.
    //                      awaiting_first_ack=true.
    //   addMatchedWriter : NACK-1 dropped.
    //   Round 1          : DATA(3) buffered; no HB arrives; no NACK triggered.
    //   sendHeartbeat    : HB(1,3,c=2) forwarded (seq 5).
    //   Round 2          : HB(1,3,c=2) → NACK-2 dropped; writer stays silent.
    //   [periodic HB]    : handleHeartbeat(c=3) called directly → NACK-3 passes.
    //   Round 3          : NACK-3 → clears awaiting_first_ack, retransmits DATA(1,2).
    //   Round 4          : DATA(1,2) arrive; SN3 unblocked → 3 samples.
    const alloc = testing.allocator;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_r = try MockTransport.init(alloc, net, &.{R1_LOC});
    defer mt_r.deinit();
    const mt_w = try MockTransport.init(alloc, net, &.{W1_LOC});
    defer mt_w.deinit();

    var drop_data = DropFirst.init(3);
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

    // Round 1: DATA(3) buffered at reader (cumAck=0, out-of-order). No HB arrived,
    //          so no re-NACK is generated; writer stays silent.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);
    try testing.expectEqual(@as(u64, 1), lossy_r.dropped.load(.monotonic));

    // Simulate writer periodic heartbeat #1 (replay HB was dropped).
    // seq 5: forwarded (DropFirst(3) exhausted after seq 3).
    writer.sendHeartbeat(false);

    // Round 2: HB(1,3,c=2) → reader re-derives NACK(1,2) → NACK-2 dropped by
    //          lossy_r (DropFirst(2) seq 2); writer stays silent.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);
    try testing.expectEqual(@as(u64, 2), lossy_r.dropped.load(.monotonic));

    // Simulate writer periodic heartbeat #2.  The reader re-derives the same
    // missing-SN bitmap; DropFirst(2) is exhausted so NACK-3 is forwarded into mt_w.
    reader.handleHeartbeat(W1_GUID, 1, 3, 3, false);

    // Round 3: NACK-3 → clears awaiting_first_ack, retransmits DATA(1,2) + trailing HB.
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), col.samples.items.len);

    // Round 4: DATA(1,2) arrive → deliver "one","two"; SN3 unblocked → "three".
    net.deliverAll();
    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    try testing.expectEqualSlices(u8, "one", col.samples.items[0]);
    try testing.expectEqualSlices(u8, "two", col.samples.items[1]);
    try testing.expectEqualSlices(u8, "three", col.samples.items[2]);

    try testing.expectEqual(@as(u64, 3), lossy_w.dropped.load(.monotonic));
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
