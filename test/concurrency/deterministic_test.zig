const std = @import("std");
const p = @import("prototype.zig");
const testing = std.testing;

test "default one limits same-instance preparation but not sibling instance" {
    var e = p.Engine.init(1, 4);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    const b = try e.submit(0, 0, 20);
    const c = try e.submit(0, 1, 30);
    try testing.expect(e.req[a].prepared);
    try testing.expect(!e.req[b].prepared);
    try testing.expect(e.req[c].prepared);
    try e.drain();
    try testing.expectEqual(@as(usize, 3), e.installed_len);
    try testing.expectEqual(@as(usize, 2), e.allocated);
    try testing.expect(e.turns < 20);
}

test "limit two prepares successors but only instance head receives ticket" {
    var e = p.Engine.init(2, 4);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    const b = try e.submit(0, 0, 20);
    const c = try e.submit(1, 0, 30);
    try testing.expect(e.req[a].prepared and e.req[b].prepared);
    try testing.expect(e.driveOne()); // a promoted
    try testing.expect(e.driveOne()); // c promoted
    try testing.expect(e.driveOne()); // b cannot get a ticket
    try testing.expect(!e.req[b].ticket);
    try testing.expect(e.req[c].ticket);
    try e.drain();
    try testing.expectEqual(@as(usize, 3), e.installed_len);
    try testing.expectEqual(a, e.installed[0].request);
    try testing.expectEqual(c, e.installed[1].request);
    try testing.expectEqual(b, e.installed[2].request);
    try testing.expectEqual(@as(usize, 2), e.allocated);
    try testing.expectEqual(@as(usize, 0), e.outstanding);
}

test "cancel entitled predecessor preserves successor and consumes stale wake" {
    var e = p.Engine.init(2, 3);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    const b = try e.submit(0, 0, 20);
    try testing.expect(e.driveOne());
    try testing.expectEqual(a, e.entitled);
    try testing.expect(e.cancel(a));
    try testing.expect(!e.cancel(a));
    try e.drain();
    try testing.expectEqual(@as(usize, 1), e.installed_len);
    try testing.expectEqual(b, e.installed[0].request);
    try testing.expect(e.stale_events > 0);
    try testing.expectEqual(@as(usize, 1), e.allocated);
}

test "coherent close drains ticket and successor enters next generation" {
    var e = p.Engine.init(2, 3);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    const b = try e.submit(0, 0, 20);
    try testing.expect(e.driveOne());
    e.beginClose();
    try testing.expect(e.closing);
    try e.drain();
    try testing.expectEqual(a, e.installed[0].request);
    try testing.expectEqual(@as(usize, 0), e.installed[0].generation);
    try testing.expectEqual(b, e.installed[1].request);
    try testing.expectEqual(@as(usize, 1), e.installed[1].generation);
    try testing.expect(!e.closing);
}

test "physical exhaustion does not discard history and shutdown drains waiters" {
    var e = p.Engine.init(2, 1);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    try e.drain();
    const b = try e.submit(0, 0, 20);
    try testing.expect(!e.req[b].prepared);
    try testing.expectEqual(a, e.history[0][0].?.request);
    e.startShutdown();
    try e.drain();
    try testing.expectEqual(p.Effect.cancelled, e.req[b].effect.load(.acquire));
    try testing.expectEqual(a, e.history[0][0].?.request);
    try testing.expectError(error.Closed, e.submit(1, 0, 30));
}

test "fixed request capacity leaves reserved internal cleanup serviceable" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    for (0..p.capacity) |i| _ = try e.submit(i % 2, 0, i);
    try testing.expectError(error.RequestCapacity, e.submit(0, 0, 100));
    e.startShutdown();
    try e.drain();
    for (e.req[0..e.count]) |*r| try testing.expect(r.finished);
    try testing.expectEqual(@as(usize, 0), e.allocated);
}

test "expiry at entitlement drains close and successor commits without sequence gap" {
    var e = p.Engine.init(2, 3);
    defer e.deinit();
    const a = try e.submitUntil(0, 0, 10, 5);
    const b = try e.submit(0, 0, 20);
    try testing.expect(e.driveOne());
    try testing.expectEqual(a, e.entitled);
    e.beginClose();
    try e.advanceTime(5);
    try e.drain();
    try testing.expectEqual(p.Effect.timed_out, e.req[a].effect.load(.acquire));
    try testing.expect(!e.cancel(a));
    try testing.expectEqual(@as(usize, 1), e.installed_len);
    try testing.expectEqual(b, e.installed[0].request);
    try testing.expectEqual(@as(usize, 1), e.installed[0].gsn);
    try testing.expectEqual(@as(usize, 1), e.installed[0].generation);
    try testing.expectEqual(@as(usize, 1), e.allocated);
    try testing.expectEqual(@as(usize, 0), e.outstanding);
    try testing.expect(e.stale_events > 0);
}

test "expiry needs no history credit and preserves resident data" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    const resident = try e.submit(0, 0, 10);
    try e.drain();
    const blocked = try e.submitUntil(0, 0, 20, 10);
    try testing.expect(!e.req[blocked].prepared);
    try testing.expectEqual(@as(?u64, 10), e.nextDeadline());
    try e.advanceTime(9);
    try e.drain();
    try testing.expectEqual(p.Effect.pending, e.req[blocked].effect.load(.acquire));
    try e.advanceTime(10);
    try e.drain();
    try testing.expectEqual(p.Effect.timed_out, e.req[blocked].effect.load(.acquire));
    try testing.expectEqual(resident, e.history[0][0].?.request);
    try testing.expectEqual(@as(usize, 1), e.allocated);
    try testing.expectEqual(@as(?u64, null), e.nextDeadline());
    try testing.expectError(error.TimeWentBackwards, e.advanceTime(9));
}

test "already due submission and cancellation retain distinct terminal outcomes" {
    var e = p.Engine.init(2, 3);
    defer e.deinit();
    try e.advanceTime(10);
    const due = try e.submitUntil(0, 0, 10, 10);
    const cancelled = try e.submitUntil(1, 0, 20, 11);
    try testing.expect(!e.req[due].prepared);
    try testing.expect(e.cancel(cancelled));
    try e.advanceTime(11);
    try e.drain();
    try testing.expectEqual(p.Effect.timed_out, e.req[due].effect.load(.acquire));
    try testing.expectEqual(p.Effect.cancelled, e.req[cancelled].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 0), e.installed_len);
    try testing.expectEqual(@as(usize, 0), e.allocated);
}

test "expired gate waiter retires ticket without disturbing entitled writer" {
    var e = p.Engine.init(1, 3);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    const b = try e.submitUntil(1, 0, 20, 5);
    try testing.expect(e.driveOne());
    try testing.expect(e.driveOne());
    try testing.expectEqual(a, e.entitled);
    try testing.expect(e.req[b].in_gate);
    try e.advanceTime(5);
    e.beginClose();
    try e.drain();
    try testing.expectEqual(p.Effect.timed_out, e.req[b].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 1), e.installed_len);
    try testing.expectEqual(a, e.installed[0].request);
    try testing.expectEqual(@as(usize, 0), e.outstanding);
    try testing.expectEqual(@as(usize, 1), e.allocated);
    try testing.expect(!e.closing);
}

test "snapshot precedes all later gate admissions under repeated writes" {
    // Exercise every possible position in a saturated burst. Service is bounded
    // by older admissions, independent of how many younger writes are prepared.
    for (0..p.capacity + 1) |older| {
        var e = p.Engine.init(p.capacity, p.capacity);
        defer e.deinit();
        for (0..older) |i| {
            _ = try e.submit(i % p.writers, 0, i);
            try e.drain();
        }
        const snapshot = try e.submitSnapshot(1);
        for (older..p.capacity) |i| _ = try e.submit(i % p.writers, 0, i);
        const start = e.turns;
        while (!e.req[snapshot].finished) {
            try testing.expect(e.driveOne());
            try testing.expect(e.turns - start <= 2);
        }
        try testing.expectEqual(older, e.req[snapshot].snapshot.?.installed_count);
        try e.drain();
        try testing.expectEqual(@as(usize, p.capacity), e.installed_len);
    }
}

test "snapshot between older and younger gate requests sees consistent prefix" {
    var e = p.Engine.init(2, 4);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    try testing.expect(e.driveOne());
    const snap = try e.submitSnapshot(0);
    _ = try e.submit(1, 0, 20);
    try testing.expect(e.driveOne()); // Younger writer joins gate behind snapshot.
    try e.drain();
    const result = e.req[snap].snapshot.?;
    try testing.expectEqual(@as(usize, 1), result.installed_count);
    try testing.expectEqual(a, result.last.?.request);
    try testing.expectEqual(result.installed_count, result.last.?.gsn);
    try testing.expectEqual(@as(usize, 2), e.installed_len);
}

test "reserved snapshots survive write saturation and cancellation releases entitlement" {
    var e = p.Engine.init(1, 0);
    defer e.deinit();
    for (0..p.capacity) |i| _ = try e.submit(i % p.writers, 0, i);
    const cancelled = try e.submitSnapshot(0);
    const next = try e.submitSnapshot(1);
    try testing.expect(e.cancel(cancelled));
    try e.drain();
    try testing.expectEqual(p.Effect.cancelled, e.req[cancelled].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 0), e.req[next].snapshot.?.installed_count);
    try testing.expect(e.req[next].snapshot.?.last == null);
    for (2..p.snapshot_capacity) |_| _ = try e.submitSnapshot(0);
    try testing.expectError(error.SnapshotCapacity, e.submitSnapshot(0));
    e.startShutdown();
    try e.drain();
    try testing.expectEqual(@as(usize, 0), e.outstanding);
    try testing.expectEqual(@as(usize, 0), e.allocated);
}

test "snapshot behind four older commits is not overtaken by twelve younger writes" {
    var e = p.Engine.init(p.capacity, p.capacity);
    defer e.deinit();
    for (0..4) |i| _ = try e.submit(i % 2, i / 2, i);
    for (0..4) |_| try testing.expect(e.driveOne()); // Four head tickets queued.
    try testing.expectEqual(@as(usize, 4), e.outstanding);
    try testing.expectEqual(@as(usize, 0), e.installed_len);
    const snap = try e.submitSnapshot(0);
    for (4..p.capacity) |i| _ = try e.submit(i % 2, (i / 2) % 2, i);
    const start = e.turns;
    while (!e.req[snap].finished) {
        try testing.expect(e.driveOne());
        // Conservative finite workload bound, including older writer-ready work.
        try testing.expect(e.turns - start <= 2 * (p.capacity + 4 + 1));
    }
    try testing.expectEqual(@as(usize, 4), e.req[snap].snapshot.?.installed_count);
    try testing.expectEqual(@as(usize, 4), e.req[snap].snapshot.?.last.?.gsn);
    try e.drain();
    try testing.expectEqual(@as(usize, p.capacity), e.installed_len);
}

test "removed replacement becomes reserved free slot and successor cannot steal it" {
    var e = p.Engine.init(2, 4);
    defer e.deinit();
    const old = try e.submit(0, 0, 10);
    try e.drain();
    const head = try e.submit(0, 0, 20);
    const successor = try e.submit(0, 0, 30);
    try testing.expect(e.driveOne());
    try testing.expectEqual(old, e.history[0][0].?.request);
    try testing.expectEqual(@as(?p.NodeHandle, e.history[0][0].?.node), e.req[head].victim);
    try e.removeHistory(0, 0);
    try testing.expect(e.history[0][0] == null);
    try testing.expect(e.req[head].victim == null);
    try testing.expectEqual(head, e.reservation[0][0]);
    try testing.expect(!e.req[successor].ticket);
    try e.drain();
    try testing.expectEqual(head, e.installed[1].request);
    try testing.expectEqual(successor, e.installed[2].request);
    try testing.expectEqual(@as(usize, 1), e.allocated);
    try testing.expectEqual(p.none, e.reservation[0][0]);
}

test "cancelled replacement preserves live victim and never resurrects removed victim" {
    for ([_]bool{ false, true }) |remove| {
        var e = p.Engine.init(1, 2);
        defer e.deinit();
        const old = try e.submit(0, 0, 10);
        try e.drain();
        const replacement = try e.submit(0, 0, 20);
        try testing.expect(e.driveOne());
        if (remove) try e.removeHistory(0, 0);
        try testing.expect(e.cancel(replacement));
        try e.drain();
        if (remove) {
            try testing.expect(e.history[0][0] == null);
            try testing.expectEqual(@as(usize, 0), e.allocated);
        } else {
            try testing.expectEqual(old, e.history[0][0].?.request);
            try testing.expectEqual(@as(usize, 1), e.allocated);
        }
        try testing.expectEqual(p.none, e.reservation[0][0]);
        try testing.expectEqual(@as(usize, 1), e.installed_len);
    }
}

test "detached pinned payload retains physical credit until final release" {
    var e = p.Engine.init(2, 2);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    try e.drain();
    const first_pin = try e.pinHistory(0, 0);
    const second_pin = try e.pinHistory(0, 0);
    _ = try e.submit(0, 0, 20);
    try testing.expect(e.driveOne());
    try e.removeHistory(0, 0);
    try e.drain();
    try testing.expectEqual(@as(u64, 10), first_pin.payload.*);
    const waiting = try e.submit(1, 0, 30); // Logical slot is empty; physical pool is full.
    try testing.expect(!e.req[waiting].prepared and !e.req[waiting].ticket);
    try e.releasePin(first_pin);
    try testing.expect(!e.req[waiting].prepared);
    try testing.expectEqual(@as(u64, 10), second_pin.payload.*);
    try e.releasePin(second_pin);
    try testing.expect(e.req[waiting].prepared);
    try e.drain();
    try testing.expectEqual(p.Effect.committed, e.req[waiting].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 2), e.allocated);
    try testing.expectEqual(@as(usize, 1), e.frees);
}

test "allocation failure aborts before reservation and preserves resident sample" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    var e = p.Engine.initWithAllocator(failing.allocator(), 2, 3);
    defer e.deinit();
    const old = try e.submit(0, 0, 10);
    try e.drain();
    const failed = try e.submit(0, 0, 20);
    try e.drain();
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(p.Effect.out_of_memory, e.req[failed].effect.load(.acquire));
    try testing.expect(!e.req[failed].prepared and !e.req[failed].ticket);
    try testing.expectEqual(old, e.history[0][0].?.request);
    try testing.expectEqual(@as(usize, 1), e.installed_len);
    try testing.expectEqual(@as(usize, 1), e.allocated);
    failing.fail_index = std.math.maxInt(usize);
    const next = try e.submit(0, 0, 30);
    try e.drain();
    try testing.expectEqual(next, e.history[0][0].?.request);
    try testing.expectEqual(@as(usize, 2), e.history[0][0].?.gsn);
}

test "prepared replacement commits with all subsequent allocations disabled" {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var e = p.Engine.initWithAllocator(failing.allocator(), 1, 2);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    try e.drain();
    const replacement = try e.submit(0, 0, 20);
    try testing.expect(e.driveOne());
    failing.fail_index = failing.alloc_index;
    try e.drain();
    try testing.expect(!failing.has_induced_failure);
    try testing.expectEqual(@as(usize, 2), failing.allocations);
    try testing.expectEqual(@as(usize, 1), failing.deallocations);
    try testing.expectEqual(replacement, e.history[0][0].?.request);
}

test "finished cancellation still retains stale scheduler references" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    const id = try e.submit(0, 0, 10);
    try testing.expect(e.driveOne()); // Entitlement publishes commit continuation.
    try testing.expect(e.cancel(id)); // Cleanup queued behind that continuation.
    try testing.expect(e.driveOne()); // Abort retirement consumes the commit event.
    try testing.expect(e.req[id].finished);
    try testing.expectEqual(@as(usize, 0), e.outstanding);
    try testing.expectEqual(@as(usize, 0), e.allocated);
    try testing.expect(!e.quiescent()); // Finished does not authorize record reuse.
    try e.drain();
    try testing.expect(e.quiescent());
    try testing.expectEqual(@as(usize, 1), e.stale_events);
}

test "shutdown reaches protocol stop while external pin retains detached storage" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    try e.drain();
    const pin = try e.pinHistory(0, 0);
    try e.removeHistory(0, 0);
    const blocked = try e.submit(1, 0, 20);
    e.startShutdown();
    try e.drain();
    try testing.expect(e.stoppedLocked()); // Deterministic driver; no concurrent access.
    try testing.expectEqual(p.Effect.cancelled, e.req[blocked].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 1), e.allocated);
    try testing.expectEqual(@as(u64, 10), pin.payload.*);
    try e.releasePin(pin); // Runtime storage outlives protocol stop.
    try testing.expectEqual(@as(usize, 0), e.allocated);
    try testing.expect(e.stoppedLocked());
}

test "physical release serves oldest eligible waiter before younger independent request" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    _ = try e.submit(0, 0, 10);
    try e.drain();
    const oldest = try e.submit(1, 0, 20);
    const younger = try e.submit(0, 1, 30);
    try e.removeHistory(0, 0);
    try testing.expect(e.req[oldest].prepared);
    try testing.expect(!e.req[younger].prepared);
    try testing.expect(e.cancel(oldest));
    try e.drain();
    try testing.expectEqual(p.Effect.committed, e.req[younger].effect.load(.acquire));
    try testing.expectEqual(@as(usize, 1), e.allocated);
}

test {
    _ = @import("lifetime_pool_test.zig");
}

test "integrated stale event retains request after result and observer retirement" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    const id = try e.submit(0, 0, 10);
    try e.auditOwnership();
    try testing.expect(e.driveOne());
    try e.auditOwnership();
    try testing.expect(e.cancel(id));
    try e.releaseObserver(id);
    try e.auditOwnership();
    try testing.expect(e.driveOne());
    try e.auditOwnership();
    try testing.expect(e.req[id].finished);
    const retained = e.ownership(id);
    try testing.expectEqual(@as(usize, 1), retained.refs);
    try testing.expectEqual(@as(usize, 1), retained.queued);
    try testing.expect(!retained.root and !retained.gate);
    try e.drain();
    try e.auditOwnership();
    try testing.expectEqual(@as(usize, 0), e.ownership(id).refs);
    try testing.expectError(error.Retired, e.retainObserver(id));
}

test "saturated shutdown conserves event and gate ownership on every turn" {
    var e = p.Engine.init(2, 4);
    defer e.deinit();
    for (0..p.capacity) |i| _ = try e.submit(i % p.writers, 0, i);
    for (0..p.snapshot_capacity) |i| _ = try e.submitSnapshot(i % p.writers);
    try e.auditOwnership();
    e.startShutdown();
    for (0..e.count) |id| try e.releaseObserver(id);
    try e.auditOwnership();
    var turns: usize = 0;
    while (e.driveOne()) {
        turns += 1;
        try testing.expect(turns <= 4 * (p.capacity + p.snapshot_capacity));
        try e.auditOwnership();
    }
    for (0..e.count) |id| try testing.expectEqual(@as(usize, 0), e.ownership(id).refs);
    try testing.expect(e.quiescent());
}

test "node slots recycle independently and stale pins cannot release a replacement" {
    var e = p.Engine.init(1, 2);
    defer e.deinit();
    const a = try e.submit(0, 0, 10);
    try e.drain();
    const stale = try e.pinHistory(0, 0);
    try e.releasePin(stale);
    _ = try e.submit(0, 0, 20);
    try e.drain(); // Reclaims A's node, but retains A's request/result.
    const c = try e.submit(0, 0, 30);
    try e.drain();
    const current = try e.pinHistory(0, 0);
    try testing.expectEqual(stale.node.slot, current.node.slot);
    try testing.expect(stale.node.generation != current.node.generation);
    try testing.expect(current.node.slot != c);
    try testing.expectEqual(p.Effect.committed, e.req[a].effect.load(.acquire));
    try testing.expectError(error.StaleHandle, e.releasePin(stale));
    try testing.expectEqual(@as(u64, 30), current.payload.*);
    try e.releasePin(current);
}

test "request handles validate owner generation and liveness under admission lock" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    var other = p.Engine.init(1, 1);
    defer other.deinit();
    const id = try e.submit(0, 0, 10);
    const h = try e.requestHandle(id);
    var obsolete = h;
    obsolete.generation += 1;
    try testing.expectError(error.StaleHandle, e.cancelHandle(obsolete));
    try testing.expectError(error.StaleHandle, other.retainHandle(h));
    try e.retainHandle(h);
    try testing.expect(try e.cancelHandle(h));
    try e.releaseObserver(id);
    try e.releaseObserver(id);
    try e.drain();
    try testing.expectError(error.StaleHandle, e.retainHandle(h));
}

test "ledger and physical admission use order rather than slot position" {
    var e = p.Engine.init(1, 1);
    defer e.deinit();
    const donor = try e.submit(1, 0, 0);
    const later = try e.submit(0, 0, 20);
    const earlier = try e.submit(0, 0, 10);
    // Permute arrival order in a paused fixture to represent reused slot placement.
    // Actual request slots are not recycled by the integrated engine yet.
    e.req[later].order = 2;
    e.req[earlier].order = 1;
    try testing.expect(e.cancel(donor));
    try e.drain();
    try testing.expectEqual(earlier, e.history[0][0].?.request);
    try testing.expect(!e.req[later].prepared);
    try e.removeHistory(0, 0);
    try e.drain();
    try testing.expectEqual(later, e.history[0][0].?.request);
    try testing.expectEqual(earlier, e.installed[0].request);
    try testing.expectEqual(later, e.installed[1].request);
}

test {
    _ = @import("listener_retirement_test.zig");
}
