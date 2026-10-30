//! Slots that give a transport's sockets and connections their `Channel`
//! identity (docs/design/concurrency/transport-adapters.md#channels-and-lifetimes).
//!
//! A channel names a slot and that slot's generation. The owner holds one
//! reference from `insert` until `close`; anything else that uses the item
//! outside the owner's lock (a send on a channel) holds its own, from
//! `acquire` to `release`. A closed slot fails `acquire`, and once its last
//! reference is gone the caller that dropped it gets the item back to free,
//! and the slot's generation moves on before it is reused. So a stale
//! channel fails with `ChannelClosed` instead of reaching a freed item, and
//! closed items are freed instead of being kept until the transport closes.
//!
//! The table's lock is a leaf: nothing else is locked while it is held.

const std = @import("std");
const Mutex = @import("../util/mutex.zig").Mutex;
const Channel = @import("interface.zig").Channel;

pub fn ChannelTable(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            item: ?*T = null,
            /// Starts at 1, so no channel is `Channel.none`'s.
            generation: u32 = 1,
            refs: u32 = 0,
            open: bool = false,
            next_free: ?u32 = null,
        };

        mu: Mutex = .{},
        slots: std.ArrayListUnmanaged(Slot) = .empty,
        free_head: ?u32 = null,
        live: usize = 0,

        /// Every item must have been closed and released.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            std.debug.assert(self.live == 0);
            self.slots.deinit(alloc);
        }

        /// Gives `item` a slot, with the owner's reference.
        pub fn insert(self: *Self, alloc: std.mem.Allocator, item: *T) error{OutOfMemory}!Channel {
            self.mu.lock();
            defer self.mu.unlock();
            const index: u32 = self.free_head orelse blk: {
                try self.slots.append(alloc, .{});
                break :blk @intCast(self.slots.items.len - 1);
            };
            const s = &self.slots.items[index];
            self.free_head = s.next_free;
            s.* = .{ .item = item, .generation = s.generation, .refs = 1, .open = true };
            self.live += 1;
            return .{ .token = @as(u64, index) + 1, .generation = s.generation };
        }

        /// The item `channel` names, with a reference the caller releases,
        /// or null if the channel is closed or was never this table's.
        pub fn acquire(self: *Self, channel: Channel) ?*T {
            self.mu.lock();
            defer self.mu.unlock();
            const s = &self.slots.items[self.indexLocked(channel) orelse return null];
            if (!s.open) return null;
            s.refs += 1;
            return s.item;
        }

        /// Drops a reference taken by `acquire`. Returns the item when this
        /// was the last reference; the caller frees it.
        pub fn release(self: *Self, channel: Channel) ?*T {
            self.mu.lock();
            defer self.mu.unlock();
            return self.unrefLocked(self.indexLocked(channel).?);
        }

        /// Closes the slot, so `acquire` fails, and drops the owner's
        /// reference. Returns the item when no other reference remains; the
        /// caller frees it. Otherwise the last `release` returns it.
        pub fn close(self: *Self, channel: Channel) ?*T {
            self.mu.lock();
            defer self.mu.unlock();
            const index = self.indexLocked(channel).?;
            const s = &self.slots.items[index];
            std.debug.assert(s.open);
            s.open = false;
            return self.unrefLocked(index);
        }

        /// Calls `f(ctx, item)` for every open item, under the table's lock.
        pub fn forEachOpen(self: *Self, ctx: anytype, comptime f: fn (@TypeOf(ctx), *T) void) void {
            self.mu.lock();
            defer self.mu.unlock();
            for (self.slots.items) |s| {
                if (s.open) f(ctx, s.item.?);
            }
        }

        /// Items not yet freed: open, or closed with references outstanding.
        pub fn liveCount(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.live;
        }

        /// Slots ever made. Grows only while every slot is in use.
        pub fn slotCount(self: *Self) usize {
            self.mu.lock();
            defer self.mu.unlock();
            return self.slots.items.len;
        }

        fn indexLocked(self: *Self, channel: Channel) ?u32 {
            if (channel.token == 0 or channel.token > self.slots.items.len) return null;
            const index: u32 = @intCast(channel.token - 1);
            const s = &self.slots.items[index];
            if (s.item == null or s.generation != channel.generation) return null;
            return index;
        }

        fn unrefLocked(self: *Self, index: u32) ?*T {
            const s = &self.slots.items[index];
            std.debug.assert(s.refs > 0);
            s.refs -= 1;
            if (s.refs > 0) return null;
            std.debug.assert(!s.open);
            const item = s.item.?;
            s.* = .{ .generation = s.generation +% 1, .next_free = self.free_head };
            if (s.generation == 0) s.generation = 1;
            self.free_head = index;
            self.live -= 1;
            return item;
        }
    };
}

test "a closed slot is reused only after its last reference, with a new generation" {
    const alloc = std.testing.allocator;
    var table: ChannelTable(u32) = .{};
    defer table.deinit(alloc);
    var a: u32 = 1;
    var b: u32 = 2;

    const ca = try table.insert(alloc, &a);
    try std.testing.expectEqual(&a, table.acquire(ca).?);
    try std.testing.expect(table.close(ca) == null);
    try std.testing.expect(table.acquire(ca) == null);
    try std.testing.expectEqual(@as(usize, 1), table.liveCount());

    // The slot is still referenced, so b gets a new one.
    const cb = try table.insert(alloc, &b);
    try std.testing.expect(cb.token != ca.token);
    try std.testing.expectEqual(&a, table.release(ca).?);

    // Now a's slot is free: reused, under a generation a's channel does not match.
    const ca2 = try table.insert(alloc, &a);
    try std.testing.expectEqual(ca.token, ca2.token);
    try std.testing.expect(ca2.generation != ca.generation);
    try std.testing.expect(table.acquire(ca) == null);
    try std.testing.expectEqual(&a, table.acquire(ca2).?);
    try std.testing.expect(table.release(ca2) == null);
    try std.testing.expectEqual(@as(usize, 2), table.slotCount());

    try std.testing.expectEqual(&a, table.close(ca2).?);
    try std.testing.expectEqual(&b, table.close(cb).?);
    try std.testing.expectEqual(@as(usize, 0), table.liveCount());
}

test "acquire refuses Channel.none and tokens past the table" {
    const alloc = std.testing.allocator;
    var table: ChannelTable(u32) = .{};
    defer table.deinit(alloc);
    var a: u32 = 1;
    const ca = try table.insert(alloc, &a);
    try std.testing.expect(table.acquire(Channel.none) == null);
    try std.testing.expect(table.acquire(.{ .token = ca.token + 1, .generation = ca.generation }) == null);
    try std.testing.expectEqual(&a, table.close(ca).?);
}
