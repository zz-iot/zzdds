//! Unit tests for DDS §2.2.2.2.1.28 ignore_participant() and related stubs.
//!
//! Tests inject discovery events directly via disc_callbacks so no real UDP
//! sockets or background threads are needed.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const iface = zzdds.discovery;
const mock_tr = zzdds.mock_transport;
const noop_security = zzdds.noop_security.noop_security_plugins;

const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = dcps.DomainParticipantImpl;
const DataReaderImpl = dcps.DataReaderImpl;
const TopicImpl = dcps.TopicImpl;
const guidToHandle = dcps.guidToHandle;
const nil = dcps;

const Discovery = iface.Discovery;
const Callbacks = iface.Callbacks;
const Guid = iface.Guid;
const GuidPrefix = zzdds.rtps.GuidPrefix;
const EntityIds = zzdds.rtps.EntityIds;
const Locator = mock_tr.Locator;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;

const testing = std.testing;

// ── Noop discovery that captures its Callbacks pointer ───────────────────────

const CapturingDisc = struct {
    callbacks: ?*const Callbacks = null,

    const vtable = Discovery.Vtable{
        .start = start,
        .stop = stop,
        .announce_writer = noopAW,
        .retract_writer = noopRW,
        .announce_reader = noopAR,
        .retract_reader = noopRR,
        .deinit = noopDeinit,
    };

    fn start(ctx: *anyopaque, _: *const iface.ParticipantAnnouncement, cbs: *const Callbacks) anyerror!void {
        const self: *CapturingDisc = @ptrCast(@alignCast(ctx));
        self.callbacks = cbs;
    }
    fn stop(_: *anyopaque) void {}
    fn noopAW(_: *anyopaque, _: *const iface.WriterAnnouncement) anyerror!void {}
    fn noopRW(_: *anyopaque, _: Guid) void {}
    fn noopAR(_: *anyopaque, _: *const iface.ReaderAnnouncement) anyerror!void {}
    fn noopRR(_: *anyopaque, _: Guid) void {}
    fn noopDeinit(_: *anyopaque) void {}

    fn toDiscovery(self: *CapturingDisc) Discovery {
        return .{ .ctx = self, .vtable = &vtable };
    }
};

// ── Harness ───────────────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,
    disc: CapturingDisc,

    fn init() !Harness {
        var h: Harness = undefined;
        h.disc = .{};
        const alloc = testing.allocator;
        h.net = try MockNetwork.init(alloc);
        errdefer h.net.deinit();
        h.transport = try MockTransport.init(alloc, h.net, &.{Locator.udp4(.{ 127, 0, 0, 1 }, 7410)});
        errdefer h.transport.deinit();
        h.factory = try DomainParticipantFactoryImpl.init(
            alloc,
            h.transport.transport(),
            h.disc.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        return h;
    }

    fn deinit(self: *Harness) void {
        self.factory.deinit();
        self.transport.deinit();
        self.net.deinit();
    }

    /// Fire on_participant_discovered for a fake remote participant with the
    /// given GUID prefix.
    fn fireParticipantDiscovered(_: *Harness, dp_impl: *DomainParticipantImpl, prefix: GuidPrefix) void {
        const remote_guid = Guid{ .prefix = prefix, .entity_id = EntityIds.participant };
        const data = iface.ParticipantData{
            .guid = remote_guid,
            .domain_id = 0,
            .name = "",
            .metatraffic_unicast_locators = &.{},
            .metatraffic_multicast_locators = &.{},
            .default_unicast_locators = &.{},
            .default_multicast_locators = &.{},
            .lease_duration_ms = 10_000,
            .builtin_endpoint_set = 0,
            .vendor_id = .{ .bytes = .{ 0x00, 0x00 } },
        };
        dp_impl.disc_callbacks.on_participant_discovered(dp_impl.disc_callbacks.ctx, &data);
    }

    /// Fire on_writer_discovered for a fake remote writer with the given GUID prefix.
    fn fireWriterDiscovered(
        _: *Harness,
        dp_impl: *DomainParticipantImpl,
        prefix: GuidPrefix,
        topic: []const u8,
        type_name: []const u8,
    ) void {
        const writer_guid = Guid{
            .prefix = prefix,
            .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x02 },
        };
        const data = iface.WriterData{
            .guid = writer_guid,
            .participant_guid = Guid{ .prefix = prefix, .entity_id = EntityIds.participant },
            .topic_name = topic,
            .type_name = type_name,
            .qos = .{ .reliability_kind = 1 },
            .unicast_locators = &.{},
            .multicast_locators = &.{},
            .type_object = &.{},
        };
        dp_impl.disc_callbacks.on_writer_discovered(dp_impl.disc_callbacks.ctx, &data);
    }

    /// Fire on_reader_discovered for a fake remote reader with the given GUID prefix.
    fn fireReaderDiscovered(
        _: *Harness,
        dp_impl: *DomainParticipantImpl,
        prefix: GuidPrefix,
        topic: []const u8,
        type_name: []const u8,
    ) void {
        const reader_guid = Guid{
            .prefix = prefix,
            .entity_id = .{ .entity_key = .{ 0, 0, 4 }, .entity_kind = 0x07 },
        };
        const data = iface.ReaderData{
            .guid = reader_guid,
            .participant_guid = Guid{ .prefix = prefix, .entity_id = EntityIds.participant },
            .topic_name = topic,
            .type_name = type_name,
            .qos = .{ .reliability_kind = 1 },
            .unicast_locators = &.{},
            .multicast_locators = &.{},
        };
        dp_impl.disc_callbacks.on_reader_discovered(dp_impl.disc_callbacks.ctx, &data);
    }
};

fn makePrefix(seed: u8) GuidPrefix {
    return .{ .bytes = .{seed} ** 12 };
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "ignore_participant: removes from discovered cache" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    const prefix = makePrefix(0xAA);

    // Discover the remote participant.
    h.fireParticipantDiscovered(dp_impl, prefix);

    // Should appear in the cache.
    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._length]);
    };
    _ = dp.vtable.get_discovered_participants(dp.ptr, &handles);
    try testing.expectEqual(@as(u32, 1), handles._length);
    const handle = handles._buffer.?[0];

    // Ignoring it must remove it and return OK.
    const rc = dp.vtable.ignore_participant(dp.ptr, handle);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    // Cache should be empty now.
    if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._length]);
    }
    handles = .{};
    _ = dp.vtable.get_discovered_participants(dp.ptr, &handles);
    try testing.expectEqual(@as(u32, 0), handles._length);
}

test "ignore_participant: blocks future announcements from same prefix" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    const prefix = makePrefix(0xBB);

    // Discover, ignore.
    h.fireParticipantDiscovered(dp_impl, prefix);
    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._length]);
    };
    _ = dp.vtable.get_discovered_participants(dp.ptr, &handles);
    _ = dp.vtable.ignore_participant(dp.ptr, handles._buffer.?[0]);

    // Re-announce from the same prefix — must stay out of the cache.
    h.fireParticipantDiscovered(dp_impl, prefix);
    if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._length]);
    }
    handles = .{};
    _ = dp.vtable.get_discovered_participants(dp.ptr, &handles);
    try testing.expectEqual(@as(u32, 0), handles._length);
}

test "ignore_participant: bad handle returns RETCODE_BAD_PARAMETER" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const rc = dp.vtable.ignore_participant(dp.ptr, 0x7FFF_FFFF);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
}

test "ignore_participant: writer from ignored prefix not matched" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    // Create a DataReader for "TestTopic".
    const sub = dp.create_subscriber(.{}, null, 0);
    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    const topic_desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = sub.create_datareader(topic_desc, dr_qos, null, 0);
    defer _ = dp.vtable.delete_contained_entities(dp.ptr);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    const prefix = makePrefix(0xCC);

    // Discover and ignore the participant.
    h.fireParticipantDiscovered(dp_impl, prefix);
    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._length]);
    };
    _ = dp.vtable.get_discovered_participants(dp.ptr, &handles);
    _ = dp.vtable.ignore_participant(dp.ptr, handles._buffer.?[0]);

    // Fire on_writer_discovered for an endpoint from the ignored prefix.
    h.fireWriterDiscovered(dp_impl, prefix, "TestTopic", "TestType");

    // The reader must have zero matched writers.
    try testing.expectEqual(@as(usize, 0), dr_impl.matchedWriterCount());
}

test "ignore_participant: reader from ignored prefix not matched to writer" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    // Create a DataWriter for "TestTopic".
    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("TestTopic", "TestType", .{}, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = pub_.create_datawriter(topic, dw_qos, null, 0);
    defer _ = dp.vtable.delete_contained_entities(dp.ptr);
    const dw_impl: *dcps.DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    const prefix = makePrefix(0xDD);

    // Discover and ignore the participant.
    h.fireParticipantDiscovered(dp_impl, prefix);
    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| testing.allocator.free(b[0..handles._length]);
    };
    _ = dp.vtable.get_discovered_participants(dp.ptr, &handles);
    _ = dp.vtable.ignore_participant(dp.ptr, handles._buffer.?[0]);

    // Fire on_reader_discovered for an endpoint from the ignored prefix.
    h.fireReaderDiscovered(dp_impl, prefix, "TestTopic", "TestType");

    // The writer must have zero matched readers.
    try testing.expectEqual(@as(usize, 0), dw_impl.matchedReaderCount());
}

test "ignore_topic: bad handle returns BAD_PARAMETER" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, dp.vtable.ignore_topic(dp.ptr, 0x7FFF_FFFF));
}

test "ignore_topic: writer for ignored topic not matched to reader" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const sub = dp.create_subscriber(.{}, null, 0);
    const topic = dp.create_topic("IgnoredTopic", "T", .{}, null, 0);
    const topic_handle = topic.vtable.get_instance_handle(topic.ptr);
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = sub.create_datareader(
        @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription(),
        dr_qos,
        null,
        0,
    );
    defer _ = dp.vtable.delete_contained_entities(dp.ptr);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_topic(dp.ptr, topic_handle));
    h.fireWriterDiscovered(dp_impl, makePrefix(0xE0), "IgnoredTopic", "T");
    try testing.expectEqual(@as(usize, 0), dr_impl.matchedWriterCount());
}

test "ignore_topic: reader for ignored topic not matched to writer" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("IgnoredTopic", "T", .{}, null, 0);
    const topic_handle = topic.vtable.get_instance_handle(topic.ptr);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = pub_.create_datawriter(topic, dw_qos, null, 0);
    defer _ = dp.vtable.delete_contained_entities(dp.ptr);
    const dw_impl: *dcps.DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_topic(dp.ptr, topic_handle));
    h.fireReaderDiscovered(dp_impl, makePrefix(0xE1), "IgnoredTopic", "T");
    try testing.expectEqual(@as(usize, 0), dw_impl.matchedReaderCount());
}

test "ignore_publication: ignored writer not matched to reader" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const sub = dp.create_subscriber(.{}, null, 0);
    const topic = dp.create_topic("PubTopic", "T", .{}, null, 0);
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = sub.create_datareader(
        @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription(),
        dr_qos,
        null,
        0,
    );
    defer _ = dp.vtable.delete_contained_entities(dp.ptr);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    // Pre-compute the handle for the writer we will fire.
    const prefix = makePrefix(0xE2);
    const writer_guid = Guid{
        .prefix = prefix,
        .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x02 },
    };
    const pub_handle = guidToHandle(writer_guid);

    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_publication(dp.ptr, pub_handle));
    h.fireWriterDiscovered(dp_impl, prefix, "PubTopic", "T");
    try testing.expectEqual(@as(usize, 0), dr_impl.matchedWriterCount());
}

test "ignore_subscription: ignored reader not matched to writer" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("SubTopic", "T", .{}, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = pub_.create_datawriter(topic, dw_qos, null, 0);
    defer _ = dp.vtable.delete_contained_entities(dp.ptr);
    const dw_impl: *dcps.DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    // Pre-compute the handle for the reader we will fire.
    const prefix = makePrefix(0xE3);
    const reader_guid = Guid{
        .prefix = prefix,
        .entity_id = .{ .entity_key = .{ 0, 0, 4 }, .entity_kind = 0x07 },
    };
    const sub_handle = guidToHandle(reader_guid);

    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_subscription(dp.ptr, sub_handle));
    h.fireReaderDiscovered(dp_impl, prefix, "SubTopic", "T");
    try testing.expectEqual(@as(usize, 0), dw_impl.matchedReaderCount());
}

test "ignore_publication/subscription: duplicate call is idempotent" {
    var h = try Harness.init();
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_publication(dp.ptr, 42));
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_publication(dp.ptr, 42));
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_subscription(dp.ptr, 42));
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.ignore_subscription(dp.ptr, 42));
}
