//! Local type bindings. Preparation pins immutable selections without creating DDS
//! entities. Prepared owns its plan; instances borrow it through successful deinit.
const std = @import("std");
const builtin = @import("builtin");
const R = @import("root.zig");
const ts = @import("../typesupport.zig");
const ts_write_kind = @import("../raw_ops.zig").WriteKind;
const DDS = @import("zzdds_generated").DDS;
pub const Identifier = [15]u8; // EK_MINIMAL and its 14-byte equivalence hash.
pub const Static = struct {
    binding: R.StaticBinding,
    minimal_identifier: ?Identifier = null,
    representations: u32 = 1,
    wire_validation: bool = false,
    keyed: ?bool = null,
};
pub const Export = struct { provider: []const u8, name: []const u8 };
pub const Binding = struct {
    participant: []const u8,
    type_name: []const u8,
    source: union(enum) { provider: Export, compiled: Static },
    expected_identifier: ?Identifier = null,
    required_representations: u32 = 1,
    require_wire_validation: bool = false,
};
pub const Options = struct { max_bindings: usize = 1024, max_artifact_bytes: usize = 64 * 1024 * 1024 };
fn same(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn validName(name: []const u8) bool {
    return name.len != 0 and std.mem.indexOfScalar(u8, name, 0) == null;
}
fn matches(binding: Binding, participant: []const u8, name: []const u8) bool {
    return same(binding.participant, participant) and same(binding.type_name, name);
}
/// Offline validation: no manager access, artifact reads, provider callbacks or DDS.
/// One explicit source is required per participant/name, including equivalent exports.
pub fn validate(plan: *const R.Plan, bindings: []const Binding, options: Options) !void {
    if (bindings.len > options.max_bindings) return error.BindingLimit;
    for (bindings, 0..) |binding, i| {
        if (!validName(binding.participant) or !validName(binding.type_name)) return error.InvalidBinding;
        if (binding.required_representations == 0 or binding.required_representations & ~@as(u32, 3) != 0) return error.InvalidCapabilities;
        if (binding.expected_identifier) |id| if (id[0] != 0xf1) return error.InvalidIdentifier;
        for (bindings[0..i]) |other| if (matches(other, binding.participant, binding.type_name)) return error.DuplicateBinding;
        var found = false;
        for (plan.application.participants) |p| if (same(p.name, binding.participant)) {
            for (p.types) |t| if (same(t.name, binding.type_name)) {
                found = true;
            };
        };
        if (!found) return error.UnknownBinding;
        switch (binding.source) {
            .provider => |source| {
                if (!validName(source.provider) or !validName(source.name)) return error.InvalidBinding;
                if (!same(source.name, binding.type_name)) return error.RegisteredNameAliasUnsupported;
            },
            .compiled => |source| {
                if (!same(source.binding.type_name, binding.type_name)) return error.RegisteredNameAliasUnsupported;
                if (source.binding.participant) |p| if (!same(p, binding.participant)) return error.InvalidBinding;
                try capabilities(binding, source.minimal_identifier, source.representations, source.wire_validation);
            },
        }
    }
    for (plan.application.participants) |p| for (p.types) |t| {
        var found = false;
        for (bindings) |b| if (matches(b, p.name, t.name)) {
            found = true;
        };
        if (!found) return error.MissingBinding;
    };
}
fn capabilities(binding: Binding, identifier: ?Identifier, representations: u32, validation: bool) !void {
    if (identifier) |id| if (id[0] != 0xf1) return error.InvalidIdentifier;
    if (representations == 0 or representations & ~@as(u32, 3) != 0) return error.InvalidCapabilities;
    // Current resource endpoints use XCDR1, irrespective of additional requirements.
    if ((representations & (binding.required_representations | 1)) != (binding.required_representations | 1)) return error.UnsupportedRepresentation;
    if (binding.require_wire_validation and !validation) return error.MissingWireValidation;
    if (binding.expected_identifier) |expected| {
        const actual = identifier orelse return error.MissingTypeIdentity;
        if (!std.mem.eql(u8, &expected, &actual)) return error.TypeIdentityMismatch;
    }
}
pub fn artifactHash(alloc: std.mem.Allocator, path: []const u8, limit: usize) ![32]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), path, alloc, .limited(limit)) catch |err| switch (err) {
        error.StreamTooLong => return error.ArtifactTooLarge,
        else => return err,
    };
    defer alloc.free(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}
pub const Info = struct {
    participant: []const u8,
    type_name: []const u8,
    provider: ?[]const u8,
    generation: ?u64,
    artifact: ?[]const u8,
    sha256: ?[32]u8,
    minimal_identifier: ?Identifier,
    representations: u32,
    wire_validation: bool,
    keyed: ?bool = null,
};
const Entry = struct {
    selection: ?ts.Selection = null,
    compiled: ?R.StaticBinding = null,
    info: Info,
    fn install(ctx: ?*anyopaque, participant: DDS.DomainParticipant, name: []const u8) !void {
        const self: *const Entry = @ptrCast(@alignCast(ctx.?));
        if (self.selection) |selection| {
            if (!same(selection.name(), name)) return error.RegisteredNameAliasUnsupported;
            const registered = try ts.register(participant, selection);
            registered.deinit(); // Participant owns its own generation reference.
        } else {
            const binding = self.compiled.?;
            try binding.register(binding.context, participant, name);
        }
    }
};
const Capture = struct { alias: []const u8, provider: ts.Provider, sha256: ?[32]u8 };
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    plan: R.Plan,
    entries: []const Entry,
    bindings: []const R.StaticBinding,
    /// Copies the plan and pins each alias once, so concurrent replacement cannot
    /// mix generations of one provider. Compiled adapter contexts remain borrowed.
    pub fn init(alloc: std.mem.Allocator, plan: *const R.Plan, manager: *ts.Manager, requested: []const Binding, options: Options) !Prepared {
        try validate(plan, requested, options);
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        var captures: std.ArrayList(Capture) = .empty;
        defer for (captures.items) |capture| capture.provider.deinit();
        const entries = try a.alloc(Entry, requested.len);
        var initialized: usize = 0;
        errdefer for (entries[0..initialized]) |entry| if (entry.selection) |s| s.deinit();
        const bindings = try a.alloc(R.StaticBinding, requested.len);
        for (requested, entries, bindings) |request, *entry, *binding| {
            entry.* = .{ .info = .{
                .participant = try a.dupe(u8, request.participant),
                .type_name = try a.dupe(u8, request.type_name),
                .provider = null,
                .generation = null,
                .artifact = null,
                .sha256 = null,
                .minimal_identifier = null,
                .representations = 0,
                .wire_validation = false,
            } };
            initialized += 1;
            switch (request.source) {
                .compiled => |source| {
                    entry.compiled = source.binding;
                    entry.info.minimal_identifier = source.minimal_identifier;
                    entry.info.representations = source.representations;
                    entry.info.wire_validation = source.wire_validation;
                    entry.info.keyed = source.keyed;
                },
                .provider => |source| {
                    var captured: ?Capture = null;
                    for (captures.items) |candidate| if (same(candidate.alias, source.provider)) {
                        captured = candidate;
                        break;
                    };
                    if (captured == null) {
                        const provider = try manager.acquire(source.provider);
                        errdefer provider.deinit();
                        const hash = if (ts.dynamic_loading_available and provider.generation.handle != null) try artifactHash(alloc, provider.generation.artifact, options.max_artifact_bytes) else null;
                        const capture = Capture{ .alias = source.provider, .provider = provider, .sha256 = hash };
                        try captures.append(a, capture);
                        captured = capture;
                    }
                    entry.selection = try captured.?.provider.select(source.name);
                    const selection = entry.selection.?;
                    const descriptor = selection.descriptor();
                    try capabilities(request, descriptor.minimal_identifier.value, descriptor.representations, true);
                    entry.info.provider = try a.dupe(u8, source.provider);
                    entry.info.generation = selection.generation.id;
                    entry.info.artifact = try a.dupe(u8, selection.generation.artifact);
                    entry.info.sha256 = captured.?.sha256;
                    entry.info.minimal_identifier = descriptor.minimal_identifier.value;
                    entry.info.representations = descriptor.representations;
                    entry.info.wire_validation = true;
                    entry.info.keyed = descriptor.keyed != 0;
                },
            }
            binding.* = .{ .participant = entry.info.participant, .type_name = entry.info.type_name, .context = entry, .register = Entry.install };
        }
        const owned_plan = try plan.clone(alloc);
        return .{ .arena = arena, .plan = owned_plan, .entries = entries, .bindings = bindings };
    }
    pub fn info(self: *const Prepared, index: usize) Info {
        return self.entries[index].info;
    }
    pub fn instantiate(self: *const Prepared, alloc: std.mem.Allocator, factory: DDS.DomainParticipantFactory) !R.Instance {
        return R.Instance.init(alloc, &self.plan, factory);
    }
    /// build never consults the manager again, even after provider replacement/removal.
    pub fn build(self: *const Prepared, instance: *R.Instance) !void {
        if (instance.plan != &self.plan) return error.WrongPreparedPlan;
        try instance.build(self.bindings);
    }
    /// Checked wire writes use the captured selection, never the current manager.
    /// Ordinary compiled adapters keep using their generated typed writer API.
    pub fn write(self: *const Prepared, instance: *R.Instance, participant: []const u8, endpoint: []const u8, kind: ts_write_kind, data: []const u8) !void {
        if (instance.plan != &self.plan) return error.WrongPreparedPlan;
        const writer = try instance.writer(participant, endpoint);
        const topic = writer.get_topic();
        for (self.entries) |entry| if (same(entry.info.participant, participant) and same(entry.info.type_name, topic.get_type_name())) {
            const selection = entry.selection orelse return error.CompiledAdapterWriteUnavailable;
            const registration = ts.Registration{ .participant = topic.get_participant(), .selection = selection.clone() };
            defer registration.deinit();
            return registration.write(writer, kind, data);
        };
        return error.MissingBinding;
    }
    pub fn deinit(self: *Prepared) void {
        for (self.entries) |entry| if (entry.selection) |selection| selection.deinit();
        self.plan.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
fn fullyAbsolute(path: []const u8) bool {
    return std.fs.path.isAbsolute(path) and (builtin.os.tag != .windows or std.fs.path.diskDesignatorWindows(path).len != 0);
}
pub const ProviderInput = struct {
    alias: []const u8,
    source: union(enum) { library: []const u8, linked: *const ts.wire.Library },
    expected_sha256: ?[32]u8 = null,
};
pub const Artifact = struct { alias: []const u8, path: ?[]const u8, sha256: ?[32]u8, generation: u64 };
pub const LoadOptions = struct {
    base_directory: ?[]const u8 = null,
    max_providers: usize = 32,
    max_live_generations: usize = 64,
    max_artifact_bytes: usize = 64 * 1024 * 1024,
};
pub const Environment = struct {
    arena: std.heap.ArenaAllocator,
    manager: ts.Manager,
    artifacts: []Artifact,
    /// All inputs are explicit. Relative paths resolve against the declaring
    /// document's absolute directory; this performs no ambient library search.
    /// Native loading executes trusted code. Paths must remain immutable.
    pub fn init(alloc: std.mem.Allocator, inputs: []const ProviderInput, options: LoadOptions) !Environment {
        const base_dir = options.base_directory;
        const max_providers = options.max_providers;
        const max_artifact_bytes = options.max_artifact_bytes;
        if (inputs.len > max_providers) return error.ProviderLimit;
        if (options.max_live_generations == 0) return error.InvalidGenerationLimit;
        if (inputs.len > options.max_live_generations) return error.GenerationLimitExceeded;
        if (base_dir) |base| if (!fullyAbsolute(base)) return error.AbsoluteBaseDirectoryRequired;
        for (inputs, 0..) |input, i| {
            if (!validName(input.alias)) return error.InvalidProviderName;
            for (inputs[0..i]) |prior| if (same(prior.alias, input.alias)) return error.ProviderAlreadyLoaded;
        }
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const artifacts = try a.alloc(Artifact, inputs.len);
        // Resolve and hash every artifact before executing any of their code.
        for (inputs, artifacts) |input, *artifact| {
            artifact.* = .{ .alias = try a.dupe(u8, input.alias), .path = null, .sha256 = null, .generation = 0 };
            switch (input.source) {
                .linked => if (input.expected_sha256 != null) return error.NoArtifactHash,
                .library => |path| {
                    if (!ts.dynamic_loading_available) return error.DynamicLoadingUnavailable;
                    if (!validName(path)) return error.InvalidLibraryPath;
                    if (!fullyAbsolute(path) and base_dir == null) return error.AbsoluteLibraryPathRequired;
                    artifact.path = try std.fs.path.resolve(a, &.{ base_dir orelse "", path });
                    if (!fullyAbsolute(artifact.path.?)) return error.AbsoluteLibraryPathRequired;
                    artifact.sha256 = try artifactHash(alloc, artifact.path.?, max_artifact_bytes);
                    if (input.expected_sha256) |expected| if (!std.mem.eql(u8, &expected, &artifact.sha256.?)) return error.ArtifactHashMismatch;
                },
            }
        }
        var manager = try ts.Manager.init(alloc, options.max_live_generations);
        errdefer manager.deinit();
        for (inputs, artifacts) |input, *artifact| {
            switch (input.source) {
                .library => try manager.load(artifact.alias, artifact.path.?),
                .linked => |descriptor| try manager.addStatic(artifact.alias, descriptor),
            }
            const provider = try manager.acquire(artifact.alias);
            defer provider.deinit();
            artifact.generation = provider.generation.id;
        }
        return .{ .arena = arena, .manager = manager, .artifacts = artifacts };
    }
    pub fn deinit(self: *Environment) void {
        self.manager.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};
