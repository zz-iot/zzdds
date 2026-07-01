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

    fn makeWriterReader(self: *Fixture) struct { dw: DDS.DataWriter, dr: DDS.DataReader } {
        const td = @as(*TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        const dr = self.sub_r.create_datareader(td, .{}, null, 0);
        const dw = self.pub_w.create_datawriter(self.topic_w, .{}, null, 0);
        return .{ .dw = dw, .dr = dr };
    }
};

// ── Factory lifecycle ─────────────────────────────────────────────────────────

test "support factory: destroy_factory is safe on nil handle" {
    const nil_factory = ZZDDS.DomainParticipantFactory{ .ptr = zzdds.dcps.NIL_PTR, .vtable = undefined };
    extensions.zzdds_destroy_factory(nil_factory); // must not crash or call deinit
}

test "support factory: generated create_participant and delete_participant" {
    const ext_factory = extensions.zzdds_create_factory();
    defer extensions.zzdds_destroy_factory(ext_factory);

    const factory = extensions.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(ext_factory);
    const dp = DDS_DomainParticipantFactory_create_participant_for_test(factory, 0, null);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
}

test "support factory: generated create_participant_ex uses config defaults" {
    const ext_factory = extensions.zzdds_create_factory();
    defer extensions.zzdds_destroy_factory(ext_factory);

    const cfg = ZZDDS.DomainParticipantConfig.default();
    const qos = DDS.DomainParticipantQos{};
    const dp = ext_factory.create_participant_ex(0, qos, null, 0, cfg);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);

    const factory = extensions.zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(ext_factory);
    try testing.expectEqual(DDS.RETCODE_OK, factory.delete_participant(dp));
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

    const td = bootstrap.zzdds_topic_as_description(fx.topic_w);
    try testing.expectEqualStrings("BootTopic", std.mem.span(td.vtable.get_name(td.ptr)));
}

// ── write_raw + take_one_raw ──────────────────────────────────────────────────

test "bootstrap: write_raw and take_one_raw round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const rc = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);
    try testing.expectEqual(@as(DDS.ReturnCode_t, 0), rc);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
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

    const rc = bootstrap.zzdds_write_raw_kind(pair.dw, .dispose, &KEY_HASH, &PAYLOAD, PAYLOAD.len);
    try testing.expectEqual(@as(DDS.ReturnCode_t, 0), rc);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expect(!info.valid_data);
    try testing.expectEqual(DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, info.instance_state);
}

test "bootstrap: take_loaned_raw and return_loaned_raw" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    var loan: bootstrap.CLoanedSample = undefined;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_loaned_raw(pair.dr, &loan, &info);
    try testing.expectEqual(@as(c_int, 1), n);
    try testing.expect(info.valid_data);
    try testing.expectEqual(PAYLOAD.len, loan.data_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, loan.data.?[0..loan.data_len]);
    try testing.expect(loan.owner != null);

    bootstrap.zzdds_return_loaned_raw(pair.dr, &loan);
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
    const n = bootstrap.zzdds_take_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 0), n);
}

test "bootstrap: take_one_raw returns -1 when buffer too small" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    var tiny: [2]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr, &tiny, tiny.len, &cdr_len, &info);
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

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw_instance(pair.dr, 0, &buf, buf.len, &cdr_len, &info);
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
    const n = bootstrap.zzdds_take_one_raw_instance(pair.dr, 0, &buf, buf.len, &cdr_len, &info);
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
    const rc = bootstrap.zzdds_write_raw_w_timestamp(pair.dw, .alive, &KEY_HASH, &PAYLOAD, PAYLOAD.len, ts);
    try testing.expectEqual(@as(DDS.ReturnCode_t, 0), rc);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_take_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
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

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n1 = bootstrap.zzdds_read_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), n1);
    try testing.expectEqual(PAYLOAD.len, cdr_len);
    // Second read still returns the same sample.
    const n2 = bootstrap.zzdds_read_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
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
    const n = bootstrap.zzdds_read_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 0), n);
}

// ── read_one_raw_instance ─────────────────────────────────────────────────────

test "bootstrap: read_one_raw_instance round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const n = bootstrap.zzdds_read_one_raw_instance(pair.dr, 0, &buf, buf.len, &cdr_len, &info);
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
    const n = bootstrap.zzdds_read_one_raw_instance(pair.dr, 0, &buf, buf.len, &cdr_len, &info);
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
    _ = bootstrap.zzdds_write_raw(pair.dw, &k1, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw, &k2, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw, &k3, &PAYLOAD, PAYLOAD.len);

    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_take_n_raw(pair.dr, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 5, &arr);
    try testing.expectEqual(@as(c_int, 3), n);
    try testing.expectEqual(@as(usize, 3), arr.count);
    try testing.expect(arr.samples != null);
    // Verify first sample payload.
    const s0 = arr.samples.?[0];
    try testing.expectEqual(PAYLOAD.len, s0.data_len);
    try testing.expectEqualSlices(u8, &PAYLOAD, s0.data.?[0..s0.data_len]);

    bootstrap.zzdds_return_raw_samples(pair.dr, &arr);
    try testing.expectEqual(@as(usize, 0), arr.count);
    try testing.expect(arr.samples == null);

    // Queue is now empty.
    var arr2: bootstrap.CRawSampleArray = undefined;
    const n2 = bootstrap.zzdds_take_n_raw(pair.dr, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 5, &arr2);
    try testing.expectEqual(@as(c_int, 0), n2);
    try testing.expect(arr2.samples == null);
}

test "bootstrap: take_n_raw returns 0 when queue is empty" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_take_n_raw(pair.dr, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 10, &arr);
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
    _ = bootstrap.zzdds_write_raw(pair.dw, &k1, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw, &k2, &PAYLOAD, PAYLOAD.len);

    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_read_n_raw(pair.dr, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 10, &arr);
    try testing.expectEqual(@as(c_int, 2), n);
    bootstrap.zzdds_return_raw_samples(pair.dr, &arr);

    // Samples still in queue — take should succeed.
    var buf: [64]u8 = undefined;
    var cdr_len: usize = 0;
    var info: bootstrap.CSampleInfo = undefined;
    const m = bootstrap.zzdds_take_one_raw(pair.dr, &buf, buf.len, &cdr_len, &info);
    try testing.expectEqual(@as(c_int, 1), m);
}

// ── get_key_value_writer / lookup_instance_writer ─────────────────────────────

test "bootstrap: get_key_value_writer returns CDR payload after alive write" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    const ih = bootstrap.zzdds_register_instance_raw(pair.dw, &KEY_HASH);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_writer(pair.dw, ih, &buf, buf.len, &len);
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
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw, &dummy_key);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_writer(pair.dw, ih, &buf, buf.len, &len);
    try testing.expectEqual(@as(c_int, -1), rc);
}

test "bootstrap: lookup_instance_writer matches register_instance_raw" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const h1 = bootstrap.zzdds_register_instance_raw(pair.dw, &KEY_HASH);
    const h2 = bootstrap.zzdds_lookup_instance_writer(pair.dw, &KEY_HASH);
    try testing.expectEqual(h1, h2);
}

// ── get_key_value_reader / lookup_instance_reader ─────────────────────────────

test "bootstrap: get_key_value_reader returns CDR payload after receive" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    const ih = bootstrap.zzdds_register_instance_raw(pair.dw, &KEY_HASH);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_reader(pair.dr, ih, &buf, buf.len, &len);
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
    const ih = bootstrap.zzdds_register_instance_raw(pair.dw, &dummy_key);
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    const rc = bootstrap.zzdds_get_key_value_reader(pair.dr, ih, &buf, buf.len, &len);
    try testing.expectEqual(@as(c_int, -1), rc);
}

test "bootstrap: lookup_instance_reader returns handle for alive instance, 0 when not found" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    // Known alive instance returns its handle.
    const ih = bootstrap.zzdds_lookup_instance_reader(pair.dr, &KEY_HASH);
    try testing.expect(ih != 0);
    try testing.expectEqual(bootstrap.zzdds_register_instance_raw(pair.dw, &KEY_HASH), ih);

    // Unknown key returns 0 (HANDLE_NIL).
    var unknown_key: [16]u8 = undefined;
    @memset(&unknown_key, 0xFF);
    const ih2 = bootstrap.zzdds_lookup_instance_reader(pair.dr, &unknown_key);
    try testing.expectEqual(@as(DDS.InstanceHandle_t, 0), ih2);
}

// ── Conversion nil-guard tests ────────────────────────────────────────────────
//
// Every DDS_X_as_DDS_Y and zzdds_X_as_DDS_X function must return a nil handle
// when passed a nil input. These tests exercise the nil-guard branch at the top
// of each conversion function so it shows up as covered in kcov.

test "extensions: condition conversion functions return nil for nil handles" {
    const np = zzdds.dcps.NIL_PTR;

    const c1 = extensions.DDS_GuardCondition_as_DDS_Condition(.{ .ptr = np, .vtable = undefined });
    try testing.expectEqual(np, c1.ptr);

    const c2 = extensions.DDS_StatusCondition_as_DDS_Condition(.{ .ptr = np, .vtable = undefined });
    try testing.expectEqual(np, c2.ptr);

    const c3 = extensions.DDS_ReadCondition_as_DDS_Condition(.{ .ptr = np, .vtable = undefined });
    try testing.expectEqual(np, c3.ptr);

    const rc = extensions.DDS_QueryCondition_as_DDS_ReadCondition(.{ .ptr = np, .vtable = undefined });
    try testing.expectEqual(np, rc.ptr);
}

test "extensions: entity and topic-description conversion functions return nil for nil handles" {
    const np = zzdds.dcps.NIL_PTR;
    const nil_topic: DDS.Topic = .{ .ptr = np, .vtable = undefined };

    try testing.expectEqual(np, extensions.DDS_DomainParticipant_as_DDS_Entity(.{ .ptr = np, .vtable = undefined }).ptr);
    try testing.expectEqual(np, extensions.DDS_Topic_as_DDS_Entity(nil_topic).ptr);
    try testing.expectEqual(np, extensions.DDS_Publisher_as_DDS_Entity(.{ .ptr = np, .vtable = undefined }).ptr);
    try testing.expectEqual(np, extensions.DDS_DataWriter_as_DDS_Entity(.{ .ptr = np, .vtable = undefined }).ptr);
    try testing.expectEqual(np, extensions.DDS_Subscriber_as_DDS_Entity(.{ .ptr = np, .vtable = undefined }).ptr);
    try testing.expectEqual(np, extensions.DDS_DataReader_as_DDS_Entity(.{ .ptr = np, .vtable = undefined }).ptr);
    try testing.expectEqual(np, extensions.DDS_Topic_as_DDS_TopicDescription(nil_topic).ptr);
    try testing.expectEqual(np, extensions.DDS_ContentFilteredTopic_as_DDS_TopicDescription(.{ .ptr = np, .vtable = undefined }).ptr);
}

// ── Conversion valid-handle tests (using IntraProcess fixture) ────────────────

test "extensions: entity conversion functions return valid handles for real entities" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const np = zzdds.dcps.NIL_PTR;

    try testing.expect(extensions.DDS_DomainParticipant_as_DDS_Entity(fx.dp_w).ptr != np);
    try testing.expect(extensions.DDS_Topic_as_DDS_Entity(fx.topic_w).ptr != np);
    try testing.expect(extensions.DDS_Publisher_as_DDS_Entity(fx.pub_w).ptr != np);
    try testing.expect(extensions.DDS_Subscriber_as_DDS_Entity(fx.sub_r).ptr != np);
    try testing.expect(extensions.DDS_DataWriter_as_DDS_Entity(pair.dw).ptr != np);
    try testing.expect(extensions.DDS_DataReader_as_DDS_Entity(pair.dr).ptr != np);

    const td = extensions.DDS_Topic_as_DDS_TopicDescription(fx.topic_w);
    try testing.expect(td.ptr != np);
    try testing.expectEqualStrings("BootTopic", std.mem.span(td.vtable.get_name(td.ptr)));
}

test "extensions: DDS_DataReader_as_zzdds and back round-trip" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const np = zzdds.dcps.NIL_PTR;

    // DDS → ZZDDS
    const zdr = extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr);
    try testing.expect(zdr.ptr != np);

    // ZZDDS → DDS round-trip
    const ddr = extensions.zzdds_DataReader_as_DDS_DataReader(zdr);
    try testing.expect(ddr.ptr != np);
    try testing.expectEqual(pair.dr.ptr, ddr.ptr);

    // Same for DataWriter
    const zdw = extensions.DDS_DataWriter_as_zzdds_DataWriter(pair.dw);
    try testing.expect(zdw.ptr != np);
    const ddw = extensions.zzdds_DataWriter_as_DDS_DataWriter(zdw);
    try testing.expectEqual(pair.dw.ptr, ddw.ptr);
}

// ── Condition conversion valid-handle tests ───────────────────────────────────

test "extensions: DDS_GuardCondition_as_DDS_Condition with real GuardCondition" {
    const gc_impl = try GuardConditionImpl.init(testing.allocator);
    defer gc_impl.deinit();

    const gc = gc_impl.toDDSGuardCondition();
    const c = extensions.DDS_GuardCondition_as_DDS_Condition(gc);
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
    const c = extensions.DDS_StatusCondition_as_DDS_Condition(sc);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
}

test "extensions: DDS_ReadCondition_as_DDS_Condition with real ReadCondition" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    const rc = pair.dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    defer _ = pair.dr.delete_readcondition(rc);

    const c = extensions.DDS_ReadCondition_as_DDS_Condition(rc);
    try testing.expect(c.ptr != zzdds.dcps.NIL_PTR);
}

// ── Extension serialized take via ZZDDS DataReader vtable ─────────────────────

test "extensions: take_serialized via ZZDDS DataReader vtable" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();
    const pair = fx.makeWriterReader();

    _ = bootstrap.zzdds_write_raw(pair.dw, &KEY_HASH, &PAYLOAD, PAYLOAD.len);

    const zdr = extensions.DDS_DataReader_as_zzdds_DataReader(pair.dr);
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
    _ = bootstrap.zzdds_write_raw(pair.dw, &k1, &PAYLOAD, PAYLOAD.len);
    _ = bootstrap.zzdds_write_raw(pair.dw, &k2, &PAYLOAD, PAYLOAD.len);

    // max=0 means "unlimited" — takes all samples and returns their count.
    var arr: bootstrap.CRawSampleArray = undefined;
    const n = bootstrap.zzdds_take_n_raw(pair.dr, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 0, &arr);
    try testing.expectEqual(@as(c_int, 2), n);
    try testing.expectEqual(@as(usize, 2), arr.count);
    try testing.expect(arr.samples != null);
    bootstrap.zzdds_return_raw_samples(pair.dr, &arr);

    // Queue is now empty.
    var arr2: bootstrap.CRawSampleArray = undefined;
    const n2 = bootstrap.zzdds_take_n_raw(pair.dr, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, 0, &arr2);
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
