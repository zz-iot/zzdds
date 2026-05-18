//! Clock registry — maps string names to Clock instances.
//!
//! Bridges serializable config (timer_clock_name: []const u8) with the
//! programmatic Clock interface. The registry is pre-populated with built-in
//! names; users register custom clocks before creating participants.
//!
//! Built-in names:
//!   "default"   → monotonicClock()   (same as "monotonic"; stable alias)
//!   "monotonic" → monotonicClock()
//!   "realtime"  → realtimeClock()
//!   "boottime"  → boottimeClock()
//!
//! Failed lookups fall back to "default" with a warning log.

const std = @import("std");
const time_mod = @import("time.zig");
const log_mod = @import("../log.zig");

pub const Clock = time_mod.Clock;

pub const ClockRegistry = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Clock),

    /// Initialize with built-in clocks pre-registered.
    pub fn init(alloc: std.mem.Allocator) !ClockRegistry {
        var self: ClockRegistry = .{ .alloc = alloc, .map = .empty };
        errdefer self.deinit();
        try self.map.ensureTotalCapacity(alloc, 8);
        try self.register("default", time_mod.monotonicClock());
        try self.register("monotonic", time_mod.monotonicClock());
        try self.register("realtime", time_mod.realtimeClock());
        try self.register("boottime", time_mod.boottimeClock());
        return self;
    }

    pub fn deinit(self: *ClockRegistry) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.alloc.free(entry.key_ptr.*);
        self.map.deinit(self.alloc);
    }

    /// Register a clock under the given name. Overwrites an existing entry
    /// if the name is already registered. The registry copies the name string.
    pub fn register(self: *ClockRegistry, name: []const u8, clock: Clock) !void {
        const key = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(key);
        const gop = try self.map.getOrPut(self.alloc, key);
        if (gop.found_existing) {
            // Existing entry: free the newly-duped key; overwrite the value.
            self.alloc.free(key);
        }
        gop.value_ptr.* = clock;
    }

    /// Look up a clock by name. Falls back to "default" (monotonic) with a
    /// warning if the name is not found.
    pub fn get(self: *const ClockRegistry, name: []const u8) Clock {
        if (self.map.get(name)) |clock| return clock;
        log_mod.dcps.warn("clock_registry: unknown clock '{s}', using 'default'", .{name});
        return self.map.get("default").?;
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "ClockRegistry: built-ins present after init" {
    var reg = try ClockRegistry.init(testing.allocator);
    defer reg.deinit();

    const now_default = reg.get("default").nowNs();
    const now_monotonic = reg.get("monotonic").nowNs();
    _ = reg.get("realtime").nowNs();
    _ = reg.get("boottime").nowNs();
    // Both default and monotonic return reasonable positive values.
    try testing.expect(now_default > 0);
    try testing.expect(now_monotonic > 0);
}

test "ClockRegistry: register and retrieve custom clock" {
    var reg = try ClockRegistry.init(testing.allocator);
    defer reg.deinit();

    const manual = time_mod.ManualClock.init(12345);
    // ManualClock.clock() takes a *ManualClock; we need a non-const here.
    var mc = manual;
    try reg.register("custom", mc.clock());

    const retrieved = reg.get("custom");
    try testing.expectEqual(@as(i64, 12345), retrieved.nowNs());
}

test "ClockRegistry: unknown name falls back to default" {
    var reg = try ClockRegistry.init(testing.allocator);
    defer reg.deinit();

    // Suppress the expected fallback warning so it does not pollute test output.
    const prev_log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = prev_log_level;

    // Should not panic; returns the default (monotonic) clock.
    const clock = reg.get("nonexistent_clock");
    try testing.expect(clock.nowNs() > 0);
}

test "ClockRegistry: register overwrites existing entry" {
    var reg = try ClockRegistry.init(testing.allocator);
    defer reg.deinit();

    var mc1 = time_mod.ManualClock.init(100);
    var mc2 = time_mod.ManualClock.init(999);
    try reg.register("my_clock", mc1.clock());
    try reg.register("my_clock", mc2.clock());

    try testing.expectEqual(@as(i64, 999), reg.get("my_clock").nowNs());
}
