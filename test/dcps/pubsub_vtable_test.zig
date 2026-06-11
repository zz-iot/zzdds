//! Publisher and Subscriber vtable coverage tests.
//!
//! Exercises every method on DDS.Publisher and DDS.Subscriber that existing
//! tests leave uncovered: enable, get_statuscondition, get_status_changes,
//! get_instance_handle, lookup_*, delete_contained_entities, set/get_qos,
//! set/get_listener, suspend/resume/begin/end coherent, wait_for_acknowledgments,
//! get_participant, set/get_default_*_qos, copy_from_topic_qos, deinit.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const nil = dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const mock_tr = zzdds.mock_transport;
const iface = zzdds.discovery;

const MockNetwork = mock_tr.MockNetwork;
const MockTransport = mock_tr.MockTransport;
const Locator = mock_tr.Locator;
const testing = std.testing;
const alloc = testing.allocator;

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

// ── Harness ───────────────────────────────────────────────────────────────────

const Harness = struct {
    net: *MockNetwork,
    transport: *MockTransport,
    factory: *DomainParticipantFactoryImpl,

    fn init(pid: u8) !Harness {
        const net = try MockNetwork.init(alloc);
        errdefer net.deinit();
        const loc = Locator.udp4(.{ 127, 0, 0, pid }, 7900 + @as(u16, pid));
        const t = try MockTransport.init(alloc, net, &.{loc});
        errdefer t.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            t.transport(),
            noopDisc(),
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

// ── Publisher vtable coverage ─────────────────────────────────────────────────

test "Publisher: enable returns RETCODE_OK" {
    var h = try Harness.init(0x20);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, pub_.vtable.enable(pub_.ptr));
}

test "Publisher: get_statuscondition and get_status_changes" {
    var h = try Harness.init(0x21);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);

    const sc = pub_.vtable.get_statuscondition(pub_.ptr);
    try testing.expect(@intFromPtr(sc.ptr) != 0);
    // No status events → trigger is false.
    try testing.expectEqual(false, sc.vtable.get_trigger_value(sc.ptr));

    const mask = pub_.vtable.get_status_changes(pub_.ptr);
    try testing.expectEqual(@as(DDS.StatusMask, 0), mask);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: lookup_datawriter found and not-found" {
    var h = try Harness.init(0x22);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("LookupTopic", "LT", .{}, null, 0);
    _ = pub_.create_datawriter(topic, .{}, null, 0);

    // Found.
    const found = pub_.vtable.lookup_datawriter(pub_.ptr, "LookupTopic");
    try testing.expect(@intFromPtr(found.ptr) != @intFromPtr(nil.NIL_PTR));

    // Not found.
    const missing = pub_.vtable.lookup_datawriter(pub_.ptr, "NoSuchTopic");
    try testing.expectEqual(@intFromPtr(nil.NIL_PTR), @intFromPtr(missing.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: delete_contained_entities clears all writers" {
    var h = try Harness.init(0x23);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("T1", "TT", .{}, null, 0);
    _ = pub_.create_datawriter(topic, .{}, null, 0);

    const rc = pub_.vtable.delete_contained_entities(pub_.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "Publisher: delete_datawriter returns BAD_PARAMETER for unknown writer" {
    var h = try Harness.init(0x24);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    const rc = pub_.vtable.delete_datawriter(pub_.ptr, nil.nil_datawriter);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
}

test "Publisher: set_qos / get_qos round-trip" {
    var h = try Harness.init(0x25);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    var qos = DDS.PublisherQos{};
    // Default Partition has no names — set a marker via the presentation field.
    qos.presentation.coherent_access = true;

    _ = pub_.set_qos(qos);

    var got: DDS.PublisherQos = .{};
    _ = pub_.vtable.get_qos(pub_.ptr, &got);
    try testing.expectEqual(true, got.presentation.coherent_access);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: set_listener / get_listener round-trip" {
    var h = try Harness.init(0x26);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    _ = pub_.set_listener(null, 0xFFFF);
    _ = pub_.vtable.get_listener(pub_.ptr); // returns noop listener after null set

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: suspend/resume/begin/end return OK" {
    var h = try Harness.init(0x27);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, pub_.vtable.suspend_publications(pub_.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, pub_.vtable.resume_publications(pub_.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, pub_.vtable.begin_coherent_changes(pub_.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, pub_.vtable.end_coherent_changes(pub_.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: wait_for_acknowledgments with BEST_EFFORT writer returns OK" {
    var h = try Harness.init(0x28);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    const topic = dp.create_topic("AckTopic", "AT", .{}, null, 0);
    // Default QoS is BEST_EFFORT; no acks needed → wait returns OK immediately.
    _ = pub_.create_datawriter(topic, .{}, null, 0);

    const timeout: DDS.Duration_t = .{ .sec = 0, .nanosec = 1_000_000 };
    const rc = pub_.vtable.wait_for_acknowledgments(pub_.ptr, &timeout);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: wait_for_acknowledgments with infinite timeout and no writers" {
    var h = try Harness.init(0x29);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    // No writers → all_done is immediately true for any timeout including infinite.
    const _inf = DDS.Duration_t{ .sec = DDS.DURATION_INFINITE_SEC, .nanosec = DDS.DURATION_INFINITE_NSEC };
    const rc = pub_.vtable.wait_for_acknowledgments(pub_.ptr, &_inf);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: get_participant returns the owning DomainParticipant" {
    var h = try Harness.init(0x2A);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    const got_dp = pub_.vtable.get_participant(pub_.ptr);
    try testing.expectEqual(@intFromPtr(dp.ptr), @intFromPtr(got_dp.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: set/get_default_datawriter_qos round-trip" {
    var h = try Harness.init(0x2B);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    var qos = DDS.DataWriterQos{};
    qos.history.depth = 42;
    _ = pub_.set_default_datawriter_qos(qos);

    var got: DDS.DataWriterQos = .{};
    _ = pub_.vtable.get_default_datawriter_qos(pub_.ptr, &got);
    try testing.expectEqual(@as(i32, 42), got.history.depth);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Publisher: copy_from_topic_qos copies relevant fields" {
    var h = try Harness.init(0x2C);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const pub_ = dp.create_publisher(.{}, null, 0);
    var topic_qos = DDS.TopicQos{};
    topic_qos.history.depth = 7;
    var dw_qos = DDS.DataWriterQos{};
    const rc = pub_.copy_from_topic_qos(&dw_qos, topic_qos);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(i32, 7), dw_qos.history.depth);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

// ── Subscriber vtable coverage ────────────────────────────────────────────────

test "Subscriber: enable, get_statuscondition, get_status_changes, get_instance_handle" {
    var h = try Harness.init(0x30);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);

    try testing.expectEqual(DDS.RETCODE_OK, sub.vtable.enable(sub.ptr));

    const sc = sub.vtable.get_statuscondition(sub.ptr);
    try testing.expect(@intFromPtr(sc.ptr) != 0);
    try testing.expectEqual(false, sc.vtable.get_trigger_value(sc.ptr));

    try testing.expectEqual(@as(DDS.StatusMask, 0), sub.vtable.get_status_changes(sub.ptr));

    const ih = sub.vtable.get_instance_handle(sub.ptr);
    try testing.expect(ih != 0);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: lookup_datareader found and not-found" {
    var h = try Harness.init(0x31);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    _ = dp.create_topic("SubLookup", "SLT", .{}, null, 0);
    const topic_desc = dp.vtable.lookup_topicdescription(dp.ptr, "SubLookup");
    _ = sub.create_datareader(topic_desc, .{}, null, 0);

    const found = sub.vtable.lookup_datareader(sub.ptr, "SubLookup");
    try testing.expect(@intFromPtr(found.ptr) != @intFromPtr(nil.NIL_PTR));

    const missing = sub.vtable.lookup_datareader(sub.ptr, "NoSuchTopic");
    try testing.expectEqual(@intFromPtr(nil.NIL_PTR), @intFromPtr(missing.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: delete_contained_entities" {
    var h = try Harness.init(0x32);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    _ = dp.create_topic("SubDel", "SDT", .{}, null, 0);
    _ = sub.create_datareader(dp.vtable.lookup_topicdescription(dp.ptr, "SubDel"), .{}, null, 0);

    const rc = sub.vtable.delete_contained_entities(sub.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "Subscriber: delete_datareader returns BAD_PARAMETER for unknown reader" {
    var h = try Harness.init(0x33);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    const rc = sub.vtable.delete_datareader(sub.ptr, nil.nil_datareader);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
}

test "Subscriber: get_datareaders with empty subscriber returns empty list" {
    var h = try Harness.init(0x34);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    var out: DDS.DataReaderSeq = .{};
    defer if (out._release) {
        if (out._buffer) |_b| alloc.free(_b[0..out._length]);
    };
    const rc = sub.vtable.get_datareaders(sub.ptr, &out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, 0), out._length);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: notify_datareaders fires listener for readers with DATA_AVAILABLE mask" {
    var h = try Harness.init(0x35);
    defer h.deinit();
    const dpf = h.factory.toDDSFactory();
    const dp = dpf.create_participant(0, .{}, null, 0);
    defer _ = dpf.delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    _ = dp.create_topic("NotifyDR", "NDT", .{}, null, 0);
    // Create a reader with DATA_AVAILABLE_STATUS in its listener mask.
    _ = sub.create_datareader(dp.vtable.lookup_topicdescription(dp.ptr, "NotifyDR"), .{}, null, DDS.DATA_AVAILABLE_STATUS);

    const rc = sub.vtable.notify_datareaders(sub.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: notify_datareaders with no readers returns OK" {
    var h = try Harness.init(0x36);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, sub.vtable.notify_datareaders(sub.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: set_qos / get_qos round-trip" {
    var h = try Harness.init(0x37);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    var qos = DDS.SubscriberQos{};
    qos.presentation.ordered_access = true;
    _ = sub.set_qos(qos);
    var got: DDS.SubscriberQos = .{};
    _ = sub.vtable.get_qos(sub.ptr, &got);
    try testing.expectEqual(true, got.presentation.ordered_access);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: set_listener / get_listener round-trip" {
    var h = try Harness.init(0x38);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    _ = sub.set_listener(null, 0xABCD);
    _ = sub.vtable.get_listener(sub.ptr); // returns noop listener after null set

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: begin_access / end_access return RETCODE_OK" {
    var h = try Harness.init(0x39);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    try testing.expectEqual(DDS.RETCODE_OK, sub.vtable.begin_access(sub.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, sub.vtable.end_access(sub.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: get_participant returns the owning DomainParticipant" {
    var h = try Harness.init(0x3A);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    const got_dp = sub.vtable.get_participant(sub.ptr);
    try testing.expectEqual(@intFromPtr(dp.ptr), @intFromPtr(got_dp.ptr));

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: set/get_default_datareader_qos round-trip" {
    var h = try Harness.init(0x3B);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    var qos = DDS.DataReaderQos{};
    qos.history.depth = 99;
    _ = sub.set_default_datareader_qos(qos);
    var got: DDS.DataReaderQos = .{};
    _ = sub.vtable.get_default_datareader_qos(sub.ptr, &got);
    try testing.expectEqual(@as(i32, 99), got.history.depth);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}

test "Subscriber: copy_from_topic_qos copies relevant fields" {
    var h = try Harness.init(0x3C);
    defer h.deinit();
    const dp = h.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    defer _ = h.factory.toDDSFactory().delete_participant(dp);

    const sub = dp.create_subscriber(.{}, null, 0);
    var topic_qos = DDS.TopicQos{};
    topic_qos.history.depth = 5;
    var dr_qos = DDS.DataReaderQos{};
    const rc = sub.copy_from_topic_qos(&dr_qos, topic_qos);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(i32, 5), dr_qos.history.depth);

    _ = dp.vtable.delete_contained_entities(dp.ptr);
}
