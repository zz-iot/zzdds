//! Phase 32a SampleRejectedStatus + RESOURCE_LIMITS enforcement tests.
//!
//! Uses IntraProcessDelivery + DirectDiscovery so delivery is synchronous
//! and all assertions are deterministic.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;
const NIL_KEY = std.mem.zeroes([16]u8);
// Minimal CDR_LE encap + one byte of payload.
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x42 };

fn makeKey(b: u8) [16]u8 {
    var k = std.mem.zeroes([16]u8);
    k[0] = b;
    return k;
}

// ── Fixture ───────────────────────────────────────────────────────────────────

const Fixture = struct {
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

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const pub_w = dp_w.vtable.create_publisher(dp_w.ptr, .{}, nil.nil_pub_listener, 0);
        const topic_w = dp_w.vtable.create_topic(dp_w.ptr, "RejTopic", "RejType", .{}, nil.nil_topic_listener, 0);
        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
        const topic_r = dp_r.vtable.create_topic(dp_r.ptr, "RejTopic", "RejType", .{}, nil.nil_topic_listener, 0);
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

    fn deinit(self: *Fixture) void {
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

    fn topicDesc(self: *Fixture) DDS.TopicDescription {
        return (@as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr)))).toTopicDescription();
    }

    fn makeWriter(self: *Fixture) *DataWriterImpl {
        const dw = self.pub_w.vtable.create_datawriter(self.pub_w.ptr, self.topic_w, .{}, nil.nil_dw_listener, 0);
        return @ptrCast(@alignCast(dw.ptr));
    }

    fn makeReader(self: *Fixture, dr_qos: DDS.DataReaderQos, listener: DDS.DataReaderListener, mask: DDS.StatusMask) *DataReaderImpl {
        const dr = self.sub_r.vtable.create_datareader(self.sub_r.ptr, self.topicDesc(), dr_qos, listener, mask);
        return @ptrCast(@alignCast(dr.ptr));
    }
};

fn write(dw: *DataWriterImpl, key: [16]u8) !void {
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, key, &PAYLOAD);
}

// ── Listener helpers ──────────────────────────────────────────────────────────

fn drOnSampleRejected(ctx: *anyopaque, _: DDS.DataReader, s: DDS.SampleRejectedStatus) void {
    @as(*DDS.SampleRejectedStatus, @ptrCast(@alignCast(ctx))).* = s;
}
fn drNoop(_: *anyopaque) void {}
fn drNoopDR(_: *anyopaque, _: DDS.DataReader) void {}
fn drNoopIncompat(_: *anyopaque, _: DDS.DataReader, _: DDS.RequestedIncompatibleQosStatus) void {}
fn drNoopDeadline(_: *anyopaque, _: DDS.DataReader, _: DDS.RequestedDeadlineMissedStatus) void {}
fn drNoopLiveliness(_: *anyopaque, _: DDS.DataReader, _: DDS.LivelinessChangedStatus) void {}
fn drNoopSubMatched(_: *anyopaque, _: DDS.DataReader, _: DDS.SubscriptionMatchedStatus) void {}
fn drNoopSampleLost(_: *anyopaque, _: DDS.DataReader, _: DDS.SampleLostStatus) void {}

const dr_rejected_vtable = DDS.DataReaderListener.Vtable{
    .on_requested_deadline_missed = drNoopDeadline,
    .on_requested_incompatible_qos = drNoopIncompat,
    .on_sample_rejected = drOnSampleRejected,
    .on_liveliness_changed = drNoopLiveliness,
    .on_data_available = drNoopDR,
    .on_subscription_matched = drNoopSubMatched,
    .on_sample_lost = drNoopSampleLost,
    .deinit = struct {
        fn f(_: *anyopaque) void {}
    }.f,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "sample_rejected: max_samples poll path" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;

    const dw = fx.makeWriter();
    const dr = fx.makeReader(dr_qos, nil.nil_dr_listener, 0);

    try write(dw, NIL_KEY); // accepted
    try write(dw, NIL_KEY); // rejected — pending full

    var s = DDS.SampleRejectedStatus{};
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.total_count_change);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.REJECTED_BY_SAMPLES_LIMIT, s.last_reason);
}

test "sample_rejected: change resets after poll" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;

    const dw = fx.makeWriter();
    const dr = fx.makeReader(dr_qos, nil.nil_dr_listener, 0);

    try write(dw, NIL_KEY);
    try write(dw, NIL_KEY); // rejected

    var s = DDS.SampleRejectedStatus{};
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count_change);

    // Second poll: change resets, total stays.
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.total_count_change);
}

test "sample_rejected: total_count accumulates across multiple rejections" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;

    const dw = fx.makeWriter();
    const dr = fx.makeReader(dr_qos, nil.nil_dr_listener, 0);

    try write(dw, NIL_KEY); // accepted
    try write(dw, NIL_KEY); // rejected #1
    try write(dw, NIL_KEY); // rejected #2

    var s = DDS.SampleRejectedStatus{};
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 2), s.total_count);
    // change reflects both since last read
    try testing.expectEqual(@as(i32, 2), s.total_count_change);
}

test "sample_rejected: listener fires on rejection" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;

    var captured = DDS.SampleRejectedStatus{};
    const listener = DDS.DataReaderListener{ .ptr = &captured, .vtable = &dr_rejected_vtable };

    const dw = fx.makeWriter();
    _ = fx.makeReader(dr_qos, listener, DDS.SAMPLE_REJECTED_STATUS);

    try write(dw, NIL_KEY); // accepted — no listener fire
    try testing.expectEqual(DDS.SampleRejectedStatusKind.NOT_REJECTED, captured.last_reason);

    try write(dw, NIL_KEY); // rejected — listener fires
    try testing.expectEqual(@as(i32, 1), captured.total_count);
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.REJECTED_BY_SAMPLES_LIMIT, captured.last_reason);
}

test "sample_rejected: listener change is 1 per event even when poll change would be higher" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;

    var captured = DDS.SampleRejectedStatus{};
    const listener = DDS.DataReaderListener{ .ptr = &captured, .vtable = &dr_rejected_vtable };

    const dw = fx.makeWriter();
    _ = fx.makeReader(dr_qos, listener, DDS.SAMPLE_REJECTED_STATUS);

    try write(dw, NIL_KEY); // accepted
    try write(dw, NIL_KEY); // rejected #1 → listener fires, captured.total_count_change = 1
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
    try write(dw, NIL_KEY); // rejected #2 → listener fires again, captured.total_count_change = 1
    try testing.expectEqual(@as(i32, 2), captured.total_count);
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
}

test "sample_rejected: max_samples_per_instance limit" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples_per_instance = 1;

    const dw = fx.makeWriter();
    const dr = fx.makeReader(dr_qos, nil.nil_dr_listener, 0);

    // Two writes for the same instance (NIL_KEY → same instance handle).
    try write(dw, NIL_KEY); // accepted
    try write(dw, NIL_KEY); // rejected — per-instance limit

    var s = DDS.SampleRejectedStatus{};
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.REJECTED_BY_SAMPLES_PER_INSTANCE_LIMIT, s.last_reason);
}

test "sample_rejected: max_instances limit" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.resource_limits.max_instances = 1;

    const dw = fx.makeWriter();
    const dr = fx.makeReader(dr_qos, nil.nil_dr_listener, 0);

    // First instance (key=0x01): accepted.
    try write(dw, makeKey(0x01));
    // Second instance (key=0x02): rejected — instance limit.
    try write(dw, makeKey(0x02));

    var s = DDS.SampleRejectedStatus{};
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.REJECTED_BY_INSTANCE_LIMIT, s.last_reason);
}

test "sample_rejected: no rejection when limits are zero (unlimited)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Default QoS: all resource_limits are 0 = unlimited.
    const dw = fx.makeWriter();
    const dr = fx.makeReader(.{}, nil.nil_dr_listener, 0);

    try write(dw, NIL_KEY);
    try write(dw, NIL_KEY);
    try write(dw, NIL_KEY);

    var s = DDS.SampleRejectedStatus{};
    _ = dr.toDDSDataReader().vtable.get_sample_rejected_status(dr.toDDSDataReader().ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.NOT_REJECTED, s.last_reason);
}
