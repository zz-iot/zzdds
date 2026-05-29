//! DCPS API unit tests.
//!
//! Tests Participant/Publisher/Subscriber/DataWriter/DataReader lifecycle,
//! Topic create/delete, WaitSet + GuardCondition trigger behavior, and
//! StatusCondition.
//!
//! Uses noop discovery and MockTransport so no real UDP sockets or background
//! threads are needed.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const iface = zzdds.discovery;
const mock_tr = zzdds.mock_transport;
const noop_security = zzdds.noop_security.noop_security_plugins;
const time_mod = zzdds.util.time;

const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = dcps.DomainParticipantImpl;
const DataReaderImpl = dcps.DataReaderImpl;
const WaitSetImpl = dcps.WaitSetImpl;
const GuardConditionImpl = dcps.GuardConditionImpl;
const nil = dcps;

const Callbacks = iface.Callbacks;
const WriterAnnouncement = iface.WriterAnnouncement;
const ReaderAnnouncement = iface.ReaderAnnouncement;
const Discovery = iface.Discovery;
const Guid = iface.Guid;
const GuidPrefix = zzdds.rtps.GuidPrefix;
const EntityIds = zzdds.rtps.EntityIds;
const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;
const Locator = mock_tr.Locator;

const testing = std.testing;

const RETCODE_OK: DDS.ReturnCode_t = DDS.RETCODE_OK;
const RETCODE_PRECONDITION: DDS.ReturnCode_t = DDS.RETCODE_PRECONDITION_NOT_MET;
const RETCODE_TIMEOUT: DDS.ReturnCode_t = DDS.RETCODE_TIMEOUT;
const DURATION_ZERO: DDS.Duration_t = .{ .sec = 0, .nanosec = 0 };

// ── Noop discovery ────────────────────────────────────────────────────────────

var noop_disc_sentinel: u8 = 0;

const noop_disc_vtable = iface.Discovery.Vtable{
    .start = noopDiscStart,
    .stop = noopDiscStop,
    .announce_writer = noopDiscAnnounceWriter,
    .retract_writer = noopDiscRetractWriter,
    .announce_reader = noopDiscAnnounceReader,
    .retract_reader = noopDiscRetractReader,
    .deinit = noopDiscDeinit,
};

fn noopDiscStart(_: *anyopaque, _: *const iface.ParticipantAnnouncement, _: *const Callbacks) anyerror!void {}
fn noopDiscStop(_: *anyopaque) void {}
fn noopDiscAnnounceWriter(_: *anyopaque, _: *const WriterAnnouncement) anyerror!void {}
fn noopDiscRetractWriter(_: *anyopaque, _: Guid) void {}
fn noopDiscAnnounceReader(_: *anyopaque, _: *const ReaderAnnouncement) anyerror!void {}
fn noopDiscRetractReader(_: *anyopaque, _: Guid) void {}
fn noopDiscDeinit(_: *anyopaque) void {}

fn noopDiscovery() Discovery {
    return .{ .ctx = &noop_disc_sentinel, .vtable = &noop_disc_vtable };
}

// ── Factory harness ───────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,

    fn init(pid: u8) !Harness {
        const alloc = testing.allocator;
        const net = try MockNetwork.init(alloc);
        errdefer net.deinit();
        const meta_loc = Locator.udp4(.{ 127, 0, 0, pid }, 7410 + @as(u16, pid));
        const locs = [_]Locator{meta_loc};
        const t = try MockTransport.init(alloc, net, &locs);
        errdefer t.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            t.transport(),
            noopDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        return .{ .net = net, .transport = t, .factory = factory };
    }

    fn deinit(self: *Harness) void {
        self.factory.deinit();
        self.transport.deinit();
        self.net.deinit();
    }
};

// ── Participant lifecycle ─────────────────────────────────────────────────────

test "DCPS: create_participant / delete_participant" {
    var h = try Harness.init(0x01);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    // ptr is *anyopaque; verify it's not the null address
    try testing.expect(@intFromPtr(dp.ptr) != 0);

    const rc = dpf.delete_participant(dp);
    try testing.expectEqual(RETCODE_OK, rc);
}

test "DCPS: delete_participant with outstanding children fails" {
    var h = try Harness.init(0x02);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    // Create a publisher without deleting it.
    _ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);

    // delete_participant without deleting children should fail.
    const rc = dpf.delete_participant(dp);
    try testing.expectEqual(RETCODE_PRECONDITION, rc);

    // Clean up: delete_contained_entities then the participant.
    _ = dp.vtable.delete_contained_entities(dp.ptr);
    _ = dpf.delete_participant(dp);
}

// ── Publisher / Subscriber / Topic lifecycle ──────────────────────────────────

test "DCPS: create/delete Publisher and Subscriber" {
    var h = try Harness.init(0x03);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
    try testing.expect(@intFromPtr(pub_.ptr) != 0);

    const sub_ = dp.vtable.create_subscriber(dp.ptr, .{}, nil.nil_sub_listener, 0);
    try testing.expect(@intFromPtr(sub_.ptr) != 0);

    try testing.expectEqual(RETCODE_OK, dp.vtable.delete_publisher(dp.ptr, pub_));
    try testing.expectEqual(RETCODE_OK, dp.vtable.delete_subscriber(dp.ptr, sub_));
}

test "DCPS: create/delete Topic" {
    var h = try Harness.init(0x04);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const topic = dp.vtable.create_topic(
        dp.ptr,
        "MyTopic",
        "MyType",
        .{},
        nil.nil_topic_listener,
        0,
    );
    try testing.expect(@intFromPtr(topic.ptr) != 0);
    try testing.expectEqualStrings("MyTopic", topic.get_name());
    try testing.expectEqualStrings("MyType", topic.get_type_name());
    try testing.expectEqual(RETCODE_OK, dp.vtable.delete_topic(dp.ptr, topic));
}

// ── DataWriter / DataReader lifecycle ─────────────────────────────────────────

test "DCPS: create/delete DataWriter and DataReader" {
    var h = try Harness.init(0x05);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
    const sub_ = dp.vtable.create_subscriber(dp.ptr, .{}, nil.nil_sub_listener, 0);
    _ = dp.vtable.create_topic(dp.ptr, "T", "TT", .{}, nil.nil_topic_listener, 0);
    const td = dp.vtable.lookup_topicdescription(dp.ptr, "T");

    const dw = pub_.vtable.create_datawriter(
        pub_.ptr,
        dp.vtable.create_topic(dp.ptr, "T2", "TT", .{}, nil.nil_topic_listener, 0),
        .{},
        nil.nil_dw_listener,
        0,
    );
    try testing.expect(@intFromPtr(dw.ptr) != 0);

    const dr = sub_.vtable.create_datareader(sub_.ptr, td, .{}, nil.nil_dr_listener, 0);
    try testing.expect(@intFromPtr(dr.ptr) != 0);

    try testing.expectEqual(RETCODE_OK, dp.vtable.delete_contained_entities(dp.ptr));
}

test "DCPS: delete_contained_entities removes all children" {
    var h = try Harness.init(0x06);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);

    const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
    const sub_ = dp.vtable.create_subscriber(dp.ptr, .{}, nil.nil_sub_listener, 0);
    _ = dp.vtable.create_topic(dp.ptr, "T", "TT", .{}, nil.nil_topic_listener, 0);
    const td = dp.vtable.lookup_topicdescription(dp.ptr, "T");
    _ = pub_.vtable.create_datawriter(
        pub_.ptr,
        dp.vtable.create_topic(dp.ptr, "T2", "TT", .{}, nil.nil_topic_listener, 0),
        .{},
        nil.nil_dw_listener,
        0,
    );
    _ = sub_.vtable.create_datareader(sub_.ptr, td, .{}, nil.nil_dr_listener, 0);

    try testing.expectEqual(RETCODE_OK, dp.vtable.delete_contained_entities(dp.ptr));
    try testing.expectEqual(RETCODE_OK, dpf.delete_participant(dp));
}

// ── WaitSet + GuardCondition ──────────────────────────────────────────────────

test "DCPS: GuardCondition set/get trigger" {
    const gc = try GuardConditionImpl.init(testing.allocator);
    defer gc.deinit();

    const cond = gc.toDDSGuardCondition();
    try testing.expectEqual(false, cond.vtable.get_trigger_value(cond.ptr));

    _ = cond.vtable.set_trigger_value(cond.ptr, true);
    try testing.expectEqual(true, cond.vtable.get_trigger_value(cond.ptr));

    _ = cond.vtable.set_trigger_value(cond.ptr, false);
    try testing.expectEqual(false, cond.vtable.get_trigger_value(cond.ptr));
}

test "DCPS: WaitSet.wait returns already-triggered GuardCondition immediately" {
    const gc = try GuardConditionImpl.init(testing.allocator);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(testing.allocator);
    defer ws.deinit();

    const dds_ws = ws.toDDSWaitSet();
    const dds_gc = gc.toDDSGuardCondition();

    _ = dds_gc.vtable.set_trigger_value(dds_gc.ptr, true);
    _ = dds_ws.vtable.attach_condition(dds_ws.ptr, gc.toCondition());

    var triggered: DDS.ConditionSeq = .empty;
    defer triggered.deinit(testing.allocator);
    const rc = dds_ws.vtable.wait(dds_ws.ptr, &triggered, DURATION_ZERO);
    try testing.expectEqual(RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 1), triggered.items.len);
    try testing.expect(triggered.items[0].ptr == dds_gc.ptr);
}

test "DCPS: WaitSet.wait times out when no condition is triggered" {
    const gc = try GuardConditionImpl.init(testing.allocator);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(testing.allocator);
    defer ws.deinit();

    const dds_ws = ws.toDDSWaitSet();
    _ = dds_ws.vtable.attach_condition(dds_ws.ptr, gc.toCondition());

    var triggered: DDS.ConditionSeq = .empty;
    defer triggered.deinit(testing.allocator);
    const rc = dds_ws.vtable.wait(dds_ws.ptr, &triggered, DURATION_ZERO);
    try testing.expectEqual(RETCODE_TIMEOUT, rc);
    try testing.expectEqual(@as(usize, 0), triggered.items.len);
}

test "DCPS: WaitSet.wait woken by GuardCondition triggered from another thread" {
    const gc = try GuardConditionImpl.init(testing.allocator);
    defer gc.deinit();
    const ws = try WaitSetImpl.init(testing.allocator);
    defer ws.deinit();

    const dds_ws = ws.toDDSWaitSet();
    const dds_gc = gc.toDDSGuardCondition();
    _ = dds_ws.vtable.attach_condition(dds_ws.ptr, gc.toCondition());

    const Trigger = struct {
        fn run(cond: DDS.GuardCondition) void {
            time_mod.sleepNs(20 * std.time.ns_per_ms);
            _ = cond.vtable.set_trigger_value(cond.ptr, true);
        }
    };
    const thr = try std.Thread.spawn(.{}, Trigger.run, .{dds_gc});
    defer thr.join();

    var triggered: DDS.ConditionSeq = .empty;
    defer triggered.deinit(testing.allocator);
    const timeout = DDS.Duration_t{ .sec = 2, .nanosec = 0 };
    const rc = dds_ws.vtable.wait(dds_ws.ptr, &triggered, timeout);
    try testing.expectEqual(RETCODE_OK, rc);
    try testing.expectEqual(@as(usize, 1), triggered.items.len);
}

// ── StatusCondition ───────────────────────────────────────────────────────────

test "DCPS: get_statuscondition on participant returns bound condition" {
    var h = try Harness.init(0x07);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const sc = dp.vtable.get_statuscondition(dp.ptr);
    try testing.expect(@intFromPtr(sc.ptr) != 0);
    // Default: no status change has occurred, trigger is false.
    try testing.expectEqual(false, sc.vtable.get_trigger_value(sc.ptr));
}

test "DCPS: get_statuscondition on DataWriter returns non-null condition" {
    var h = try Harness.init(0x08);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
    const topic = dp.vtable.create_topic(dp.ptr, "T", "TT", .{}, nil.nil_topic_listener, 0);
    const dw = pub_.vtable.create_datawriter(pub_.ptr, topic, .{}, nil.nil_dw_listener, 0);

    const sc = dw.vtable.get_statuscondition(dw.ptr);
    try testing.expect(@intFromPtr(sc.ptr) != 0);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

// ── DCPSTopic / get_discovered_topics / contains_entity ──────────────────────
//
// Injects synthetic discovery events via dp_impl.disc_callbacks directly,
// matching the pattern used in ignore_test.zig.

fn fireRemoteWriter(dp_impl: *DomainParticipantImpl, topic: []const u8, type_name: []const u8) void {
    const pfx = GuidPrefix{ .bytes = .{ 0xAA, 0xBB, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } };
    const data = iface.WriterData{
        .guid = .{ .prefix = pfx, .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x02 } },
        .participant_guid = .{ .prefix = pfx, .entity_id = EntityIds.participant },
        .topic_name = topic,
        .type_name = type_name,
        .qos = .{ .reliability_kind = 1, .durability_kind = 1 },
        .unicast_locators = &.{},
        .multicast_locators = &.{},
        .type_object = &.{},
    };
    dp_impl.disc_callbacks.on_writer_discovered(dp_impl.disc_callbacks.ctx, &data);
}

test "DCPS: DCPSTopic reader receives a sample when a topic is created" {
    var h = try Harness.init(0x0A);
    defer h.deinit();

    const alloc = testing.allocator;
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const bs_sub = dp.vtable.get_builtin_subscriber(dp.ptr);
    try testing.expect(@intFromPtr(bs_sub.ptr) != 0);

    _ = dp.vtable.create_topic(dp.ptr, "MyTopic", "MyType", .{}, nil.nil_topic_listener, 0);

    // The builtin DCPSTopic DataReader should now have one pending sample.
    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    const topic_dr = dp_impl.builtin_sub.?.topic_dr;
    const sample = topic_dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(sample.data);
    try testing.expect(sample.data.len > 0);
}

test "DCPS: get_discovered_topics returns handle for a SEDP-discovered writer's topic" {
    var h = try Harness.init(0x0B);
    defer h.deinit();

    const alloc = testing.allocator;
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    fireRemoteWriter(dp_impl, "RemoteTopic", "RemoteType");

    var handles = DDS.InstanceHandleSeq.empty;
    defer handles.deinit(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_discovered_topics(dp.ptr, &handles));
    try testing.expectEqual(@as(usize, 1), handles.items.len);
    try testing.expect(handles.items[0] != 0);
}

test "DCPS: get_discovered_topic_data returns name and type_name for discovered topic" {
    var h = try Harness.init(0x0C);
    defer h.deinit();

    const alloc = testing.allocator;
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    fireRemoteWriter(dp_impl, "DiscTopic", "DiscType");

    var handles = DDS.InstanceHandleSeq.empty;
    defer handles.deinit(alloc);
    _ = dp.vtable.get_discovered_topics(dp.ptr, &handles);
    try testing.expectEqual(@as(usize, 1), handles.items.len);

    var data = DDS.TopicBuiltinTopicData{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.vtable.get_discovered_topic_data(dp.ptr, &data, handles.items[0]));
    try testing.expectEqualStrings("DiscTopic", data.name);
    try testing.expectEqualStrings("DiscType", data.type_name);

    // Unknown handle returns BAD_PARAMETER.
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, dp.vtable.get_discovered_topic_data(dp.ptr, &data, 0xDEAD));
}

test "DCPS: get_discovered_topics deduplicates same topic from multiple writers" {
    var h = try Harness.init(0x0D);
    defer h.deinit();

    const alloc = testing.allocator;
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    // Inject two writers for the same topic.
    fireRemoteWriter(dp_impl, "SharedTopic", "SharedType");
    fireRemoteWriter(dp_impl, "SharedTopic", "SharedType");

    var handles = DDS.InstanceHandleSeq.empty;
    defer handles.deinit(alloc);
    _ = dp.vtable.get_discovered_topics(dp.ptr, &handles);
    try testing.expectEqual(@as(usize, 1), handles.items.len);
}

test "DCPS: contains_entity returns true for participant, topic, publisher, writer" {
    var h = try Harness.init(0x09);
    defer h.deinit();

    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
    defer _ = dpf.delete_participant(dp);

    const dp_handle = dp.vtable.get_instance_handle(dp.ptr);
    try testing.expect(dp.vtable.contains_entity(dp.ptr, dp_handle));

    const topic = dp.vtable.create_topic(dp.ptr, "T", "TT", .{}, nil.nil_topic_listener, 0);
    const topic_handle = topic.vtable.get_instance_handle(topic.ptr);
    try testing.expect(dp.vtable.contains_entity(dp.ptr, topic_handle));

    const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
    const pub_handle = pub_.vtable.get_instance_handle(pub_.ptr);
    try testing.expect(dp.vtable.contains_entity(dp.ptr, pub_handle));

    const dw = pub_.vtable.create_datawriter(pub_.ptr, topic, .{}, nil.nil_dw_listener, 0);
    const dw_handle = dw.vtable.get_instance_handle(dw.ptr);
    try testing.expect(dp.vtable.contains_entity(dp.ptr, dw_handle));

    // Unknown handle.
    try testing.expect(!dp.vtable.contains_entity(dp.ptr, 0x7EAD_BEEF));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}
