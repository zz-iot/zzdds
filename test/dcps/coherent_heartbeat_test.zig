//! A HEARTBEAT never ends a coherent set.
//!
//! RTPS 2.5 §9.6.4.2 ends a coherent set with an end-of-set DATA, a sample of a
//! different set, or a sample without PID_COHERENT_SET. A HEARTBEAT only says
//! which samples the writer has; a writer that sends each sample as it is
//! written (unlike zzdds's own writer, which holds a set until it ends) sends
//! HEARTBEATs in the middle of a set. Committing on one split the set across
//! read cycles.
//!
//! Technique (as in entity_routing_test.zig): IntraProcessDelivery matches a
//! writer/reader pair synchronously, then crafted RTPS bytes sent through a
//! second MemoryTransport stand in for that writer's traffic.
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
const noop_security = zzdds.noop_security.noop_security_plugins;
const Locator = zzdds.transport.Locator;

// CDR-LE encapsulation header + 1 payload byte.
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xDE };

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

    /// DATA (LE, inline QoS, serialized payload) carrying PID_COHERENT_SET = `cs`.
    fn coherentData(self: *Msg, alloc: std.mem.Allocator, writer_eid: [4]u8, sn: u32, cs: u32) !void {
        // extraFlags(2) + octetsToInlineQos(2) + readerId(4) + writerId(4) + sn(8)
        // + PID_COHERENT_SET(4 + 8) + PID_SENTINEL(4) + payload
        const content_len: u16 = 20 + 12 + 4 + PAYLOAD.len;
        var smh = [_]u8{ 0x15, 0x07, 0, 0 }; // DATA, E|Q|D
        std.mem.writeInt(u16, smh[2..4], content_len, .little);
        try self.buf.appendSlice(alloc, &smh);
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x10, 0 }); // octetsToInlineQos = 16
        try self.buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 }); // ENTITYID_UNKNOWN
        try self.buf.appendSlice(alloc, &writer_eid);
        try self.appendSn(alloc, sn);
        try self.buf.appendSlice(alloc, &[_]u8{ 0x56, 0x00, 0x08, 0x00 }); // PID_COHERENT_SET
        try self.appendSn(alloc, cs);
        try self.buf.appendSlice(alloc, &[_]u8{ 0x01, 0x00, 0x00, 0x00 }); // PID_SENTINEL
        try self.buf.appendSlice(alloc, &PAYLOAD);
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

test "coherent set: a HEARTBEAT in the middle of a set does not commit it" {
    const alloc = testing.allocator;

    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();

    const t_w = try delivery.newTransport();
    defer t_w.deinit();
    const d_w = try delivery.newDiscovery();
    defer d_w.deinit();
    const factory_w = try DomainParticipantFactoryImpl.init(alloc, t_w.transport(), d_w.toDiscovery(), noop_security, .spec_random, .{});
    defer factory_w.deinit();
    const dp_w = factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
    defer _ = factory_w.toDDSFactory().delete_participant(dp_w);
    const dp_w_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp_w.ptr));

    const t_r = try delivery.newTransport();
    defer t_r.deinit();
    const d_r = try delivery.newDiscovery();
    defer d_r.deinit();
    const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
    defer factory_r.deinit();
    const dp_r = factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
    defer _ = factory_r.toDDSFactory().delete_participant(dp_r);
    const dp_r_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp_r.ptr));

    const injector = try delivery.newTransport();
    defer injector.deinit();

    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const pub_w = dp_w.create_publisher(pub_qos, null, 0);
    const topic_w = dp_w.create_topic("CoherentHbTopic", "CoherentHbType", .{}, null, 0);
    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    _ = pub_w.create_datawriter(topic_w, dw_qos, null, 0);

    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.access_scope = .TOPIC_PRESENTATION_QOS;
    const sub_r = dp_r.create_subscriber(sub_qos, null, 0);
    const topic_r = dp_r.create_topic("CoherentHbTopic", "CoherentHbType", .{}, null, 0);
    const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    const dr = sub_r.create_datareader(td, dr_qos, null, 0);
    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));

    const w_eid = blk: {
        dp_w_impl.mu.lock();
        defer dp_w_impl.mu.unlock();
        var it = dp_w_impl.active_writers.valueIterator();
        const aw = it.next() orelse return error.NoWriter;
        const id = aw.guid.entity_id;
        break :blk [4]u8{ id.entity_key[0], id.entity_key[1], id.entity_key[2], id.entity_kind };
    };
    const dest = Locator.udp4(.{ 0, 0, 0, 0 }, dp_r_impl.data_listen_port);
    const prefix = dp_w_impl.guid.prefix.bytes;

    const State = struct { wip: usize, committed_sets: usize, first_set_len: usize };
    const state = struct {
        fn get(r: *DataReaderImpl) State {
            r.mu.lock();
            defer r.mu.unlock();
            var wip: usize = 0;
            var it = r.coherent_wip.valueIterator();
            while (it.next()) |e| wip += e.samples.items.len;
            return .{
                .wip = wip,
                .committed_sets = r.coherent_committed.items.len,
                .first_set_len = if (r.coherent_committed.items.len > 0) r.coherent_committed.items[0].items.len else 0,
            };
        }
    }.get;

    // The first two samples of the set starting at SN 1, then a HEARTBEAT
    // announcing them: the writer has more of the set to come.
    {
        var msg = Msg{};
        defer msg.deinit(alloc);
        try msg.header(alloc, prefix);
        try msg.coherentData(alloc, w_eid, 1, 1);
        try msg.coherentData(alloc, w_eid, 2, 1);
        try msg.heartbeat(alloc, w_eid, 1, 2, 100);
        try injector.transport().send(&dest, msg.buf.items);
    }
    try testing.expectEqual(State{ .wip = 2, .committed_sets = 0, .first_set_len = 0 }, state(dr_impl));

    // The set's last sample, then the first sample of the next set ends it.
    {
        var msg = Msg{};
        defer msg.deinit(alloc);
        try msg.header(alloc, prefix);
        try msg.coherentData(alloc, w_eid, 3, 1);
        try msg.heartbeat(alloc, w_eid, 1, 3, 101);
        try msg.coherentData(alloc, w_eid, 4, 4);
        try injector.transport().send(&dest, msg.buf.items);
    }
    try testing.expectEqual(State{ .wip = 1, .committed_sets = 1, .first_set_len = 3 }, state(dr_impl));
}
