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
const DDS = zzdds.DDS;
const dwire = zzdds.disc_wire;
const rtps_time = zzdds.util.time;

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

/// Prepares and commits a local writer's announcement.
fn announceWriterNow(se: *SedpEndpoints, ann: *const WriterAnnouncement) !void {
    try se.prepareWriter(ann);
    se.announceWriter(ann.guid);
}

/// Prepares and commits a local reader's announcement.
fn announceReaderNow(se: *SedpEndpoints, ann: *const ReaderAnnouncement) !void {
    try se.prepareReader(ann);
    se.announceReader(ann.guid);
}
const WriterData = iface.WriterData;
const ReaderData = iface.ReaderData;

// RTPS §8.5.4.2 BuiltinEndpointSet flags (DISC subset).
const BES_PUB_ANNOUNCER: u32 = 0x00000004;
const BES_PUB_DETECTOR: u32 = 0x00000008;
const BES_SUB_ANNOUNCER: u32 = 0x00000010;
const BES_SUB_DETECTOR: u32 = 0x00000020;

const testing = std.testing;

// ── Helpers ───────────────────────────────────────────────────────────────────

fn prefix(b: u8) GuidPrefix {
    return .{ .bytes = @as([12]u8, @splat(b)) };
}

fn makeGuid(p: u8, eid_key: u8) Guid {
    return .{
        .prefix = prefix(p),
        .entity_id = .{ .entity_key = .{ eid_key, 0, 0 }, .entity_kind = 0x04 },
    };
}

const ALL_SEDP_ENDPOINTS: u32 = BES_PUB_ANNOUNCER | BES_PUB_DETECTOR | BES_SUB_ANNOUNCER | BES_SUB_DETECTOR;

// ── QoS builders / readers for the typed discovery model ─────────────────────

fn dwq(reliable: bool, durability: u8) DDS.DataWriterQos {
    return .{
        .reliability = .{ .kind = if (reliable) .RELIABLE_RELIABILITY_QOS else .BEST_EFFORT_RELIABILITY_QOS, .max_blocking_time = .{} },
        .durability = .{ .kind = @fromBackingInt(@intCast(durability)) },
    };
}
fn drq(reliable: bool, durability: u8) DDS.DataReaderQos {
    return .{
        .reliability = .{ .kind = if (reliable) .RELIABLE_RELIABILITY_QOS else .BEST_EFFORT_RELIABILITY_QOS, .max_blocking_time = .{} },
        .durability = .{ .kind = @fromBackingInt(@intCast(durability)) },
    };
}
fn pres(scope: u32, coherent: bool, ordered: bool) DDS.PresentationQosPolicy {
    return .{ .access_scope = @fromBackingInt(@intCast(scope)), .coherent_access = coherent, .ordered_access = ordered };
}
fn udPolicy(bytes: []const u8) DDS.UserDataQosPolicy {
    return .{ .value = .{ ._maximum = @intCast(bytes.len), ._length = @intCast(bytes.len), ._buffer = @constCast(bytes.ptr), ._release = false } };
}
fn relK(q: anytype) u8 {
    return iface.discReliabilityKind(q);
}
fn durK(q: anytype) u8 {
    return @intCast(q.durabilityKind);
}
fn presScope(q: anytype) u8 {
    return if (q.presentation) |x| @intCast(x.access_scope) else 0;
}
fn presCoh(q: anytype) bool {
    return if (q.presentation) |x| x.coherent_access else false;
}
fn presOrd(q: anytype) bool {
    return if (q.presentation) |x| x.ordered_access else false;
}
fn wireDur(od: ?dwire.Duration_t) rtps_time.Duration {
    const d = od orelse return rtps_time.Duration.infinite;
    return (rtps_time.RtpsDuration{ .seconds = d.seconds, .fraction = d.fraction }).toDuration();
}

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
    user_data: []u8,
    partitions: [][]u8, // owned deep copy of WriterData.partition_names
    qos: dwire.DiscoveredWriterData, // owned clone
    alloc: std.mem.Allocator,
    fn deinit(self: *@This()) void {
        self.alloc.free(self.topic);
        self.alloc.free(self.typ);
        self.alloc.free(self.user_data);
        for (self.partitions) |p| self.alloc.free(p);
        self.alloc.free(self.partitions);
        self.qos.deinit(self.alloc);
    }
};

fn dupePartitions(alloc: std.mem.Allocator, names: []const []const u8) ![][]u8 {
    const out = try alloc.alloc([]u8, names.len);
    errdefer alloc.free(out);
    var done: usize = 0;
    errdefer for (out[0..done]) |p| alloc.free(p);
    for (names, 0..) |nm, i| {
        out[i] = try alloc.dupe(u8, nm);
        done = i + 1;
    }
    return out;
}

const SnapshotR = struct {
    guid: Guid,
    topic: []u8,
    typ: []u8,
    user_data: []u8,
    qos: dwire.DiscoveredReaderData, // owned clone
    alloc: std.mem.Allocator,
    fn deinit(self: *@This()) void {
        self.alloc.free(self.topic);
        self.alloc.free(self.typ);
        self.alloc.free(self.user_data);
        self.qos.deinit(self.alloc);
    }
};

const Recorder = struct {
    alloc: std.mem.Allocator,
    writers_found: std.ArrayListUnmanaged(SnapshotW) = .empty,
    readers_found: std.ArrayListUnmanaged(SnapshotR) = .empty,
    writers_lost: std.ArrayListUnmanaged(Guid) = .empty,
    readers_lost: std.ArrayListUnmanaged(Guid) = .empty,
    /// When set, discovery callbacks check they are not running under one
    /// of these SEDP endpoints' built-in reader locks (they reach
    /// application listeners in a real participant).
    sedp: ?*SedpEndpoints = null,
    called_under_reader_lock: bool = false,

    fn checkUnlocked(self: *Recorder) void {
        const s = self.sedp orelse return;
        inline for (.{ s.pub_reader, s.sub_reader }) |maybe_r| if (maybe_r) |r| {
            if (r.mu.tryLock()) r.mu.unlock() else self.called_under_reader_lock = true;
        };
    }

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
            .on_wlp_alive = noopWlpAlive,
        };
    }

    fn noopParticipant(_: *anyopaque, _: *const ParticipantData) void {}
    fn noopWlpAlive(_: *anyopaque, _: GuidPrefix, _: u8) void {}
    fn noopParticipantLost(_: *anyopaque, _: Guid) void {}

    fn onWriterDiscovered(ctx: *anyopaque, d: *const WriterData) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.checkUnlocked();
        const user_data = self.alloc.dupe(u8, iface.discUserData(d.qos)) catch return;
        const qos = d.qos.clone(self.alloc) catch return;
        const parts = dupePartitions(self.alloc, d.partition_names) catch return;
        const s = SnapshotW{
            .alloc = self.alloc,
            .guid = d.guid,
            .topic = self.alloc.dupe(u8, d.topic_name) catch return,
            .typ = self.alloc.dupe(u8, d.type_name) catch return,
            .user_data = user_data,
            .partitions = parts,
            .qos = qos,
        };
        self.writers_found.append(self.alloc, s) catch {};
    }
    fn onReaderDiscovered(ctx: *anyopaque, d: *const ReaderData) void {
        const self: *Recorder = @ptrCast(@alignCast(ctx));
        self.checkUnlocked();
        const user_data = self.alloc.dupe(u8, iface.discUserData(d.qos)) catch return;
        const qos = d.qos.clone(self.alloc) catch return;
        const s = SnapshotR{
            .alloc = self.alloc,
            .guid = d.guid,
            .topic = self.alloc.dupe(u8, d.topic_name) catch return,
            .typ = self.alloc.dupe(u8, d.type_name) catch return,
            .user_data = user_data,
            .qos = qos,
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
            .vendor_id = .{ .bytes = .{ 0x00, 0x00 } },
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
    try announceWriterNow(local.sedp, &.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x01, 0x01),
        .topic_name = "HelloWorldTopic",
        .type_name = "HelloWorld",
        .qos = dwq(true, 0),
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    const found = &remote.rec.writers_found.items[0];
    try testing.expect(found.guid.eql(writer_guid));
    try testing.expectEqualStrings("HelloWorldTopic", found.topic);
    try testing.expectEqualStrings("HelloWorld", found.typ);
    try testing.expectEqual(@as(u8, 1), relK(&found.qos));
}

test "SEDP: announcements are processed after the built-in reader's lock is released" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x01);
    var remote = try Participant.init(net, 0x02);
    defer local.deinit();
    defer remote.deinit();
    remote.rec.sedp = remote.sedp;

    local.discoverPeer(0x02);
    remote.discoverPeer(0x01);

    try announceWriterNow(local.sedp, &.{
        .guid = makeGuid(0x01, 0x10),
        .participant_guid = makeGuid(0x01, 0x01),
        .topic_name = "T",
        .type_name = "Ty",
        .qos = dwq(true, 0),
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try announceReaderNow(local.sedp, &.{
        .guid = makeGuid(0x01, 0x11),
        .participant_guid = makeGuid(0x01, 0x01),
        .topic_name = "T",
        .type_name = "Ty",
        .qos = drq(true, 0),
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    try testing.expectEqual(@as(usize, 1), remote.rec.readers_found.items.len);
    try testing.expect(!remote.rec.called_under_reader_lock);
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
    try announceReaderNow(local.sedp, &.{
        .guid = reader_guid,
        .participant_guid = makeGuid(0x03, 0x01),
        .topic_name = "SensorData",
        .type_name = "Sensor",
        .qos = drq(false, 1),
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.readers_found.items.len);
    const found = &remote.rec.readers_found.items[0];
    try testing.expect(found.guid.eql(reader_guid));
    try testing.expectEqualStrings("SensorData", found.topic);
    try testing.expectEqualStrings("Sensor", found.typ);
    try testing.expectEqual(@as(u8, 0), relK(&found.qos));
    try testing.expectEqual(@as(u8, 1), durK(&found.qos));
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
    try announceWriterNow(local.sedp, &.{
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

    const later_writer_guid = makeGuid(0x05, 0x11);
    try announceWriterNow(local.sedp, &.{
        .guid = later_writer_guid,
        .participant_guid = makeGuid(0x05, 0x01),
        .topic_name = "LaterT",
        .type_name = "TT",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    var found_later_writer = false;
    for (remote.rec.writers_found.items) |found| {
        found_later_writer = found_later_writer or found.guid.eql(later_writer_guid);
    }
    try testing.expect(found_later_writer);
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
    try announceReaderNow(local.sedp, &.{
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

    const later_reader_guid = makeGuid(0x07, 0x21);
    try announceReaderNow(local.sedp, &.{
        .guid = later_reader_guid,
        .participant_guid = makeGuid(0x07, 0x01),
        .topic_name = "LaterT",
        .type_name = "TT",
        .qos = .{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    var found_later_reader = false;
    for (remote.rec.readers_found.items) |found| {
        found_later_reader = found_later_reader or found.guid.eql(later_reader_guid);
    }
    try testing.expect(found_later_reader);
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
    try announceWriterNow(local.sedp, &.{
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

    try announceWriterNow(local.sedp, &.{
        .guid = makeGuid(0x11, 0x10),
        .participant_guid = makeGuid(0x11, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{},
        .presentation = pres(1, false, true), // TOPIC
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    const w = &remote.rec.writers_found.items[0];
    try testing.expectEqual(@as(u8, 1), presScope(&w.qos));
    try testing.expectEqual(false, presCoh(&w.qos));
    try testing.expectEqual(true, presOrd(&w.qos));
}

test "SEDP: WriterAnnouncement USER_DATA round-trips as binary octets" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x31);
    var remote = try Participant.init(net, 0x32);
    defer local.deinit();
    defer remote.deinit();
    local.discoverPeer(0x32);
    remote.discoverPeer(0x31);

    const user_data = [_]u8{ 't', 'y', 'p', 'e', 0, 0xff };
    try announceWriterNow(local.sedp, &.{
        .guid = makeGuid(0x31, 0x10),
        .participant_guid = makeGuid(0x31, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{ .user_data = udPolicy(&user_data) },
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    try testing.expectEqualSlices(u8, &user_data, remote.rec.writers_found.items[0].user_data);
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

    try announceReaderNow(local.sedp, &.{
        .guid = makeGuid(0x13, 0x20),
        .participant_guid = makeGuid(0x13, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{},
        .presentation = pres(2, true, true), // GROUP
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.readers_found.items.len);
    const r = &remote.rec.readers_found.items[0];
    try testing.expectEqual(@as(u8, 2), presScope(&r.qos));
    try testing.expectEqual(true, presCoh(&r.qos));
    try testing.expectEqual(true, presOrd(&r.qos));
}

test "SEDP: second onParticipantDiscovered replaces proxy without adding a duplicate" {
    // A second onParticipantDiscovered for the same peer (a rediscovery whose
    // loss was never reported) replaces the existing proxy in place rather than
    // appending a new one.  The proxy count must remain 1, not grow to 2.
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
    try announceWriterNow(local.sedp, &.{
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

test "SEDP: WriterAnnouncement with group_guid encodes and delivers without error" {
    // Covers sedp.zig lines 180-188: the PID_GROUP_GUID block that encodes the
    // publisher-group GUID into the DiscoveredWriterData inline QoS parameters.
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x15);
    var remote = try Participant.init(net, 0x16);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x16);
    remote.discoverPeer(0x15);

    const writer_guid = makeGuid(0x15, 0x10);
    try announceWriterNow(local.sedp, &.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x15, 0x01),
        .group_guid = makeGuid(0x15, 0x01), // publisher participant GUID as group GUID
        .topic_name = "GroupTopic",
        .type_name = "GroupType",
        .qos = .{},
        .presentation = pres(2, true, false),
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    try testing.expect(remote.rec.writers_found.items[0].guid.eql(writer_guid));
}

test "SEDP: WriterAnnouncement with lifespan and deadline QoS round-trips correctly" {
    // Covers sedp.zig lines 151-153 (writeDdsDuration for lifespan) and 519-522
    // (lifespan decode), and 236/363 + 477-482 (deadline encode/decode).
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x17);
    var remote = try Participant.init(net, 0x18);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x18);
    remote.discoverPeer(0x17);

    try announceWriterNow(local.sedp, &.{
        .guid = makeGuid(0x17, 0x10),
        .participant_guid = makeGuid(0x17, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{
            .lifespan = .{ .duration = .{ .sec = 10, .nanosec = 500_000_000 } },
            .deadline = .{ .period = .{ .sec = 5, .nanosec = 0 } },
        },
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    const found = &remote.rec.writers_found.items[0];
    try testing.expectEqual(@as(i32, 10), wireDur(found.qos.lifespan).sec);
    try testing.expectEqual(@as(u32, 500_000_000), wireDur(found.qos.lifespan).nanosec);
    try testing.expectEqual(@as(i32, 5), wireDur(found.qos.deadline).sec);
    try testing.expectEqual(@as(u32, 0), wireDur(found.qos.deadline).nanosec);
}

test "SEDP: a writer with >32 PARTITION names delivers all of them (no truncation)" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x19);
    var remote = try Participant.init(net, 0x1A);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x1A);
    remote.discoverPeer(0x19);

    var names: [40][]const u8 = undefined;
    var storage: [40][16]u8 = undefined;
    for (0..40) |i| names[i] = std.fmt.bufPrint(&storage[i], "partition-{d}", .{i}) catch unreachable;

    try announceWriterNow(local.sedp, &.{
        .guid = makeGuid(0x19, 0x10),
        .participant_guid = makeGuid(0x19, 0x01),
        .topic_name = "T",
        .type_name = "TT",
        .qos = .{},
        .partition_names = &names,
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();

    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
    const got = remote.rec.writers_found.items[0].partitions;
    try testing.expectEqual(@as(usize, 40), got.len);
    for (0..40) |i| try testing.expectEqualStrings(names[i], got[i]);
}

test "SEDP: a peer lost and rediscovered on one side has its endpoints delivered again" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var local = try Participant.init(net, 0x1B);
    var remote = try Participant.init(net, 0x1C);
    defer local.deinit();
    defer remote.deinit();

    local.discoverPeer(0x1C);
    remote.discoverPeer(0x1B);

    const reader_guid = makeGuid(0x1C, 0x20);
    try announceReaderNow(remote.sedp, &.{
        .guid = reader_guid,
        .participant_guid = makeGuid(0x1C, 0x01),
        .topic_name = "Again",
        .type_name = "AgainT",
        .qos = .{},
        .type_info_cdr = &.{},
    });
    const writer_guid = makeGuid(0x1B, 0x10);
    try announceWriterNow(local.sedp, &.{
        .guid = writer_guid,
        .participant_guid = makeGuid(0x1B, 0x01),
        .topic_name = "Again",
        .type_name = "AgainT",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), local.rec.readers_found.items.len);
    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);

    // A long session: local has sent many ACKNACKs, and the peer last
    // retransmitted for one with a high count. The peer ignores counts no
    // higher than that one.
    const local_reader = local.sedp.sub_reader.?;
    local_reader.ack_count += 100_000;
    remote.sedp.sub_writer.?.sendHeartbeat(false, false);
    net.deliverAll();
    const peer_writer = remote.sedp.sub_writer.?;
    try testing.expectEqual(@as(usize, 1), peer_writer.reader_proxies.items.len);
    peer_writer.reader_proxies.items[0].last_ack_nack_count = local_reader.ack_count;

    // Only local loses the peer, as when its lease runs out on one side.
    SedpEndpoints.onParticipantLost(local.sedp, prefix(0x1C));
    local.discoverPeer(0x1C);

    // The peer kept its proxies, so its periodic heartbeat (fired here by
    // hand) is what tells local to ask for its announcements again.
    // Local's next ACKNACK counts on from that session's, so the peer acts
    // on it.
    var round: usize = 0;
    while (local.rec.readers_found.items.len < 2 and round < 2) : (round += 1) {
        remote.sedp.sub_writer.?.sendHeartbeat(false, false);
        net.deliverAll();
        net.deliverAll();
    }
    try testing.expectEqual(@as(usize, 2), local.rec.readers_found.items.len);
    try testing.expect(local.rec.readers_found.items[1].guid.eql(reader_guid));
    // The peer never lost local: local's replay to it is all duplicates.
    try testing.expectEqual(@as(usize, 1), remote.rec.writers_found.items.len);
}

test "SEDP: peers that lose and rediscover each other exchange their endpoints again" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();

    var a = try Participant.init(net, 0x1D);
    var b = try Participant.init(net, 0x1E);
    defer a.deinit();
    defer b.deinit();

    a.discoverPeer(0x1E);
    b.discoverPeer(0x1D);

    try announceWriterNow(a.sedp, &.{
        .guid = makeGuid(0x1D, 0x10),
        .participant_guid = makeGuid(0x1D, 0x01),
        .topic_name = "Both",
        .type_name = "BothT",
        .qos = .{},
        .type_object = &.{},
        .type_info_cdr = &.{},
    });
    try announceReaderNow(b.sedp, &.{
        .guid = makeGuid(0x1E, 0x20),
        .participant_guid = makeGuid(0x1E, 0x01),
        .topic_name = "Both",
        .type_name = "BothT",
        .qos = .{},
        .type_info_cdr = &.{},
    });
    net.deliverAll();
    try testing.expectEqual(@as(usize, 1), b.rec.writers_found.items.len);
    try testing.expectEqual(@as(usize, 1), a.rec.readers_found.items.len);

    SedpEndpoints.onParticipantLost(a.sedp, prefix(0x1E));
    SedpEndpoints.onParticipantLost(b.sedp, prefix(0x1D));
    try testing.expectEqual(@as(usize, 0), a.sedp.pub_writer.?.reader_proxies.items.len);
    try testing.expectEqual(@as(usize, 0), a.sedp.sub_reader.?.writer_proxies.items.len);

    a.discoverPeer(0x1E);
    b.discoverPeer(0x1D);
    // Both sides matched afresh: each replays its history to the other.
    var round: usize = 0;
    while ((a.rec.readers_found.items.len < 2 or b.rec.writers_found.items.len < 2) and round < 10) : (round += 1) {
        net.deliverAll();
        net.deliverAll();
    }
    try testing.expectEqual(@as(usize, 2), b.rec.writers_found.items.len);
    try testing.expectEqual(@as(usize, 2), a.rec.readers_found.items.len);
}

// ── Announcement reservations ─────────────────────────────────────────────────
// docs/design/concurrency/architecture.md#local-endpoint-publication-announcement-and-disposal:
// once prepared, an endpoint's announcement and disposal cannot fail for
// lack of local resources.

/// SEDP on a FailingAllocator, started or not, with no peer.
const Reserving = struct {
    failing: std.testing.FailingAllocator,
    net: *MockNetwork,
    transport: *MockTransport,
    sedp: *SedpEndpoints,
    rec: Recorder,
    cbs: Callbacks,

    fn init(self: *Reserving) !void {
        self.failing = .init(testing.allocator, .{});
        const alloc = self.failing.allocator();
        self.net = try MockNetwork.init(testing.allocator);
        const meta_locs = [_]Locator{Locator.udp4(.{ 127, 0, 0, 0x30 }, metaPort(0x30))};
        self.transport = try MockTransport.init(testing.allocator, self.net, &meta_locs);
        self.sedp = try SedpEndpoints.init(alloc, self.transport.transport());
        self.rec = .{ .alloc = testing.allocator };
        self.cbs = self.rec.callbacks();
    }

    fn start(self: *Reserving) !void {
        const meta_locs = [_]Locator{Locator.udp4(.{ 127, 0, 0, 0x30 }, metaPort(0x30))};
        try self.sedp.start(&.{
            .guid = makeGuid(0x30, 0x01),
            .domain_id = 0,
            .name = "",
            .metatraffic_unicast_locators = &meta_locs,
            .metatraffic_multicast_locators = &.{},
            .default_unicast_locators = &.{},
            .default_multicast_locators = &.{},
            .lease_duration_ms = 10_000,
            .builtin_endpoint_set = ALL_SEDP_ENDPOINTS,
        }, &self.cbs);
    }

    fn deinit(self: *Reserving) void {
        self.sedp.stop();
        self.sedp.deinit();
        self.transport.deinit();
        self.net.deinit();
        self.rec.deinit();
    }

    /// Every allocation from now on fails.
    fn exhaust(self: *Reserving) void {
        self.failing.fail_index = self.failing.alloc_index;
    }

    fn writerAnnouncement(guid: Guid) WriterAnnouncement {
        return .{
            .guid = guid,
            .participant_guid = makeGuid(0x30, 0x01),
            .topic_name = "Reserved",
            .type_name = "ReservedType",
            .qos = .{},
            .partition_names = &.{ "p1", "p2" },
            .type_object = &.{},
            .type_info_cdr = &.{},
        };
    }

    /// The kinds of the publications writer's history, oldest first.
    fn history(self: *Reserving, buf: []history_kind) []history_kind {
        const changes = self.sedp.pub_writer.?.cache.changes.items;
        for (changes, buf[0..changes.len]) |ch, *k| k.* = ch.kind;
        return buf[0..changes.len];
    }
};

const history_kind = zzdds.rtps.history.ChangeKind;

test "SEDP: a prepared writer is announced and disposed with no memory left" {
    var r: Reserving = undefined;
    try r.init();
    defer r.deinit();
    try r.start();

    const guid = makeGuid(0x30, 0x10);
    try r.sedp.prepareWriter(&Reserving.writerAnnouncement(guid));
    r.exhaust();
    var buf: [4]history_kind = undefined;
    r.sedp.announceWriter(guid);
    try testing.expectEqualSlices(history_kind, &.{.alive}, r.history(&buf));
    r.sedp.retractWriter(guid);
    // The disposal replaces the announcement.
    try testing.expectEqualSlices(history_kind, &.{.not_alive_disposed}, r.history(&buf));
}

test "SEDP: a writer prepared before start is reserved by the start" {
    var r: Reserving = undefined;
    try r.init();
    defer r.deinit();

    const a = makeGuid(0x30, 0x11);
    const b = makeGuid(0x30, 0x12);
    try r.sedp.prepareWriter(&Reserving.writerAnnouncement(a));
    try r.sedp.prepareWriter(&Reserving.writerAnnouncement(b));
    try r.start();
    r.exhaust();
    var buf: [4]history_kind = undefined;
    r.sedp.announceWriter(a);
    r.sedp.announceWriter(b);
    try testing.expectEqualSlices(history_kind, &.{ .alive, .alive }, r.history(&buf));
    r.sedp.retractWriter(a);
    r.sedp.retractWriter(b);
    try testing.expectEqualSlices(history_kind, &.{ .not_alive_disposed, .not_alive_disposed }, r.history(&buf));
}

test "SEDP: a writer that cannot be prepared leaves nothing to announce or dispose" {
    var r: Reserving = undefined;
    try r.init();
    defer r.deinit();
    try r.start();

    const guid = makeGuid(0x30, 0x13);
    r.exhaust();
    try testing.expectError(error.OutOfMemory, r.sedp.prepareWriter(&Reserving.writerAnnouncement(guid)));
    r.failing.fail_index = std.math.maxInt(usize);
    var buf: [4]history_kind = undefined;
    r.sedp.announceWriter(guid);
    r.sedp.retractWriter(guid);
    try testing.expectEqual(@as(usize, 0), r.history(&buf).len);
    // Nothing stays reserved: the history's spare room is all that is left.
    try testing.expectEqual(@as(usize, 0), r.sedp.pub_writer.?.cache.reserved);
}

test "SEDP: a writer retracted unannounced gives back its reservation" {
    var r: Reserving = undefined;
    try r.init();
    defer r.deinit();
    try r.start();

    const guid = makeGuid(0x30, 0x14);
    try r.sedp.prepareWriter(&Reserving.writerAnnouncement(guid));
    try testing.expectEqual(@as(usize, 1), r.sedp.pub_writer.?.cache.reserved);
    r.sedp.retractWriter(guid);
    try testing.expectEqual(@as(usize, 0), r.sedp.pub_writer.?.cache.reserved);
    var buf: [4]history_kind = undefined;
    try testing.expectEqual(@as(usize, 0), r.history(&buf).len);
}

test "SEDP: a writer prepared while the plugin is stopped is announced once the next participant starts it" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const meta_locs = [_]Locator{Locator.udp4(.{ 127, 0, 0, 0x31 }, metaPort(0x31))};
    const transport = try MockTransport.init(testing.allocator, net, &meta_locs);
    defer transport.deinit();
    const plugin = try zzdds.combined_discovery.SpdpSedpDiscovery.init(testing.allocator, transport.transport(), 0, 1_000);
    defer plugin.deinit();
    const d = plugin.toDiscovery();
    var rec: Recorder = .{ .alloc = testing.allocator };
    defer rec.deinit();
    const cbs = rec.callbacks();
    var ann: ParticipantAnnouncement = .{
        .guid = makeGuid(0x31, 0x01),
        .domain_id = 0,
        .name = "",
        .metatraffic_unicast_locators = &meta_locs,
        .metatraffic_multicast_locators = &.{},
        .default_unicast_locators = &.{},
        .default_multicast_locators = &.{},
        .lease_duration_ms = 10_000,
        .builtin_endpoint_set = ALL_SEDP_ENDPOINTS,
    };
    try d.start(&ann, &cbs);
    d.stop();

    // The next participant prepares its writer before it starts the plugin,
    // which then gives it new SEDP.
    ann.guid = makeGuid(0x32, 0x01);
    const guid = makeGuid(0x32, 0x10);
    var w = Reserving.writerAnnouncement(guid);
    w.participant_guid = ann.guid;
    try d.prepareWriter(&w);
    try d.start(&ann, &cbs);
    defer d.stop();
    d.announceWriter(guid);
    const changes = plugin.sedp.pub_writer.?.cache.changes.items;
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqual(history_kind.alive, changes[0].kind);
    d.retractWriter(guid);
    try testing.expectEqual(history_kind.not_alive_disposed, plugin.sedp.pub_writer.?.cache.changes.items[0].kind);
}

test "SEDP: a writer prepared again is announced with the replacement only once adopted, with no memory left" {
    var r: Reserving = undefined;
    try r.init();
    defer r.deinit();
    try r.start();

    const guid = makeGuid(0x30, 0x15);
    var ann = Reserving.writerAnnouncement(guid);
    try r.sedp.prepareWriter(&ann);
    r.sedp.announceWriter(guid);
    const first = r.sedp.pub_writer.?.cache.changes.items[0].sequence_number;

    // Held beside the announcement: neither an announce nor an abandon
    // writes it.
    ann.partition_names = &.{"p3"};
    try r.sedp.prepareWriter(&ann);
    r.sedp.announceWriter(guid);
    r.sedp.abandonWriter(guid);
    r.sedp.announceWriter(guid);
    var buf: [4]history_kind = undefined;
    try testing.expectEqualSlices(history_kind, &.{.alive}, r.history(&buf));
    try testing.expect(std.meta.eql(first, r.sedp.pub_writer.?.cache.changes.items[0].sequence_number));

    try r.sedp.prepareWriter(&ann);
    r.exhaust();
    r.sedp.adoptWriter(guid);
    r.sedp.announceWriter(guid);
    // The replacement takes the announcement's slot.
    try testing.expectEqualSlices(history_kind, &.{.alive}, r.history(&buf));
    try testing.expect(!std.meta.eql(first, r.sedp.pub_writer.?.cache.changes.items[0].sequence_number));
    r.sedp.retractWriter(guid);
    try testing.expectEqualSlices(history_kind, &.{.not_alive_disposed}, r.history(&buf));
}
