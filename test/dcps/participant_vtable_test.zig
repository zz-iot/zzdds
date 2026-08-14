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
const config_mod = zzdds.config;
const noop_security = zzdds.noop_security.noop_security_plugins;
const mock_tr = zzdds.mock_transport;
const iface = zzdds.discovery;
const time_mod = zzdds.util.time;

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

    _ = fx.impl().registerTypeSupport("MyType", .{
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

    _ = fx.impl().registerTypeSupport("MyType", .{
        .ctx = &ctx,
        .compute_key_hash = zeroed_key_hash,
        .deinit = Ctx.deinitFn,
    });
    try testing.expect(!deinit_called);

    // Re-register same type name → old entry's deinit must be called.
    _ = fx.impl().registerTypeSupport("MyType", .{
        .ctx = undefined,
        .compute_key_hash = zeroed_key_hash,
    });
    try testing.expect(deinit_called);
}

test "registerTypeSupport: replacement refreshes an active reader's cached get_field getter (not just key_hash)" {
    // Regression test: a DataReader caches the get_field getter (and, if
    // created against a ContentFilteredTopic, its cft_filter's copy too)
    // once at creation time. Re-registering TypeSupport for the same type
    // used to free the old ctx and refresh only ActiveReader's key_hash
    // fields -- the reader's own cached getters kept pointing at the freed
    // ctx until a new reader/filter happened to be created, and a CFT/
    // QueryCondition evaluation in between would dereference freed memory.
    var fx = try Fixture.init(4);
    defer fx.deinit();

    // Not zero-sized: Zig doesn't guarantee distinct addresses for
    // zero-sized types (`struct {}`), which would make the pointer-identity
    // assertions below vacuously true regardless of whether the refresh
    // actually happened -- found live, while verifying this test actually
    // catches the bug it's meant to catch.
    const CtxA = struct { tag: u8 = 0xAA };
    const CtxB = struct { tag: u8 = 0xBB };
    var ctx_a = CtxA{};
    var ctx_b = CtxB{};

    const getFieldA = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) ?zzdds.dcps.filter.FilterValue {
            return .{ .int = 1 };
        }
    }.f;
    const getFieldB = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8, _: []u8) ?zzdds.dcps.filter.FilterValue {
            return .{ .int = 2 };
        }
    }.f;

    _ = fx.impl().registerTypeSupport("CftType", .{
        .ctx = &ctx_a,
        .compute_key_hash = zeroed_key_hash,
        .get_field = getFieldA,
    });

    const topic = fx.dp.create_topic("CftTopic", "CftType", .{}, null, 0);
    const cft = fx.dp.create_contentfilteredtopic("CftAlias", topic, "x = 1", &DDS.StringSeq{});
    const sub = fx.dp.create_subscriber(.{}, null, 0);
    const cft_impl: *zzdds.dcps.ContentFilteredTopicImpl = @ptrCast(@alignCast(cft.ptr));
    const dr = sub.create_datareader(cft_impl.toTopicDescription(), .{}, null, 0);
    const dr_impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    try testing.expect(dr_impl.get_field_fn != null);
    try testing.expectEqual(@as(*anyopaque, &ctx_a), dr_impl.get_field_fn.?.ctx);
    try testing.expect(dr_impl.cft_filter != null);
    try testing.expectEqual(@as(*anyopaque, &ctx_a), dr_impl.cft_filter.?.get_field_fn.ctx);

    // Re-register the same type with a different ctx/getter -- simulates
    // e.g. a Java caller replacing its TypeSupport registration.
    _ = fx.impl().registerTypeSupport("CftType", .{
        .ctx = &ctx_b,
        .compute_key_hash = zeroed_key_hash,
        .get_field = getFieldB,
    });

    // Both of the reader's cached copies must now point at the new ctx --
    // not the freed old one.
    try testing.expect(dr_impl.get_field_fn != null);
    try testing.expectEqual(@as(*anyopaque, &ctx_b), dr_impl.get_field_fn.?.ctx);
    try testing.expect(dr_impl.cft_filter != null);
    try testing.expectEqual(@as(*anyopaque, &ctx_b), dr_impl.cft_filter.?.get_field_fn.ctx);
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
    _ = dp_impl.registerTypeSupport("T", .{
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
        fn on_data_on_readers(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {}
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

// ── Heap-QoS round-trip tests ─────────────────────────────────────────────────
// These tests verify clone+deinit correctness by using QoS values with
// heap-owning fields. testing.allocator detects any leak or double-free.
//
// Pattern: pass QoS with _release=false (stack-backed, no heap to manage on
// our end). set_qos clones into _release=true internally. A second set_qos must
// deinit the first clone. get_qos returns a new clone that we own and deinit.

test "participant: set_qos with user_data — clone survives replacement" {
    var fx = try Fixture.init(0x80);
    defer fx.deinit();
    const dp = fx.dp;

    var data = [_]u8{0x01};
    var q1 = DDS.DomainParticipantQos{};
    q1.user_data.value = .{ ._buffer = &data, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_qos(dp.ptr, &q1));

    var data2 = [_]u8{0x02};
    var q2 = DDS.DomainParticipantQos{};
    q2.user_data.value = .{ ._buffer = &data2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_qos(dp.ptr, &q2));

    var got = DDS.DomainParticipantQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_qos(dp.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(testing.allocator);
}

test "participant: set_default_publisher_qos with partition names — clone survives replacement" {
    var fx = try Fixture.init(0x81);
    defer fx.deinit();
    const dp = fx.dp;

    var n1 = [1][*:0]const u8{"part_a"};
    var q1 = DDS.PublisherQos{};
    q1.partition.name = .{ ._buffer = &n1, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_publisher_qos(dp.ptr, &q1));

    var n2 = [1][*:0]const u8{"part_b"};
    var q2 = DDS.PublisherQos{};
    q2.partition.name = .{ ._buffer = &n2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_publisher_qos(dp.ptr, &q2));

    var got = DDS.PublisherQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_publisher_qos(dp.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.partition.name._length);
    got.deinit(testing.allocator);
}

test "participant: set_default_subscriber_qos with partition names — clone survives replacement" {
    var fx = try Fixture.init(0x82);
    defer fx.deinit();
    const dp = fx.dp;

    var n1 = [1][*:0]const u8{"sub_part_a"};
    var q1 = DDS.SubscriberQos{};
    q1.partition.name = .{ ._buffer = &n1, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_subscriber_qos(dp.ptr, &q1));

    var n2 = [1][*:0]const u8{"sub_part_b"};
    var q2 = DDS.SubscriberQos{};
    q2.partition.name = .{ ._buffer = &n2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_subscriber_qos(dp.ptr, &q2));

    var got = DDS.SubscriberQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_subscriber_qos(dp.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.partition.name._length);
    got.deinit(testing.allocator);
}

test "participant: set_default_topic_qos with topic_data — clone survives replacement" {
    var fx = try Fixture.init(0x83);
    defer fx.deinit();
    const dp = fx.dp;

    var d1 = [_]u8{0xAB};
    var q1 = DDS.TopicQos{};
    q1.topic_data.value = .{ ._buffer = &d1, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_topic_qos(dp.ptr, &q1));

    var d2 = [_]u8{0xCD};
    var q2 = DDS.TopicQos{};
    q2.topic_data.value = .{ ._buffer = &d2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.set_default_topic_qos(dp.ptr, &q2));

    var got = DDS.TopicQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_topic_qos(dp.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.topic_data.value._length);
    got.deinit(testing.allocator);
}

test "participant: get_qos returns independent clone — internal replacement does not dangle" {
    var fx = try Fixture.init(0x84);
    defer fx.deinit();
    const dp = fx.dp;

    var data = [_]u8{0xFF};
    var q = DDS.DomainParticipantQos{};
    q.user_data.value = .{ ._buffer = &data, ._length = 1, ._maximum = 1, ._release = false };
    _ = dp.vtable.set_qos(dp.ptr, &q);

    // Capture a clone from get_qos.
    var got = DDS.DomainParticipantQos{};
    _ = dp.vtable.get_qos(dp.ptr, &got);

    // Replace the internal copy — a shallow get would leave `got` dangling.
    var data2 = [_]u8{0x00};
    var q2 = DDS.DomainParticipantQos{};
    q2.user_data.value = .{ ._buffer = &data2, ._length = 1, ._maximum = 1, ._release = false };
    _ = dp.vtable.set_qos(dp.ptr, &q2);

    // `got` must still be valid (it's a clone, not a view into the internal copy).
    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(testing.allocator);
}

// ── TCP data transport: bind_address validation ───────────────────────────────

test "createParticipantWithConfig: TCP enabled with empty bind_address fails cleanly, not silently" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 0x90 }, 7990);
    const t = try MockTransport.init(testing.allocator, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        testing.allocator,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();

    var config = config_mod.Config{};
    config.transport.tcp.enabled = true;
    // bind_address left at its default (""), the scenario under test — no
    // concrete address configured for the TCP data transport to advertise.

    const qos = DDS.DomainParticipantQos{};
    const dp = factory.createParticipantWithConfig(0, &qos, null, 0, config);
    defer {
        if (dp.ptr != nil.NIL_PTR) _ = factory.toDDSFactory().delete_participant(dp);
    }

    // A wildcard (0.0.0.0) locator is not something a remote peer can connect
    // to. Construction must fail outright here, not silently bind/advertise
    // the wildcard and leave discovery working while data delivery is broken.
    try testing.expect(dp.ptr == nil.NIL_PTR);
}

test "createParticipantWithConfig: TCP enabled with a concrete bind_address succeeds and binds a real port" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 0x91 }, 7991);
    const t = try MockTransport.init(testing.allocator, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        testing.allocator,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();

    var config = config_mod.Config{};
    config.transport.tcp.enabled = true;
    config.transport.tcp.bind_address = "127.0.0.1";

    const qos = DDS.DomainParticipantQos{};
    const dp = factory.createParticipantWithConfig(0, &qos, null, 0, config);
    defer {
        if (dp.ptr != nil.NIL_PTR) _ = factory.toDDSFactory().delete_participant(dp);
    }

    // Unlike the empty-bind_address case, a concrete address is something a
    // remote peer really can connect to — construction must succeed, and the
    // TCP branch must have actually bound a real (OS-assigned) port rather
    // than leaving data_listen_port at its zero-value default.
    try testing.expect(dp.ptr != nil.NIL_PTR);
    const impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    try testing.expect(impl.data_listen_port != 0);
}

// ── config.qos (QosDefaults) actually reaching real entities ──────────────────
//
// Regression test for the gap docs/design/shape-reference-app.md flagged:
// config.qos was resolved from TOML by toRuntimeConfig but never read again by
// any entity-creation path. get_default_{topic,datawriter,datareader}_qos()
// is the one spot an application can observe it (create_topic/
// create_datawriter/create_datareader all take a caller-supplied literal QoS
// here — there's no QOS_DEFAULT-style sentinel to special-case).

test "createParticipantWithConfig: config.qos seeds default_topic_qos" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 0x92 }, 7992);
    const t = try MockTransport.init(testing.allocator, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        testing.allocator,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();

    var config = config_mod.Config{};
    config.qos = .{
        .reliability_kind = .reliable,
        .durability_kind = .transient_local,
        .history_kind = .keep_all,
        .history_depth = 8,
    };

    const qos = DDS.DomainParticipantQos{};
    const dp = factory.createParticipantWithConfig(0, &qos, null, 0, config);
    defer {
        if (dp.ptr != nil.NIL_PTR) _ = factory.toDDSFactory().delete_participant(dp);
    }
    try testing.expect(dp.ptr != nil.NIL_PTR);

    var got = DDS.TopicQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_default_topic_qos(dp.ptr, &got));
    try testing.expectEqual(DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS, got.reliability.kind);
    try testing.expectEqual(DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS, got.durability.kind);
    try testing.expectEqual(DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS, got.history.kind);
    try testing.expectEqual(@as(i32, 8), got.history.depth);
}

test "createParticipantWithConfig: config.qos seeds Publisher's default_datawriter_qos and Subscriber's default_datareader_qos" {
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 0x93 }, 7993);
    const t = try MockTransport.init(testing.allocator, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        testing.allocator,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();

    var config = config_mod.Config{};
    config.qos = .{
        .reliability_kind = .reliable,
        .durability_kind = .persistent,
        .history_kind = .keep_all,
        .history_depth = 4,
    };

    const qos = DDS.DomainParticipantQos{};
    const dp = factory.createParticipantWithConfig(0, &qos, null, 0, config);
    defer {
        if (dp.ptr != nil.NIL_PTR) _ = factory.toDDSFactory().delete_participant(dp);
    }
    try testing.expect(dp.ptr != nil.NIL_PTR);

    const publisher = dp.create_publisher(.{}, null, 0);
    defer _ = dp.vtable.delete_publisher(dp.ptr, publisher);
    var dw_qos = DDS.DataWriterQos{};
    try testing.expectEqual(DDS.RETCODE_OK, publisher.vtable.get_default_datawriter_qos(publisher.ptr, &dw_qos));
    try testing.expectEqual(DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS, dw_qos.reliability.kind);
    try testing.expectEqual(DDS.DurabilityQosPolicyKind.PERSISTENT_DURABILITY_QOS, dw_qos.durability.kind);
    try testing.expectEqual(DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS, dw_qos.history.kind);
    try testing.expectEqual(@as(i32, 4), dw_qos.history.depth);

    const subscriber = dp.create_subscriber(.{}, null, 0);
    defer _ = dp.vtable.delete_subscriber(dp.ptr, subscriber);
    var dr_qos = DDS.DataReaderQos{};
    try testing.expectEqual(DDS.RETCODE_OK, subscriber.vtable.get_default_datareader_qos(subscriber.ptr, &dr_qos));
    try testing.expectEqual(DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS, dr_qos.reliability.kind);
    try testing.expectEqual(DDS.DurabilityQosPolicyKind.PERSISTENT_DURABILITY_QOS, dr_qos.durability.kind);
    try testing.expectEqual(DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS, dr_qos.history.kind);
    try testing.expectEqual(@as(i32, 4), dr_qos.history.depth);
}

// ── deinit() reentrancy from the timer thread ───────────────────────────────

const SelfDeleteCtx = struct {
    // Set (release) by the main thread only once every field below has been
    // populated; the callback checks it (acquire) before touching any of
    // them. Without this, there's no happens-before edge between the main
    // thread's plain (non-atomic) `ctx.dw = dw;` etc. and the timer thread
    // potentially reading them the instant the deadline fires -- a genuine
    // data race per the memory model even though the real timing (deadline
    // period 50ms vs. this setup taking microseconds) makes it practically
    // unhittable (confirmed via TSan).
    ready: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    caller_thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
    factory: DDS.DomainParticipantFactory,
    dp: DDS.DomainParticipant,
    pub_: DDS.Publisher,
    dw: DDS.DataWriter,
    topic: DDS.Topic,
};

fn selfDeleteOnDeadlineMissed(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    const ctx: *SelfDeleteCtx = @ptrCast(@alignCast(ld));
    if (!ctx.ready.load(.acquire)) return; // too early: ctx isn't fully populated yet
    if (ctx.fired.swap(true, .acq_rel)) return; // one shot: everything below is gone after the first firing
    ctx.caller_thread_id.store(std.Thread.getCurrentId(), .release);
    // Spec-legal, if unusual: reentrantly tear down the entire entity graph
    // -- including the participant itself -- from inside a DEADLINE listener
    // callback fired by the participant's own timer thread.
    _ = ctx.pub_.delete_datawriter(ctx.dw);
    _ = ctx.dp.delete_publisher(ctx.pub_);
    _ = ctx.dp.delete_topic(ctx.topic);
    _ = ctx.factory.delete_participant(ctx.dp);
    ctx.done.store(true, .release);
}

test "deinit: reentrant delete_participant from a timer-driven listener does not self-deadlock or use-after-free" {
    // checkTimers() runs on the participant's own background timer thread
    // and may fire a DEADLINE-missed listener. DDS listeners are spec-legal
    // to reentrantly delete every entity -- including the participant
    // itself -- from inside that callback, which makes delete_participant()
    // -> deinit() run FROM the timer thread deinit() is trying to stop:
    // joining that thread from itself would deadlock, and freeing the
    // participant struct while checkTimers()/timerThreadFn are still
    // executing further up that same call stack would be a use-after-free
    // (see deinit()'s and timerThreadFn's doc comments). This needs a real
    // background thread and real wall-clock time -- ManualClock only ever
    // advances from the calling test thread, so it can never reach this
    // scenario -- audited in check_test_sleeps.py's allowlist alongside
    // this codebase's other real-thread tests.
    const net = try MockNetwork.init(testing.allocator);
    defer net.deinit();
    const loc = Locator.udp4(.{ 127, 0, 0, 0x94 }, 7994);
    const t = try MockTransport.init(testing.allocator, net, &.{loc});
    defer t.deinit();
    const factory = try DomainParticipantFactoryImpl.init(
        testing.allocator,
        t.transport(),
        noopDisc(),
        noop_security,
        .spec_random,
        .{},
    );
    defer factory.deinit();
    const dpf = factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    try testing.expect(dp.ptr != nil.NIL_PTR);

    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("SelfDeleteTopic", "SelfDeleteType", .{}, null, 0);

    var ctx = SelfDeleteCtx{
        .factory = dpf,
        .dp = dp,
        .pub_ = pub_,
        .dw = undefined,
        .topic = topic,
    };
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.deadline.period = .{ .sec = 0, .nanosec = 50_000_000 }; // 50 ms: well under TIMER_CHECK_INTERVAL_MS's 100ms poll granularity's headroom for a prompt first firing
    const dw = pub_.create_datawriter(topic, dw_qos, DDS.DataWriterListener{
        .listener_data = &ctx,
        .on_offered_deadline_missed = selfDeleteOnDeadlineMissed,
    }, DDS.OFFERED_DEADLINE_MISSED_STATUS);
    ctx.dw = dw;
    ctx.ready.store(true, .release);

    const test_thread_id = std.Thread.getCurrentId();
    const deadline_ns = time_mod.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (!ctx.done.load(.acquire)) {
        if (time_mod.nanoTimestamp() >= deadline_ns) {
            try testing.expect(false); // timed out: the fix regressed (self-join deadlock)
            return;
        }
        time_mod.sleepNs(20 * std.time.ns_per_ms);
    }

    // Confirms this genuinely exercised the timer-thread path, not just a
    // same-thread synchronous call (which wouldn't hit self-join/self-free
    // at all).
    try testing.expect(ctx.caller_thread_id.load(.acquire) != test_thread_id);
}
