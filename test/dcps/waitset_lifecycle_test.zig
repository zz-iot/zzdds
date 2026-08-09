//! Regression coverage for condition/entity lifecycle safety around WaitSet
//! attachment — see docs/roadmap.md's WaitSet/condition-example plan.
//!
//! Before this fix, StatusCondition/ReadCondition/QueryCondition were freed
//! unconditionally by their owning entity/reader's teardown path with no
//! regard for whether a WaitSet still had them attached, and WaitSetImpl's
//! own deinit() never unregistered itself from conditions it still held —
//! either direction left a dangling pointer live in the other object. These
//! tests use real entities (via IntraProcessDelivery, matching
//! intraprocess_test.zig's harness) so the real writer.zig/reader.zig
//! teardown paths run, not just the isolated waitset.zig unit stubs already
//! covered by waitset_test.zig.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const WaitSetImpl = zzdds.dcps.WaitSetImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

const DURATION_ZERO: DDS.Duration_t = .{ .sec = 0, .nanosec = 0 };
const DURATION_1S: DDS.Duration_t = .{ .sec = 1, .nanosec = 0 };

// ── Fixture (mirrors intraprocess_test.zig's Fixture) ──────────────────────────

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

    fn init(alloc: std.mem.Allocator, topic_name: [:0]const u8, type_name: [:0]const u8) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(
            alloc,
            t_w.transport(),
            d_w.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_w.deinit();
        const dpf_w = factory_w.toDDSFactory();
        const dp_w = dpf_w.create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic(topic_name, type_name, .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(
            alloc,
            t_r.transport(),
            d_r.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_r.deinit();
        const dpf_r = factory_r.toDDSFactory();
        const dp_r = dpf_r.create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic(topic_name, type_name, .{}, null, 0);

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

    fn makeWriterReader(
        self: *Fixture,
        dw_qos: DDS.DataWriterQos,
        dr_qos: DDS.DataReaderQos,
    ) struct { dw: DDS.DataWriter, dr: DDS.DataReader } {
        const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
        const dw = self.pub_w.create_datawriter(self.topic_w, dw_qos, null, 0);
        return .{ .dw = dw, .dr = dr };
    }
};

// zidl's Zig backend generates the `as_Condition` vtable slot for these
// synthetic base-interface upcasts but not a `pub fn as_Condition(self)`
// convenience wrapper on the struct itself (pre-existing gap, unrelated to
// this test's own subject matter) — call through the vtable directly.
fn statusAsCondition(sc: DDS.StatusCondition) DDS.Condition {
    return sc.vtable.as_Condition(sc.ptr);
}
fn readAsCondition(rc: DDS.ReadCondition) DDS.Condition {
    return rc.vtable.as_Condition(rc.ptr);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "WaitSet: StatusCondition survives DataWriter deletion while still attached" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "WSLifecycleTopic1", "WSLifecycleType1");
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});

    const ws = try WaitSetImpl.init(alloc);
    defer ws.deinit();

    const sc = pair.dw.get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(statusAsCondition(sc)));

    // Delete the writer without detaching the condition first — this used to
    // free the StatusCondition unconditionally, leaving `ws` with a dangling
    // `conditions` entry.
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.delete_datawriter(pair.dw));

    // Both of these touch `ws.conditions`; neither should crash or leak.
    var seq = DDS.ConditionSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().get_conditions(&seq));
    try testing.expectEqual(@as(u32, 0), seq._length);
    if (seq._release) {
        if (seq._buffer) |b| alloc.free(b[0..seq._maximum]);
    }

    // detach_condition() on the now-invalid handle correctly reports it's no
    // longer attached (it was already removed by the writer's own teardown).
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, ws.toDDSWaitSet().detach_condition(statusAsCondition(sc)));
}

test "WaitSet: ReadCondition survives DataReader deletion while still attached" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "WSLifecycleTopic2", "WSLifecycleType2");
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});

    const ws = try WaitSetImpl.init(alloc);
    defer ws.deinit();

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(readAsCondition(rc)));

    // Delete the reader directly — never called delete_readcondition() on
    // `rc` first. Used to leave `ws` with a dangling `conditions` entry and
    // the reader's `data_notifiers` list pointing at a WaitSet with no way
    // to ever clean it up (the reader is gone by the time anyone would try).
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_r.delete_datareader(pair.dr));

    var seq = DDS.ConditionSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().get_conditions(&seq));
    try testing.expectEqual(@as(u32, 0), seq._length);
    if (seq._release) {
        if (seq._buffer) |b| alloc.free(b[0..seq._maximum]);
    }
}

test "WaitSet: deinit while GuardCondition/StatusCondition/ReadCondition of real entities still attached" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "WSLifecycleTopic3", "WSLifecycleType3");
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});

    const gc = try zzdds.dcps.GuardConditionImpl.init(alloc);
    defer gc.deinit();
    const sc = pair.dw.get_statuscondition();
    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = fx.sub_r.delete_datareader(pair.dr);

    const ws = try WaitSetImpl.init(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(statusAsCondition(sc)));
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(readAsCondition(rc)));

    // WaitSet goes away first, with all three still attached — each
    // condition's own WakeupList must not be left pointing at freed memory.
    ws.deinit();

    // Triggering/reading each condition post-WaitSet-teardown must not touch
    // the freed WaitSet (this is exactly what a stale WakeupList entry would
    // do) — the assertions below are just "must not crash"; DebugAllocator
    // catches any resulting use-after-free/double-free.
    try testing.expectEqual(DDS.RETCODE_OK, gc.toDDSGuardCondition().set_trigger_value(true));
    _ = statusAsCondition(sc).get_trigger_value();
    _ = readAsCondition(rc).get_trigger_value();
}

test "WaitSet: concurrent wait() vs. attach/delete-entity/detach cycling doesn't race" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc, "WSLifecycleTopic4", "WSLifecycleType4");
    defer fx.deinit();

    const ws = try WaitSetImpl.init(alloc);
    defer ws.deinit();

    const gc = try zzdds.dcps.GuardConditionImpl.init(alloc);
    defer gc.deinit();
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));

    const Ctx = struct {
        ws: *WaitSetImpl,
        stop: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var seq = DDS.ConditionSeq{};
            while (!self.stop.load(.acquire)) {
                _ = self.ws.toDDSWaitSet().wait(&seq, DURATION_ZERO);
                if (seq._release) {
                    if (seq._buffer) |b| self.ws.alloc.free(b[0..seq._maximum]);
                    seq = .{};
                }
            }
        }
    };
    var ctx = Ctx{ .ws = ws };
    const t = try std.Thread.spawn(.{}, Ctx.run, .{&ctx});

    // Main thread: repeatedly create+attach+delete a real writer's
    // StatusCondition while the background thread is concurrently calling
    // wait()/touching ws.conditions — this is the exact "app thread and
    // middleware thread both touching the same conditions/entities"
    // scenario this hardening pass targeted.
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const pair = fx.makeWriterReader(.{}, .{});
        const sc = pair.dw.get_statuscondition();
        _ = ws.toDDSWaitSet().attach_condition(statusAsCondition(sc));
        _ = fx.pub_w.delete_datawriter(pair.dw);
        _ = fx.sub_r.delete_datareader(pair.dr);
    }

    ctx.stop.store(true, .release);
    t.join();
}
