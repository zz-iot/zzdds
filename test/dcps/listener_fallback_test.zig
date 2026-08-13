//! DDS 1.4 §2.2.4.1.5 "Listener Access to Plain Communication Status" —
//! the "nearest enclosing non-null listener" fallback chain: reader ->
//! subscriber -> participant, writer -> publisher -> participant.
//!
//! Uses IntraProcessDelivery + DirectDiscovery (synchronous, no pump) so
//! every assertion is deterministic, matching matched_status_test.zig's/
//! instance_lifecycle_test.zig's existing pattern for real (not stub-
//! vtable) two-participant entity trees.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

const testing = std.testing;

// CDR encap header (little-endian) + one byte of payload.
const PAYLOAD: [5]u8 = .{ 0x00, 0x01, 0x00, 0x00, 0x42 };
const NIL_KEY: [16]u8 = std.mem.zeroes([16]u8);
const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return (@as(*TopicImpl, @ptrCast(@alignCast(t.ptr)))).toTopicDescription();
}

// ── Fixture: two participants (writer side, reader side), matched via
// DirectDiscovery — mirrors matched_status_test.zig's Fixture exactly. ───

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
        const dp_w = factory_w.toDDSFactory().create_participant(0, .{}, null, 0);
        const pub_w = dp_w.create_publisher(.{}, null, 0);
        const topic_w = dp_w.create_topic("FallbackTopic", "FallbackType", .{}, null, 0);

        const t_r = try delivery.newTransport();
        errdefer t_r.deinit();
        const d_r = try delivery.newDiscovery();
        errdefer d_r.deinit();
        const factory_r = try DomainParticipantFactoryImpl.init(alloc, t_r.transport(), d_r.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_r.deinit();
        const dp_r = factory_r.toDDSFactory().create_participant(0, .{}, null, 0);
        const sub_r = dp_r.create_subscriber(.{}, null, 0);
        const topic_r = dp_r.create_topic("FallbackTopic", "FallbackType", .{}, null, 0);

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

// ── on_data_available fallback: reader has no listener, Subscriber does ────

const FiredOn = enum { none, reader, subscriber, participant };

const RecordingState = struct {
    fired_on: FiredOn = .none,
    handle: DDS.DataReader = undefined,
};

fn onDataAvailableAt(comptime level: FiredOn) fn (*anyopaque, ?*anyopaque) callconv(.c) void {
    return struct {
        fn cb(handle: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
            const state: *RecordingState = @ptrCast(@alignCast(ld.?));
            state.fired_on = level;
            state.handle = .{ .ptr = handle, .vtable = undefined };
        }
    }.cb;
}

test "listener fallback: reader with no listener falls back to Subscriber's on_data_available" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var state = RecordingState{};

    // Reader installed with NO listener at all (mask=0) -- must not fire here.
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    const dr_handle = dr_raw.vtable.get_c_abi_handle(dr_raw.ptr);

    // Subscriber has an on_data_available listener installed.
    var sub_listener = DDS.SubscriberListener{
        .listener_data = &state,
        .on_data_available = onDataAvailableAt(.subscriber),
    };
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_r.vtable.set_listener(fx.sub_r.ptr, &sub_listener, DDS.DATA_AVAILABLE_STATUS));

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD);

    try testing.expectEqual(FiredOn.subscriber, state.fired_on);
    // The callback that ran is the Subscriber's, but the handle it received
    // is still the originating DataReader's own (DDS 1.4 §2.2.4.1.5).
    try testing.expectEqual(dr_handle, state.handle.ptr);
}

test "listener fallback: reader and Subscriber both silent falls back to DomainParticipant's on_data_available" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var state = RecordingState{};

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    const dr_handle = dr_raw.vtable.get_c_abi_handle(dr_raw.ptr);

    // Neither the reader nor the Subscriber has a listener installed; only
    // the DomainParticipant does -- the terminal link in the chain.
    var dp_listener = DDS.DomainParticipantListener{
        .listener_data = &state,
        .on_data_available = onDataAvailableAt(.participant),
    };
    try testing.expectEqual(DDS.RETCODE_OK, fx.dp_r.vtable.set_listener(fx.dp_r.ptr, &dp_listener, DDS.DATA_AVAILABLE_STATUS));

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD);

    try testing.expectEqual(FiredOn.participant, state.fired_on);
    try testing.expectEqual(dr_handle, state.handle.ptr);
}

test "listener fallback: reader's own listener wins over Subscriber's (no fallback needed)" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var state = RecordingState{};

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, .{
        .listener_data = &state,
        .on_data_available = onDataAvailableAt(.reader),
    }, DDS.DATA_AVAILABLE_STATUS);
    const dr_handle = dr_raw.vtable.get_c_abi_handle(dr_raw.ptr);

    // Subscriber ALSO has one installed -- must NOT fire, since the reader's
    // own (nearer) listener already handled it.
    var sub_listener = DDS.SubscriberListener{
        .listener_data = &state,
        .on_data_available = onDataAvailableAt(.subscriber),
    };
    try testing.expectEqual(DDS.RETCODE_OK, fx.sub_r.vtable.set_listener(fx.sub_r.ptr, &sub_listener, DDS.DATA_AVAILABLE_STATUS));

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(dw_raw.ptr));
    _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD);

    try testing.expectEqual(FiredOn.reader, state.fired_on);
    try testing.expectEqual(dr_handle, state.handle.ptr);
}

// ── on_publication_matched fallback: writer has no listener, Publisher does ─

const PubFiredOn = enum { none, publisher, participant };

const MatchState = struct {
    fired_on: PubFiredOn = .none,
};

fn onPubMatchedAt(comptime level: PubFiredOn) fn (*anyopaque, *const DDS.PublicationMatchedStatus, ?*anyopaque) callconv(.c) void {
    return struct {
        fn cb(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
            const state: *MatchState = @ptrCast(@alignCast(ld.?));
            state.fired_on = level;
        }
    }.cb;
}

test "listener fallback: writer with no listener falls back to Publisher's on_publication_matched" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var state = MatchState{};

    var pub_listener = DDS.PublisherListener{
        .listener_data = &state,
        .on_publication_matched = onPubMatchedAt(.publisher),
    };
    try testing.expectEqual(DDS.RETCODE_OK, fx.pub_w.vtable.set_listener(fx.pub_w.ptr, &pub_listener, DDS.PUBLICATION_MATCHED_STATUS));

    // Writer created with NO listener -- match must fall back to the Publisher.
    _ = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    // Reader on the other participant triggers discovery/match synchronously
    // (DirectDiscovery, no pump needed).
    _ = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);

    try testing.expectEqual(PubFiredOn.publisher, state.fired_on);
}
