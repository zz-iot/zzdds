//! Configuration resolution.
//!
//! Four functions, no hidden precedence: whichever one you call gives you back
//! a concrete, ordinary config value with no further merging ever applied to
//! it — `create_participant`/factory calls always use exactly the config object
//! they're handed. Customize the result by mutating fields directly; there is
//! no separate "programmatic overrides" layer (see project decision notes).
//!
//!   resolveParticipantConfig(alloc)              -> !DomainParticipantConfig
//!     No file activity — just the IDL-declared @default values. Still runs
//!     an (empty-table) applyToml pass rather than returning a bare literal;
//!     see "Why every resolve function always calls applyToml" below. Only
//!     fails on allocation failure.
//!
//!   resolveParticipantConfigFrom(alloc, path)     -> !DomainParticipantConfig
//!     Reads `path`, applies it over the defaults. Any failure (missing file,
//!     permission, malformed TOML, a value that doesn't fit its field) is a
//!     real, propagated error — nothing here is silently swallowed, because a
//!     caller who named a specific file almost certainly wants to know if it
//!     didn't work.
//!
//!   resolveProcessConfig(alloc)                   -> !ProcessConfig
//!     Tries "./zzdds.toml". A missing file is fine (falls back to defaults —
//!     this is the expected common case, most processes have none); a file
//!     that exists but fails to parse is NOT silently ignored, since that's
//!     much more likely a real mistake than an intentional absence.
//!
//!   resolveProcessConfigFrom(alloc, path)         -> !ProcessConfig
//!     Same fallible contract as resolveParticipantConfigFrom.
//!
//! Env vars are deliberately not part of this at all: they're one value per
//! process, but config objects here are per-participant/per-factory, and this
//! library explicitly supports many of each per process — a flat env var can't
//! express "which one." An application that wants env-driven tweaks can read
//! them itself and mutate the resolved struct, same as any other override.
//!
//! ## Why every resolve function always calls applyToml, even with nothing to apply
//!
//! `applyToml` (zidl-generated) unconditionally dupes every string field —
//! including ones no TOML key overrides, using the field's *current* value as
//! the fallback — specifically so every field ends up uniformly heap-owned
//! after the call, never a mix of "heap" and "still a literal default"
//! depending on which keys happened to be present. That's what lets the
//! generated `deinit()`/`clone()` free/dupe every string field unconditionally,
//! with no per-field ownership flag.
//!
//! That invariant only holds if applyToml actually ran. A bare `DomainParticipantConfig{}`
//! that skipped it (several fields default to non-empty literals — e.g.
//! `timer_clock_name = "default"`, `multicast_group_v4 = "239.255.0.1"`) is
//! NOT safe to `.deinit()`: `deinit` would try to free those literals and
//! crash. So every function here that can return a config someone might later
//! `.deinit()` — including the "nothing to override" cases — runs it through
//! `applyToml` (against an empty `toml.Table{}` when there's genuinely nothing
//! to apply) rather than shortcutting to a bare struct literal.
//!
//! The corollary: don't hand-construct a bare `.{}` and pass it to
//! `process.configure()` or call `.deinit()` on one directly — always go
//! through one of the four functions here first, even if you don't need any
//! overrides.
//!
//! One remaining sharp edge, inherent to `applyToml` itself, not particular to
//! this file: if `applyToml` returns an error partway through (a value that
//! doesn't fit its field, etc.), fields *after* the failure point were never
//! reached and are still whatever literal the struct started with — `deinit()`
//! is NOT safe to call on that partially-populated result. `resolveXFrom`
//! propagate such errors via `try` without ever calling `.deinit()` themselves,
//! so this doesn't arise internally; it only matters if you call `applyToml`
//! yourself and it fails.

const std = @import("std");
const ext = @import("zzdds_ext_generated").zzdds;
const toml = @import("toml.zig");

pub const DomainParticipantConfig = ext.DomainParticipantConfig;
pub const ProcessConfig = ext.ProcessConfig;

/// Just the IDL-declared defaults — no file, no ambient lookup. Still runs an
/// applyToml pass (against an empty table) so every string field ends up
/// uniformly heap-owned; see the module doc comment. Only fails on OOM.
pub fn resolveParticipantConfig(alloc: std.mem.Allocator) !DomainParticipantConfig {
    var cfg: DomainParticipantConfig = .{};
    try cfg.applyToml(alloc, toml.Table{});
    return cfg;
}

/// Read `path`, apply it over the defaults. Propagates every failure.
pub fn resolveParticipantConfigFrom(alloc: std.mem.Allocator, path: []const u8) !DomainParticipantConfig {
    return resolveFrom(DomainParticipantConfig, alloc, path);
}

/// The ambient default: try "./zzdds.toml"; a missing file falls back to
/// defaults (still via applyToml, against an empty table — see the module doc
/// comment), anything else (malformed content, a value of the wrong type,
/// permission errors) propagates.
pub fn resolveProcessConfig(alloc: std.mem.Allocator) !ProcessConfig {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const table = toml.parseFile(arena.allocator(), "zzdds.toml") catch |err| switch (err) {
        error.FileNotFound, error.AccessDenied => toml.Table{},
        else => |e| return e,
    };
    var cfg: ProcessConfig = .{};
    try cfg.applyToml(alloc, table);
    return cfg;
}

/// Read `path`, apply it over the defaults. Propagates every failure.
pub fn resolveProcessConfigFrom(alloc: std.mem.Allocator, path: []const u8) !ProcessConfig {
    return resolveFrom(ProcessConfig, alloc, path);
}

/// Shared body for the `...From` functions: identical for every top-level
/// config type, since neither the file I/O nor the generated `applyToml` call
/// varies by type. The `table`'s own memory (an arena) never needs to outlive
/// this call — `applyToml` dupes whatever it keeps into `alloc`.
fn resolveFrom(comptime T: type, alloc: std.mem.Allocator, path: []const u8) !T {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const table = try toml.parseFile(arena.allocator(), path);
    var cfg: T = .{};
    try cfg.applyToml(alloc, table);
    return cfg;
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
    // Non-empty literal defaults (e.g. timer_clock_name) must have been duped,
    // not left as the original literal, or deinit above would crash.
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
