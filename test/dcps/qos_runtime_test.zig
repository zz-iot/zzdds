//! Phase 31 QoS runtime behaviour tests: RESOURCE_LIMITS, OWNERSHIP, TIME_BASED_FILTER,
//! DEADLINE, LIVELINESS.
//!
//! Uses IntraProcessDelivery (synchronous, no pump or sleep) so every assertion
//! is deterministic. DEADLINE and LIVELINESS tests additionally use ManualClock
//! for fully deterministic timer control.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const ManualClock = zzdds.util.time.ManualClock;
const history_mod = zzdds.rtps.history;

const testing = std.testing;

const PAYLOAD_A = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAA };
const PAYLOAD_B = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xBB };
const PAYLOAD_C = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xCC };

// ── Helpers ───────────────────────────────────────────────────────────────────

fn writeRaw(dw: *DataWriterImpl, payload: []const u8) !void {
    _ = try dw.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        payload,
    );
}

fn pendingCount(dr: *DataReaderImpl) usize {
    dr.mu.lock();
    defer dr.mu.unlock();
    return dr.pending.items.len;
}

fn drainSamples(alloc: std.mem.Allocator, dr: *DataReaderImpl) ![][]u8 {
    var samples: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (samples.items) |s| alloc.free(s);
        samples.deinit(alloc);
    }
    while (dr.takeRaw()) |sample| try samples.append(alloc, sample.data);
    return samples.toOwnedSlice(alloc);
}

// ── Simple two-party fixture ──────────────────────────────────────────────────

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
        const topic_w = dp_w.vtable.create_topic(dp_w.ptr, "QosTopic", "QosType", .{}, nil.nil_topic_listener, 0);

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
        const topic_r = dp_r.vtable.create_topic(dp_r.ptr, "QosTopic", "QosType", .{}, nil.nil_topic_listener, 0);

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

// ── RESOURCE_LIMITS tests ─────────────────────────────────────────────────────

test "resource_limits: writer BEST_EFFORT — returns OutOfResources when cache full" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dw_qos.resource_limits.max_samples = 2;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    // First two writes succeed.
    try writeRaw(pair.dw, &PAYLOAD_A);
    try writeRaw(pair.dw, &PAYLOAD_B);

    // Third write hits the limit (cache still holds A and B for BEST_EFFORT).
    const err = pair.dw.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        &PAYLOAD_C,
    );
    try testing.expectError(error.OutOfResources, err);
}

test "resource_limits: writer KEEP_LAST — limit never hit because cache depth evicts" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // KEEP_LAST depth=1, max_samples=2 (depth < max_samples → cache never exceeds 1).
    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dw_qos.history.depth = 1;
    dw_qos.resource_limits.max_samples = 2;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    // All writes succeed: KEEP_LAST evicts oldest before we check the limit.
    try writeRaw(pair.dw, &PAYLOAD_A);
    try writeRaw(pair.dw, &PAYLOAD_B);
    try writeRaw(pair.dw, &PAYLOAD_C);
}

test "resource_limits: reader — samples dropped when pending queue full" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 2; // reader accepts at most 2

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRaw(pair.dw, &PAYLOAD_A);
    try writeRaw(pair.dw, &PAYLOAD_B);
    try writeRaw(pair.dw, &PAYLOAD_C); // reader drops this one

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 2), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
    try testing.expectEqualSlices(u8, &PAYLOAD_B, samples[1]);
}

test "resource_limits: reader limit 0 (unlimited) — all samples accepted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    var dr_qos = DDS.DataReaderQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    dr_qos.resource_limits.max_samples = 0; // 0 = unlimited (generated default)

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRaw(pair.dw, &PAYLOAD_A);
    try writeRaw(pair.dw, &PAYLOAD_B);
    try writeRaw(pair.dw, &PAYLOAD_C);

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 3), samples.len);
}

// ── OWNERSHIP tests ───────────────────────────────────────────────────────────
//
// Two-writer fixture: writer A and writer B publish on the same topic; a single
// reader (EXCLUSIVE ownership) only accepts samples from the current owner.
//
// DirectDiscovery's synchronous matching guarantees the owner is elected before
// any write is attempted.

const OwnershipFixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    // Writer A (high strength)
    t_a: *zzdds.intraprocess.MemoryTransport,
    d_a: *zzdds.intraprocess.DirectDiscovery,
    factory_a: *DomainParticipantFactoryImpl,
    dp_a: DDS.DomainParticipant,
    pub_a: DDS.Publisher,
    topic_a: DDS.Topic,

    // Writer B (low strength)
    t_b: *zzdds.intraprocess.MemoryTransport,
    d_b: *zzdds.intraprocess.DirectDiscovery,
    factory_b: *DomainParticipantFactoryImpl,
    dp_b: DDS.DomainParticipant,
    pub_b: DDS.Publisher,
    topic_b: DDS.Topic,

    // Reader
    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !OwnershipFixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        const t_a = try delivery.newTransport();
        errdefer t_a.deinit();
        const d_a = try delivery.newDiscovery();
        errdefer d_a.deinit();
        const factory_a = try DomainParticipantFactoryImpl.init(
            alloc,
            t_a.transport(),
            d_a.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_a.deinit();
        const dp_a = factory_a.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const pub_a = dp_a.vtable.create_publisher(dp_a.ptr, .{}, nil.nil_pub_listener, 0);
        const topic_a = dp_a.vtable.create_topic(dp_a.ptr, "OwnTopic", "OwnType", .{}, nil.nil_topic_listener, 0);

        const t_b = try delivery.newTransport();
        errdefer t_b.deinit();
        const d_b = try delivery.newDiscovery();
        errdefer d_b.deinit();
        const factory_b = try DomainParticipantFactoryImpl.init(
            alloc,
            t_b.transport(),
            d_b.toDiscovery(),
            noop_security,
            .spec_random,
            .{},
        );
        errdefer factory_b.deinit();
        const dp_b = factory_b.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const pub_b = dp_b.vtable.create_publisher(dp_b.ptr, .{}, nil.nil_pub_listener, 0);
        const topic_b = dp_b.vtable.create_topic(dp_b.ptr, "OwnTopic", "OwnType", .{}, nil.nil_topic_listener, 0);

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
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
        const topic_r = dp_r.vtable.create_topic(dp_r.ptr, "OwnTopic", "OwnType", .{}, nil.nil_topic_listener, 0);

        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t_a = t_a,
            .d_a = d_a,
            .factory_a = factory_a,
            .dp_a = dp_a,
            .pub_a = pub_a,
            .topic_a = topic_a,
            .t_b = t_b,
            .d_b = d_b,
            .factory_b = factory_b,
            .dp_b = dp_b,
            .pub_b = pub_b,
            .topic_b = topic_b,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .sub_r = sub_r,
            .topic_r = topic_r,
        };
    }

    fn deinit(self: *OwnershipFixture) void {
        _ = self.factory_a.toDDSFactory().delete_participant(self.dp_a);
        _ = self.factory_b.toDDSFactory().delete_participant(self.dp_b);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_a.deinit();
        self.d_a.deinit();
        self.t_a.deinit();
        self.factory_b.deinit();
        self.d_b.deinit();
        self.t_b.deinit();
        self.factory_r.deinit();
        self.d_r.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }

    fn makeReader(self: *OwnershipFixture, dr_qos: DDS.DataReaderQos) *DataReaderImpl {
        const topic_desc = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr_raw = self.sub_r.vtable.create_datareader(self.sub_r.ptr, topic_desc, dr_qos, nil.nil_dr_listener, 0);
        return @ptrCast(@alignCast(dr_raw.ptr));
    }

    fn makeWriterA(self: *OwnershipFixture, dw_qos: DDS.DataWriterQos) *DataWriterImpl {
        const dw_raw = self.pub_a.vtable.create_datawriter(self.pub_a.ptr, self.topic_a, dw_qos, nil.nil_dw_listener, 0);
        return @ptrCast(@alignCast(dw_raw.ptr));
    }

    fn makeWriterB(self: *OwnershipFixture, dw_qos: DDS.DataWriterQos) *DataWriterImpl {
        const dw_raw = self.pub_b.vtable.create_datawriter(self.pub_b.ptr, self.topic_b, dw_qos, nil.nil_dw_listener, 0);
        return @ptrCast(@alignCast(dw_raw.ptr));
    }
};

test "ownership: SHARED — both writers deliver to reader" {
    const alloc = testing.allocator;
    var fx = try OwnershipFixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.ownership.kind = .SHARED_OWNERSHIP_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.ownership.kind = .SHARED_OWNERSHIP_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dr = fx.makeReader(dr_qos);
    const dw_a = fx.makeWriterA(dw_qos);
    const dw_b = fx.makeWriterB(dw_qos);

    try writeRaw(dw_a, &PAYLOAD_A);
    try writeRaw(dw_b, &PAYLOAD_B);

    const samples = try drainSamples(alloc, dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    // Both samples delivered with SHARED ownership.
    try testing.expectEqual(@as(usize, 2), samples.len);
}

test "ownership: EXCLUSIVE — only the highest-strength writer delivers" {
    const alloc = testing.allocator;
    var fx = try OwnershipFixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var dw_qos_a = DDS.DataWriterQos{};
    dw_qos_a.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos_a.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dw_qos_a.ownership_strength.value = 10;
    dw_qos_a.history.kind = .KEEP_ALL_HISTORY_QOS;

    var dw_qos_b = DDS.DataWriterQos{};
    dw_qos_b.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos_b.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dw_qos_b.ownership_strength.value = 5;
    dw_qos_b.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dr = fx.makeReader(dr_qos);
    // Create reader first so both writers match it synchronously on creation.
    const dw_a = fx.makeWriterA(dw_qos_a);
    const dw_b = fx.makeWriterB(dw_qos_b);

    try writeRaw(dw_a, &PAYLOAD_A); // from owner (strength 10) → delivered
    try writeRaw(dw_b, &PAYLOAD_B); // from non-owner (strength 5) → dropped

    const samples = try drainSamples(alloc, dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 1), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
}

test "ownership: EXCLUSIVE — sole writer becomes owner by default" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dw_qos.ownership_strength.value = 7;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRaw(pair.dw, &PAYLOAD_A);

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 1), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
}

test "ownership: EXCLUSIVE — owner transfer when current owner is removed" {
    const alloc = testing.allocator;
    var fx = try OwnershipFixture.init(alloc);
    defer fx.deinit();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var dw_qos_a = DDS.DataWriterQos{};
    dw_qos_a.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos_a.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dw_qos_a.ownership_strength.value = 10;
    dw_qos_a.history.kind = .KEEP_ALL_HISTORY_QOS;

    var dw_qos_b = DDS.DataWriterQos{};
    dw_qos_b.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dw_qos_b.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    dw_qos_b.ownership_strength.value = 5;
    dw_qos_b.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dr = fx.makeReader(dr_qos);
    const dw_a_raw = fx.pub_a.vtable.create_datawriter(fx.pub_a.ptr, fx.topic_a, dw_qos_a, nil.nil_dw_listener, 0);
    const dw_b = fx.makeWriterB(dw_qos_b);

    // A is owner (strength 10).  B is not.
    const dw_a: *DataWriterImpl = @ptrCast(@alignCast(dw_a_raw.ptr));
    try writeRaw(dw_a, &PAYLOAD_A); // delivered
    try writeRaw(dw_b, &PAYLOAD_B); // dropped

    // Remove writer A.  B should now become the owner.
    _ = fx.pub_a.vtable.delete_datawriter(fx.pub_a.ptr, dw_a_raw);

    try writeRaw(dw_b, &PAYLOAD_C); // now delivered (B is the new owner)

    const samples = try drainSamples(alloc, dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 2), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
    try testing.expectEqualSlices(u8, &PAYLOAD_C, samples[1]);
}

// ── TIME_BASED_FILTER tests ───────────────────────────────────────────────────
//
// Uses fixed source timestamps (seconds field of RtpsTimestamp) so tests are
// fully deterministic without real-time sleeps.

fn writeRawAt(dw: *DataWriterImpl, payload: []const u8, secs: u32) !void {
    _ = try dw.writeRaw(
        .alive,
        .{ .seconds = secs, .fraction = 0 },
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        payload,
    );
}

test "time_based_filter: zero separation (default) — all samples pass" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    // minimum_separation = 0 (default) → no filtering

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    try writeRawAt(pair.dw, &PAYLOAD_A, 0);
    try writeRawAt(pair.dw, &PAYLOAD_B, 0);
    try writeRawAt(pair.dw, &PAYLOAD_C, 0);

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 3), samples.len);
}

test "time_based_filter: samples within minimum_separation are suppressed" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.time_based_filter.minimum_separation = .{ .sec = 1, .nanosec = 0 };

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    // First sample always delivers; second is at same timestamp (< 1 s apart → drop).
    try writeRawAt(pair.dw, &PAYLOAD_A, 10);
    try writeRawAt(pair.dw, &PAYLOAD_B, 10);

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 1), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
}

test "time_based_filter: sample after minimum_separation is delivered" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.time_based_filter.minimum_separation = .{ .sec = 1, .nanosec = 0 };

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    // t=10: delivers; t=11: exactly 1 s later → also delivers.
    try writeRawAt(pair.dw, &PAYLOAD_A, 10);
    try writeRawAt(pair.dw, &PAYLOAD_B, 11);

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 2), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
    try testing.expectEqualSlices(u8, &PAYLOAD_B, samples[1]);
}

test "time_based_filter: multiple suppressions then delivery after window" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    dr_qos.time_based_filter.minimum_separation = .{ .sec = 2, .nanosec = 0 };

    const pair = fx.makeWriterReader(dw_qos, dr_qos);

    // t=0: delivers; t=1 and t=1: within 2s window → drop; t=3: ≥2s after t=0 → delivers.
    try writeRawAt(pair.dw, &PAYLOAD_A, 0); // delivers; window start = 0
    try writeRawAt(pair.dw, &PAYLOAD_B, 1); // 1s < 2s → drop
    try writeRawAt(pair.dw, &PAYLOAD_C, 1); // 1s < 2s → drop
    try writeRawAt(pair.dw, &PAYLOAD_A, 3); // 3s ≥ 2s → delivers

    const samples = try drainSamples(alloc, pair.dr);
    defer {
        for (samples) |s| alloc.free(s);
        alloc.free(samples);
    }

    try testing.expectEqual(@as(usize, 2), samples.len);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[0]);
    try testing.expectEqualSlices(u8, &PAYLOAD_A, samples[1]);
}

// ── DEADLINE and LIVELINESS tests ─────────────────────────────────────────────
//
// Uses ManualClock + checkTimers() for fully deterministic timer control.
// TimerFixture creates a single participant with a manual clock; tests inject
// the clock by registering it before create_participant().

// ── Timer listener helpers ────────────────────────────────────────────────────
// ctx is *i32; callback stores status.total_count there.

fn dwOnDeadlineMissed(ctx: *anyopaque, _: DDS.DataWriter, s: DDS.OfferedDeadlineMissedStatus) void {
    @as(*i32, @ptrCast(@alignCast(ctx))).* = s.total_count;
}
fn dwOnLivelinessLost(ctx: *anyopaque, _: DDS.DataWriter, s: DDS.LivelinessLostStatus) void {
    @as(*i32, @ptrCast(@alignCast(ctx))).* = s.total_count;
}
fn drOnDeadlineMissed(ctx: *anyopaque, _: DDS.DataReader, s: DDS.RequestedDeadlineMissedStatus) void {
    @as(*i32, @ptrCast(@alignCast(ctx))).* = s.total_count;
}
fn dwNoopDeadline(_: *anyopaque, _: DDS.DataWriter, _: DDS.OfferedDeadlineMissedStatus) void {}
fn dwNoopIncompat(_: *anyopaque, _: DDS.DataWriter, _: DDS.OfferedIncompatibleQosStatus) void {}
fn dwNoopLiveliness(_: *anyopaque, _: DDS.DataWriter, _: DDS.LivelinessLostStatus) void {}
fn dwNoopPubMatched(_: *anyopaque, _: DDS.DataWriter, _: DDS.PublicationMatchedStatus) void {}
fn dwNoopDeinit(_: *anyopaque) void {}
fn drNoopDeadline(_: *anyopaque, _: DDS.DataReader, _: DDS.RequestedDeadlineMissedStatus) void {}
fn drNoopIncompat(_: *anyopaque, _: DDS.DataReader, _: DDS.RequestedIncompatibleQosStatus) void {}
fn drNoopSampleRejected(_: *anyopaque, _: DDS.DataReader, _: DDS.SampleRejectedStatus) void {}
fn drNoopLivelinessChanged(_: *anyopaque, _: DDS.DataReader, _: DDS.LivelinessChangedStatus) void {}
fn drNoopDataAvail(_: *anyopaque, _: DDS.DataReader) void {}
fn drNoopSubMatched(_: *anyopaque, _: DDS.DataReader, _: DDS.SubscriptionMatchedStatus) void {}
fn drNoopSampleLost(_: *anyopaque, _: DDS.DataReader, _: DDS.SampleLostStatus) void {}
fn drNoopDeinit(_: *anyopaque) void {}

const dw_vtable_deadline = DDS.DataWriterListener.Vtable{
    .on_offered_deadline_missed = dwOnDeadlineMissed,
    .on_offered_incompatible_qos = dwNoopIncompat,
    .on_liveliness_lost = dwNoopLiveliness,
    .on_publication_matched = dwNoopPubMatched,
    .deinit = dwNoopDeinit,
};
const dw_vtable_liveliness = DDS.DataWriterListener.Vtable{
    .on_offered_deadline_missed = dwNoopDeadline,
    .on_offered_incompatible_qos = dwNoopIncompat,
    .on_liveliness_lost = dwOnLivelinessLost,
    .on_publication_matched = dwNoopPubMatched,
    .deinit = dwNoopDeinit,
};
const dr_vtable_deadline = DDS.DataReaderListener.Vtable{
    .on_requested_deadline_missed = drOnDeadlineMissed,
    .on_requested_incompatible_qos = drNoopIncompat,
    .on_sample_rejected = drNoopSampleRejected,
    .on_liveliness_changed = drNoopLivelinessChanged,
    .on_data_available = drNoopDataAvail,
    .on_subscription_matched = drNoopSubMatched,
    .on_sample_lost = drNoopSampleLost,
    .deinit = drNoopDeinit,
};

// ── TimerFixture ──────────────────────────────────────────────────────────────

const TimerFixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t: *zzdds.intraprocess.MemoryTransport,
    d: *zzdds.intraprocess.DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant,
    dp_impl: *DomainParticipantImpl,
    pub_: DDS.Publisher,
    sub_: DDS.Subscriber,
    topic: DDS.Topic,

    fn init(alloc: std.mem.Allocator, clock: zzdds.util.time.Clock) !TimerFixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        var config = zzdds.config.Config{};
        config.participant.timer_clock_name = "manual";
        const factory = try DomainParticipantFactoryImpl.init(
            alloc,
            t.transport(),
            d.toDiscovery(),
            noop_security,
            .spec_random,
            config,
        );
        errdefer factory.deinit();
        try factory.clock_registry.register("manual", clock);
        const dpf = factory.toDDSFactory();
        const dp = dpf.create_participant(0, .{}, nil.nil_dp_listener, 0);
        const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
        const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
        const sub_ = dp.vtable.create_subscriber(dp.ptr, .{}, nil.nil_sub_listener, 0);
        const topic = dp.vtable.create_topic(dp.ptr, "TimerTopic", "TimerType", .{}, nil.nil_topic_listener, 0);
        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t = t,
            .d = d,
            .factory = factory,
            .dp = dp,
            .dp_impl = dp_impl,
            .pub_ = pub_,
            .sub_ = sub_,
            .topic = topic,
        };
    }

    fn deinit(self: *TimerFixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.d.deinit();
        self.t.deinit();
        self.delivery.deinit();
    }

    fn makeWriter(
        self: *TimerFixture,
        qos: DDS.DataWriterQos,
        listener: DDS.DataWriterListener,
        mask: DDS.StatusMask,
    ) *DataWriterImpl {
        const dw = self.pub_.vtable.create_datawriter(self.pub_.ptr, self.topic, qos, listener, mask);
        return @ptrCast(@alignCast(dw.ptr));
    }

    fn makeReader(
        self: *TimerFixture,
        qos: DDS.DataReaderQos,
        listener: DDS.DataReaderListener,
        mask: DDS.StatusMask,
    ) *DataReaderImpl {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic.ptr))).toTopicDescription();
        const dr = self.sub_.vtable.create_datareader(self.sub_.ptr, td, qos, listener, mask);
        return @ptrCast(@alignCast(dr.ptr));
    }
};

// ── DEADLINE tests ────────────────────────────────────────────────────────────

test "deadline: writer — fires on_offered_deadline_missed when period elapses" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    _ = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_deadline }, DDS.OFFERED_DEADLINE_MISSED_STATUS);

    // Period not yet elapsed — no notification.
    mc.advance(999_999_999); // 1 ns short of 1 s
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // Advance past the 1 s deadline — should fire once.
    mc.advance(1); // now at exactly 1 s
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);

    // Another full period without a write — fires again.
    mc.advance(std.time.ns_per_s);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 2), count);
}

test "deadline: writer — write() resets the deadline window" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    const dw = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_deadline }, DDS.OFFERED_DEADLINE_MISSED_STATUS);

    // Write at T=0.5 s — resets last_write_ns to 500 ms.
    mc.advance(std.time.ns_per_s / 2);
    try writeRaw(dw, &PAYLOAD_A);

    // T=1.0 s: only 0.5 s since last write — not yet missed.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // T=1.5 s: 1 s since last write — deadline missed.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "deadline: reader — fires on_requested_deadline_missed when period elapses" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    _ = fx.makeReader(dr_qos, .{ .ptr = &count, .vtable = &dr_vtable_deadline }, DDS.REQUESTED_DEADLINE_MISSED_STATUS);

    // Period not yet elapsed.
    mc.advance(999_999_999);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // Exactly 1 s — fires.
    mc.advance(1);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "deadline: reader — receiving data resets the deadline window" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    const dr = fx.makeReader(dr_qos, .{ .ptr = &count, .vtable = &dr_vtable_deadline }, DDS.REQUESTED_DEADLINE_MISSED_STATUS);

    // Receive a sample at T=0.5 s — resets last_received_ns.
    mc.advance(std.time.ns_per_s / 2);
    dr.pushCdr(&PAYLOAD_A);

    // T=1.0 s: only 0.5 s since last sample — not yet missed.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // T=1.5 s: 1 s since last sample — deadline missed.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "deadline: inactive (period = 0) — never fires" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    // Default DataWriterQos has deadline.period = {0, 0} = infinite/inactive.
    _ = fx.makeWriter(.{}, .{ .ptr = &count, .vtable = &dw_vtable_deadline }, DDS.OFFERED_DEADLINE_MISSED_STATUS);

    mc.advance(100 * std.time.ns_per_s); // advance 100 seconds
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);
}

// ── LIVELINESS tests ──────────────────────────────────────────────────────────

test "liveliness: AUTOMATIC — fires on_liveliness_lost after lease elapses without write" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .AUTOMATIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    _ = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_liveliness }, DDS.LIVELINESS_LOST_STATUS);

    // Lease not yet expired.
    mc.advance(999_999_999);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // Exactly 1 s — lease expired.
    mc.advance(1);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "liveliness: AUTOMATIC — write() resets the liveliness lease" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .AUTOMATIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    const dw = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_liveliness }, DDS.LIVELINESS_LOST_STATUS);

    // Write at T=0.5 s — resets liveliness_last_ns.
    mc.advance(std.time.ns_per_s / 2);
    try writeRaw(dw, &PAYLOAD_A);

    // T=1.0 s: only 0.5 s since last write — lease still valid.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // T=1.5 s: 1 s since last write — lease expired.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "liveliness: MANUAL_BY_TOPIC — fires when assert_liveliness() not called in time" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    const dw = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_liveliness }, DDS.LIVELINESS_LOST_STATUS);

    // write() does NOT reset liveliness for MANUAL_BY_TOPIC.
    mc.advance(std.time.ns_per_s / 2);
    try writeRaw(dw, &PAYLOAD_A);

    // Still 1 s from creation — lease expires at T=1 s.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "liveliness: MANUAL_BY_TOPIC — assert_liveliness() on writer resets the lease" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    const dw = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_liveliness }, DDS.LIVELINESS_LOST_STATUS);
    const dw_dds = dw.toDDSDataWriter();

    // Assert liveliness at T=0.5 s.
    mc.advance(std.time.ns_per_s / 2);
    _ = dw_dds.vtable.assert_liveliness(dw_dds.ptr);

    // T=1.0 s: only 0.5 s since assertion — lease still valid.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // T=1.5 s: 1 s since last assertion — lease expired.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "liveliness: MANUAL_BY_PARTICIPANT — participant.assert_liveliness() resets the lease" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    _ = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_liveliness }, DDS.LIVELINESS_LOST_STATUS);

    // Call participant.assert_liveliness() at T=0.5 s.
    mc.advance(std.time.ns_per_s / 2);
    _ = fx.dp.vtable.assert_liveliness(fx.dp.ptr);

    // T=1.0 s: only 0.5 s since participant assertion — lease still valid.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 0), count);

    // T=1.5 s: 1 s since last assertion — lease expired.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}

test "liveliness: MANUAL_BY_PARTICIPANT — write() does not reset the lease" {
    const alloc = testing.allocator;
    var mc = ManualClock.init(0);
    var fx = try TimerFixture.init(alloc, mc.clock());
    defer fx.deinit();

    var count: i32 = 0;
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.liveliness.kind = .MANUAL_BY_PARTICIPANT_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    const dw = fx.makeWriter(dw_qos, .{ .ptr = &count, .vtable = &dw_vtable_liveliness }, DDS.LIVELINESS_LOST_STATUS);

    // write() must NOT reset liveliness for MANUAL_BY_PARTICIPANT.
    mc.advance(std.time.ns_per_s / 2);
    try writeRaw(dw, &PAYLOAD_A);

    // T=1.0 s: lease expires despite the write.
    mc.advance(std.time.ns_per_s / 2);
    fx.dp_impl.checkTimers();
    try testing.expectEqual(@as(i32, 1), count);
}
