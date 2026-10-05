//! Work handed over under one lock and processed later, in order, with no
//! lock held while processing.
//!
//! The built-in discovery readers (SEDP, WLP) receive under their protocol
//! reader's lock, but processing reaches application listeners, which must
//! not run under any zzdds lock. They push under the reader's lock and drain
//! once it is released. One caller drains at a time, which keeps items in
//! arrival order; a drain that starts while another is running (on another
//! thread, or re-entrantly from inside `process`, e.g. a listener whose
//! endpoint creation is delivered straight back to this reader) returns at
//! once, leaving its items to the running drain.

const std = @import("std");
const Mutex = @import("mutex.zig").Mutex;

pub fn DrainQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        mu: Mutex = .{},
        items: std.ArrayListUnmanaged(T) = .empty,
        draining: bool = false,

        /// Frees the queue's storage. Items still queued are passed to
        /// `ctx.discard(item)` first, so the caller can free what they own.
        pub fn deinit(self: *Self, alloc: std.mem.Allocator, ctx: anytype) void {
            for (self.items.items) |item| ctx.discard(item);
            self.items.deinit(alloc);
        }

        pub fn push(self: *Self, alloc: std.mem.Allocator, item: T) error{OutOfMemory}!void {
            self.mu.lock();
            defer self.mu.unlock();
            try self.items.append(alloc, item);
        }

        /// Calls `ctx.process(item)` for every queued item, in order, with no
        /// lock held, including items pushed meanwhile. Returns at once if a
        /// drain is already running; that drain processes them.
        pub fn drain(self: *Self, alloc: std.mem.Allocator, ctx: anytype) void {
            self.mu.lock();
            if (self.draining) {
                self.mu.unlock();
                return;
            }
            self.draining = true;
            while (self.items.items.len > 0) {
                var batch = self.items;
                self.items = .empty;
                self.mu.unlock();
                for (batch.items) |item| ctx.process(item);
                batch.deinit(alloc);
                self.mu.lock();
            }
            self.draining = false;
            self.mu.unlock();
        }
    };
}

const testing = std.testing;

test "DrainQueue: in order, with a re-entrant drain left to the running one" {
    const Q = DrainQueue(u32);
    const Ctx = struct {
        q: *Q,
        seen: std.ArrayListUnmanaged(u32) = .empty,
        fn process(self: *@This(), item: u32) void {
            self.seen.append(testing.allocator, item) catch unreachable;
            if (item == 1) {
                // As a listener whose action is delivered straight back:
                // queue more and drain re-entrantly. Must not deadlock, and
                // must not run 10 before 2.
                self.q.push(testing.allocator, 10) catch unreachable;
                self.q.drain(testing.allocator, self);
                self.seen.append(testing.allocator, 99) catch unreachable;
            }
        }
        fn discard(_: *@This(), _: u32) void {}
    };
    var q: Q = .{};
    var ctx = Ctx{ .q = &q };
    defer ctx.seen.deinit(testing.allocator);
    defer q.deinit(testing.allocator, &ctx);

    try q.push(testing.allocator, 1);
    try q.push(testing.allocator, 2);
    q.drain(testing.allocator, &ctx);
    try testing.expectEqualSlices(u32, &.{ 1, 99, 2, 10 }, ctx.seen.items);

    q.drain(testing.allocator, &ctx); // empty: nothing
    try testing.expectEqual(@as(usize, 4), ctx.seen.items.len);
}

test "DrainQueue: deinit discards what is still queued" {
    const Q = DrainQueue(u32);
    const Ctx = struct {
        discarded: u32 = 0,
        fn process(_: *@This(), _: u32) void {}
        fn discard(self: *@This(), item: u32) void {
            self.discarded += item;
        }
    };
    var q: Q = .{};
    var ctx = Ctx{};
    try q.push(testing.allocator, 3);
    try q.push(testing.allocator, 4);
    q.deinit(testing.allocator, &ctx);
    try testing.expectEqual(@as(u32, 7), ctx.discarded);
}
