//! Phase 32 instance lifecycle tests: SampleInfo fields, instance state machine,
//! dispose(), unregister(), and the autodispose_unregistered_instances QoS flag.
//!
//! Uses IntraProcessDelivery (synchronous, no pump) for deterministic delivery.

const std = @import("std");
const test_domain = @import("test_domain");
const ManualRuntime = @import("manual_runtime").ManualRuntime;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

const testing = std.testing;

// CDR encap header (little-endian) + one byte of payload.
const PAYLOAD: [5]u8 = .{ 0x00, 0x01, 0x00, 0x00, 0x42 };

// All-zeros key hash / instance handle for keyless topics.
const NIL_KEY: [16]u8 = std.mem.zeroes([16]u8);
const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;

// ── Fixture ───────────────────────────────────────────────────────────────────

const Fixture = struct {
    alloc: std.mem.Allocator,
    mr: *ManualRuntime,
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
        const mr = try std.heap.page_allocator.create(ManualRuntime);
        errdefer std.heap.page_allocator.destroy(mr);
        mr.init();
        errdefer mr.deinit();
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
        const dp_w = dpf_w.create_participant(test_domain.get(), .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("ILTopic", "ILType", .{}, null, 0);

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
        const dp_r = dpf_r.create_participant(test_domain.get(), .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("ILTopic", "ILType", .{}, null, 0);

        return .{
            .mr = mr,
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
        self.mr.settle();
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
        self.mr.deinit();
        std.heap.page_allocator.destroy(self.mr);
    }

    /// Delivers what was sent so far (a no-op on the default build).
    fn settle(self: *Fixture) void {
        self.mr.settle();
    }

    fn makeWriterReader(
        self: *Fixture,
        dw_qos: DDS.DataWriterQos,
        dr_qos: DDS.DataReaderQos,
    ) struct { dw: *DataWriterImpl, dr: *DataReaderImpl } {
        const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr_raw = self.sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
        const dw_raw = self.pub_w.create_datawriter(self.topic_w, dw_qos, null, 0);
        // Matching runs on the runtime too.
        self.mr.settle();
        return .{
            .dw = @ptrCast(@alignCast(dw_raw.ptr)),
            .dr = @ptrCast(@alignCast(dr_raw.ptr)),
        };
    }
};

fn writeAlive(dw: *DataWriterImpl) !void {
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_KEY, &PAYLOAD);
}

fn takeOne(dr: *DataReaderImpl) !zzdds.dcps.TakenSample {
    return dr.takeRaw() orelse error.NoSample;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "sample_info: first alive sample has NEW_VIEW, ALIVE, NOT_READ, valid_data" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});
    try writeAlive(pair.dw);
    fx.settle();

    const s = try takeOne(pair.dr);
    defer alloc.free(s.data);

    try testing.expectEqual(DDS.NOT_READ_SAMPLE_STATE, s.info.sample_state);
    try testing.expectEqual(DDS.NEW_VIEW_STATE, s.info.view_state);
    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, s.info.instance_state);
    try testing.expect(s.info.valid_data);
    try testing.expect(s.info.instance_handle != 0);
    try testing.expect(s.info.publication_handle != 0);
    try testing.expectEqualSlices(u8, &PAYLOAD, s.data);
}

test "sample_info: second alive sample has NOT_NEW_VIEW" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);
    fx.settle();

    const s1 = try takeOne(pair.dr);
    defer alloc.free(s1.data);
    const s2 = try takeOne(pair.dr);
    defer alloc.free(s2.data);

    try testing.expectEqual(DDS.NEW_VIEW_STATE, s1.info.view_state);
    try testing.expectEqual(DDS.NOT_NEW_VIEW_STATE, s2.info.view_state);
    // Both are ALIVE with valid data.
    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, s2.info.instance_state);
    try testing.expect(s2.info.valid_data);
    // Instance handles are stable across samples for the same instance.
    try testing.expectEqual(s1.info.instance_handle, s2.info.instance_handle);
}

test "sample_info: dispose delivers NOT_ALIVE_DISPOSED, valid_data=false" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});
    // Establish the instance.
    try writeAlive(pair.dw);
    fx.settle();
    const alive = try takeOne(pair.dr);
    defer alloc.free(alive.data);

    // Dispose the instance.
    try pair.dw.disposeRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();

    const disposed = try takeOne(pair.dr);
    defer alloc.free(disposed.data);

    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, disposed.info.instance_state);
    try testing.expect(!disposed.info.valid_data);
    try testing.expectEqual(DDS.NOT_NEW_VIEW_STATE, disposed.info.view_state);
    // Instance handle must be consistent.
    try testing.expectEqual(alive.info.instance_handle, disposed.info.instance_handle);
}

test "sample_info: alive after dispose gets NEW_VIEW (resurrection)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});
    try writeAlive(pair.dw);
    fx.settle();
    const s1 = try takeOne(pair.dr);
    defer alloc.free(s1.data);
    try pair.dw.disposeRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    const disposed = try takeOne(pair.dr);
    defer alloc.free(disposed.data);

    // Write again — instance resurrects, view_state resets to NEW_VIEW.
    try writeAlive(pair.dw);
    fx.settle();
    const resurrected = try takeOne(pair.dr);
    defer alloc.free(resurrected.data);

    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, resurrected.info.instance_state);
    try testing.expectEqual(DDS.NEW_VIEW_STATE, resurrected.info.view_state);
    try testing.expect(resurrected.info.valid_data);
    try testing.expectEqual(s1.info.instance_handle, resurrected.info.instance_handle);
}

test "sample_info: unregister (autodispose=false) delivers NOT_ALIVE_NO_WRITERS" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.writer_data_lifecycle.autodispose_unregistered_instances = false;
    const pair = fx.makeWriterReader(dw_qos, .{});

    try writeAlive(pair.dw);
    fx.settle();
    const alive = try takeOne(pair.dr);
    defer alloc.free(alive.data);

    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();

    const unreg = try takeOne(pair.dr);
    defer alloc.free(unreg.data);

    try testing.expectEqual(DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE, unreg.info.instance_state);
    try testing.expect(!unreg.info.valid_data);
    try testing.expectEqual(alive.info.instance_handle, unreg.info.instance_handle);
}

test "sample_info: unregister (autodispose=true) delivers NOT_ALIVE_DISPOSED" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.writer_data_lifecycle.autodispose_unregistered_instances = true;
    const pair = fx.makeWriterReader(dw_qos, .{});

    try writeAlive(pair.dw);
    fx.settle();
    const alive = try takeOne(pair.dr);
    defer alloc.free(alive.data);

    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();

    const unreg = try takeOne(pair.dr);
    defer alloc.free(unreg.data);

    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, unreg.info.instance_state);
    try testing.expect(!unreg.info.valid_data);
}

test "sample_info: source_timestamp is propagated from writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const pair = fx.makeWriterReader(.{}, .{});
    const ts = RtpsTimestamp{ .seconds = 1_700_000_000, .fraction = 0 };
    _ = try pair.dw.writeRaw(.alive, ts, NIL_KEY, &PAYLOAD);
    fx.settle();

    const s = try takeOne(pair.dr);
    defer alloc.free(s.data);

    try testing.expectEqual(@as(i32, 1_700_000_000), s.info.source_timestamp.sec);
}

test "registerInstance: a writer's instance has one handle; lookupInstance finds only registered ones" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    try testing.expectEqual(DDS.HANDLE_NIL, pair.dw.lookupInstance(NIL_KEY));
    const handle = pair.dw.registerInstance(NIL_KEY, &.{});
    try testing.expect(handle != DDS.HANDLE_NIL);
    try testing.expectEqual(handle, pair.dw.registerInstance(NIL_KEY, &.{}));
    try testing.expectEqual(handle, pair.dw.lookupInstance(NIL_KEY));

    // A write registers the instance it writes.
    var key = NIL_KEY;
    key[15] = 1;
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), key, &PAYLOAD);
    const written = pair.dw.lookupInstance(key);
    try testing.expect(written != DDS.HANDLE_NIL and written != handle);
}

test "unregister: a writer forgets the instance, which a later write registers anew" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    try writeAlive(pair.dw);
    const first = pair.dw.lookupInstance(NIL_KEY);
    try testing.expect(pair.dw.storedKey(first, &.{}) != null);

    // With autodispose_unregistered_instances, as without it.
    _ = try pair.dw.writeRaw(.not_alive_disposed_unregistered, RtpsTimestamp.now(), NIL_KEY, &.{});
    try testing.expectEqual(DDS.HANDLE_NIL, pair.dw.lookupInstance(NIL_KEY));
    try testing.expect(pair.dw.storedKey(first, &.{}) == null);

    try writeAlive(pair.dw);
    const second = pair.dw.lookupInstance(NIL_KEY);
    try testing.expect(second != DDS.HANDLE_NIL and second != first);
    _ = try pair.dw.writeRaw(.not_alive_unregistered, RtpsTimestamp.now(), NIL_KEY, &.{});
    try testing.expectEqual(DDS.HANDLE_NIL, pair.dw.lookupInstance(NIL_KEY));

    // A dispose alone keeps it.
    try writeAlive(pair.dw);
    const third = pair.dw.lookupInstance(NIL_KEY);
    _ = try pair.dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    try testing.expectEqual(third, pair.dw.lookupInstance(NIL_KEY));
}

test "max_instances: a writer holds at most that many instances, and an unregister frees room" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.resource_limits.max_instances = 2;
    const pair = fx.makeWriterReader(dw_qos, .{});

    var keys: [3][16]u8 = .{ NIL_KEY, NIL_KEY, NIL_KEY };
    for (&keys, 1..) |*k, i| k[15] = @intCast(i);
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), keys[0], &PAYLOAD);
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), keys[1], &PAYLOAD);
    try testing.expectError(error.OutOfResources, pair.dw.writeRaw(.alive, RtpsTimestamp.now(), keys[2], &PAYLOAD));
    try testing.expectEqual(DDS.HANDLE_NIL, pair.dw.registerInstance(keys[2], &.{}));
    // An instance already registered is still written.
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), keys[1], &PAYLOAD);

    _ = try pair.dw.writeRaw(.not_alive_disposed_unregistered, RtpsTimestamp.now(), keys[0], &.{});
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), keys[2], &PAYLOAD);
    try testing.expect(pair.dw.lookupInstance(keys[2]) != DDS.HANDLE_NIL);
}

// ── Reader instance reclamation (DDS 1.4 §2.2.3.22) ──────────────────────────

/// Takes every queued sample, freeing them, and returns the last.
fn takeAll(dr: *DataReaderImpl) !DDS.SampleInfo {
    var last: ?DDS.SampleInfo = null;
    while (dr.takeRaw()) |s| {
        dr.alloc.free(s.data);
        last = s.info;
    }
    return last orelse error.NoSample;
}

test "reclamation: a reader forgets an unregistered instance once its samples are taken" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.writer_data_lifecycle.autodispose_unregistered_instances = false;
    const pair = fx.makeWriterReader(dw_qos, .{});

    try writeAlive(pair.dw);
    fx.settle();
    const first = (try takeAll(pair.dr)).instance_handle;
    try writeAlive(pair.dw);
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    try testing.expectEqual(@as(u32, 1), pair.dr.instances.count());

    // Its samples still queued hold it; taking them lets it go.
    const unreg = try takeAll(pair.dr);
    try testing.expectEqual(DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE, unreg.instance_state);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
    try testing.expect(pair.dr.storedKey(first, &.{}) == null);

    // A later sample of its key starts a new instance.
    try writeAlive(pair.dw);
    fx.settle();
    const again = try takeAll(pair.dr);
    try testing.expect(again.instance_handle != first);
    try testing.expectEqual(DDS.NEW_VIEW_STATE, again.view_state);
    try testing.expectEqual(@as(i32, 0), again.no_writers_generation_count);
}

test "reclamation: a disposed instance is kept while its writer has it registered" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.writer_data_lifecycle.autodispose_unregistered_instances = true;
    const pair = fx.makeWriterReader(dw_qos, .{});

    try writeAlive(pair.dw);
    _ = try pair.dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    fx.settle();
    const disposed = try takeAll(pair.dr);
    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, disposed.instance_state);
    try testing.expectEqual(@as(u32, 1), pair.dr.instances.count());

    // Written again, it counts on from its disposal.
    try writeAlive(pair.dw);
    fx.settle();
    const alive = try takeAll(pair.dr);
    try testing.expectEqual(disposed.instance_handle, alive.instance_handle);
    try testing.expectEqual(@as(i32, 1), alive.disposed_generation_count);

    // An unregister under autodispose arrives as dispose and unregister:
    // disposed, and no longer registered, so forgotten once taken.
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    const unreg = try takeAll(pair.dr);
    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, unreg.instance_state);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
}

test "reclamation: a reader that first hears of an instance by a dispose keeps it while its writer has it" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Written alive before the (VOLATILE) reader exists, so the reader's
    // first change of it is the dispose.
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));
    try writeAlive(dw);
    fx.settle();
    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    const dr_raw = fx.sub_r.create_datareader(topic_desc_r, .{}, null, 0);
    const dr: *DataReaderImpl = @ptrCast(@alignCast(dr_raw.ptr));
    fx.settle();

    _ = try dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    fx.settle();
    const disposed = try takeAll(dr);
    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, disposed.instance_state);
    try testing.expectEqual(@as(u32, 1), dr.instances.count());

    try writeAlive(dw);
    fx.settle();
    const alive = try takeAll(dr);
    try testing.expectEqual(disposed.instance_handle, alive.instance_handle);
    try testing.expectEqual(@as(i32, 1), alive.disposed_generation_count);
}

test "reclamation: an unregister the reader rejects leaves the writer's registration" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples_per_instance = 1;
    const pair = fx.makeWriterReader(.{}, dr_qos);

    // The unregister finds the instance's one sample slot taken.
    try writeAlive(pair.dw);
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    const alive = try takeAll(pair.dr);
    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, alive.instance_state);
    try testing.expectEqual(@as(?DDS.InstanceHandle_t, alive.instance_handle), pair.dr.lookupInstance(NIL_KEY));

    // So losing the writer still ends the instance, and then it goes.
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, pair.dw.toDDSDataWriter()));
    fx.settle();
    const no_writers = try takeAll(pair.dr);
    try testing.expectEqual(DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE, no_writers.instance_state);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
}

test "reclamation: under exclusive ownership, a weaker writer's dropped unregister ends its registration" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    var strong_qos = DDS.DataWriterQos{};
    strong_qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    strong_qos.ownership_strength.value = 10;
    strong_qos.writer_data_lifecycle.autodispose_unregistered_instances = false;
    const pair = fx.makeWriterReader(strong_qos, dr_qos);
    var weak_qos = strong_qos;
    weak_qos.ownership_strength.value = 1;
    const weak_raw = fx.pub_w.create_datawriter(fx.topic_w, weak_qos, null, 0);
    const weak: *DataWriterImpl = @ptrCast(@alignCast(weak_raw.ptr));
    fx.settle();

    // The strong writer owns the instance, so the weak one's write and
    // unregister are dropped.
    try writeAlive(pair.dw);
    try writeAlive(weak);
    try weak.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    const last = try takeAll(pair.dr);
    try testing.expectEqual(DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE, last.instance_state);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
}

test "reclamation: a reader forgets the instances of a writer it loses" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    var key_b = NIL_KEY;
    key_b[15] = 1;
    // A disposed instance and an alive one.
    try writeAlive(pair.dw);
    _ = try pair.dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), key_b, &PAYLOAD);
    fx.settle();
    _ = try takeAll(pair.dr);
    try testing.expectEqual(@as(u32, 2), pair.dr.instances.count());

    // The disposed one goes with the writer; the alive one gets a
    // NOT_ALIVE_NO_WRITERS sample, and goes once that is taken.
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, pair.dw.toDDSDataWriter()));
    fx.settle();
    try testing.expectEqual(@as(u32, 1), pair.dr.instances.count());
    const no_writers = try takeAll(pair.dr);
    try testing.expectEqual(DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE, no_writers.instance_state);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
}

test "max_instances: a reader rejects a new instance beyond it, until one is forgotten" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.resource_limits.max_instances = 1;
    const pair = fx.makeWriterReader(.{}, dr_qos);

    var key_b = NIL_KEY;
    key_b[15] = 1;
    try writeAlive(pair.dw);
    fx.settle();
    _ = try takeAll(pair.dr);

    // The first instance is alive and registered, so taking its sample
    // leaves it held.
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), key_b, &PAYLOAD);
    fx.settle();
    try testing.expectError(error.NoSample, takeAll(pair.dr));
    var rejected = DDS.SampleRejectedStatus{};
    _ = pair.dr.toDDSDataReader().vtable.get_sample_rejected_status(pair.dr.toDDSDataReader().ptr, &rejected);
    try testing.expectEqual(@as(i32, 1), rejected.total_count);
    try testing.expectEqual(DDS.SampleRejectedStatusKind.REJECTED_BY_INSTANCE_LIMIT, rejected.last_reason);
    try testing.expectEqual(DDS.HANDLE_NIL, rejected.last_instance_handle);

    // Unregistered and taken, it is forgotten, which makes room.
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    _ = try takeAll(pair.dr);
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), key_b, &PAYLOAD);
    fx.settle();
    const b = try takeAll(pair.dr);
    try testing.expect(b.valid_data);
}

// ── READER_DATA_LIFECYCLE autopurge ──────────────────────────────────────────
//
// The reader's timers run on the manual runtime's clock, which the tests move
// and then check, as qos_runtime_test's DEADLINE tests do.

fn checkReaderTimers(fx: *Fixture) void {
    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(fx.dp_r.ptr));
    dp_impl.checkTimers();
    fx.settle();
}

const ONE_SECOND: DDS.Duration_t = .{ .sec = 1, .nanosec = 0 };

test "autopurge: a NOT_ALIVE_NO_WRITERS instance's untaken samples go after its delay, and it is forgotten" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const mc = fx.mr.manualClock();
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.writer_data_lifecycle.autodispose_unregistered_instances = false;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reader_data_lifecycle.autopurge_nowriter_samples_delay = ONE_SECOND;
    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeAlive(pair.dw);
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    try testing.expectEqual(@as(usize, 2), pair.dr.pending.items.len);

    mc.advance(std.time.ns_per_s - 1);
    checkReaderTimers(&fx);
    try testing.expectEqual(@as(usize, 2), pair.dr.pending.items.len);

    mc.advance(1);
    checkReaderTimers(&fx);
    try testing.expectEqual(@as(usize, 0), pair.dr.pending.items.len);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
    try testing.expect(pair.dr.takeRaw() == null);
}

test "autopurge: a disposed instance's samples go after its delay, and a registered one is kept" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const mc = fx.mr.manualClock();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reader_data_lifecycle.autopurge_disposed_samples_delay = ONE_SECOND;
    const pair = fx.makeWriterReader(.{}, dr_qos);

    try writeAlive(pair.dw);
    _ = try pair.dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    fx.settle();
    try testing.expectEqual(@as(usize, 2), pair.dr.pending.items.len);

    mc.advance(std.time.ns_per_s);
    checkReaderTimers(&fx);
    try testing.expect(pair.dr.takeRaw() == null);
    // Its writer still has it registered, so it is kept, and its generation
    // counts carry on.
    try testing.expectEqual(@as(u32, 1), pair.dr.instances.count());
    try writeAlive(pair.dw);
    fx.settle();
    const alive = try takeAll(pair.dr);
    try testing.expectEqual(@as(i32, 1), alive.disposed_generation_count);
}

test "autopurge: an instance alive again before its delay keeps its samples" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const mc = fx.mr.manualClock();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reader_data_lifecycle.autopurge_disposed_samples_delay = ONE_SECOND;
    const pair = fx.makeWriterReader(.{}, dr_qos);

    _ = try pair.dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    fx.settle();
    mc.advance(std.time.ns_per_s / 2);
    try writeAlive(pair.dw);
    fx.settle();
    mc.advance(std.time.ns_per_s);
    checkReaderTimers(&fx);
    try testing.expectEqual(@as(usize, 2), pair.dr.pending.items.len);
}

test "autopurge: zero and infinite delays never purge, and set_qos can start one" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const mc = fx.mr.manualClock();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reader_data_lifecycle.autopurge_disposed_samples_delay = .{
        .sec = DDS.DURATION_INFINITE_SEC,
        .nanosec = DDS.DURATION_INFINITE_NSEC,
    };
    const pair = fx.makeWriterReader(.{}, dr_qos);

    _ = try pair.dw.writeRaw(.not_alive_disposed, RtpsTimestamp.now(), NIL_KEY, &.{});
    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_KEY);
    fx.settle();
    mc.advance(3600 * std.time.ns_per_s);
    checkReaderTimers(&fx);
    try testing.expectEqual(@as(usize, 1), pair.dr.pending.items.len);

    // The delay counts from when the instance became not alive.
    const dr = pair.dr.toDDSDataReader();
    var qos = DDS.DataReaderQos{};
    defer qos.deinit(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_qos(dr.ptr, &qos));
    qos.reader_data_lifecycle.autopurge_disposed_samples_delay = ONE_SECOND;
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.set_qos(dr.ptr, &qos));
    checkReaderTimers(&fx);
    try testing.expectEqual(@as(usize, 0), pair.dr.pending.items.len);
    try testing.expectEqual(@as(u32, 0), pair.dr.instances.count());
}

// ── Keyless topic, end-to-end via a real on_data_available listener ─────────
//
// Everything above this point already writes with NIL_KEY, but always with
// the *same* PAYLOAD and always drains via direct takeRaw() polling — never
// varying content, and never through a real DataReaderListener. Neither
// actually exercises the DDS 1.4 §2.2.2.1 guarantee this file's tests are
// implicitly relying on: "If no key is provided, the data set associated
// with the Topic is restricted to a single instance" — i.e. that *varying*
// content on a keyless topic still resolves to one instance, not one
// instance per distinct payload. This test writes three different payloads
// and confirms that invariant end-to-end through the same
// listener-driven on_data_available path a real subscriber uses (matching
// zzdds-examples' zig/hello_world), not just the isolated registerInstance
// mechanism above.

const KeylessListenerState = struct {
    dr: *DataReaderImpl = undefined,
    alloc: std.mem.Allocator,
    // Last payload byte of each delivered sample, in delivery order.
    payloads: std.ArrayListUnmanaged(u8) = .empty,
    handles: std.ArrayListUnmanaged(DDS.InstanceHandle_t) = .empty,

    fn deinit(self: *@This()) void {
        self.payloads.deinit(self.alloc);
        self.handles.deinit(self.alloc);
    }
};

fn onKeylessDataAvailable(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
    const state: *KeylessListenerState = @ptrCast(@alignCast(ld.?));
    while (state.dr.takeRaw()) |s| {
        defer state.alloc.free(s.data);
        if (!s.info.valid_data) continue;
        state.payloads.append(state.alloc, s.data[s.data.len - 1]) catch unreachable;
        state.handles.append(state.alloc, s.info.instance_handle) catch unreachable;
    }
}

test "keyless topic: varying-content alive samples are one instance, delivered in order via on_data_available" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var state = KeylessListenerState{ .alloc = alloc };
    defer state.deinit();

    const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(fx.topic_r.ptr))).toTopicDescription();
    const dr_raw = fx.sub_r.create_datareader(topic_desc_r, dr_qos, .{
        .listener_data = &state,
        .on_data_available = onKeylessDataAvailable,
    }, DDS.DATA_AVAILABLE_STATUS);
    state.dr = @ptrCast(@alignCast(dr_raw.ptr));

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));

    // Same NIL_KEY on every write, but three *different* payloads -- per DDS
    // 1.4 §2.2.2.1 a keyless Topic is exactly one instance regardless of
    // content, so all three must land on the same instance_handle, not three
    // different ones.
    var payload1 = PAYLOAD;
    payload1[4] = 0x10;
    var payload2 = PAYLOAD;
    payload2[4] = 0x20;
    var payload3 = PAYLOAD;
    payload3[4] = 0x30;
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_KEY, &payload1);
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_KEY, &payload2);
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_KEY, &payload3);
    fx.settle();

    // Delivered in write order, via the listener, not by polling.
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30 }, state.payloads.items);

    // All one instance, despite varying content.
    try testing.expectEqual(@as(usize, 3), state.handles.items.len);
    try testing.expectEqual(state.handles.items[0], state.handles.items[1]);
    try testing.expectEqual(state.handles.items[1], state.handles.items[2]);
    try testing.expect(state.handles.items[0] != 0);
}
