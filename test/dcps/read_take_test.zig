//! Phase 32 read/take semantics tests: readRaw(), takeFiltered(), state masks.
//!
//! Uses IntraProcessDelivery (synchronous, no pump) for deterministic delivery.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;
const TakenSample = zzdds.dcps.TakenSample;

const testing = std.testing;

const PAYLOAD: [5]u8 = .{ 0x00, 0x01, 0x00, 0x00, 0x42 };
const NIL_KEY: [16]u8 = std.mem.zeroes([16]u8);
const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;

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
        const dp_w = dpf_w.create_participant(0, .{}, nil.nil_dp_listener, 0);
        const pub_w = dp_w.vtable.create_publisher(dp_w.ptr, .{}, nil.nil_pub_listener, 0);
        const topic_w = dp_w.vtable.create_topic(dp_w.ptr, "RTTopic", "RTType", .{}, nil.nil_topic_listener, 0);

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
        const dp_r = dpf_r.create_participant(0, .{}, nil.nil_dp_listener, 0);
        const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
        const topic_r = dp_r.vtable.create_topic(dp_r.ptr, "RTTopic", "RTType", .{}, nil.nil_topic_listener, 0);

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
    ) struct { dw: *DataWriterImpl, dr: *DataReaderImpl } {
        const topic_desc_r = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr_raw = self.sub_r.vtable.create_datareader(self.sub_r.ptr, topic_desc_r, dr_qos, nil.nil_dr_listener, 0);
        const dw_raw = self.pub_w.vtable.create_datawriter(self.pub_w.ptr, self.topic_w, dw_qos, nil.nil_dw_listener, 0);
        return .{
            .dw = @ptrCast(@alignCast(dw_raw.ptr)),
            .dr = @ptrCast(@alignCast(dr_raw.ptr)),
        };
    }
};

fn writeAlive(dw: *DataWriterImpl) !void {
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD);
}

fn freeOut(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(TakenSample)) void {
    for (out.items) |s| alloc.free(s.data);
    out.deinit(alloc);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "read: non-destructive, sample remains in queue for subsequent take" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});
    try writeAlive(pair.dw);

    var out1: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out1);
    try pair.dr.readRaw(&out1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), out1.items.len);

    // Sample still in queue — take it.
    const taken = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(taken.data);
    try testing.expectEqualSlices(u8, &PAYLOAD, taken.data);
}

test "read: marks sample as READ_SAMPLE_STATE in queue" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});
    try writeAlive(pair.dw);

    // First read: sample is NOT_READ; clone reflects that.
    var out1: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out1);
    try pair.dr.readRaw(&out1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), out1.items.len);
    try testing.expectEqual(DDS.NOT_READ_SAMPLE_STATE, out1.items[0].info.sample_state);

    // Second read with NOT_READ filter: the sample is now READ, so it is skipped.
    var out2: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out2);
    try pair.dr.readRaw(&out2, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 0), out2.items.len);

    // Second read with READ filter: the sample is now READ, so it matches.
    var out3: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out3);
    try pair.dr.readRaw(&out3, DDS.READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), out3.items.len);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, out3.items[0].info.sample_state);
}

test "takeFiltered: removes only NOT_READ samples when filter applied" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);

    // Read first sample (marks it READ, leaves both in queue).
    var read_out: std.ArrayListUnmanaged(TakenSample) = .empty;
    try pair.dr.readRaw(&read_out, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 1, null);
    freeOut(alloc, &read_out);

    // takeFiltered with NOT_READ: should remove only the second sample.
    var take_out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &take_out);
    try pair.dr.takeFiltered(&take_out, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), take_out.items.len);
    try testing.expectEqual(DDS.NOT_READ_SAMPLE_STATE, take_out.items[0].info.sample_state);

    // The READ sample is still in queue.
    const remaining = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(remaining.data);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, remaining.info.sample_state);

    // Queue is now empty.
    try testing.expectEqual(@as(?TakenSample, null), pair.dr.takeRaw());
}

test "takeFiltered: max_samples limits how many are removed" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);

    var out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out);
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 2, null);
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // One sample remains.
    const s = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(s.data);
    try testing.expectEqual(@as(?TakenSample, null), pair.dr.takeRaw());
}

test "takeFiltered: view_state mask selects NEW_VIEW only" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);

    // Two samples: first has NEW_VIEW, second has NOT_NEW_VIEW.
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);

    var out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out);
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.NEW_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(DDS.NEW_VIEW_STATE, out.items[0].info.view_state);

    // The NOT_NEW_VIEW sample remains.
    const s = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(s.data);
    try testing.expectEqual(DDS.NOT_NEW_VIEW_STATE, s.info.view_state);
}

test "takeFiltered: instance_state mask selects ALIVE only" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);

    try writeAlive(pair.dw);
    // Drain the alive sample first so queue is at a known state, then dispose.
    const alive = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(alive.data);

    // Write alive, dispose — queue has alive + disposed.
    try writeAlive(pair.dw);
    try pair.dw.disposeRaw(RtpsTimestamp.now(), NIL_IH, NIL_KEY);

    // takeFiltered with ALIVE only.
    var out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out);
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ALIVE_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(DDS.ALIVE_INSTANCE_STATE, out.items[0].info.instance_state);
    try testing.expect(out.items[0].info.valid_data);

    // The disposed sample remains.
    const disposed = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(disposed.data);
    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, disposed.info.instance_state);
    try testing.expect(!disposed.info.valid_data);
}

test "readRaw: ANY masks returns all samples" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);

    var out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out);
    try pair.dr.readRaw(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    // Queue still has 2 samples.
    try testing.expect(pair.dr.hasPendingData());
}

test "takeFiltered: empty queue returns zero results" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    var out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out);
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
