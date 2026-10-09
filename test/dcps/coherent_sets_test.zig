//! Coherent sets on the receive path (RTPS 2.5 §8.7.6).
//!
//! A writer's coherent set ends with a sample of its next set, a sample
//! outside any set, or an end marker (a DATA without a payload) -- never a
//! HEARTBEAT, which only says which samples the writer has.  The set is
//! complete when every SN from its first sample up to the change that ends it
//! arrived; an incomplete set is discarded.  In GROUP scope the subscriber
//! assembles each publisher's group set from its readers' parts by
//! PID_GROUP_COHERENT_SET, not by their position in each reader's queue.
//!
//! Technique (as in entity_routing_test.zig): IntraProcessDelivery matches
//! writer/reader pairs synchronously, then crafted RTPS bytes sent through a
//! second MemoryTransport stand in for those writers' traffic.
const std = @import("std");
const test_domain = @import("test_domain");
const testing = std.testing;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const MemoryTransport = zzdds.memory_transport.MemoryTransport;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const Locator = zzdds.transport.Locator;

// CDR-LE encapsulation header + payload, padded to a multiple of 4.
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xDE, 0x00, 0x00, 0x00 };

/// One DATA submessage to inject.
const Data = struct {
    sn: u32,
    /// PID_COHERENT_SET; null = none.
    cs: ?u32 = null,
    /// PID_COHERENT_SET = SEQUENCENUMBER_UNKNOWN instead (RTPS 2.5 Table 9.22
    /// Example 2).
    cs_unknown: bool = false,
    /// PID_GROUP_SEQ_NUM; null = none.
    gsn: ?u32 = null,
    /// PID_GROUP_COHERENT_SET; null = none.
    gcs: ?u32 = null,
    /// False for an end marker.
    payload: bool = true,
};

const Msg = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *Msg, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    fn header(self: *Msg, alloc: std.mem.Allocator, prefix: [12]u8) !void {
        try self.buf.appendSlice(alloc, "RTPS");
        try self.buf.appendSlice(alloc, &[_]u8{ 2, 3, 0x01, 0x10 });
        try self.buf.appendSlice(alloc, &prefix);
    }

    fn appendSn(self: *Msg, alloc: std.mem.Allocator, sn: u32) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(i32, b[0..4], 0, .little);
        std.mem.writeInt(u32, b[4..8], sn, .little);
        try self.buf.appendSlice(alloc, &b);
    }

    fn snParam(self: *Msg, alloc: std.mem.Allocator, pid: u8, sn: ?u32) !void {
        const v = sn orelse return;
        try self.buf.appendSlice(alloc, &[_]u8{ pid, 0x00, 0x08, 0x00 });
        try self.appendSn(alloc, v);
    }

    /// DATA (LE), from writer `writer_eid` to every reader of the participant.
    fn data(self: *Msg, alloc: std.mem.Allocator, writer_eid: [4]u8, d: Data) !void {
        var iqos_len: u16 = 0;
        if (d.cs != null or d.cs_unknown) iqos_len += 12;
        if (d.gsn != null) iqos_len += 12;
        if (d.gcs != null) iqos_len += 12;
        if (iqos_len > 0) iqos_len += 4; // PID_SENTINEL
        const payload_len: u16 = if (d.payload) PAYLOAD.len else 0;
        // extraFlags(2) + octetsToInlineQos(2) + readerId(4) + writerId(4) + sn(8)
        var smh = [_]u8{ 0x15, 0x01, 0, 0 }; // DATA, E
        if (iqos_len > 0) smh[1] |= 0x02; // Q
        if (d.payload) smh[1] |= 0x04; // D
        std.mem.writeInt(u16, smh[2..4], 20 + iqos_len + payload_len, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x10, 0 }); // octetsToInlineQos = 16
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // ENTITYID_UNKNOWN
        try self.buf.appendSlice(alloc, &writer_eid);
        try self.appendSn(alloc, d.sn);
        try self.snParam(alloc, 0x56, d.cs); // PID_COHERENT_SET
        if (d.cs_unknown) {
            // PID_COHERENT_SET = SEQUENCENUMBER_UNKNOWN {high = -1, low = 0}
            try self.buf.appendSlice(alloc, &[_]u8{ 0x56, 0x00, 0x08, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0 });
        }
        try self.snParam(alloc, 0x64, d.gsn); // PID_GROUP_SEQ_NUM
        try self.snParam(alloc, 0x63, d.gcs); // PID_GROUP_COHERENT_SET
        if (iqos_len > 0) try self.buf.appendSlice(alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }); // PID_SENTINEL
        if (d.payload) try self.buf.appendSlice(alloc, &PAYLOAD);
    }

    /// DATA_FRAG (LE) carrying fragment `frag` (1-based) of a sample of
    /// PAYLOAD split into 4-byte fragments; fragment 1 carries PID_COHERENT_SET.
    fn dataFrag(self: *Msg, alloc: std.mem.Allocator, writer_eid: [4]u8, sn: u32, frag: u32, cs: u32) !void {
        const iqos_len: u16 = if (frag == 1) 16 else 0;
        var smh = [_]u8{ 0x16, 0x01, 0, 0 }; // DATA_FRAG, E
        if (frag == 1) smh[1] |= 0x02; // Q
        // extraFlags(2) + octetsToInlineQos(2) + ids(8) + sn(8) + fragStart(4)
        // + fragsInSubmessage(2) + fragSize(2) + sampleSize(4) + fragment(4)
        std.mem.writeInt(u16, smh[2..4], 32 + iqos_len + 4, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 28, 0 }); // octetsToInlineQos = 28
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // ENTITYID_UNKNOWN
        try self.buf.appendSlice(alloc, &writer_eid);
        try self.appendSn(alloc, sn);
        var f: [12]u8 = undefined;
        std.mem.writeInt(u32, f[0..4], frag, .little);
        std.mem.writeInt(u16, f[4..6], 1, .little);
        std.mem.writeInt(u16, f[6..8], 4, .little);
        std.mem.writeInt(u32, f[8..12], PAYLOAD.len, .little);
        try self.buf.appendSlice(alloc, &f);
        if (frag == 1) {
            try self.snParam(alloc, 0x56, cs); // PID_COHERENT_SET
            try self.buf.appendSlice(alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }); // PID_SENTINEL
        }
        try self.buf.appendSlice(alloc, PAYLOAD[(frag - 1) * 4 ..][0..4]);
    }

    /// GAP for SNs [first, end): the writer will never send them.
    fn gap(self: *Msg, alloc: std.mem.Allocator, writer_eid: [4]u8, first: u32, end: u32) !void {
        try self.buf.appendSlice(alloc, &[_]u8{ 0x08, 0x01, 28, 0 }); // GAP, E
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // ENTITYID_UNKNOWN
        try self.buf.appendSlice(alloc, &writer_eid);
        try self.appendSn(alloc, first);
        try self.appendSn(alloc, end); // gapList.bitmapBase
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // numBits = 0
    }

    fn heartbeat(self: *Msg, alloc: std.mem.Allocator, writer_eid: [4]u8, first: u32, last: u32, count: i32) !void {
        var smh = [_]u8{ 0x07, 0x01, 0, 0 }; // HEARTBEAT, LE
        std.mem.writeInt(u16, smh[2..4], 28, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // ENTITYID_UNKNOWN
        try self.buf.appendSlice(alloc, &writer_eid);
        try self.appendSn(alloc, first);
        try self.appendSn(alloc, last);
        var c: [4]u8 = undefined;
        std.mem.writeInt(i32, &c, count, .little);
        try self.buf.appendSlice(alloc, &c);
    }
};

const MAX_TOPICS = 2;

/// A publisher with one writer per topic and a subscriber with one reader per
/// topic, both with coherent access at `scope`, matched in-process.  `inject`
/// sends crafted traffic as if from those writers.
const Fixture = struct {
    alloc: std.mem.Allocator,
    delivery: IntraProcessDelivery,
    t_w: *MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    t_r: *MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    injector: *MemoryTransport,
    sub_r: DDS.Subscriber,
    readers: [MAX_TOPICS]*DataReaderImpl = undefined,
    writer_eids: [MAX_TOPICS][4]u8 = undefined,
    dest: Locator,
    prefix: [12]u8,

    fn init(
        self: *Fixture,
        alloc: std.mem.Allocator,
        scope: DDS.PresentationQosPolicyAccessScopeKind,
        n_topics: usize,
        dr_qos: DDS.DataReaderQos,
        reliable: bool,
    ) !void {
        var delivery = try IntraProcessDelivery.init(alloc);
        const t_w = try delivery.newTransport();
        const d_w = try delivery.newDiscovery();
        const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
        const dp_w = factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        const t_r = try delivery.newTransport();
        const d_r = try delivery.newDiscovery();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);

        var pub_qos = DDS.PublisherQos{};
        pub_qos.presentation.coherent_access = true;
        pub_qos.presentation.access_scope = scope;
        const pub_w = dp_w.create_publisher(pub_qos, null, 0);
        var sub_qos = DDS.SubscriberQos{};
        sub_qos.presentation.coherent_access = true;
        sub_qos.presentation.access_scope = scope;
        const sub_r = dp_r.create_subscriber(sub_qos, null, 0);

        self.* = .{
            .alloc = alloc,
            .delivery = delivery,
            .t_w = t_w,
            .d_w = d_w,
            .factory_w = factory_w,
            .dp_w = dp_w,
            .t_r = t_r,
            .d_r = d_r,
            .factory_r = factory_r,
            .dp_r = dp_r,
            .injector = try delivery.newTransport(),
            .sub_r = sub_r,
            .dest = Locator.udp4(.{ 0, 0, 0, 0 }, @as(*DomainParticipantImpl, @ptrCast(@alignCast(dp_r.ptr))).data_listen_port),
            .prefix = @as(*DomainParticipantImpl, @ptrCast(@alignCast(dp_w.ptr))).guid.prefix.bytes,
        };

        const names = [MAX_TOPICS][:0]const u8{ "CoherentT0", "CoherentT1" };
        for (0..n_topics) |i| {
            const topic_w = dp_w.create_topic(names[i], "CoherentType", .{}, null, 0);
            var dw_qos = DDS.DataWriterQos{};
            dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
            dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
            const dw = pub_w.create_datawriter(topic_w, dw_qos, null, 0);
            const id = @as(*DataWriterImpl, @ptrCast(@alignCast(dw.ptr))).guid.entity_id;
            self.writer_eids[i] = .{ id.entity_key[0], id.entity_key[1], id.entity_key[2], id.entity_kind };

            const topic_r = dp_r.create_topic(names[i], "CoherentType", .{}, null, 0);
            const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
            var qos = dr_qos;
            qos.reliability.kind = if (reliable) .RELIABLE_RELIABILITY_QOS else .BEST_EFFORT_RELIABILITY_QOS;
            qos.history.kind = .KEEP_ALL_HISTORY_QOS;
            const dr = sub_r.create_datareader(td, qos, null, 0);
            self.readers[i] = @ptrCast(@alignCast(dr.ptr));
        }
    }

    fn deinit(self: *Fixture) void {
        self.injector.deinit();
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

    /// Send one RTPS message, as if from the writer participant.
    fn inject(self: *Fixture, build: anytype) !void {
        var msg = Msg{};
        defer msg.deinit(self.alloc);
        try msg.header(self.alloc, self.prefix);
        try build.add(self.alloc, &msg, self.writer_eids);
        try self.injector.transport().send(&self.dest, msg.buf.items);
    }

    /// begin_access, then the number of samples each reader exposes.
    fn access(self: *Fixture, n_topics: usize) ![MAX_TOPICS]usize {
        try testing.expectEqual(DDS.RETCODE_OK, self.sub_r.begin_access());
        var out = [_]usize{0} ** MAX_TOPICS;
        for (0..n_topics) |i| {
            const r = self.readers[i];
            r.mu.lock();
            defer r.mu.unlock();
            out[i] = r.pending.items.len;
        }
        // Drop what was exposed, as a take would.
        for (0..n_topics) |i| {
            while (self.readers[i].takeRaw()) |s| self.alloc.free(s.data);
        }
        try testing.expectEqual(DDS.RETCODE_OK, self.sub_r.end_access());
        return out;
    }
};

const State = struct { wip: usize, committed_sets: usize, first_set_len: usize };

fn state(r: *DataReaderImpl) State {
    r.mu.lock();
    defer r.mu.unlock();
    var wip: usize = 0;
    var it = r.coherent_wip.valueIterator();
    while (it.next()) |e| wip += e.samples.items.len;
    var sets: usize = 0;
    var first_len: usize = 0;
    for (r.coherent_committed.items) |cs| {
        if (!cs.complete) continue;
        if (sets == 0) first_len = cs.samples.items.len;
        sets += 1;
    }
    return .{ .wip = wip, .committed_sets = sets, .first_set_len = first_len };
}

test "coherent set: a HEARTBEAT in the middle of a set does not commit it" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, true);
    defer fx.deinit();
    const r = fx.readers[0];

    // The first two samples of the set starting at SN 1, then a HEARTBEAT
    // announcing them: the writer has more of the set to come.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1 });
            try m.heartbeat(alloc, w[0], 1, 2, 100);
        }
    });
    try testing.expectEqual(State{ .wip = 2, .committed_sets = 0, .first_set_len = 0 }, state(r));

    // The set's last sample, then the first sample of the next set ends it.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 3, .cs = 1 });
            try m.heartbeat(alloc, w[0], 1, 3, 101);
            try m.data(alloc, w[0], .{ .sn = 4, .cs = 4 });
        }
    });
    try testing.expectEqual(State{ .wip = 1, .committed_sets = 1, .first_set_len = 3 }, state(r));
}

test "coherent set: a set missing an SN is discarded" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, true);
    defer fx.deinit();
    const r = fx.readers[0];

    // SN 3 of the set starting at SN 1 is gone (GAP): the set ends at its end
    // marker incomplete and is discarded.  The next set arrives whole.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1 });
            try m.gap(alloc, w[0], 3, 4);
            try m.data(alloc, w[0], .{ .sn = 4, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 5, .payload = false });
            try m.data(alloc, w[0], .{ .sn = 6, .cs = 6 });
            try m.data(alloc, w[0], .{ .sn = 7, .cs = 6 });
            try m.data(alloc, w[0], .{ .sn = 8, .payload = false });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 2 }, state(r));
    try testing.expectEqual(@as(usize, 2), (try fx.access(1))[0]);
}

test "coherent set: a reader that matched in the middle of a set discards that set" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, true);
    defer fx.deinit();
    const r = fx.readers[0];

    // SNs 1-2 predate the reader (GAPed, as a volatile writer does); the set
    // they began (PID_COHERENT_SET 1) is incomplete for it.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.gap(alloc, w[0], 1, 3);
            try m.data(alloc, w[0], .{ .sn = 3, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 4, .payload = false });
            try m.data(alloc, w[0], .{ .sn = 5, .cs = 5 });
            try m.data(alloc, w[0], .{ .sn = 6, .payload = false });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 1 }, state(r));
}

test "coherent set: a sample the reader filters out still counts toward its set" {
    // RTPS 2.5 §8.7.6 leaves samples filtered by content or time out of what
    // the reader must receive.  Both samples share a source timestamp (no
    // INFO_TS: the receive time), so a 10 s TIME_BASED_FILTER drops SN 2.
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.time_based_filter.minimum_separation = .{ .sec = 10, .nanosec = 0 };
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, dr_qos, true);
    defer fx.deinit();
    const r = fx.readers[0];

    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 3, .payload = false });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 1 }, state(r));
}

test "group coherent set: waits for every writer's part, assembled by id, not position" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .GROUP_PRESENTATION_QOS, 2, .{}, true);
    defer fx.deinit();

    // Group set 1 (GSNs 1-4) and group set 6 (GSNs 6-7): two samples, then one,
    // from writer 0, each ended by an End Coherent Set marker.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1, .gsn = 1, .gcs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1, .gsn = 2, .gcs = 1 });
            try m.data(alloc, w[0], .{ .sn = 3, .gsn = 5, .gcs = 1, .payload = false });
            try m.data(alloc, w[0], .{ .sn = 4, .cs = 4, .gsn = 6, .gcs = 6 });
            try m.data(alloc, w[0], .{ .sn = 5, .gsn = 8, .gcs = 6, .payload = false });
        }
    });
    // Writer 1 matched but has sent nothing: its parts may still be coming.
    try testing.expectEqual([_]usize{ 0, 0 }, try fx.access(2));

    // Writer 1's part of set 1 never reaches its reader (GAPed); its part of
    // set 6 does.  Set 1 is incomplete, so it goes, and set 6 comes out whole
    // -- where pairing each reader's oldest set would pair writer 0's set 1
    // with writer 1's set 6.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.gap(alloc, w[1], 1, 3);
            try m.data(alloc, w[1], .{ .sn = 3, .gsn = 5, .gcs = 1, .payload = false });
            try m.data(alloc, w[1], .{ .sn = 4, .cs = 4, .gsn = 7, .gcs = 6 });
            try m.data(alloc, w[1], .{ .sn = 5, .gsn = 8, .gcs = 6, .payload = false });
        }
    });
    try testing.expectEqual([_]usize{ 1, 1 }, try fx.access(2));
    try testing.expectEqual([_]usize{ 0, 0 }, try fx.access(2));
}

test "group coherent set: a part still arriving holds the set back past the idle gate" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .GROUP_PRESENTATION_QOS, 2, .{}, true);
    defer fx.deinit();

    // Group set 1: writer 0's part arrives whole; writer 1's first sample
    // arrives, the rest of its part has yet to.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1, .gsn = 1, .gcs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .gsn = 4, .gcs = 1, .payload = false });
            try m.data(alloc, w[1], .{ .sn = 1, .cs = 1, .gsn = 2, .gcs = 1 });
        }
    });
    // Longer than the idle gate since either writer was last heard from: a
    // part in progress still holds the set back.
    for (fx.readers[0..2]) |r| {
        r.mu.lock();
        defer r.mu.unlock();
        var it = r.coherent_writers.valueIterator();
        while (it.next()) |cw| cw.last_progress_ns -= 10 * std.time.ns_per_s;
    }
    try testing.expectEqual([_]usize{ 0, 0 }, try fx.access(2));

    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[1], .{ .sn = 2, .cs = 1, .gsn = 3, .gcs = 1 });
            try m.data(alloc, w[1], .{ .sn = 3, .gsn = 4, .gcs = 1, .payload = false });
        }
    });
    try testing.expectEqual([_]usize{ 1, 2 }, try fx.access(2));
}

test "group coherent set: a part that arrived before its writer matched joins its publisher's set" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .GROUP_PRESENTATION_QOS, 2, .{}, true);
    defer fx.deinit();
    const r0 = fx.readers[0];
    const r1 = fx.readers[1];

    // A third writer of the publisher, on topic 0, not yet discovered.
    const late_eid = [4]u8{ 0x00, 0x00, 0x77, 0x02 };
    const late_guid = zzdds.rtps.Guid{
        .prefix = .{ .bytes = fx.prefix },
        .entity_id = .{ .entity_key = late_eid[0..3].*, .entity_kind = late_eid[3] },
    };
    const w1_guid = zzdds.rtps.Guid{
        .prefix = .{ .bytes = fx.prefix },
        .entity_id = .{ .entity_key = fx.writer_eids[1][0..3].*, .entity_kind = fx.writer_eids[1][3] },
    };
    const w0_guid = zzdds.rtps.Guid{
        .prefix = .{ .bytes = fx.prefix },
        .entity_id = .{ .entity_key = fx.writer_eids[0][0..3].*, .entity_kind = fx.writer_eids[0][3] },
    };
    // The publisher announces a group GUID (PID_GROUP_GUID), so its key is not
    // the participant-only one a writer's parts get before its match completes.
    const publisher = zzdds.rtps.Guid{
        .prefix = .{ .bytes = fx.prefix },
        .entity_id = .{ .entity_key = .{ 0x00, 0x00, 0x55 }, .entity_kind = 0x08 },
    };
    for ([_]zzdds.rtps.Guid{ w0_guid, w1_guid }, [_]*DataReaderImpl{ r0, r1 }) |g, r| {
        const cb = r.writerMatchCallback();
        cb.on_writer_matched(cb.ctx, &.{
            .guid = g,
            .unicast_locators = &.{},
            .multicast_locators = &.{},
            .reliability = .reliable,
            .group_coherent = true,
            .publisher_guid = publisher,
        });
    }

    // Group set 1: the late writer's part arrives whole (and waits for its
    // writer's match), writer 0 wrote nothing, writer 1's part is in progress.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, late_eid, .{ .sn = 1, .cs = 1, .gsn = 1, .gcs = 1 });
            try m.data(alloc, late_eid, .{ .sn = 2, .gsn = 3, .gcs = 1, .payload = false });
            try m.data(alloc, w[0], .{ .sn = 1, .gsn = 3, .gcs = 1, .payload = false });
            try m.data(alloc, w[1], .{ .sn = 1, .cs = 1, .gsn = 2, .gcs = 1 });
        }
    });

    // The late writer matches.  Its early samples are delivered before the
    // reader hears which publisher it has: held back here, in that window,
    // the part must not come out on its own.
    const info = zzdds.protocol.MatchedWriterInfo{
        .guid = late_guid,
        .unicast_locators = &.{},
        .multicast_locators = &.{},
        .reliability = .reliable,
        .group_coherent = true,
        .publisher_guid = publisher,
    };
    const real_cb = r0.writerMatchCallback();
    const Held = struct {
        fn matched(_: *anyopaque, _: *const zzdds.protocol.MatchedWriterInfo) void {}
        fn unmatched(_: *anyopaque, _: zzdds.rtps.Guid) void {}
    };
    var held_ctx: u8 = 0;
    r0.proto_reader.setWriterMatchCallback(.{ .ctx = &held_ctx, .on_writer_matched = Held.matched, .on_writer_unmatched = Held.unmatched });
    _ = try r0.proto_reader.addMatchedWriter(&info);
    try testing.expectEqual([_]usize{ 0, 0 }, try fx.access(2));

    // Once the match completes, the part joins its publisher's set, which
    // waits for writer 1's part.
    r0.proto_reader.setWriterMatchCallback(real_cb);
    real_cb.on_writer_matched(real_cb.ctx, &info);
    try testing.expectEqual([_]usize{ 0, 0 }, try fx.access(2));

    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[1], .{ .sn = 2, .gsn = 3, .gcs = 1, .payload = false });
        }
    });
    try testing.expectEqual([_]usize{ 1, 1 }, try fx.access(2));
}

test "group coherent set: a writer with nothing in the set ends it with its marker" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .GROUP_PRESENTATION_QOS, 2, .{}, true);
    defer fx.deinit();

    // Group set 1 has two samples from writer 0 and none from writer 1, whose
    // End Coherent Set marker says it is done with the set.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1, .gsn = 1, .gcs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1, .gsn = 2, .gcs = 1 });
            try m.data(alloc, w[0], .{ .sn = 3, .gsn = 3, .gcs = 1, .payload = false });
            try m.data(alloc, w[1], .{ .sn = 1, .gsn = 3, .gcs = 1, .payload = false });
        }
    });
    try testing.expectEqual([_]usize{ 2, 0 }, try fx.access(2));
}

test "coherent set: a fragmented sample keeps its coherent-set inline QoS" {
    // Only fragment 1 carries PID_COHERENT_SET; the reassembled sample must
    // still belong to the set, not end it as a sample outside any set.
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, true);
    defer fx.deinit();
    const r = fx.readers[0];

    // Fragment 2 arrives before fragment 1.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.dataFrag(alloc, w[0], 2, 2, 1);
            try m.dataFrag(alloc, w[0], 2, 1, 1);
            try m.data(alloc, w[0], .{ .sn = 3, .payload = false });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 2 }, state(r));
}

test "coherent set: an end marker ends a best-effort reader's set" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, false);
    defer fx.deinit();
    const r = fx.readers[0];

    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .payload = false });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 1 }, state(r));
}

// RTPS 2.5 Table 9.22 lists three DATA submessages that end a writer's set:
// a sample of a new set (Example 1, see the HEARTBEAT test above), an end
// marker with PID_COHERENT_SET = SEQUENCENUMBER_UNKNOWN (Example 2) and one
// without PID_COHERENT_SET (Example 3).

test "coherent set: an end marker with PID_COHERENT_SET = SEQUENCENUMBER_UNKNOWN ends the set" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, true);
    defer fx.deinit();
    const r = fx.readers[0];

    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 3, .cs_unknown = true, .payload = false });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 2 }, state(r));
}

test "coherent set: a sample outside any set ends the set" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator, .TOPIC_PRESENTATION_QOS, 1, .{}, true);
    defer fx.deinit();
    const r = fx.readers[0];

    // RTPS 2.5 §8.7.6: a sample without PID_COHERENT_SET, or with it set to
    // SEQUENCENUMBER_UNKNOWN, ends the set even when it carries data.
    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 1, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 2, .cs = 1 });
            try m.data(alloc, w[0], .{ .sn = 3 });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 1, .first_set_len = 2 }, state(r));

    try fx.inject(struct {
        fn add(alloc: std.mem.Allocator, m: *Msg, w: [MAX_TOPICS][4]u8) !void {
            try m.data(alloc, w[0], .{ .sn = 4, .cs = 4 });
            try m.data(alloc, w[0], .{ .sn = 5, .cs_unknown = true });
        }
    });
    try testing.expectEqual(State{ .wip = 0, .committed_sets = 2, .first_set_len = 2 }, state(r));
}
