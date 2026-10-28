//! Strict authored resource records -> concrete shared builder plans.
const std = @import("std");
const rt = @import("zidl_rt");
comptime {
    if (!@hasDecl(rt, "authoring")) @compileError("resource authoring requires zidl v0.3.23 or newer");
}
const generic = rt.authoring;
const schema = @import("resource_authoring_generated");
const toml = @import("../config/toml.zig");
const R = @import("root.zig");
pub const Diagnostic = struct {
    phase: enum { syntax, decode, resolve } = .syntax,
    detail: generic.Diagnostic = .{},
};
pub const Origin = struct {
    participant: []const u8,
    endpoint: []const u8,
    reader: bool,
    field: []const u8,
    source_file: []const u8,
    location: ?generic.Location,
    profile: ?[]const u8,
};
pub const Resolved = struct {
    arena: std.heap.ArenaAllocator,
    plan: R.Plan,
    origins: []const Origin,
    source_name: []const u8,
    skipped: []const generic.Skipped,
    pub fn deinit(self: *@This()) void {
        self.plan.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const Parsed = struct {
    decoded: generic.Decoded(schema.ResourceDocument),
    source_name: []const u8,
    pub fn deinit(self: *@This()) void {
        self.decoded.deinit();
        self.* = undefined;
    }
    pub fn resolve(self: *const @This(), alloc: std.mem.Allocator, limits: R.Limits, diag: *Diagnostic) !Resolved {
        diag.* = .{ .phase = .resolve };
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        var ctx = Resolver{ .a = arena.allocator(), .parsed = self, .diag = diag, .limits = limits };
        const doc = self.decoded.value;
        if (doc.schema_version != 1) return ctx.fail(error.UnsupportedSchema, &.{"schema_version"});
        const profiles = elements(doc.profiles);
        var count: usize = 1;
        count = std.math.add(usize, count, profiles.len) catch return ctx.fail(error.ResourceLimit, &.{});
        for (elements(doc.participants)) |p| {
            count = std.math.add(usize, count, 1) catch return ctx.fail(error.ResourceLimit, &.{});
            inline for (.{ "types", "topics", "publishers", "subscribers", "writers", "readers" }) |field| {
                count = std.math.add(usize, count, elements(@field(p, field)).len) catch return ctx.fail(error.ResourceLimit, &.{});
            }
        }
        if (count > limits.max_resources) return ctx.fail(error.ResourceLimit, &.{});

        if (profiles.len > limits.max_resources) return ctx.fail(error.ResourceLimit, &.{"profiles"});
        ctx.visited = try ctx.a.alloc(u8, profiles.len);
        ctx.heights = try ctx.a.alloc(usize, profiles.len);
        @memset(ctx.visited, 0);
        for (profiles, 0..) |p, i| {
            if (p.name.len == 0 or p.name.len > limits.max_name_bytes or std.mem.indexOfScalar(u8, p.name, 0) != null) return ctx.fail(error.InvalidName, &.{"profiles"});
            for (profiles[0..i]) |previous| if (std.mem.eql(u8, previous.name, p.name)) return ctx.fail(error.DuplicateName, &.{"profiles"});
            try ctx.visit(i, 0);
        }
        const participants = try ctx.a.alloc(R.Participant, elements(doc.participants).len);
        if (participants.len > limits.max_resources) return ctx.fail(error.ResourceLimit, &.{"participants"});
        for (elements(doc.participants), participants, 0..) |p, *out, i| {
            const key = try ctx.segment(&.{"participants"}, p.name, i);
            const prefix = &[_][]const u8{ "participants", key };
            const domain = p.domain_id orelse return ctx.fail(error.MissingDomain, prefix);
            const types = try ctx.a.alloc(R.Type, elements(p.types).len);
            for (elements(p.types), types) |t, *dest| dest.* = .{ .name = t.name };
            const topics = try ctx.a.alloc(R.Topic, elements(p.topics).len);
            for (elements(p.topics), topics, 0..) |t, *dest, n| {
                if (!hasName(types, t.type_ref)) {
                    const tk = try ctx.segment(&.{ "participants", key, "topics" }, t.name, n);
                    return ctx.fail(error.UnknownReference, &.{ "participants", key, "topics", tk, "type_ref" });
                }
                dest.* = .{ .name = t.name, .topic_name = t.topic_name, .type_ref = t.type_ref };
            }
            const pubs = try ctx.a.alloc(R.Container, elements(p.publishers).len);
            for (elements(p.publishers), pubs) |c, *dest| dest.* = .{ .name = c.name };
            const subs = try ctx.a.alloc(R.Container, elements(p.subscribers).len);
            for (elements(p.subscribers), subs) |c, *dest| dest.* = .{ .name = c.name };
            out.* = .{
                .name = p.name,
                .domain_id = domain,
                .types = types,
                .topics = topics,
                .publishers = pubs,
                .subscribers = subs,
                .writers = try ctx.endpoints(key, p.name, elements(p.writers), pubs, topics, false),
                .readers = try ctx.endpoints(key, p.name, elements(p.readers), subs, topics, true),
            };
        }
        const origins = try ctx.origins.toOwnedSlice(ctx.a);
        const source_name = try ctx.a.dupe(u8, self.source_name);
        const skipped = try ctx.a.dupe(generic.Skipped, self.decoded.skipped);
        for (skipped) |*item| {
            item.path = try copyPath(ctx.a, item.path);
            item.input_path = try copyPath(ctx.a, item.input_path);
        }
        // Plan deep-copies the concrete graph. Parsed records can be freed next.
        const plan = R.Plan.resolve(alloc, .{ .name = doc.name, .participants = participants }, .{ .max_resources = limits.max_resources - profiles.len, .max_name_bytes = limits.max_name_bytes }) catch |err| return ctx.fail(err, &.{});
        return .{ .arena = arena, .plan = plan, .origins = origins, .source_name = source_name, .skipped = skipped };
    }
};
pub fn parse(alloc: std.mem.Allocator, source_name: []const u8, bytes: []const u8, diag: *Diagnostic) !Parsed {
    diag.* = .{};
    var syntax_diag: toml.Diagnostic = .{};
    var document = toml.parseOwned(alloc, bytes, &syntax_diag, .{}) catch |err| {
        diag.detail.code = err;
        diag.detail.location = .{ .offset = syntax_diag.location.offset, .line = syntax_diag.location.line, .column = syntax_diag.location.column };
        return err;
    };
    defer document.deinit();
    diag.phase = .decode;
    var decoded = try schema.ResourceDocument.decodeToml(alloc, document.table, .{ .named_field = "name", .conditional_members = true }, &diag.detail);
    errdefer decoded.deinit();
    const name = try decoded.arena.allocator().dupe(u8, source_name);
    return .{ .decoded = decoded, .source_name = name };
}
fn copyPath(alloc: std.mem.Allocator, path: []const []const u8) ![]const []const u8 {
    const result = try alloc.alloc([]const u8, path.len);
    for (path, result) |part, *out| out.* = try alloc.dupe(u8, part);
    return result;
}
fn elements(seq: anytype) []const rt.SeqElem(@TypeOf(seq)) {
    return if (seq._buffer) |buf| buf[0..seq._length] else &.{};
}
fn hasName(items: anytype, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}
const fields = [_][]const u8{ "reliability", "history_depth", "max_samples", "max_instances", "max_samples_per_instance" };
const Winner = struct { location: ?generic.Location = null, profile: ?[]const u8 = null };
const Resolver = struct {
    a: std.mem.Allocator,
    parsed: *const Parsed,
    diag: *Diagnostic,
    limits: R.Limits,
    visited: []u8 = &.{},
    heights: []usize = &.{},
    origins: std.ArrayList(Origin) = .empty,
    fn fail(ctx: *@This(), err: anyerror, path: []const []const u8) anyerror {
        ctx.diag.detail.code = err;
        ctx.diag.detail.path_len = 0;
        var n = path.len;
        while (true) {
            if (ctx.parsed.decoded.source(path[0..n])) |loc| {
                ctx.diag.detail.location = loc;
                break;
            }
            if (n == 0) break;
            n -= 1;
        }
        for (path, 0..) |part, i| {
            if (i != 0) ctx.appendDiagnostic(".");
            ctx.appendDiagnostic(part);
        }
        return err;
    }
    fn appendDiagnostic(ctx: *@This(), text: []const u8) void {
        const d = &ctx.diag.detail;
        const n = @min(text.len, d.path.len - d.path_len);
        @memcpy(d.path[d.path_len..][0..n], text[0..n]);
        d.path_len += n;
        if (n != text.len) d.path_truncated = true;
    }
    fn segment(ctx: *@This(), prefix: []const []const u8, name: []const u8, i: usize) ![]const u8 {
        return if (ctx.parsed.decoded.collectionIsNamed(prefix)) name else try std.fmt.allocPrint(ctx.a, "{d}", .{i});
    }
    fn profileIndex(ctx: *@This(), name: []const u8) ?usize {
        for (elements(ctx.parsed.decoded.value.profiles), 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
        return null;
    }
    fn visit(ctx: *@This(), i: usize, depth: usize) anyerror!void {
        const p = elements(ctx.parsed.decoded.value.profiles)[i];
        const key = try ctx.segment(&.{"profiles"}, p.name, i);
        if (depth >= 64) return ctx.fail(error.ResourceLimit, &.{ "profiles", key, "base" });
        if (ctx.visited[i] == 1) return ctx.fail(error.ProfileCycle, &.{ "profiles", key, "base" });
        if (ctx.visited[i] == 2) return;
        ctx.visited[i] = 1;
        if (p.base) |base| {
            const parent = ctx.profileIndex(base) orelse return ctx.fail(error.UnknownProfile, &.{ "profiles", key, "base" });
            try ctx.visit(parent, depth + 1);
            ctx.heights[i] = ctx.heights[parent] + 1;
        } else ctx.heights[i] = 1;
        if (ctx.heights[i] > 64) return ctx.fail(error.ResourceLimit, &.{ "profiles", key, "base" });
        ctx.visited[i] = 2;
    }
    fn overlay(ctx: *@This(), value: schema.ResourceQos, prefix: []const []const u8, profile: ?[]const u8, qos: *R.EndpointQos, winners: *[fields.len]Winner) !void {
        inline for (fields, 0..) |field, i| if (@field(value, field)) |v| {
            if (comptime std.mem.eql(u8, field, "reliability")) {
                qos.reliability = switch (v) {
                    .BEST_EFFORT_RELIABILITY_QOS => .BEST_EFFORT_RELIABILITY_QOS,
                    .RELIABLE_RELIABILITY_QOS => .RELIABLE_RELIABILITY_QOS,
                    else => return ctx.fail(error.InvalidEnum, prefix),
                };
            } else @field(qos, field) = v;
            const path = try ctx.a.alloc([]const u8, prefix.len + 1);
            @memcpy(path[0..prefix.len], prefix);
            path[prefix.len] = field;
            winners[i] = .{ .profile = profile, .location = ctx.parsed.decoded.source(path) };
        };
    }
    fn applyProfile(ctx: *@This(), i: usize, reader: bool, qos: *R.EndpointQos, winners: *[fields.len]Winner) anyerror!void {
        const p = elements(ctx.parsed.decoded.value.profiles)[i];
        if (p.base) |base| try ctx.applyProfile(ctx.profileIndex(base).?, reader, qos, winners);
        const key = try ctx.segment(&.{"profiles"}, p.name, i);
        try ctx.overlay(if (reader) p.reader_qos else p.writer_qos, &.{ "profiles", key, if (reader) "reader_qos" else "writer_qos" }, p.name, qos, winners);
    }
    fn endpoints(ctx: *@This(), pk: []const u8, participant: []const u8, authored: []const schema.ResourceEndpoint, containers: []const R.Container, topics: []const R.Topic, reader: bool) ![]R.Endpoint {
        const result = try ctx.a.alloc(R.Endpoint, authored.len);
        const kind = if (reader) "readers" else "writers";
        for (authored, result, 0..) |e, *out, i| {
            const key = try ctx.segment(&.{ "participants", pk, kind }, e.name, i);
            if (!hasName(containers, e.container_ref)) return ctx.fail(error.UnknownReference, &.{ "participants", pk, kind, key, "container_ref" });
            if (!hasName(topics, e.topic_ref)) return ctx.fail(error.UnknownReference, &.{ "participants", pk, kind, key, "topic_ref" });
            var qos: R.EndpointQos = .{}; // Defaults used only after absent overlays.
            var winners: [fields.len]Winner = @splat(.{});
            if (e.profile_ref) |ref| {
                const idx = ctx.profileIndex(ref) orelse return ctx.fail(error.UnknownProfile, &.{ "participants", pk, kind, key, "profile_ref" });
                try ctx.applyProfile(idx, reader, &qos, &winners);
            }
            try ctx.overlay(e.qos, &.{ "participants", pk, kind, key, "qos" }, null, &qos, &winners);
            if (qos.invalidField()) |field| {
                const failure = ctx.fail(error.InvalidQos, &.{ "participants", pk, kind, key, "qos", field });
                for (fields, winners) |f, winner| if (std.mem.eql(u8, f, field)) {
                    if (winner.location) |loc| ctx.diag.detail.location = loc;
                };
                return failure;
            }
            out.* = .{ .name = e.name, .container_ref = e.container_ref, .topic_ref = e.topic_ref, .qos = qos };
            for (fields, winners) |field, winner| try ctx.origins.append(ctx.a, .{
                .participant = try ctx.a.dupe(u8, participant),
                .endpoint = try ctx.a.dupe(u8, e.name),
                .reader = reader,
                .field = field,
                .source_file = try ctx.a.dupe(u8, ctx.parsed.source_name),
                .location = winner.location,
                .profile = if (winner.profile) |p| try ctx.a.dupe(u8, p) else null,
            });
        }
        return result;
    }
};
