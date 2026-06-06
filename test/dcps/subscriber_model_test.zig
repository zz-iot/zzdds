//! Subscriber presentation/read-side model tests.
//!
//! These tests bypass discovery, transport, and timers.  They populate
//! DataReaderImpl presentation buffers directly, then drive the real
//! Subscriber.begin_access() state machine beside a small independent model.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const dcps = zzdds.dcps;
const filter_mod = dcps.filter;
const proto = zzdds.protocol;
const time_mod = zzdds.util.time;
const rtps = zzdds.rtps;

const testing = std.testing;

const DataReaderImpl = dcps.DataReaderImpl;
const PendingChange = dcps.PendingChange;
const SubscriberImpl = dcps.SubscriberImpl;

const GUID_A = proto.Guid{
    .prefix = .{ .bytes = [_]u8{0xA1} ** 12 },
    .entity_id = rtps.EntityIds.sedp_builtin_publications_writer,
};

const ModelChange = struct {
    id: u8,
    instance: DDS.InstanceHandle_t,
    group_seq_num: ?i64 = null,
};

const ModelReader = struct {
    pending: std.ArrayListUnmanaged(ModelChange) = .empty,
    committed: std.ArrayListUnmanaged(std.ArrayListUnmanaged(ModelChange)) = .empty,
    wip_count: usize = 0,

    fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        self.pending.deinit(alloc);
        for (self.committed.items) |*set| set.deinit(alloc);
        self.committed.deinit(alloc);
    }

    fn addPending(self: *@This(), alloc: std.mem.Allocator, ch: ModelChange) !void {
        try self.pending.append(alloc, ch);
    }

    fn addCommitted(self: *@This(), alloc: std.mem.Allocator, changes: []const ModelChange) !void {
        var set: std.ArrayListUnmanaged(ModelChange) = .empty;
        errdefer set.deinit(alloc);
        try set.appendSlice(alloc, changes);
        try self.committed.append(alloc, set);
    }
};

const Harness = struct {
    alloc: std.mem.Allocator,
    clock: time_mod.ManualClock,
    sub: *SubscriberImpl,
    next_handle: DDS.InstanceHandle_t = 1,

    fn init(alloc: std.mem.Allocator, presentation: DDS.PresentationQosPolicy) !Harness {
        var clock = time_mod.ManualClock.init(0);
        var qos = DDS.SubscriberQos{};
        qos.presentation = presentation;
        const cbs = dcps.SubscriberParticipantCbs{
            .ctx = undefined,
            .create_proto_reader = createProtoReader,
            .destroy_proto_reader = destroyProtoReader,
            .next_handle = nextHandle,
            .register_incompat_qos = registerIncompatQos,
            .register_matched_notify = registerMatchedNotify,
            .announce_reader = announceReader,
            .timer_clock = clock.clock(),
            .register_timer_notify = registerTimerNotify,
            .get_field_fn = getFieldFn,
        };
        const sub = try SubscriberImpl.init(
            alloc,
            dcps.nil_participant,
            cbs,
            qos,
            dcps.nil_sub_listener,
            0,
            1,
        );
        return .{ .alloc = alloc, .clock = clock, .sub = sub };
    }

    fn deinit(self: *@This()) void {
        self.sub.deinit();
    }

    fn makeReader(self: *@This()) !*DataReaderImpl {
        const handle = self.next_handle;
        self.next_handle += 1;
        const dr = try self.alloc.create(DataReaderImpl);
        dr.* = .{
            .alloc = self.alloc,
            .topic_desc = dcps.nil_topic_description,
            .subscriber = self.sub.toDDSSubscriber(),
            .proto_reader = undefined,
            .qos = .{},
            .listener = dcps.nil_dr_listener,
            .listener_mask = 0,
            .instance_handle = handle,
            .status_changes = 0,
            .status_cond = null,
            .timer_clock = self.clock.clock(),
            .last_received_ns = .init(self.clock.clock().nowNs()),
            .data_notifiers = .empty,
            .pending = .empty,
            .coherent_wip = .{},
            .coherent_committed = .empty,
            .coherent_committed_ready = false,
            .mu = .{},
            .subscriber_presentation = self.sub.qos.presentation,
            .seen_instances = .empty,
        };
        try self.sub.readers.append(self.alloc, dr);
        return dr;
    }

    fn beginAccess(self: *@This()) !void {
        const dds_sub = self.sub.toDDSSubscriber();
        try testing.expectEqual(DDS.RETCODE_OK, dds_sub.vtable.begin_access(dds_sub.ptr));
    }

    fn createProtoReader(
        _: *anyopaque,
        _: []const u8,
        _: []const u8,
        _: DDS.DataReaderQos,
        _: DDS.InstanceHandle_t,
    ) anyerror!proto.ProtocolReader {
        return error.Unused;
    }

    fn destroyProtoReader(_: *anyopaque, _: DDS.InstanceHandle_t) void {}
    fn nextHandle(_: *anyopaque) DDS.InstanceHandle_t {
        return 0;
    }
    fn registerIncompatQos(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i32) void) void {}
    fn registerMatchedNotify(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, DDS.InstanceHandle_t, bool) void) void {}
    fn announceReader(_: *anyopaque, _: DDS.InstanceHandle_t, _: []const []const u8, _: DDS.PresentationQosPolicy) void {}
    fn registerTimerNotify(_: *anyopaque, _: DDS.InstanceHandle_t, _: *anyopaque, _: *const fn (*anyopaque, i64) void) void {}
    fn getFieldFn(_: *anyopaque, _: []const u8) ?*const fn ([]const u8, []const u8) ?filter_mod.FilterValue {
        return null;
    }
};

fn modelBeginAccess(
    alloc: std.mem.Allocator,
    presentation: DDS.PresentationQosPolicy,
    readers: []const *ModelReader,
) !void {
    if (presentation.coherent_access) {
        var all_ready = true;
        var any_committed = false;
        for (readers) |r| {
            if (r.wip_count > 0) all_ready = false;
            if (r.committed.items.len > 0) any_committed = true;
        }
        if (!any_committed) all_ready = false;
        if (all_ready and readers.len > 0) {
            for (readers) |r| {
                if (r.committed.items.len == 0) continue;
                var first = r.committed.orderedRemove(0);
                defer first.deinit(alloc);
                try r.pending.appendSlice(alloc, first.items);
            }
        }
    }

    if (presentation.ordered_access) {
        for (readers) |r| {
            switch (presentation.access_scope) {
                .INSTANCE_PRESENTATION_QOS => std.mem.sort(ModelChange, r.pending.items, {}, modelInstanceLessThan),
                else => std.mem.sort(ModelChange, r.pending.items, {}, modelLessThan),
            }
        }
    }
}

fn modelLessThan(_: void, a: ModelChange, b: ModelChange) bool {
    return gsnOrMax(a) < gsnOrMax(b);
}

fn modelInstanceLessThan(_: void, a: ModelChange, b: ModelChange) bool {
    if (a.instance != b.instance) return a.instance < b.instance;
    return gsnOrMax(a) < gsnOrMax(b);
}

fn gsnOrMax(ch: ModelChange) i64 {
    return ch.group_seq_num orelse std.math.maxInt(i64);
}

fn sampleInfo(instance: DDS.InstanceHandle_t) DDS.SampleInfo {
    return .{
        .sample_state = DDS.NOT_READ_SAMPLE_STATE,
        .view_state = DDS.NEW_VIEW_STATE,
        .instance_state = DDS.ALIVE_INSTANCE_STATE,
        .instance_handle = instance,
        .valid_data = true,
    };
}

fn makePending(alloc: std.mem.Allocator, ch: ModelChange) !PendingChange {
    const data = try alloc.dupe(u8, &.{ch.id});
    return .{
        .data = data,
        .alloc = alloc,
        .info = sampleInfo(ch.instance),
        .group_seq_num = ch.group_seq_num,
    };
}

fn addPending(alloc: std.mem.Allocator, dr: *DataReaderImpl, ch: ModelChange) !void {
    try dr.pending.append(alloc, try makePending(alloc, ch));
}

fn addCommitted(alloc: std.mem.Allocator, dr: *DataReaderImpl, changes: []const ModelChange) !void {
    var set: std.ArrayListUnmanaged(PendingChange) = .empty;
    errdefer {
        for (set.items) |pc| pc.deinit();
        set.deinit(alloc);
    }
    for (changes) |ch| try set.append(alloc, try makePending(alloc, ch));
    try dr.coherent_committed.append(alloc, set);
    dr.coherent_committed_ready = true;
}

fn addWip(alloc: std.mem.Allocator, dr: *DataReaderImpl, writer_guid: proto.Guid, changes: []const ModelChange) !void {
    var set: std.ArrayListUnmanaged(PendingChange) = .empty;
    errdefer {
        for (set.items) |pc| pc.deinit();
        set.deinit(alloc);
    }
    for (changes) |ch| try set.append(alloc, try makePending(alloc, ch));
    try dr.coherent_wip.put(alloc, writer_guid, set);
}

fn clearWip(alloc: std.mem.Allocator, dr: *DataReaderImpl, writer_guid: proto.Guid) void {
    if (dr.coherent_wip.fetchRemove(writer_guid)) |kv| {
        var set = kv.value;
        for (set.items) |pc| pc.deinit();
        set.deinit(alloc);
    }
}

fn expectReaderMatchesModel(dr: *DataReaderImpl, model: *const ModelReader) !void {
    dr.mu.lock();
    defer dr.mu.unlock();
    try testing.expectEqual(model.pending.items.len, dr.pending.items.len);
    for (model.pending.items, dr.pending.items) |exp, got| {
        try testing.expectEqual(@as(usize, 1), got.data.len);
        try testing.expectEqual(exp.id, got.data[0]);
        try testing.expectEqual(exp.instance, got.info.instance_handle);
        try testing.expectEqual(exp.group_seq_num, got.group_seq_num);
    }
    try testing.expectEqual(model.committed.items.len > 0, dr.coherent_committed_ready);
}

test "subscriber model: begin_access exposes one committed coherent set per call" {
    const alloc = testing.allocator;
    var presentation = DDS.PresentationQosPolicy{};
    presentation.coherent_access = true;
    var h = try Harness.init(alloc, presentation);
    defer h.deinit();
    const dr = try h.makeReader();
    var model = ModelReader{};
    defer model.deinit(alloc);

    try addCommitted(alloc, dr, &.{ .{ .id = 'A', .instance = 1 }, .{ .id = 'B', .instance = 1 } });
    try model.addCommitted(alloc, &.{ .{ .id = 'A', .instance = 1 }, .{ .id = 'B', .instance = 1 } });
    try addCommitted(alloc, dr, &.{.{ .id = 'C', .instance = 1 }});
    try model.addCommitted(alloc, &.{.{ .id = 'C', .instance = 1 }});

    try h.beginAccess();
    try modelBeginAccess(alloc, presentation, &.{&model});
    try expectReaderMatchesModel(dr, &model);

    try h.beginAccess();
    try modelBeginAccess(alloc, presentation, &.{&model});
    try expectReaderMatchesModel(dr, &model);
}

test "subscriber model: incomplete coherent WIP blocks committed sets across readers" {
    const alloc = testing.allocator;
    var presentation = DDS.PresentationQosPolicy{};
    presentation.coherent_access = true;
    var h = try Harness.init(alloc, presentation);
    defer h.deinit();
    const dr1 = try h.makeReader();
    const dr2 = try h.makeReader();
    var m1 = ModelReader{};
    defer m1.deinit(alloc);
    var m2 = ModelReader{};
    defer m2.deinit(alloc);

    try addCommitted(alloc, dr1, &.{.{ .id = 'A', .instance = 1 }});
    try m1.addCommitted(alloc, &.{.{ .id = 'A', .instance = 1 }});
    try addCommitted(alloc, dr2, &.{.{ .id = 'B', .instance = 2 }});
    try m2.addCommitted(alloc, &.{.{ .id = 'B', .instance = 2 }});
    try addWip(alloc, dr2, GUID_A, &.{.{ .id = 'C', .instance = 2 }});
    m2.wip_count = 1;

    try h.beginAccess();
    try modelBeginAccess(alloc, presentation, &.{ &m1, &m2 });
    try expectReaderMatchesModel(dr1, &m1);
    try expectReaderMatchesModel(dr2, &m2);

    clearWip(alloc, dr2, GUID_A);
    m2.wip_count = 0;
    try h.beginAccess();
    try modelBeginAccess(alloc, presentation, &.{ &m1, &m2 });
    try expectReaderMatchesModel(dr1, &m1);
    try expectReaderMatchesModel(dr2, &m2);
}

test "subscriber model: ordered access sorts pending by presentation scope" {
    const alloc = testing.allocator;

    var group_presentation = DDS.PresentationQosPolicy{};
    group_presentation.ordered_access = true;
    group_presentation.access_scope = .GROUP_PRESENTATION_QOS;
    var h_group = try Harness.init(alloc, group_presentation);
    defer h_group.deinit();
    const dr_group = try h_group.makeReader();
    var m_group = ModelReader{};
    defer m_group.deinit(alloc);

    const changes = [_]ModelChange{
        .{ .id = 'A', .instance = 1, .group_seq_num = 3 },
        .{ .id = 'B', .instance = 2, .group_seq_num = 1 },
        .{ .id = 'C', .instance = 1, .group_seq_num = 2 },
    };
    for (changes) |ch| {
        try addPending(alloc, dr_group, ch);
        try m_group.addPending(alloc, ch);
    }
    try h_group.beginAccess();
    try modelBeginAccess(alloc, group_presentation, &.{&m_group});
    try expectReaderMatchesModel(dr_group, &m_group);

    var instance_presentation = DDS.PresentationQosPolicy{};
    instance_presentation.ordered_access = true;
    instance_presentation.access_scope = .INSTANCE_PRESENTATION_QOS;
    var h_instance = try Harness.init(alloc, instance_presentation);
    defer h_instance.deinit();
    const dr_instance = try h_instance.makeReader();
    var m_instance = ModelReader{};
    defer m_instance.deinit(alloc);

    for (changes) |ch| {
        try addPending(alloc, dr_instance, ch);
        try m_instance.addPending(alloc, ch);
    }
    try h_instance.beginAccess();
    try modelBeginAccess(alloc, instance_presentation, &.{&m_instance});
    try expectReaderMatchesModel(dr_instance, &m_instance);
}
