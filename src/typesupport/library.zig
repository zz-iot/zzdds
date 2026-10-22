//! Experimental provider generations. Descriptors are immutable; every Selection
//! owns a generation reference. Manager operations may run concurrently except
//! deinit, which requires the caller to stop concurrent manager operations first.
//! Concurrent operations/final releases require a thread-safe backing allocator.
const std = @import("std");
const abi = @import("zidl_typesupport");
const dynamic = @import("dynamic_library.zig");
pub const dynamic_loading_available = dynamic.available;
const Mutex = @import("../util/mutex.zig").Mutex;
pub const wire = abi;
const Query = *const fn (u32, [*c][*c]const abi.Library) callconv(.c) u32;
var next_generation: std.atomic.Value(u64) = .init(1);

const Pool = struct {
    alloc: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    live: std.atomic.Value(usize) = .init(0),
    limit: usize,
    fn retain(self: *Pool) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    fn release(self: *Pool) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.alloc.destroy(self);
    }
    fn reserve(self: *Pool) !void {
        if (self.live.fetchAdd(1, .acq_rel) >= self.limit) {
            _ = self.live.fetchSub(1, .acq_rel);
            return error.GenerationLimitExceeded;
        }
        self.retain();
    }
    fn unreserve(self: *Pool) void {
        _ = self.live.fetchSub(1, .acq_rel);
        self.release();
    }
};

pub const Generation = struct {
    alloc: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    pool: *Pool,
    id: u64,
    provider: []const u8,
    artifact: []const u8,
    descriptor: *const abi.Library,
    handle: ?dynamic.Library,
    fn create(pool: *Pool, provider: []const u8, path: ?[]const u8, static_descriptor: ?*const abi.Library) !*Generation {
        if (provider.len == 0) return error.InvalidProviderName;
        try pool.reserve();
        errdefer pool.unreserve();
        var handle: ?dynamic.Library = if (path) |p| try dynamic.Library.open(pool.alloc, p) else null;
        errdefer if (handle) |*h| h.close();
        const descriptor = if (handle) |*h| blk: {
            const query = h.lookup(Query, "zidl_typesupport_query") orelse return error.MissingLibraryQuery;
            var result: [*c]const abi.Library = null;
            if (query(abi.abi_major, &result) != abi.ok or result == null) return error.IncompatibleLibrary;
            break :blk @as(*const abi.Library, result);
        } else static_descriptor.?;
        try abi.checkLibrary(descriptor);
        const name = try pool.alloc.dupe(u8, provider);
        errdefer pool.alloc.free(name);
        const artifact = try pool.alloc.dupe(u8, path orelse "<static>");
        errdefer pool.alloc.free(artifact);
        const self = try pool.alloc.create(Generation);
        self.* = .{ .alloc = pool.alloc, .pool = pool, .id = next_generation.fetchAdd(1, .monotonic), .provider = name, .artifact = artifact, .descriptor = descriptor, .handle = handle };
        return self;
    }
    pub fn retain(self: *Generation) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }
    /// The final release must run outside participant/registry/reader locks.
    pub fn release(self: *Generation) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.handle) |*h| h.close();
        const pool = self.pool;
        self.alloc.free(self.provider);
        self.alloc.free(self.artifact);
        self.alloc.destroy(self);
        pool.unreserve();
    }
};

pub const Selection = struct {
    generation: *Generation,
    type_index: usize,
    pub fn clone(self: Selection) Selection {
        self.generation.retain();
        return self;
    }
    pub fn deinit(self: Selection) void {
        self.generation.release();
    }
    pub fn descriptor(self: Selection) *const abi.Type {
        const array: [*]const abi.Type = self.generation.descriptor.types;
        return &array[self.type_index];
    }
    pub fn name(self: Selection) []const u8 {
        const d = self.descriptor();
        return d.name.data[0..@intCast(d.name.size)];
    }
    pub fn equivalent(self: Selection, other: Selection) bool {
        return std.mem.eql(u8, &self.descriptor().minimal_identifier.value, &other.descriptor().minimal_identifier.value);
    }
    fn representation(self: Selection, data: []const u8) !void {
        _ = abi.reader(data.ptr, data.len) catch return error.UnsupportedRepresentation;
        const flag: u32 = if (data[1] < 2) 1 else 2;
        if (self.descriptor().representations & flag == 0) return error.UnsupportedRepresentation;
    }
    pub fn validate(self: Selection, data: []const u8) !void {
        try self.representation(data);
        try checkStatus(self.descriptor().validate.?(data.ptr, data.len));
    }
    pub fn keyHash(self: Selection, data: []const u8, key_only: bool) ![16]u8 {
        try self.representation(data);
        const callback = if (key_only) self.descriptor().key_only_hash.? else self.descriptor().key_hash.?;
        var hash: [16]u8 = undefined;
        try checkStatus(callback(data.ptr, data.len, &hash));
        return hash;
    }
};
fn checkStatus(status: u32) !void {
    switch (status) {
        abi.ok => {},
        abi.invalid_data => return error.InvalidSample,
        abi.unsupported => return error.UnsupportedRepresentation,
        else => return error.ProviderOperationFailed,
    }
}

/// An owning inspection view. Returned descriptor slices are borrowed from this
/// generation and must not be retained after the view or another pin is released.
pub const Provider = struct {
    generation: *Generation,
    pub fn deinit(self: Provider) void {
        self.generation.release();
    }
    pub fn types(self: Provider) []const abi.Type {
        return self.generation.descriptor.types[0..@intCast(self.generation.descriptor.type_count)];
    }
    pub fn select(self: Provider, type_name: []const u8) !Selection {
        for (self.types(), 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name.data[0..@intCast(entry.name.size)], type_name)) {
                self.generation.retain();
                return .{ .generation = self.generation, .type_index = i };
            }
        }
        return error.UnknownType;
    }
};

pub const Manager = struct {
    pool: *Pool,
    mu: Mutex = .{},
    active: std.ArrayList(*Generation) = .empty,
    pub fn init(alloc: std.mem.Allocator, max_live_generations: usize) !Manager {
        if (max_live_generations == 0) return error.InvalidGenerationLimit;
        const pool = try alloc.create(Pool);
        pool.* = .{ .alloc = alloc, .limit = max_live_generations };
        return .{ .pool = pool };
    }
    pub fn deinit(self: *Manager) void {
        for (self.active.items) |g| g.release();
        self.active.deinit(self.pool.alloc);
        self.mu.deinit();
        self.pool.release();
        self.* = undefined;
    }
    pub fn liveGenerations(self: *const Manager) usize {
        return self.pool.live.load(.acquire);
    }
    pub fn load(self: *Manager, provider: []const u8, path: []const u8) !void {
        const g = try Generation.create(self.pool, provider, path, null);
        errdefer g.release();
        try self.publish(g, false);
    }
    /// Static descriptor and its callbacks must remain valid through all users.
    pub fn addStatic(self: *Manager, provider: []const u8, descriptor: *const abi.Library) !void {
        const g = try Generation.create(self.pool, provider, null, descriptor);
        errdefer g.release();
        try self.publish(g, false);
    }
    /// Load and verify a distinct immutable artifact before publishing. Existing
    /// selections/registrations continue using the old generation. No live swap.
    pub fn replace(self: *Manager, provider: []const u8, path: []const u8) !void {
        const g = try Generation.create(self.pool, provider, path, null);
        errdefer g.release();
        try self.publish(g, true);
    }
    fn publish(self: *Manager, g: *Generation, replacing: bool) !void {
        var retired: ?*Generation = null;
        defer if (retired) |old| old.release();
        self.mu.lock();
        defer self.mu.unlock();
        for (self.active.items) |*slot| if (std.mem.eql(u8, slot.*.provider, g.provider)) {
            if (!replacing) return error.ProviderAlreadyLoaded;
            if (std.mem.eql(u8, slot.*.artifact, g.artifact)) return error.ArtifactPathUnchanged;
            retired = slot.*;
            slot.* = g;
            return;
        };
        if (replacing) return error.UnknownProvider;
        try self.active.append(self.pool.alloc, g);
    }
    /// Owns a generation reference while enumerating immutable type/metadata
    /// descriptors. Removing/replacing a provider does not invalidate this view.
    pub fn acquire(self: *Manager, provider: []const u8) !Provider {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.active.items) |g| if (std.mem.eql(u8, g.provider, provider)) {
            g.retain();
            return .{ .generation = g };
        };
        return error.UnknownProvider;
    }
    pub fn select(self: *Manager, provider: []const u8, type_name: []const u8) !Selection {
        const view = try self.acquire(provider);
        defer view.deinit();
        return view.select(type_name);
    }
    pub fn remove(self: *Manager, provider: []const u8) !void {
        var retired: ?*Generation = null;
        defer if (retired) |g| g.release();
        self.mu.lock();
        defer self.mu.unlock();
        for (self.active.items, 0..) |g, i| if (std.mem.eql(u8, provider, g.provider)) {
            retired = self.active.swapRemove(i);
            return;
        };
        return error.UnknownProvider;
    }
};
