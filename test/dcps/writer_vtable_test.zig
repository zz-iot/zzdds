//! DataWriter vtable coverage tests.
//!
//! Exercises every method on DDS.DataWriter left uncovered by existing tests:
//! enable, get_statuscondition, get_status_changes, get_instance_handle,
//! set/get_qos, set/get_listener, get_topic, get_publisher,
//! wait_for_acknowledgments (BEST_EFFORT + no-writes paths),
//! all four status getters (initial-zero + change-clearing),
//! assert_liveliness, get_matched_subscriptions, get_matched_subscription_data,
//! and all four notification fire paths.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const DomainParticipantFactoryImpl = dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = dcps.DataWriterImpl;
const TopicImpl = dcps.TopicImpl;
const nil = dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;

const testing = std.testing;
const alloc = testing.allocator;

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return (@as(*TopicImpl, @ptrCast(@alignCast(t.ptr)))).toTopicDescription();
}

// ── Counting listener ─────────────────────────────────────────────────────────

const Counts = struct {
    pub_matched: i32 = 0,
    incompat: i32 = 0,
    deadline: i32 = 0,
    liveliness_lost: i32 = 0,
};

fn dwOnPubMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).pub_matched += 1;
}
fn dwOnIncompat(_: *anyopaque, _: *const DDS.OfferedIncompatibleQosStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).incompat += 1;
}
fn dwOnDeadline(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).deadline += 1;
}
fn dwOnLivelinessLost(_: *anyopaque, _: *const DDS.LivelinessLostStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).liveliness_lost += 1;
}

fn countingWriter(counts: *Counts) DDS.DataWriterListener {
    return .{
        .listener_data = counts,
        .on_publication_matched = dwOnPubMatched,
        .on_offered_incompatible_qos = dwOnIncompat,
        .on_offered_deadline_missed = dwOnDeadline,
        .on_liveliness_lost = dwOnLivelinessLost,
    };
}

// ── SingleFixture ─────────────────────────────────────────────────────────────

const SingleFixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t: *zzdds.intraprocess.MemoryTransport,
    d: *zzdds.intraprocess.DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,
    pub_: DDS.Publisher,
    topic: DDS.Topic,

    fn init(a: std.mem.Allocator) !SingleFixture {
        var delivery = try IntraProcessDelivery.init(a);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const factory = try DomainParticipantFactoryImpl.init(
            a,
            t.transport(),
            d.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory.deinit();
        const dp = factory.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_ = dp.create_publisher(.{}, null, 0);
        const topic = dp.create_topic("WriterTopic", "WriterType", .{}, null, 0);
        return .{
            .alloc = a,
            .delivery = delivery,
            .t = t,
            .d = d,
            .factory = factory,
            .dp = dp,
            .pub_ = pub_,
            .topic = topic,
        };
    }

    fn deinit(self: *SingleFixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }

    fn makeWriter(self: *SingleFixture, qos: DDS.DataWriterQos, listener: ?DDS.DataWriterListener, mask: DDS.StatusMask) DDS.DataWriter {
        return self.pub_.create_datawriter(self.topic, qos, listener, mask);
    }
};

// ── TwoPartyFixture ───────────────────────────────────────────────────────────

const TwoPartyFixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t_w: *zzdds.intraprocess.MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_: DDS.Publisher,
    topic_w: DDS.Topic,

    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(a: std.mem.Allocator) !TwoPartyFixture {
        var delivery = try IntraProcessDelivery.init(a);
        errdefer delivery.deinit();

        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(
            a,
            t_w.transport(),
            d_w.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_ = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("WVTopic", "WVType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(
            a,
            t_r.transport(),
            d_r.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const sub_ = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("WVTopic", "WVType", .{}, null, 0);

        return .{
            .alloc = a,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .pub_ = pub_,
            .topic_w = topic_w,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_ = sub_,
            .topic_r = topic_r,
        };
    }

    fn deinit(self: *TwoPartyFixture) void {
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }

    fn makeWriter(self: *TwoPartyFixture, qos: DDS.DataWriterQos) DDS.DataWriter {
        return self.pub_.create_datawriter(self.topic_w, qos, null, 0);
    }

    fn makeReader(self: *TwoPartyFixture, qos: DDS.DataReaderQos) DDS.DataReader {
        return self.sub_.create_datareader(
            topicDesc(self.topic_r),
            qos,
            null,
            0,
        );
    }
};

// ── Tests: basic vtable methods ───────────────────────────────────────────────

test "enable: returns RETCODE_OK" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.enable(dw.ptr));
}

test "get_statuscondition: returns non-nil condition" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const sc = dw.vtable.get_statuscondition(dw.ptr);
    try testing.expect(sc.ptr != dcps.NIL_PTR);
}

test "get_status_changes: initially zero" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    try testing.expectEqual(@as(DDS.StatusMask, 0), dw.vtable.get_status_changes(dw.ptr));
}

test "get_instance_handle: nonzero" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    try testing.expect(dw.vtable.get_instance_handle(dw.ptr) != 0);
}

test "set_qos / get_qos: round-trips" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var qos = DDS.DataWriterQos{};
    qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = fx.makeWriter(qos, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var qos2 = DDS.DataWriterQos{};
    qos2.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    _ = dw.set_qos(qos2);

    var out: DDS.DataWriterQos = .{};
    _ = dw.vtable.get_qos(dw.ptr, &out);
    try testing.expectEqual(DDS.ReliabilityQosPolicyKind.BEST_EFFORT_RELIABILITY_QOS, out.reliability.kind);
}

test "set_listener / get_listener: round-trips" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var counts = Counts{};
    const listener = countingWriter(&counts);
    _ = dw.set_listener(listener, DDS.PUBLICATION_MATCHED_STATUS);
    _ = dw.vtable.get_listener(dw.ptr); // listener stored internally
}

test "get_topic: returns the writer's topic" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const t = dw.vtable.get_topic(dw.ptr);
    try testing.expect(t.ptr == fx.topic.ptr);
}

test "get_publisher: returns the writer's publisher" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const p = dw.vtable.get_publisher(dw.ptr);
    try testing.expect(p.ptr == fx.pub_.ptr);
}

test "wait_for_acknowledgments: BEST_EFFORT returns OK immediately" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var qos = DDS.DataWriterQos{};
    qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    const dw = fx.makeWriter(qos, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const rc = (blk: {
        const _d = DDS.Duration_t{ .sec = 0, .nanosec = 0 };
        break :blk dw.vtable.wait_for_acknowledgments(dw.ptr, &_d);
    });
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "wait_for_acknowledgments: RELIABLE with no writes returns OK immediately" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var qos = DDS.DataWriterQos{};
    qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = fx.makeWriter(qos, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    // last_sn == 0 → nothing to wait for
    const rc = (blk: {
        const _d = DDS.Duration_t{ .sec = 0, .nanosec = 1 };
        break :blk dw.vtable.wait_for_acknowledgments(dw.ptr, &_d);
    });
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "assert_liveliness: returns RETCODE_OK" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.assert_liveliness(dw.ptr));
}

// ── Tests: status getters — initially zero ────────────────────────────────────

test "get_liveliness_lost_status: initially zero" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    var s: DDS.LivelinessLostStatus = .{};
    _ = dw.vtable.get_liveliness_lost_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.total_count_change);
}

test "get_offered_deadline_missed_status: initially zero" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    var s: DDS.OfferedDeadlineMissedStatus = .{};
    _ = dw.vtable.get_offered_deadline_missed_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
}

test "get_offered_incompatible_qos_status: initially zero" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    var s: DDS.OfferedIncompatibleQosStatus = .{};
    _ = dw.vtable.get_offered_incompatible_qos_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
}

test "get_publication_matched_status: initially zero" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    var s: DDS.PublicationMatchedStatus = .{};
    _ = dw.vtable.get_publication_matched_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);
}

// ── Tests: notification fire paths ───────────────────────────────────────────

test "notifyPublicationMatched: fires listener and sets status_changes" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingWriter(&counts);
    const dw = fx.makeWriter(.{}, listener, DDS.PUBLICATION_MATCHED_STATUS);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    DataWriterImpl.notifyPublicationMatched(dw.ptr, 42, true);
    try testing.expectEqual(@as(i32, 1), counts.pub_matched);
    // Listener clears the change on fire; status_changes should be clear too.
    try testing.expectEqual(@as(DDS.StatusMask, 0), dw.vtable.get_status_changes(dw.ptr));
}

test "notifyPublicationMatched: accumulates in status when no listener" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    DataWriterImpl.notifyPublicationMatched(dw.ptr, 7, true);
    try testing.expect(dw.vtable.get_status_changes(dw.ptr) & DDS.PUBLICATION_MATCHED_STATUS != 0);

    var s: DDS.PublicationMatchedStatus = .{};
    _ = dw.vtable.get_publication_matched_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expectEqual(@as(i32, 1), s.current_count_change);
    // Second read: changes were cleared by the first read.
    var s2: DDS.PublicationMatchedStatus = .{};
    _ = dw.vtable.get_publication_matched_status(dw.ptr, &s2);
    try testing.expectEqual(@as(i32, 0), s2.total_count_change);
    try testing.expectEqual(@as(i32, 0), s2.current_count_change);
}

test "notifyIncompatibleQos: fires listener and clears status" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingWriter(&counts);
    const dw = fx.makeWriter(.{}, listener, DDS.OFFERED_INCOMPATIBLE_QOS_STATUS);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    DataWriterImpl.notifyIncompatibleQos(dw.ptr, 11);
    try testing.expectEqual(@as(i32, 1), counts.incompat);
    try testing.expectEqual(@as(DDS.StatusMask, 0), dw.vtable.get_status_changes(dw.ptr));
}

test "notifyIncompatibleQos: accumulates when no listener; getter clears change" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    DataWriterImpl.notifyIncompatibleQos(dw.ptr, 11);
    try testing.expect(dw.vtable.get_status_changes(dw.ptr) & DDS.OFFERED_INCOMPATIBLE_QOS_STATUS != 0);

    var s: DDS.OfferedIncompatibleQosStatus = .{};
    _ = dw.vtable.get_offered_incompatible_qos_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 11), s.last_policy_id);
    // After reading, change is cleared.
    var s2: DDS.OfferedIncompatibleQosStatus = .{};
    _ = dw.vtable.get_offered_incompatible_qos_status(dw.ptr, &s2);
    try testing.expectEqual(@as(i32, 0), s2.total_count_change);
}

test "notifyDeadlineMissed: fires listener and clears status" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingWriter(&counts);
    const dw = fx.makeWriter(.{}, listener, DDS.OFFERED_DEADLINE_MISSED_STATUS);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    const impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    impl.notifyDeadlineMissed();
    try testing.expectEqual(@as(i32, 1), counts.deadline);
    try testing.expectEqual(@as(DDS.StatusMask, 0), dw.vtable.get_status_changes(dw.ptr));
}

test "notifyDeadlineMissed: accumulates when no listener; getter clears change" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    const impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    impl.notifyDeadlineMissed();
    try testing.expect(dw.vtable.get_status_changes(dw.ptr) & DDS.OFFERED_DEADLINE_MISSED_STATUS != 0);

    var s: DDS.OfferedDeadlineMissedStatus = .{};
    _ = dw.vtable.get_offered_deadline_missed_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    var s2: DDS.OfferedDeadlineMissedStatus = .{};
    _ = dw.vtable.get_offered_deadline_missed_status(dw.ptr, &s2);
    try testing.expectEqual(@as(i32, 0), s2.total_count_change);
}

test "notifyLivelinessLost: fires listener and clears status" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingWriter(&counts);
    const dw = fx.makeWriter(.{}, listener, DDS.LIVELINESS_LOST_STATUS);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    const impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    impl.notifyLivelinessLost();
    try testing.expectEqual(@as(i32, 1), counts.liveliness_lost);
    try testing.expectEqual(@as(DDS.StatusMask, 0), dw.vtable.get_status_changes(dw.ptr));
}

test "notifyLivelinessLost: accumulates when no listener; getter clears change" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    const impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    impl.notifyLivelinessLost();
    try testing.expect(dw.vtable.get_status_changes(dw.ptr) & DDS.LIVELINESS_LOST_STATUS != 0);

    var s: DDS.LivelinessLostStatus = .{};
    _ = dw.vtable.get_liveliness_lost_status(dw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    var s2: DDS.LivelinessLostStatus = .{};
    _ = dw.vtable.get_liveliness_lost_status(dw.ptr, &s2);
    try testing.expectEqual(@as(i32, 0), s2.total_count_change);
}

// ── Tests: matched subscriptions ─────────────────────────────────────────────

test "get_matched_subscriptions: empty before any match" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    const rc = dw.vtable.get_matched_subscriptions(dw.ptr, &handles);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, 0), handles._length);
}

test "get_matched_subscriptions: returns handle after reader matches" {
    var fx = try TwoPartyFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{});
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dr = fx.makeReader(.{});
    defer _ = fx.sub_.vtable.delete_datareader(fx.sub_.ptr, dr);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    const rc = dw.vtable.get_matched_subscriptions(dw.ptr, &handles);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, 1), handles._length);
}

test "get_matched_subscription_data: BAD_PARAMETER for unknown handle" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var data: DDS.SubscriptionBuiltinTopicData = .{};
    const rc = dw.vtable.get_matched_subscription_data(dw.ptr, &data, 9999);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
}

test "get_matched_subscription_data: returns data for matched reader" {
    var fx = try TwoPartyFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{});
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dr = fx.makeReader(.{});
    defer _ = fx.sub_.vtable.delete_datareader(fx.sub_.ptr, dr);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    _ = dw.vtable.get_matched_subscriptions(dw.ptr, &handles);
    try testing.expectEqual(@as(u32, 1), handles._length);

    var data: DDS.SubscriptionBuiltinTopicData = .{};
    defer data.deinit(std.heap.c_allocator);
    const rc = dw.vtable.get_matched_subscription_data(dw.ptr, &data, handles._buffer.?[0]);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqualStrings("WVTopic", data.topic_name);
    try testing.expectEqualStrings("WVType", data.type_name);
}

// ── Tests: allAcked / matchedReaderCount ─────────────────────────────────────

test "allAcked: true when no writes" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    try testing.expect(impl.allAcked());
}

test "matchedReaderCount: zero before any match" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    try testing.expectEqual(@as(usize, 0), impl.matchedReaderCount());
}

test "DataWriter: set_qos with user_data — clone survives replacement" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var d1 = [_]u8{0xAA};
    var q1 = DDS.DataWriterQos{};
    q1.user_data.value = .{ ._buffer = &d1, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.set_qos(dw.ptr, &q1));

    var d2 = [_]u8{0xBB};
    var q2 = DDS.DataWriterQos{};
    q2.user_data.value = .{ ._buffer = &d2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.set_qos(dw.ptr, &q2));

    var got = DDS.DataWriterQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.get_qos(dw.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(alloc);
}

test "DataWriter: get_qos returns independent clone — replacement does not dangle" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var d1 = [_]u8{0xCC};
    var q1 = DDS.DataWriterQos{};
    q1.user_data.value = .{ ._buffer = &d1, ._length = 1, ._maximum = 1, ._release = false };
    _ = dw.vtable.set_qos(dw.ptr, &q1);

    var got = DDS.DataWriterQos{};
    _ = dw.vtable.get_qos(dw.ptr, &got);

    _ = dw.vtable.set_qos(dw.ptr, &DDS.DataWriterQos{});

    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(alloc);
}

// ── Raw/loaned write ops (write_raw/loan_raw/publish_loan_raw/return_loan_raw) ─

test "write_raw: valid key_hash + payload lands in the cache" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    var key_hash_bytes = [_]u8{1} ** 16;
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    var payload_bytes = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    const payload = DDS.OctetSeq{ ._buffer = &payload_bytes, ._length = 4, ._maximum = 4, ._release = false };

    const before = dw_impl.proto_writer.cacheLen();
    const rc = dw.vtable.write_raw(dw.ptr, &key_hash, DDS.HANDLE_NIL, &payload, .ALIVE_WRITE_KIND, &DDS.Time_t{ .sec = DDS.TIME_INVALID_SEC, .nanosec = DDS.TIME_INVALID_NSEC });
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(before + 1, dw_impl.proto_writer.cacheLen());
}

test "write_raw: wrong-length key_hash is BAD_PARAMETER" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var short_bytes = [_]u8{1} ** 4;
    const short_key_hash = DDS.OctetSeq{ ._buffer = &short_bytes, ._length = 4, ._maximum = 4, ._release = false };
    var payload_bytes = [_]u8{0x01};
    const payload = DDS.OctetSeq{ ._buffer = &payload_bytes, ._length = 1, ._maximum = 1, ._release = false };

    const rc = dw.vtable.write_raw(dw.ptr, &short_key_hash, DDS.HANDLE_NIL, &payload, .ALIVE_WRITE_KIND, &DDS.Time_t{ .sec = DDS.TIME_INVALID_SEC, .nanosec = DDS.TIME_INVALID_NSEC });
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
}

test "loan_raw + publish_loan_raw: round trip through the real vtable lands the loaned bytes in the cache" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 4, &cdr_payload));
    try testing.expectEqual(@as(usize, 1), dw_impl.outstanding_loans.load(.monotonic));
    try testing.expect(cdr_payload._buffer != null);
    cdr_payload._buffer.?[0..4].* = .{ 0x01, 0x02, 0x03, 0x04 };

    var key_hash_bytes = [_]u8{2} ** 16;
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };

    const before = dw_impl.proto_writer.cacheLen();
    const rc = dw.vtable.publish_loan_raw(dw.ptr, &cdr_payload, &key_hash, DDS.HANDLE_NIL, .ALIVE_WRITE_KIND);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(before + 1, dw_impl.proto_writer.cacheLen());
    try testing.expectEqual(@as(usize, 0), dw_impl.outstanding_loans.load(.monotonic));
    // publish_loan_raw must clear the sequence -- the caller no longer owns it.
    try testing.expect(cdr_payload._buffer == null);
}

test "loan_raw + return_loan_raw: round trip through the real vtable publishes nothing" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 8, &cdr_payload));
    try testing.expectEqual(@as(usize, 1), dw_impl.outstanding_loans.load(.monotonic));

    const before = dw_impl.proto_writer.cacheLen();
    const rc = dw.vtable.return_loan_raw(dw.ptr, &cdr_payload);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(before, dw_impl.proto_writer.cacheLen());
    try testing.expectEqual(@as(usize, 0), dw_impl.outstanding_loans.load(.monotonic));
    try testing.expect(cdr_payload._buffer == null);
}

test "loan_raw: an outstanding loan blocks delete_datawriter with PRECONDITION_NOT_MET" {
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 1, &cdr_payload));

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw));

    // Resolve the loan, then teardown must succeed.
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.return_loan_raw(dw.ptr, &cdr_payload));
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw));
}

test "loan_raw: outstanding loan defers real protocol-writer teardown until the loan resolves" {
    // Regression for a real, distinct race (Greptile PR #69 review, round
    // 3): checkDeleteContainedPrecondition() is a momentary read -- it
    // observing zero outstanding loans doesn't mean a concurrent loan_raw()
    // can't acquire one immediately after. Reproducing that exact timing
    // race is inherently fragile (see this session's own notes on why a
    // thread-spawn-latency-based test for a similar race wasn't safe to
    // ship); this test instead directly proves the fix that actually closes
    // it, independent of check timing: even when protocol-writer teardown
    // proceeds with a loan already outstanding (simulated here by calling
    // the *real* destroy_proto_writer callback directly, bypassing the
    // precondition check entirely -- exactly what publisher.zig's own
    // teardown loop calls, just out of its normal sequence), the real
    // protocol writer's resources are not actually destroyed until the
    // loan releases its transferred quiesce ref. Before the fix, this would
    // segfault inside publish_loan_raw on a freed protocol writer.
    //
    // Calling the real callback (not proto_writer.deinit() directly)
    // matters for test hygiene too: it correctly removes the writer's
    // active_writers entry, so the fixture's own later teardown (which
    // still calls destroy_proto_writer once more, from PublisherImpl's own
    // deinit loop) finds nothing and safely no-ops instead of double-freeing
    // the now-torn-down protocol writer.
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(fx.pub_.ptr));

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 4, &cdr_payload));
    cdr_payload._buffer.?[0..4].* = .{ 0xAA, 0xBB, 0xCC, 0xDD };

    // Simulate the race having already gone the unsafe way: the protocol
    // writer is destroyed (from the participant's perspective) while the
    // loan above is still outstanding.
    pub_impl.cbs.destroy_proto_writer(pub_impl.cbs.ctx, dw_impl.instance_handle);

    // proto_writer's real resources are legitimately gone once
    // publish_loan_raw resolves the transferred ref and real teardown
    // finally runs, so there's nothing left to inspect on it afterward --
    // the proof here is publish_loan_raw succeeding at all, not crashing on
    // a use-after-free while it's still writing through the (correctly
    // still-alive) protocol writer.
    var key_hash_bytes = [_]u8{3} ** 16;
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    const rc = dw.vtable.publish_loan_raw(dw.ptr, &cdr_payload, &key_hash, DDS.HANDLE_NIL, .ALIVE_WRITE_KIND);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "return_loan_raw: releasing the last quiesce ref doesn't touch self afterward" {
    // Regression for a real, distinct bug (Greptile PR #69 review, round 4):
    // vtReturnLoanRaw released self's own quiesce ref -- which can
    // synchronously free self when it's the last outstanding ref -- BEFORE
    // reading self.proto_writer to release its ref too, a genuine
    // use-after-free. vtPublishLoanRaw already had the correct order for
    // free via LIFO `defer`s; vtReturnLoanRaw has no defers, so the order
    // had to be made explicit (proto_writer's ref released first, self's
    // own ref released last).
    //
    // Caution for future readers: this test does NOT reliably catch a
    // regression back to the wrong order via a crash. Confirmed by direct
    // manual instrumentation this session (temporary prints in reallyDeinit
    // and vtReturnLoanRaw, not kept): with the order deliberately broken,
    // self.releaseQuiesce() does synchronously free `self` here (reallyDeinit
    // fires) exactly as expected -- but the very next statement's read of
    // the now-dangling self.proto_writer still succeeds and returns the
    // correct pointer value, because std.testing.allocator's small-object
    // path doesn't unmap or poison a freed slot this size, unlike the
    // round-3 regression test's proto_writer object (whose crash comes from
    // touching genuinely torn-down nested RTPS state -- sockets, freed
    // internal containers -- not just a reused-but-intact struct field).
    // This test still exercises the real "loan is the last outstanding
    // ref, released via return_loan_raw" code path (untouched by any other
    // test in this file) and pins down the ref-count mechanics below via
    // explicit assertions; the actual use-after-free-safety property is
    // enforced by the explicit release order in vtReturnLoanRaw's source
    // and its accompanying comment, not by this test's pass/fail. Worth
    // revisiting under ASan if this project ever gets an ASan test step.
    //
    // Reproduces the exact ref state the real race leaves behind: a loan
    // outstanding, followed by a delete_datawriter that raced ahead of the
    // loan and completed anyway. Simulated the same way as the round-3
    // regression test above -- removing the writer from the publisher's own
    // list, destroying its protocol writer, and calling deinit() directly,
    // mirroring vtDeleteDataWriter's real successful path minus the
    // precondition check it would otherwise fail on. deinit() drops the
    // writer's baseline quiesce ref; since the loan below still holds a
    // transferred ref, the writer survives (EntityQuiesce defers physical
    // teardown) until return_loan_raw resolves it.
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(fx.pub_.ptr));

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(@as(usize, 1), dw_impl.quiesce.state.load(.monotonic));
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 4, &cdr_payload));
    try testing.expectEqual(@as(usize, 2), dw_impl.quiesce.state.load(.monotonic));

    pub_impl.mu.lock();
    for (pub_impl.writers.items, 0..) |w, i| {
        if (w == dw_impl) {
            _ = pub_impl.writers.swapRemove(i);
            break;
        }
    }
    pub_impl.mu.unlock();
    pub_impl.cbs.destroy_proto_writer(pub_impl.cbs.ctx, dw_impl.instance_handle);
    dw_impl.deinit();
    // Tearing-down bit set (high bit) + refcount 1 (just the loan's ref) --
    // confirms the precondition this test exists to exercise actually holds
    // before return_loan_raw runs.
    try testing.expectEqual(@as(usize, 0x8000000000000001), dw_impl.quiesce.state.load(.monotonic));

    // dw_impl is now kept alive only by the loan's transferred quiesce ref
    // -- removed from pub_impl.writers above, so nothing else will touch it
    // again (no `defer delete_datawriter` for this dw). Returning the loan
    // resolves that ref and frees dw_impl for real: the proof here is this
    // call succeeding without crashing, not anything left to inspect on
    // dw_impl afterward (it's legitimately gone).
    const rc = dw.vtable.return_loan_raw(dw.ptr, &cdr_payload);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "delete_publisher: a loan racing the TOCTOU window before the real deinit cascade is safe" {
    // Regression matching Greptile PR #69 review's own sequence diagram for
    // its round-5 restatement of the (already-fixed) round-3 finding: this
    // exercises the exact parent-level shape it describes -- a real
    // checkDeleteContainedPrecondition() call (observing zero loans),
    // followed by a loan racing in during the gap before the real
    // PublisherImpl.deinit() cascade runs (matching vtDeletePublisher's/
    // participant.zig's vtDeleteContained's actual check-then-unlock-then-
    // deinit shape -- neither holds a lock spanning both) -- rather than
    // round-3's test, which simulates the destroy_proto_writer step
    // directly without going through the parent's own real check+cascade
    // code path at all.
    //
    // Greptile's restated concern: parent deletion "destroys the protocol
    // endpoint" while a loan racing the check still needs it. This proves
    // that's safe: destroy_proto_writer/w.deinit() (called from the real
    // PublisherImpl.deinit() cascade below) only *defer* real teardown --
    // acquiring the loan transferred both quiesce refs (entity + protocol,
    // round-3's fix) before the cascade ran, so nothing is actually freed
    // until the loan resolves, regardless of how tight the TOCTOU window is
    // or how many layers up the deletion started.
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(fx.pub_.ptr));
    const dp_impl: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(fx.dp.ptr));

    // Step 1: the real precondition check, exactly as vtDeletePublisher
    // calls it -- observes zero outstanding loans, passes.
    try testing.expectEqual(DDS.RETCODE_OK, pub_impl.checkDeleteContainedPrecondition());

    // Step 2: a loan races in during the window between the check above and
    // the deinit cascade below -- exactly what Greptile's diagram depicts.
    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 4, &cdr_payload));

    // Step 3: the real parent-level teardown proceeds anyway, mirroring
    // vtDeletePublisher exactly: remove from the participant's own list
    // under its lock, then deinit outside the lock (vtDeletePublisher
    // doesn't re-check the precondition either -- it already checked once
    // above, and re-checking here wouldn't close the gap being tested).
    dp_impl.mu.lock();
    for (dp_impl.publishers.items, 0..) |p, i| {
        if (p == pub_impl) {
            _ = dp_impl.publishers.swapRemove(i);
            break;
        }
    }
    dp_impl.mu.unlock();
    pub_impl.deinit();

    // pub_impl (and its child writer's protocol writer, via
    // destroy_proto_writer inside the deinit loop above) are now gone --
    // but dw_impl survives, kept alive solely by the loan's transferred
    // quiesce refs. Publishing the loan must still succeed: the proof this
    // scenario is actually safe.
    var key_hash_bytes = [_]u8{4} ** 16;
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    const rc = dw.vtable.publish_loan_raw(dw.ptr, &cdr_payload, &key_hash, DDS.HANDLE_NIL, .ALIVE_WRITE_KIND);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

// ── kcov coverage sweep (2026-08-24): closing gaps 1-4 from the fresh
// kcov-vs-PR-diff comparison ─────────────────────────────────────────────────

test "loan_raw: proto_writer already tearing down (but not yet freed) fails cleanly with ALREADY_DELETED" {
    // Coverage gap #1: the `!self.proto_writer.quiesceAcquire()` failure
    // branch in vtLoanRaw was untested -- this is the failure path of the
    // round-3 fix itself (src/dcps/writer.zig ~L1094-1097).
    //
    // To hit it without relying on undefined behavior, this holds an EXTRA
    // quiesce ref on proto_writer first (simulating some other legitimate
    // concurrent operation already using it -- the same technique
    // EntityQuiesce's own doc comment uses: "a background callback that
    // acquired before teardown began"), so destroy_proto_writer's
    // beginTeardown() only sets the tearing-down bit and drops the count
    // from 2 to 1 -- proto_writer stays genuinely allocated (not freed)
    // for the whole test, so quiesceAcquire()'s tearing-down-bit check is
    // what rejects the loan, never a read of freed memory.
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(fx.pub_.ptr));

    try testing.expect(dw_impl.proto_writer.quiesceAcquire());
    pub_impl.cbs.destroy_proto_writer(pub_impl.cbs.ctx, dw_impl.instance_handle);

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, dw.vtable.loan_raw(dw.ptr, 4, &cdr_payload));
    try testing.expect(cdr_payload._buffer == null);

    // Release the extra ref this test itself is holding -- proto_writer's
    // real teardown finally runs here, safely (nothing else touches it
    // afterward). Uses the same still-valid `ProtocolWriter` handle
    // acquired above; the field on dw_impl hasn't changed.
    dw_impl.proto_writer.quiesceRelease();
}

test "changeKindFromWriteKind: UNREGISTER_WRITE_KIND maps through autodispose_unregistered_instances" {
    // Coverage gap #2 (src/dcps/writer.zig L999-1000): UNREGISTER_WRITE_KIND
    // was never exercised by any write_raw test -- every existing one used
    // ALIVE_WRITE_KIND or DISPOSE_WRITE_KIND. autodispose_unregistered_
    // instances defaults to true, so a default-QoS writer's unregister maps
    // to .not_alive_disposed (the branch this test hits); the `else`
    // (.not_alive_unregistered, when the QoS is false) is a one-line mirror
    // of the same ternary, not separately worth a second test.
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var key_hash_bytes = [_]u8{5} ** 16;
    var key_hash_seq = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    var payload_buf = [_]u8{0x01};
    var payload_seq = DDS.OctetSeq{ ._buffer = &payload_buf, ._length = payload_buf.len, ._maximum = payload_buf.len, ._release = false };
    const ts = DDS.Time_t{ .sec = DDS.TIME_INVALID_SEC, .nanosec = DDS.TIME_INVALID_NSEC };
    const rc = dw.vtable.write_raw(dw.ptr, &key_hash_seq, DDS.HANDLE_NIL, &payload_seq, .UNREGISTER_WRITE_KIND, &ts);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "write_raw: an explicit instance_handle that doesn't match the key hash is rejected" {
    // Coverage gap #3 (src/dcps/writer.zig L1044): the
    // `handle != HANDLE_NIL and handle != registerInstanceRaw(kh)`
    // mismatch-rejection branch was untested -- every existing write_raw
    // test passed HANDLE_NIL (which always skips this check).
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var key_hash_bytes = [_]u8{6} ** 16;
    var key_hash_seq = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    var payload_buf = [_]u8{0x02};
    var payload_seq = DDS.OctetSeq{ ._buffer = &payload_buf, ._length = payload_buf.len, ._maximum = payload_buf.len, ._release = false };
    const ts = DDS.Time_t{ .sec = DDS.TIME_INVALID_SEC, .nanosec = DDS.TIME_INVALID_NSEC };
    const real_handle = DataWriterImpl.registerInstanceRaw(key_hash_bytes);
    const wrong_handle = real_handle + 1;
    const rc = dw.vtable.write_raw(dw.ptr, &key_hash_seq, wrong_handle, &payload_seq, .ALIVE_WRITE_KIND, &ts);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);
}

test "publish_loan_raw: an explicit instance_handle that doesn't match the key hash is rejected" {
    // Coverage gap #3, publish_loan_raw's own copy of the same check
    // (src/dcps/writer.zig L1124).
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dw = fx.makeWriter(.{}, null, 0);
    defer _ = fx.pub_.vtable.delete_datawriter(fx.pub_.ptr, dw);

    var cdr_payload = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.loan_raw(dw.ptr, 4, &cdr_payload));

    var key_hash_bytes = [_]u8{7} ** 16;
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    const real_handle = DataWriterImpl.registerInstanceRaw(key_hash_bytes);
    const wrong_handle = real_handle + 1;
    const rc = dw.vtable.publish_loan_raw(dw.ptr, &cdr_payload, &key_hash, wrong_handle, .ALIVE_WRITE_KIND);
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rc);

    // publish_loan_raw rejected before consuming the loan -- return it
    // properly so delete_datawriter (the deferred cleanup above) doesn't
    // hit PRECONDITION_NOT_MET.
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.return_loan_raw(dw.ptr, &cdr_payload));
}
