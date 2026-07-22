//! Tests for the C-ABI bootstrap shim (src/c_abi/bootstrap.zig).
//!
//! - Factory lifecycle test: zzdds_create_factory + generated create/delete
//! - Write/take tests: use IntraProcessDelivery for synchronous delivery so
//!   no timing sensitivity; the write/take functions work on any DDS entity handle.
//! - topic_as_description: verified against the CFT TopicDescription vtable.

const std = @import("std");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = zzdds.ZZDDS;

const bootstrap = zzdds.c_abi.bootstrap;
const extensions = zzdds.c_abi.extensions;
const zidl_rt = @import("zidl_rt");
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const GuardConditionImpl = zzdds.dcps.GuardConditionImpl;
const StatusConditionImpl = zzdds.dcps.StatusConditionImpl;
const ReadConditionImpl = zzdds.dcps.ReadConditionImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const generated_config = zzdds.generated_config;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history = zzdds.rtps.history;

// CDR_LE encapsulation header + 1-byte payload.
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAB };
const KEY_HASH = std.mem.zeroes([16]u8);

// ── Intraprocess fixture ──────────────────────────────────────────────────────

const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t_w: *MemoryTransport,
    d_w: *DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,
    t_r: *MemoryTransport,
    d_r: *DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,
    /// Boxed C-ABI handles from the most recent makeWriterReader() call --
    /// what a real C caller actually has (zzdds_c.h's DDS_DataWriter/
    /// DDS_DataReader are opaque pointers, not the native {ptr, vtable} fat
    /// pointer). Freed in deinit(); at most one pair per Fixture instance in
    /// this test file, so tracking "the last one" is sufficient.
    dw_box: ?*anyopaque = null,
    dr_box: ?*anyopaque = null,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("BootTopic", "BootType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("BootTopic", "BootType", .{}, null, 0);

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
        if (self.dw_box) |b| zidl_rt.freeEntityBox(self.alloc, b);
        if (self.dr_box) |b| zidl_rt.freeEntityBox(self.alloc, b);
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

    /// Returns both the native fat-pointer structs (dw/dr -- for calling
    /// vtable methods directly, as some tests do) and their *boxed* C-ABI
    /// handle equivalents (dw_boxed/dr_boxed -- what a real C caller actually
    /// has and must pass to bootstrap.zzdds_write_raw/zzdds_take_one_raw/etc;
    /// zzdds_c.h's DDS_DataWriter/DDS_DataReader are opaque pointers, not the
    /// native struct). Exercising the bootstrap functions with the native
    /// structs directly previously masked a real C-ABI signature mismatch bug
    /// (see bootstrap.zig's file-level doc comment).
    fn makeWriterReader(self: *Fixture) struct { dw: DDS.DataWriter, dr: DDS.DataReader, dw_boxed: *anyopaque, dr_boxed: *anyopaque } {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_r.create_datareader(td, .{}, null, 0);
        const dw = self.pub_w.create_datawriter(self.topic_w, .{}, null, 0);
        const dw_box = zidl_rt.boxEntity(self.alloc, dw.ptr, dw.vtable) catch @panic("test OOM boxing DataWriter");
        const dr_box = zidl_rt.boxEntity(self.alloc, dr.ptr, dr.vtable) catch @panic("test OOM boxing DataReader");
        self.dw_box = dw_box;
        self.dr_box = dr_box;
        return .{ .dw = dw, .dr = dr, .dw_boxed = dw_box, .dr_boxed = dr_box };
    }
};

// ── Factory lifecycle ─────────────────────────────────────────────────────────

test "support factory: destroy_factory is safe on nil handle" {
    const alloc = testing.allocator;
    // Must use the real ZZDDS.DomainParticipantFactory.Vtable here, not some
    // other interface's vtable — zzdds_destroy_factory checks ptr == NIL_PTR
    // before touching .vtable today, but boxing with a mismatched vtable type
    // would be unsound if that guard ever moved.
    const boxed = try zidl_rt.boxEntity(alloc, zzdds.dcps.NIL_PTR, &extensions.factory_vtable);
    defer zidl_rt.freeEntityBox(alloc, boxed);
    extensions.zzdds_destroy_factory(boxed); // must not crash or call deinit
}

test "support factory: generated create_participant and delete_participant" {
    const ext_factory_boxed = extensions.zzdds_create_factory();
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, 0, null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
}

test "support factory: generated create_participant_ex uses config defaults" {
    const ext_factory_boxed = extensions.zzdds_create_factory();
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    const cfg = ZZDDS.DomainParticipantConfig.default();
    const qos = DDS.DomainParticipantQos{};
    const dp = ext_factory.create_participant_ex(0, qos, null, 0, cfg);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
}

// ── zzdds_create_factory_with_allocator ────────────────────────────────────────
//
// Proves the C-ABI allocator injection actually reaches every downstream
// allocation (factory bootstrap, transport, discovery, participant), not just
// that the new export compiles. TrackingCtx forwards every call to
// std.testing.allocator's raw vtable functions, so Zig's own leak/double-free
// detection for `testing.allocator` continues to apply transparently across
// the C-ABI round trip — a missing free anywhere in the injected path would
// fail this test the same way any other testing.allocator leak would.

const TrackingCtx = struct {
    child: std.mem.Allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    free_calls: usize = 0,
};

fn trackAlloc(ctx: ?*anyopaque, len: usize, alignment: usize) callconv(.c) ?[*]u8 {
    const self: *TrackingCtx = @ptrCast(@alignCast(ctx.?));
    self.alloc_calls += 1;
    return self.child.rawAlloc(len, std.mem.Alignment.fromByteUnits(alignment), @returnAddress());
}

fn trackResize(ctx: ?*anyopaque, ptr: ?[*]u8, old_len: usize, new_len: usize, alignment: usize) callconv(.c) bool {
    const self: *TrackingCtx = @ptrCast(@alignCast(ctx.?));
    self.resize_calls += 1;
    return self.child.rawResize(ptr.?[0..old_len], std.mem.Alignment.fromByteUnits(alignment), new_len, @returnAddress());
}

fn trackFree(ctx: ?*anyopaque, ptr: ?[*]u8, len: usize, alignment: usize) callconv(.c) void {
    const self: *TrackingCtx = @ptrCast(@alignCast(ctx.?));
    self.free_calls += 1;
    self.child.rawFree(ptr.?[0..len], std.mem.Alignment.fromByteUnits(alignment), @returnAddress());
}

test "support factory: zzdds_create_factory_with_allocator(NULL) matches zzdds_create_factory" {
    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(null);
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, ext_factory_boxed);
    try testing.expect(ext_factory.ptr != zzdds.dcps.NIL_PTR);
}

test "support factory: zzdds_create_factory_with_allocator routes every allocation through the caller's allocator" {
    var track = TrackingCtx{ .child = testing.allocator };
    const c_alloc = zidl_rt.ZidlAllocator{
        .ctx = &track,
        .alloc = trackAlloc,
        .resize = trackResize,
        .free = trackFree,
    };

    const ext_factory_boxed = extensions.zzdds_create_factory_with_allocator(&c_alloc);
    defer extensions.zzdds_destroy_factory(ext_factory_boxed);
    const ext_factory = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, ext_factory_boxed);

    // Bootstrapping the factory itself (FactoryOwner) already allocates.
    try testing.expect(track.alloc_calls > 0);
    const calls_after_bootstrap = track.alloc_calls;

    // Creating a participant spins up a real UdpTransport + SpdpSedpDiscovery +
    // DomainParticipantFactoryImpl/DomainParticipantImpl stack (ParticipantStack.init)
    // — every one of those allocates, and every one must inherit the injected
    // allocator, not silently fall back to std.heap.c_allocator.
    const cfg = ZZDDS.DomainParticipantConfig.default();
    const qos = DDS.DomainParticipantQos{};
    const dp = ext_factory.create_participant_ex(0, qos, null, 0, cfg);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expect(track.alloc_calls > calls_after_bootstrap);

    const factory = ext_factory.vtable.as_DomainParticipantFactory(ext_factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
    try testing.expect(track.free_calls > 0);
}

fn DDS_DomainParticipantFactory_create_participant_for_test(
    factory: DDS.DomainParticipantFactory,
    domain_id: DDS.DomainId_t,
    listener: ?*const DDS.DomainParticipantListener,
) DDS.DomainParticipant {
    const qos = DDS.DomainParticipantQos{};
    return factory.vtable.create_participant(factory.ptr, domain_id, &qos, listener, 0);
}

// ── topic_as_description ──────────────────────────────────────────────────────

test "bootstrap: topic_as_description returns TopicDescription with correct name" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // zzdds_topic_as_description takes/returns *boxed* C-ABI handles, matching
    // what a real C caller has (zzdds_c.h's DDS_Topic/DDS_TopicDescription are
    // opaque pointers, not the native {ptr, vtable} fat pointer) -- box
    // fx.topic_w the same way, then unbox the result to call its vtable.
    const topic_w_boxed = try zidl_rt.boxEntity(alloc, fx.topic_w.ptr, fx.topic_w.vtable);
    defer zidl_rt.freeEntityBox(alloc, topic_w_boxed);

    const td_boxed = bootstrap.zzdds_topic_as_description(topic_w_boxed);
    const td = zidl_rt.unboxAs(DDS.TopicDescription, td_boxed);
    try testing.expectEqualStrings("BootTopic", std.mem.span(td.vtable.get_name(td.ptr)));
}

// ── write_raw + take_one_raw ──────────────────────────────────────────────────

test "bootstrap: write_raw and take_one_raw round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const rc = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);
    try testing.expectEqual(@as(DDS.ReturnCode_t, 0), rc);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expectEqual(PAYLOAD.len, cdr_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..cdr_len]);
    try testing.expect(info.valid_data);
}

test "bootstrap: write_raw_kind dispose produces not-alive sample" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const rc = bootstrap.zzdds_write_raw_kind(pair.dw_boxed, .dispose, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);
    try testing.expectEqual(@as(DDS.ReturnCode_t, 0), rc);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expect(!info.valid_data);
    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, info.instance_state);
}

test "bootstrap: take_loaned_raw and return_loaned_raw" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var loan: bootstrap.CLoanedSample = undefined;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_loaned_raw(pair.dr_boxed, &loan, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expect(info.valid_data);
    try testing.expectEqual(PAYLOAD.len, loan.data_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, loan.data.?[0..loan.data_len]);
    try testing.expect(loan.owner != null);

    bootstrap.zzdds_return_loaned_raw(pair.dr_boxed, &loan);
    try testing.expectEqual(@as(usize, 0), loan.data_len);
    try testing.expect(loan.data == null);
    try testing.expect(loan.owner == null);
}

test "bootstrap: take_one_raw returns 0 when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 0), n);
}

test "bootstrap: take_one_raw returns -1 when buffer too small" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var tiny: [2]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr_boxed, &tiny, tiny.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, -1), n);
    // cdr_len_out must be set even on failure so the caller can retry with a larger buffer.
    try testing.expectEqual(PAYLOAD.len, cdr_len);
}

// ── take_one_raw_instance ─────────────────────────────────────────────────────

test "bootstrap: take_one_raw_instance round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw_instance(pair.dr_boxed, 0, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expectEqual(PAYLOAD.len, cdr_len);
}

test "bootstrap: take_one_raw_instance returns 0 when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw_instance(pair.dr_boxed, 0, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 0), n);
}

// ── register_instance_raw ─────────────────────────────────────────────────────

test "bootstrap: register_instance_raw returns deterministic handle" {
    const h1 = bootstrap.zzdds_register_instance_raw(undefined, &KEY_HASH);
    const h2 = bootstrap.zzdds_register_instance_raw(undefined, &KEY_HASH);
    try testing.expectEqual(h1, h2);
    // Distinct key should produce distinct handle.
    var other_key: [16]u8 = undefined;
    @memset(&other_key, 0x01);
    const h3 = bootstrap.zzdds_register_instance_raw(undefined, &other_key);
    try testing.expect(h1 != h3);
}

// ── write_raw_w_timestamp ─────────────────────────────────────────────────────

test "bootstrap: write_raw_w_timestamp round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const ts = DDS.Time_t{ .sec = 42, .nanosec = 0 };
    const rc = bootstrap.zzdds_write_raw_w_timestamp(pair.dw_boxed, .alive, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len, ts);
    try testing.expectEqual(@as(DDS.ReturnCode_t, 0), rc);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expectEqual(PAYLOAD.len, cdr_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..cdr_len]);
}

// ── read_one_raw ──────────────────────────────────────────────────────────────

test "bootstrap: read_one_raw non-destructive — sample stays in queue" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n1 = bootstrap.zzdds_read_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n1);
    try testing.expectEqual(PAYLOAD.len, cdr_len);
    // Second read still returns the same sample.
    const n2 = bootstrap.zzdds_read_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n2);
}

test "bootstrap: read_one_raw returns 0 when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_read_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 0), n);
}

// ── read_one_raw_instance ─────────────────────────────────────────────────────

test "bootstrap: read_one_raw_instance round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_read_one_raw_instance(pair.dr_boxed, 0, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expectEqual(PAYLOAD.len, cdr_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..cdr_len]);
}

test "bootstrap: read_one_raw_instance returns 0 when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_read_one_raw_instance(pair.dr_boxed, 0, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 0), n);
}

// ── take_n_raw / read_n_raw / return_raw_samples ──────────────────────────────

test "bootstrap: take_n_raw returns all samples and return_raw_samples frees" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    // Use three different key hashes to get three distinct instances
    // (default KEEP_LAST=1 QoS keeps one sample per instance).
    var k1: [16]u8 = std.mem.zeroes([16]u8);
    k1[0] = 1;
    var k2: [16]u8 = std.mem.zeroes([16]u8);
    k2[0] = 2;
    var k3: [16]u8 = std.mem.zeroes([16]u8);
    k3[0] = 3;
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k1, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k2, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k3, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_take_n_raw(pair.dr_boxed, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 5, &arr);
    try testing.expectEqual(@as(c_int, 3), n);
    try testing.expectEqual(@as(usize, 3), arr.count);
    try testing.expect(arr.samples != null);
    // Verify first sample payload.
    const s0 = arr.samples.?[0];
    try testing.expectEqual(PAYLOAD.len, s0.data_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, s0.data.?[0..s0.data_len]);

    bootstrap.zzdds_return_raw_samples(pair.dr_boxed, &arr);
    try testing.expectEqual(@as(usize, 0), arr.count);
    try testing.expect(arr.samples == null);

    // Queue is now empty.
    var arr2: bootstrap.CRawSampleArray = undefined;
    const n2 = bootstrap.zzdds_take_n_raw(pair.dr_boxed, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 5, &arr2);
    try testing.expectEqual(@as(c_int, 0), n2);
    try testing.expect(arr2.samples == null);
}

test "bootstrap: take_n_raw returns 0 when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_take_n_raw(pair.dr_boxed, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 10, &arr);
    try testing.expectEqual(@as(c_int, 0), n);
    try testing.expect(arr.samples == null);
}

test "bootstrap: read_n_raw is non-destructive" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var k1: [16]u8 = std.mem.zeroes([16]u8);
    k1[0] = 1;
    var k2: [16]u8 = std.mem.zeroes([16]u8);
    k2[0] = 2;
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k1, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k2, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_read_n_raw(pair.dr_boxed, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 10, &arr);
    try testing.expectEqual(@as(c_int, 2), n);
    bootstrap.zzdds_return_raw_samples(pair.dr_boxed, &arr);

    // Samples still in queue — take should succeed.
    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const m = bootstrap.zzdds_take_one_raw(pair.dr_boxed, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), m);
}

// ── get_key_value_writer / lookup_instance_writer ─────────────────────────────

test "bootstrap: get_key_value_writer returns CDR payload after alive write" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(@as(c_int, 0), rc);
    try testing.expectEqual(PAYLOAD.len, len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..len]);
}

test "bootstrap: get_key_value_writer returns -1 for unknown handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var dummy_key: [16]u8 = undefined;
    @memset(&dummy_key, 0xFF);
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &dummy_key);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_writer(pair.dw_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(@as(c_int, -1), rc);
}

test "bootstrap: lookup_instance_writer matches register_instance_raw" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const h1 = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);
    const h2 = bootstrap.zzdds_lookup_instance_writer(pair.dw_boxed, &KEY_HASH);
    try testing.expectEqual(h1, h2);
}

// ── get_key_value_reader / lookup_instance_reader ─────────────────────────────

test "bootstrap: get_key_value_reader returns CDR payload after receive" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(@as(c_int, 0), rc);
    try testing.expectEqual(PAYLOAD.len, len);
    try testing.expectEqualSlices(u8, &PAYLOAD, buf[0..len]);
}

test "bootstrap: get_key_value_reader returns -1 for unknown handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var dummy_key: [16]u8 = undefined;
    @memset(&dummy_key, 0xFF);
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &dummy_key);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_reader(pair.dr_boxed, ih, &buf, buf.len, &len);
    try testing.expectEqual(@as(c_int, -1), rc);
}

test "bootstrap: lookup_instance_reader returns handle for alive instance, 0 when not found" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    // Known alive instance returns its handle.
    const ih = bootstrap.zzdds_lookup_instance_reader(pair.dr_boxed, &KEY_HASH);
    try testing.expect(ih != 0);
    try testing.expectEqual(bootstrap.zzdds_register_instance_raw(pair.dw_boxed, &KEY_HASH), ih);

    // Unknown key returns 0 (HANDLE_NIL).
    var unknown_key: [16]u8 = undefined;
    @memset(&unknown_key, 0xFF);
    const ih2 = bootstrap.zzdds_lookup_instance_reader(pair.dr_boxed, &unknown_key);
    try testing.expectEqual(@as(DDS.InstanceHandle_t, 0), ih2);
}

// ── Conversion nil-guard tests ────────────────────────────────────────────────
//
// The DDS-internal upcasts (DDS_X_as_DDS_Y, where Y is an IDL-declared base
// of X) are now generated via the `as_{Base}` vtable slot mechanism (see
// zidl's docs/roadmap.md) rather than hand-written free functions with their
// own defensive vtable-identity check. That check — "is this really the
// vtable I expect, else return nil" — doesn't have an analogue to test
// anymore: dispatch through the vtable is correct by construction (you can
// only ever call `.vtable.as_X()` on a value that already has *some* real
// vtable for the interface type it claims to be), so there's no
// "wrong-implementation" runtime branch left to exercise here.

// ── Conversion valid-handle tests (using IntraProcess fixture) ────────────────

test "extensions: entity conversion functions return valid handles for real entities" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const np = zzdds.dcps.NIL_PTR;

    try testing.expect(fx.dp_w.vtable.as_Entity(fx.dp_w.ptr).ptr != np);
    try testing.expect(fx.topic_w.vtable.as_Entity(fx.topic_w.ptr).ptr != np);
    try testing.expect(fx.pub_w.vtable.as_Entity(fx.pub_w.ptr).ptr != np);
    try testing.expect(fx.sub_r.vtable.as_Entity(fx.sub_r.ptr).ptr != np);
    try testing.expect(pair.dw.vtable.as_Entity(pair.dw.ptr).ptr != np);
    try testing.expect(pair.dr.vtable.as_Entity(pair.dr.ptr).ptr != np);

    const td = fx.topic_w.vtable.as_TopicDescription(fx.topic_w.ptr);
    try testing.expect(td.ptr != np);
    try testing.expectEqualStrings("BootTopic", std.mem.span(td.vtable.get_name(td.ptr)));
}

test "extensions: DDS_DataReader_as_zzdds and back round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const np = zzdds.dcps.NIL_PTR;

    // DDS → ZZDDS: still hand-written (genuine downcast, no IDL relationship
    // zidl could derive it from).
    const zdr_boxed = extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr.vtable.get_c_abi_handle(pair.dr.ptr));
    const zdr = zidl_rt.unboxAs(ZZDDS.DataReader, zdr_boxed);
    try testing.expect(zdr.ptr != np);

    // ZZDDS → DDS round-trip: generated upcast (ZZDDS.DataReader : DDS::DataReader).
    const ddr = zdr.vtable.as_DataReader(zdr.ptr);
    try testing.expect(ddr.ptr != np);
    try testing.expectEqual(pair.dr.ptr, ddr.ptr);

    // Same for DataWriter
    const zdw_boxed = extensions.DDS_DataWriter_as_zzdds_DataWriter(pair.dw.vtable.get_c_abi_handle(pair.dw.ptr));
    const zdw = zidl_rt.unboxAs(ZZDDS.DataWriter, zdw_boxed);
    try testing.expect(zdw.ptr != np);
    const ddw = zdw.vtable.as_DataWriter(zdw.ptr);
    try testing.expectEqual(pair.dw.ptr, ddw.ptr);
}

// ── Condition conversion valid-handle tests ───────────────────────────────────

test "extensions: DDS_GuardCondition_as_DDS_Condition with real GuardCondition" {
    const gc_impl = try GuardConditionImpl.init(testing.allocator);
    defer gc_impl.deinit();

    const gc = gc_impl.toDDSGuardCondition();
    const c = gc.vtable.as_Condition(gc.ptr);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
    try testing.expect(!c.vtable.get_trigger_value(c.ptr));

    _ = gc.set_trigger_value(true);
    try testing.expect(c.vtable.get_trigger_value(c.ptr));
}

test "extensions: DDS_StatusCondition_as_DDS_Condition with participant status condition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const sc = fx.dp_w.get_statuscondition();
    const c = sc.vtable.as_Condition(sc.ptr);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
}

test "extensions: DDS_ReadCondition_as_DDS_Condition with real ReadCondition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);

    const c = rc.vtable.as_Condition(rc.ptr);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
}

// ── Extension serialized take via ZZDDS DataReader vtable ─────────────────────

test "extensions: take_serialized via ZZDDS DataReader vtable" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &KEY_HASH, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    const zdr = zidl_rt.unboxAs(ZZDDS.DataReader, extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr.vtable.get_c_abi_handle(pair.dr.ptr)));
    var sample: ZZDDS.SerializedSample = std.mem.zeroes(ZZDDS.SerializedSample);
    const rc = zdr.vtable.take_serialized(zdr.ptr, &sample);
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expectEqual(@as(u32, @intCast(PAYLOAD.len)), sample.cdr._length);
    try testing.expect(sample.cdr._release);
    try testing.expectEqualSlices(u8, &PAYLOAD, sample.cdr._buffer.?[0..sample.cdr._length]);
    std.heap.c_allocator.free(sample.cdr._buffer.?[0..sample.cdr._maximum]);

    // Queue is now empty.
    var sample2: ZZDDS.SerializedSample = std.mem.zeroes(ZZDDS.SerializedSample);
    try testing.expectEqual(DDS.RETCODE_NO_DATA, zdr.vtable.take_serialized(zdr.ptr, &sample2));
}

// ── nRawImpl max≤0: unbounded take ───────────────────────────────────────────
//
// max=0 and max=-1 both mean "take all available samples" (unlimited).
// The implementation peeks with readRaw(-1) first to size the pre-allocation,
// then calls takeFiltered with the peeked count.

test "bootstrap: take_n_raw with max=0 takes all available samples" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var k1 = std.mem.zeroes([16]u8);
    k1[0] = 0xC1;
    var k2 = std.mem.zeroes([16]u8);
    k2[0] = 0xC2;
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k1, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw_boxed, &k2, DDS.HANDLE_NIL, &PAYLOAD, PAYLOAD.len);

    // max=0 means "unlimited" — takes all samples and returns their count.
    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_take_n_raw(pair.dr_boxed, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 0, &arr);
    try testing.expectEqual(@as(c_int, 2), n);
    try testing.expectEqual(@as(usize, 2), arr.count);
    try testing.expect(arr.samples != null);
    bootstrap.zzdds_return_raw_samples(pair.dr_boxed, &arr);

    // Queue is now empty.
    var arr2: bootstrap.CRawSampleArray = undefined;
    const n2 = bootstrap.zzdds_take_n_raw(pair.dr_boxed, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 0, &arr2);
    try testing.expectEqual(@as(c_int, 0), n2);
    try testing.expect(arr2.samples == null);
}

// ── Config: stringSeqSlice null-buffer and null-element guards ────────────────

test "generated: toRuntimeConfig returns NullBuffer when StringSeq has length>0 but null buffer" {
    const alloc = testing.allocator;
    var cfg = ZZDDS.DomainParticipantConfig.default();
    // interfaces has length=0 by default; set length=1 with null buffer.
    cfg.transport.udp.interfaces._length = 1;
    cfg.transport.udp.interfaces._buffer = null;
    try testing.expectError(error.NullBuffer, generated_config.toRuntimeConfig(alloc, &cfg));
}

// ── C-ABI handle coverage: get_c_abi_handle / as_Base on nil singletons ───────

test "nil singletons: get_c_abi_handle boxes every nil entity/condition view" {
    const np = zzdds.dcps.NIL_PTR;
    const nd = zzdds.dcps;

    // Every nil.* singleton's get_c_abi_handle must box (NIL_PTR, its own
    // vtable) rather than returning some raw sentinel, and must be
    // identity-stable across repeated calls, same as any real entity's.
    inline for (.{
        nd.nil_status_condition,
        nd.nil_entity,
        nd.nil_participant,
        nd.nil_publisher,
        nd.nil_subscriber,
        nd.nil_datawriter,
        nd.nil_datareader,
        nd.nil_topic_description,
        nd.nil_topic,
        nd.nil_cft,
        nd.nil_multitopic,
        nd.nil_condition,
        nd.nil_readcondition,
        nd.nil_querycondition,
        nd.nil_factory,
    }) |nil_handle| {
        const T = @TypeOf(nil_handle);
        const boxed = nil_handle.vtable.get_c_abi_handle(nil_handle.ptr);
        const unboxed = zidl_rt.unboxAs(T, boxed);
        try testing.expectEqual(np, unboxed.ptr);
        try testing.expectEqual(boxed, nil_handle.vtable.get_c_abi_handle(nil_handle.ptr));
    }
}

test "nil singletons: as_Base upcast slots return the correct nil singleton" {
    const nd = zzdds.dcps;

    const e1 = nd.nil_participant.vtable.as_Entity(nd.nil_participant.ptr);
    try testing.expectEqual(nd.nil_entity.ptr, e1.ptr);
    try testing.expectEqual(nd.nil_entity.vtable, e1.vtable);

    const c1 = nd.nil_status_condition.vtable.as_Condition(nd.nil_status_condition.ptr);
    try testing.expectEqual(nd.nil_condition.ptr, c1.ptr);
    try testing.expectEqual(nd.nil_condition.vtable, c1.vtable);

    const td1 = nd.nil_topic.vtable.as_TopicDescription(nd.nil_topic.ptr);
    try testing.expectEqual(nd.nil_topic_description.ptr, td1.ptr);
    try testing.expectEqual(nd.nil_topic_description.vtable, td1.vtable);

    const rc1 = nd.nil_querycondition.vtable.as_ReadCondition(nd.nil_querycondition.ptr);
    try testing.expectEqual(nd.nil_readcondition.ptr, rc1.ptr);
    try testing.expectEqual(nd.nil_readcondition.vtable, rc1.vtable);
}

// ── C-ABI handle coverage: extensions.zig nil-guard regression ────────────────

test "extensions: as_Base borrowed-view upcasts are safe on nil ZZDDS handles" {
    // Regression test for the nil-guard fix in participantAsDds / topicAsDds /
    // writerAsDds / readerAsDds: each used to @ptrCast(@alignCast(ctx)) without
    // checking ctx == NIL_PTR, which panics (safe builds) or is UB (ReleaseFast)
    // when a C caller downcasts a non-FactoryOwner handle (getting a nil ZZDDS
    // view back) and then upcasts it again via the generated as_Base export.
    const nd = zzdds.dcps;

    const nil_dp_boxed = nd.nil_participant.vtable.get_c_abi_handle(nd.nil_participant.ptr);
    const zdp_boxed = extensions.DDS_DomainParticipant_as_zzdds_DomainParticipant(nil_dp_boxed);
    const zdp = zidl_rt.unboxAs(ZZDDS.DomainParticipant, zdp_boxed);
    try testing.expectEqual(nd.NIL_PTR, zdp.ptr);
    const back_dp = zdp.vtable.as_DomainParticipant(zdp.ptr);
    try testing.expectEqual(nd.nil_participant.ptr, back_dp.ptr);
    try testing.expectEqual(nd.nil_participant.vtable, back_dp.vtable);

    const nil_topic_boxed = nd.nil_topic.vtable.get_c_abi_handle(nd.nil_topic.ptr);
    const ztopic_boxed = extensions.DDS_Topic_as_zzdds_Topic(nil_topic_boxed);
    const ztopic = zidl_rt.unboxAs(ZZDDS.Topic, ztopic_boxed);
    const back_topic = ztopic.vtable.as_Topic(ztopic.ptr);
    try testing.expectEqual(nd.nil_topic.ptr, back_topic.ptr);

    const nil_dw_boxed = nd.nil_datawriter.vtable.get_c_abi_handle(nd.nil_datawriter.ptr);
    const zdw_boxed = extensions.DDS_DataWriter_as_zzdds_DataWriter(nil_dw_boxed);
    const zdw = zidl_rt.unboxAs(ZZDDS.DataWriter, zdw_boxed);
    const back_dw = zdw.vtable.as_DataWriter(zdw.ptr);
    try testing.expectEqual(nd.nil_datawriter.ptr, back_dw.ptr);

    const nil_dr_boxed = nd.nil_datareader.vtable.get_c_abi_handle(nd.nil_datareader.ptr);
    const zdr_boxed = extensions.DDS_DataReader_as_zzdds_DataReader(nil_dr_boxed);
    const zdr = zidl_rt.unboxAs(ZZDDS.DataReader, zdr_boxed);
    const back_dr = zdr.vtable.as_DataReader(zdr.ptr);
    try testing.expectEqual(nd.nil_datareader.ptr, back_dr.ptr);
}

test "extensions: DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory rejects foreign handles" {
    const nd = zzdds.dcps;
    const nil_fac_boxed = nd.nil_factory.vtable.get_c_abi_handle(nd.nil_factory.ptr);
    const zf_boxed = extensions.DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(nil_fac_boxed);
    const zf = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, zf_boxed);
    try testing.expectEqual(nd.NIL_PTR, zf.ptr);
}

test "extensions: factory DDS-view get_c_abi_handle boxes nil handle correctly" {
    const alloc = testing.allocator;
    const boxed = try zidl_rt.boxEntity(alloc, zzdds.dcps.NIL_PTR, &extensions.factory_vtable);
    defer zidl_rt.freeEntityBox(alloc, boxed);
    const zf = zidl_rt.unboxAs(ZZDDS.DomainParticipantFactory, boxed);

    const dds_view = zf.vtable.as_DomainParticipantFactory(zf.ptr);
    const dds_boxed = dds_view.vtable.get_c_abi_handle(dds_view.ptr);
    const unboxed = zidl_rt.unboxAs(DDS.DomainParticipantFactory, dds_boxed);
    try testing.expectEqual(zzdds.dcps.NIL_PTR, unboxed.ptr);
}

test "extensions: zzdds_factory_is_nil distinguishes nil and real handles" {
    const alloc = testing.allocator;
    const nil_boxed = try zidl_rt.boxEntity(alloc, zzdds.dcps.NIL_PTR, &extensions.factory_vtable);
    defer zidl_rt.freeEntityBox(alloc, nil_boxed);
    try testing.expect(extensions.zzdds_factory_is_nil(nil_boxed));

    const real_boxed = extensions.zzdds_create_factory();
    defer extensions.zzdds_destroy_factory(real_boxed);
    try testing.expect(!extensions.zzdds_factory_is_nil(real_boxed));
}

// ── C-ABI handle coverage: real WaitSet / conditions ───────────────────────────

test "waitset: get_c_abi_handle boxes real WaitSet, conditions, and their Condition views" {
    const alloc = testing.allocator;

    const ws = try zzdds.dcps.WaitSetImpl.init(alloc);
    defer ws.deinit();
    const ws_dds = ws.toDDSWaitSet();
    const ws_boxed = ws_dds.vtable.get_c_abi_handle(ws_dds.ptr);
    try testing.expectEqual(ws_boxed, ws_dds.vtable.get_c_abi_handle(ws_dds.ptr));

    const gc = try GuardConditionImpl.init(alloc);
    defer gc.deinit();
    const gc_dds = gc.toDDSGuardCondition();
    _ = gc_dds.vtable.get_c_abi_handle(gc_dds.ptr);
    const gc_cond = gc.toCondition();
    _ = gc_cond.vtable.get_c_abi_handle(gc_cond.ptr);

    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const sc = fx.dp_w.get_statuscondition();
    _ = sc.vtable.get_c_abi_handle(sc.ptr);
    const sc_cond = sc.vtable.as_Condition(sc.ptr);
    _ = sc_cond.vtable.get_c_abi_handle(sc_cond.ptr);

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);
    _ = rc.vtable.get_c_abi_handle(rc.ptr);
    const rc_cond = rc.vtable.as_Condition(rc.ptr);
    _ = rc_cond.vtable.get_c_abi_handle(rc_cond.ptr);

    var empty_params = DDS.StringSeq{};
    const qc = pair.dr.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "", &empty_params);
    try testing.expect(qc.ptr != zzdds.dcps.NIL_PTR);
    defer qc.deinit();
    _ = qc.vtable.get_c_abi_handle(qc.ptr);
    const qc_as_rc = qc.vtable.as_ReadCondition(qc.ptr);
    try testing.expect(qc_as_rc.ptr != zzdds.dcps.NIL_PTR);
    _ = qc_as_rc.vtable.get_c_abi_handle(qc_as_rc.ptr);
}

// ── C-ABI handle coverage: real Topic / ContentFilteredTopic ──────────────────

test "topic: get_c_abi_handle boxes Topic, Entity, and TopicDescription views" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.topic_w.vtable.get_c_abi_handle(fx.topic_w.ptr);
    const ent = fx.topic_w.vtable.as_Entity(fx.topic_w.ptr);
    _ = ent.vtable.get_c_abi_handle(ent.ptr);
    const td = fx.topic_w.vtable.as_TopicDescription(fx.topic_w.ptr);
    _ = td.vtable.get_c_abi_handle(td.ptr);

    const cft = fx.dp_r.create_contentfilteredtopic("BootCft", fx.topic_r, "", &DDS.StringSeq{});
    defer _ = fx.dp_r.vtable.delete_contentfilteredtopic(fx.dp_r.ptr, cft);
    _ = cft.vtable.get_c_abi_handle(cft.ptr);
    const cft_td = cft.vtable.as_TopicDescription(cft.ptr);
    try testing.expect(cft_td.ptr != zzdds.dcps.NIL_PTR);
    _ = cft_td.vtable.get_c_abi_handle(cft_td.ptr);
}

// ── C-ABI handle coverage: real factory / participant / pub / sub / writer / reader ──

test "entities: get_c_abi_handle boxes every remaining real entity and Entity view" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const factory_dds = fx.factory_w.toDDSFactory();
    _ = factory_dds.vtable.get_c_abi_handle(factory_dds.ptr);

    _ = fx.dp_w.vtable.get_c_abi_handle(fx.dp_w.ptr);
    _ = fx.dp_w.vtable.as_Entity(fx.dp_w.ptr).vtable.get_c_abi_handle(fx.dp_w.vtable.as_Entity(fx.dp_w.ptr).ptr);

    _ = fx.pub_w.vtable.get_c_abi_handle(fx.pub_w.ptr);
    _ = fx.pub_w.vtable.as_Entity(fx.pub_w.ptr).vtable.get_c_abi_handle(fx.pub_w.vtable.as_Entity(fx.pub_w.ptr).ptr);

    _ = fx.sub_r.vtable.get_c_abi_handle(fx.sub_r.ptr);
    _ = fx.sub_r.vtable.as_Entity(fx.sub_r.ptr).vtable.get_c_abi_handle(fx.sub_r.vtable.as_Entity(fx.sub_r.ptr).ptr);

    _ = pair.dw.vtable.get_c_abi_handle(pair.dw.ptr);
    _ = pair.dw.vtable.as_Entity(pair.dw.ptr).vtable.get_c_abi_handle(pair.dw.vtable.as_Entity(pair.dw.ptr).ptr);

    _ = pair.dr.vtable.get_c_abi_handle(pair.dr.ptr);
    _ = pair.dr.vtable.as_Entity(pair.dr.ptr).vtable.get_c_abi_handle(pair.dr.vtable.as_Entity(pair.dr.ptr).ptr);
}
