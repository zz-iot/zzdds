//! Status claim boundary for listeners
//! (docs/design/concurrency/listeners.md#status-ordering-requirements).
//!
//! A listener claims a plain status, snapshotting it and resetting its
//! change fields, at one boundary under the entity's lock; the callback
//! runs after it. So an update that lands while the callback runs stays
//! pending for the next getter or callback: callback return cannot clear
//! it. Each test injects that update from inside the callback, after
//! hiding the listener (mask 0) so the update is not claimed by a nested
//! callback of its own, then checks a getter still sees it.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const ManualClock = zzdds.util.time.ManualClock;
const history_mod = zzdds.rtps.history;
const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;
const NIL_KEY = std.mem.zeroes([16]u8);
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x42 };

fn write(dw: *DataWriterImpl) !void {
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD);
}

// ── Injecting listener ────────────────────────────────────────────────────────

/// `listener_data` of an injecting callback: counts calls, records the
/// first call's change count, and on the first call hides the listener and
/// runs `inject`.
const Injector = struct {
    mask: *DDS.StatusMask,
    inject: *const fn (*Injector) void,
    target: *anyopaque,
    writer: ?*DataWriterImpl = null,
    calls: u32 = 0,
    first_change: i32 = 0,
};

fn injectingCb(comptime Status: type, comptime change_field: []const u8) fn (*anyopaque, *const Status, ?*anyopaque) callconv(.c) void {
    return struct {
        fn cb(_: *anyopaque, s: *const Status, ld: ?*anyopaque) callconv(.c) void {
            const inj: *Injector = @ptrCast(@alignCast(ld));
            inj.calls += 1;
            if (inj.calls > 1) return;
            inj.first_change = @field(s, change_field);
            @atomicStore(DDS.StatusMask, inj.mask, 0, .monotonic);
            inj.inject(inj);
        }
    }.cb;
}

fn reader(inj: *Injector) *DataReaderImpl {
    return @ptrCast(@alignCast(inj.target));
}

fn writerOf(inj: *Injector) *DataWriterImpl {
    return @ptrCast(@alignCast(inj.target));
}

// ── Fixture ───────────────────────────────────────────────────────────────────

/// Writer and reader participants over IntraProcessDelivery (synchronous
/// delivery), sharing a ManualClock, with no Publisher, Subscriber or
/// participant listeners: a hidden endpoint listener leaves nothing to
/// claim an injected update.
const Fixture = struct {
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

    fn init(alloc: std.mem.Allocator, clock: zzdds.util.time.Clock) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        var config = zzdds.config.Config{};
        config.participant.timer_clock_name = "manual";

        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, config);
        errdefer factory_w.deinit();
        try factory_w.clock_registry.register("manual", clock);
        const dp_w = factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_ = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("ClaimTopic", "ClaimType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, config);
        errdefer factory_r.deinit();
        try factory_r.clock_registry.register("manual", clock);
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const sub_ = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("ClaimTopic", "ClaimType", .{}, null, 0);

        return .{
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

    fn makeWriter(self: *Fixture, qos: DDS.DataWriterQos, listener: ?DDS.DataWriterListener, mask: DDS.StatusMask) *DataWriterImpl {
        const dw = self.pub_.create_datawriter(self.topic_w, qos, listener, mask);
        return @ptrCast(@alignCast(dw.ptr));
    }

    fn makeReader(self: *Fixture, qos: DDS.DataReaderQos, listener: ?DDS.DataReaderListener, mask: DDS.StatusMask) *DataReaderImpl {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_.create_datareader(td, qos, listener, mask);
        return @ptrCast(@alignCast(dr.ptr));
    }
};

fn drStatusChanges(dr: *DataReaderImpl) DDS.StatusMask {
    const dds = dr.toDDSDataReader();
    return dds.vtable.get_status_changes(dds.ptr);
}

fn dwStatusChanges(dw: *DataWriterImpl) DDS.StatusMask {
    const dds = dw.toDDSDataWriter();
    return dds.vtable.get_status_changes(dds.ptr);
}

// ── DataReader ────────────────────────────────────────────────────────────────

test "status claim: SUBSCRIPTION_MATCHED changed during the callback stays pending, zero net included" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{
        .mask = undefined,
        .target = undefined,
        .inject = struct {
            // A match and an unmatch: current_count nets to zero, total_count
            // does not, and the status is changed either way.
            fn f(i: *Injector) void {
                reader(i).recordSubscriptionMatched(0x200, true);
                reader(i).recordSubscriptionMatched(0x200, false);
            }
        }.f,
    };
    const dr = fx.makeReader(.{}, .{ .listener_data = &inj, .on_subscription_matched = injectingCb(DDS.SubscriptionMatchedStatus, "total_count_change") }, DDS.SUBSCRIPTION_MATCHED_STATUS);
    inj.mask = &dr.listener_mask;
    inj.target = dr;

    dr.recordSubscriptionMatched(0x100, true);
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(drStatusChanges(dr) & DDS.SUBSCRIPTION_MATCHED_STATUS != 0);
    const dds = dr.toDDSDataReader();
    var st: DDS.SubscriptionMatchedStatus = undefined;
    _ = dds.vtable.get_subscription_matched_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
    try testing.expectEqual(@as(i32, 1), st.current_count);
    try testing.expectEqual(@as(i32, 0), st.current_count_change);
    try testing.expect(drStatusChanges(dr) & DDS.SUBSCRIPTION_MATCHED_STATUS == 0);
}

test "status claim: REQUESTED_INCOMPATIBLE_QOS changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            DataReaderImpl.notifyIncompatibleQos(reader(i), 9);
        }
    }.f };
    const dr = fx.makeReader(.{}, .{ .listener_data = &inj, .on_requested_incompatible_qos = injectingCb(DDS.RequestedIncompatibleQosStatus, "total_count_change") }, DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS);
    inj.mask = &dr.listener_mask;
    inj.target = dr;

    DataReaderImpl.notifyIncompatibleQos(dr, 7);
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(drStatusChanges(dr) & DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS != 0);
    const dds = dr.toDDSDataReader();
    var st: DDS.RequestedIncompatibleQosStatus = undefined;
    _ = dds.vtable.get_requested_incompatible_qos_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
    try testing.expectEqual(@as(i32, 9), st.last_policy_id);
}

test "status claim: SAMPLE_LOST changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            reader(i).notifySampleLost(2);
        }
    }.f };
    const dr = fx.makeReader(.{}, .{ .listener_data = &inj, .on_sample_lost = injectingCb(DDS.SampleLostStatus, "total_count_change") }, DDS.SAMPLE_LOST_STATUS);
    inj.mask = &dr.listener_mask;
    inj.target = dr;

    dr.notifySampleLost(3);
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 3), inj.first_change);

    try testing.expect(drStatusChanges(dr) & DDS.SAMPLE_LOST_STATUS != 0);
    const dds = dr.toDDSDataReader();
    var st: DDS.SampleLostStatus = undefined;
    _ = dds.vtable.get_sample_lost_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 5), st.total_count);
    try testing.expectEqual(@as(i32, 2), st.total_count_change);
}

test "status claim: REQUESTED_DEADLINE_MISSED changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            reader(i).notifyDeadlineMissed();
        }
    }.f };
    const dr = fx.makeReader(.{}, .{ .listener_data = &inj, .on_requested_deadline_missed = injectingCb(DDS.RequestedDeadlineMissedStatus, "total_count_change") }, DDS.REQUESTED_DEADLINE_MISSED_STATUS);
    inj.mask = &dr.listener_mask;
    inj.target = dr;

    dr.notifyDeadlineMissed();
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(drStatusChanges(dr) & DDS.REQUESTED_DEADLINE_MISSED_STATUS != 0);
    const dds = dr.toDDSDataReader();
    var st: DDS.RequestedDeadlineMissedStatus = undefined;
    _ = dds.vtable.get_requested_deadline_missed_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
}

test "status claim: SAMPLE_REJECTED changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    // The injected update is another rejected sample, which is counted
    // when it is received and dispatched from the reader's flush.
    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            write(i.writer.?) catch unreachable;
        }
    }.f };
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 1;
    const dw = fx.makeWriter(.{}, null, 0);
    const dr = fx.makeReader(dr_qos, .{ .listener_data = &inj, .on_sample_rejected = injectingCb(DDS.SampleRejectedStatus, "total_count_change") }, DDS.SAMPLE_REJECTED_STATUS);
    inj.mask = &dr.listener_mask;
    inj.target = dr;
    inj.writer = dw;

    try write(dw); // accepted
    try write(dw); // rejected: the callback runs and rejects another
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(drStatusChanges(dr) & DDS.SAMPLE_REJECTED_STATUS != 0);
    const dds = dr.toDDSDataReader();
    var st: DDS.SampleRejectedStatus = undefined;
    _ = dds.vtable.get_sample_rejected_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
}

test "status claim: LIVELINESS_CHANGED changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    // The outer update is the writer's lease expiring; the injected one is
    // the writer coming back alive by writing.
    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            write(i.writer.?) catch unreachable;
        }
    }.f };
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .AUTOMATIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    const dw = fx.makeWriter(dw_qos, null, 0);
    const dr = fx.makeReader(.{}, .{ .listener_data = &inj, .on_liveliness_changed = injectingCb(DDS.LivelinessChangedStatus, "not_alive_count_change") }, 0);
    inj.target = dr;
    inj.writer = dw;
    // Consume the match's own change (alive 0 -> 1) before listening.
    const dds = dr.toDDSDataReader();
    var st: DDS.LivelinessChangedStatus = undefined;
    _ = dds.vtable.get_liveliness_changed_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 1), st.alive_count);
    @atomicStore(DDS.StatusMask, &dr.listener_mask, DDS.LIVELINESS_CHANGED_STATUS, .monotonic);
    inj.mask = &dr.listener_mask;

    mc.advance(1_000_000_000);
    const dp_r: *DomainParticipantImpl = @ptrCast(@alignCast(fx.dp_r.ptr));
    dp_r.checkTimers();
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(drStatusChanges(dr) & DDS.LIVELINESS_CHANGED_STATUS != 0);
    _ = dds.vtable.get_liveliness_changed_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 1), st.alive_count);
    try testing.expectEqual(@as(i32, 1), st.alive_count_change);
    try testing.expectEqual(@as(i32, 0), st.not_alive_count);
    try testing.expectEqual(@as(i32, -1), st.not_alive_count_change);
}

// ── DataWriter ────────────────────────────────────────────────────────────────

test "status claim: PUBLICATION_MATCHED changed during the callback stays pending, zero net included" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            writerOf(i).recordPublicationMatched(0x200, true);
            writerOf(i).recordPublicationMatched(0x200, false);
        }
    }.f };
    const dw = fx.makeWriter(.{}, .{ .listener_data = &inj, .on_publication_matched = injectingCb(DDS.PublicationMatchedStatus, "total_count_change") }, DDS.PUBLICATION_MATCHED_STATUS);
    inj.mask = &dw.listener_mask;
    inj.target = dw;

    dw.recordPublicationMatched(0x100, true);
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(dwStatusChanges(dw) & DDS.PUBLICATION_MATCHED_STATUS != 0);
    const dds = dw.toDDSDataWriter();
    var st: DDS.PublicationMatchedStatus = undefined;
    _ = dds.vtable.get_publication_matched_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
    try testing.expectEqual(@as(i32, 1), st.current_count);
    try testing.expectEqual(@as(i32, 0), st.current_count_change);
}

test "status claim: OFFERED_INCOMPATIBLE_QOS changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            DataWriterImpl.notifyIncompatibleQos(writerOf(i), 9);
        }
    }.f };
    const dw = fx.makeWriter(.{}, .{ .listener_data = &inj, .on_offered_incompatible_qos = injectingCb(DDS.OfferedIncompatibleQosStatus, "total_count_change") }, DDS.OFFERED_INCOMPATIBLE_QOS_STATUS);
    inj.mask = &dw.listener_mask;
    inj.target = dw;

    DataWriterImpl.notifyIncompatibleQos(dw, 7);
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(dwStatusChanges(dw) & DDS.OFFERED_INCOMPATIBLE_QOS_STATUS != 0);
    const dds = dw.toDDSDataWriter();
    var st: DDS.OfferedIncompatibleQosStatus = undefined;
    _ = dds.vtable.get_offered_incompatible_qos_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
    try testing.expectEqual(@as(i32, 9), st.last_policy_id);
}

test "status claim: OFFERED_DEADLINE_MISSED changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            writerOf(i).notifyDeadlineMissed();
        }
    }.f };
    const dw = fx.makeWriter(.{}, .{ .listener_data = &inj, .on_offered_deadline_missed = injectingCb(DDS.OfferedDeadlineMissedStatus, "total_count_change") }, DDS.OFFERED_DEADLINE_MISSED_STATUS);
    inj.mask = &dw.listener_mask;
    inj.target = dw;

    dw.notifyDeadlineMissed();
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(dwStatusChanges(dw) & DDS.OFFERED_DEADLINE_MISSED_STATUS != 0);
    const dds = dw.toDDSDataWriter();
    var st: DDS.OfferedDeadlineMissedStatus = undefined;
    _ = dds.vtable.get_offered_deadline_missed_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
}

test "status claim: LIVELINESS_LOST changed during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var inj = Injector{ .mask = undefined, .target = undefined, .inject = struct {
        fn f(i: *Injector) void {
            writerOf(i).notifyLivelinessLost();
        }
    }.f };
    const dw = fx.makeWriter(.{}, .{ .listener_data = &inj, .on_liveliness_lost = injectingCb(DDS.LivelinessLostStatus, "total_count_change") }, DDS.LIVELINESS_LOST_STATUS);
    inj.mask = &dw.listener_mask;
    inj.target = dw;

    dw.notifyLivelinessLost();
    try testing.expectEqual(@as(u32, 1), inj.calls);
    try testing.expectEqual(@as(i32, 1), inj.first_change);

    try testing.expect(dwStatusChanges(dw) & DDS.LIVELINESS_LOST_STATUS != 0);
    const dds = dw.toDDSDataWriter();
    var st: DDS.LivelinessLostStatus = undefined;
    _ = dds.vtable.get_liveliness_lost_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
}

// ── Claim at dispatch ─────────────────────────────────────────────────────────

fn dwCountMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*u32, @ptrCast(@alignCast(ld))).* += 1;
}

test "status claim: a status a listener received is consumed, a later one is not" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var calls: u32 = 0;
    const dw = fx.makeWriter(.{}, .{ .listener_data = &calls, .on_publication_matched = dwCountMatched }, DDS.PUBLICATION_MATCHED_STATUS);
    dw.recordPublicationMatched(0x100, true);
    try testing.expectEqual(@as(u32, 1), calls);
    try testing.expect(dwStatusChanges(dw) & DDS.PUBLICATION_MATCHED_STATUS == 0);

    // With the listener masked out the change stays for the getter.
    @atomicStore(DDS.StatusMask, &dw.listener_mask, 0, .monotonic);
    dw.recordPublicationMatched(0x200, true);
    try testing.expectEqual(@as(u32, 1), calls);
    try testing.expect(dwStatusChanges(dw) & DDS.PUBLICATION_MATCHED_STATUS != 0);
    const dds = dw.toDDSDataWriter();
    var st: DDS.PublicationMatchedStatus = undefined;
    _ = dds.vtable.get_publication_matched_status(dds.ptr, &st);
    try testing.expectEqual(@as(i32, 1), st.total_count_change);
    try testing.expectEqual(@as(i32, 0x200), st.last_subscription_handle);
}

// ── DATA_AVAILABLE ────────────────────────────────────────────────────────────
//
// DDS 1.4 §2.2.4.2.2: every read or take resets DATA_AVAILABLE, and so does
// on_data_available, claimed like a plain status
// (docs/design/concurrency/listeners.md#reader-data-available-reset).

fn freeTaken(dr: *DataReaderImpl, samples: []const zzdds.dcps.TakenSample) void {
    for (samples) |s| dr.alloc.free(s.data);
}

fn readAll(dr: *DataReaderImpl, out: *std.ArrayListUnmanaged(zzdds.dcps.TakenSample)) !void {
    try dr.readRaw(out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
}

/// Keeps every sample written to the fixture's one (NIL) instance.
fn keepAllReaderQos() DDS.DataReaderQos {
    var qos = DDS.DataReaderQos{};
    qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    return qos;
}

fn countDataAvailable(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
    @as(*u32, @ptrCast(@alignCast(ld))).* += 1;
}

test "DATA_AVAILABLE: a read resets it, though the samples stay" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    const dw = fx.makeWriter(.{}, null, 0);
    const dr = fx.makeReader(keepAllReaderQos(), null, 0);
    try write(dw);
    try write(dw);
    try testing.expect(drStatusChanges(dr) & DDS.DATA_AVAILABLE_STATUS != 0);

    var out: std.ArrayListUnmanaged(zzdds.dcps.TakenSample) = .empty;
    defer out.deinit(testing.allocator);
    defer freeTaken(dr, out.items);
    try readAll(dr, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expect(drStatusChanges(dr) & DDS.DATA_AVAILABLE_STATUS == 0);

    // A new sample sets it again.
    try write(dw);
    try testing.expect(drStatusChanges(dr) & DDS.DATA_AVAILABLE_STATUS != 0);
}

test "DATA_AVAILABLE: a take resets it while samples remain" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    const dw = fx.makeWriter(.{}, null, 0);
    const dr = fx.makeReader(keepAllReaderQos(), null, 0);
    try write(dw);
    try write(dw);

    const taken = dr.takeRaw() orelse return error.TestExpectedNonNull;
    dr.alloc.free(taken.data);
    try testing.expect(drStatusChanges(dr) & DDS.DATA_AVAILABLE_STATUS == 0);
    const rest = dr.takeRaw() orelse return error.TestExpectedNonNull;
    dr.alloc.free(rest.data);
}

test "DATA_AVAILABLE: on_data_available resets it, and data arriving during the callback stays pending" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    const Probe = struct {
        var dr: *DataReaderImpl = undefined;
        var dw: *DataWriterImpl = undefined;
        var calls: u32 = 0;
        var set_in_callback: bool = true;

        fn cb(_: *anyopaque, _: ?*anyopaque) callconv(.c) void {
            calls += 1;
            if (calls > 1) return;
            set_in_callback = drStatusChanges(dr) & DDS.DATA_AVAILABLE_STATUS != 0;
            // Hidden, so the arrival below is not claimed by a nested call.
            @atomicStore(DDS.StatusMask, &dr.listener_mask, 0, .monotonic);
            write(dw) catch unreachable;
        }
    };
    Probe.calls = 0;
    Probe.dw = fx.makeWriter(.{}, null, 0);
    Probe.dr = fx.makeReader(.{}, .{ .on_data_available = Probe.cb }, DDS.DATA_AVAILABLE_STATUS);

    try write(Probe.dw);
    try testing.expectEqual(@as(u32, 1), Probe.calls);
    try testing.expect(!Probe.set_in_callback);
    try testing.expect(drStatusChanges(Probe.dr) & DDS.DATA_AVAILABLE_STATUS != 0);
}

test "DATA_AVAILABLE: a listener whose change was consumed does not run" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    var calls: u32 = 0;
    const listener = DDS.DataReaderListener{ .listener_data = &calls, .on_data_available = countDataAvailable };
    const dw = fx.makeWriter(.{}, null, 0);
    const dr = fx.makeReader(keepAllReaderQos(), listener, DDS.DATA_AVAILABLE_STATUS);

    // The arrival's callback claims the change, leaving nothing for
    // notify_datareaders.
    try write(dw);
    try testing.expectEqual(@as(u32, 1), calls);
    _ = fx.sub_.notify_datareaders();
    try testing.expectEqual(@as(u32, 1), calls);

    // Two more arrive unclaimed; a take consumes the change first, so
    // neither notify_datareaders nor the catch-up of a reinstalled listener
    // runs, though a sample remains.
    @atomicStore(DDS.StatusMask, &dr.listener_mask, 0, .monotonic);
    try write(dw);
    try write(dw);
    const taken = dr.takeRaw() orelse return error.TestExpectedNonNull;
    dr.alloc.free(taken.data);
    @atomicStore(DDS.StatusMask, &dr.listener_mask, DDS.DATA_AVAILABLE_STATUS, .monotonic);
    _ = fx.sub_.notify_datareaders();
    const dds = dr.toDDSDataReader();
    _ = dds.vtable.set_listener(dds.ptr, &listener, DDS.DATA_AVAILABLE_STATUS);
    try testing.expectEqual(@as(u32, 1), calls);
}

test "DATA_AVAILABLE: begin_access that cannot queue on_data_available leaves it changed" {
    var mc = ManualClock.init(0);
    var fx = try Fixture.init(testing.allocator, mc.clock());
    defer fx.deinit();

    // PRESENTATION must be offered as requested for the pair to match.
    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation.coherent_access = true;
    const pub_ = fx.dp_w.create_publisher(pub_qos, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(pub_.create_datawriter(fx.topic_w, .{}, null, 0).ptr));
    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation.coherent_access = true;
    const sub = fx.dp_r.create_subscriber(sub_qos, null, 0);
    var calls: u32 = 0;
    const listener = DDS.DataReaderListener{ .listener_data = &calls, .on_data_available = countDataAvailable };
    const td = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    // Hidden while the sample arrives, so only begin_access raises it.
    const dds_dr = sub.create_datareader(td, keepAllReaderQos(), listener, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dds_dr.ptr));
    try write(dw);
    try testing.expectEqual(@as(u32, 0), calls);
    @atomicStore(DDS.StatusMask, &dr.listener_mask, DDS.DATA_AVAILABLE_STATUS, .monotonic);

    // The Subscriber cannot allocate the callback's entry.
    const impl: *zzdds.dcps.SubscriberImpl = @ptrCast(@alignCast(sub.ptr));
    const saved = impl.alloc;
    impl.alloc = testing.failing_allocator;
    _ = sub.begin_access();
    impl.alloc = saved;
    try testing.expectEqual(@as(u32, 0), calls);
    try testing.expect(drStatusChanges(dr) & DDS.DATA_AVAILABLE_STATUS != 0);

    // So a later notification still runs it.
    _ = sub.notify_datareaders();
    try testing.expectEqual(@as(u32, 1), calls);
    _ = sub.end_access();
}
