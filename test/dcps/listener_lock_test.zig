//! Listeners must never run while zzdds holds one of its own locks: a
//! listener may call back into its entity, its parent or its participant,
//! and every such call that needs the held lock would deadlock. Each test
//! here makes a listener do exactly that, on a path that used to hold the
//! lock (participant message dispatch, protocol reader delivery, discovery
//! QoS checks, reader loss, notify_datareaders). A regression hangs rather
//! than fails; the CI test timeout catches it.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = zzdds.ZZDDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

const testing = std.testing;

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return t.vtable.as_TopicDescription(t.ptr);
}

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
        const dp_w = factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("MatchTopic", "MatchType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("MatchTopic", "MatchType", .{}, null, 0);

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
};

const NIL_KEY: [16]u8 = std.mem.zeroes([16]u8);
const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x2a };

/// Calls that each need one of the locks a listener used to run under.
fn probeParticipant(dp: DDS.DomainParticipant) bool {
    return dp.lookup_topicdescription("MatchTopic").ptr != zzdds.dcps.NIL_PTR;
}
fn probeReader(dr: DDS.DataReader) usize {
    var handles = DDS.InstanceHandleSeq{};
    _ = dr.vtable.get_matched_publications(dr.ptr, &handles);
    defer if (handles._buffer) |b| testing.allocator.free(b[0..handles._maximum]);
    return handles._length;
}
fn probeWriter(dw: DDS.DataWriter) usize {
    var handles = DDS.InstanceHandleSeq{};
    _ = dw.vtable.get_matched_subscriptions(dw.ptr, &handles);
    defer if (handles._buffer) |b| testing.allocator.free(b[0..handles._maximum]);
    return handles._length;
}

// ── DATA delivery: participant.mu and the protocol reader's lock ────────────

const DataProbe = struct {
    dp: DDS.DomainParticipant,
    sub: DDS.Subscriber,
    dr: DDS.DataReader = undefined,
    calls: usize = 0,
    participant_ok: bool = false,
    subscriber_ok: bool = false,
    matched_seen: usize = 0,
};

fn dataProbeOnDataAvailable(p: *DataProbe, _: DDS.DataReader) void {
    p.calls += 1;
    p.participant_ok = probeParticipant(p.dp);
    p.subscriber_ok = p.sub.lookup_datareader("MatchTopic").ptr != zzdds.dcps.NIL_PTR;
    p.matched_seen = probeReader(p.dr);
}

test "on_data_available may call into its participant, subscriber and reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var probe = DataProbe{ .dp = fx.dp_r, .sub = fx.sub_r };
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, DDS.dataReaderListener(&probe, .{
        .on_data_available = dataProbeOnDataAvailable,
    }), DDS.DATA_AVAILABLE_STATUS);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);
    probe.dr = dr;
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));

    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD);
    try testing.expect(probe.calls >= 1);
    try testing.expect(probe.participant_ok);
    try testing.expect(probe.subscriber_ok);
    try testing.expectEqual(@as(usize, 1), probe.matched_seen);
}

// ── Discovery: incompatible QoS ─────────────────────────────────────────────

const IncompatProbe = struct {
    dp: DDS.DomainParticipant,
    calls: usize = 0,
    participant_ok: bool = false,
};

fn incompatReaderCb(p: *IncompatProbe, _: DDS.DataReader, _: DDS.RequestedIncompatibleQosStatus) void {
    p.calls += 1;
    p.participant_ok = probeParticipant(p.dp);
}
fn incompatWriterCb(p: *IncompatProbe, _: DDS.DataWriter, _: DDS.OfferedIncompatibleQosStatus) void {
    p.calls += 1;
    p.participant_ok = probeParticipant(p.dp);
}

test "incompatible-QoS listeners may call into their participant" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // RELIABLE requested, BEST_EFFORT offered: incompatible both ways round.
    var r_probe = IncompatProbe{ .dp = fx.dp_r };
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), dr_qos, DDS.dataReaderListener(&r_probe, .{
        .on_requested_incompatible_qos = incompatReaderCb,
    }), DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);

    var w_probe = IncompatProbe{ .dp = fx.dp_w };
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    const dw = fx.pub_w.create_datawriter(fx.topic_w, dw_qos, DDS.dataWriterListener(&w_probe, .{
        .on_offered_incompatible_qos = incompatWriterCb,
    }), DDS.OFFERED_INCOMPATIBLE_QOS_STATUS);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);

    try testing.expect(r_probe.calls >= 1 and r_probe.participant_ok);
    try testing.expect(w_probe.calls >= 1 and w_probe.participant_ok);
}

// ── Discovery: a remote reader is lost ──────────────────────────────────────

const LostProbe = struct {
    dp: DDS.DomainParticipant,
    dw: DDS.DataWriter = undefined,
    last_current: i32 = -1,
    participant_ok: bool = false,
    matched_seen: usize = 99,
};

fn lostProbeOnMatched(p: *LostProbe, _: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    p.last_current = status.current_count;
    p.participant_ok = probeParticipant(p.dp);
    p.matched_seen = probeWriter(p.dw);
}

test "on_publication_matched for a lost reader may call into its participant and writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var probe = LostProbe{ .dp = fx.dp_w };
    const dw = fx.pub_w.create_datawriter(fx.topic_w, .{}, DDS.dataWriterListener(&probe, .{
        .on_publication_matched = lostProbeOnMatched,
    }), DDS.PUBLICATION_MATCHED_STATUS);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);
    probe.dw = dw;

    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    try testing.expectEqual(@as(i32, 1), probe.last_current);
    _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);
    try testing.expectEqual(@as(i32, 0), probe.last_current);
    try testing.expect(probe.participant_ok);
    try testing.expectEqual(@as(usize, 0), probe.matched_seen);
}

// ── Subscriber::notify_datareaders ──────────────────────────────────────────

const NotifyProbe = struct {
    sub: DDS.Subscriber,
    calls: usize = 0,
    subscriber_ok: bool = false,
};

fn notifyProbeOnDataAvailable(p: *NotifyProbe, _: DDS.DataReader) void {
    p.calls += 1;
    p.subscriber_ok = p.sub.lookup_datareader("MatchTopic").ptr != zzdds.dcps.NIL_PTR;
}

test "listeners raised by notify_datareaders may call into their subscriber" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var probe = NotifyProbe{ .sub = fx.sub_r };
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, DDS.dataReaderListener(&probe, .{
        .on_data_available = notifyProbeOnDataAvailable,
    }), DDS.DATA_AVAILABLE_STATUS);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);

    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_r.vtable.notify_datareaders(fx.sub_r.ptr));
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expect(probe.subscriber_ok);
}

// ── ACKNACK: on_reliable_reader_ready ───────────────────────────────────────

const ReadyProbe = struct {
    dp: DDS.DomainParticipant,
    ready: bool = false,
    participant_ok: bool = false,
};

fn readyProbeOnReady(_: DDS.InstanceHandle_t, is_ready: bool, ld: ?*anyopaque) callconv(.c) void {
    const p: *ReadyProbe = @ptrCast(@alignCast(ld));
    if (!is_ready) return;
    p.participant_ok = probeParticipant(p.dp);
    p.ready = true;
}

test "on_reliable_reader_ready may call into its participant" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), dr_qos, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);

    var probe = ReadyProbe{ .dp = fx.dp_w };
    const zpub = zzdds.asZzddsPublisher(fx.pub_w) orelse return error.TestUnexpectedResult;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    // The handshake completes on an ACKNACK, which in-process delivery hands
    // to the participant synchronously, before create_datawriter_ex returns.
    const dw = zpub.create_datawriter_ex(fx.topic_w, dw_qos, .{
        .listener_data = &probe,
        .on_reliable_reader_ready = readyProbeOnReady,
    }, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);
    try testing.expect(probe.ready);
    try testing.expect(probe.participant_ok);
}

// ── Fan-out and discovery with more endpoints than one batch ────────────────

const MANY = 37; // more than two of the participant's fixed-size batches

test "fan-out without a target list reaches every reader exactly once" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var readers: [MANY]DDS.DataReader = undefined;
    for (&readers) |*r| r.* = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer for (readers) |r| {
        _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, r);
    };

    // The path taken when the fan-out list cannot be allocated.
    const dp: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(fx.dp_r.ptr));
    const Seen = struct {
        protos: std.AutoHashMapUnmanaged(usize, u32) = .empty,
        pub fn deliver(self: *@This(), t: zzdds.dcps.DomainParticipantImpl.PinnedReader) void {
            const gop = self.protos.getOrPut(testing.allocator, @intFromPtr(t.proto.ctx)) catch unreachable;
            gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
        }
    };
    var seen: Seen = .{};
    defer seen.protos.deinit(alloc);
    dp.dispatchToReadersBatched(null, &seen);

    try testing.expect(seen.protos.count() >= MANY);
    var it = seen.protos.valueIterator();
    while (it.next()) |n| try testing.expectEqual(@as(u32, 1), n.*);
}

const IncompatCount = struct {
    calls: usize = 0,
    fn cb(p: *IncompatCount, _: DDS.DataReader, _: DDS.RequestedIncompatibleQosStatus) void {
        p.calls += 1;
    }
};

test "every incompatible reader is notified once, however many there are" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var counts: [MANY]IncompatCount = @splat(.{});
    var readers: [MANY]DDS.DataReader = undefined;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    for (&readers, &counts) |*r, *c| r.* = fx.sub_r.create_datareader(topicDesc(fx.topic_r), dr_qos, DDS.dataReaderListener(c, .{
        .on_requested_incompatible_qos = IncompatCount.cb,
    }), DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS);
    defer for (readers) |r| {
        _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, r);
    };

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    const dw = fx.pub_w.create_datawriter(fx.topic_w, dw_qos, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);

    for (counts) |c| try testing.expectEqual(@as(usize, 1), c.calls);
}

const IncompatPolicies = struct {
    ids: [8]DDS.QosPolicyId_t = undefined,
    n: usize = 0,
    fn cb(p: *IncompatPolicies, _: DDS.DataReader, status: DDS.RequestedIncompatibleQosStatus) void {
        if (p.n < p.ids.len) p.ids[p.n] = status.last_policy_id;
        p.n += 1;
    }
};

test "a reader incompatible with several writers is told each policy" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Incompatible with a RELIABLE, TRANSIENT_LOCAL reader for different
    // reasons: one on reliability only, the other on durability only.
    var be_qos = DDS.DataWriterQos{};
    be_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    be_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dw_be = fx.pub_w.create_datawriter(fx.topic_w, be_qos, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_be);
    var vol_qos = DDS.DataWriterQos{};
    vol_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    vol_qos.durability.kind = .VOLATILE_DURABILITY_QOS;
    const dw_vol = fx.pub_w.create_datawriter(fx.topic_w, vol_qos, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_vol);

    // Both writers are already discovered: checked as the reader is created.
    var probe: IncompatPolicies = .{};
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), dr_qos, DDS.dataReaderListener(&probe, .{
        .on_requested_incompatible_qos = IncompatPolicies.cb,
    }), DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);

    // The first two come from the check made as the reader is created, one
    // per writer, each with its own policy. (Nothing after them is checked:
    // this test's in-process discovery then announces both writers again,
    // and an already-reported incompatible writer is currently reported
    // again.)
    try testing.expect(probe.n >= 2);
    const first = probe.ids[0..2];
    std.mem.sort(DDS.QosPolicyId_t, first, {}, std.sort.asc(DDS.QosPolicyId_t));
    try testing.expectEqualSlices(DDS.QosPolicyId_t, &.{ DDS.DURABILITY_QOS_POLICY_ID, DDS.RELIABILITY_QOS_POLICY_ID }, first);
}
