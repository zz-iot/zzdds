//! DataReader vtable and notification coverage tests.
//!
//! Covers all DDS.DataReader vtable methods, direct pub notify functions
//! (notifyIncompatibleQos, notifySubscriptionMatched, notifySampleLost,
//! notifyDeadlineMissed), pushCdr resource-limit behaviour, hasPendingData,
//! matchedWriterCount, and matched-publication queries.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const time_mod = zzdds.util.time;

const testing = std.testing;

// ── Listener helpers (C callback struct form) ─────────────────────────────────

// Recording listener: listener_data is *Counts; each callback increments its counter.
const Counts = struct {
    incompat: i32 = 0,
    sub_matched: i32 = 0,
    sample_lost: i32 = 0,
    deadline: i32 = 0,
};

fn drCountIncompat(_: *anyopaque, _: *const DDS.RequestedIncompatibleQosStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).incompat += 1;
}
fn drCountSubMatched(_: *anyopaque, _: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).sub_matched += 1;
}
fn drCountSampleLost(_: *anyopaque, _: *const DDS.SampleLostStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).sample_lost += 1;
}
fn drCountDeadline(_: *anyopaque, _: *const DDS.RequestedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*Counts, @ptrCast(@alignCast(ld))).deadline += 1;
}

fn countingListener(counts: *Counts) DDS.DataReaderListener {
    return .{
        .listener_data = counts,
        .on_requested_incompatible_qos = drCountIncompat,
        .on_subscription_matched = drCountSubMatched,
        .on_sample_lost = drCountSampleLost,
        .on_requested_deadline_missed = drCountDeadline,
    };
}

// ── Single-participant fixture ─────────────────────────────────────────────────

const SingleFixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t: *zzdds.intraprocess.MemoryTransport,
    d: *zzdds.intraprocess.DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,
    sub: DDS.Subscriber,
    topic: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !SingleFixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const factory = try DomainParticipantFactoryImpl.init(alloc, t.transport(), d.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory.deinit();
        const dp = factory.toDDSFactory().create_participant(0, .{}, null, 0);
        const sub = dp.create_subscriber(.{}, null, 0);
        const topic = dp.create_topic("RdrVtTopic", "RdrVtType", .{}, null, 0);
        return .{ .alloc = alloc, .delivery = delivery, .t = t, .d = d, .factory = factory, .dp = dp, .sub = sub, .topic = topic };
    }

    fn deinit(self: *SingleFixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }

    fn makeReader(self: *SingleFixture, listener: ?DDS.DataReaderListener, mask: DDS.StatusMask) DDS.DataReader {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic.ptr))).toTopicDescription();
        return self.sub.create_datareader(td, .{}, listener, mask);
    }

    fn makeReaderQos(self: *SingleFixture, qos: DDS.DataReaderQos, listener: ?DDS.DataReaderListener, mask: DDS.StatusMask) DDS.DataReader {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic.ptr))).toTopicDescription();
        return self.sub.create_datareader(td, qos, listener, mask);
    }
};

// ── Two-party fixture (for matched-publication tests) ─────────────────────────

const TwoPartyFixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    t_w: *zzdds.intraprocess.MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,

    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !TwoPartyFixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("RdrPubTopic", "RdrPubType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("RdrPubTopic", "RdrPubType", .{}, null, 0);
        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .pub_w = pub_w,
            .topic_w = topic_w,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_r = sub_r,
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
};

// ── vtable accessor tests ─────────────────────────────────────────────────────

test "DataReader: enable returns RETCODE_OK" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.enable(dr.ptr));
}

test "DataReader: get_statuscondition returns non-nil condition" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    const sc = dr.vtable.get_statuscondition(dr.ptr);
    try testing.expect(sc.ptr != nil.NIL_PTR);
    try testing.expectEqual(false, sc.vtable.get_trigger_value(sc.ptr));
}

test "DataReader: get_status_changes initially zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    try testing.expectEqual(@as(DDS.StatusMask, 0), dr.vtable.get_status_changes(dr.ptr));
}

test "DataReader: get_instance_handle returns non-zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    try testing.expect(dr.vtable.get_instance_handle(dr.ptr) != 0);
}

test "DataReader: create_readcondition and delete_readcondition" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    const rc = dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    try testing.expect(rc.ptr != nil.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.delete_readcondition(dr.ptr, rc));
}

test "DataReader: create_querycondition with no TypeSupport and non-empty expression returns nil" {
    // Without a registered TypeSupport, field access is unavailable and a
    // non-empty SQL expression cannot be evaluated.  create_querycondition must
    // return NIL rather than a condition that silently passes every sample.
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var _empty_params = DDS.StringSeq{};
    const qc = dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "x = 1", &_empty_params);
    try testing.expect(qc.ptr == nil.NIL_PTR);
}

test "DataReader: create_querycondition with empty expression succeeds without TypeSupport" {
    // An empty SQL expression imposes no field constraints, so it is valid
    // even when no TypeSupport is registered (it degrades to a ReadCondition).
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var _empty_params2 = DDS.StringSeq{};
    const qc = dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "", &_empty_params2);
    try testing.expect(qc.ptr != nil.NIL_PTR);
    qc.deinit();
}

test "DataReader: delete_contained_entities returns OK" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.delete_contained_entities(dr.ptr));
}

test "DataReader: set_qos / get_qos round-trip" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);

    var qos = DDS.DataReaderQos{};
    qos.history.depth = 17;
    try testing.expectEqual(DDS.RETCODE_OK, dr.set_qos(qos));
    var got: DDS.DataReaderQos = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_qos(dr.ptr, &got));
    try testing.expectEqual(@as(i32, 17), got.history.depth);
}

test "DataReader: set_listener / get_listener round-trip" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);

    try testing.expectEqual(DDS.RETCODE_OK, dr.set_listener(null, 0));
    _ = dr.vtable.get_listener(dr.ptr);
}

test "DataReader: get_topicdescription returns non-nil" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    const td = dr.vtable.get_topicdescription(dr.ptr);
    try testing.expect(td.ptr != nil.NIL_PTR);
}

test "DataReader: get_subscriber returns non-nil" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    const sub2 = dr.vtable.get_subscriber(dr.ptr);
    try testing.expect(sub2.ptr != nil.NIL_PTR);
}

test "DataReader: get_sample_rejected_status initially NOT_REJECTED" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var status: DDS.SampleRejectedStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_sample_rejected_status(dr.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.total_count);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.NOT_REJECTED, status.last_reason);
}

test "DataReader: get_liveliness_changed_status initially zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var status: DDS.LivelinessChangedStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_liveliness_changed_status(dr.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.alive_count);
    try testing.expectEqual(@as(i32, 0), status.not_alive_count);
}

test "DataReader: get_requested_deadline_missed_status initially zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var status: DDS.RequestedDeadlineMissedStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_requested_deadline_missed_status(dr.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.total_count);
}

test "DataReader: get_requested_incompatible_qos_status initially zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var status: DDS.RequestedIncompatibleQosStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_requested_incompatible_qos_status(dr.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.total_count);
}

test "DataReader: get_subscription_matched_status initially zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var status: DDS.SubscriptionMatchedStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_subscription_matched_status(dr.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.total_count);
}

test "DataReader: get_sample_lost_status initially zero" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var status: DDS.SampleLostStatus = undefined;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_sample_lost_status(dr.ptr, &status));
    try testing.expectEqual(@as(i32, 0), status.total_count);
}

test "DataReader: wait_for_historical_data with VOLATILE QoS returns OK immediately" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    // Default QoS is VOLATILE_DURABILITY_QOS — returns OK without waiting.
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    const _timeout = DDS.Duration_t{ .sec = 0, .nanosec = 1_000_000 };
    const rc = dr.vtable.wait_for_historical_data(dr.ptr, &_timeout);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

test "DataReader: get_matched_publications empty when no writer" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_matched_publications(dr.ptr, &handles));
    try testing.expectEqual(@as(u32, 0), handles._length);
}

test "DataReader: get_matched_publication_data with unknown handle returns BAD_PARAMETER" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);
    var data: DDS.PublicationBuiltinTopicData = undefined;
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, dr.vtable.get_matched_publication_data(dr.ptr, &data, 0xDEAD));
}

// ── hasPendingData + matchedWriterCount ───────────────────────────────────────

test "DataReader: hasPendingData false initially, true after pushCdr" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    try testing.expectEqual(false, dr.hasPendingData());
    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x42 });
    try testing.expectEqual(true, dr.hasPendingData());
    if (dr.takeRaw()) |s| dr.alloc.free(s.data);
}

test "DataReader: matchedWriterCount zero with no writer" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    try testing.expectEqual(@as(usize, 0), dr.matchedWriterCount());
}

// ── pushCdr resource limit ────────────────────────────────────────────────────

test "DataReader: pushCdr drops sample when max_samples=1 queue full" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var qos = DDS.DataReaderQos{};
    qos.resource_limits.max_samples = 1;
    const dr_dds = fx.makeReaderQos(qos, null, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xFF };
    dr.pushCdr(&payload);
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len); // first accepted
    dr.pushCdr(&payload);
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len); // second dropped
    if (dr.takeRaw()) |s| dr.alloc.free(s.data);
}

// ── Notification fire paths ───────────────────────────────────────────────────

test "DataReader: notifyIncompatibleQos fires listener when mask set" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingListener(&counts);
    const dr_dds = fx.makeReader(listener, DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    DataReaderImpl.notifyIncompatibleQos(dr, 7);
    try testing.expectEqual(@as(i32, 1), counts.incompat);
}

test "DataReader: notifySubscriptionMatched fires listener when mask set" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingListener(&counts);
    const dr_dds = fx.makeReader(listener, DDS.SUBSCRIPTION_MATCHED_STATUS);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    DataReaderImpl.notifySubscriptionMatched(dr, 42, true);
    try testing.expectEqual(@as(i32, 1), counts.sub_matched);
}

test "DataReader: notifySampleLost fires listener when mask set" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingListener(&counts);
    const dr_dds = fx.makeReader(listener, DDS.SAMPLE_LOST_STATUS);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.notifySampleLost(3);
    try testing.expectEqual(@as(i32, 1), counts.sample_lost);
}

test "DataReader: notifyDeadlineMissed fires listener when mask set" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    var counts = Counts{};
    const listener = countingListener(&counts);
    const dr_dds = fx.makeReader(listener, DDS.REQUESTED_DEADLINE_MISSED_STATUS);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.notifyDeadlineMissed();
    try testing.expectEqual(@as(i32, 1), counts.deadline);
}

// ── Status read-back clears change fields ─────────────────────────────────────

test "DataReader: get_requested_incompatible_qos_status clears change after read" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    DataReaderImpl.notifyIncompatibleQos(dr, 5);
    var status: DDS.RequestedIncompatibleQosStatus = undefined;
    _ = dr_dds.vtable.get_requested_incompatible_qos_status(dr_dds.ptr, &status);
    try testing.expectEqual(@as(i32, 1), status.total_count);
    try testing.expectEqual(@as(i32, 5), status.last_policy_id);
    // Second read: total_count_change cleared.
    _ = dr_dds.vtable.get_requested_incompatible_qos_status(dr_dds.ptr, &status);
    try testing.expectEqual(@as(i32, 0), status.total_count_change);
}

test "DataReader: get_sample_lost_status clears change after read" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.notifySampleLost(2);
    var status: DDS.SampleLostStatus = undefined;
    _ = dr_dds.vtable.get_sample_lost_status(dr_dds.ptr, &status);
    try testing.expectEqual(@as(i32, 2), status.total_count);
    _ = dr_dds.vtable.get_sample_lost_status(dr_dds.ptr, &status);
    try testing.expectEqual(@as(i32, 0), status.total_count_change);
}

test "DataReader: get_requested_deadline_missed_status clears change after read" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.notifyDeadlineMissed();
    var status: DDS.RequestedDeadlineMissedStatus = undefined;
    _ = dr_dds.vtable.get_requested_deadline_missed_status(dr_dds.ptr, &status);
    try testing.expectEqual(@as(i32, 1), status.total_count);
    _ = dr_dds.vtable.get_requested_deadline_missed_status(dr_dds.ptr, &status);
    try testing.expectEqual(@as(i32, 0), status.total_count_change);
}

// ── Two-party: matched publications ──────────────────────────────────────────

test "DataReader: get_matched_publications returns writer handle after match" {
    const alloc = testing.allocator;
    var fx = try TwoPartyFixture.init(alloc);
    defer fx.deinit();

    const td_r = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    const dr_dds = fx.sub_r.create_datareader(td_r, .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_dds);

    const dw_dds = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_dds);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.get_matched_publications(dr_dds.ptr, &handles));
    try testing.expectEqual(@as(u32, 1), handles._length);
    try testing.expect(handles._buffer.?[0] != 0);
}

test "DataReader: get_matched_publication_data returns data for matched writer" {
    const alloc = testing.allocator;
    var fx = try TwoPartyFixture.init(alloc);
    defer fx.deinit();

    const td_r = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    const dr_dds = fx.sub_r.create_datareader(td_r, .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_dds);

    const dw_dds = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_dds);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    _ = dr_dds.vtable.get_matched_publications(dr_dds.ptr, &handles);
    try testing.expectEqual(@as(u32, 1), handles._length);

    // Zero-initialized, matching the real calling convention every caller
    // (C-ABI FromCAbi, zig/discovery) follows: vtGetMatchedPubData frees
    // whatever is already in *data before writing fresh content, so passing
    // undefined here would crash trying to free garbage.
    var data: DDS.PublicationBuiltinTopicData = .{};
    defer data.deinit(std.heap.c_allocator);
    const rc = dr_dds.vtable.get_matched_publication_data(dr_dds.ptr, &data, handles._buffer.?[0]);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqualStrings("RdrPubTopic", data.topic_name);
    try testing.expectEqualStrings("RdrPubType", data.type_name);
}

test "DataReader: set_qos with user_data — clone survives replacement" {
    var fx = try SingleFixture.init(testing.allocator);
    defer fx.deinit();
    const dr = fx.makeReaderQos(.{}, null, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);

    var d1 = [_]u8{0xDD};
    var q1 = DDS.DataReaderQos{};
    q1.user_data.value = .{ ._buffer = &d1, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.set_qos(dr.ptr, &q1));

    var d2 = [_]u8{0xEE};
    var q2 = DDS.DataReaderQos{};
    q2.user_data.value = .{ ._buffer = &d2, ._length = 1, ._maximum = 1, ._release = false };
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.set_qos(dr.ptr, &q2));

    var got = DDS.DataReaderQos{};
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_qos(dr.ptr, &got));
    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(testing.allocator);
}

test "DataReader: get_qos returns independent clone — replacement does not dangle" {
    var fx = try SingleFixture.init(testing.allocator);
    defer fx.deinit();
    const dr = fx.makeReaderQos(.{}, null, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr);

    var d1 = [_]u8{0xFF};
    var q1 = DDS.DataReaderQos{};
    q1.user_data.value = .{ ._buffer = &d1, ._length = 1, ._maximum = 1, ._release = false };
    _ = dr.vtable.set_qos(dr.ptr, &q1);

    var got = DDS.DataReaderQos{};
    _ = dr.vtable.get_qos(dr.ptr, &got);

    _ = dr.vtable.set_qos(dr.ptr, &DDS.DataReaderQos{});

    try testing.expectEqual(@as(u32, 1), got.user_data.value._length);
    got.deinit(testing.allocator);
}

// ── Raw/loaned read ops (take_raw/read_raw/return_loan_raw) ────────────────────

test "take_raw: loan mode (max_len==0) is destructive, zero-copy, and outstanding_loans-tracked" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAA });
    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0xBB });
    try testing.expectEqual(@as(usize, 2), dr.pending.items.len);

    var payloads = DDS.OctetSeqSeq{}; // _maximum == 0 -> loan mode
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    const rc = dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    try testing.expectEqual(@as(u32, 2), payloads._length);
    try testing.expectEqual(false, payloads._release);
    try testing.expectEqual(@as(u32, 32), hashes._length); // 2 * 16 bytes
    try testing.expectEqual(@as(u32, 2), infos._length);
    try testing.expectEqual(@as(usize, 0), dr.pending.items.len); // destructive
    try testing.expectEqual(@as(usize, 2), dr.outstanding_loans.load(.monotonic));

    const buf0 = payloads._buffer.?[0];
    try testing.expectEqualSlices(u8, &.{ 0x00, 0x01, 0x00, 0x00, 0xAA }, buf0._buffer.?[0..buf0._length]);

    const rc2 = dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos);
    try testing.expectEqual(DDS.RETCODE_OK, rc2);
    try testing.expectEqual(@as(usize, 0), dr.outstanding_loans.load(.monotonic));
}

test "read_raw: loan mode is non-destructive -- samples stay in pending, marked READ" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAA });

    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    const rc = dr_dds.vtable.read_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1);
    try testing.expectEqual(DDS.RETCODE_OK, rc);

    try testing.expectEqual(@as(u32, 1), payloads._length);
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len); // non-destructive
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, dr.pending.items[0].info.sample_state);
    try testing.expectEqual(@as(usize, 1), dr.outstanding_loans.load(.monotonic));

    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
    try testing.expectEqual(@as(usize, 0), dr.outstanding_loans.load(.monotonic));
    // Sample is still in pending -- releasing a loan doesn't retire it.
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len);
}

test "take_raw: copy mode (max_len!=0) does not require return_loan_raw -- generic free is safe" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0xCC });

    // A non-zero _maximum signals copy mode -- the actual value/buffer
    // content is ignored (matches this codebase's existing convention for
    // sequence-returning ops, e.g. vtGetMatchedSubs, which always allocates
    // fresh rather than filling a caller-supplied buffer).
    var payloads = DDS.OctetSeqSeq{ ._maximum = 1 };
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    const rc = dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, 1), payloads._length);
    try testing.expectEqual(@as(usize, 0), dr.outstanding_loans.load(.monotonic)); // not a loan

    // return_loan_raw still works correctly on copy-mode output (finds no
    // loan_table entry, falls back to freeing each descriptor directly).
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
}

test "take_raw: an outstanding read-loan blocks delete_datareader with PRECONDITION_NOT_MET" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x01 });

    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));

    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds));

    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds));
}

test "take_raw: outstanding read-loan defers real protocol-reader teardown until the loan resolves" {
    // Regression for a real, distinct race (Greptile PR #69 review, round
    // 3), read-side counterpart of writer_vtable_test.zig's identical
    // fix/test -- see that test's comment for the full race description and
    // why the underlying fix (acquiring proto_reader's own EntityQuiesce
    // ref for the loan's whole lifetime, deferring real teardown) closes it
    // regardless of checkDeleteContainedPrecondition()'s check timing.
    //
    // Unlike the write side, releasing a read loan (return_loan_raw) never
    // itself touches proto_reader -- pinned samples live entirely in
    // DataReaderImpl's own `pending` queue. So the proof here is different:
    // matchedWriterCount() (which does call into proto_reader) must still
    // work correctly after the simulated destroy below, while the loan is
    // still outstanding -- proving proto_reader's real resources weren't
    // actually destroyed yet, not just that release itself doesn't crash.
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    const sub_impl: *zzdds.dcps.SubscriberImpl = @ptrCast(@alignCast(fx.sub.ptr));
    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x01 });

    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));

    // Simulate the race having already gone the unsafe way: the protocol
    // reader is destroyed (from the participant's perspective) while the
    // loan above is still outstanding.
    sub_impl.cbs.destroy_proto_reader(sub_impl.cbs.ctx, dr.instance_handle);

    // Before the fix, proto_reader's real resources would already be gone
    // here, and this would use-after-free.
    _ = dr.matchedWriterCount();

    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
}

test "return_loan_raw: releasing the last quiesce ref doesn't touch self afterward" {
    // Regression for a real, distinct bug (Greptile PR #69 review, round
    // 4), read-side counterpart of writer_vtable_test.zig's identical
    // fix/test -- see that test's comment for the full bug description AND
    // an important caveat: this test does not reliably catch a regression
    // back to the wrong release order via a crash (confirmed empirically on
    // the write side this session; std.testing.allocator's small-object
    // path doesn't unmap/poison a freed slot this size). The actual
    // use-after-free-safety property is enforced by the explicit release
    // order in vtReturnLoanRaw's source and its accompanying comment, not
    // by this test's pass/fail -- this test exercises the real code path
    // and pins down the ref-count mechanics via explicit assertions.
    //
    // Unlike the write side, this function also frees hashes_seq/infos_seq
    // and the taken samples' own storage (all via self.alloc) before
    // releasing any quiesce ref -- every one of those self.alloc reads
    // would also have use-after-freed under the old (wrong) release order,
    // not just the self.proto_reader read.
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    const sub_impl: *zzdds.dcps.SubscriberImpl = @ptrCast(@alignCast(fx.sub.ptr));
    dr.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x01 });

    try testing.expectEqual(@as(usize, 1), dr.quiesce.state.load(.monotonic));
    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(usize, 2), dr.quiesce.state.load(.monotonic));

    // Simulate the race having already gone the unsafe way: a
    // delete_datareader raced ahead of the loan above and completed anyway
    // -- removing dr from the subscriber's own list, destroying its
    // protocol reader, and calling deinit() directly, mirroring
    // vtDeleteDataReader's real successful path minus the precondition
    // check it would otherwise fail on. deinit() drops dr's baseline
    // quiesce ref; the loan above still holds a transferred ref, so dr
    // survives (EntityQuiesce defers physical teardown) until
    // return_loan_raw resolves it.
    sub_impl.mu.lock();
    for (sub_impl.readers.items, 0..) |r, i| {
        if (r == dr) {
            _ = sub_impl.readers.swapRemove(i);
            break;
        }
    }
    sub_impl.mu.unlock();
    sub_impl.cbs.destroy_proto_reader(sub_impl.cbs.ctx, dr.instance_handle);
    dr.deinit();
    // Tearing-down bit set (high bit) + refcount 1 (just the loan's ref) --
    // confirms the precondition this test exists to exercise actually holds
    // before return_loan_raw runs.
    try testing.expectEqual(@as(usize, 0x8000000000000001), dr.quiesce.state.load(.monotonic));

    // dr is now kept alive only by the loan's transferred quiesce ref --
    // removed from sub_impl.readers above, so nothing else will touch it
    // again (no `defer delete_datareader`). Returning the loan resolves
    // that ref and frees dr for real: the proof here is this call
    // succeeding without crashing.
    const rc = dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
}

const PendingChange = zzdds.dcps.PendingChange;

/// Injects a sample for a specific instance_handle directly (pushCdr always
/// uses a single zero key hash / instance -- these tests need >= 2 distinct
/// instances, which nothing else in this file's fixtures can produce).
fn pushInstance(dr: *DataReaderImpl, alloc: std.mem.Allocator, ih: DDS.InstanceHandle_t, data: []const u8) !void {
    const pc = try alloc.create(PendingChange);
    pc.* = .{
        .data = try alloc.dupe(u8, data),
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = ih, .valid_data = true },
    };
    try dr.pending.append(alloc, pc);
}

/// Like pushInstance, but already expired (LIFESPAN QoS) -- expiry_ns is set
/// to a timestamp already in the past, so any raw op's expiry-sweep check
/// (`if (now_ns >= exp) ...`) fires the first time it runs, with no need to
/// wait for real time to pass or configure a real writer's lifespan QoS.
fn pushExpiredInstance(dr: *DataReaderImpl, alloc: std.mem.Allocator, ih: DDS.InstanceHandle_t, data: []const u8) !void {
    const pc = try alloc.create(PendingChange);
    pc.* = .{
        .data = try alloc.dupe(u8, data),
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = ih, .valid_data = true },
        .expiry_ns = time_mod.nanoTimestamp() - std.time.ns_per_s,
    };
    try dr.pending.append(alloc, pc);
}

test "take_raw: instance_handle filters to exactly that instance" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    try pushInstance(dr, alloc, 1, &[_]u8{0xA1});
    try pushInstance(dr, alloc, 2, &[_]u8{0xB2});

    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    const rc = dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, 2, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, 1), payloads._length);
    try testing.expectEqualSlices(u8, &.{0xB2}, payloads._buffer.?[0]._buffer.?[0..1]);
    try testing.expectEqual(@as(i32, 2), infos._buffer.?[0].instance_handle);
    // Instance 1's sample is untouched -- still in pending.
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len);

    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
}

test "take_next_instance_raw: cursor iteration visits each instance once, in handle order" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    try pushInstance(dr, alloc, 5, &[_]u8{0x05});
    try pushInstance(dr, alloc, 3, &[_]u8{0x03});

    // First call (previous_handle = HANDLE_NIL): lowest handle, instance 3.
    var payloads1 = DDS.OctetSeqSeq{};
    var hashes1 = DDS.OctetSeq{};
    var infos1 = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_next_instance_raw(dr_dds.ptr, &payloads1, &hashes1, &infos1, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads1._length);
    try testing.expectEqual(@as(i32, 3), infos1._buffer.?[0].instance_handle);
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads1, &hashes1, &infos1));

    // Second call (previous_handle = 3): next instance after it, instance 5.
    var payloads2 = DDS.OctetSeqSeq{};
    var hashes2 = DDS.OctetSeq{};
    var infos2 = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_next_instance_raw(dr_dds.ptr, &payloads2, &hashes2, &infos2, 3, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads2._length);
    try testing.expectEqual(@as(i32, 5), infos2._buffer.?[0].instance_handle);
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads2, &hashes2, &infos2));

    // No more instances after 5.
    var payloads3 = DDS.OctetSeqSeq{};
    var hashes3 = DDS.OctetSeq{};
    var infos3 = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_next_instance_raw(dr_dds.ptr, &payloads3, &hashes3, &infos3, 5, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 0), payloads3._length);
}

// ── Coverage gap #1: read_next_instance_raw (never previously exercised in
// either mode -- take_next_instance_raw's read-only sibling) ───────────────

test "read_next_instance_raw: loan mode is non-destructive and advances the cursor, mirroring take_next_instance_raw" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    try pushInstance(dr, alloc, 5, &[_]u8{0x05});
    try pushInstance(dr, alloc, 3, &[_]u8{0x03});

    var payloads1 = DDS.OctetSeqSeq{};
    var hashes1 = DDS.OctetSeq{};
    var infos1 = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.read_next_instance_raw(dr_dds.ptr, &payloads1, &hashes1, &infos1, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads1._length);
    try testing.expectEqual(@as(i32, 3), infos1._buffer.?[0].instance_handle);
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads1, &hashes1, &infos1));
    // Non-destructive: both samples remain in pending, just marked read.
    try testing.expectEqual(@as(usize, 2), dr.pending.items.len);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, dr.pending.items[1].info.sample_state);

    // Cursor still advances past instance 3, same as take_next_instance_raw.
    var payloads2 = DDS.OctetSeqSeq{};
    var hashes2 = DDS.OctetSeq{};
    var infos2 = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.read_next_instance_raw(dr_dds.ptr, &payloads2, &hashes2, &infos2, 3, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads2._length);
    try testing.expectEqual(@as(i32, 5), infos2._buffer.?[0].instance_handle);
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads2, &hashes2, &infos2));
}

test "read_next_instance_raw: copy mode (max_len!=0) is non-destructive and independently owned" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    try pushInstance(dr, alloc, 3, &[_]u8{0x03});

    var descriptor_buf: [1]DDS.OctetSeq = undefined;
    var payloads = DDS.OctetSeqSeq{ ._buffer = &descriptor_buf, ._length = 0, ._maximum = 1, ._release = false };
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.read_next_instance_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads._length);
    try testing.expectEqualSlices(u8, &.{0x03}, payloads._buffer.?[0]._buffer.?[0..1]);
    // Non-destructive: sample remains in pending, marked read.
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, dr.pending.items[0].info.sample_state);
    // Copy mode: return_loan_raw still safely releases the independently-owned copy.
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
}

// ── Coverage gap #2: read_raw copy mode (only take_raw's copy mode had a
// test; readRaw's own call site inside rawReadOrTakeImpl never fired) ──────

test "read_raw: copy mode (max_len!=0) is non-destructive and independently owned" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    try pushInstance(dr, alloc, 1, &[_]u8{0x07});

    // A non-zero _maximum signals copy mode -- the actual caller-supplied
    // buffer/value is ignored, matching take_raw's copy-mode test above
    // (buildRawOutputFromTaken always allocates fresh regardless of mode).
    var payloads = DDS.OctetSeqSeq{ ._maximum = 1 };
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.read_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads._length);
    try testing.expectEqualSlices(u8, &.{0x07}, payloads._buffer.?[0]._buffer.?[0..1]);
    // Non-destructive: sample remains in pending, marked read.
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, dr.pending.items[0].info.sample_state);
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
}

// ── Coverage gap #3: raw ops + a real QueryCondition (every existing raw-op
// condition test used a plain ReadCondition; the QueryCondition-thunk branch
// in resolveRawFilter never ran) ────────────────────────────────────────────

test "take_raw: a_condition accepts a real QueryCondition (degrades to ReadCondition semantics with an empty expression)" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));
    try pushInstance(dr, alloc, 1, &[_]u8{0x09});

    // Empty expression imposes no field constraints -- valid without a
    // registered TypeSupport, and matches everything, same as a plain
    // ReadCondition with ANY_*_STATE masks.
    var empty_params = DDS.StringSeq{};
    const qc = dr_dds.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "", &empty_params);
    try testing.expect(qc.ptr != nil.NIL_PTR);
    defer qc.deinit();
    const rc_view = qc.vtable.as_ReadCondition(qc.ptr);

    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    // Explicit masks are ignored when a_condition is non-nil -- pass masks
    // that would exclude everything, to prove the condition's own stored
    // masks (not these) are what's actually applied.
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, rc_view, 0, 0, 0, -1));
    try testing.expectEqual(@as(u32, 1), payloads._length);
    try testing.expectEqualSlices(u8, &.{0x09}, payloads._buffer.?[0]._buffer.?[0..1]);
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.return_loan_raw(dr_dds.ptr, &payloads, &hashes, &infos));
}

// ── Coverage gap #4: LIFESPAN expiry sweep, never exercised for any of the
// raw-op pin/take-for-loan functions (pinSamplesForLoan, takeSamplesForLoan,
// pinNextInstanceForLoan, takeNextInstanceForLoan all duplicate this same
// sweep, each independently untested) ───────────────────────────────────────

test "take_raw: loan mode sweeps an already-expired (LIFESPAN) sample instead of returning it" {
    const alloc = testing.allocator;
    var fx = try SingleFixture.init(alloc);
    defer fx.deinit();
    const dr_dds = fx.makeReader(nil.nil_dr_listener, 0);
    defer _ = fx.sub.vtable.delete_datareader(fx.sub.ptr, dr_dds);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_dds.ptr));

    try pushExpiredInstance(dr, alloc, 1, &[_]u8{0xEE});
    try testing.expectEqual(@as(usize, 1), dr.pending.items.len);

    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, dr_dds.vtable.take_raw(dr_dds.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, nil.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    // Swept during the expiry pass, not returned as a real sample.
    try testing.expectEqual(@as(u32, 0), payloads._length);
    try testing.expectEqual(@as(usize, 0), dr.pending.items.len);
}
