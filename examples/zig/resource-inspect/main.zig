//! Explicit command-line provider bindings, kept outside portable resource TOML.
const std = @import("std");
const builtin = @import("builtin");
const dds = @import("zzdds");
const P = dds.resources.providers;
const Constraint = struct { name: []const u8, value: []const u8 };
fn pair(text: []const u8, separator: u8) !Constraint {
    const i = std.mem.indexOfScalar(u8, text, separator) orelse return error.ExpectedBindingPair;
    if (i == 0 or i + 1 == text.len) return error.EmptyBindingName;
    return .{ .name = text[0..i], .value = text[i + 1 ..] };
}
fn hex(comptime n: usize, text: []const u8) ![n]u8 {
    if (text.len != 2 * n) return error.InvalidHexLength;
    var value: [n]u8 = undefined;
    _ = try std.fmt.hexToBytes(&value, text);
    return value;
}
pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, a);
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse return error.ExpectedValidatePlanOrInspect;
    if (!std.mem.eql(u8, mode, "validate") and !std.mem.eql(u8, mode, "plan") and !std.mem.eql(u8, mode, "inspect")) return error.ExpectedValidatePlanOrInspect;
    const filename = args.next() orelse return error.ExpectedResourceFile;
    var inputs: std.ArrayList(P.ProviderInput) = .empty;
    var bindings: std.ArrayList(P.Binding) = .empty;
    var identifiers: std.ArrayList(Constraint) = .empty;
    var hashes: std.ArrayList(Constraint) = .empty;
    while (args.next()) |option| {
        const value = args.next() orelse return error.ExpectedOptionValue;
        const parts = try pair(value, '=');
        if (std.mem.eql(u8, option, "--library")) {
            try inputs.append(a, .{ .alias = parts.name, .source = .{ .library = parts.value } });
        } else if (std.mem.eql(u8, option, "--bind")) {
            const scope = try pair(parts.name, '/');
            const source = try pair(parts.value, '/');
            try bindings.append(a, .{ .participant = scope.name, .type_name = scope.value, .source = .{ .provider = .{ .provider = source.name, .name = source.value } } });
        } else if (std.mem.eql(u8, option, "--expect")) {
            for (identifiers.items) |prior| if (std.mem.eql(u8, prior.name, parts.name)) return error.DuplicateConstraint;
            try identifiers.append(a, parts);
        } else if (std.mem.eql(u8, option, "--sha256")) {
            for (hashes.items) |prior| if (std.mem.eql(u8, prior.name, parts.name)) return error.DuplicateConstraint;
            try hashes.append(a, parts);
        } else return error.UnknownOption;
    }
    for (identifiers.items) |constraint| {
        const scope = try pair(constraint.name, '/');
        var found = false;
        for (bindings.items) |*binding| if (std.mem.eql(u8, binding.participant, scope.name) and std.mem.eql(u8, binding.type_name, scope.value)) {
            binding.expected_identifier = try hex(15, constraint.value);
            found = true;
        };
        if (!found) return error.UnknownBindingConstraint;
    }
    for (hashes.items) |constraint| {
        var found = false;
        for (inputs.items) |*input| if (std.mem.eql(u8, input.alias, constraint.name)) {
            input.expected_sha256 = try hex(32, constraint.value);
            found = true;
        };
        if (!found) return error.UnknownProviderConstraint;
    }
    const io = init.io;
    const source = try std.Io.Dir.cwd().readFileAlloc(io, filename, a, .limited(256 * 1024));
    var diagnostic: dds.resources.authoring.Diagnostic = .{};
    var parsed = dds.resources.authoring.parse(init.gpa, filename, source, &diagnostic) catch |err| {
        std.debug.print("{s}:{d}:{d}: {s} {s}\n", .{ filename, diagnostic.detail.location.line, diagnostic.detail.location.column, @errorName(err), diagnostic.detail.fieldPath() });
        return err;
    };
    defer parsed.deinit();
    var resolved = parsed.resolve(init.gpa, .{}, &diagnostic) catch |err| {
        std.debug.print("{s}:{d}:{d}: {s} {s}\n", .{ filename, diagnostic.detail.location.line, diagnostic.detail.location.column, @errorName(err), diagnostic.detail.fieldPath() });
        return err;
    };
    defer resolved.deinit();
    try P.validate(&resolved.plan, bindings.items, .{});
    // Offline commands verify explicit aliases without inspecting any file/library.
    const load_limits: P.LoadOptions = .{};
    if (inputs.items.len > load_limits.max_providers) return error.ProviderLimit;
    for (inputs.items, 0..) |input, i| for (inputs.items[0..i]) |prior| {
        if (std.mem.eql(u8, input.alias, prior.alias)) return error.ProviderAlreadyLoaded;
    };
    for (bindings.items) |binding| {
        var found = false;
        for (inputs.items) |input| if (std.mem.eql(u8, input.alias, binding.source.provider.provider)) {
            found = true;
        };
        if (!found) return error.UnknownProvider;
    }
    std.debug.print("plan {s}: {d} participant(s), {d} explicit type binding(s), {d} skipped setting(s)\n", .{ resolved.plan.application.name, resolved.plan.application.participants.len, bindings.items.len, resolved.skipped.len });
    if (!std.mem.eql(u8, mode, "validate")) for (resolved.plan.application.participants) |participant| {
        std.debug.print("participant {s} domain={d} topics={d} writers={d} readers={d}\n", .{ participant.name, participant.domain_id, participant.topics.len, participant.writers.len, participant.readers.len });
        for (participant.writers) |endpoint| std.debug.print("  writer {s} topic={s} reliability={s} depth={d} max_samples={d} max_instances={d} max_samples_per_instance={d}\n", .{ endpoint.name, endpoint.topic_ref, @tagName(endpoint.qos.reliability), endpoint.qos.history_depth, endpoint.qos.max_samples, endpoint.qos.max_instances, endpoint.qos.max_samples_per_instance });
        for (participant.readers) |endpoint| std.debug.print("  reader {s} topic={s} reliability={s} depth={d} max_samples={d} max_instances={d} max_samples_per_instance={d}\n", .{ endpoint.name, endpoint.topic_ref, @tagName(endpoint.qos.reliability), endpoint.qos.history_depth, endpoint.qos.max_samples, endpoint.qos.max_instances, endpoint.qos.max_samples_per_instance });
    };
    if (!std.mem.eql(u8, mode, "inspect")) {
        std.debug.print("offline validation passed; provider code was not loaded; export identity/capabilities remain unchecked\n", .{});
        return;
    }
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", a);
    var environment = try P.Environment.init(init.gpa, inputs.items, .{ .base_directory = cwd });
    defer environment.deinit();
    var ready = try P.Prepared.init(init.gpa, &resolved.plan, &environment.manager, bindings.items, .{});
    defer ready.deinit();
    std.debug.print("prepared for {s}/{s}, typesupport ABI={x}; no DDS entities created\n", .{ @tagName(builtin.cpu.arch), @tagName(builtin.os.tag), dds.typesupport.wire.abi_major });
    for (0..ready.bindings.len) |i| {
        const info = ready.info(i);
        std.debug.print("type {s}/{s} provider={s} generation={d} representations={d} keyed={} minimal={s}\n", .{ info.participant, info.type_name, info.provider.?, info.generation.?, info.representations, info.keyed.?, std.fmt.bytesToHex(info.minimal_identifier.?, .lower) });
        std.debug.print("  artifact {s} sha256={s}\n", .{ info.artifact.?, std.fmt.bytesToHex(info.sha256.?, .lower) });
    }
}
