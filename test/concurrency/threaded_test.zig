//! Hosted POSIX experiment. Explicit condition checkpoints, no sleep polling.
const std = @import("std");
const builtin = @import("builtin");
const Mutex = @import("host_mutex").Mutex;
const p = @import("prototype.zig");
const testing = std.testing;
const IdleDriver = @import("idle_driver.zig").Driver;

const Checkpoint = struct {
    mu: Mutex = .{},
    cv: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
    arrived: usize = 0,
    released: bool = false,
    seen: [2]bool = .{false} ** 2,
    kind: p.Checkpoint,

    fn deinit(self: *@This()) void {
        if (std.c.pthread_cond_destroy(&self.cv) != .SUCCESS) @panic("condition destruction failed");
        self.mu.deinit();
    }
    fn wait(self: *@This()) void {
        var deadline: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.REALTIME, &deadline);
        deadline.sec += 10; // Failure watchdog, not scheduling control.
        const rc = std.c.pthread_cond_timedwait(&self.cv, &self.mu.inner, &deadline);
        if (rc != .SUCCESS) @panic("concurrency checkpoint watchdog expired");
    }
    fn hook(ctx: *anyopaque, kind: p.Checkpoint, id: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (kind != self.kind) return;
        self.mu.lock();
        defer self.mu.unlock();
        if (self.seen[id]) return;
        self.seen[id] = true;
        self.arrived += 1;
        if (std.c.pthread_cond_broadcast(&self.cv) != .SUCCESS) @panic("condition broadcast failed");
        while (!self.released) self.wait();
    }
    fn waitFor(self: *@This(), count: usize) void {
        self.mu.lock();
        defer self.mu.unlock();
        while (self.arrived < count) self.wait();
    }
    fn release(self: *@This()) void {
        self.mu.lock();
        self.released = true;
        if (std.c.pthread_cond_broadcast(&self.cv) != .SUCCESS) @panic("condition broadcast failed");
        self.mu.unlock();
    }
};

fn drive(e: *p.Engine) void {
    e.drain() catch @panic("driver budget exceeded");
}

test "two actual executors overlap independent writer turns" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(2, 4);
    defer e.deinit();
    var checkpoint = Checkpoint{ .kind = .writer_claimed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    _ = try e.submit(0, 0, 10);
    _ = try e.submit(1, 0, 20);
    const a = try std.Thread.spawn(.{}, drive, .{&e});
    const b = std.Thread.spawn(.{}, drive, .{&e}) catch |err| {
        checkpoint.release();
        a.join();
        return err;
    };
    checkpoint.waitFor(2); // Would time out if one global lock covered turns.
    checkpoint.release();
    a.join();
    b.join();
    try e.drain();
    try testing.expectEqual(@as(usize, 2), e.installed_len);
    try testing.expectEqual(@as(usize, 1), e.installed[0].gsn);
    try testing.expectEqual(@as(usize, 2), e.installed[1].gsn);
}

test "cancellation loses after commit claim and close waits for installation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(2, 3);
    defer e.deinit();
    var checkpoint = Checkpoint{ .kind = .commit_claimed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const id = try e.submit(0, 0, 10);
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1);
    const cancelled = e.cancel(id);
    e.beginClose();
    // Worker is parked after the irrevocable claim. Main can access admission
    // metadata but must not inspect unprotected installed history yet.
    e.mu.lock();
    const closing = e.closing;
    const outstanding = e.outstanding;
    e.mu.unlock();
    checkpoint.release();
    worker.join();
    try e.drain();
    try testing.expect(!cancelled and closing);
    try testing.expectEqual(@as(usize, 1), outstanding);
    try testing.expectEqual(@as(usize, 1), e.installed_len);
    try testing.expect(!e.closing);
}

test "idle worker wakes for later submission and empty shutdown" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(2, 3);
    defer e.deinit();
    var driver = IdleDriver{ .engine = &e };
    driver.attach();
    defer driver.deinit();
    const worker = try std.Thread.spawn(.{}, IdleDriver.run, .{&driver});
    defer {
        e.startShutdown();
        worker.join();
    }
    driver.waitParked(1);
    const id = try e.submit(0, 0, 42);
    driver.waitFinished(id);
    // The final state is release-published before finished becomes observable.
    try testing.expectEqual(p.Effect.committed, e.req[id].effect.load(.acquire));
    driver.waitParked(2);
}

test "two idle workers drain shutdown while history capacity is unavailable" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(2, 1);
    defer e.deinit();
    var driver = IdleDriver{ .engine = &e };
    driver.attach();
    defer driver.deinit();
    // Publication before any worker waits exercises the predicate-recheck path.
    const committed = try e.submit(0, 0, 10);
    const a = std.Thread.spawn(.{}, IdleDriver.run, .{&driver}) catch |err| {
        e.startShutdown();
        try e.drain();
        return err;
    };
    const b = std.Thread.spawn(.{}, IdleDriver.run, .{&driver}) catch |err| {
        e.startShutdown();
        a.join();
        return err;
    };
    defer {
        e.startShutdown();
        a.join();
        b.join();
    }
    driver.waitFinished(committed);
    const blocked = try e.submit(0, 0, 20);
    e.startShutdown();
    driver.waitFinished(blocked);
    try testing.expectEqual(p.Effect.cancelled, e.req[blocked].effect.load(.acquire));
}

test "submission between empty observation and sleep is found by recheck" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    var checkpoint = Checkpoint{ .kind = .idle_observed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    var driver = IdleDriver{ .engine = &e };
    driver.attach();
    defer driver.deinit();
    const worker = try std.Thread.spawn(.{}, IdleDriver.run, .{&driver});
    defer {
        checkpoint.release();
        e.startShutdown();
        worker.join();
    }
    checkpoint.waitFor(1);
    const id = try e.submit(1, 1, 99); // Signal precedes worker's condition wait.
    checkpoint.release();
    driver.waitFinished(id);
    try testing.expectEqual(p.Effect.committed, e.req[id].effect.load(.acquire));
}

test "deadline recheck prevents commit when timer dispatch is delayed" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    const id = try e.submitUntil(0, 0, 42, 10);
    try testing.expect(e.driveOne()); // Entitlement and commit event published.
    var checkpoint = Checkpoint{ .kind = .writer_claimed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1); // Scheduler checked timers before this pause.
    e.advanceTime(10) catch unreachable;
    checkpoint.release();
    worker.join();
    try testing.expectEqual(p.Effect.timed_out, e.req[id].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 0), e.installed_len);
    try testing.expectEqual(@as(usize, 0), e.allocated);
}

test "expiry after irrevocable claim cannot report timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    var checkpoint = Checkpoint{ .kind = .commit_claimed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const id = try e.submitUntil(0, 0, 42, 10);
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1);
    e.advanceTime(10) catch unreachable;
    const next = e.nextDeadline();
    const progressed = e.driveOne(); // Service timers while installation paused.
    checkpoint.release();
    worker.join();
    try testing.expect(!progressed);
    try testing.expectEqual(@as(?u64, null), next);
    try testing.expectEqual(p.Effect.committed, e.req[id].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 1), e.installed_len);
}

test "time publication wakes idle worker to expire capacity waiter" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 0);
    defer e.deinit();
    var driver = IdleDriver{ .engine = &e };
    driver.attach();
    defer driver.deinit();
    const id = try e.submitUntil(0, 0, 42, 10);
    const worker = try std.Thread.spawn(.{}, IdleDriver.run, .{&driver});
    defer {
        e.startShutdown();
        worker.join();
    }
    driver.waitParked(1);
    try e.advanceTime(10);
    driver.waitFinished(id);
    try testing.expectEqual(p.Effect.timed_out, e.req[id].effect.load(.acquire));
}

test "snapshot cannot observe partially installed progress across executors" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    var checkpoint = Checkpoint{ .kind = .commit_partial };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const id = try e.submit(0, 0, 42);
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1); // Count updated, corresponding last sample not yet published.
    const snap = e.submitSnapshot(1) catch unreachable;
    const progressed = e.driveOne();
    checkpoint.release();
    worker.join();
    try e.drain();
    try testing.expect(!progressed);
    const result = e.req[snap].snapshot.?;
    try testing.expectEqual(@as(usize, 1), result.installed_count);
    try testing.expectEqual(id, result.last.?.request);
    try testing.expectEqual(result.installed_count, result.last.?.gsn);
}

test "last pin release during installation defers free until gate is released" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    try e.drain();
    const pin = try e.pinHistory(0, 0);
    _ = try e.submit(0, 0, 20);
    var checkpoint = Checkpoint{ .kind = .commit_partial };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1);
    const removal = e.removeHistory(0, 0);
    e.releasePin(pin) catch unreachable;
    e.mu.lock();
    const frees_during_gate = e.frees;
    e.mu.unlock();
    checkpoint.release();
    worker.join();
    try testing.expectError(error.Busy, removal);
    try testing.expectEqual(@as(usize, 0), frees_during_gate);
    try testing.expectEqual(@as(usize, 1), e.frees);
    try testing.expectEqual(@as(usize, 1), e.allocated);
}

test "pin reclamation wakes idle worker waiting on physical storage" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    try e.drain();
    const pin = try e.pinHistory(0, 0);
    try e.removeHistory(0, 0);
    const waiting = try e.submit(1, 0, 20);
    var driver = IdleDriver{ .engine = &e };
    driver.attach();
    defer driver.deinit();
    const worker = try std.Thread.spawn(.{}, IdleDriver.run, .{&driver});
    defer {
        e.startShutdown();
        worker.join();
    }
    driver.waitParked(1);
    try e.releasePin(pin);
    driver.waitFinished(waiting);
    try testing.expectEqual(p.Effect.committed, e.req[waiting].effect.load(.acquire));
}

const LifetimePool = @import("lifetime_pool.zig");
const PoppedOwner = struct {
    pool: *LifetimePool.Pool,
    event: LifetimePool.EventHandle,
    checkpoint: *Checkpoint,
    delivered: bool = true,
    fn run(self: *@This()) void {
        self.pool.pop(self.event) catch @panic("pop failed");
        Checkpoint.hook(self.checkpoint, .writer_claimed, 0);
        self.delivered = self.pool.consume(self.event) catch @panic("consume failed");
    }
};

test "pool executor retains popped request across concurrent completion and release" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var pool = LifetimePool.Pool{};
    defer pool.deinit();
    const a = try pool.admit();
    const b = try pool.admit();
    const event = try pool.post(a);
    var checkpoint = Checkpoint{ .kind = .writer_claimed };
    defer checkpoint.deinit();
    var owner = PoppedOwner{ .pool = &pool, .event = event, .checkpoint = &checkpoint };
    const worker = try std.Thread.spawn(.{}, PoppedOwner.run, .{&owner});
    checkpoint.waitFor(1);
    pool.complete(a, 42) catch unreachable;
    pool.releaseObserver(a) catch unreachable;
    const admission = pool.admit();
    checkpoint.release();
    worker.join();
    try testing.expectError(error.RequestCapacity, admission);
    try testing.expect(!owner.delivered);
    const reused = try pool.admit();
    try testing.expectEqual(a.slot, reused.slot);
    try testing.expectError(error.StaleHandle, pool.retainObserver(a));
    try pool.complete(b, 0);
    try pool.releaseObserver(b);
    try pool.complete(reused, 0);
    try pool.releaseObserver(reused);
}

test "integrated gate tombstone retains completed request until unlink" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    const b = try e.submit(1, 0, 20);
    try testing.expect(e.driveOne());
    try testing.expect(e.driveOne()); // B queued behind A's entitlement.
    var checkpoint = Checkpoint{ .kind = .commit_claimed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1);
    const cancelled = e.cancel(b);
    e.releaseObserver(b) catch unreachable;
    const cleanup = e.driveOne(); // B retires while A holds the gate.
    const retained = e.ownership(b);
    const audit = e.auditOwnership();
    checkpoint.release();
    worker.join();
    try e.drain();
    try audit;
    try testing.expect(cancelled and cleanup);
    try testing.expectEqual(@as(usize, 1), retained.refs);
    try testing.expect(retained.gate and !retained.root);
    try testing.expectEqual(@as(usize, 0), retained.queued + retained.executing + retained.observers);
    try testing.expectEqual(@as(usize, 0), e.ownership(b).refs);
    try e.auditOwnership();
}

test "integrated popped event keeps ownership during concurrent cancellation" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    const id = try e.submit(0, 0, 10);
    var checkpoint = Checkpoint{ .kind = .writer_claimed };
    defer checkpoint.deinit();
    e.hook = .{ .ctx = &checkpoint, .call = Checkpoint.hook };
    const worker = try std.Thread.spawn(.{}, drive, .{&e});
    checkpoint.waitFor(1);
    const cancelled = e.cancel(id);
    e.releaseObserver(id) catch unreachable;
    const retained = e.ownership(id);
    const audit = e.auditOwnership();
    checkpoint.release();
    worker.join();
    try e.drain();
    try audit;
    try testing.expect(cancelled);
    try testing.expectEqual(@as(usize, 1), retained.executing);
    try testing.expectEqual(@as(usize, 1), retained.queued); // Reserved cleanup.
    try testing.expectEqual(@as(usize, 3), retained.refs); // Plus operation root.
    try testing.expectEqual(@as(usize, 0), e.ownership(id).refs);
    try testing.expectEqual(@as(usize, 0), e.installed_len);
}
