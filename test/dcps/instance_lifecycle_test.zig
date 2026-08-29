//! Phase 32 instance lifecycle tests: SampleInfo fields, instance state machine,
//! dispose(), unregister(), and the autodispose_unregistered_instances QoS flag.
//!
//! Uses IntraProcessDelivery (synchronous, no pump) for deterministic delivery.

const std = @import("std");
const test_domain = @import("test_domain");
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

const testing = std.testing;

// CDR encap header (little-endian) + one byte of payload.
const PAYLOAD: [5]u8 = .{ 0x00, 0x01, 0x00, 0x00, 0x42 };

// All-zeros key hash / instance handle for keyless topics.
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
    const alive = try takeOne(pair.dr);
    defer alloc.free(alive.data);

    // Dispose the instance.
    try pair.dw.disposeRaw(RtpsTimestamp.now(), NIL_IH, NIL_KEY);

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
    const s1 = try takeOne(pair.dr);
    defer alloc.free(s1.data);
    try pair.dw.disposeRaw(RtpsTimestamp.now(), NIL_IH, NIL_KEY);
    const disposed = try takeOne(pair.dr);
    defer alloc.free(disposed.data);

    // Write again — instance resurrects, view_state resets to NEW_VIEW.
    try writeAlive(pair.dw);
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
    const alive = try takeOne(pair.dr);
    defer alloc.free(alive.data);

    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_IH, NIL_KEY);

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
    const alive = try takeOne(pair.dr);
    defer alloc.free(alive.data);

    try pair.dw.unregisterRaw(RtpsTimestamp.now(), NIL_IH, NIL_KEY);

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
    _ = try pair.dw.writeRaw(.alive, ts, NIL_IH, NIL_KEY, &PAYLOAD);

    const s = try takeOne(pair.dr);
    defer alloc.free(s.data);

    try testing.expectEqual(@as(i32, 1_700_000_000), s.info.source_timestamp.sec);
}

test "registerInstanceRaw: returns stable nonzero handle for keyless topic" {
    const handle = DataWriterImpl.registerInstanceRaw(NIL_KEY);
    try testing.expect(handle != 0);
    // Deterministic: same key → same handle.
    try testing.expectEqual(handle, DataWriterImpl.registerInstanceRaw(NIL_KEY));
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
// zzdds-examples' zig/hello_world), not just the isolated registerInstanceRaw
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
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &payload1);
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &payload2);
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &payload3);

    // Delivered in write order, via the listener, not by polling.
    try testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x30 }, state.payloads.items);

    // All one instance, despite varying content.
    try testing.expectEqual(@as(usize, 3), state.handles.items.len);
    try testing.expectEqual(state.handles.items[0], state.handles.items[1]);
    try testing.expectEqual(state.handles.items[1], state.handles.items[2]);
    try testing.expect(state.handles.items[0] != 0);
}
