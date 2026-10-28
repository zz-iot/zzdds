const std = @import("std");
const zzdds = @import("zzdds");
const R = zzdds.resources;
const A = R.authoring;
const testing = std.testing;
const writer =
    \\schema_version = 1
    \\name = 'Writer'
    \\[profiles.Base.writer_qos]
    \\reliability = 'RELIABLE_RELIABILITY_QOS'
    \\history_depth = 4
    \\[profiles.Derived]
    \\base = 'Base'
    \\[profiles.Derived.writer_qos]
    \\history_depth = 2
    \\[participants.main]
    \\domain_id = 42
    \\types = { Probe = {} }
    \\topics = { Announcement = { topic_name = 'Announcement', type_ref = 'Probe' } }
    \\publishers = { pub = {} }
    \\[participants.main.writers.endpoint]
    \\container_ref = 'pub'
    \\topic_ref = 'Announcement'
    \\profile_ref = 'Derived'
    \\[participants.main.writers.endpoint.qos]
    \\history_depth = 1
;
test "strict generated records preserve presence and resolve profile order" {
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "writer.toml", writer, &diag);
    defer parsed.deinit();
    try testing.expect(parsed.decoded.isPresent(&.{ "profiles", "Base", "writer_qos", "history_depth" }));
    try testing.expect(!parsed.decoded.isPresent(&.{ "profiles", "Base", "writer_qos", "max_samples" }));
    var resolved = try parsed.resolve(testing.allocator, .{}, &diag);
    defer resolved.deinit();
    const p = resolved.plan.application.participants[0];
    try testing.expectEqualStrings("main", p.name);
    try testing.expectEqual(zzdds.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS, p.writers[0].qos.reliability);
    try testing.expectEqual(@as(i32, 1), p.writers[0].qos.history_depth);
    try testing.expectEqual(@as(i32, 32), p.writers[0].qos.max_samples);
    try testing.expectEqualStrings("Base", resolved.origins[0].profile.?);
    try testing.expect(resolved.origins[1].profile == null);
    try testing.expectEqualStrings("writer.toml", resolved.origins[0].source_file);
}
const reader =
    \\schema_version = 1
    \\name = 'Reader'
    \\participants = [{ name = 'main', domain_id = 42, types = [{ name = 'Probe' }], topics = [{ name = 'Announcement', topic_name = 'Announcement', type_ref = 'Probe' }], subscribers = [{ name = 'sub' }], readers = [{ name = 'endpoint', container_ref = 'sub', topic_ref = 'Announcement' }] }]
;

test "record arrays produce the identical concrete programmatic reader plan" {
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "reader.toml", reader, &diag);
    var resolved = try parsed.resolve(testing.allocator, .{}, &diag);
    defer resolved.deinit();
    parsed.deinit(); // Plans and provenance do not borrow decoded storage.
    var expected = try R.Plan.resolve(testing.allocator, .{ .name = "Reader", .participants = &.{.{
        .name = "main",
        .domain_id = 42,
        .types = &.{.{ .name = "Probe" }},
        .topics = &.{.{ .name = "Announcement", .topic_name = "Announcement", .type_ref = "Probe" }},
        .subscribers = &.{.{ .name = "sub" }},
        .readers = &.{.{ .name = "endpoint", .container_ref = "sub", .topic_ref = "Announcement" }},
    }} }, .{});
    defer expected.deinit();
    try testing.expectEqualDeep(expected.application, resolved.plan.application);
    for (resolved.origins) |origin| {
        try testing.expect(origin.location == null); // Defaulted QoS has no authored origin.
        try testing.expectEqualStrings("reader.toml", origin.source_file);
    }
}

test "strict typo diagnostic identifies its full authored path and location" {
    const input = writer ++ "\nhistory_dept = 2\n";
    var diag: A.Diagnostic = .{};
    try testing.expectError(error.UnknownField, A.parse(testing.allocator, "typo.toml", input, &diag));
    try testing.expectEqualStrings("participants.main.writers.endpoint.qos.history_dept", diag.detail.fieldPath());
    try testing.expectEqual(@as(usize, 21), diag.detail.location.line);
}

fn resolveError(input: []const u8, expected: anyerror) !void {
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "bad.toml", input, &diag);
    defer parsed.deinit();
    try testing.expectError(expected, parsed.resolve(testing.allocator, .{}, &diag));
    try testing.expect(diag.detail.code != null);
}

test "explicit zero is not mistaken for an absent inherited value" {
    const input = try std.mem.replaceOwned(u8, testing.allocator, writer, "history_depth = 1", "history_depth = 0");
    defer testing.allocator.free(input);
    try resolveError(input, error.InvalidQos);
}

test "profile references and cycles are validated even for unused profiles" {
    try resolveError("schema_version=1\nname='bad'\n[profiles.a]\nbase='b'\n[profiles.b]\nbase='a'", error.ProfileCycle);
    try resolveError("schema_version=1\nname='bad'\n[profiles.a]\nbase='missing'", error.UnknownProfile);
    const input = try std.mem.replaceOwned(u8, testing.allocator, writer, "profile_ref = 'Derived'", "profile_ref = 'missing'");
    defer testing.allocator.free(input);
    try resolveError(input, error.UnknownProfile);
}

test "unknown resource references report their source field" {
    const input = try std.mem.replaceOwned(u8, testing.allocator, writer, "topic_ref = 'Announcement'", "topic_ref = 'Missing'");
    defer testing.allocator.free(input);
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "ref.toml", input, &diag);
    defer parsed.deinit();
    try testing.expectError(error.UnknownReference, parsed.resolve(testing.allocator, .{}, &diag));
    try testing.expectEqualStrings("participants.main.writers.endpoint.topic_ref", diag.detail.fieldPath());
}

test "authored graph enforces schema, domain and resource admission" {
    try resolveError("schema_version=2\nname='bad'", error.UnsupportedSchema);
    try resolveError("schema_version=1\nname='bad'\n[participants.main]", error.MissingDomain);
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "writer.toml", writer, &diag);
    defer parsed.deinit();
    try testing.expectError(error.ResourceLimit, parsed.resolve(testing.allocator, .{ .max_resources = 2 }, &diag));
}

test "authored and resolved owners release every partial allocation" {
    const Run = struct {
        fn run(alloc: std.mem.Allocator) !void {
            var diag: A.Diagnostic = .{};
            var parsed = try A.parse(alloc, "writer.toml", writer, &diag);
            defer parsed.deinit();
            var result = try parsed.resolve(alloc, .{}, &diag);
            defer result.deinit();
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Run.run, .{});
}

const Side = struct {
    t: *zzdds.intraprocess.MemoryTransport,
    d: *zzdds.intraprocess.DirectDiscovery,
    f: *zzdds.dcps.DomainParticipantFactoryImpl,
    fn init(delivery: *zzdds.intraprocess.IntraProcessDelivery) !@This() {
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        const f = try zzdds.dcps.DomainParticipantFactoryImpl.init(testing.allocator, t.transport(), d.toDiscovery(), zzdds.noop_security.noop_security_plugins, .spec_random, .{});
        return .{ .t = t, .d = d, .f = f };
    }
    fn deinit(s: @This()) void {
        s.f.deinit();
        s.d.deinit();
        s.t.deinit();
    }
};
const probe = @import("resource_probe");
fn install(_: ?*anyopaque, dp: zzdds.DDS.DomainParticipant, name: []const u8) !void {
    if (!zzdds.registerTypeSupport(dp, name, .{ .ctx = @constCast(&testing.allocator), .compute_key_hash = probe.Probe.computeKeyHashFromCdr, .has_key = probe.Probe.has_key })) return error.RegistrationFailed;
}
test "TOML writer and reader construct real graphs and exchange generated samples" {
    var diag: A.Diagnostic = .{};
    var wp = try A.parse(testing.allocator, "writer.toml", writer ++ "\nreliability='BEST_EFFORT_RELIABILITY_QOS'\n", &diag);
    defer wp.deinit();
    var rp = try A.parse(testing.allocator, "reader.toml", reader, &diag);
    defer rp.deinit();
    var wr = try wp.resolve(testing.allocator, .{}, &diag);
    defer wr.deinit();
    var rr = try rp.resolve(testing.allocator, .{}, &diag);
    defer rr.deinit();
    var delivery = try zzdds.intraprocess.IntraProcessDelivery.init(testing.allocator);
    defer delivery.deinit();
    const a = try Side.init(&delivery);
    defer a.deinit();
    const b = try Side.init(&delivery);
    defer b.deinit();
    var wi = try R.Instance.init(testing.allocator, &wr.plan, a.f.toDDSFactory());
    defer wi.deinit() catch @panic("writer cleanup");
    var ri = try R.Instance.init(testing.allocator, &rr.plan, b.f.toDDSFactory());
    defer ri.deinit() catch @panic("reader cleanup");
    const bindings = [_]R.StaticBinding{.{ .type_name = "Probe", .register = install }};
    try ri.build(&bindings);
    try wi.build(&bindings);
    const writer_handle = try wi.writer("main", "endpoint");
    try probe.ProbeDataWriter.init(writer_handle, testing.allocator).write(.{ .value = 123 }, 0);
    const sample = try takeSample(try ri.reader("main", "endpoint"));
    defer sample.deinit();
    var cdr = try zzdds.zidl_rt.CdrReader.init(sample.data);
    var value: probe.Probe = .{};
    try probe.Probe.deserializeInto(&value, &cdr, testing.allocator);
    try testing.expectEqual(@as(u32, 123), value.value);
}

test "array record names that look like indexes retain their actual source path" {
    const input = "schema_version=1\nname='numeric'\nparticipants=[{name='1'},{name='0',domain_id=42}]";
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "numeric.toml", input, &diag);
    defer parsed.deinit();
    try testing.expectError(error.MissingDomain, parsed.resolve(testing.allocator, .{}, &diag));
    try testing.expectEqualStrings("participants.0", diag.detail.fieldPath());
}

test "cached profile ancestors cannot bypass the chain depth limit" {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(testing.allocator);
    try text.appendSlice(testing.allocator, "schema_version=1\nname='deep'\n[profiles.p0]\n");
    for (1..66) |i| {
        const line = try std.fmt.allocPrint(testing.allocator, "[profiles.p{d}]\nbase='p{d}'\n", .{ i, i - 1 });
        defer testing.allocator.free(line);
        try text.appendSlice(testing.allocator, line);
    }
    try resolveError(text.items, error.ResourceLimit);
}

test "reader profile resolution uses its reader policy block" {
    const selected = try std.mem.replaceOwned(u8, testing.allocator, reader, "topic_ref = 'Announcement'", "topic_ref = 'Announcement', profile_ref = 'Both'");
    defer testing.allocator.free(selected);
    const input = try std.mem.concat(testing.allocator, u8, &.{
        selected,
        "\nprofiles=[{name='Both',writer_qos={history_depth=8},reader_qos={history_depth=2}}]\n",
    });
    defer testing.allocator.free(input);
    var diag: A.Diagnostic = .{};
    var parsed = try A.parse(testing.allocator, "reader-profile.toml", input, &diag);
    defer parsed.deinit();
    var resolved = try parsed.resolve(testing.allocator, .{}, &diag);
    defer resolved.deinit();
    try testing.expectEqual(@as(i32, 2), resolved.plan.application.participants[0].readers[0].qos.history_depth);
    try testing.expect(resolved.origins[1].reader);
    try testing.expectEqualStrings("Both", resolved.origins[1].profile.?);
}

test "conditional members retain named identities and owned skip reports" {
    var diag: A.Diagnostic = .{};
    const input =
        \\schema_version = 1
        \\name = 'Conditional'
        \\_future = { enabled = true }
        \\[participants._Telemetry]
        \\_domain_id = 42
    ;
    var resolved = blk: {
        var parsed = try A.parse(testing.allocator, "conditional.toml", input, &diag);
        defer parsed.deinit();
        break :blk try parsed.resolve(testing.allocator, .{}, &diag);
    };
    defer resolved.deinit();
    try testing.expectEqualStrings("_Telemetry", resolved.plan.application.participants[0].name);
    try testing.expectEqual(@as(i32, 42), resolved.plan.application.participants[0].domain_id);
    try testing.expectEqualStrings("conditional.toml", resolved.source_name);
    try testing.expectEqual(@as(usize, 1), resolved.skipped.len);
    try testing.expectEqualStrings("future", resolved.skipped[0].path[0]);
    try testing.expectEqualStrings("_future", resolved.skipped[0].input_path[0]);
}

// Shared-runtime delivery may complete after write returns. Wait on the public
// data-available condition rather than assuming synchronous sample delivery.
fn takeSample(dr: zzdds.DDS.DataReader) !zzdds.OwnedRawSample {
    const status = dr.get_statuscondition();
    try testing.expectEqual(zzdds.DDS.RETCODE_OK, status.set_enabled_statuses(zzdds.DDS.DATA_AVAILABLE_STATUS));
    const ws = try zzdds.dcps.WaitSetImpl.init(testing.allocator);
    defer ws.deinit();
    try testing.expectEqual(zzdds.DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(status.as_Condition()));
    var active: zzdds.DDS.ConditionSeq = .{};
    defer if (active._buffer) |buffer| testing.allocator.free(buffer[0..active._maximum]);
    while (true) {
        while (zzdds.takeRaw(dr)) |sample| {
            if (sample.info.valid_data) return sample;
            // Deleting the first writer may enqueue lifecycle-only samples.
            sample.deinit();
        }
        try testing.expectEqual(zzdds.DDS.RETCODE_OK, ws.toDDSWaitSet().wait(&active, .{ .sec = 5, .nanosec = 0 }));
    }
}
