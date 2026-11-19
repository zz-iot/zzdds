const std = @import("std");
const dds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const rt = @import("zidl_bindings");
const testing = std.testing;
const alloc = testing.allocator;

const Observed = struct {
    handles: []const *anyopaque,
    calls: [8]std.atomic.Value(u32) = @splat(.init(0)),

    fn on_retire(ctx: ?*anyopaque, retired_handle: *anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        for (self.handles, 0..) |expected, i| {
            if (retired_handle == expected) _ = self.calls[i].fetchAdd(1, .monotonic);
        }
    }
    fn start(self: *@This()) !void {
        try testing.expect(rt.observeHandleRetire(on_retire, self));
    }
    fn stop(self: *@This()) void {
        const removed = rt.unobserveHandleRetire(on_retire, self);
        std.debug.assert(removed);
    }
    fn expect_once(self: *@This()) !void {
        for (self.handles, 0..) |_, i| try testing.expectEqual(@as(u32, 1), self.calls[i].load(.acquire));
    }
};

fn handle(entity: anytype) *anyopaque {
    return entity.vtable.get_c_abi_handle(entity.ptr);
}

const Fixture = struct {
    delivery: *dds.intraprocess.IntraProcessDelivery,
    transport: *dds.intraprocess.MemoryTransport,
    discovery: *dds.intraprocess.DirectDiscovery,
    factory: *dds.dcps.DomainParticipantFactoryImpl,
    participant: DDS.DomainParticipant,
    topic: DDS.Topic,

    fn init() !Fixture {
        const delivery = try alloc.create(dds.intraprocess.IntraProcessDelivery);
        errdefer alloc.destroy(delivery);
        delivery.* = try .init(alloc);
        errdefer delivery.deinit();
        const transport = try delivery.newTransport();
        errdefer transport.deinit();
        const discovery = try delivery.newDiscovery();
        errdefer discovery.deinit();
        const factory = try dds.dcps.DomainParticipantFactoryImpl.init(alloc, transport.transport(), discovery.toDiscovery(), dds.noop_security.noop_security_plugins, .spec_random, .{});
        errdefer factory.deinit();
        const participant = factory.toDDSFactory().create_participant(@import("test_domain").get(), .{}, null, 0);
        const topic = participant.create_topic("Retirement", "RetirementType", .{}, null, 0);
        return .{ .delivery = delivery, .transport = transport, .discovery = discovery, .factory = factory, .participant = participant, .topic = topic };
    }
    fn deinit(self: *Fixture) void {
        _ = self.factory.toDDSFactory().delete_participant(self.participant);
        self.factory.deinit();
        self.discovery.deinit();
        self.transport.deinit();
        self.delivery.deinit();
        alloc.destroy(self.delivery);
    }
};

test "writer and status condition retire before the final native reference is released" {
    var f = try Fixture.init();
    defer f.deinit();
    const pub_ = f.participant.create_publisher(.{}, null, 0);
    const writer = pub_.create_datawriter(f.topic, .{}, null, 0);
    const native: *dds.dcps.DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
    const writer_handle = handle(writer);
    var observed: Observed = .{ .handles = &.{ writer_handle, handle(writer.get_statuscondition()) } };
    try observed.start();
    defer observed.stop();
    // An already-running callback can keep storage alive after delete returns.
    try testing.expect(native.acquireQuiesce());
    var held = true;
    defer if (held) native.releaseQuiesce();
    try testing.expectEqual(DDS.RETCODE_OK, pub_.delete_datawriter(writer));
    try observed.expect_once();
    try testing.expect(rt.isEntityBoxRetired(writer_handle));
    try testing.expectEqual(writer_handle, handle(writer));
    try testing.expectEqual(writer.ptr, rt.unboxEntity(writer_handle).ptr);
    native.releaseQuiesce();
    held = false;
    try observed.expect_once(); // Freeing storage must not send another retirement.
}

test "reader retirement includes its status read and query conditions" {
    var f = try Fixture.init();
    defer f.deinit();
    const sub = f.participant.create_subscriber(.{}, null, 0);
    const topic: *dds.dcps.TopicImpl = @ptrCast(@alignCast(f.topic.ptr));
    const reader = sub.create_datareader(topic.toTopicDescription(), .{}, null, 0);
    const condition = reader.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    var params: DDS.StringSeq = .{};
    const query = reader.create_querycondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, "", &params);
    try testing.expect(condition.ptr != rt.NIL_PTR);
    try testing.expect(query.ptr != rt.NIL_PTR);
    const query_handle = handle(query);
    const query_view = rt.unboxAsView(DDS.Condition, query_handle);
    const ws = try dds.dcps.WaitSetImpl.init(alloc);
    defer ws.deinit();
    const waitset = ws.toDDSWaitSet();
    const status = reader.get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(condition.as_Condition()));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(query_view));
    // Both QueryCondition representations must name the same attachment.
    try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(query_view));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(query_view));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(status.as_Condition()));
    var observed: Observed = .{ .handles = &.{ handle(reader), handle(status), handle(condition), query_handle } };
    try observed.start();
    defer observed.stop();
    const native: *dds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    try testing.expect(native.acquireQuiesce());
    var held = true;
    defer if (held) native.releaseQuiesce();
    native.mu.lock();
    native.status_changes = DDS.DATA_AVAILABLE_STATUS;
    native.mu.unlock();
    try testing.expect(status.get_trigger_value());
    try testing.expectEqual(DDS.RETCODE_OK, sub.delete_datareader(reader));
    try observed.expect_once();
    for (observed.handles) |h| try testing.expect(rt.isEntityBoxRetired(h));
    var listed: DDS.ConditionSeq = .{};
    defer listed.deinit(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, waitset.get_conditions(&listed));
    try testing.expectEqual(@as(u32, 0), listed._length);
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, waitset.attach_condition(query_view));
    var accepted = true;
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, ws.attachConditionWithRelease(query_view, null, null, &accepted));
    try testing.expect(!accepted);
    var active: DDS.ConditionSeq = .{};
    defer active.deinit(alloc);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, waitset.wait(&active, .{ .sec = 0, .nanosec = 0 }));
    native.releaseQuiesce();
    held = false;
    try observed.expect_once();
}

test "cascading deletion retires containers while their children still pin storage" {
    inline for (.{ true, false }) |writer_side| {
        var f = try Fixture.init();
        defer f.deinit();
        const parent = if (writer_side) f.participant.create_publisher(.{}, null, 0) else f.participant.create_subscriber(.{}, null, 0);
        const topic: *dds.dcps.TopicImpl = @ptrCast(@alignCast(f.topic.ptr));
        const endpoint = if (writer_side) parent.create_datawriter(f.topic, .{}, null, 0) else parent.create_datareader(topic.toTopicDescription(), .{}, null, 0);
        const Native = if (writer_side) dds.dcps.DataWriterImpl else dds.dcps.DataReaderImpl;
        const native: *Native = @ptrCast(@alignCast(endpoint.ptr));
        var observed: Observed = .{ .handles = &.{ handle(parent), handle(parent.get_statuscondition()), handle(endpoint), handle(endpoint.get_statuscondition()) } };
        try observed.start();
        defer observed.stop();
        try testing.expect(native.acquireQuiesce());
        var held = true;
        defer if (held) native.releaseQuiesce();
        try testing.expectEqual(DDS.RETCODE_OK, f.participant.delete_contained_entities());
        try observed.expect_once();
        native.releaseQuiesce();
        held = false;
        try observed.expect_once();
    }
}

test "topic retirement includes its description, status condition and filtered topic" {
    var f = try Fixture.init();
    defer f.deinit();
    const topic: *dds.dcps.TopicImpl = @ptrCast(@alignCast(f.topic.ptr));
    var params: DDS.StringSeq = .{};
    const filtered = f.participant.create_contentfilteredtopic("RetirementFiltered", f.topic, "x = 1", &params);
    const filtered_impl: *dds.dcps.ContentFilteredTopicImpl = @ptrCast(@alignCast(filtered.ptr));
    const sub = f.participant.create_subscriber(.{}, null, 0);
    const reader = sub.create_datareader(filtered_impl.toTopicDescription(), .{}, null, 0);
    const native: *dds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    var observed: Observed = .{ .handles = &.{ handle(f.topic), handle(topic.toTopicDescription()), handle(f.topic.get_statuscondition()), handle(filtered) } };
    try observed.start();
    defer observed.stop();
    // The reader's references keep both topics alive past their deletes.
    try testing.expect(native.acquireQuiesce());
    var held = true;
    defer if (held) native.releaseQuiesce();
    try testing.expectEqual(DDS.RETCODE_OK, sub.delete_datareader(reader));
    try testing.expectEqual(DDS.RETCODE_OK, f.participant.delete_contentfilteredtopic(filtered));
    try testing.expectEqual(DDS.RETCODE_OK, f.participant.delete_topic(f.topic));
    try observed.expect_once();
    for (observed.handles) |h| try testing.expect(rt.isEntityBoxRetired(h));
    native.releaseQuiesce();
    held = false;
    try observed.expect_once();
}

test "cascading deletion retires topics while a deleted reader still pins them" {
    var f = try Fixture.init();
    defer f.deinit();
    const topic: *dds.dcps.TopicImpl = @ptrCast(@alignCast(f.topic.ptr));
    var params: DDS.StringSeq = .{};
    const filtered = f.participant.create_contentfilteredtopic("RetirementFiltered", f.topic, "x = 1", &params);
    const filtered_impl: *dds.dcps.ContentFilteredTopicImpl = @ptrCast(@alignCast(filtered.ptr));
    const sub = f.participant.create_subscriber(.{}, null, 0);
    const reader = sub.create_datareader(filtered_impl.toTopicDescription(), .{}, null, 0);
    const native: *dds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    var observed: Observed = .{ .handles = &.{ handle(f.topic), handle(topic.toTopicDescription()), handle(f.topic.get_statuscondition()), handle(filtered) } };
    try observed.start();
    defer observed.stop();
    try testing.expect(native.acquireQuiesce());
    var held = true;
    defer if (held) native.releaseQuiesce();
    try testing.expectEqual(DDS.RETCODE_OK, f.participant.delete_contained_entities());
    try observed.expect_once();
    native.releaseQuiesce();
    held = false;
    try observed.expect_once();
}

// A cascade deletes a reader or writer with a loan out. Its handle stays
// usable until the last loan comes back, so a binding can return it, and is
// retired when that frees it. Every other operation is ALREADY_DELETED.

/// Tears the fixture down with a cascade (the factory deletes its
/// participants), not with delete_participant, which a loan would refuse.
fn cascade(f: *Fixture) void {
    f.factory.deinit();
}

fn finish(f: *Fixture) void {
    f.discovery.deinit();
    f.transport.deinit();
    f.delivery.deinit();
    alloc.destroy(f.delivery);
}

test "a writer deleted with loans out keeps its handle until the last loan comes back" {
    var f = try Fixture.init();
    defer finish(&f);
    const pub_ = f.participant.create_publisher(.{}, null, 0);
    const writer = pub_.create_datawriter(f.topic, .{}, null, 0);
    const writer_handle = handle(writer);
    var observed: Observed = .{ .handles = &.{writer_handle} };
    try observed.start();
    defer observed.stop();
    var returned = DDS.OctetSeq{};
    var published = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, writer.vtable.loan_raw(writer.ptr, 4, &returned));
    try testing.expectEqual(DDS.RETCODE_OK, writer.vtable.loan_raw(writer.ptr, 4, &published));
    returned._buffer.?[0..4].* = .{ 1, 2, 3, 4 };

    cascade(&f);
    try testing.expectEqual(@as(u32, 0), observed.calls[0].load(.acquire));
    try testing.expect(!rt.isEntityBoxRetired(writer_handle));
    try testing.expectEqual(@as(u8, 4), returned._buffer.?[3]);

    var qos: DDS.DataWriterQos = .{};
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, writer.get_qos(&qos));
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, writer.assert_liveliness());
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, writer.enable());
    try testing.expect(writer.get_publisher().ptr == rt.NIL_PTR);
    try testing.expect(writer.get_topic().ptr == rt.NIL_PTR);
    try testing.expect(writer.get_statuscondition().ptr == rt.NIL_PTR);
    try testing.expectEqual(DDS.HANDLE_NIL, writer.get_instance_handle());
    var another = DDS.OctetSeq{};
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, writer.vtable.loan_raw(writer.ptr, 4, &another));

    // Publishing a loan on a deleted writer consumes it and sends nothing.
    var key_hash_bytes = @as([16]u8, @splat(0));
    const key_hash = DDS.OctetSeq{ ._buffer = &key_hash_bytes, ._length = 16, ._maximum = 16, ._release = false };
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, writer.vtable.publish_loan_raw(writer.ptr, &published, &key_hash, DDS.HANDLE_NIL, .ALIVE_WRITE_KIND));
    try testing.expect(published._buffer == null);
    try testing.expect(!rt.isEntityBoxRetired(writer_handle));

    // The last loan's return frees the writer, its protocol writer, publisher
    // and topic (the testing allocator checks), and retires the handle once.
    try testing.expectEqual(DDS.RETCODE_OK, writer.vtable.return_loan_raw(writer.ptr, &returned));
    try observed.expect_once();
}

test "a reader deleted with a loan out keeps its handle until the loan comes back" {
    var f = try Fixture.init();
    defer finish(&f);
    const sub = f.participant.create_subscriber(.{}, null, 0);
    const topic: *dds.dcps.TopicImpl = @ptrCast(@alignCast(f.topic.ptr));
    const reader = sub.create_datareader(topic.toTopicDescription(), .{}, null, 0);
    const status_handle = handle(reader.get_statuscondition());
    const reader_handle = handle(reader);
    var observed: Observed = .{ .handles = &.{ reader_handle, status_handle } };
    try observed.start();
    defer observed.stop();
    const native: *dds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    native.pushCdr(&[_]u8{ 0x00, 0x01, 0x00, 0x00, 0x5A });
    var payloads = DDS.OctetSeqSeq{};
    var hashes = DDS.OctetSeq{};
    var infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_OK, reader.vtable.take_raw(reader.ptr, &payloads, &hashes, &infos, DDS.HANDLE_NIL, dds.dcps.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));
    try testing.expectEqual(@as(u32, 1), payloads._length);

    cascade(&f);
    // Its status condition went with it; the reader's own handle stays.
    try testing.expectEqual(@as(u32, 0), observed.calls[0].load(.acquire));
    try testing.expectEqual(@as(u32, 1), observed.calls[1].load(.acquire));
    try testing.expectEqual(@as(u8, 0x5A), payloads._buffer.?[0]._buffer.?[4]);

    var qos: DDS.DataReaderQos = .{};
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, reader.get_qos(&qos));
    try testing.expect(reader.get_subscriber().ptr == rt.NIL_PTR);
    try testing.expect(reader.get_topicdescription().ptr == rt.NIL_PTR);
    var more = DDS.OctetSeqSeq{};
    var more_hashes = DDS.OctetSeq{};
    var more_infos = DDS.SampleInfoSeq{};
    try testing.expectEqual(DDS.RETCODE_ALREADY_DELETED, reader.vtable.take_raw(reader.ptr, &more, &more_hashes, &more_infos, DDS.HANDLE_NIL, dds.dcps.nil_readcondition, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1));

    try testing.expectEqual(DDS.RETCODE_OK, reader.vtable.return_loan_raw(reader.ptr, &payloads, &hashes, &infos));
    try observed.expect_once();
}
