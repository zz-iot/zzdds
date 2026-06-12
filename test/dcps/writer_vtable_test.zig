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

fn dwOnPubMatched(_: DDS.DataWriter, _: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).pub_matched += 1;
}
fn dwOnIncompat(_: DDS.DataWriter, _: *const DDS.OfferedIncompatibleQosStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).incompat += 1;
}
fn dwOnDeadline(_: DDS.DataWriter, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).deadline += 1;
}
fn dwOnLivelinessLost(_: DDS.DataWriter, _: *const DDS.LivelinessLostStatus, ld: ?*anyopaque) callconv(.c) void {
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
        const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
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
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
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
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
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
