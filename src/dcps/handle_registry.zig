//! Allocated handles: a key-to-slot index and a dense slot array, where a
//! handle names a slot and the generation of its occupant
//! (docs/design/handle-registries.md).
//!
//! A handle is `(generation << 22) | (slot + 1)`: positive, never
//! `HANDLE_NIL`, at most 4,194,303 live entries and 512 generations per slot.
//! Resolving a handle checks the slot's generation, so a handle whose entry
//! was removed resolves to nothing rather than to the slot's next occupant
//! until the slot has been reused 512 times. Freed slots are reused first in,
//! first out, which spreads reuse over all of them.
//!
//! Not thread-safe: each registry is guarded by its owner's lock.

const std = @import("std");

pub const Handle = i32;

const SLOT_BITS = 22;
const GENERATION_BITS = 9;
/// The most live entries a registry holds.
pub const MAX_ENTRIES: u32 = (1 << SLOT_BITS) - 1;
const GENERATION_MASK: u32 = (1 << GENERATION_BITS) - 1;
const NO_SLOT: u32 = std.math.maxInt(u32);

pub fn HandleRegistry(comptime Key: type, comptime Value: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            key: Key,
            generation: u32,
            live: bool,
            /// The next free slot, while this one is free.
            next_free: u32,
            value: Value,
        };

        index: std.AutoHashMapUnmanaged(Key, u32) = .empty,
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: u32 = NO_SLOT,
        free_tail: u32 = NO_SLOT,
        live: u32 = 0,
        /// `getOrPut` fails with `error.OutOfHandles` for a new key once this
        /// many entries are live.
        limit: u32 = MAX_ENTRIES,

        pub const empty: Self = .{};

        pub const GetOrPutResult = struct {
            handle: Handle,
            /// Valid until the next `getOrPut`. Undefined for a new entry,
            /// which the caller initializes.
            value: *Value,
            found_existing: bool,
        };

        pub const Entry = struct {
            handle: Handle,
            key: *const Key,
            value: *Value,
        };

        /// Does not deinitialize the values; iterate first if they own memory.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.index.deinit(alloc);
            self.slots.deinit(alloc);
            self.* = undefined;
        }

        fn handleOf(slot: u32, generation: u32) Handle {
            return @intCast((generation << SLOT_BITS) | (slot + 1));
        }

        fn slotOf(self: *const Self, handle: Handle) ?u32 {
            if (handle <= 0) return null;
            const h: u32 = @intCast(handle);
            const slot_plus_one = h & MAX_ENTRIES;
            if (slot_plus_one == 0) return null;
            const slot = slot_plus_one - 1;
            if (slot >= self.slots.items.len) return null;
            const s = &self.slots.items[slot];
            if (!s.live or s.generation != h >> SLOT_BITS) return null;
            return slot;
        }

        /// The entry for `key`, allocating one if there is none.
        pub fn getOrPut(self: *Self, alloc: std.mem.Allocator, key: Key) error{ OutOfMemory, OutOfHandles }!GetOrPutResult {
            if (self.index.get(key)) |slot| {
                const s = &self.slots.items[slot];
                return .{ .handle = handleOf(slot, s.generation), .value = &s.value, .found_existing = true };
            }
            if (self.live >= self.limit) return error.OutOfHandles;
            try self.index.ensureUnusedCapacity(alloc, 1);
            const slot = if (self.free_head != NO_SLOT) blk: {
                const slot = self.free_head;
                self.free_head = self.slots.items[slot].next_free;
                if (self.free_head == NO_SLOT) self.free_tail = NO_SLOT;
                break :blk slot;
            } else blk: {
                if (self.slots.items.len >= MAX_ENTRIES) return error.OutOfHandles;
                try self.slots.append(alloc, .{ .key = key, .generation = 0, .live = false, .next_free = NO_SLOT, .value = undefined });
                break :blk @as(u32, @intCast(self.slots.items.len - 1));
            };
            self.index.putAssumeCapacityNoClobber(key, slot);
            const s = &self.slots.items[slot];
            s.key = key;
            s.live = true;
            self.live += 1;
            return .{ .handle = handleOf(slot, s.generation), .value = &s.value, .found_existing = false };
        }

        /// The handle of `key`'s entry, or null.
        pub fn handleOfKey(self: *const Self, key: Key) ?Handle {
            const slot = self.index.get(key) orelse return null;
            return handleOf(slot, self.slots.items[slot].generation);
        }

        /// The value of `key`'s entry, or null.
        pub fn getByKey(self: *const Self, key: Key) ?*Value {
            const slot = self.index.get(key) orelse return null;
            return &self.slots.items[slot].value;
        }

        /// The value of the entry `handle` names, or null if it names none
        /// (`HANDLE_NIL`, never issued, or removed).
        pub fn get(self: *const Self, handle: Handle) ?*Value {
            const slot = self.slotOf(handle) orelse return null;
            return &self.slots.items[slot].value;
        }

        /// The key of the entry `handle` names, or null.
        pub fn keyOf(self: *const Self, handle: Handle) ?Key {
            const slot = self.slotOf(handle) orelse return null;
            return self.slots.items[slot].key;
        }

        /// Remove the entry `handle` names and return its value, or null if it
        /// names none. The handle, and any copy of it, then resolves to nothing.
        pub fn remove(self: *Self, handle: Handle) ?Value {
            const slot = self.slotOf(handle) orelse return null;
            const s = &self.slots.items[slot];
            _ = self.index.remove(s.key);
            const value = s.value;
            s.live = false;
            s.generation = (s.generation + 1) & GENERATION_MASK;
            s.next_free = NO_SLOT;
            s.value = undefined;
            if (self.free_tail == NO_SLOT) {
                self.free_head = slot;
            } else {
                self.slots.items[self.free_tail].next_free = slot;
            }
            self.free_tail = slot;
            self.live -= 1;
            return value;
        }

        pub fn count(self: *const Self) u32 {
            return self.live;
        }

        pub fn iterator(self: *Self) Iterator {
            return .{ .registry = self };
        }

        /// Live entries in slot order. Valid until the registry changes.
        pub const Iterator = struct {
            registry: *Self,
            next_slot: u32 = 0,

            pub fn next(it: *Iterator) ?Entry {
                const slots = it.registry.slots.items;
                while (it.next_slot < slots.len) {
                    const slot = it.next_slot;
                    it.next_slot += 1;
                    const s = &slots[slot];
                    if (s.live) return .{ .handle = handleOf(slot, s.generation), .key = &s.key, .value = &s.value };
                }
                return null;
            }
        };
    };
}

const testing = std.testing;
const TestRegistry = HandleRegistry([16]u8, u32);

fn testKey(n: u8) [16]u8 {
    var k = std.mem.zeroes([16]u8);
    k[15] = n;
    return k;
}

test "getOrPut allocates a handle once per key; lookups by key and handle agree" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);

    const a = try r.getOrPut(testing.allocator, testKey(1));
    try testing.expect(!a.found_existing);
    a.value.* = 10;
    const b = try r.getOrPut(testing.allocator, testKey(2));
    b.value.* = 20;
    try testing.expect(a.handle > 0 and b.handle > 0 and a.handle != b.handle);

    const again = try r.getOrPut(testing.allocator, testKey(1));
    try testing.expect(again.found_existing);
    try testing.expectEqual(a.handle, again.handle);
    try testing.expectEqual(@as(u32, 10), again.value.*);

    try testing.expectEqual(a.handle, r.handleOfKey(testKey(1)).?);
    try testing.expectEqual(@as(?Handle, null), r.handleOfKey(testKey(3)));
    try testing.expectEqual(@as(u32, 20), r.get(b.handle).?.*);
    try testing.expectEqual(@as(u32, 20), r.getByKey(testKey(2)).?.*);
    try testing.expectEqualSlices(u8, &testKey(2), &r.keyOf(b.handle).?);
    try testing.expectEqual(@as(u32, 2), r.count());
}

test "handles that were never issued resolve to nothing" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);
    const a = try r.getOrPut(testing.allocator, testKey(1));
    a.value.* = 1;
    for ([_]Handle{ 0, -1, std.math.minInt(Handle), a.handle + 1, std.math.maxInt(Handle), a.handle | (1 << SLOT_BITS) }) |h| {
        try testing.expectEqual(@as(?*u32, null), r.get(h));
        try testing.expectEqual(@as(?[16]u8, null), r.keyOf(h));
    }
}

test "a removed entry's handle goes stale, and its slot comes back under a new handle" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);
    const a = try r.getOrPut(testing.allocator, testKey(1));
    a.value.* = 1;
    try testing.expectEqual(@as(u32, 1), r.remove(a.handle).?);
    try testing.expectEqual(@as(?*u32, null), r.get(a.handle));
    try testing.expectEqual(@as(?u32, null), r.remove(a.handle));
    try testing.expectEqual(@as(?Handle, null), r.handleOfKey(testKey(1)));
    try testing.expectEqual(@as(u32, 0), r.count());

    // The same key gets the freed slot, under the next generation.
    const b = try r.getOrPut(testing.allocator, testKey(1));
    try testing.expect(!b.found_existing);
    try testing.expect(b.handle != a.handle);
    try testing.expectEqual(a.handle & MAX_ENTRIES, b.handle & MAX_ENTRIES);
    try testing.expectEqual(@as(usize, 1), r.slots.items.len);
}

test "freed slots are reused first in, first out" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);
    var handles: [4]Handle = undefined;
    for (&handles, 0..) |*h, i| h.* = (try r.getOrPut(testing.allocator, testKey(@intCast(i)))).handle;
    _ = r.remove(handles[2]);
    _ = r.remove(handles[0]);
    const x = try r.getOrPut(testing.allocator, testKey(10));
    const y = try r.getOrPut(testing.allocator, testKey(11));
    try testing.expectEqual(handles[2] & MAX_ENTRIES, x.handle & MAX_ENTRIES);
    try testing.expectEqual(handles[0] & MAX_ENTRIES, y.handle & MAX_ENTRIES);
    const z = try r.getOrPut(testing.allocator, testKey(12));
    try testing.expectEqual(@as(Handle, 5), z.handle);
}

test "a slot's generation wraps after 512 reuses and its handles stay positive" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);
    const first = (try r.getOrPut(testing.allocator, testKey(0))).handle;
    var h = first;
    for (0..(1 << GENERATION_BITS) - 1) |_| {
        _ = r.remove(h);
        const next = (try r.getOrPut(testing.allocator, testKey(0))).handle;
        try testing.expect(next > 0 and next != h);
        h = next;
    }
    try testing.expectEqual(@as(Handle, std.math.maxInt(Handle)) & ~@as(Handle, MAX_ENTRIES) | 1, h);
    _ = r.remove(h);
    try testing.expectEqual(first, (try r.getOrPut(testing.allocator, testKey(0))).handle);
}

test "getOrPut stops at the limit; a removal makes room" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);
    r.limit = 2;
    const a = try r.getOrPut(testing.allocator, testKey(1));
    _ = try r.getOrPut(testing.allocator, testKey(2));
    try testing.expectError(error.OutOfHandles, r.getOrPut(testing.allocator, testKey(3)));
    // An existing key is still found.
    try testing.expect((try r.getOrPut(testing.allocator, testKey(2))).found_existing);
    _ = r.remove(a.handle);
    _ = try r.getOrPut(testing.allocator, testKey(3));
}

test "iterator visits live entries" {
    var r: TestRegistry = .empty;
    defer r.deinit(testing.allocator);
    for (0..5) |i| (try r.getOrPut(testing.allocator, testKey(@intCast(i)))).value.* = @intCast(i);
    _ = r.remove(r.handleOfKey(testKey(1)).?);
    _ = r.remove(r.handleOfKey(testKey(3)).?);
    var sum: u32 = 0;
    var n: usize = 0;
    var it = r.iterator();
    while (it.next()) |e| {
        try testing.expectEqual(e.handle, r.handleOfKey(e.key.*).?);
        sum += e.value.*;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(u32, 0 + 2 + 4), sum);
}

fn putThree(alloc: std.mem.Allocator) !void {
    var r: TestRegistry = .empty;
    defer r.deinit(alloc);
    for (0..3) |i| {
        const e = try r.getOrPut(alloc, testKey(@intCast(i)));
        e.value.* = @intCast(i);
    }
    _ = r.remove(r.handleOfKey(testKey(0)).?);
    const e = try r.getOrPut(alloc, testKey(9));
    e.value.* = 9;
    try testing.expectEqual(@as(u32, 3), r.count());
    try testing.expectEqual(r.count(), r.index.count());
}

test "an allocation failure leaves the registry consistent" {
    try testing.checkAllAllocationFailures(testing.allocator, putThree, .{});
}
