const std = @import("std");
const zzdds = @import("zzdds");
const DDS = zzdds.DDS;
const R = zzdds.resources;
const testing = std.testing;
const Probe = @import("resource_probe").Probe;
const domain = @import("test_domain");

fn definition(writer: bool) R.Participant {
    return .{
        .name = "main",
        .domain_id = @intCast(domain.get()),
        .types = &.{.{ .name = "Probe" }},
        .topics = &.{.{ .name = "announcement", .topic_name = "Announcement", .type_ref = "Probe" }},
        .publishers = if (writer) &.{.{ .name = "pub" }} else &.{},
        .subscribers = if (!writer) &.{.{ .name = "sub" }} else &.{},
        .writers = if (writer) &.{.{ .name = "endpoint", .container_ref = "pub", .topic_ref = "announcement" }} else &.{},
        .readers = if (!writer) &.{.{ .name = "endpoint", .container_ref = "sub", .topic_ref = "announcement" }} else &.{},
    };
}
// Compiled-in wire adapter using zidl-generated Probe callbacks.
// Each registration has its own participant-owned support; no shared owned ctx.
fn register(_: ?*anyopaque, dp: DDS.DomainParticipant, name: []const u8) !void {
    if (!zzdds.registerTypeSupport(dp, name, .{ .ctx = @constCast(&testing.allocator), .has_key = Probe.has_key, .compute_key_hash = Probe.computeKeyHashFromCdr }))
        return error.RegistrationFailed;
}
const bindings = [_]R.StaticBinding{.{ .type_name = "Probe", .register = register }};

const Side = struct {
    transport: *zzdds.intraprocess.MemoryTransport,
    discovery: *zzdds.intraprocess.DirectDiscovery,
    factory: *zzdds.dcps.DomainParticipantFactoryImpl,
    fn init(delivery: *zzdds.intraprocess.IntraProcessDelivery) !Side {
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const f = try zzdds.dcps.DomainParticipantFactoryImpl.init(testing.allocator, t.transport(), d.toDiscovery(), zzdds.noop_security.noop_security_plugins, .spec_random, .{});
        return .{ .transport = t, .discovery = d, .factory = f };
    }
    fn deinit(self: Side) void {
        self.factory.deinit();
        self.discovery.deinit();
        self.transport.deinit();
    }
};

test "owned plans instantiate independent writer/reader graphs and exchange bytes" {
    var wp = definition(true);
    var participant_name = [_]u8{ 'm', 'a', 'i', 'n' };
    wp.name = &participant_name;
    var rp = definition(false);
    var writer_plan = try R.Plan.resolve(testing.allocator, .{ .name = "writer", .participants = (&wp)[0..1] }, .{});
    defer writer_plan.deinit();
    var reader_plan = try R.Plan.resolve(testing.allocator, .{ .name = "reader", .participants = (&rp)[0..1] }, .{});
    defer reader_plan.deinit();
    // Overwriting authored data cannot change the plan.
    wp.name = "overwritten";
    @memset(&participant_name, 'x');
    try testing.expectEqualStrings("main", writer_plan.application.participants[0].name);
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    const b = try Side.init(&delivery);
    defer b.deinit();
    const c = try Side.init(&delivery);
    defer c.deinit();
    var wi = try R.Instance.init(testing.allocator, &writer_plan, a.factory.toDDSFactory());
    defer wi.deinit() catch @panic("writer cleanup");
    var ri = try R.Instance.init(testing.allocator, &reader_plan, b.factory.toDDSFactory());
    defer ri.deinit() catch @panic("reader cleanup");
    var wi2 = try R.Instance.init(testing.allocator, &writer_plan, c.factory.toDDSFactory());
    defer wi2.deinit() catch @panic("second writer cleanup");
    try ri.build(&bindings);
    try wi.build(&bindings);
    try wi2.build(&bindings);
    const w = try wi.writer("main", "endpoint");
    const w2 = try wi2.writer("main", "endpoint");
    try testing.expect(w.ptr != w2.ptr);
    const reader = try ri.reader("main", "endpoint");
    const payload = [_]u8{ 0, 1, 0, 0, 42, 0, 0, 0 };
    try @import("resource_probe").ProbeDataWriter.init(w, testing.allocator).write(.{ .value = 42 }, 0);
    const sample = zzdds.takeRaw(reader) orelse return error.NoSample;
    defer sample.deinit();
    try testing.expectEqualSlices(u8, &payload, sample.data);
    try wi.destroy();
    try testing.expectError(error.InvalidState, wi.writer("main", "endpoint"));
    try @import("resource_probe").ProbeDataWriter.init(w2, testing.allocator).write(.{ .value = 42 }, 0);
    const second = zzdds.takeRaw(reader) orelse return error.NoSample;
    defer second.deinit();
    try testing.expectEqualSlices(u8, &payload, second.data);
}

test "resolution rejects references, duplicate identities, QoS and budgets before DDS" {
    var p = definition(true);
    const app = R.Application{ .name = "app", .participants = (&p)[0..1] };
    try testing.expectError(error.ResourceLimit, R.Plan.resolve(testing.allocator, app, .{ .max_resources = 2 }));
    p.domain_id = -1;
    try testing.expectError(error.InvalidDomain, R.Plan.resolve(testing.allocator, app, .{}));
    p = definition(true);
    p.topics = &.{.{ .name = "t", .topic_name = "T", .type_ref = "Missing" }};
    try testing.expectError(error.UnknownReference, R.Plan.resolve(testing.allocator, app, .{}));
    p = definition(true);
    p.writers = &.{.{ .name = "w", .container_ref = "missing", .topic_ref = "announcement" }};
    try testing.expectError(error.UnknownReference, R.Plan.resolve(testing.allocator, app, .{}));
    p.writers = &.{.{ .name = "w", .container_ref = "pub", .topic_ref = "announcement", .qos = .{ .history_depth = 33 } }};
    try testing.expectError(error.InvalidQos, R.Plan.resolve(testing.allocator, app, .{}));
    p = definition(true);
    p.types = &.{ .{ .name = "Probe" }, .{ .name = "Probe" } };
    try testing.expectError(error.DuplicateName, R.Plan.resolve(testing.allocator, app, .{}));
}

test "plan allocation failure releases all partial copies" {
    const AllocationProbe = struct {
        fn run(a: std.mem.Allocator) !void {
            const p = definition(true);
            var plan = try R.Plan.resolve(a, .{ .name = "app", .participants = (&p)[0..1] }, .{});
            defer plan.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, AllocationProbe.run, .{});
}

test "missing binding creates nothing; failing registration retains cleanup owner" {
    const p = definition(true);
    var plan = try R.Plan.resolve(testing.allocator, .{ .name = "app", .participants = (&p)[0..1] }, .{});
    defer plan.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    var instance = try R.Instance.init(testing.allocator, &plan, a.factory.toDDSFactory());
    defer instance.deinit() catch @panic("cleanup");
    try testing.expectError(error.MissingBinding, instance.build(&.{}));
    try testing.expect(instance.local[0].participant == null);
    const Fail = struct {
        fn install(_: ?*anyopaque, _: DDS.DomainParticipant, _: []const u8) !void {
            return error.InjectedFailure;
        }
    };
    try testing.expectError(error.InjectedFailure, instance.build(&.{.{ .type_name = "Probe", .register = Fail.install }}));
    try testing.expect(instance.local[0].participant == null);
    try testing.expect(instance.cleanup_error == null);
    try instance.destroy();
    try testing.expect(instance.local[0].participant == null);
    try instance.destroy();
}

test "reentrant cancellation never waits for its own constructor" {
    const p = definition(true);
    var plan = try R.Plan.resolve(testing.allocator, .{ .name = "app", .participants = (&p)[0..1] }, .{});
    defer plan.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    var instance = try R.Instance.init(testing.allocator, &plan, a.factory.toDDSFactory());
    defer instance.deinit() catch @panic("cleanup");
    const Cancel = struct {
        fn install(ctx: ?*anyopaque, _: DDS.DomainParticipant, _: []const u8) !void {
            const owner: *R.Instance = @ptrCast(@alignCast(ctx.?));
            try testing.expectError(error.ConstructionInProgress, owner.destroy());
        }
    };
    try testing.expectError(error.Cancelled, instance.build(&.{.{ .type_name = "Probe", .context = &instance, .register = Cancel.install }}));
    try instance.destroy();
}

const MatchAction = struct {
    owner: *R.Instance,
    fired: bool = false,
    deleted: bool = false,
    cancelled: bool = false,
    fn install(ctx: ?*anyopaque, dp: DDS.DomainParticipant, name: []const u8) !void {
        try register(null, dp, name);
        const listener = DDS.DomainParticipantListener{
            .listener_data = ctx,
            .on_publication_matched = writerMatched,
            .on_subscription_matched = readerMatched,
        };
        if (dp.set_listener(listener, DDS.PUBLICATION_MATCHED_STATUS | DDS.SUBSCRIPTION_MATCHED_STATUS) != DDS.RETCODE_OK)
            return error.ListenerFailed;
    }
    fn writerMatched(handle: *anyopaque, _: *const DDS.PublicationMatchedStatus, ctx: ?*anyopaque) callconv(.c) void {
        const action: *MatchAction = @ptrCast(@alignCast(ctx.?));
        if (action.fired) return;
        action.fired = true;
        const writer = zzdds.zidl_rt.unboxAsView(DDS.DataWriter, handle);
        action.deleted = writer.get_publisher().delete_datawriter(writer) == DDS.RETCODE_OK;
        action.owner.destroy() catch |err| {
            action.cancelled = err == error.ConstructionInProgress;
        };
    }
    fn readerMatched(handle: *anyopaque, _: *const DDS.SubscriptionMatchedStatus, ctx: ?*anyopaque) callconv(.c) void {
        const action: *MatchAction = @ptrCast(@alignCast(ctx.?));
        if (action.fired) return;
        action.fired = true;
        const reader = zzdds.zidl_rt.unboxAsView(DDS.DataReader, handle);
        action.deleted = reader.get_subscriber().delete_datareader(reader) == DDS.RETCODE_OK;
        action.owner.destroy() catch |err| {
            action.cancelled = err == error.ConstructionInProgress;
        };
    }
};

test "match callback deletes constructing writer or reader and requests graph destruction" {
    for ([_]bool{ true, false }) |writer| {
        const p = definition(writer);
        const peer_p = definition(!writer);
        var plan = try R.Plan.resolve(testing.allocator, .{ .name = "app", .participants = (&p)[0..1] }, .{});
        defer plan.deinit();
        var peer_plan = try R.Plan.resolve(testing.allocator, .{ .name = "peer", .participants = (&peer_p)[0..1] }, .{});
        defer peer_plan.deinit();
        var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
        defer delivery.deinit();
        const a = try Side.init(&delivery);
        defer a.deinit();
        const b = try Side.init(&delivery);
        defer b.deinit();
        var peer = try R.Instance.init(testing.allocator, &peer_plan, b.factory.toDDSFactory());
        defer peer.deinit() catch @panic("peer cleanup");
        try peer.build(&bindings);
        var instance = try R.Instance.init(testing.allocator, &plan, a.factory.toDDSFactory());
        defer instance.deinit() catch @panic("cleanup");
        var action = MatchAction{ .owner = &instance };
        const result = instance.build(&.{.{ .type_name = "Probe", .context = &action, .register = MatchAction.install }});
        if (writer) try testing.expectError(error.WriterCreationFailed, result) else try testing.expectError(error.ReaderCreationFailed, result);
        try testing.expect(action.fired and action.deleted and action.cancelled);
        try instance.destroy();
    }
}

// Faults at public factory boundaries; the real DDS implementation still owns
// every created entity. This also proves the builder never deinitializes a factory.
const FactoryProbe = struct {
    inner: DDS.DomainParticipantFactory,
    vtable: DDS.DomainParticipantFactory.Vtable,
    creates: usize = 0,
    deletes: usize = 0,
    fail_create: usize = 0,
    fail_delete: bool = false,
    fn handle(self: *@This()) DDS.DomainParticipantFactory {
        self.vtable.create_participant = create;
        self.vtable.delete_participant = delete;
        return .{ .ptr = self, .vtable = &self.vtable };
    }
    fn create(ctx: *anyopaque, id: DDS.DomainId_t, qos: *const DDS.DomainParticipantQos, listener: ?*const DDS.DomainParticipantListener, mask: DDS.StatusMask) DDS.DomainParticipant {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.creates += 1;
        if (self.creates == self.fail_create) return zzdds.dcps.nil_participant;
        return self.inner.vtable.create_participant(self.inner.ptr, id, qos, listener, mask);
    }
    fn delete(ctx: *anyopaque, dp: DDS.DomainParticipant) DDS.ReturnCode_t {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.deletes += 1;
        if (self.fail_delete) {
            self.fail_delete = false;
            return DDS.RETCODE_PRECONDITION_NOT_MET;
        }
        return self.inner.delete_participant(dp);
    }
};

test "late failure retains prior graph and failed deletion is retryable" {
    var participants = [_]R.Participant{ definition(true), definition(false) };
    participants[1].name = "second";
    var plan = try R.Plan.resolve(testing.allocator, .{ .name = "app", .participants = &participants }, .{});
    defer plan.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    const factory = a.factory.toDDSFactory();
    var probe = FactoryProbe{ .inner = factory, .vtable = factory.vtable.*, .fail_create = 2, .fail_delete = true };
    var instance = try R.Instance.init(testing.allocator, &plan, probe.handle());
    defer instance.deinit() catch @panic("cleanup");
    try testing.expectError(error.ParticipantCreationFailed, instance.build(&bindings));
    try testing.expect(instance.local[0].participant != null);
    try testing.expectEqual(error.CleanupFailed, instance.cleanup_error.?);
    try testing.expect(instance.local[0].participant != null);
    try instance.destroy();
    try testing.expect(instance.local[0].participant == null);
    try testing.expectEqual(@as(usize, 2), probe.deletes);
}

test "bookkeeping allocation failure creates no DDS entities" {
    const p = definition(true);
    var plan = try R.Plan.resolve(testing.allocator, .{ .name = "app", .participants = (&p)[0..1] }, .{});
    defer plan.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    const factory = a.factory.toDDSFactory();
    var probe = FactoryProbe{ .inner = factory, .vtable = factory.vtable.* };
    const Run = struct {
        fn run(alloc: std.mem.Allocator, plan_: *const R.Plan, f: DDS.DomainParticipantFactory) !void {
            var instance = try R.Instance.init(alloc, plan_, f);
            defer instance.deinit() catch @panic("cleanup");
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ &plan, probe.handle() });
    try testing.expectEqual(@as(usize, 0), probe.creates);
}

test "concrete QoS is applied through the public endpoint constructor" {
    var p = definition(true);
    p.writers = &.{.{
        .name = "endpoint",
        .container_ref = "pub",
        .topic_ref = "announcement",
        .qos = .{ .reliability = .RELIABLE_RELIABILITY_QOS, .history_depth = 3, .max_samples = 6, .max_instances = 2, .max_samples_per_instance = 3 },
    }};
    var plan = try R.Plan.resolve(testing.allocator, .{ .name = "app", .participants = (&p)[0..1] }, .{});
    defer plan.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    var instance = try R.Instance.init(testing.allocator, &plan, a.factory.toDDSFactory());
    defer instance.deinit() catch @panic("cleanup");
    try instance.build(&bindings);
    var qos: DDS.DataWriterQos = .{};
    try testing.expectEqual(DDS.RETCODE_OK, (try instance.writer("main", "endpoint")).get_qos(&qos));
    defer qos.deinit(testing.allocator);
    try testing.expectEqual(DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS, qos.reliability.kind);
    try testing.expectEqual(@as(i32, 3), qos.history.depth);
    try testing.expectEqual(@as(i32, 6), qos.resource_limits.max_samples);
    try testing.expectEqual(@as(i16, 0), qos.data_representation.value._buffer.?[0]);
}
