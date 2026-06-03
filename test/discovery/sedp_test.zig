//! SEDP unit tests.
//!
//! Tests encode/decode round-trips for WriterAnnouncement and ReaderAnnouncement,
//! endpoint disposal (retract), and the combined SPDP→SEDP flow (proxy
//! establishment, callback delivery, and re-announcement idempotency).
//!
//! All tests use MockNetwork / MockTransport so no real sockets are opened.

const std = @import("std");
const zzdds = @import("zzdds");

const sedp_mod = zzdds.sedp_discovery;
const iface = zzdds.discovery;
const mock_tr = zzdds.mock_transport;

const SedpEndpoints = sedp_mod.SedpEndpoints;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;
const Locator = mock_tr.Locator;
const Guid = iface.Guid;
const GuidPrefix = iface.GuidPrefix;
const Callbacks = iface.Callbacks;
const ParticipantAnnouncement = iface.ParticipantAnnouncement;
const ParticipantData = iface.ParticipantData;
const WriterAnnouncement = iface.WriterAnnouncement;
const ReaderAnnouncement = iface.ReaderAnnouncement;
const WriterData = iface.WriterData;
const ReaderData = iface.ReaderData;
const QosSnapshot = iface.QosSnapshot;

// RTPS §8.5.4.2 BuiltinEndpointSet flags (DISC subset).
const BES_PUB_ANNOUNCER: u32 = 0x00000004;
const BES_PUB_DETECTOR: u32 = 0x00000008;
const BES_SUB_ANNOUNCER: u32 = 0x00000010;
const BES_SUB_DETECTOR: u32 = 0x00000020;

const testing = std.testing;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn prefix(b: u8) GuidPrefix {
    return .{ .bytes = [_]u8{b} ** 12 };
}

fn makeGuid(p: u8, eid_key: u8) Guid {
    return .{
        .prefix = prefix(p),
        .entity_id = .{ .entity_key = .{ eid_key, 0, 0 }, .entity_kind = 0x04 },
    };
}

const ALL_SEDP_ENDPOINTS: u32 = BES_PUB_ANNOUNCER | BES_PUB_DETECTOR | BES_SUB_ANNOUNCER | BES_SUB_DETECTOR;

// Per-participant locator port allocation: each participant gets a unique port
// derived from its prefix byte so MockNetwork routing is unambiguous.
fn metaPort(p: u8) u16 {
    return 7410 + @as(u16, p);
}
fn dataPort(p: u8) u16 {
    return 7420 + @as(u16, p);
}

// ── Event recorder ────────────────────────────────────────────────────────────

const SnapshotW = struct {
    guid: Guid,
    topic: []u8,
    typ: []u8,
    qos: QosSnapshot,
    alloc: std.mem.Allocator,
    fn deinit(self: *@This()) void {
        self.alloc.free(self.topic);
        self.alloc.free(self.typ);
    }
};

const SnapshotR = struct {
    guid: Guid,
    topic: []u8,
    typ: []u8,
    qos: QosSnapshot,
    alloc: std.mem.Allocator,
    fn deinit(self: *@This()) void {
        self.alloc.free(self.topic);
        self.alloc.free(self.typ);
    }
};

const Recorder = struct {
    alloc: std.mem.Allocator,
    writers_found: std.ArrayListUnmanaged(SnapshotW) = .empty,
    readers_found: std.ArrayListUnmanaged(SnapshotR) = .empty,
    writers_lost: std.ArrayListUnmanaged(Guid) = .empty,
    readers_lost: std.ArrayListUnmanaged(Guid) = .empty,

    fn deinit(self: *Recorder) void {
        for (self.writers_found.items) |*s| s.deinit();
        for (self.readers_found.items) |*s| s.deinit();
        self.writers_found.deinit(self.alloc);
        self.readers_found.deinit(self.alloc);
        self.writers_lost.deinit(self.alloc);
        self.readers_lost.deinit(self.alloc);
    }

    fn callbacks(self: *Recorder) Callbacks {
        return .{
            .ctx = self,
            .on_participant_discovered = noopParticipant,
            .on_participant_lost = noopParticipantLost,
            .on_writer_discovered = onWriterDiscovered,
            .on_writer_lost = onWriterLost,
            .on_reader_discovered = onReaderDiscovered,
            .on_reader_lost = onReaderLost,
        };
    }

    fn noopParticipant(_: *anyopaque, _: *const ParticipantData) void {}
    fn noopParticipantLost(_: *anyopaque, _: Guid) void {}

    fn onWriterDiscovered(ctx: *anyopaque, d: *const WriterData) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const s = SnapshotW{
            .alloc = self.alloc,
            .guid = d.guid,
            .topic = self.alloc.dupe(u8, d.topic_name) catch return,
            .typ = self.alloc.dupe(u8, d.type_name) catch return,
            .qos = d.qos,
        };
        self.writers_found.append(self.alloc, s) catch {};
    }
    fn onReaderDiscovered(ctx: *anyopaque, d: *const ReaderData) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        const s = SnapshotR{
            .alloc = self.alloc,
            .guid = d.guid,
            .topic = self.alloc.dupe(u8, d.topic_name) catch return,
            .typ = self.alloc.dupe(u8, d.type_name) catch return,
            .qos = d.qos,
        };
        self.readers_found.append(self.alloc, s) catch {};
    }
    fn onWriterLost(ctx: *anyopaque, guid: Guid) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.writers_lost.append(self.alloc, guid) catch {};
    }
    fn onReaderLost(ctx: *anyopaque, guid: Guid) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.readers_lost.append(self.alloc, guid) catch {};
    }
};

// ── Test harness ──────────────────────────────────────────────────────────────

/// One SEDP participant in a shared MockNetwork.
/// Both `rec` and `cbs` are heap-allocated so their addresses are stable after
/// init() returns — the SEDP callbacks hold a pointer to rec.
const Participant = struct {
    transport: *MockTransport,
    sedp: *SedpEndpoints,
    cbs: *Callbacks,
    rec: *Recorder,

    fn init(net: *MockNetwork, p: u8) !Participant {
        const alloc = testing.allocator;

        // Locators as named stack arrays: valid for the duration of init()
        // because start() only reads them transiently (extracts port, calls listen).
        const meta_loc = Locator.udp4(.{ 127, 0, 0, p }, metaPort(p));
        const data_loc = Locator.udp4(.{ 127, 0, 0, p }, dataPort(p));
        const meta_locs = [_]Locator{meta_loc};
        const data_locs = [_]Locator{data_loc};

        const t = try MockTransport.init(alloc, net, &meta_locs);
        errdefer t.deinit();
        const sedp = try SedpEndpoints.init(alloc, t.transport());
        errdefer sedp.deinit();

        // Heap-allocate Recorder so its address is stable for the callback ctx.
        const rec = try alloc.create(Recorder);
        errdefer alloc.destroy(rec);
        rec.* = Recorder{ .alloc = alloc };

        const cbs = try alloc.create(Callbacks);
        errdefer alloc.destroy(cbs);
        cbs.* = rec.callbacks();

        const local = ParticipantAnnouncement{
            .guid = makeGuid(p, 0x01),
            .domain_id = 0,
            .name = "",
            .metatraffic_unicast_locators = &meta_locs,
            .metatraffic_multicast_locators = &.{},
            .default_unicast_locators = &data_locs,
            .default_multicast_locators = &.{},
            .lease_duration_ms = 10_000,
            .builtin_endpoint_set = ALL_SEDP_ENDPOINTS,
        };
        try sedp.start(&local, cbs);

        return .{ .transport = t, .sedp = sedp, .cbs = cbs, .rec = rec };
    }

    fn deinit(self: *Participant) void {
        const alloc = testing.allocator;
        self.sedp.stop();
        self.sedp.deinit();
        self.transport.deinit();
        self.rec.deinit();
        alloc.destroy(self.rec);
        alloc.destroy(self.cbs);
    }

    /// Notify this participant that peer `p` has been discovered via SPDP.
    /// onParticipantDiscovered dups the locators internally so stack-local
    /// arrays here are safe.
    fn discoverPeer(self: *Participant, p: u8) void {
        const meta_loc = Locator.udp4(.{ 127, 0, 0, p }, metaPort(p));
        const data_loc = Locator.udp4(.{ 127, 0, 0, p }, dataPort(p));
        const meta_locs = [_]Locator{meta_loc};
        const data_locs = [_]Locator{data_loc};
        const data = ParticipantData{
            .guid = makeGuid(p, 0x01),
            .domain_id = 0,
            .name = "",
            .metatraffic_unicast_locators = &meta_locs,
            .metatraffic_multicast_locators = &.{},
            .default_unicast_locators = &data_locs,
            .default_multicast_locators = &.{},
            .lease_duration_ms = 10_000,
            .builtin_endpoint_set = ALL_SEDP_ENDPOINTS,
        };
        SedpEndpoints.onParticipantDiscovered(self.sedp, &data);
    }
};

// ── Tests: encode/decode round-trips ─────────────────────────────────────────

test "SEDP: WriterAnnouncement encode/decode round-trip" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x01);
    var remote = try Participant.init(net, 0x02);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x02);
    remote.discoverPeer(0x01);

    const writer_guid = makeGuid(0x01, 0x10);
    try local.sedp.announceWriter(&.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x01, 0x01),
        .topic_name = "HelloWorldTopic",
        .type_name = "HelloWorld",
        .qos = .{ .reliability_kind = 1, .durability_kind = 0 },
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    const found = &remote.rec.writers_found.items[0];
    try testing.expect(found.guid.eql(writer_guid));
    try testing.expectEqualStrings("HelloWorldTopic", found.topic);
    try testing.expectEqualStrings("HelloWorld", found.typ);
    try testing.expectEqual(@as(u8, 1), found.qos.reliability_kind);
}

test "SEDP: ReaderAnnouncement encode/decode round-trip" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x03);
    var remote = try Participant.init(net, 0x04);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x04);
    remote.discoverPeer(0x03);

    const reader_guid = makeGuid(0x03, 0x20);
    try local.sedp.announceReader(&.{
        .guid = reader_guid,
        .participant_guid = makeGuid(0x03, 0x01),
        .topic_name = "SensorData",
        .type_name = "Sensor",
        .qos = .{ .reliability_kind = 0, .durability_kind = 1 },
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.readers_found.items.len);
    const found = &remote.rec.readers_found.items[0];
    try testing.expect(found.guid.eql(reader_guid));
    try testing.expectEqualStrings("SensorData", found.topic);
    try testing.expectEqualStrings("Sensor", found.typ);
    try testing.expectEqual(@as(u8, 0), found.qos.reliability_kind);
    try testing.expectEqual(@as(u8, 1), found.qos.durability_kind);
}

// ── Tests: endpoint retraction ────────────────────────────────────────────────

test "SEDP: retractWriter fires on_writer_lost on remote" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x05);
    var remote = try Participant.init(net, 0x06);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x06);
    remote.discoverPeer(0x05);

    const writer_guid = makeGuid(0x05, 0x10);
    try local.sedp.announceWriter(&.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x05, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    try testing.expectEqual(@as(usize, 0), remote.rec.writers_lost.items.len);

    local.sedp.retractWriter(writer_guid);
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_lost.items.len);
    try testing.expect(remote.rec.writers_lost.items[0].eql(writer_guid));
}

test "SEDP: retractReader fires on_reader_lost on remote" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x07);
    var remote = try Participant.init(net, 0x08);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x08);
    remote.discoverPeer(0x07);

    const reader_guid = makeGuid(0x07, 0x20);
    try local.sedp.announceReader(&.{
        .guid = reader_guid,
        .participant_guid = makeGuid(0x07, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), remote.rec.readers_found.items.len);
    try testing.expectEqual(@as(usize, 0), remote.rec.readers_lost.items.len);

    local.sedp.retractReader(reader_guid);
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.readers_lost.items.len);
    try testing.expect(remote.rec.readers_lost.items[0].eql(reader_guid));
}

// ── Tests: SPDP→SEDP combined flow ───────────────────────────────────────────

test "SEDP: announcement before peer discovery is replayed after onParticipantDiscovered" {
    // Write to the pub_writer cache before any proxy exists, then discover the
    // peer — the StatefulWriter replays cached history to the new proxy.
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x09);
    var remote = try Participant.init(net, 0x0a);
    defer local.deinit();
    defer remote.deinit();

    // Announce before cross-wiring — no proxies yet, so nothing is delivered.
    const writer_guid = makeGuid(0x09, 0x10);
    try local.sedp.announceWriter(&.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x09, 0x01),
        .topic_name = "RT",
        .type_name = "RTT",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    try testing.expectEqual(@as(usize, 0), remote.rec.writers_found.items.len);

    // Now wire participant discovery — StatefulWriter replays the cached change.
    local.discoverPeer(0x0a);
    remote.discoverPeer(0x09);
    // One round for the DATA replay, one for AckNack/HB exchange.
    net.deliverAll();
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    try testing.expect(remote.rec.writers_found.items[0].guid.eql(writer_guid));
}

test "SEDP: WriterAnnouncement with non-default PRESENTATION round-trips correctly" {
    // Verifies that PID_PRESENTATION (0x0021) is encoded when non-default and that
    // the decoded QosSnapshot carries the correct access_scope / coherent / ordered
    // values, guarding against byte-layout regressions.
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x11);
    var remote = try Participant.init(net, 0x12);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x12);
    remote.discoverPeer(0x11);

    try local.sedp.announceWriter(&.{
        .guid = makeGuid(0x11, 0x10),
        .participant_guid = makeGuid(0x11, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{
            .presentation_access_scope = 1, // TOPIC
            .coherent_access = false,
            .ordered_access = true,
        },
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    const w = &remote.rec.writers_found.items[0];
    try testing.expectEqual(@as(u8, 1), w.qos.presentation_access_scope);
    try testing.expectEqual(false, w.qos.coherent_access);
    try testing.expectEqual(true, w.qos.ordered_access);
}

test "SEDP: ReaderAnnouncement with non-default PRESENTATION round-trips correctly" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x13);
    var remote = try Participant.init(net, 0x14);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x14);
    remote.discoverPeer(0x13);

    try local.sedp.announceReader(&.{
        .guid = makeGuid(0x13, 0x20),
        .participant_guid = makeGuid(0x13, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{
            .presentation_access_scope = 2, // GROUP
            .coherent_access = true,
            .ordered_access = true,
        },
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.readers_found.items.len);
    const r = &remote.rec.readers_found.items[0];
    try testing.expectEqual(@as(u8, 2), r.qos.presentation_access_scope);
    try testing.expectEqual(true, r.qos.coherent_access);
    try testing.expectEqual(true, r.qos.ordered_access);
}

test "SEDP: second onParticipantDiscovered replaces proxy without adding a duplicate" {
    // A second onParticipantDiscovered for the same peer (e.g. after SPDP lease
    // re-expiry) replaces the existing proxy in place rather than appending a new
    // one.  The proxy count must remain 1, not grow to 2.
    // Note: re-discovery intentionally replays cached history so the peer gets the
    // latest state — only the proxy LIST size is the invariant here.
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x0b);
    var remote = try Participant.init(net, 0x0c);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x0c);
    remote.discoverPeer(0x0b);

    const writer_guid = makeGuid(0x0b, 0x10);
    try local.sedp.announceWriter(&.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x0b, 0x01),
        .topic_name = "Idem",
        .type_name = "I",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    net.deliverAll();

    // Verify the proxy is present (exactly one writer GUID in pub_writer proxies).
    // We check this via matchedReaderCount on the pub_writer state machine.
    const count_before = local.sedp.pub_writer.?.reader_proxies.items.len;
    try testing.expectEqual(@as(usize, 1), count_before);

    // Second discovery of the same participant.
    local.discoverPeer(0x0c);
    remote.discoverPeer(0x0b);
    net.deliverAll();
    net.deliverAll();

    const count_after = local.sedp.pub_writer.?.reader_proxies.items.len;
    try testing.expectEqual(@as(usize, 1), count_after);
}
