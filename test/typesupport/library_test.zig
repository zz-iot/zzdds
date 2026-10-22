const std = @import("std");
const testing = std.testing;
const zzdds = @import("zzdds");
const ts = zzdds.typesupport;
const raw_paths = @import("library_paths");
// LazyPath options may be relative when using the default local cache. The
// loader deliberately accepts only absolute paths, including in these fixtures.
const paths = struct {
    const a = absolute(raw_paths.a);
    const b = absolute(raw_paths.b);
    const conflict = absolute(raw_paths.conflict);
    const bad_abi = absolute(raw_paths.bad_abi);
};
fn absolute(comptime path: []const u8) []const u8 {
    return if (std.fs.path.isAbsolute(path)) path else raw_paths.root ++ std.fs.path.sep_str ++ path;
}
const DDS = @import("zzdds_generated").DDS;
fn isNil(entity: anytype) bool {
    return entity.ptr == zzdds.dcps.NIL_PTR;
}
const type_name = "LibraryTest::Reading";
const sample = [_]u8{ 0, 1, 0, 0, 0, 0, 128, 63, 42, 0, 0, 0 };
const Factory = zzdds.dcps.DomainParticipantFactoryImpl;
const Participant = zzdds.dcps.DomainParticipantImpl;

const Side = struct {
    transport: *zzdds.memory_transport.MemoryTransport,
    discovery: *zzdds.direct_discovery.DirectDiscovery,
    factory: *Factory,
    dp: DDS.DomainParticipant,
    fn init(delivery: *zzdds.intraprocess.IntraProcessDelivery) !Side {
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const f = try Factory.init(testing.allocator, t.transport(), d.toDiscovery(), zzdds.noop_security.noop_security_plugins, .spec_random, .{});
        errdefer f.deinit();
        const dp = f.toDDSFactory().create_participant(187, .{}, null, 0);
        try testing.expect(!isNil(dp));
        return .{ .transport = t, .discovery = d, .factory = f, .dp = dp };
    }
    fn impl(self: Side) *Participant {
        return @ptrCast(@alignCast(self.dp.ptr));
    }
    fn deinit(self: Side) void {
        _ = self.factory.toDDSFactory().delete_participant(self.dp);
        self.factory.deinit();
        self.discovery.deinit();
        self.transport.deinit();
    }
};

test "candidate publication, immutable generations and bounded retirement" {
    var m = try ts.Manager.init(testing.allocator, 4);
    defer m.deinit();
    try m.load("project", paths.a);
    const view = try m.acquire("project");
    defer view.deinit();
    try testing.expectEqual(@as(usize, 2), view.types().len);
    const a = try view.select(type_name);
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), m.liveGenerations());
    try testing.expectError(error.IncompatibleLibrary, m.replace("project", paths.bad_abi));
    // A failed candidate leaves the old mapping intact and leaks no generation.
    if (m.replace("project", paths.a ++ ".missing")) |_| return error.ExpectedFailure else |_| {}
    try testing.expectEqual(@as(usize, 1), m.liveGenerations());
    var still_a = try m.select("project", type_name);
    try testing.expectEqual(a.generation.id, still_a.generation.id);
    still_a.deinit();
    try testing.expectError(error.ArtifactPathUnchanged, m.replace("project", paths.a));
    try m.replace("project", paths.b);
    const b = try m.select("project", type_name);
    defer b.deinit();
    try testing.expect(a.generation.id != b.generation.id);
    try testing.expect(a.equivalent(b));
    try a.validate(&sample);
    try b.validate(&sample);
    try testing.expectEqual(@as(usize, 2), m.liveGenerations());
    try m.load("conflict", paths.conflict);
    const c = try m.select("conflict", type_name);
    defer c.deinit();
    try testing.expect(!a.equivalent(c));
    try m.remove("project");
    try testing.expectError(error.UnknownProvider, m.select("project", type_name));
    try b.validate(&sample);
    try testing.expectError(error.ProviderAlreadyLoaded, m.load("conflict", paths.a));
    try testing.expectEqual(@as(usize, 3), m.liveGenerations());
}

test "retired generations count against limits and selections outlive their manager" {
    var m = try ts.Manager.init(testing.allocator, 1);
    try m.load("project", paths.a);
    const a = try m.select("project", type_name);
    try m.remove("project");
    try testing.expectError(error.GenerationLimitExceeded, m.load("new", paths.b));
    try testing.expectEqual(@as(usize, 1), m.liveGenerations());
    m.deinit();
    // Descriptors, executable code and the limit-accounting pool still exist.
    try a.validate(&sample);
    a.deinit();
}

fn allocationWork(alloc: std.mem.Allocator, descriptor: *const ts.wire.Library) !void {
    var m = try ts.Manager.init(alloc, 3);
    defer m.deinit();
    try m.addStatic("static", descriptor);
    const selected = try m.select("static", type_name);
    defer selected.deinit();
    try selected.validate(&sample);
    try m.remove("static");
    try selected.validate(&sample);
}
test "static registration and every generation-publication allocation failure clean up" {
    var m = try ts.Manager.init(testing.allocator, 1);
    defer m.deinit();
    try m.load("source", paths.a);
    const s = try m.select("source", type_name);
    defer s.deinit();
    // A borrowed descriptor's original provider is kept alive by s throughout.
    try testing.checkAllAllocationFailures(testing.allocator, allocationWork, .{s.generation.descriptor});
}

test "registered providers survive removal, validate writes and preserve keyed instances" {
    var m = try ts.Manager.init(testing.allocator, 4);
    defer m.deinit();
    try m.load("project", paths.a);
    const a = try m.select("project", type_name);
    defer a.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const pub_side = try Side.init(&delivery);
    defer pub_side.deinit();
    const read_side = try Side.init(&delivery);
    defer read_side.deinit();
    const registration = try ts.register(pub_side.dp, a);
    defer registration.deinit();
    const reader_registration = try ts.register(read_side.dp, a);
    defer reader_registration.deinit();
    const duplicate = try ts.register(pub_side.dp, a);
    duplicate.deinit();
    try m.replace("project", paths.b);
    const b = try m.select("project", type_name);
    defer b.deinit();
    try testing.expectError(error.EquivalentProviderAlreadyRegistered, ts.register(pub_side.dp, b));
    try m.load("conflict", paths.conflict);
    const c = try m.select("conflict", type_name);
    defer c.deinit();
    try testing.expectError(error.ConflictingTypeRegistration, ts.register(pub_side.dp, c));
    const topic = pub_side.dp.create_topic("LoadedReadings", type_name, .{}, null, 0);
    const reader_topic = read_side.dp.create_topic("LoadedReadings", type_name, .{}, null, 0);
    const publisher = pub_side.dp.create_publisher(.{}, null, 0);
    const subscriber = read_side.dp.create_subscriber(.{}, null, 0);
    const writer = publisher.create_datawriter(topic, .{}, null, 0);
    const reader = subscriber.create_datareader(reader_topic.as_TopicDescription(), .{ .history = .{ .depth = 8 } }, null, 0);
    try testing.expect(!isNil(writer) and !isNil(reader));
    try m.remove("project");
    try registration.write(writer, .alive, &sample);
    var second = sample;
    second[8] = 43;
    try registration.write(writer, .alive, &second);
    try testing.expectError(error.InvalidSample, registration.write(writer, .alive, sample[0..11]));
    var wrong_rep = sample;
    wrong_rep[1] = 7;
    try testing.expectError(error.UnsupportedRepresentation, registration.write(writer, .alive, &wrong_rep));
    const impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const first = impl.takeRaw() orelse return error.NoSample;
    defer testing.allocator.free(first.data);
    const next = impl.takeRaw() orelse return error.NoSample;
    defer testing.allocator.free(next.data);
    try testing.expect(first.info.instance_handle != next.info.instance_handle);
    try testing.expectEqualSlices(u8, &sample, first.data);
    try testing.expect(impl.takeRaw() == null);
    // Old registration cannot be overwritten through the legacy/native API.
    const Cleanup = struct {
        participant: *Participant,
        calls: usize = 0,
        fn hash(_: *anyopaque, _: []const u8) [16]u8 {
            return @splat(0);
        }
        fn cleanup(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!self.participant.mu.tryLock()) @panic("provider cleanup ran under participant lock");
            self.participant.mu.unlock();
            self.calls += 1;
        }
    };
    var cleanup = Cleanup{ .participant = pub_side.impl() };
    try testing.expect(!pub_side.impl().registerTypeSupport(type_name, .{ .ctx = &cleanup, .compute_key_hash = Cleanup.hash, .deinit = Cleanup.cleanup }));
    try testing.expectEqual(@as(usize, 1), cleanup.calls);
}

test "participant pin drops only at teardown and registration OOM transfers no ownership" {
    var m = try ts.Manager.init(testing.allocator, 2);
    defer m.deinit();
    try m.load("project", paths.a);
    const a = try m.select("project", type_name);
    defer a.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    for (0..4) |failure_index| {
        const side = try Side.init(&delivery);
        const before = a.generation.refs.load(.acquire);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = failure_index });
        side.impl().alloc = failing.allocator();
        const result = ts.register(side.dp, a);
        side.impl().alloc = testing.allocator;
        if (result) |registered| {
            registered.deinit();
            try testing.expectEqual(before + 1, a.generation.refs.load(.acquire));
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(u32, 0), side.impl().type_support_registry.count());
            try testing.expectEqual(before, a.generation.refs.load(.acquire));
        }
        side.deinit();
        try testing.expectEqual(before, a.generation.refs.load(.acquire));
    }
    const side = try Side.init(&delivery);
    _ = side.dp.create_topic("AlreadyCreated", type_name, .{}, null, 0);
    try testing.expectError(error.TypeInUse, ts.register(side.dp, a));
    side.deinit();
}

test "deferred protocol reader retirement keeps provider executable code alive" {
    var m = try ts.Manager.init(testing.allocator, 2);
    defer m.deinit();
    try m.load("project", paths.a);
    const a = try m.select("project", type_name);
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const side = try Side.init(&delivery);
    const registration = try ts.register(side.dp, a);
    registration.deinit();
    a.deinit();
    const topic = side.dp.create_topic("DeferredProvider", type_name, .{}, null, 0);
    const sub = side.dp.create_subscriber(.{}, null, 0);
    const reader = sub.create_datareader(topic.as_TopicDescription(), .{}, null, 0);
    try testing.expect(!isNil(reader));
    const impl: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
    const protocol = impl.proto_reader;
    try testing.expect(protocol.quiesceAcquire());
    try m.remove("project");
    side.deinit();
    // The participant and catalog are gone; in-flight protocol work still owns
    // its processor context and library. Last quiesce release can now unload it.
    try testing.expectEqual(@as(usize, 1), m.liveGenerations());
    protocol.quiesceRelease();
    try testing.expectEqual(@as(usize, 0), m.liveGenerations());
}

test "concurrent selections keep immutable provider generations pinned across replacement" {
    var m = try ts.Manager.init(testing.allocator, 16);
    defer m.deinit();
    try m.load("project", paths.a);
    const Work = struct {
        manager: *ts.Manager,
        start: std.atomic.Value(bool) = .init(false),
        failed: std.atomic.Value(bool) = .init(false),
        fn run(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            for (0..1000) |_| {
                const selected = self.manager.select("project", type_name) catch {
                    self.failed.store(true, .release);
                    return;
                };
                defer selected.deinit();
                selected.validate(&sample) catch {
                    self.failed.store(true, .release);
                    return;
                };
            }
        }
    };
    var work = Work{ .manager = &m };
    const one = try std.Thread.spawn(.{}, Work.run, .{&work});
    const two = std.Thread.spawn(.{}, Work.run, .{&work}) catch |err| {
        work.start.store(true, .release);
        one.join();
        return err;
    };
    work.start.store(true, .release);
    // Always join before propagating a replacement failure/deinitializing m.
    const replacement_error: ?anyerror = blk: {
        for (0..40) |i| m.replace("project", if (i % 2 == 0) paths.b else paths.a) catch |err| break :blk err;
        break :blk null;
    };
    one.join();
    two.join();
    if (replacement_error) |err| return err;
    try testing.expect(!work.failed.load(.acquire));
    try testing.expectEqual(@as(usize, 1), m.liveGenerations());
}

test "registered writes honor full validation independently of key-hash success" {
    var m = try ts.Manager.init(testing.allocator, 3);
    defer m.deinit();
    try m.load("source", paths.a);
    const source = try m.select("source", type_name);
    defer source.deinit();
    const Reject = struct {
        fn validate(_: [*c]const u8, _: u64) callconv(.c) u32 {
            return ts.wire.invalid_data;
        }
    };
    var descriptor = source.generation.descriptor.*;
    var exported = [_]ts.wire.Type{source.descriptor().*};
    exported[0].validate = Reject.validate;
    descriptor.types = &exported;
    descriptor.type_count = 1;
    // Static descriptor storage and its original callback provider stay live
    // until the participant, selection and manager have all released their pins.
    var rejecting = try ts.Manager.init(testing.allocator, 1);
    defer rejecting.deinit();
    try rejecting.addStatic("rejecting", &descriptor);
    const selected = try rejecting.select("rejecting", type_name);
    defer selected.deinit();
    _ = try selected.keyHash(&sample, false); // Key-hash success is insufficient.
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const side = try Side.init(&delivery);
    defer side.deinit();
    const registration = try ts.register(side.dp, selected);
    defer registration.deinit();
    const topic = side.dp.create_topic("Rejecting", type_name, .{}, null, 0);
    const publisher = side.dp.create_publisher(.{}, null, 0);
    const writer = publisher.create_datawriter(topic, .{}, null, 0);
    try testing.expectError(error.InvalidSample, registration.write(writer, .alive, &sample));
}

// A peer derives topic kind from the GUID, before receiving any payload. Both
// local sides previously used WITH_KEY unconditionally, hiding this mismatch.
test "registered keyedness determines writer and reader RTPS entity kinds" {
    var m = try ts.Manager.init(testing.allocator, 1);
    defer m.deinit();
    try m.load("project", paths.a);
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const side = try Side.init(&delivery);
    defer side.deinit();
    const publisher = side.dp.create_publisher(.{}, null, 0);
    const subscriber = side.dp.create_subscriber(.{}, null, 0);
    try testing.expect(!isNil(publisher) and !isNil(subscriber));
    const kinds = zzdds.rtps.guid.EntityKind;
    for ([_][:0]const u8{ type_name, "LibraryTest::Pulse" }, 0..) |name, i| {
        const selected = try m.select("project", name);
        defer selected.deinit();
        const registration = try ts.register(side.dp, selected);
        defer registration.deinit();
        const topic = side.dp.create_topic(name, name, .{}, null, 0);
        try testing.expect(!isNil(topic));
        const writer = publisher.create_datawriter(topic, .{}, null, 0);
        const reader = subscriber.create_datareader(topic.as_TopicDescription(), .{}, null, 0);
        try testing.expect(!isNil(writer) and !isNil(reader));
        const wi: *zzdds.dcps.DataWriterImpl = @ptrCast(@alignCast(writer.ptr));
        const ri: *zzdds.dcps.DataReaderImpl = @ptrCast(@alignCast(reader.ptr));
        try testing.expectEqual(if (i == 0) kinds.user_writer_with_key else kinds.user_writer_no_key, wi.guid.entity_id.entity_kind);
        try testing.expectEqual(if (i == 0) kinds.user_reader_with_key else kinds.user_reader_no_key, ri.guid.entity_id.entity_kind);
    }
}

extern fn zidl_ts_c_probe(*const ts.wire.Library) callconv(.c) c_int;
test "OS-loaded descriptor uses the native C layout and callback convention" {
    var manager = try ts.Manager.init(testing.allocator, 1);
    defer manager.deinit();
    try manager.load("project", paths.a);
    const selected = try manager.select("project", type_name);
    defer selected.deinit();
    try testing.expectEqual(@as(c_int, 0), zidl_ts_c_probe(selected.generation.descriptor));
}

test "dynamic candidates require explicit NUL-free absolute artifact paths" {
    var manager = try ts.Manager.init(testing.allocator, 1);
    defer manager.deinit();
    try testing.expectError(error.AbsoluteLibraryPathRequired, manager.load("project", "provider.so"));
    try testing.expectError(error.InvalidLibraryPath, manager.load("project", paths.a ++ "\x00ignored"));
    if (@import("builtin").os.tag == .windows)
        try testing.expectError(error.AbsoluteLibraryPathRequired, manager.load("project", "\\rooted.dll"));
    try testing.expectEqual(@as(usize, 0), manager.liveGenerations());
    try manager.load("project", paths.a);
}

extern fn zidl_ts_module_loaded([*:0]const u8) callconv(.c) c_int;
test "native modules unload only after retired generation users release" {
    // musl's static ELF loader is not represented in dlopen's module table.
    if (@import("builtin").abi == .musl) return error.SkipZigTest;
    const a_path = try testing.allocator.dupeSentinel(u8, paths.a, 0);
    defer testing.allocator.free(a_path);
    const b_path = try testing.allocator.dupeSentinel(u8, paths.b, 0);
    defer testing.allocator.free(b_path);
    try testing.expectEqual(@as(c_int, 0), zidl_ts_module_loaded(a_path));
    var manager = try ts.Manager.init(testing.allocator, 2);
    defer manager.deinit();
    try manager.load("project", paths.a);
    var old: ?ts.Selection = try manager.select("project", type_name);
    defer if (old) |selection| selection.deinit();
    try manager.replace("project", paths.b);
    try testing.expectEqual(@as(c_int, 1), zidl_ts_module_loaded(a_path));
    try testing.expectEqual(@as(c_int, 1), zidl_ts_module_loaded(b_path));
    try manager.remove("project");
    try testing.expectEqual(@as(c_int, 0), zidl_ts_module_loaded(b_path));
    try testing.expectEqual(@as(c_int, 1), zidl_ts_module_loaded(a_path));
    try old.?.validate(&sample);
    old.?.deinit();
    old = null;
    try testing.expectEqual(@as(c_int, 0), zidl_ts_module_loaded(a_path));
    try testing.expectEqual(@as(usize, 0), manager.liveGenerations());
}

fn dynamicAllocationWork(alloc: std.mem.Allocator) !void {
    var manager = try ts.Manager.init(alloc, 2);
    defer manager.deinit();
    try manager.load("project", paths.a);
    const old = try manager.select("project", type_name);
    defer old.deinit();
    manager.replace("project", paths.b) catch |err| {
        // Candidate allocation failures must preserve the published generation.
        const current = try manager.select("project", type_name);
        defer current.deinit();
        try testing.expectEqual(old.generation.id, current.generation.id);
        try old.validate(&sample);
        return err;
    };
    try old.validate(&sample);
    const current = try manager.select("project", type_name);
    defer current.deinit();
    try testing.expect(old.generation.id != current.generation.id);
    try current.validate(&sample);
}
test "OS load and replacement allocation failures preserve ownership and publication" {
    try testing.checkAllAllocationFailures(testing.allocator, dynamicAllocationWork, .{});
}
