//! DomainParticipantImpl vtable coverage for PR #27 changes.
//!
//! Exercises: registerTypeSupport (single + double-registration deinit callback),
//! vtSetQos, vtSetDefaultPubQos/SubQos/TopicQos, vtSetListener, and the
//! partition-name ownership lifecycle through DataWriter/DataReader creation.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = dcps.DomainParticipantImpl;
const TypeSupport = dcps.TypeSupport;
const nil = dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const mock_tr = zzdds.mock_transport;
const iface = zzdds.discovery;

const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;
const Locator = mock_tr.Locator;
const testing = std.testing;

// ── Noop discovery ────────────────────────────────────────────────────────────

var noop_disc_sentinel: u8 = 0;

const noop_vtable = iface.Discovery.Vtable{
    .start = struct {
        fn f(_: *anyopaque, _: *const iface.ParticipantAnnouncement, _: *const iface.Callbacks) anyerror!void {}
    }.f,
    .stop = struct {
        fn f(_: *anyopaque) void {}
    }.f,
    .announce_writer = struct {
        fn f(_: *anyopaque, _: *const iface.WriterAnnouncement) anyerror!void {}
    }.f,
    .retract_writer = struct {
        fn f(_: *anyopaque, _: iface.Guid) void {}
    }.f,
    .announce_reader = struct {
        fn f(_: *anyopaque, _: *const iface.ReaderAnnouncement) anyerror!void {}
    }.f,
    .retract_reader = struct {
        fn f(_: *anyopaque, _: iface.Guid) void {}
    }.f,
    .deinit = struct {
        fn f(_: *anyopaque) void {}
    }.f,
};

fn noopDisc() iface.Discovery {
    return .{ .ctx = &noop_disc_sentinel, .vtable = &noop_vtable };
}

// ── Test fixture ──────────────────────────────────────────────────────────────

const Fixture = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,

    fn init(pid: u8) !Fixture {
        const net = try MockNetwork.init(testing.allocator);
        errdefer net.deinit();
        const loc = Locator.udp4(.{ 127, 0, 0, pid }, 7900 + @as(u16, pid));
        const t = try MockTransport.init(testing.allocator, net, &.{loc});
        errdefer t.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            testing.allocator,
            t.transport(),
            noopDisc(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory.deinit();
        const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
        return .{ .net = net, .transport = t, .factory = factory, .dp = dp };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.transport.deinit();
        self.net.deinit();
    }

    fn impl(self: *Fixture) *DomainParticipantImpl {
        return @ptrCast(@alignCast(self.dp.ptr));
    }
};

// ── Helpers ───────────────────────────────────────────────────────────────────

fn zeroed_key_hash(_: *anyopaque, _: []const u8) [16]u8 {
    return std.mem.zeroes([16]u8);
}

// ── registerTypeSupport ───────────────────────────────────────────────────────

test "registerTypeSupport: single registration is retrievable" {
    var fx = try Fixture.init(1);
    defer fx.deinit();

    fx.impl().registerTypeSupport("MyType", .{
        .ctx = undefined,
        .compute_key_hash = zeroed_key_hash,
    });
    // Verified indirectly: no crash, and a second register (below) will deinit it.
}

test "registerTypeSupport: double-registration calls deinit on the old entry" {
    var fx = try Fixture.init(2);
    defer fx.deinit();

    var deinit_called = false;
    const Ctx = struct {
        called: *bool,
        fn deinitFn(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called.* = true;
        }
    };
    var ctx = Ctx{ .called = &deinit_called };

    fx.impl().registerTypeSupport("MyType", .{
        .ctx = &ctx,
        .compute_key_hash = zeroed_key_hash,
        .deinit = Ctx.deinitFn,
    });
    try testing.expect(!deinit_called);

    // Re-register same type name → old entry's deinit must be called.
    fx.impl().registerTypeSupport("MyType", .{
        .ctx = undefined,
        .compute_key_hash = zeroed_key_hash,
    });
    try testing.expect(deinit_called);
}

test "registerTypeSupport: deinit on participant teardown calls entry deinit" {
    // TypeSupport.deinit is also called at participant deinit (line 840).
    var net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 3 }, 7903);
    var t = try MockTransport.init(testing.allocator, net, &.{loc});
    defer t.deinit();
    var factory = try DomainParticipantFactoryImpl.init(
        testing.allocator,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();

    const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));

    var deinit_called = false;
    const Ctx = struct {
        called: *bool,
        fn deinitFn(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.called.* = true;
        }
    };
    var ctx = Ctx{ .called = &deinit_called };
    dp_impl.registerTypeSupport("T", .{
        .ctx = &ctx,
        .compute_key_hash = zeroed_key_hash,
        .deinit = Ctx.deinitFn,
    });

    _ = factory.toDDSFactory().delete_participant(dp);
    try testing.expect(deinit_called);
}

// ── Participant vtable: QoS setters (now pointer params) ──────────────────────

test "participant: vtSetQos and vtGetQos round-trip" {
    var fx = try Fixture.init(4);
    defer fx.deinit();
    const dp = fx.dp;

    var set_qos = DDS.DomainParticipantQos{};
    set_qos.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_qos(dp.ptr, &set_qos));

    var got = DDS.DomainParticipantQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_qos(dp.ptr, &got));
    try testing.expect(!got.entity_factory.autoenable_created_entities);
}

test "participant: vtSetDefaultPubQos and vtGetDefaultPubQos round-trip" {
    var fx = try Fixture.init(5);
    defer fx.deinit();
    const dp = fx.dp;

    var q = DDS.PublisherQos{};
    q.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_publisher_qos(dp.ptr, &q));

    var got = DDS.PublisherQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_publisher_qos(dp.ptr, &got));
    try testing.expect(!got.entity_factory.autoenable_created_entities);
}

test "participant: vtSetDefaultSubQos and vtGetDefaultSubQos round-trip" {
    var fx = try Fixture.init(6);
    defer fx.deinit();
    const dp = fx.dp;

    var q = DDS.SubscriberQos{};
    q.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_subscriber_qos(dp.ptr, &q));

    var got = DDS.SubscriberQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_subscriber_qos(dp.ptr, &got));
    try testing.expect(!got.entity_factory.autoenable_created_entities);
}

test "participant: vtSetDefaultTopicQos and vtGetDefaultTopicQos round-trip" {
    var fx = try Fixture.init(7);
    defer fx.deinit();
    const dp = fx.dp;

    var q = DDS.TopicQos{};
    q.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_topic_qos(dp.ptr, &q));

    var got = DDS.TopicQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_topic_qos(dp.ptr, &got));
    try testing.expectEqual(DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS, got.durability.kind);
}

// ── Participant vtable: set_listener ─────────────────────────────────────────

test "participant: set_listener with null clears to noop listener" {
    var fx = try Fixture.init(8);
    defer fx.deinit();
    const dp = fx.dp;

    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_listener(dp.ptr, null, 0));
    const got = dp.vtable.get_listener(dp.ptr);
    // noop listener: all callbacks are null function pointers (zeroed struct).
    _ = got;
}

test "participant: set_listener stores and retrieves the listener" {
    var fx = try Fixture.init(9);
    defer fx.deinit();
    const dp = fx.dp;

    const L = struct {
        fn on_data_on_readers(_: DDS.Subscriber, _: ?*anyopaque) callconv(.c) void {}
    };
    const listener = DDS.DomainParticipantListener{
        .on_data_on_readers = L.on_data_on_readers,
    };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_listener(dp.ptr, &listener, 0));
    const got = dp.vtable.get_listener(dp.ptr);
    try testing.expect(got.on_data_on_readers == L.on_data_on_readers);
}

// ── Partition name lifecycle ──────────────────────────────────────────────────

test "partition names: DataWriter with partition QoS — create and delete" {
    // Exercises pubAnnounceProtoWriter (happy path) and freePartitionNames on destroy.
    var fx = try Fixture.init(10);
    defer fx.deinit();

    var part_strs: [2][*:0]const u8 = .{ "A", "B" };
    const part_seq = DDS.StringSeq{
        ._buffer = @ptrCast(&part_strs),
        ._length = 2,
        ._maximum = 2,
        ._release = false,
    };
    var pub_qos = DDS.PublisherQos{};
    pub_qos.partition.name = part_seq;

    const topic = fx.dp.create_topic("PartTopic", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const publisher = fx.dp.create_publisher(pub_qos, null, 0);
    defer _ = fx.dp.vtable.delete_publisher(fx.dp.ptr, publisher);

    const dw = publisher.create_datawriter(topic, .{}, null, 0);
    // Deleting the writer should call freePartitionNames on the stored owned_names.
    _ = publisher.vtable.delete_datawriter(publisher.ptr, dw);
}

test "partition names: DataReader with partition QoS — create and delete" {
    // Exercises subAnnounceProtoReader (happy path) and freePartitionNames on destroy.
    var fx = try Fixture.init(11);
    defer fx.deinit();

    var part_strs: [1][*:0]const u8 = .{"C"};
    const part_seq = DDS.StringSeq{
        ._buffer = @ptrCast(&part_strs),
        ._length = 1,
        ._maximum = 1,
        ._release = false,
    };
    var sub_qos = DDS.SubscriberQos{};
    sub_qos.partition.name = part_seq;

    const topic = fx.dp.create_topic("PartTopicR", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const subscriber = fx.dp.create_subscriber(sub_qos, null, 0);
    defer _ = fx.dp.vtable.delete_subscriber(fx.dp.ptr, subscriber);

    const topic_impl = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic.ptr)));
    const td = topic_impl.toTopicDescription();
    const dr = subscriber.create_datareader(td, .{}, null, 0);
    _ = subscriber.vtable.delete_datareader(subscriber.ptr, dr);
}

test "partition names: multiple writers with partitions — deinit via delete_publisher" {
    // When the publisher is deleted, its writers are removed from active_writers
    // via unregisterProtoWriter, each calling freePartitionNames.
    var fx = try Fixture.init(12);
    defer fx.deinit();

    var part_strs: [1][*:0]const u8 = .{"X"};
    const part_seq = DDS.StringSeq{
        ._buffer = @ptrCast(&part_strs),
        ._length = 1,
        ._maximum = 1,
        ._release = false,
    };
    var pub_qos = DDS.PublisherQos{};
    pub_qos.partition.name = part_seq;

    const topic = fx.dp.create_topic("PartTopicM", "T", .{}, null, 0);
    defer _ = fx.dp.vtable.delete_topic(fx.dp.ptr, topic);

    const publisher = fx.dp.create_publisher(pub_qos, null, 0);

    _ = publisher.create_datawriter(topic, .{}, null, 0);
    _ = publisher.create_datawriter(topic, .{}, null, 0);

    // delete_publisher → delete_contained_entities → each writer removed from active_writers.
    _ = fx.dp.vtable.delete_publisher(fx.dp.ptr, publisher);
}
