const std = @import("std");
const p = @import("lifetime_pool.zig");
const t = std.testing;

fn finish(pool: *p.Pool, h: p.RequestHandle) !void {
    try pool.complete(h, 0);
    try pool.releaseObserver(h);
}

test "queued and popped events independently retain completed request" {
    var pool = p.Pool{};
    defer pool.deinit();
    const a = try pool.admit();
    const b = try pool.admit();
    const queued = try pool.post(a);
    const popped = try pool.post(a);
    try pool.pop(popped);
    try finish(&pool, a);
    try t.expectError(error.RequestCapacity, pool.admit());
    try t.expect(!try pool.consume(popped));
    try t.expectError(error.RequestCapacity, pool.admit());
    try pool.pop(queued);
    try t.expect(!try pool.consume(queued));
    const c = try pool.admit();
    try t.expectEqual(a.slot, c.slot);
    try t.expect(a.generation != c.generation);
    try t.expectError(error.StaleHandle, pool.retainObserver(a));
    // Reused lower slot cannot jump ahead of the older higher slot.
    try t.expectEqual(b, pool.head().?);
    try finish(&pool, b);
    try t.expectEqual(c, pool.head().?);
    try finish(&pool, c);
}

test "old wait event cannot alter new wait registration" {
    var pool = p.Pool{};
    defer pool.deinit();
    const a = try pool.admit();
    try t.expectEqual(@as(u8, 1), try pool.registerWait(a));
    const old = try pool.post(a);
    try t.expectEqual(@as(u8, 2), try pool.registerWait(a));
    const current = try pool.post(a);
    try pool.pop(old);
    try t.expect(!try pool.consume(old));
    try t.expectEqual(@as(usize, 0), try pool.deliveries(a));
    try pool.pop(current);
    try t.expect(try pool.consume(current));
    try t.expectEqual(@as(usize, 1), try pool.deliveries(a));
    try finish(&pool, a);
}

test "result observer retains slot independently of completed protocol work" {
    var pool = p.Pool{};
    defer pool.deinit();
    const a = try pool.admit();
    const b = try pool.admit();
    try pool.retainObserver(a);
    try pool.complete(a, 42);
    try pool.releaseObserver(a);
    try t.expectError(error.RequestCapacity, pool.admit());
    try t.expectEqual(@as(u64, 42), try pool.result(a));
    try pool.releaseObserver(a);
    const reused = try pool.admit();
    try t.expectEqual(a.slot, reused.slot);
    try finish(&pool, reused);
    try finish(&pool, b);
}

test "pinned node survives request reuse and deferred reclamation prevents node reuse" {
    var pool = p.Pool{};
    defer pool.deinit();
    const a = try pool.admit();
    const node = try pool.commit(a, 42);
    try pool.pin(node);
    try pool.releaseObserver(a);
    const b = try pool.admit();
    try t.expectEqual(a.slot, b.slot);
    try pool.detach(node);
    try t.expectEqual(@as(u64, 42), try pool.readPin(node));
    const other = try pool.commit(b, 99);
    try pool.releaseObserver(b);
    try pool.releasePin(node);
    const c = try pool.admit();
    try t.expectError(error.NodeCapacity, pool.commit(c, 100));
    try t.expectError(error.Pending, pool.result(c));
    try pool.reclaim(node);
    const reused = try pool.commit(c, 100);
    try t.expectEqual(node.slot, reused.slot);
    try t.expect(node.generation != reused.generation);
    try t.expectError(error.StaleHandle, pool.pin(node));
    try pool.releaseObserver(c);
    try pool.detach(other);
    try pool.reclaim(other);
    try pool.detach(reused);
    try pool.reclaim(reused);
}

test "bounded event and observer admission fails without losing retained ownership" {
    var pool = p.Pool{};
    defer pool.deinit();
    const a = try pool.admit();
    var events: [4]p.EventHandle = undefined;
    for (&events) |*event| event.* = try pool.post(a);
    try t.expectError(error.EventCapacity, pool.post(a));
    for (0..3) |_| try pool.retainObserver(a);
    try t.expectError(error.ObserverCapacity, pool.retainObserver(a));
    try pool.complete(a, 1);
    for (0..4) |_| try pool.releaseObserver(a);
    for (events) |event| {
        try pool.pop(event);
        try t.expect(!try pool.consume(event));
    }
}

test "request and wait generations fail closed at exhaustion" {
    var pool = p.Pool{};
    defer pool.deinit();
    for (0..256) |i| {
        const a = try pool.admit();
        try t.expectEqual(@as(usize, 0), a.slot);
        try t.expectEqual(@as(u8, @intCast(i)), a.generation);
        try finish(&pool, a);
    }
    const last = try pool.admit();
    try t.expectEqual(@as(usize, 1), last.slot);
    for (0..255) |_| _ = try pool.registerWait(last);
    try t.expectError(error.GenerationExhausted, pool.registerWait(last));
    try t.expectError(error.RequestCapacity, pool.admit());
    try finish(&pool, last);
}

test "negative control dropped dequeue reference permits premature reuse" {
    var pool = p.Pool{ .fault = .drop_reference_at_pop };
    defer pool.deinit();
    const a = try pool.admit();
    const event = try pool.post(a);
    try pool.pop(event);
    try finish(&pool, a);
    const b = try pool.admit();
    try t.expectEqual(a.slot, b.slot); // Witness: executor still holds old event.
    try t.expectError(error.DanglingEvent, pool.consume(event));
    try finish(&pool, b);
}

test "negative control missing lookup generation retains unrelated replacement" {
    var pool = p.Pool{ .fault = .ignore_lookup_generation };
    defer pool.deinit();
    const a = try pool.admit();
    try finish(&pool, a);
    const b = try pool.admit();
    try t.expectEqual(a.slot, b.slot);
    try t.expect(a.generation != b.generation);
    try pool.retainObserver(a); // Witness: old handle wrongly acquires B.
    try pool.releaseObserver(b); // Release the incorrectly acquired B reference.
    try finish(&pool, b);
}
