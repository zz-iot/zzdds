//! Tests for TypeSupport registration and key-hash fallback.
//!
//! The central scenario is Ownership_4: two writers each publish a
//! different keyed instance.  Without TypeSupport the per-instance key
//! hash is absent, all samples collapse to InstanceHandle NIL, and
//! exclusive ownership blocks the weaker writer globally.  With
//! TypeSupport the reader's participant derives distinct key hashes from
//! the CDR payloads and correctly applies ownership per-instance.

const std = @import("std");
const test_domain = @import("test_domain");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

// Minimal CDR-LE payloads: 4-byte encapsulation header + 1 discriminator byte.
const PAYLOAD_A = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAA };
const PAYLOAD_B = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xBB };

fn writeNilKey(dw: *DataWriterImpl, payload: []const u8) !void {
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

/// TypeSupport that uses payload byte [4] as the entire key discriminator.
fn testKeyHash(_: *anyopaque, payload: []const u8) [16]u8 {
    var h = std.mem.zeroes([16]u8);
    if (payload.len > 4) h[0] = payload[4];
    return h;
}

/// TypeSupport that always returns the same hash regardless of payload.
fn constKeyHash(_: *anyopaque, _: []const u8) [16]u8 {
    var h = std.mem.zeroes([16]u8);
    h[0] = 0xAA;
    return h;
}

// ── Shared fixture ────────────────────────────────────────────────────────────

const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;

const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    t_a: *MemoryTransport,
    d_a: *DirectDiscovery,
    factory_a: *DomainParticipantFactoryImpl,
    dp_a: DDS.DomainParticipant,
    pub_a: DDS.Publisher,
    topic_a: DDS.Topic,

    t_b: *MemoryTransport,
    d_b: *DirectDiscovery,
    factory_b: *DomainParticipantFactoryImpl,
    dp_b: DDS.DomainParticipant,
    pub_b: DDS.Publisher,
    topic_b: DDS.Topic,

    t_r: *MemoryTransport,
    d_r: *DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(alloc: std.mem.Allocator) !Fixture {
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
        const dp_a = factory_a.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_a = dp_a.create_publisher(.{}, null, 0);
        const topic_a = dp_a.create_topic("TSTopic", "TSType", .{}, null, 0);

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
        const dp_b = factory_b.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const pub_b = dp_b.create_publisher(.{}, null, 0);
        const topic_b = dp_b.create_topic("TSTopic", "TSType", .{}, null, 0);

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
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("TSTopic", "TSType", .{}, null, 0);

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

    fn deinit(self: *Fixture) void {
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

    fn dpImpl(self: *const Fixture, dp: DDS.DomainParticipant) *DomainParticipantImpl {
        _ = self;
        return @ptrCast(@alignCast(dp.ptr));
    }

    fn makeWriterA(self: *Fixture, qos: DDS.DataWriterQos) *DataWriterImpl {
        const dw = self.pub_a.create_datawriter(self.topic_a, qos, null, 0);
        return @ptrCast(@alignCast(dw.ptr));
    }

    fn makeWriterB(self: *Fixture, qos: DDS.DataWriterQos) *DataWriterImpl {
        const dw = self.pub_b.create_datawriter(self.topic_b, qos, null, 0);
        return @ptrCast(@alignCast(dw.ptr));
    }

    fn makeReader(self: *Fixture, qos: DDS.DataReaderQos) *DataReaderImpl {
        const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_r.create_datareader(td, qos, null, 0);
        return @ptrCast(@alignCast(dr.ptr));
    }
};

fn exclusiveDwQos(strength: i32) DDS.DataWriterQos {
    var q = DDS.DataWriterQos{};
    q.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    q.ownership_strength.value = strength;
    return q;
}

fn exclusiveDrQos() DDS.DataReaderQos {
    var q = DDS.DataReaderQos{};
    q.ownership.kind = .EXCLUSIVE_OWNERSHIP_QOS;
    return q;
}

fn keepAllDrQos() DDS.DataReaderQos {
    var q = DDS.DataReaderQos{};
    q.history.kind = .KEEP_ALL_HISTORY_QOS;
    return q;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "TypeSupport: registerTypeSupport stores callback" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dp_impl = fx.dpImpl(fx.dp_r);
    try testing.expect(dp_impl.type_support_registry.get("TSType") == null);

    _ = dp_impl.registerTypeSupport("TSType", .{ .ctx = undefined, .compute_key_hash = testKeyHash });
    try testing.expect(dp_impl.type_support_registry.get("TSType") != null);
}

test "TypeSupport: key_hash_fn set on reader when registered before reader creation" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.dpImpl(fx.dp_r).registerTypeSupport("TSType", .{ .ctx = undefined, .compute_key_hash = testKeyHash });
    _ = fx.makeReader(.{});

    const dp_impl = fx.dpImpl(fx.dp_r);
    dp_impl.mu.lock();
    var found_fn = false;
    var ar_it = dp_impl.active_readers.valueIterator();
    while (ar_it.next()) |ar| {
        if (ar.key_hash_fn != null) found_fn = true;
    }
    dp_impl.mu.unlock();
    try testing.expect(found_fn);
}

test "TypeSupport: reader created before registration has no key_hash_fn" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeReader(.{});
    // Register after reader creation — should not retroactively set key_hash_fn.
    _ = fx.dpImpl(fx.dp_r).registerTypeSupport("TSType", .{ .ctx = undefined, .compute_key_hash = testKeyHash });

    const dp_impl = fx.dpImpl(fx.dp_r);
    dp_impl.mu.lock();
    var any_fn = false;
    var ar_it2 = dp_impl.active_readers.valueIterator();
    while (ar_it2.next()) |ar| {
        if (ar.key_hash_fn != null) any_fn = true;
    }
    dp_impl.mu.unlock();
    try testing.expect(!any_fn);
}

test "TypeSupport: without TypeSupport, nil-key instances collapse and EXCLUSIVE ownership is global" {
    // Control group: without TypeSupport, both writers write nil key_hash →
    // one instance → only the high-strength writer is delivered.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_a = fx.makeWriterA(exclusiveDwQos(10));
    const dw_b = fx.makeWriterB(exclusiveDwQos(5));
    const dr = fx.makeReader(exclusiveDrQos());

    try writeNilKey(dw_a, &PAYLOAD_A);
    try writeNilKey(dw_b, &PAYLOAD_B);

    try testing.expectEqual(@as(usize, 1), pendingCount(dr));
    dr.mu.lock();
    const data = dr.pending.items[0].data;
    dr.mu.unlock();
    try testing.expectEqualSlices(u8, &PAYLOAD_A, data);
}

test "TypeSupport: with TypeSupport, EXCLUSIVE ownership is per-instance (Ownership_4 scenario)" {
    // Each writer publishes a different keyed instance (PAYLOAD_A vs PAYLOAD_B).
    // The writers send nil key_hash; the reader's TypeSupport derives distinct
    // hashes, so both instances are delivered despite EXCLUSIVE ownership.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.dpImpl(fx.dp_r).registerTypeSupport("TSType", .{ .ctx = undefined, .compute_key_hash = testKeyHash });

    const dw_a = fx.makeWriterA(exclusiveDwQos(10));
    const dw_b = fx.makeWriterB(exclusiveDwQos(5));
    const dr = fx.makeReader(exclusiveDrQos());

    try writeNilKey(dw_a, &PAYLOAD_A); // instance key 0xAA
    try writeNilKey(dw_b, &PAYLOAD_B); // instance key 0xBB — different instance

    try testing.expectEqual(@as(usize, 2), pendingCount(dr));
}

test "TypeSupport: non-nil inline key_hash takes precedence over TypeSupport" {
    // TypeSupport always returns 0xAA.  Writer A sends with explicit inline
    // key_hash 0xBB.  Writer B sends with nil key_hash → TypeSupport gives 0xAA.
    // 0xBB ≠ 0xAA → two different instances → both delivered.
    // If TypeSupport had overridden the inline key_hash for A (bug), A would also
    // be 0xAA → same instance → only one sample delivered.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.dpImpl(fx.dp_r).registerTypeSupport("TSType", .{ .ctx = undefined, .compute_key_hash = constKeyHash });

    const dw_a = fx.makeWriterA(exclusiveDwQos(10));
    const dw_b = fx.makeWriterB(exclusiveDwQos(5));
    const dr = fx.makeReader(exclusiveDrQos());

    var kh_bb = std.mem.zeroes([16]u8);
    kh_bb[0] = 0xBB;
    _ = try dw_a.writeRaw(.alive, RtpsTimestamp.now(), history_mod.INSTANCE_HANDLE_NIL, kh_bb, &PAYLOAD_A);
    try writeNilKey(dw_b, &PAYLOAD_B); // TypeSupport → 0xAA

    // 0xBB (A, from inline) ≠ 0xAA (B, from TypeSupport) → two instances.
    try testing.expectEqual(@as(usize, 2), pendingCount(dr));
}

test "TypeSupport: has_key writer sends inline PID_KEY_HASH for a zero-valued key, bypassing key_hash_fn" {
    // A keyed writer (TypeSupport.has_key = true) must put an inline
    // PID_KEY_HASH on every alive sample per RTPS §8.7.9 — including when the
    // hash is all-zeros (a zero-valued key). The subscriber then routes by that
    // *present* hash and never calls key_hash_fn to reconstruct one from the
    // payload (which, for a non-leading @key, would misread it).
    //
    // Here both writers emit a zero key hash for different payloads. testKeyHash
    // (reads payload[4]) *would* derive distinct hashes 0xAA / 0xBB if it were
    // consulted — but it must NOT be, because the wire now carries an explicit
    // all-zero PID_KEY_HASH. So both samples land on one instance.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // has_key must be registered on the *writer* participants, before the
    // writers are created, for pubCreateProtoWriter to mark them keyed.
    inline for (.{ fx.dp_a, fx.dp_b, fx.dp_r }) |dp| {
        _ = fx.dpImpl(dp).registerTypeSupport("TSType", .{
            .ctx = undefined,
            .compute_key_hash = testKeyHash,
            .has_key = true,
        });
    }

    const dw_a = fx.makeWriterA(.{});
    const dw_b = fx.makeWriterB(.{});
    const dr = fx.makeReader(keepAllDrQos());

    try writeNilKey(dw_a, &PAYLOAD_A); // payload[4] = 0xAA — ignored
    try writeNilKey(dw_b, &PAYLOAD_B); // payload[4] = 0xBB — ignored

    // Both carry an inline all-zero key hash → same instance → both retained
    // (KEEP_ALL) under one instance handle.
    try testing.expectEqual(@as(usize, 2), pendingCount(dr));
    dr.mu.lock();
    const ih0 = dr.pending.items[0].info.instance_handle;
    const ih1 = dr.pending.items[1].info.instance_handle;
    dr.mu.unlock();
    try testing.expectEqual(ih0, ih1);
}

test "TypeSupport: without has_key, a zero-valued key still falls back to key_hash_fn (unchanged)" {
    // Control: same inputs as above but has_key defaults false. The writer omits
    // the inline hash for an all-zero key, so the reader reconstructs distinct
    // hashes via key_hash_fn (testKeyHash → 0xAA / 0xBB) → two instances.
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.dpImpl(fx.dp_r).registerTypeSupport("TSType", .{ .ctx = undefined, .compute_key_hash = testKeyHash });

    const dw_a = fx.makeWriterA(.{});
    const dw_b = fx.makeWriterB(.{});
    const dr = fx.makeReader(keepAllDrQos());

    try writeNilKey(dw_a, &PAYLOAD_A);
    try writeNilKey(dw_b, &PAYLOAD_B);

    try testing.expectEqual(@as(usize, 2), pendingCount(dr));
    dr.mu.lock();
    const ih0 = dr.pending.items[0].info.instance_handle;
    const ih1 = dr.pending.items[1].info.instance_handle;
    dr.mu.unlock();
    try testing.expect(ih0 != ih1);
}
