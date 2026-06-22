//! Tests for the C-ABI bootstrap shim (src/c_abi/bootstrap.zig).
//!
//! - UDP lifecycle test: zzdds_create_participant_udp + zzdds_destroy_participant
//! - Write/take tests: use IntraProcessDelivery for synchronous delivery so
//!   no timing sensitivity; the write/take functions work on any DDS entity handle.
//! - topic_as_description: verified against the CFT TopicDescription vtable.

const std = @import("std");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const bootstrap = zzdds.c_abi.bootstrap;
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
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

// ── UDP lifecycle ─────────────────────────────────────────────────────────────

test "bootstrap: create_participant_udp returns non-nil participant" {
    const dp = bootstrap.zzdds_create_participant_udp(0, null);
    defer bootstrap.zzdds_destroy_participant(dp);
    try testing.expect(dp.ptr != zzdds.dcps.NIL_PTR);
}

test "bootstrap: destroy_participant is safe on nil participant" {
    bootstrap.zzdds_destroy_participant(std.mem.zeroes(DDS.DomainParticipant));
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
    try testing.expectEqualSlices(u8, &PAYLOAD, loan.data[0..loan.data_len]);
    try testing.expect(loan.owner != null);

    bootstrap.zzdds_return_loaned_raw(pair.dr, &loan);
    try testing.expectEqual(@as(usize, 0), loan.data_len);
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
