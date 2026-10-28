//! Resolve ordinary owned config values. File defaults, caller field mutation,
//! one-time process installation and factory snapshots retain their existing policy.
//! The shared reader replaces only decoding; config-authoring=false selects legacy decoding.
//! No profile merging, environment overrides or implicit participant file access.
//! Explicit file failures propagate; ambient process lookup alone treats missing
//! or inaccessible ./zzdds.toml as defaults. Generated clone/deinit own the returned
//! fields independently of parsing/report storage.

const std = @import("std");
const ext = @import("zzdds_ext_generated").zzdds;
const toml = @import("toml.zig");
const rt = @import("zidl_rt");
const reader = @import("read_options.zig");
const modern = @import("build_options").config_authoring;
pub const ReadOptions = reader.Options;
pub const ReadDiagnostics = reader.Diagnostics;

pub const DomainParticipantConfig = ext.DomainParticipantConfig;
pub const ProcessConfig = ext.ProcessConfig;

/// Just the IDL-declared defaults, with independently owned strings and lists.
/// No file or ambient lookup. Only fails on OOM.
pub fn resolveParticipantConfig(alloc: std.mem.Allocator) !DomainParticipantConfig {
    return fromTable(DomainParticipantConfig, alloc, toml.Table{});
}

/// Read `path`, apply it over the defaults. Propagates every failure.
pub fn resolveParticipantConfigFrom(alloc: std.mem.Allocator, path: []const u8) !DomainParticipantConfig {
    return resolveFrom(DomainParticipantConfig, alloc, path);
}

/// The ambient default: try "./zzdds.toml"; a missing file falls back to
/// defaults. AccessDenied also retains its established fallback; other errors propagate.
pub fn resolveProcessConfig(alloc: std.mem.Allocator) !ProcessConfig {
    var buffer: [8192]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, alloc);
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());
    defer arena.deinit();
    const table = toml.parseFile(arena.allocator(), "zzdds.toml") catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => toml.Table{},
        else => |e| return e,
    };
    return fromTable(ProcessConfig, alloc, table);
}

/// Read `path`, apply it over the defaults. Propagates every failure.
pub fn resolveProcessConfigFrom(alloc: std.mem.Allocator, path: []const u8) !ProcessConfig {
    return resolveFrom(ProcessConfig, alloc, path);
}

/// Read a temporary tree and return an independently owned config.
fn resolveFrom(comptime T: type, alloc: std.mem.Allocator, path: []const u8) !T {
    var buffer: [8192]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, alloc);
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());
    defer arena.deinit();
    const table = try toml.parseFile(arena.allocator(), path);
    return fromTable(T, alloc, table);
}
fn fromTable(comptime T: type, alloc: std.mem.Allocator, table: toml.Table) !T {
    if (comptime modern) return readOwned(T, alloc, table, .{ .unknown_fields = .ignore, .capture_skipped = false }, null);
    var cfg: T = .{};
    try cfg.applyToml(alloc, table);
    return cfg;
}

/// Strict ordinary-field checks by default; preserves legacy enum spelling.
/// Requires the config-authoring build. Existing APIs keep their signatures and
/// ignore unmarked unknowns for compatibility. Diagnostic data is independently owned.
pub fn resolveParticipantConfigFromWithOptions(alloc: std.mem.Allocator, path: []const u8, options: ReadOptions, diagnostic: *ReadDiagnostics) !DomainParticipantConfig {
    return resolveWithOptions(DomainParticipantConfig, alloc, path, options, diagnostic);
}
pub fn resolveProcessConfigFromWithOptions(alloc: std.mem.Allocator, path: []const u8, options: ReadOptions, diagnostic: *ReadDiagnostics) !ProcessConfig {
    return resolveWithOptions(ProcessConfig, alloc, path, options, diagnostic);
}
fn resolveWithOptions(comptime T: type, alloc: std.mem.Allocator, path: []const u8, options: ReadOptions, diagnostic: *ReadDiagnostics) !T {
    diagnostic.deinit();
    if (comptime !modern) {
        diagnostic.code = error.ConfigAuthoringUnavailable;
        return error.ConfigAuthoringUnavailable;
    }
    var buffer: [8192]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, alloc);
    var arena = std.heap.ArenaAllocator.init(scratch.allocator());
    defer arena.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena.allocator(), .limited(reader.file_limit)) catch |err| {
        diagnostic.code = err;
        return err;
    };
    var syntax: toml.Diagnostic = .{};
    const table = toml.parseLocated(arena.allocator(), bytes, &syntax, .{ .max_values = options.max_elements, .max_depth = options.max_depth }) catch |err| {
        diagnostic.code = err;
        diagnostic.location = .{ .offset = syntax.location.offset, .line = syntax.location.line, .column = syntax.location.column };
        return err;
    };
    return readOwned(T, alloc, table, options, diagnostic) catch |err| {
        if (diagnostic.code == null) diagnostic.code = err;
        return err;
    };
}
fn copyPath(alloc: std.mem.Allocator, path: []const []const u8) ![]const []const u8 {
    const result = try alloc.alloc([]const u8, path.len);
    for (path, result) |part, *out| out.* = try alloc.dupe(u8, part);
    return result;
}
fn readOwned(comptime T: type, alloc: std.mem.Allocator, table: toml.Table, options: ReadOptions, diagnostic: ?*ReadDiagnostics) !T {
    if (comptime !modern) return error.ConfigAuthoringUnavailable;
    var detail: rt.authoring.Diagnostic = .{};
    // Small configs need no growing arena blocks from fixed-block allocators.
    // Larger temporary work falls back only to the caller's allocator.
    var buffer: [8192]u8 = undefined;
    var scratch = std.heap.BufferFirstAllocator.init(&buffer, alloc);
    var decoded = T.decodeToml(scratch.allocator(), table, .{
        .conditional_members = options.conditional_members,
        .unknown_fields = switch (options.unknown_fields) {
            .reject => .reject,
            .ignore => .ignore,
        },
        .enum_matching = switch (options.enum_matching) {
            .canonical => .canonical,
            .ascii_case_insensitive => .ascii_case_insensitive,
        },
        .capture_element_presence = false,
        .capture_skipped = diagnostic != null and options.capture_skipped,
        .max_depth = options.max_depth,
        .max_string_bytes = options.max_string_bytes,
        .max_elements = options.max_elements,
        .max_path_bytes = options.max_path_bytes,
        .max_skipped = options.max_skipped,
    }, &detail) catch |err| {
        const mapped = switch (err) {
            error.OutOfRange, error.InvalidEnum => error.InvalidValue,
            else => err,
        };
        if (diagnostic) |d| {
            d.code = err;
            d.location = .{ .offset = detail.location.offset, .line = detail.location.line, .column = detail.location.column };
            d.path = detail.path;
            d.path_len = detail.path_len;
            d.path_truncated = detail.path_truncated;
        }
        return mapped;
    };
    defer decoded.deinit();
    var result = try decoded.value.clone(alloc);
    errdefer result.deinit(alloc);
    if (diagnostic) |d| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        errdefer arena.deinit();
        const a = arena.allocator();
        const skipped = try a.alloc(reader.Skipped, decoded.skipped.len);
        for (decoded.skipped, skipped) |source, *dest| dest.* = .{
            .path = try copyPath(a, source.path),
            .input_path = try copyPath(a, source.input_path),
            .location = .{ .offset = source.location.offset, .line = source.location.line, .column = source.location.column },
            .reason = switch (source.reason) {
                .conditional_unknown => .conditional_unknown,
                .compatibility_unknown => .compatibility_unknown,
            },
        };
        d.arena = arena;
        d.skipped = skipped;
        d.skipped_count = decoded.skipped_count;
        d.skipped_complete = decoded.skipped_complete;
    }
    return result;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "resolveParticipantConfig: pure defaults, safely deinit-able" {
    var cfg = try resolveParticipantConfig(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    const expected = DomainParticipantConfig{};
    try std.testing.expectEqual(expected.domain.id, cfg.domain.id);
    try std.testing.expectEqual(expected.participant.lease_duration_ms, cfg.participant.lease_duration_ms);
    try std.testing.expectEqual(expected.transport.udp.port_base, cfg.transport.udp.port_base);
    try std.testing.expectEqual(expected.discovery.kind, cfg.discovery.kind);
    // Non-empty defaults must remain independently owned after temporary storage
    // has been freed.
    try std.testing.expectEqualStrings("default", cfg.participant.timer_clock_name);
}

test "resolveParticipantConfigFrom: applies a file over defaults" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zzdds_resolve_participant_test.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\[domain]
        \\id = 5
        \\[participant]
        \\lease_duration_ms = 30000
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var cfg = try resolveParticipantConfigFrom(arena.allocator(), path);
    defer cfg.deinit(arena.allocator());
    try std.testing.expectEqual(@as(u32, 5), cfg.domain.id);
    try std.testing.expectEqual(@as(u32, 30000), cfg.participant.lease_duration_ms);
    // Fields not mentioned in the file stay at their IDL defaults.
    try std.testing.expectEqual(@as(u16, 7400), cfg.transport.udp.port_base);
}

test "resolveParticipantConfigFrom: missing file propagates FileNotFound" {
    try std.testing.expectError(
        error.FileNotFound,
        resolveParticipantConfigFrom(std.testing.allocator, "zzdds_definitely_does_not_exist.toml"),
    );
}

test "resolveParticipantConfigFrom: malformed value propagates InvalidValue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zzdds_resolve_participant_bad_test.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\[transport.udp]
        \\port_base = 999999
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try std.testing.expectError(error.InvalidValue, resolveParticipantConfigFrom(arena.allocator(), path));
}

test "resolveProcessConfig: no zzdds.toml in cwd falls back to defaults" {
    // The test runner's cwd has no zzdds.toml.
    var cfg = try resolveProcessConfig(std.testing.allocator);
    defer cfg.deinit(std.testing.allocator);
    const expected = ProcessConfig{};
    try std.testing.expectEqual(expected.default_participant_config.domain.id, cfg.default_participant_config.domain.id);
}

test "resolveProcessConfigFrom: applies the nested default_participant_config table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zzdds_resolve_process_test.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\[default_participant_config.domain]
        \\id = 9
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    var cfg = try resolveProcessConfigFrom(arena.allocator(), path);
    defer cfg.deinit(arena.allocator());
    try std.testing.expectEqual(@as(u32, 9), cfg.default_participant_config.domain.id);
}
