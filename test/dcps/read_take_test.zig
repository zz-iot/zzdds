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
        const dp_w = dpf_w.create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("RTTopic", "RTType", .{}, null, 0);

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
        const topic_r = dp_r.create_topic("RTTopic", "RTType", .{}, null, 0);

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
        const dr_raw = self.sub_r.create_datareader(topic_desc_r, dr_qos, null, 0);
        const dw_raw = self.pub_w.create_datawriter(self.topic_w, dw_qos, null, 0);
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
    try pair.dr.readRaw(&out1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
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
    try pair.dr.readRaw(&out1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
    try testing.expectEqual(@as(usize, 1), out1.items.len);
    try testing.expectEqual(DDS.NOT_READ_SAMPLE_STATE, out1.items[0].info.sample_state);

    // Second read with NOT_READ filter: the sample is now READ, so it is skipped.
    var out2: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out2);
    try pair.dr.readRaw(&out2, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
    try testing.expectEqual(@as(usize, 0), out2.items.len);

    // Second read with READ filter: the sample is now READ, so it matches.
    var out3: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &out3);
    try pair.dr.readRaw(&out3, DDS.READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
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
    try pair.dr.readRaw(&read_out, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 1, null, null);
    freeOut(alloc, &read_out);

    // takeFiltered with NOT_READ: should remove only the second sample.
    var take_out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer freeOut(alloc, &take_out);
    try pair.dr.takeFiltered(&take_out, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
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
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 2, null, null);
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
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.NEW_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
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
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ALIVE_INSTANCE_STATE, -1, null, null);
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
    try pair.dr.readRaw(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
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
    try pair.dr.takeFiltered(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// ── readNextInstanceRaw ───────────────────────────────────────────────────────

const KEY_A: [16]u8 = .{1} ++ .{0} ** 15;
const KEY_B: [16]u8 = .{2} ++ .{0} ** 15;

test "readNextInstanceRaw: returns one sample from the first instance" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);

    const s = pair.dr.readNextInstanceRaw(0);
    try testing.expect(s != null);
    defer alloc.free(s.?.data);
    try testing.expectEqualSlices(u8, &PAYLOAD, s.?.data);
}

test "readNextInstanceRaw: returns null when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    try testing.expect(pair.dr.readNextInstanceRaw(0) == null);
}

test "readNextInstanceRaw: iterates instances in handle order" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_B, &PAYLOAD);

    const ih_a = DataWriterImpl.registerInstanceRaw(KEY_A);
    const ih_b = DataWriterImpl.registerInstanceRaw(KEY_B);
    const first_ih = @min(ih_a, ih_b);
    const second_ih = @max(ih_a, ih_b);

    const s1 = pair.dr.readNextInstanceRaw(0);
    try testing.expect(s1 != null);
    defer alloc.free(s1.?.data);
    try testing.expectEqual(first_ih, s1.?.info.instance_handle);

    const s2 = pair.dr.readNextInstanceRaw(first_ih);
    try testing.expect(s2 != null);
    defer alloc.free(s2.?.data);
    try testing.expectEqual(second_ih, s2.?.info.instance_handle);

    try testing.expect(pair.dr.readNextInstanceRaw(second_ih) == null);
}

// ── getKeyValueRaw (reader) ───────────────────────────────────────────────────

test "getKeyValueRaw (reader): returns CDR payload for known alive instance" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);

    const ih = DataWriterImpl.registerInstanceRaw(KEY_A);
    const kv = pair.dr.getKeyValueRaw(ih);
    try testing.expect(kv != null);
    try testing.expectEqualSlices(u8, &PAYLOAD, kv.?);
}

test "getKeyValueRaw (reader): returns null for unknown handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    const unknown_ih: DDS.InstanceHandle_t = @bitCast(@as(u32, 0x7FFF_FFFE));
    try testing.expect(pair.dr.getKeyValueRaw(unknown_ih) == null);
}

// ── lookupInstance ────────────────────────────────────────────────────────────

test "lookupInstance: true for alive instance, false for unknown" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);

    const ih_a = DataWriterImpl.registerInstanceRaw(KEY_A);
    try testing.expect(pair.dr.lookupInstance(ih_a));
    try testing.expect(!pair.dr.lookupInstance(0x7FFF_FFFE));
}

// ── getKeyValueRaw (writer) ───────────────────────────────────────────────────

test "getKeyValueRaw (writer): returns CDR payload after alive write" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);

    const ih = DataWriterImpl.registerInstanceRaw(KEY_A);
    const kv = pair.dw.getKeyValueRaw(ih);
    try testing.expect(kv != null);
    try testing.expectEqualSlices(u8, &PAYLOAD, kv.?);
}

test "getKeyValueRaw (writer): returns null for handle with no prior write" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    const ih = DataWriterImpl.registerInstanceRaw(KEY_A);
    try testing.expect(pair.dw.getKeyValueRaw(ih) == null);
}

// ── takeWithReadConditionRaw / readWithReadConditionRaw ────────────────────────
//
// The raw path to what the OMG spec calls take_w_condition/read_w_condition
// (see zidl's roadmap / zzdds/idl/dcps.idl's DataReader comment). These wrap
// DataReaderImpl.takeFiltered/readRaw, pulling the state masks (and, for a
// QueryCondition, the query filter via ReadConditionImpl.owner_qc) off an
// arbitrary DDS.ReadCondition instead of requiring the caller to already know
// which masks to pass -- most of the mask-handling correctness itself is
// already covered by the takeFiltered/readRaw tests above; these focus on the
// new dispatch (does the right condition's state actually get used) and on
// query filtering being honored end-to-end through a real QueryCondition.

/// Query-filterable field: the last byte of PAYLOAD, overridable per write so
/// tests can distinguish "matching" from "non-matching" samples without a
/// real typed CDR struct.
fn writeTagged(dw: *DataWriterImpl, key: [16]u8, tag: u8) !void {
    var payload = PAYLOAD;
    payload[4] = tag;
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, key, &payload);
}

const TagField = struct {
    fn get(_: *anyopaque, payload: []const u8, field: []const u8, _: []u8) ?zzdds.dcps.filter.FilterValue {
        if (!std.mem.eql(u8, field, "tag")) return null;
        return .{ .int = payload[payload.len - 1] };
    }
    fn computeKeyHash(_: *anyopaque, _: []const u8) [16]u8 {
        return std.mem.zeroes([16]u8); // unused: these tests pass key hashes explicitly to writeRaw.
    }
};

fn freeOwned(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(zzdds.OwnedRawSample)) void {
    for (out.items) |s| s.deinit();
    out.deinit(alloc);
}

test "takeWithReadConditionRaw: plain ReadCondition applies its own state masks" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);
    try writeAlive(pair.dw);
    try writeAlive(pair.dw);

    const dr = pair.dr.toDDSDataReader();
    // Mark the first sample READ, leaving both in queue (mirrors the
    // existing "takeFiltered: removes only NOT_READ" test above).
    var read_out: std.ArrayListUnmanaged(TakenSample) = .empty;
    try pair.dr.readRaw(&read_out, DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 1, null, null);
    freeOut(alloc, &read_out);

    const rc = dr.create_readcondition(DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = dr.delete_readcondition(rc);

    var out: std.ArrayListUnmanaged(zzdds.OwnedRawSample) = .empty;
    defer freeOwned(alloc, &out);
    try zzdds.takeWithReadConditionRaw(dr, rc, &out, -1, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(DDS.NOT_READ_SAMPLE_STATE, out.items[0].info.sample_state);

    // The READ sample is still in queue -- only the NOT_READ one was taken.
    const remaining = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(remaining.data);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, remaining.info.sample_state);
}

test "takeWithReadConditionRaw: QueryCondition (owner_qc) applies its query filter" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    try testing.expect(zzdds.registerTypeSupport(fx.dp_r, "RTType", .{
        .ctx = undefined,
        .compute_key_hash = TagField.computeKeyHash,
        .get_field = TagField.get,
    }));
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const pair = fx.makeWriterReader(.{}, dr_qos);
    try writeTagged(pair.dw, KEY_A, 1);
    try writeTagged(pair.dw, KEY_B, 2);

    const dr = pair.dr.toDDSDataReader();
    var params = [_][*:0]const u8{"2"};
    var params_seq = DDS.StringSeq{ ._buffer = &params, ._length = 1, ._maximum = 1, ._release = false };
    const qc = dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "tag = %0", &params_seq);
    try testing.expect(qc.ptr != nil.NIL_PTR);
    const rc = qc.vtable.as_ReadCondition(qc.ptr);
    defer _ = dr.delete_readcondition(rc);

    var out: std.ArrayListUnmanaged(zzdds.OwnedRawSample) = .empty;
    defer freeOwned(alloc, &out);
    try zzdds.takeWithReadConditionRaw(dr, rc, &out, -1, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u8, 2), out.items[0].data[out.items[0].data.len - 1]);

    // The non-matching sample (tag=1) is still in queue.
    const remaining = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(remaining.data);
    try testing.expectEqual(@as(u8, 1), remaining.data[remaining.data.len - 1]);
}

test "readWithReadConditionRaw: non-destructive, matching sample remains for a later take" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});
    try writeAlive(pair.dw);

    const dr = pair.dr.toDDSDataReader();
    const rc = dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = dr.delete_readcondition(rc);

    var out: std.ArrayListUnmanaged(zzdds.OwnedRawSample) = .empty;
    defer freeOwned(alloc, &out);
    try zzdds.readWithReadConditionRaw(dr, rc, &out, -1, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    const taken = pair.dr.takeRaw() orelse return error.NoSample;
    defer alloc.free(taken.data);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, taken.info.sample_state);
}

// ── takeNextInstanceWithReadConditionRaw / readNextInstanceWithReadConditionRaw ─
//
// The raw path to take_next_instance_w_condition/read_next_instance_w_condition.
// Per spec §2.2.2.5.3.18-19, instance *selection* itself must be restricted to
// instances with a matching sample -- not just "the next instance with any
// sample," which is what plain takeNextInstanceRaw does. These tests target
// exactly that difference.

test "takeNextInstanceWithReadConditionRaw: instance selection skips a non-matching instance" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});

    // Instance A's only sample is marked READ (via a prior read); instance B's
    // sample is untouched (NOT_READ). A plain takeNextInstanceRaw(0) would
    // still select whichever instance has the smaller handle, regardless of
    // sample_state -- takeNextInstanceWithReadConditionRaw must skip an
    // instance whose only sample doesn't match the condition's own mask.
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_B, &PAYLOAD);
    const ih_a = DataWriterImpl.registerInstanceRaw(KEY_A);
    const ih_b = DataWriterImpl.registerInstanceRaw(KEY_B);
    const first_ih = @min(ih_a, ih_b);
    const excluded_ih = first_ih; // whichever instance sorts first gets excluded below.

    var mark_read: std.ArrayListUnmanaged(TakenSample) = .empty;
    try pair.dr.readNextInstanceFiltered(&mark_read, 0, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null);
    try testing.expectEqual(@as(usize, 1), mark_read.items.len);
    try testing.expectEqual(excluded_ih, mark_read.items[0].info.instance_handle);
    freeOut(alloc, &mark_read);

    const dr = pair.dr.toDDSDataReader();
    const rc = dr.create_readcondition(DDS.NOT_READ_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = dr.delete_readcondition(rc);

    var out: std.ArrayListUnmanaged(zzdds.OwnedRawSample) = .empty;
    defer freeOwned(alloc, &out);
    try zzdds.takeNextInstanceWithReadConditionRaw(dr, rc, 0, &out, -1, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    // Must have selected the OTHER instance (the one still NOT_READ), not
    // simply the smallest handle.
    try testing.expect(out.items[0].info.instance_handle != excluded_ih);
    try testing.expectEqual(DDS.NOT_READ_SAMPLE_STATE, out.items[0].info.sample_state);
}

test "readNextInstanceWithReadConditionRaw: non-destructive, sample remains for a later take" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader(.{}, .{});
    _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, KEY_A, &PAYLOAD);

    const dr = pair.dr.toDDSDataReader();
    const rc = dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = dr.delete_readcondition(rc);

    var out: std.ArrayListUnmanaged(zzdds.OwnedRawSample) = .empty;
    defer freeOwned(alloc, &out);
    try zzdds.readNextInstanceWithReadConditionRaw(dr, rc, 0, &out, -1, alloc);
    try testing.expectEqual(@as(usize, 1), out.items.len);

    const taken = pair.dr.takeNextInstanceRaw(0) orelse return error.NoSample;
    defer alloc.free(taken.data);
    try testing.expectEqual(DDS.READ_SAMPLE_STATE, taken.info.sample_state);
}
