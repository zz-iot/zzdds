const std = @import("std");
const dds = @import("zzdds");
const R = dds.resources;
const P = R.providers;
const ts = dds.typesupport;
const testing = std.testing;
const a = @import("provider_a");
const paths = @import("library_paths");
const reading = "LibraryTest::Reading";
const pulse = "LibraryTest::Pulse";
fn plan(alloc: std.mem.Allocator) !R.Plan {
    return planFor(alloc, .XCDR1);
}
fn planFor(alloc: std.mem.Allocator, representation: R.DataRepresentation) !R.Plan {
    return R.Plan.resolve(alloc, .{ .name = "multi", .participants = &.{.{
        .name = "main",
        .domain_id = 184,
        .types = &.{ .{ .name = reading }, .{ .name = pulse } },
        .topics = &.{ .{ .name = "reading", .topic_name = "Reading", .type_ref = reading }, .{ .name = "pulse", .topic_name = "Pulse", .type_ref = pulse } },
        .publishers = &.{.{ .name = "pub" }},
        .subscribers = &.{.{ .name = "sub" }},
        .readers = &.{ .{ .name = "reading", .container_ref = "sub", .topic_ref = "reading", .qos = .{ .data_representation = representation } }, .{ .name = "pulse", .container_ref = "sub", .topic_ref = "pulse", .qos = .{ .data_representation = representation } } },
        .writers = &.{ .{ .name = "reading", .container_ref = "pub", .topic_ref = "reading", .qos = .{ .data_representation = representation } }, .{ .name = "pulse", .container_ref = "pub", .topic_ref = "pulse", .qos = .{ .data_representation = representation } } },
    }} }, .{});
}
const bindings = [_]P.Binding{
    .{ .participant = "main", .type_name = reading, .source = .{ .provider = .{ .provider = "project_b", .name = reading } } },
    .{ .participant = "main", .type_name = pulse, .source = .{ .provider = .{ .provider = "project_a", .name = pulse } } },
};
fn manager(alloc: std.mem.Allocator) !ts.Manager {
    var m = try ts.Manager.init(alloc, 8);
    errdefer m.deinit();
    if (comptime paths.dynamic_enabled) {
        const first = try std.fs.path.resolve(alloc, &.{ paths.root, paths.a });
        defer alloc.free(first);
        const second = try std.fs.path.resolve(alloc, &.{ paths.root, paths.b });
        defer alloc.free(second);
        try m.load("project_a", first);
        try m.load("project_b", second);
    } else {
        try m.addStatic("project_a", &a.library);
        try m.addStatic("project_b", &a.library);
    }
    return m;
}
test "offline validation requires an explicit export per participant and forbids aliases" {
    var p = try plan(testing.allocator);
    defer p.deinit();
    try P.validate(&p, &bindings, .{});
    try testing.expectError(error.MissingBinding, P.validate(&p, bindings[0..1], .{}));
    try testing.expectError(error.DuplicateBinding, P.validate(&p, &.{ bindings[0], bindings[0], bindings[1] }, .{}));
    var equivalent_choice = bindings[0];
    equivalent_choice.source.provider.provider = "project_a";
    try testing.expectError(error.DuplicateBinding, P.validate(&p, &.{ bindings[0], equivalent_choice, bindings[1] }, .{}));
    var bad = bindings;
    bad[0].source.provider.name = "SomeAlias";
    try testing.expectError(error.RegisteredNameAliasUnsupported, P.validate(&p, &bad, .{}));
    bad = bindings;
    bad[0].participant = "absent";
    try testing.expectError(error.UnknownBinding, P.validate(&p, &bad, .{}));
}
test "preparation pins selections after manager removal and owns its plan" {
    var m = try manager(testing.allocator);
    defer m.deinit();
    var ready = blk: {
        var p = try plan(testing.allocator);
        defer p.deinit();
        break :blk try P.Prepared.init(testing.allocator, &p, &m, &bindings, .{});
    };
    defer ready.deinit();
    const generation = ready.info(0).generation.?;
    try m.remove("project_b");
    try m.addStatic("project_b", &a.library);
    var expected = bindings;
    expected[0].expected_identifier = ready.info(0).minimal_identifier;
    var next = try P.Prepared.init(testing.allocator, &ready.plan, &m, &expected, .{});
    defer next.deinit();
    try testing.expect(generation != next.info(0).generation.?);
    try testing.expectEqual(ready.info(0).minimal_identifier, next.info(0).minimal_identifier);
    try testing.expectEqualStrings("project_b", ready.info(0).provider.?);
    try testing.expectEqualStrings(pulse, ready.info(1).type_name);
    try testing.expectEqual(@as(?bool, true), ready.info(0).keyed);
    try testing.expectEqual(@as(?bool, false), ready.info(1).keyed);
    expected[0].expected_identifier.?[1] ^= 1;
    try testing.expectError(error.TypeIdentityMismatch, P.Prepared.init(testing.allocator, &ready.plan, &m, &expected, .{}));
    // Destroying the manager's current providers cannot invalidate the preparation.
    try m.remove("project_a");
    try m.remove("project_b");
    try testing.expectEqualStrings("multi", ready.plan.application.name);
    try testing.expectEqual(@as(usize, 3), m.liveGenerations());
}
test "compiled adapters declare identity and validation capabilities explicitly" {
    var p = try plan(testing.allocator);
    defer p.deinit();
    const Adapter = struct {
        fn install(_: ?*anyopaque, _: dds.DDS.DomainParticipant, _: []const u8) !void {}
    };
    var requested = bindings;
    requested[0].source = .{ .compiled = .{ .binding = .{ .type_name = reading, .register = Adapter.install } } };
    try P.validate(&p, &requested, .{});
    requested[0].require_wire_validation = true;
    try testing.expectError(error.MissingWireValidation, P.validate(&p, &requested, .{}));
    requested[0].require_wire_validation = false;
    var id: P.Identifier = @splat(0);
    id[0] = 0xf1;
    requested[0].expected_identifier = id;
    try testing.expectError(error.MissingTypeIdentity, P.validate(&p, &requested, .{}));
}
test "all preparation allocation failures release provider references" {
    var p = try plan(testing.allocator);
    defer p.deinit();
    var m = try manager(testing.allocator);
    defer m.deinit();
    const Run = struct {
        fn run(alloc: std.mem.Allocator, source: *const R.Plan, providers: *ts.Manager) !void {
            var ready = try P.Prepared.init(alloc, source, providers, &bindings, .{});
            defer ready.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{ &p, &m });
    try testing.expectEqual(@as(usize, 2), m.liveGenerations());
}
test "environment admits explicit linked providers and rolls back failures" {
    const inputs = [_]P.ProviderInput{
        .{ .alias = "project_a", .source = .{ .linked = &a.library } },
        .{ .alias = "project_b", .source = .{ .linked = &a.library } },
    };
    const Run = struct {
        fn run(alloc: std.mem.Allocator, requested: []const P.ProviderInput) !void {
            var env = try P.Environment.init(alloc, requested, .{ .max_providers = 8, .max_artifact_bytes = 1024 * 1024 });
            defer env.deinit();
            try testing.expectEqual(@as(usize, 2), env.artifacts.len);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{@as([]const P.ProviderInput, &inputs)});
    try testing.expectError(error.ProviderAlreadyLoaded, P.Environment.init(testing.allocator, &.{ inputs[0], inputs[0] }, .{ .max_providers = 8, .max_artifact_bytes = 1024 }));
    try testing.expectError(error.ProviderLimit, P.Environment.init(testing.allocator, &inputs, .{ .max_providers = 1 }));
    try testing.expectError(error.GenerationLimitExceeded, P.Environment.init(testing.allocator, &inputs, .{ .max_live_generations = 1 }));
    var no_file_hash = inputs[0];
    no_file_hash.expected_sha256 = @splat(0);
    try testing.expectError(error.NoArtifactHash, P.Environment.init(testing.allocator, &.{no_file_hash}, .{}));
}
test "prepared multi-library types still exchange samples after their manager is destroyed" {
    inline for (.{ R.DataRepresentation.XCDR1, R.DataRepresentation.XCDR2 }) |representation| {
        var p = try planFor(testing.allocator, representation);
        defer p.deinit();
        var ready = blk: {
            var m = try manager(testing.allocator);
            defer m.deinit();
            break :blk try P.Prepared.init(testing.allocator, &p, &m, &bindings, .{});
        };
        defer ready.deinit();
        var delivery = try dds.intraprocess.IntraProcessDelivery.init(testing.allocator);
        defer delivery.deinit();
        const transport = try delivery.newTransport();
        defer transport.deinit();
        const discovery = try delivery.newDiscovery();
        defer discovery.deinit();
        const factory = try dds.dcps.DomainParticipantFactoryImpl.init(testing.allocator, transport.transport(), discovery.toDiscovery(), dds.noop_security.noop_security_plugins, .spec_random, .{});
        defer factory.deinit();
        const peer_transport = try delivery.newTransport();
        defer peer_transport.deinit();
        const peer_discovery = try delivery.newDiscovery();
        defer peer_discovery.deinit();
        const peer_factory = try dds.dcps.DomainParticipantFactoryImpl.init(testing.allocator, peer_transport.transport(), peer_discovery.toDiscovery(), dds.noop_security.noop_security_plugins, .spec_random, .{});
        defer peer_factory.deinit();
        var peer = try ready.incremental(testing.allocator, peer_factory.toDDSFactory(), 10);
        defer peer.deinit() catch @panic("peer cleanup");
        var instance = try ready.instantiate(testing.allocator, factory.toDDSFactory());
        defer instance.deinit() catch @panic("cleanup");
        try ready.build(&instance);
        const peer_dp = try peer.createParticipant("main");
        try testing.expectEqual(@as(usize, 1), peer.count());
        const peer_reading_topic = try peer.createTopic(peer_dp, "reading");
        const peer_sub = try peer.createSubscriber(peer_dp, "sub");
        const peer_reading = try peer.createReader(peer_sub, peer_reading_topic, "reading");
        try testing.expectEqual(@as(usize, 4), peer.count()); // Pulse was not created eagerly.
        const peer_pulse_topic = try peer.createTopic(peer_dp, "pulse");
        const peer_pulse = try peer.createReader(peer_sub, peer_pulse_topic, "pulse");
        var writer_qos: dds.DDS.DataWriterQos = .{};
        try testing.expectEqual(dds.DDS.RETCODE_OK, (try instance.writer("main", "reading")).get_qos(&writer_qos));
        defer writer_qos.deinit(testing.allocator);
        var reader_qos: dds.DDS.DataReaderQos = .{};
        try testing.expectEqual(dds.DDS.RETCODE_OK, (try peer.reader(peer_reading)).get_qos(&reader_qos));
        defer reader_qos.deinit(testing.allocator);
        try testing.expectEqual(representation.ddsValue(), writer_qos.data_representation.value._buffer.?[0]);
        try testing.expectEqual(representation.ddsValue(), reader_qos.data_representation.value._buffer.?[0]);
        const encoding: u8 = if (representation == .XCDR1) 1 else 7;
        const sample = [_]u8{ 0, encoding, 0, 0, 0, 0, 128, 63, 42, 0, 0, 0 };
        try ready.write(&instance, "main", "reading", .alive, &sample);
        try ready.write(&instance, "main", "pulse", .alive, &.{ 0, encoding, 0, 0, 9, 0, 0, 0 });
        const received_reading = try take(try peer.reader(peer_reading));
        defer received_reading.deinit();
        const received_pulse = try take(try peer.reader(peer_pulse));
        defer received_pulse.deinit();
        try testing.expectEqualSlices(u8, &sample, received_reading.data);
        const peer_pub = try peer.createPublisher(peer_dp, "pub");
        const peer_writer = try peer.createWriter(peer_pub, peer_reading_topic, "reading");
        try ready.writeIncremental(&peer, peer_writer, .alive, &sample);
        const reverse_sample = try take(try instance.reader("main", "reading"));
        defer reverse_sample.deinit();
        try testing.expectEqualSlices(u8, &sample, reverse_sample.data);
        try testing.expectError(error.InvalidSample, ready.writeIncremental(&peer, peer_writer, .alive, &.{ 0, 1, 0, 0 }));
        var wrong_encoding = sample;
        wrong_encoding[1] = if (representation == .XCDR1) 7 else 1;
        try testing.expectError(error.UnsupportedRepresentation, ready.write(&instance, "main", "reading", .alive, &wrong_encoding));
        try testing.expectError(error.UnsupportedRepresentation, ready.writeIncremental(&peer, peer_writer, .alive, &wrong_encoding));
        try testing.expectEqualSlices(u8, &.{ 0, encoding, 0, 0, 9, 0, 0, 0 }, received_pulse.data);
        try testing.expectError(error.InvalidSample, ready.write(&instance, "main", "reading", .alive, &.{ 0, 1, 0, 0 }));
    }
}
test "dynamic startup resolves explicit files and checks expected hashes before loading" {
    if (!paths.dynamic_enabled) return error.SkipZigTest;
    const actual_a = try std.fs.path.resolve(testing.allocator, &.{ paths.root, paths.a });
    defer testing.allocator.free(actual_a);
    const actual_b = try std.fs.path.resolve(testing.allocator, &.{ paths.root, paths.b });
    defer testing.allocator.free(actual_b);
    const inputs = [_]P.ProviderInput{
        .{ .alias = "project_a", .source = .{ .library = actual_a } },
        .{ .alias = "project_b", .source = .{ .library = actual_b } },
    };
    var env = try P.Environment.init(testing.allocator, &inputs, .{ .max_providers = 8 });
    defer env.deinit();
    var p = try plan(testing.allocator);
    defer p.deinit();
    var ready = try P.Prepared.init(testing.allocator, &p, &env.manager, &bindings, .{});
    defer ready.deinit();
    try testing.expect(ready.info(0).sha256 != null);
    const conflict_path = try std.fs.path.resolve(testing.allocator, &.{ paths.root, paths.conflict });
    defer testing.allocator.free(conflict_path);
    try env.manager.replace("project_b", conflict_path);
    var next = try P.Prepared.init(testing.allocator, &p, &env.manager, &bindings, .{});
    defer next.deinit();
    try testing.expect(!std.mem.eql(u8, &ready.info(0).minimal_identifier.?, &next.info(0).minimal_identifier.?));
    var original_identity = bindings;
    original_identity[0].expected_identifier = ready.info(0).minimal_identifier;
    try testing.expectError(error.TypeIdentityMismatch, P.Prepared.init(testing.allocator, &p, &env.manager, &original_identity, .{}));

    const bad_path = try std.fs.path.resolve(testing.allocator, &.{ paths.root, paths.bad_abi });
    defer testing.allocator.free(bad_path);
    const bad_input = P.ProviderInput{ .alias = "bad", .source = .{ .library = bad_path } };
    try testing.expectError(error.IncompatibleLibrary, P.Environment.init(testing.allocator, &.{ inputs[0], bad_input }, .{}));
    try testing.expectError(error.ArtifactTooLarge, P.Environment.init(testing.allocator, &inputs, .{ .max_artifact_bytes = 1 }));
    var wrong = inputs;
    wrong[0].expected_sha256 = @splat(0);
    try testing.expectError(error.ArtifactHashMismatch, P.Environment.init(testing.allocator, &wrong, .{ .max_providers = 8 }));
}

test "the same registered name can select distinct generations in different participants" {
    var p = try R.Plan.resolve(testing.allocator, .{ .name = "scopes", .participants = &.{
        .{ .name = "left", .domain_id = 184, .types = &.{.{ .name = reading }} },
        .{ .name = "right", .domain_id = 184, .types = &.{.{ .name = reading }} },
    } }, .{});
    defer p.deinit();
    const requested = [_]P.Binding{
        .{ .participant = "left", .type_name = reading, .source = .{ .provider = .{ .provider = "project_a", .name = reading } } },
        .{ .participant = "right", .type_name = reading, .source = .{ .provider = .{ .provider = "project_b", .name = reading } } },
    };
    var m = try manager(testing.allocator);
    defer m.deinit();
    var ready = try P.Prepared.init(testing.allocator, &p, &m, &requested, .{});
    defer ready.deinit();
    try testing.expect(ready.info(0).generation.? != ready.info(1).generation.?);
    var delivery = try dds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const transport = try delivery.newTransport();
    defer transport.deinit();
    const discovery = try delivery.newDiscovery();
    defer discovery.deinit();
    const factory = try dds.dcps.DomainParticipantFactoryImpl.init(testing.allocator, transport.transport(), discovery.toDiscovery(), dds.noop_security.noop_security_plugins, .spec_random, .{});
    defer factory.deinit();
    var qos: dds.DDS.DomainParticipantFactoryQos = .{};
    qos.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(dds.DDS.RETCODE_OK, factory.toDDSFactory().set_qos(qos));
    var instance = try ready.instantiate(testing.allocator, factory.toDDSFactory());
    defer instance.deinit() catch @panic("cleanup");
    try ready.build(&instance);
}

test "ordinary compiled registration adapters work without provider descriptors" {
    var count: usize = 0;
    const Adapter = struct {
        fn key(_: *anyopaque, _: []const u8) [16]u8 {
            return @splat(0);
        }
        fn install(ctx: ?*anyopaque, dp: dds.DDS.DomainParticipant, name: []const u8) !void {
            const calls: *usize = @ptrCast(@alignCast(ctx.?));
            calls.* += 1;
            if (!dds.registerTypeSupport(dp, name, .{ .ctx = calls, .has_key = false, .compute_key_hash = key })) return error.RegistrationFailed;
        }
    };
    var p = try R.Plan.resolve(testing.allocator, .{ .name = "compiled", .participants = &.{.{
        .name = "main",
        .domain_id = 184,
        .types = &.{.{ .name = pulse }},
        .topics = &.{.{ .name = "pulse", .topic_name = "Pulse", .type_ref = pulse }},
        .publishers = &.{.{ .name = "pub" }},
        .writers = &.{.{ .name = "pulse", .container_ref = "pub", .topic_ref = "pulse" }},
    }} }, .{});
    defer p.deinit();
    var m = try ts.Manager.init(testing.allocator, 1);
    defer m.deinit();
    const requested = [_]P.Binding{.{ .participant = "main", .type_name = pulse, .source = .{ .compiled = .{ .binding = .{ .type_name = pulse, .context = &count, .register = Adapter.install } } } }};
    var ready = try P.Prepared.init(testing.allocator, &p, &m, &requested, .{});
    defer ready.deinit();
    var delivery = try dds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const transport = try delivery.newTransport();
    defer transport.deinit();
    const discovery = try delivery.newDiscovery();
    defer discovery.deinit();
    const factory = try dds.dcps.DomainParticipantFactoryImpl.init(testing.allocator, transport.transport(), discovery.toDiscovery(), dds.noop_security.noop_security_plugins, .spec_random, .{});
    defer factory.deinit();
    var instance = try ready.instantiate(testing.allocator, factory.toDDSFactory());
    defer instance.deinit() catch @panic("cleanup");
    try ready.build(&instance);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expect(!ready.info(0).wire_validation);
    try testing.expectEqual(@as(?u64, null), ready.info(0).generation);
    try testing.expectError(error.CompiledAdapterWriteUnavailable, ready.write(&instance, "main", "pulse", .alive, &.{ 0, 1, 0, 0, 9, 0, 0, 0 }));
}

fn take(dr: dds.DDS.DataReader) !dds.OwnedRawSample {
    const condition = dr.get_statuscondition();
    try testing.expectEqual(dds.DDS.RETCODE_OK, condition.set_enabled_statuses(dds.DDS.DATA_AVAILABLE_STATUS));
    const waitset = try dds.dcps.WaitSetImpl.init(testing.allocator);
    defer waitset.deinit();
    try testing.expectEqual(dds.DDS.RETCODE_OK, waitset.toDDSWaitSet().attach_condition(condition.as_Condition()));
    var active: dds.DDS.ConditionSeq = .{};
    defer if (active._buffer) |buffer| testing.allocator.free(buffer[0..active._maximum]);
    while (true) {
        while (dds.takeRaw(dr)) |sample| {
            if (sample.info.valid_data) return sample;
            sample.deinit();
        }
        try testing.expectEqual(dds.DDS.RETCODE_OK, waitset.toDDSWaitSet().wait(&active, .{ .sec = 5, .nanosec = 0 }));
    }
}

test "static-only startup does not read library files" {
    if (paths.dynamic_enabled) return error.SkipZigTest;
    try testing.expectError(error.DynamicLoadingUnavailable, P.Environment.init(testing.allocator, &.{.{ .alias = "absent", .source = .{ .library = "/no-such-provider" } }}, .{}));
}

test "failed identity and capability requirements never leave generation pins" {
    var p = try plan(testing.allocator);
    defer p.deinit();
    var m = try manager(testing.allocator);
    defer m.deinit();
    var bad = bindings;
    bad[0].required_representations = 8;
    try testing.expectError(error.InvalidCapabilities, P.validate(&p, &bad, .{}));
    try testing.expectError(error.BindingLimit, P.validate(&p, &bindings, .{ .max_bindings = 1 }));
    bad = bindings;
    bad[0].expected_identifier = @splat(0);
    try testing.expectError(error.InvalidIdentifier, P.validate(&p, &bad, .{}));
    bad = bindings;
    bad[0].source.provider.provider = "absent";
    try testing.expectError(error.UnknownProvider, P.Prepared.init(testing.allocator, &p, &m, &bad, .{}));
    if (paths.dynamic_enabled) {
        bad = bindings;
        bad[1].source.provider.provider = "project_b";
        try testing.expectError(error.UnknownType, P.Prepared.init(testing.allocator, &p, &m, &bad, .{}));
    }
    const Noop = struct {
        fn install(_: ?*anyopaque, _: dds.DDS.DomainParticipant, _: []const u8) !void {}
    };
    bad = bindings;
    bad[0].source = .{ .compiled = .{ .binding = .{ .type_name = reading, .register = Noop.install }, .representations = 2 } };
    try testing.expectError(error.UnsupportedRepresentation, P.validate(&p, &bad, .{}));
    try testing.expectEqual(@as(usize, 2), m.liveGenerations());
}

test "selected endpoint representations determine compiled provider requirements" {
    var p = try planFor(testing.allocator, .XCDR2);
    defer p.deinit();
    const Noop = struct {
        fn install(_: ?*anyopaque, _: dds.DDS.DomainParticipant, _: []const u8) !void {}
    };
    var b = bindings;
    for (&b) |*binding| binding.source = .{ .compiled = .{ .binding = .{ .type_name = binding.type_name, .register = Noop.install }, .representations = 2 } };
    try P.validate(&p, &b, .{}); // XCDR2-only support is sufficient.
    b[0].source.compiled.representations = 1;
    try testing.expectError(error.UnsupportedRepresentation, P.validate(&p, &b, .{}));
    b[0].source.compiled.representations = 2;
    b[0].required_representations = 1; // Explicit extra requirements still apply.
    try testing.expectError(error.UnsupportedRepresentation, P.validate(&p, &b, .{}));
    b[0].required_representations = 0;
    // Mixed writer/reader representations require both capabilities for the type.
    @constCast(p.application.participants[0].readers)[0].qos.data_representation = .XCDR1;
    try testing.expectError(error.UnsupportedRepresentation, P.validate(&p, &b, .{}));
    b[0].source.compiled.representations = 3;
    try P.validate(&p, &b, .{});
}
