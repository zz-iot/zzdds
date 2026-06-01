//! Entity routing tests for DomainParticipantImpl.userDataOnReceive.
//!
//! Exercises: INFO_DST participant filtering, INFO_SRC src_prefix override,
//! direct entity-ID dispatch (reader_entity_id != ENTITYID_UNKNOWN),
//! and dispatchDirectedWrite (PID_DIRECTED_WRITE inline QoS) including
//! big-endian count decoding.
//!
//! Technique: use IntraProcessDelivery to create a matched writer/reader pair
//! (DirectDiscovery fires synchronously), then inject crafted raw RTPS bytes
//! via a second MemoryTransport on the same bus to the reader participant's
//! data port.  MemoryTransport.send() is synchronous, so assertions are immediate.

const std = @import("std");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const MemoryTransport = zzdds.memory_transport.MemoryTransport;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;

const EntityKind = zzdds.rtps.EntityKind;
const Locator = zzdds.transport.Locator;

// CDR-LE encapsulation header + 1 payload byte.
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xDE };

// ── RTPS message builder ──────────────────────────────────────────────────────

const Msg = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *Msg, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    fn bytes(self: *const Msg) []const u8 {
        return self.buf.items;
    }

    fn header(self: *Msg, alloc: std.mem.Allocator, prefix: [12]u8) !void {
        try self.buf.appendSlice(alloc, "RTPS");
        try self.buf.appendSlice(alloc, &[_]u8{ 2, 3, 0x01, 0x10 });
        try self.buf.appendSlice(alloc, &prefix);
    }

    /// INFO_DST submessage (16 bytes total).
    fn infoDst(self: *Msg, alloc: std.mem.Allocator, prefix: [12]u8) !void {
        var smh = [_]u8{ 0x0E, 0x01, 0, 0 };
        std.mem.writeInt(u16, smh[2..4], 12, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &prefix);
    }

    /// INFO_SRC submessage (24 bytes total).
    fn infoSrc(self: *Msg, alloc: std.mem.Allocator, prefix: [12]u8) !void {
        var smh = [_]u8{ 0x0C, 0x01, 0, 0 };
        std.mem.writeInt(u16, smh[2..4], 20, .little);
        try self.buf.appendSlice(alloc, &smh);
        // unused(4) + protocol_version(2) + vendor_id(2) + guid_prefix(12) = 20
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0, 2, 3, 1, 0x10 });
        try self.buf.appendSlice(alloc, &prefix);
    }

    /// DATA submessage with no inline QoS.
    fn data(
        self: *Msg,
        alloc: std.mem.Allocator,
        flags: u8,
        reader_eid: [4]u8,
        writer_eid: [4]u8,
        sn: u32,
        payload: []const u8,
    ) !void {
        // content = extraFlags(2) + octetsToInlineQos(2) + readerId(4) + writerId(4) + sn(8) + payload
        const content_len: u16 = 20 + @as(u16, @intCast(payload.len));
        var smh = [_]u8{ 0x15, flags, 0, 0 };
        std.mem.writeInt(u16, smh[2..4], content_len, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x10, 0 }); // extraFlags + octetsToInlineQos=16
        try self.buf.appendSlice(alloc, &reader_eid);
        try self.buf.appendSlice(alloc, &writer_eid);
        var sn_bytes: [8]u8 = undefined;
        std.mem.writeInt(i32, sn_bytes[0..4], 0, .little);
        std.mem.writeInt(u32, sn_bytes[4..8], sn, .little);
        try self.buf.appendSlice(alloc, &sn_bytes);
        try self.buf.appendSlice(alloc, payload);
    }

    /// DATA with PID_DIRECTED_WRITE inline QoS targeting one GUID.
    /// The count field uses the specified endian (matching the DATA submessage flags).
    fn dataDirectedWrite(
        self: *Msg,
        alloc: std.mem.Allocator,
        writer_eid: [4]u8,
        sn: u32,
        payload: []const u8,
        target_prefix: [12]u8,
        target_eid: [4]u8,
        endian: std.builtin.Endian,
    ) !void {
        // Inline QoS: PID_DIRECTED_WRITE param (4 hdr + 20 value) + sentinel (4) = 28 bytes.
        var iq: [28]u8 = undefined;
        std.mem.writeInt(u16, iq[0..2], 0x0057, endian); // PID_DIRECTED_WRITE
        std.mem.writeInt(u16, iq[2..4], 20, endian); // value length
        std.mem.writeInt(u32, iq[4..8], 1, endian); // count = 1 GUID
        @memcpy(iq[8..20], &target_prefix);
        @memcpy(iq[20..24], &target_eid);
        std.mem.writeInt(u16, iq[24..26], 0x0001, endian); // PID_SENTINEL
        std.mem.writeInt(u16, iq[26..28], 0, endian);

        const le_flag: u8 = if (endian == .little) 0x01 else 0x00;
        const flags: u8 = le_flag | 0x02 | 0x04; // inline_qos | data_present
        const content_len: u16 = 20 + 28 + @as(u16, @intCast(payload.len));
        var smh = [_]u8{ 0x15, flags, 0, 0 };
        // octets_to_next_header in the submessage header is always LE (RTPS §9.4.2).
        std.mem.writeInt(u16, smh[2..4], content_len, .little);
        try self.buf.appendSlice(alloc, &smh);
        // extraFlags and octetsToInlineQos follow the submessage's endianness.
        var hdr4: [4]u8 = undefined;
        std.mem.writeInt(u16, hdr4[0..2], 0, endian); // extraFlags
        std.mem.writeInt(u16, hdr4[2..4], 16, endian); // octetsToInlineQos = 16
        try self.buf.appendSlice(alloc, &hdr4);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // reader_eid = UNKNOWN
        try self.buf.appendSlice(alloc, &writer_eid);
        var sn_bytes: [8]u8 = undefined;
        std.mem.writeInt(i32, sn_bytes[0..4], 0, endian);
        std.mem.writeInt(u32, sn_bytes[4..8], sn, endian);
        try self.buf.appendSlice(alloc, &sn_bytes);
        try self.buf.appendSlice(alloc, &iq);
        try self.buf.appendSlice(alloc, payload);
    }

    /// HEARTBEAT submessage (content = 28 bytes).
    fn heartbeat(
        self: *Msg,
        alloc: std.mem.Allocator,
        reader_eid: [4]u8,
        writer_eid: [4]u8,
    ) !void {
        var smh = [_]u8{ 0x07, 0x01, 0, 0 }; // id=HEARTBEAT, LE
        std.mem.writeInt(u16, smh[2..4], 28, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &reader_eid);
        try self.buf.appendSlice(alloc, &writer_eid);
        // firstSN = 1, lastSN = 0 (empty), count = 1
        var payload: [20]u8 = undefined;
        std.mem.writeInt(i32, payload[0..4], 0, .little); // firstSN high
        std.mem.writeInt(u32, payload[4..8], 1, .little); // firstSN low
        std.mem.writeInt(i32, payload[8..12], 0, .little); // lastSN high
        std.mem.writeInt(u32, payload[12..16], 0, .little); // lastSN low
        std.mem.writeInt(i32, payload[16..20], 1, .little); // count
        try self.buf.appendSlice(alloc, &payload);
    }

    /// DATA_FRAG submessage (minimal: no inline QoS, 1-byte fragment payload).
    /// content = extraFlags(2)+octetsToInlineQos(2)+readerEid(4)+writerEid(4)+sn(8)+
    ///           fragStart(4)+fragCount(2)+fragSize(2)+dataSize(4)+payload = 32+payload.len
    fn dataFrag(
        self: *Msg,
        alloc: std.mem.Allocator,
        reader_eid: [4]u8,
        writer_eid: [4]u8,
        payload: []const u8,
    ) !void {
        const content_len: u16 = 32 + @as(u16, @intCast(payload.len));
        var smh = [_]u8{ 0x16, 0x01, 0, 0 }; // DATA_FRAG id, LE
        std.mem.writeInt(u16, smh[2..4], content_len, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x1C, 0 }); // extraFlags + octetsToInlineQos=28
        try self.buf.appendSlice(alloc, &reader_eid);
        try self.buf.appendSlice(alloc, &writer_eid);
        var fields: [20]u8 = undefined;
        std.mem.writeInt(i32, fields[0..4], 0, .little); // sn high
        std.mem.writeInt(u32, fields[4..8], 1, .little); // sn low
        std.mem.writeInt(u32, fields[8..12], 1, .little); // fragmentStartingNum
        std.mem.writeInt(u16, fields[12..14], 1, .little); // fragmentsInSubmessage
        std.mem.writeInt(u16, fields[14..16], @as(u16, @intCast(payload.len)), .little); // fragmentSize
        std.mem.writeInt(u32, fields[16..20], @as(u32, @intCast(payload.len)), .little); // dataSize
        try self.buf.appendSlice(alloc, &fields);
        try self.buf.appendSlice(alloc, payload);
    }

    /// HEARTBEAT_FRAG submessage (content = 24 bytes).
    fn heartbeatFrag(
        self: *Msg,
        alloc: std.mem.Allocator,
        reader_eid: [4]u8,
        writer_eid: [4]u8,
    ) !void {
        var smh = [_]u8{ 0x13, 0x01, 0, 0 }; // HEARTBEAT_FRAG id, LE
        std.mem.writeInt(u16, smh[2..4], 24, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &reader_eid);
        try self.buf.appendSlice(alloc, &writer_eid);
        var fields: [16]u8 = undefined;
        std.mem.writeInt(i32, fields[0..4], 0, .little); // sn high
        std.mem.writeInt(u32, fields[4..8], 1, .little); // sn low
        std.mem.writeInt(u32, fields[8..12], 1, .little); // lastFragmentNum
        std.mem.writeInt(i32, fields[12..16], 1, .little); // count
        try self.buf.appendSlice(alloc, &fields);
    }

    /// NACK_FRAG submessage (minimal: 0-bit fragment set, content = 28 bytes).
    fn nackFrag(
        self: *Msg,
        alloc: std.mem.Allocator,
        reader_eid: [4]u8,
        writer_eid: [4]u8,
    ) !void {
        var smh = [_]u8{ 0x12, 0x01, 0, 0 }; // NACK_FRAG id, LE
        std.mem.writeInt(u16, smh[2..4], 28, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &reader_eid);
        try self.buf.appendSlice(alloc, &writer_eid);
        var fields: [20]u8 = undefined;
        std.mem.writeInt(i32, fields[0..4], 0, .little); // sn high
        std.mem.writeInt(u32, fields[4..8], 1, .little); // sn low
        std.mem.writeInt(u32, fields[8..12], 1, .little); // fragmentNumberState.base
        std.mem.writeInt(u32, fields[12..16], 0, .little); // fragmentNumberState.numBits = 0
        std.mem.writeInt(i32, fields[16..20], 1, .little); // count
        try self.buf.appendSlice(alloc, &fields);
    }

    /// GAP submessage (minimal: 0-bit gap list, content = 28 bytes).
    fn gap(
        self: *Msg,
        alloc: std.mem.Allocator,
        reader_eid: [4]u8,
        writer_eid: [4]u8,
    ) !void {
        var smh = [_]u8{ 0x08, 0x01, 0, 0 }; // GAP id, LE
        std.mem.writeInt(u16, smh[2..4], 28, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &reader_eid);
        try self.buf.appendSlice(alloc, &writer_eid);
        var fields: [20]u8 = undefined;
        std.mem.writeInt(i32, fields[0..4], 0, .little); // gapStart high
        std.mem.writeInt(u32, fields[4..8], 1, .little); // gapStart low
        std.mem.writeInt(i32, fields[8..12], 0, .little); // gapList.base high
        std.mem.writeInt(u32, fields[12..16], 2, .little); // gapList.base low
        std.mem.writeInt(u32, fields[16..20], 0, .little); // gapList.numBits = 0
        try self.buf.appendSlice(alloc, &fields);
    }
};

// ── Fixture ───────────────────────────────────────────────────────────────────

/// Writer GUID is derived from the writer participant; reader GUID from the reader participant.
/// DirectDiscovery fires onWriterDiscovered / onReaderDiscovered synchronously, so both
/// sides are matched before any inject() call.
const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,

    // Writer side (provides the GUID for isWriterMatched checks).
    t_w: *MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    dp_w_impl: *DomainParticipantImpl,

    // Reader side (receives injected bytes through userDataOnReceive).
    t_r: *MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    dp_r_impl: *DomainParticipantImpl,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    // Second transport on the same bus used to inject raw RTPS bytes.
    injector: *MemoryTransport,

    fn init(alloc: std.mem.Allocator) !Fixture {
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        const t_w = try delivery.newTransport();
        errdefer t_w.deinit();
        const d_w = try delivery.newDiscovery();
        errdefer d_w.deinit();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_w.deinit();
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const dp_w_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp_w.ptr));

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, nil.nil_dp_listener, 0);
        const dp_r_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp_r.ptr));

        const sub_r = dp_r.vtable.create_subscriber(dp_r.ptr, .{}, nil.nil_sub_listener, 0);
        const topic_r = dp_r.vtable.create_topic(dp_r.ptr, "RouteTopic", "RouteType", .{}, nil.nil_topic_listener, 0);

        const injector = try delivery.newTransport();
        errdefer injector.deinit();

        return .{
            .alloc = alloc,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .dp_w_impl = dp_w_impl,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .dp_r_impl = dp_r_impl,
            .sub_r = sub_r,
            .topic_r = topic_r,
            .injector = injector,
        };
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        self.factory_r.deinit();
        self.d_r.deinit();
        self.t_r.deinit();
        self.factory_w.deinit();
        self.d_w.deinit();
        self.t_w.deinit();
        self.injector.deinit();
        self.delivery.deinit();
    }

    /// Create a DataWriter on the writer side for a given topic (used only to trigger
    /// onWriterDiscovered on the reader side so the reader has a matched writer).
    fn makeWriter(self: *Fixture) *DataWriterImpl {
        const pub_w = self.dp_w.vtable.create_publisher(self.dp_w.ptr, .{}, nil.nil_pub_listener, 0);
        const topic_w = self.dp_w.vtable.create_topic(self.dp_w.ptr, "RouteTopic", "RouteType", .{}, nil.nil_topic_listener, 0);
        const dw = pub_w.vtable.create_datawriter(pub_w.ptr, topic_w, .{}, nil.nil_dw_listener, 0);
        return @as(*DataWriterImpl, @ptrCast(@alignCast(dw.ptr)));
    }

    /// Create a BEST_EFFORT DataReader on the reader side.
    fn makeReader(self: *Fixture) *DataReaderImpl {
        const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(self.topic_r.ptr))).toTopicDescription();
        var qos = DDS.DataReaderQos{};
        qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
        const dr = self.sub_r.vtable.create_datareader(self.sub_r.ptr, td, qos, nil.nil_dr_listener, 0);
        return @as(*DataReaderImpl, @ptrCast(@alignCast(dr.ptr)));
    }

    /// Inject raw RTPS bytes to the reader participant's data port.
    fn inject(self: *Fixture, raw: []const u8) !void {
        const port = self.dp_r_impl.data_listen_port;
        const dest = Locator.udp4(.{ 0, 0, 0, 0 }, port);
        try self.injector.transport().send(&dest, raw);
    }

    fn pendingCount(dr: *DataReaderImpl) usize {
        dr.mu.lock();
        defer dr.mu.unlock();
        return dr.pending.items.len;
    }

    /// Return the entity ID bytes for the first active writer on the writer side.
    fn writerEid(self: *Fixture) [4]u8 {
        self.dp_w_impl.mu.lock();
        defer self.dp_w_impl.mu.unlock();
        var it = self.dp_w_impl.active_writers.valueIterator();
        const aw = it.next() orelse unreachable;
        return [4]u8{
            aw.guid.entity_id.entity_key[0],
            aw.guid.entity_id.entity_key[1],
            aw.guid.entity_id.entity_key[2],
            aw.guid.entity_id.entity_kind,
        };
    }

    /// Return the entity ID bytes for the first active reader on the reader side.
    fn readerEid(self: *Fixture) [4]u8 {
        self.dp_r_impl.mu.lock();
        defer self.dp_r_impl.mu.unlock();
        var it = self.dp_r_impl.active_readers.valueIterator();
        const ar = it.next() orelse unreachable;
        return [4]u8{
            ar.guid.entity_id.entity_key[0],
            ar.guid.entity_id.entity_key[1],
            ar.guid.entity_id.entity_key[2],
            ar.guid.entity_id.entity_kind,
        };
    }

    /// Inject raw RTPS bytes to the writer participant's data port.
    /// Used for submessages that target writers (e.g. NACK_FRAG).
    fn injectToWriterSide(self: *Fixture, raw: []const u8) !void {
        const port = self.dp_w_impl.data_listen_port;
        const dest = Locator.udp4(.{ 0, 0, 0, 0 }, port);
        try self.injector.transport().send(&dest, raw);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "entity_routing: ENTITYID_UNKNOWN fan-out delivers to matched reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.data(alloc, 0x05, [_]u8{ 0, 0, 0, 0 }, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: direct reader_entity_id dispatch delivers to target reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.data(alloc, 0x05, r_eid, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: direct dispatch to wrong entity ID delivers nothing" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const wrong_eid = [_]u8{ 0x00, 0x00, 0x99, EntityKind.user_reader_with_key };

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.data(alloc, 0x05, wrong_eid, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 0), Fixture.pendingCount(dr));
}

test "entity_routing: INFO_DST matching this participant passes through" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const my_prefix = fx.dp_r_impl.guid.prefix.bytes;

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.infoDst(alloc, my_prefix);
    try msg.data(alloc, 0x05, [_]u8{ 0, 0, 0, 0 }, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: INFO_DST for different participant drops the message" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const other_prefix = [_]u8{0xBB} ** 12;

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.infoDst(alloc, other_prefix);
    try msg.data(alloc, 0x05, [_]u8{ 0, 0, 0, 0 }, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 0), Fixture.pendingCount(dr));
}

test "entity_routing: INFO_DST GUIDPREFIX_UNKNOWN broadcasts to all participants" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const unknown_prefix = std.mem.zeroes([12]u8);

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.infoDst(alloc, unknown_prefix);
    try msg.data(alloc, 0x05, [_]u8{ 0, 0, 0, 0 }, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: INFO_SRC overrides src_prefix for subsequent submessages" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    // The message header uses a different (unmatched) prefix, but INFO_SRC provides
    // the real writer prefix — which the reader has matched against.
    const real_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const fake_header_prefix = [_]u8{0xFF} ** 12;

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, fake_header_prefix);
    try msg.infoSrc(alloc, real_prefix);
    try msg.data(alloc, 0x05, [_]u8{ 0, 0, 0, 0 }, w_eid, 1, &PAYLOAD);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: dispatchDirectedWrite LE delivers to targeted reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const my_prefix = fx.dp_r_impl.guid.prefix.bytes;
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.dataDirectedWrite(alloc, w_eid, 1, &PAYLOAD, my_prefix, r_eid, .little);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: dispatchDirectedWrite BE delivers to targeted reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const my_prefix = fx.dp_r_impl.guid.prefix.bytes;
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    // Big-endian DATA: dispatchDirectedWrite must read count as big-endian.
    try msg.dataDirectedWrite(alloc, w_eid, 1, &PAYLOAD, my_prefix, r_eid, .big);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 1), Fixture.pendingCount(dr));
}

test "entity_routing: dispatchDirectedWrite prefix mismatch delivers nothing" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    const dr = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const other_prefix = [_]u8{0xDD} ** 12;
    const some_eid = [_]u8{ 0x00, 0x00, 0x01, EntityKind.user_reader_with_key };

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.dataDirectedWrite(alloc, w_eid, 1, &PAYLOAD, other_prefix, some_eid, .little);
    try fx.inject(msg.bytes());

    try testing.expectEqual(@as(usize, 0), Fixture.pendingCount(dr));
}

// ── Coverage: submessage types not exercised by existing tests ────────────────

test "entity_routing: HEARTBEAT ENTITYID_UNKNOWN fans out to all readers" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    // reader_entity_id = UNKNOWN → exercises the fan-out path (1278–1280).
    try msg.heartbeat(alloc, [_]u8{ 0, 0, 0, 0 }, w_eid);
    try fx.inject(msg.bytes());
}

test "entity_routing: DATA_FRAG ENTITYID_UNKNOWN fans out to all readers" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.dataFrag(alloc, [_]u8{ 0, 0, 0, 0 }, w_eid, &PAYLOAD);
    try fx.inject(msg.bytes());
}

test "entity_routing: DATA_FRAG direct dispatch to specific reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.dataFrag(alloc, r_eid, w_eid, &PAYLOAD);
    try fx.inject(msg.bytes());
}

test "entity_routing: HEARTBEAT_FRAG ENTITYID_UNKNOWN fans out to all readers" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.heartbeatFrag(alloc, [_]u8{ 0, 0, 0, 0 }, w_eid);
    try fx.inject(msg.bytes());
}

test "entity_routing: HEARTBEAT_FRAG direct dispatch to specific reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.heartbeatFrag(alloc, r_eid, w_eid);
    try fx.inject(msg.bytes());
}

test "entity_routing: NACK_FRAG routes to matched writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // makeWriter() creates the writer on dp_w; NACK_FRAG is sent by the reader side
    // back to the writer side participant's data port.
    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_r_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.nackFrag(alloc, r_eid, w_eid);
    try fx.injectToWriterSide(msg.bytes());
}

test "entity_routing: GAP ENTITYID_UNKNOWN fans out to all readers" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.gap(alloc, [_]u8{ 0, 0, 0, 0 }, w_eid);
    try fx.inject(msg.bytes());
}

test "entity_routing: GAP direct dispatch to specific reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    _ = fx.makeWriter();
    _ = fx.makeReader();

    const src_prefix = fx.dp_w_impl.guid.prefix.bytes;
    const w_eid = fx.writerEid();
    const r_eid = fx.readerEid();

    var msg = Msg{};
    defer msg.deinit(alloc);
    try msg.header(alloc, src_prefix);
    try msg.gap(alloc, r_eid, w_eid);
    try fx.inject(msg.bytes());
}
