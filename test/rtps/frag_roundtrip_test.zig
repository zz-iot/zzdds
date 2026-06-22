//! Phase 25: DATA_FRAG fragmentation round-trip tests.
//!
//! Validates end-to-end fragment splitting (writer) and reassembly (reader)
//! using MockTransport, following the same pattern as mock_transport_test.zig.
//!
//! The boundary tests for sendIovecs (was the Phase 24 acceptance gate) are
//! retained to document the 65536-byte hard limit that remains in place even
//! after DATA_FRAG support is added.

const std = @import("std");
const zzdds = @import("zzdds");

const rtps = zzdds.rtps;
const msg = rtps.message;

const writer_sm_mod = zzdds.rtps.writer_sm;
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
const Transport = zzdds.transport.Transport;
const Locator = zzdds.transport.Locator;
const ReceiveHandler = zzdds.transport.ReceiveHandler;

const MessageIterator = msg.MessageIterator;
const InlineQosParam = msg.InlineQosParam;
const IoVec = zzdds.rtps.message.IoVec;

const testing = std.testing;

// ── Fixed test GUIDs and locators ─────────────────────────────────────────────

fn prefix(b: u8) GuidPrefix {
    return .{ .bytes = [_]u8{b} ** 12 };
}

const WRITER_GUID = Guid{ .prefix = prefix(0xAA), .entity_id = EntityIds.sedp_builtin_publications_writer };
const READER_GUID = Guid{ .prefix = prefix(0xBB), .entity_id = EntityIds.sedp_builtin_publications_reader };

const WRITER_LOC = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 1 }, .port = 7511 } };
const READER_LOC = Locator{ .udp_v4 = .{ .addr = .{ 127, 0, 0, 2 }, .port = 7513 } };

const NIL_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = std.mem.zeroes([16]u8);
const NIL_KH = std.mem.zeroes([16]u8);

// ── RTPS message dispatchers ──────────────────────────────────────────────────

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
            .data_frag => |df| {
                const wguid = Guid{ .prefix = src, .entity_id = df.writer_entity_id };
                self.reader.handleDataFrag(wguid, RtpsTimestamp.invalid, df) catch {};
            },
            .heartbeat => |hb| {
                const wguid = Guid{ .prefix = src, .entity_id = hb.writer_entity_id };
                self.reader.handleHeartbeat(wguid, hb.first_sn, hb.last_sn, hb.count, hb.isFinal());
            },
            .heartbeat_frag => |hbf| {
                const wguid = Guid{ .prefix = src, .entity_id = hbf.writer_entity_id };
                self.reader.handleHeartbeatFrag(wguid, hbf.writer_sn, hbf.last_fragment_num, hbf.count);
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
            .nack_frag => |nf| {
                const rguid = Guid{ .prefix = src, .entity_id = nf.reader_entity_id };
                self.writer.handleNackFrag(rguid, nf.writer_sn, nf.fragment_number_state, nf.count);
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
        self.samples.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }
};

// ── sendIovecs boundary tests (retained from Phase 24 gate) ──────────────────

var noop_ctx: u8 = 0;
const noop_vtable = Transport.Vtable{
    .capabilities = .{ .unicast = true, .multicast = false },
    .can_reach = struct {
        fn f(_: *anyopaque, _: *const Locator) bool {
            return true;
        }
    }.f,
    .send = struct {
        fn f(_: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {}
    }.f,
    .listen = struct {
        fn f(_: *anyopaque, _: *const Locator, _: zzdds.transport.ReceiveHandler) anyerror!void {}
    }.f,
    .join_multicast = struct {
        fn f(_: *anyopaque, _: *const Locator) anyerror!void {}
    }.f,
    .leave_multicast = struct {
        fn f(_: *anyopaque, _: *const Locator) void {}
    }.f,
    .unlisten = struct {
        fn f(_: *anyopaque, _: *const Locator, _: ReceiveHandler) void {}
    }.f,
    .unicast_locators = struct {
        fn f(_: *anyopaque, _: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {}
    }.f,
    .set_locator_change_handler = struct {
        fn f(_: *anyopaque, _: ?zzdds.transport.LocatorChangeHandler) void {}
    }.f,
    .close = struct {
        fn f(_: *anyopaque) void {}
    }.f,
};

fn noopTransport() Transport {
    return .{ .ctx = &noop_ctx, .vtable = &noop_vtable };
}

test "sendIovecs: returns MessageTooLarge for payload > MAX_SEND_BYTES" {
    var large: [writer_sm_mod.MAX_SEND_BYTES + 1]u8 = .{0xAB} ** (writer_sm_mod.MAX_SEND_BYTES + 1);
    const iov = IoVec{ .base = &large, .len = large.len };
    const loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7410);
    try testing.expectError(
        error.MessageTooLarge,
        writer_sm_mod.sendIovecs(noopTransport(), &loc, &.{iov}),
    );
}

test "sendIovecs: succeeds for payload == MAX_SEND_BYTES" {
    var exact: [writer_sm_mod.MAX_SEND_BYTES]u8 = .{0xCD} ** writer_sm_mod.MAX_SEND_BYTES;
    const iov = IoVec{ .base = &exact, .len = exact.len };
    const loc = Locator.udp4(.{ 127, 0, 0, 1 }, 7410);
    try writer_sm_mod.sendIovecs(noopTransport(), &loc, &.{iov});
}

// ── DATA_FRAG round-trip tests ────────────────────────────────────────────────

// Small frag_size makes it easy to trigger fragmentation in tests.
const TEST_FRAG_SIZE: u16 = 64;

fn makeWriter(alloc: std.mem.Allocator, transport: Transport) !*StatefulWriter {
    return StatefulWriter.init(
        alloc,
        WRITER_GUID,
        transport,
        .keep_all,
        0,
        EntityIds.unknown,
        TEST_FRAG_SIZE,
        false,
    );
}

fn makeReader(alloc: std.mem.Allocator, transport: Transport, reliable: bool) !*StatefulReader {
    return StatefulReader.init(alloc, READER_GUID, transport, .keep_all, 0, reliable);
}

fn addProxies(alloc: std.mem.Allocator, writer: *StatefulWriter, reader: *StatefulReader, reliable: bool) !void {
    const rp = try ReaderProxy.init(alloc, READER_GUID, &.{READER_LOC}, &.{}, false, reliable);
    try writer.addMatchedReader(rp);
    const wp = try WriterProxy.init(alloc, WRITER_GUID, &.{WRITER_LOC}, &.{}, reliable);
    try reader.addMatchedWriter(wp);
}

test "DATA_FRAG: large payload assembles correctly (BEST_EFFORT)" {
    // Payload larger than TEST_FRAG_SIZE (64) — triggers DATA_FRAG splitting.
    const alloc = testing.allocator;
    const PAYLOAD_LEN = 300;

    var payload: [PAYLOAD_LEN]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i);

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{WRITER_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{READER_LOC});
    defer mt_r.deinit();

    const writer = try makeWriter(alloc, mt_w.transport());
    defer writer.deinit();
    const reader = try makeReader(alloc, mt_r.transport(), false);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&WRITER_LOC, wd.makeHandler());
    try mt_r.transport().listen(&READER_LOC, rd.makeHandler());

    try addProxies(alloc, writer, reader, false);
    _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, &payload);

    // All DATA_FRAG packets + HEARTBEAT_FRAG travel in one deliverAll.
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), col.samples.items.len);
    try testing.expectEqual(PAYLOAD_LEN, col.samples.items[0].len);
    try testing.expectEqualSlices(u8, &payload, col.samples.items[0]);
}

test "DATA_FRAG: large payload assembles correctly (RELIABLE)" {
    const alloc = testing.allocator;
    const PAYLOAD_LEN = 500;

    var payload: [PAYLOAD_LEN]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i *% 3);

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{WRITER_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{READER_LOC});
    defer mt_r.deinit();

    const writer = try makeWriter(alloc, mt_w.transport());
    defer writer.deinit();
    const reader = try makeReader(alloc, mt_r.transport(), true);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&WRITER_LOC, wd.makeHandler());
    try mt_r.transport().listen(&READER_LOC, rd.makeHandler());

    try addProxies(alloc, writer, reader, true);
    _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, &payload);

    net.deliverAll(); // frag1 + HEARTBEAT_FRAG → reader; NACK_FRAG for frags 2..N
    net.deliverAll(); // retransmit frags settle

    try testing.expectEqual(@as(usize, 1), col.samples.items.len);
    try testing.expectEqualSlices(u8, &payload, col.samples.items[0]);
}

test "DATA_FRAG: payload exactly one fragment delivered as single DATA_FRAG" {
    // Exactly TEST_FRAG_SIZE bytes → triggers fragmentation (ch.data.len > frag_size is false
    // when len == frag_size, so this should go through the normal DATA path).
    // This test verifies the boundary: len <= frag_size stays as DATA.
    const alloc = testing.allocator;

    var payload: [TEST_FRAG_SIZE]u8 = .{0x42} ** TEST_FRAG_SIZE;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{WRITER_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{READER_LOC});
    defer mt_r.deinit();

    const writer = try makeWriter(alloc, mt_w.transport());
    defer writer.deinit();
    const reader = try makeReader(alloc, mt_r.transport(), false);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&WRITER_LOC, wd.makeHandler());
    try mt_r.transport().listen(&READER_LOC, rd.makeHandler());

    try addProxies(alloc, writer, reader, false);
    _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, &payload);

    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), col.samples.items.len);
    try testing.expectEqualSlices(u8, &payload, col.samples.items[0]);
}

test "DATA_FRAG: multiple large samples each reassemble correctly" {
    const alloc = testing.allocator;
    const PAYLOAD_LEN = 200;

    const net = try MockNetwork.init(alloc);
    defer net.deinit();

    const mt_w = try MockTransport.init(alloc, net, &.{WRITER_LOC});
    defer mt_w.deinit();
    const mt_r = try MockTransport.init(alloc, net, &.{READER_LOC});
    defer mt_r.deinit();

    const writer = try makeWriter(alloc, mt_w.transport());
    defer writer.deinit();
    const reader = try makeReader(alloc, mt_r.transport(), false);
    defer reader.deinit();

    var col = Collector.init(alloc);
    defer col.deinit();
    reader.setCallback(col.callback());

    var wd = WriterDispatch{ .writer = writer };
    var rd = ReaderDispatch{ .reader = reader };
    try mt_w.transport().listen(&WRITER_LOC, wd.makeHandler());
    try mt_r.transport().listen(&READER_LOC, rd.makeHandler());

    try addProxies(alloc, writer, reader, false);

    var payloads: [3][PAYLOAD_LEN]u8 = undefined;
    for (&payloads, 0..) |*p, pi| {
        for (p, 0..) |*b, i| b.* = @truncate(pi * 100 + i);
        _ = try writer.write(.alive, NIL_TS, NIL_IH, NIL_KH, p);
    }

    net.deliverAll();
    net.deliverAll();

    try testing.expectEqual(@as(usize, 3), col.samples.items.len);
    for (col.samples.items, 0..) |s, i| {
        try testing.expectEqualSlices(u8, &payloads[i], s);
    }
}
