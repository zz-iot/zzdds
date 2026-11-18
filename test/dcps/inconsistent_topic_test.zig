//! INCONSISTENT_TOPIC (DDS 1.4 §2.2.4.1): a Topic counts each discovered
//! DataWriter and DataReader with its name and another type, and reports
//! it through its StatusCondition and `on_inconsistent_topic`, else the
//! participant's (§2.2.4.1.5).

const std = @import("std");
const test_domain = @import("test_domain");
const ManualRuntime = @import("manual_runtime").ManualRuntime;
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

const TOPIC = "InconsistentTopic";

/// Two participants over IntraProcessDelivery, on a ManualRuntime: `dp_a`
/// makes the endpoints, `dp_b` the Topic under test.
const Fixture = struct {
    mr: *ManualRuntime,
    delivery: IntraProcessDelivery,
    t_a: *zzdds.intraprocess.MemoryTransport,
    d_a: *zzdds.intraprocess.DirectDiscovery,
    factory_a: *DomainParticipantFactoryImpl,
    dp_a: DDS.DomainParticipant,
    t_b: *zzdds.intraprocess.MemoryTransport,
    d_b: *zzdds.intraprocess.DirectDiscovery,
    factory_b: *DomainParticipantFactoryImpl,
    dp_b: DDS.DomainParticipant,

    fn init(alloc: std.mem.Allocator, b_qos: DDS.DomainParticipantQos) !Fixture {
        const mr = try std.heap.page_allocator.create(ManualRuntime);
        errdefer std.heap.page_allocator.destroy(mr);
        mr.init();
        errdefer mr.deinit();
        var delivery = try IntraProcessDelivery.init(alloc);
        errdefer delivery.deinit();

        const t_a = try delivery.newTransport();
        errdefer t_a.deinit();
        const d_a = try delivery.newDiscovery();
        errdefer d_a.deinit();
        const factory_a = try DomainParticipantFactoryImpl.init(alloc, t_a.transport(), d_a.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_a.deinit();
        const dp_a = factory_a.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);

        const t_b = try delivery.newTransport();
        errdefer t_b.deinit();
        const d_b = try delivery.newDiscovery();
        errdefer d_b.deinit();
        const factory_b = try DomainParticipantFactoryImpl.init(alloc, t_b.transport(), d_b.toDiscovery(), noop_security, .spec_random, .{});
        errdefer factory_b.deinit();
        const dp_b = factory_b.toDDSFactory().create_participant(test_domain.get(), b_qos, null, 0);
        mr.settle();

        return .{
            .mr = mr,
            .delivery = delivery,
            .t_a = t_a,
            .d_a = d_a,
            .factory_a = factory_a,
            .dp_a = dp_a,
            .t_b = t_b,
            .d_b = d_b,
            .factory_b = factory_b,
            .dp_b = dp_b,
        };
    }

    fn deinit(self: *Fixture) void {
        self.mr.settle();
        _ = self.factory_a.toDDSFactory().delete_participant(self.dp_a);
        _ = self.factory_b.toDDSFactory().delete_participant(self.dp_b);
        self.mr.settle();
        self.factory_a.deinit();
        self.factory_b.deinit();
        self.d_a.deinit();
        self.d_b.deinit();
        self.t_a.deinit();
        self.t_b.deinit();
        self.delivery.deinit();
        self.mr.deinit();
        std.heap.page_allocator.destroy(self.mr);
    }

    /// A DataWriter and a DataReader on `dp_a`'s Topic of `type_name`.
    fn endpointsOfType(self: *Fixture, type_name: [:0]const u8) DDS.Topic {
        const topic = self.dp_a.create_topic(TOPIC, type_name, .{}, null, 0);
        const pub_ = self.dp_a.create_publisher(.{}, null, 0);
        _ = pub_.create_datawriter(topic, .{}, null, 0);
        const sub_ = self.dp_a.create_subscriber(.{}, null, 0);
        _ = sub_.create_datareader(@as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription(), .{}, null, 0);
        self.mr.settle();
        return topic;
    }
};

const Seen = struct {
    calls: u32 = 0,
    change_sum: i32 = 0,
    last: DDS.InconsistentTopicStatus = .{},
    handle: ?*anyopaque = null,
    /// Deletes `topic` from its own callback.
    delete_from: ?DDS.DomainParticipant = null,
    topic: DDS.Topic = undefined,
};

fn onInconsistent(handle: *anyopaque, status: *const DDS.InconsistentTopicStatus, ld: ?*anyopaque) callconv(.c) void {
    const seen: *Seen = @ptrCast(@alignCast(ld.?));
    seen.calls += 1;
    seen.change_sum += status.total_count_change;
    seen.last = status.*;
    seen.handle = handle;
    if (seen.delete_from) |dp| std.debug.assert(dp.vtable.delete_topic(dp.ptr, seen.topic) == DDS.RETCODE_OK);
}

fn topicListener(seen: *Seen) DDS.TopicListener {
    return .{ .listener_data = seen, .on_inconsistent_topic = onInconsistent };
}

fn statusOf(topic: DDS.Topic) DDS.InconsistentTopicStatus {
    var st: DDS.InconsistentTopicStatus = .{};
    std.debug.assert(topic.vtable.get_inconsistent_topic_status(topic.ptr, &st) == DDS.RETCODE_OK);
    return st;
}

fn statusChanges(topic: DDS.Topic) DDS.StatusMask {
    return topic.vtable.get_status_changes(topic.ptr);
}

fn cAbiHandle(topic: DDS.Topic) *anyopaque {
    return topic.vtable.get_c_abi_handle(topic.ptr);
}

fn topicOctets(bytes: []const u8) @FieldType(DDS.TopicDataQosPolicy, "value") {
    return .{ ._buffer = @constCast(bytes.ptr), ._length = @intCast(bytes.len), ._maximum = @intCast(bytes.len), ._release = false };
}

test "a discovered DataWriter and DataReader of another type count once each, and reach the Topic's listener" {
    var fx = try Fixture.init(testing.allocator, .{});
    defer fx.deinit();
    var seen = Seen{};
    const topic_b = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, topicListener(&seen), DDS.INCONSISTENT_TOPIC_STATUS);

    const topic_a = fx.endpointsOfType("TypeA");
    try testing.expect(seen.calls > 0);
    try testing.expectEqual(@as(i32, 2), seen.last.total_count);
    try testing.expectEqual(@as(i32, 2), seen.change_sum);
    try testing.expectEqual(cAbiHandle(topic_b), seen.handle.?);
    // The listener took the change.
    try testing.expect(statusChanges(topic_b) & DDS.INCONSISTENT_TOPIC_STATUS == 0);

    // Announced again, they are not counted again.
    var qos = DDS.TopicQos{};
    qos.topic_data.value = topicOctets("again");
    try testing.expectEqual(DDS.RETCODE_OK, topic_a.set_qos(qos));
    fx.mr.settle();
    const st = statusOf(topic_b);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 0), st.total_count_change);
    try testing.expectEqual(@as(i32, 2), seen.change_sum);
}

test "endpoints of the same type are not inconsistent" {
    var fx = try Fixture.init(testing.allocator, .{});
    defer fx.deinit();
    var seen = Seen{};
    const topic_b = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, topicListener(&seen), DDS.INCONSISTENT_TOPIC_STATUS);

    _ = fx.endpointsOfType("TypeB");
    try testing.expectEqual(@as(u32, 0), seen.calls);
    try testing.expect(statusChanges(topic_b) & DDS.INCONSISTENT_TOPIC_STATUS == 0);
    try testing.expectEqual(@as(i32, 0), statusOf(topic_b).total_count);
}

test "a Topic created after them counts the endpoints discovered already" {
    var fx = try Fixture.init(testing.allocator, .{});
    defer fx.deinit();
    _ = fx.endpointsOfType("TypeA");

    var seen = Seen{};
    const topic_b = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, topicListener(&seen), DDS.INCONSISTENT_TOPIC_STATUS);
    fx.mr.settle();
    try testing.expectEqual(@as(u32, 1), seen.calls);
    try testing.expectEqual(@as(i32, 2), seen.last.total_count);
    try testing.expectEqual(@as(i32, 2), seen.last.total_count_change);
    try testing.expectEqual(cAbiHandle(topic_b), seen.handle.?);
}

test "a Topic with no listener of its own reaches the participant's on_inconsistent_topic, with the Topic's handle" {
    var fx = try Fixture.init(testing.allocator, .{});
    defer fx.deinit();
    var seen = Seen{};
    const dp_listener = DDS.DomainParticipantListener{ .listener_data = &seen, .on_inconsistent_topic = onInconsistent };
    try testing.expectEqual(DDS.RETCODE_OK, fx.dp_b.vtable.set_listener(fx.dp_b.ptr, &dp_listener, DDS.INCONSISTENT_TOPIC_STATUS));
    // Its own listener, without the status in its mask, does not take it.
    var own = Seen{};
    const topic_b = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, topicListener(&own), 0);

    _ = fx.endpointsOfType("TypeA");
    try testing.expectEqual(@as(u32, 0), own.calls);
    try testing.expect(seen.calls > 0);
    try testing.expectEqual(@as(i32, 2), seen.change_sum);
    try testing.expectEqual(cAbiHandle(topic_b), seen.handle.?);
}

test "with no listener, the status waits for the getter and wakes the StatusCondition" {
    var fx = try Fixture.init(testing.allocator, .{});
    defer fx.deinit();
    const topic_b = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, null, 0);
    const cond = topic_b.vtable.get_statuscondition(topic_b.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, cond.vtable.set_enabled_statuses(cond.ptr, DDS.INCONSISTENT_TOPIC_STATUS));
    try testing.expect(!cond.vtable.get_trigger_value(cond.ptr));

    _ = fx.endpointsOfType("TypeA");
    try testing.expect(cond.vtable.get_trigger_value(cond.ptr));
    const st = statusOf(topic_b);
    try testing.expectEqual(@as(i32, 2), st.total_count);
    try testing.expectEqual(@as(i32, 2), st.total_count_change);
    try testing.expect(!cond.vtable.get_trigger_value(cond.ptr));
    try testing.expectEqual(@as(i32, 0), statusOf(topic_b).total_count_change);
}

test "a disabled Topic counts them, and its listener runs once it is enabled" {
    var b_qos = DDS.DomainParticipantQos{};
    b_qos.entity_factory.autoenable_created_entities = false;
    var fx = try Fixture.init(testing.allocator, b_qos);
    defer fx.deinit();
    var seen = Seen{};
    const topic_b = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, topicListener(&seen), DDS.INCONSISTENT_TOPIC_STATUS);

    _ = fx.endpointsOfType("TypeA");
    try testing.expectEqual(@as(u32, 0), seen.calls);
    try testing.expect(statusChanges(topic_b) & DDS.INCONSISTENT_TOPIC_STATUS != 0);

    try testing.expectEqual(DDS.RETCODE_OK, topic_b.vtable.enable(topic_b.ptr));
    fx.mr.settle();
    try testing.expectEqual(@as(u32, 1), seen.calls);
    try testing.expectEqual(@as(i32, 2), seen.last.total_count);
    try testing.expectEqual(@as(i32, 2), seen.last.total_count_change);
}

test "a Topic deleted from its own on_inconsistent_topic is freed once the callback returns" {
    var fx = try Fixture.init(testing.allocator, .{});
    defer fx.deinit();
    var seen = Seen{ .delete_from = fx.dp_b };
    seen.topic = fx.dp_b.create_topic(TOPIC, "TypeB", .{}, topicListener(&seen), DDS.INCONSISTENT_TOPIC_STATUS);

    _ = fx.endpointsOfType("TypeA");
    try testing.expectEqual(@as(u32, 1), seen.calls);
    const p: *zzdds.dcps.DomainParticipantImpl = @ptrCast(@alignCast(fx.dp_b.ptr));
    try testing.expectEqual(@as(usize, 0), p.topics.items.len);
}
