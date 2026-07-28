//! Process-wide configuration state.
//!
//! This is a deliberate, singular exception to this codebase's usual "not a
//! singleton" stance (see `factory.zig`'s own doc comment): a process
//! genuinely has exactly one ambient environment/filesystem, unlike a
//! `DomainParticipantConfig`, which is inherently per-participant/per-factory
//! and explicitly supports many coexisting instances per process.
//!
//! `resolveProcessConfig`/`resolveProcessConfigFrom` (resolve.zig) stay pure —
//! they just return a value, no side effects. Installing a `ProcessConfig` as
//! *the* process-wide one is a separate, explicit act (`configure`), so calling
//! resolve never has a hidden side effect. If the app never calls `configure`
//! itself, `getForNewFactory` resolves the ambient default lazily, exactly
//! once, the first time any factory is created.

const std = @import("std");
const Mutex = @import("../util/mutex.zig").Mutex;
const resolve = @import("resolve.zig");

pub const ProcessConfig = resolve.ProcessConfig;

var mu: Mutex = .{};
var state: ?ProcessConfig = null;

/// The allocator the canonical process-wide copy is CURRENTLY stored with —
/// always whichever allocator actually produced `state` (see `configure`/
/// `getForNewFactory` below), never a value assumed ahead of time. Only ever
/// read/written while holding `mu`. Defaults to `std.heap.c_allocator` purely
/// as the fallback for the fully-ambient path (`getForNewFactory` when
/// nobody ever called `configure` first) — there's no caller-supplied
/// allocator available yet at that point to prefer instead.
var state_alloc: std.mem.Allocator = std.heap.c_allocator;

/// Install `cfg` as the process-wide config, stored via `alloc` — the SAME
/// allocator `cfg` itself was already built with (typically via
/// `resolve.resolveProcessConfig(From)(alloc, ...)`). Calling this explicitly,
/// before any factory has been created, is what lets an embedded/RT caller
/// avoid `getForNewFactory`'s ambient `std.heap.c_allocator` fallback below
/// entirely: the persistent singleton then lives in the caller's own
/// allocator for its whole process lifetime, same as everything else the
/// caller already routes through it. `cfg` is always fully consumed by this
/// call (freed via `alloc` once it's been cloned into this module's own
/// persistent storage) regardless of success or failure.
/// Errors if a config is already installed, whether from an earlier explicit
/// `configure` call or from `getForNewFactory` already having resolved the
/// lazy default — configuring after that point would silently strand whatever
/// factory already started from the old value, so it's a hard error instead.
pub fn configure(alloc: std.mem.Allocator, cfg: ProcessConfig) !void {
    var owned = cfg;
    defer owned.deinit(alloc);
    mu.lock();
    defer mu.unlock();
    if (state != null) return error.AlreadyConfigured;
    state = try owned.clone(alloc);
    state_alloc = alloc;
}

/// Resolve `path` and install it as the process-wide config in one step,
/// entirely through `alloc` — the combined form of
/// `resolve.resolveProcessConfigFrom` + `configure`, and the recommended way
/// for an embedded/RT caller to seed the ambient default from a caller-chosen
/// allocator instead of the fallback `std.heap.c_allocator` `getForNewFactory`
/// would otherwise use. Same "must be called before any factory exists"
/// precondition as `configure` (surfaces as `error.AlreadyConfigured`).
pub fn configureFromFile(alloc: std.mem.Allocator, path: []const u8) !void {
    const cfg = try resolve.resolveProcessConfigFrom(alloc, path);
    try configure(alloc, cfg);
}

/// Called when constructing a new factory. Returns a clone of the process-wide
/// config, owned by `alloc`. Resolves+commits the ambient default lazily, at
/// most once per process — via `std.heap.c_allocator`, regardless of `alloc`
/// — if neither `configure` nor `configureFromFile` was ever called
/// explicitly first. This is a one-time, pre-arm bootstrap cost (same shape
/// as `dcps/nil.zig`'s nil-singleton bookkeeping), not a hot-path one: it can
/// only ever run once, on whichever factory happens to be first, and every
/// subsequent call (including this one, once resolved) only ever *clones*
/// the cached result through `alloc`. A caller that wants zero libc `malloc`
/// even for this one-time step must call `configure`/`configureFromFile`
/// itself, with its own allocator, before creating its first factory.
pub fn getForNewFactory(alloc: std.mem.Allocator) !ProcessConfig {
    mu.lock();
    defer mu.unlock();
    if (state == null) {
        state = try resolve.resolveProcessConfig(std.heap.c_allocator);
        state_alloc = std.heap.c_allocator;
    }
    return state.?.clone(alloc);
}

/// Test-only escape hatch. A lazily-resolved, cached-once global is a classic
/// source of test-order contamination in a test binary that runs many `test`
/// blocks in one process; call this between tests that each need to observe
/// their own lazy-resolution or explicit-`configure` behavior.
pub fn resetForTesting() void {
    mu.lock();
    defer mu.unlock();
    if (state) |*s| s.deinit(state_alloc);
    state = null;
    state_alloc = std.heap.c_allocator;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// NOTE: every `ProcessConfig` passed to `configure()` below comes from
// `resolve.resolveProcessConfig()`, never a bare `.{}` literal — `configure`
// always calls `.deinit()` on its input, and a bare literal has non-empty
// string fields (e.g. `timer_clock_name`) that were never duped, which
// crashes. See resolve.zig's module doc comment.

test "configure then getForNewFactory returns a clone of the configured value" {
    resetForTesting();
    defer resetForTesting();
    var cfg = try resolve.resolveProcessConfig(std.testing.allocator);
    cfg.default_participant_config.domain.id = 42;
    try configure(std.testing.allocator, cfg);

    var got = try getForNewFactory(std.testing.allocator);
    defer got.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 42), got.default_participant_config.domain.id);
}

test "configure twice is an error" {
    resetForTesting();
    defer resetForTesting();
    try configure(std.testing.allocator, try resolve.resolveProcessConfig(std.testing.allocator));
    try std.testing.expectError(
        error.AlreadyConfigured,
        configure(std.testing.allocator, try resolve.resolveProcessConfig(std.testing.allocator)),
    );
}

test "getForNewFactory resolves the ambient default lazily if configure was never called" {
    resetForTesting();
    defer resetForTesting();
    // No zzdds.toml in the test cwd, and configure() was never called — the
    // lazy path should still succeed, falling back to defaults.
    var got = try getForNewFactory(std.testing.allocator);
    defer got.deinit(std.testing.allocator);
    const expected = ProcessConfig{};
    try std.testing.expectEqual(
        expected.default_participant_config.domain.id,
        got.default_participant_config.domain.id,
    );
}

test "configure after the lazy default has already resolved is an error" {
    resetForTesting();
    defer resetForTesting();
    var first = try getForNewFactory(std.testing.allocator);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.AlreadyConfigured,
        configure(std.testing.allocator, try resolve.resolveProcessConfig(std.testing.allocator)),
    );
}

test "getForNewFactory gives independent clones, not shared state" {
    resetForTesting();
    defer resetForTesting();
    try configure(std.testing.allocator, try resolve.resolveProcessConfig(std.testing.allocator));

    var a = try getForNewFactory(std.testing.allocator);
    defer a.deinit(std.testing.allocator);
    var b = try getForNewFactory(std.testing.allocator);
    defer b.deinit(std.testing.allocator);
    a.default_participant_config.domain.id = 1;
    b.default_participant_config.domain.id = 2;
    try std.testing.expectEqual(@as(u32, 1), a.default_participant_config.domain.id);
    try std.testing.expectEqual(@as(u32, 2), b.default_participant_config.domain.id);
}

test "configure stores the persistent copy through the caller's own allocator, not a hidden default" {
    resetForTesting();
    defer resetForTesting();
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();

    const cfg = try resolve.resolveProcessConfig(alloc);
    try configure(alloc, cfg);

    // If `configure` silently re-cloned into some other allocator internally
    // (the bug this test guards against — the persistent singleton used to
    // always live in std.heap.c_allocator regardless of what was passed
    // here), this pointer would fall outside `buf`.
    const stored_ptr = @intFromPtr(state.?.default_participant_config.participant.timer_clock_name.ptr);
    const buf_start = @intFromPtr(&buf[0]);
    try std.testing.expect(stored_ptr >= buf_start and stored_ptr < buf_start + buf.len);

    var got = try getForNewFactory(std.testing.allocator);
    defer got.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("default", got.default_participant_config.participant.timer_clock_name);
}

test "configureFromFile resolves and installs in one step" {
    resetForTesting();
    defer resetForTesting();
    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "zzdds_configure_from_file_test.toml";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data =
        \\[default_participant_config.domain]
        \\id = 11
        \\
    });
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    try configureFromFile(std.testing.allocator, path);

    var got = try getForNewFactory(std.testing.allocator);
    defer got.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 11), got.default_participant_config.domain.id);
}

test "configureFromFile propagates a missing file as an error, without installing anything" {
    resetForTesting();
    defer resetForTesting();
    try std.testing.expectError(
        error.FileNotFound,
        configureFromFile(std.testing.allocator, "zzdds_definitely_does_not_exist.toml"),
    );
    // The lazy ambient path must still be available afterward -- a failed
    // configureFromFile must not have left `state` partially set.
    var got = try getForNewFactory(std.testing.allocator);
    defer got.deinit(std.testing.allocator);
}
