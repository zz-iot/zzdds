//! Phase 32 on_publication_matched / on_subscription_matched tests.
//!
//! Covers the polling path (get_publication/subscription_matched_status) and the
//! listener path (on_publication/subscription_matched callbacks).  Uses
//! IntraProcessDelivery + DirectDiscovery, which fires discovery callbacks
//! synchronously so every assertion is deterministic.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = zzdds.ZZDDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const nil = zzdds.dcps;
const noop_security = zzdds.noop_security.noop_security_plugins;

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return (@as(*TopicImpl, @ptrCast(@alignCast(t.ptr)))).toTopicDescription();
}

const testing = std.testing;

// ── Fixture ───────────────────────────────────────────────────────────────────
// Two separate participants: one on the writer side, one on the reader side.

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

// ── Listener helpers ──────────────────────────────────────────────────────────

fn dwOnPubMatched(_: *anyopaque, s: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*DDS.PublicationMatchedStatus, @ptrCast(@alignCast(ld))).* = s.*;
}
fn drOnSubMatched(_: *anyopaque, s: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*DDS.SubscriptionMatchedStatus, @ptrCast(@alignCast(ld))).* = s.*;
}

fn dwMatchedListener(ctx: *DDS.PublicationMatchedStatus) DDS.DataWriterListener {
    return .{ .listener_data = ctx, .on_publication_matched = dwOnPubMatched };
}
fn drMatchedListener(ctx: *DDS.SubscriptionMatchedStatus) DDS.DataReaderListener {
    return .{ .listener_data = ctx, .on_subscription_matched = drOnSubMatched };
}

// ── Tests: polling path ───────────────────────────────────────────────────────

test "pub_matched: status populated when reader is created after writer" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create the writer first; no readers yet.
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // No match yet.
    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);

    // Create a matching reader — DirectDiscovery fires synchronously.
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expect(s.last_subscription_handle != 0);
}

test "sub_matched: status populated when writer is created after reader" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // Create the reader first.
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    var s = DDS.SubscriptionMatchedStatus{};
    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 0), s.total_count);

    // Now create the writer.
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expect(s.last_publication_handle != 0);
}

test "pub_matched: total_count accumulates; change resets after read" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // First reader matches.
    const dr1_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr1_raw);

    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.total_count_change);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expectEqual(@as(i32, 1), s.current_count_change);

    // Reading again resets the change fields.
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.total_count_change);
    try testing.expectEqual(@as(i32, 1), s.current_count);
    try testing.expectEqual(@as(i32, 0), s.current_count_change);

    // Second reader matches: total goes to 2.
    const dr2_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr2_raw);

    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 2), s.total_count);
    try testing.expectEqual(@as(i32, 1), s.total_count_change);
    try testing.expectEqual(@as(i32, 2), s.current_count);
    try testing.expectEqual(@as(i32, 1), s.current_count_change);
}

test "pub_matched: current_count decrements when reader is deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);

    // Confirm match.
    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.current_count);

    // Delete the reader — retracts from discovery, fires onReaderLost.
    _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count); // total never decrements
    try testing.expectEqual(@as(i32, 0), s.current_count);
    try testing.expectEqual(@as(i32, -1), s.current_count_change);
}

test "sub_matched: current_count decrements when writer is deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);

    var s = DDS.SubscriptionMatchedStatus{};
    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.current_count);

    _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    _ = dr_raw.vtable.get_subscription_matched_status(dr_raw.ptr, &s);
    try testing.expectEqual(@as(i32, 1), s.total_count);
    try testing.expectEqual(@as(i32, 0), s.current_count);
    try testing.expectEqual(@as(i32, -1), s.current_count_change);
}

// ── Tests: listener path ──────────────────────────────────────────────────────

test "pub_matched: listener fires with correct status on match" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.PublicationMatchedStatus{};
    const listener = dwMatchedListener(&captured);
    const dw_raw = fx.pub_w.create_datawriter(
        fx.topic_w,
        .{},
        listener,
        DDS.PUBLICATION_MATCHED_STATUS,
    );
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    // Listener not yet fired (no reader exists).
    try testing.expectEqual(@as(i32, 0), captured.total_count);

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    // Listener fired synchronously by DirectDiscovery.
    try testing.expectEqual(@as(i32, 1), captured.total_count);
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
    try testing.expectEqual(@as(i32, 1), captured.current_count);
    try testing.expectEqual(@as(i32, 1), captured.current_count_change);
    try testing.expect(captured.last_subscription_handle != 0);
}

test "pub_matched: listener fires on unmatch when reader deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.PublicationMatchedStatus{};
    const listener = dwMatchedListener(&captured);
    const dw_raw = fx.pub_w.create_datawriter(
        fx.topic_w,
        .{},
        listener,
        DDS.PUBLICATION_MATCHED_STATUS,
    );
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    try testing.expectEqual(@as(i32, 1), captured.total_count);

    // Reset the capture, then delete the reader.
    captured = .{};
    _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    // Listener fires with current_count = 0, change = -1.
    try testing.expectEqual(@as(i32, 0), captured.total_count_change); // no new matches
    try testing.expectEqual(@as(i32, 0), captured.current_count);
    try testing.expectEqual(@as(i32, -1), captured.current_count_change);
}

test "sub_matched: listener fires with correct status on match" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.SubscriptionMatchedStatus{};
    const listener = drMatchedListener(&captured);
    const dr_raw = fx.sub_r.create_datareader(
        topicDesc(fx.topic_r),
        .{},
        listener,
        DDS.SUBSCRIPTION_MATCHED_STATUS,
    );
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    try testing.expectEqual(@as(i32, 0), captured.total_count);

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    try testing.expectEqual(@as(i32, 1), captured.total_count);
    try testing.expectEqual(@as(i32, 1), captured.total_count_change);
    try testing.expectEqual(@as(i32, 1), captured.current_count);
    try testing.expectEqual(@as(i32, 1), captured.current_count_change);
    try testing.expect(captured.last_publication_handle != 0);
}

test "sub_matched: listener fires on unmatch when writer deleted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    var captured = DDS.SubscriptionMatchedStatus{};
    const listener = drMatchedListener(&captured);
    const dr_raw = fx.sub_r.create_datareader(
        topicDesc(fx.topic_r),
        .{},
        listener,
        DDS.SUBSCRIPTION_MATCHED_STATUS,
    );
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    try testing.expectEqual(@as(i32, 1), captured.total_count);

    captured = .{};
    _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    try testing.expectEqual(@as(i32, 0), captured.total_count_change);
    try testing.expectEqual(@as(i32, 0), captured.current_count);
    try testing.expectEqual(@as(i32, -1), captured.current_count_change);
}

test "pub_matched: last_subscription_handle matches get_matched_subscriptions handle" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    var s = DDS.PublicationMatchedStatus{};
    _ = dw_raw.vtable.get_publication_matched_status(dw_raw.ptr, &s);

    var handles = DDS.InstanceHandleSeq{};
    defer if (handles._release) {
        if (handles._buffer) |b| alloc.free(b[0..handles._length]);
    };
    _ = dw_raw.vtable.get_matched_subscriptions(dw_raw.ptr, &handles);

    try testing.expectEqual(@as(u32, 1), handles._length);
    try testing.expectEqual(handles._buffer.?[0], s.last_subscription_handle);
}

// ── Listeners installed at creation (zzdds create_datawriter_ex/_ex) ─────────
//
// DirectDiscovery matches synchronously, so an endpoint created after its
// remote counterpart is already known matches *inside* create_datawriter /
// create_datareader. A listener installed afterwards (set_listener /
// set_listener_ex) misses that status change: DDS does not report earlier
// status changes to a newly attached listener. These tests pin both halves:
// the race, and that a listener passed at creation (standard or extended)
// sees the match.

fn matchedSubscriptionCount(dw: DDS.DataWriter) !usize {
    var handles = DDS.InstanceHandleSeq{};
    defer handles.deinit(testing.allocator);
    try testing.expectEqual(DDS.RETCODE_OK, dw.vtable.get_matched_subscriptions(dw.ptr, &handles));
    return handles._length;
}

fn matchedPublicationCount(dr: DDS.DataReader) !usize {
    var handles = DDS.InstanceHandleSeq{};
    defer handles.deinit(testing.allocator);
    try testing.expectEqual(DDS.RETCODE_OK, dr.vtable.get_matched_publications(dr.ptr, &handles));
    return handles._length;
}

const ExWriterState = struct {
    matched: DDS.PublicationMatchedStatus = .{},
    ready_calls: usize = 0,
    last_ready: bool = false,
};

fn exOnPubMatched(_: *anyopaque, s: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*ExWriterState, @ptrCast(@alignCast(ld))).matched = s.*;
}
fn exOnReaderReady(_: DDS.InstanceHandle_t, ready: bool, ld: ?*anyopaque) callconv(.c) void {
    const state: *ExWriterState = @ptrCast(@alignCast(ld));
    state.ready_calls += 1;
    state.last_ready = ready;
}

const ExReaderState = struct {
    matched: DDS.SubscriptionMatchedStatus = .{},
    ready_calls: usize = 0,
    last_ready: bool = false,
};

fn exOnSubMatched(_: *anyopaque, s: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*ExReaderState, @ptrCast(@alignCast(ld))).matched = s.*;
}
fn exOnWriterReady(_: DDS.InstanceHandle_t, ready: bool, ld: ?*anyopaque) callconv(.c) void {
    const state: *ExReaderState = @ptrCast(@alignCast(ld));
    state.ready_calls += 1;
    state.last_ready = ready;
}

fn bestEffortReaderQos() DDS.DataReaderQos {
    var q = DDS.DataReaderQos{};
    q.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    return q;
}

fn bestEffortWriterQos() DDS.DataWriterQos {
    var q = DDS.DataWriterQos{};
    q.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
    return q;
}

test "pub_matched: a listener attached after create_datawriter misses a match made during creation" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    // Late listener: the match already happened inside create_datawriter.
    var late = DDS.PublicationMatchedStatus{};
    const dw_late = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_late);
    _ = dw_late.set_listener(dwMatchedListener(&late), DDS.PUBLICATION_MATCHED_STATUS);
    try testing.expectEqual(@as(usize, 1), try matchedSubscriptionCount(dw_late));
    try testing.expectEqual(@as(i32, 0), late.total_count);

    // Listener passed at creation: sees it.
    var early = DDS.PublicationMatchedStatus{};
    const dw_early = fx.pub_w.create_datawriter(fx.topic_w, .{}, dwMatchedListener(&early), DDS.PUBLICATION_MATCHED_STATUS);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_early);
    try testing.expectEqual(@as(usize, 1), try matchedSubscriptionCount(dw_early));
    try testing.expectEqual(@as(i32, 1), early.current_count);
}

test "create_datawriter_ex: extended listener sees the match and readiness from creation" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // BEST_EFFORT reader: on_reliable_reader_ready fires at match (no handshake).
    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), bestEffortReaderQos(), null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);

    const zpub = zzdds.asZzddsPublisher(fx.pub_w) orelse return error.TestUnexpectedResult;
    var state = ExWriterState{};
    const dw = zpub.create_datawriter_ex(fx.topic_w, .{}, .{
        .listener_data = &state,
        .on_publication_matched = exOnPubMatched,
        .on_reliable_reader_ready = exOnReaderReady,
    }, DDS.PUBLICATION_MATCHED_STATUS);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);

    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(@as(usize, 1), try matchedSubscriptionCount(dw));
    try testing.expectEqual(@as(i32, 1), state.matched.current_count);
    try testing.expectEqual(@as(usize, 1), state.ready_calls);
    try testing.expect(state.last_ready);
    // The writer is an ordinary DataWriter of this Publisher.
    try testing.expectEqual(fx.pub_w.ptr, dw.get_publisher().ptr);
}

test "create_datareader_ex: extended listener sees the match and readiness from creation" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // BEST_EFFORT writer: on_reliable_writer_ready fires at match (no handshake).
    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, bestEffortWriterQos(), null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);

    const zsub = zzdds.asZzddsSubscriber(fx.sub_r) orelse return error.TestUnexpectedResult;
    var state = ExReaderState{};
    const dr = zsub.create_datareader_ex(topicDesc(fx.topic_r), bestEffortReaderQos(), .{
        .listener_data = &state,
        .on_subscription_matched = exOnSubMatched,
        .on_reliable_writer_ready = exOnWriterReady,
    }, DDS.SUBSCRIPTION_MATCHED_STATUS);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);

    try testing.expect(dr.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(@as(usize, 1), try matchedPublicationCount(dr));
    try testing.expectEqual(@as(i32, 1), state.matched.current_count);
    try testing.expectEqual(@as(usize, 1), state.ready_calls);
    try testing.expect(state.last_ready);
    try testing.expectEqual(fx.sub_r.ptr, dr.get_subscriber().ptr);
}

test "asZzddsPublisher/asZzddsSubscriber reject foreign handles; null listener is allowed" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    try testing.expect(zzdds.asZzddsPublisher(zzdds.dcps.nil_publisher) == null);
    try testing.expect(zzdds.asZzddsSubscriber(zzdds.dcps.nil_subscriber) == null);

    const zpub = zzdds.asZzddsPublisher(fx.pub_w).?;
    const dw = zpub.create_datawriter_ex(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    try testing.expectEqual(fx.pub_w.ptr, zpub.as_Publisher().ptr);
}

// ── A re-reported match is counted once ──────────────────────────────────────
//
// The participant can report one writer/reader pair more than once:
// DirectDiscovery re-delivers every known reader whenever a writer is
// announced, and SEDP re-delivers an endpoint whose discovery data changes.
// The matched status must count the pair once, and still drop to zero when
// the remote endpoint goes away.

test "pub_matched: a writer created after a known reader counts it once, and unmatch returns to zero" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dr_raw = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    const dw_a = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_a);
    // A second writer's announcement re-delivers the reader to this participant.
    const dw_b = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_b);

    for ([_]DDS.DataWriter{ dw_a, dw_b }) |dw| {
        var s = DDS.PublicationMatchedStatus{};
        _ = dw.vtable.get_publication_matched_status(dw.ptr, &s);
        try testing.expectEqual(@as(i32, 1), s.current_count);
        try testing.expectEqual(@as(i32, 1), s.total_count);
    }

    _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_raw);
    for ([_]DDS.DataWriter{ dw_a, dw_b }) |dw| {
        var s = DDS.PublicationMatchedStatus{};
        _ = dw.vtable.get_publication_matched_status(dw.ptr, &s);
        try testing.expectEqual(@as(i32, 0), s.current_count);
        try testing.expectEqual(@as(i32, 1), s.total_count);
    }
}

test "sub_matched: a reader created after a known writer counts it once, and unmatch returns to zero" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const dw_raw = fx.pub_w.create_datawriter(fx.topic_w, .{}, null, 0);
    const dr_a = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_a);
    const dr_b = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr_b);

    for ([_]DDS.DataReader{ dr_a, dr_b }) |dr| {
        var s = DDS.SubscriptionMatchedStatus{};
        _ = dr.vtable.get_subscription_matched_status(dr.ptr, &s);
        try testing.expectEqual(@as(i32, 1), s.current_count);
        try testing.expectEqual(@as(i32, 1), s.total_count);
    }

    _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw_raw);
    for ([_]DDS.DataReader{ dr_a, dr_b }) |dr| {
        var s = DDS.SubscriptionMatchedStatus{};
        _ = dr.vtable.get_subscription_matched_status(dr.ptr, &s);
        try testing.expectEqual(@as(i32, 0), s.current_count);
        try testing.expectEqual(@as(i32, 1), s.total_count);
    }
}

// ── Discovery waits for a writer's matched notify ────────────────────────────
//
// create_datawriter makes the protocol writer (which joins the participant's
// active writers) before it registers the writer's matched notify, and only
// then announces it, which is when the writer is matched. A remote reader
// discovered in between must not be matched yet: the RTPS match would be
// added with no notify, the announce's add would then only refresh it, and
// the writer's matched status would never count that reader.

test "pub_matched: a reader discovered while create_datawriter runs is matched by its announce and counted" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    // create_datawriter's first step: the protocol writer joins the
    // participant's active writers.
    const pub_impl: *zzdds.dcps.PublisherImpl = @ptrCast(@alignCast(fx.pub_w.ptr));
    const qos = DDS.DataWriterQos{};
    const parts = try pub_impl.createProtoWriter(fx.topic_w, &qos);

    // DirectDiscovery delivers the new reader to the writer's participant
    // synchronously, inside create_datareader, before the writer's matched
    // notify is registered: discovery must not match it yet.
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    try testing.expect(dr.ptr != zzdds.dcps.NIL_PTR);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);
    try testing.expectEqual(@as(usize, 0), parts.pw.matchedReaderCount());

    // create_datawriter's second step registers the notify and announces the
    // writer, which matches the reader and counts it once.
    var status = DDS.PublicationMatchedStatus{};
    const dw = pub_impl.finishDataWriter(fx.topic_w, &qos, .{
        .listener_data = &status,
        .on_publication_matched = dwOnPubMatched,
    }, DDS.PUBLICATION_MATCHED_STATUS, parts);
    try testing.expect(dw.ptr != zzdds.dcps.NIL_PTR);
    defer _ = fx.pub_w.vtable.delete_datawriter(fx.pub_w.ptr, dw);
    try testing.expectEqual(@as(usize, 1), parts.pw.matchedReaderCount());
    try testing.expectEqual(@as(usize, 1), try matchedSubscriptionCount(dw));
    try testing.expectEqual(@as(i32, 1), status.current_count);
    try testing.expectEqual(@as(i32, 1), status.total_count);
}

// ── A sample's publication handle resolves while it can be taken ─────────────
//
// Samples that reach a reader before it has matched their writer are
// buffered, and adding the match delivers them -- before the writer-matched
// callback runs. The publisher GUID must already resolve then.

const GuidCheck = struct {
    dr: DDS.DataReader,
    zdr: ZZDDS.DataReader,
    calls: usize = 0,
    taken: u32 = 0,
    publication_handle: DDS.InstanceHandle_t = DDS.HANDLE_NIL,
    rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    guid: ZZDDS.RtpsGuid = .{},
};

// Takes the sample while it is being delivered and resolves the publisher
// GUID from its own SampleInfo.publication_handle, as an application would.
fn guidCheckOnDataAvailable(check: *GuidCheck, _: DDS.DataReader) void {
    check.calls += 1;
    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    if (check.dr.vtable.take_raw(check.dr.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, zzdds.dcps.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1) != DDS.RETCODE_OK) return;
    defer _ = check.dr.vtable.return_loan_raw(check.dr.ptr, &payloads, &hashes, &infos);
    check.taken = infos._length;
    if (infos._length == 0) return;
    check.publication_handle = infos._buffer.?[0].publication_handle;
    check.rc = check.zdr.vtable.get_matched_publication_rtps_guid(check.zdr.ptr, check.publication_handle, &check.guid);
}

test "sub data: a sample delivered when its writer is matched already resolves its publisher GUID" {
    const alloc = testing.allocator;
    var fx = try Fixture.init(alloc);
    defer fx.deinit();

    const writer_guid = zzdds.protocol.Guid{
        .prefix = .{ .bytes = [_]u8{0x5a} ** 12 },
        .entity_id = .{ .entity_key = .{ 0, 0, 9 }, .entity_kind = 0x03 },
    };
    var check = GuidCheck{ .dr = undefined, .zdr = undefined };
    // RELIABLE: only a reliable reader buffers DATA from a writer it has not
    // matched yet.
    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), dr_qos, DDS.dataReaderListener(&check, .{
        .on_data_available = guidCheckOnDataAvailable,
    }), DDS.DATA_AVAILABLE_STATUS);
    try testing.expect(dr.ptr != zzdds.dcps.NIL_PTR);
    defer _ = fx.sub_r.vtable.delete_datareader(fx.sub_r.ptr, dr);
    check.dr = dr;
    check.zdr = zzdds.asZzddsDataReader(dr) orelse return error.TestUnexpectedResult;

    // DATA from a writer this reader has not matched yet: buffered.
    const pr = @as(*zzdds.dcps.DataReaderImpl, @ptrCast(@alignCast(dr.ptr))).proto_reader;
    pr.handleIncomingChange(writer_guid, 1, .{ .seconds = 0, .fraction = 0 }, std.mem.zeroes([16]u8), &.{ 0x00, 0x01, 0x00, 0x00 }, .alive, null, null, null);
    try testing.expectEqual(@as(usize, 0), check.calls);

    // Matching the writer delivers it, before the writer-matched callback.
    _ = try pr.addMatchedWriter(&.{
        .guid = writer_guid,
        .unicast_locators = &.{},
        .multicast_locators = &.{},
        .reliability = .reliable,
    });
    try testing.expectEqual(@as(usize, 1), check.calls);
    try testing.expectEqual(@as(u32, 1), check.taken);
    try testing.expectEqual(zzdds.dcps.guidToHandle(writer_guid), check.publication_handle);
    try testing.expectEqual(DDS.RETCODE_OK, check.rc);
    try testing.expectEqualSlices(u8, std.mem.asBytes(&writer_guid), &check.guid.value);
}
