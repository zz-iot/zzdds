//! Bounds a queue of received data, by records and by bytes, in aggregate
//! and per peer (docs/design/concurrency/runtime.md#ingress). No peer holds
//! more than three quarters of either bound, so a peer with nothing queued
//! always finds room. Below half of both, anyone is admitted otherwise; past
//! it, a peer is admitted only within its fair share, the bounds divided
//! among the peers with data queued, so one peer cannot crowd out the rest.
//!
//! Peers are told apart by a key the caller gives, hashed into a fixed table
//! of buckets: peers sharing a bucket share a share, and nothing is allocated
//! per peer. `peerKey` is the usual key. A stream that cannot be admitted
//! waits for room with a `RoomWaiter`.

const std = @import("std");
const iface = @import("interface.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const Locator = iface.Locator;
const RoomWaiter = iface.RoomWaiter;

pub const IngressBudget = struct {
    pub const bucket_count = 32;

    record_limit: u32,
    byte_limit: usize,
    mu: Mutex = .{},
    // Guarded by `mu`.
    records: u32 = 0,
    bytes: usize = 0,
    buckets: [bucket_count]Bucket = @splat(.{}),
    /// Buckets with data queued.
    active: u32 = 0,
    waiters: ?*RoomWaiter = null,

    const Bucket = struct {
        records: u32 = 0,
        bytes: usize = 0,
    };

    /// What one admission took, given back with `release`.
    pub const Admission = struct {
        bucket: u8,
        len: usize,
    };

    pub fn init(record_limit: u32, byte_limit: usize) IngressBudget {
        return .{ .record_limit = record_limit, .byte_limit = byte_limit };
    }

    pub fn deinit(self: *IngressBudget) void {
        self.mu.deinit();
    }

    /// The sender of `raw`: the GuidPrefix in its RTPS header, or, without
    /// one, its source. Read before anything is parsed or authenticated, so
    /// a peer may claim another's; it only shares that peer's share.
    pub fn peerKey(raw: []const u8, src: Locator) u64 {
        if (raw.len >= 20 and std.mem.eql(u8, raw[0..4], "RTPS")) return std.hash.Wyhash.hash(0, raw[8..20]);
        const wire = src.toRtpsWire();
        return std.hash.Wyhash.hash(1, std.mem.asBytes(&wire));
    }

    /// Takes room for `len` bytes from peer `key`, or returns null when
    /// there is none.
    pub fn admit(self: *IngressBudget, key: u64, len: usize) ?Admission {
        const b = bucketOf(key);
        self.mu.lock();
        defer self.mu.unlock();
        if (!self.fitsLocked(b, len)) return null;
        const bucket = &self.buckets[b];
        if (bucket.records == 0) self.active += 1;
        bucket.records += 1;
        bucket.bytes += len;
        self.records += 1;
        self.bytes += len;
        return .{ .bucket = @intCast(b), .len = len };
    }

    /// Gives back what `adm` took, and runs each waiter that now fits.
    pub fn release(self: *IngressBudget, adm: Admission) void {
        self.mu.lock();
        defer self.mu.unlock();
        const bucket = &self.buckets[adm.bucket];
        bucket.records -= 1;
        bucket.bytes -= adm.len;
        if (bucket.records == 0) self.active -= 1;
        self.records -= 1;
        self.bytes -= adm.len;
        self.runWaitersLocked();
    }

    /// Runs `waiter` once `waiter.len` bytes from peer `waiter.key` fit, at
    /// once if they do now. A queued waiter is not queued again.
    pub fn notifyRoom(self: *IngressBudget, waiter: *RoomWaiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!waiter.queued) {
            waiter.next = self.waiters;
            self.waiters = waiter;
            waiter.queued = true;
        }
        self.runWaitersLocked();
    }

    /// Dequeues `waiter`. Once it returns, the waiter is not running and
    /// does not run.
    pub fn cancelRoom(self: *IngressBudget, waiter: *RoomWaiter) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (!waiter.queued) return;
        var link = &self.waiters;
        while (link.*) |w| : (link = &w.next) {
            if (w == waiter) {
                link.* = w.next;
                break;
            }
        }
        waiter.next = null;
        waiter.queued = false;
    }

    /// The most records one peer may hold.
    pub fn maxPeerRecords(self: *const IngressBudget) u32 {
        return self.record_limit / 4 * 3 + self.record_limit % 4 * 3 / 4;
    }

    /// The most bytes one peer may hold: larger data is never admitted.
    pub fn maxPeerBytes(self: *const IngressBudget) usize {
        return self.byte_limit / 4 * 3 + self.byte_limit % 4 * 3 / 4;
    }

    /// Records queued now, for diagnostics and tests.
    pub fn queuedRecords(self: *IngressBudget) u32 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.records;
    }

    /// Bytes queued now, for diagnostics and tests.
    pub fn queuedBytes(self: *IngressBudget) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.bytes;
    }

    fn bucketOf(key: u64) usize {
        return @intCast(key % bucket_count);
    }

    fn fitsLocked(self: *const IngressBudget, b: usize, len: usize) bool {
        if (self.records >= self.record_limit or self.bytes + len > self.byte_limit) return false;
        const bucket = &self.buckets[b];
        // A quarter stays for peers with nothing queued.
        if (bucket.records + 1 > self.maxPeerRecords() or bucket.bytes + len > self.maxPeerBytes()) return false;
        const records = self.records + 1;
        const bytes = self.bytes + len;
        if (records * 2 <= self.record_limit and bytes * 2 <= self.byte_limit) return true;
        const peers: usize = self.active + @intFromBool(bucket.records == 0);
        return (bucket.records + 1) * peers <= self.record_limit and
            (bucket.bytes + len) * peers <= self.byte_limit;
    }

    fn runWaitersLocked(self: *IngressBudget) void {
        var link = &self.waiters;
        while (link.*) |w| {
            if (!self.fitsLocked(bucketOf(w.key), w.len)) {
                link = &w.next;
                continue;
            }
            link.* = w.next;
            w.next = null;
            w.queued = false;
            w.on_room(w);
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Keys landing in distinct buckets.
const key_a: u64 = 1;
const key_b: u64 = 2;
const key_c: u64 = 3;

test "a lone peer has three quarters of the queue, and the rest stays for others, by records and by bytes" {
    var budget = IngressBudget.init(8, 1000);
    defer budget.deinit();
    try testing.expectEqual(@as(u32, 6), budget.maxPeerRecords());
    var taken: [6]IngressBudget.Admission = undefined;
    for (&taken) |*t| t.* = budget.admit(key_a, 10).?;
    try testing.expectEqual(@as(?IngressBudget.Admission, null), budget.admit(key_a, 10));
    // A peer with nothing queued finds room, up to the aggregate bound.
    _ = budget.admit(key_b, 10).?;
    _ = budget.admit(key_b, 10).?;
    try testing.expectEqual(@as(?IngressBudget.Admission, null), budget.admit(key_c, 10));
    budget.release(taken[0]);
    _ = budget.admit(key_c, 10).?;

    var bytes = IngressBudget.init(100, 1000);
    defer bytes.deinit();
    try testing.expectEqual(@as(usize, 750), bytes.maxPeerBytes());
    _ = bytes.admit(key_a, 700).?;
    try testing.expectEqual(@as(?IngressBudget.Admission, null), bytes.admit(key_a, 51));
    _ = bytes.admit(key_a, 50).?;
    _ = bytes.admit(key_b, 250).?;
    try testing.expectEqual(@as(usize, 1000), bytes.queuedBytes());
}

test "past half the queue, a peer over its fair share is refused while another is admitted" {
    var budget = IngressBudget.init(12, 1_000_000);
    defer budget.deinit();
    // A takes half, freely.
    for (0..6) |_| _ = budget.admit(key_a, 1).?;
    // B arrives: two peers share 12, so A may hold 6 and no more.
    _ = budget.admit(key_b, 1).?;
    try testing.expectEqual(@as(?IngressBudget.Admission, null), budget.admit(key_a, 1));
    for (0..5) |_| _ = budget.admit(key_b, 1).?;
    try testing.expectEqual(@as(?IngressBudget.Admission, null), budget.admit(key_b, 1));
    try testing.expectEqual(@as(u32, 12), budget.queuedRecords());

    // By bytes too: A holds most of the bytes once B has some queued.
    var bytes = IngressBudget.init(1000, 1000);
    defer bytes.deinit();
    _ = bytes.admit(key_a, 500).?;
    _ = bytes.admit(key_c, 10).?;
    try testing.expectEqual(@as(?IngressBudget.Admission, null), bytes.admit(key_a, 1));
    _ = bytes.admit(key_c, 400).?;
}

/// Counts the runs of its waiter.
const Room = struct {
    waiter: RoomWaiter = .{ .on_room = run },
    runs: u32 = 0,

    fn run(w: *RoomWaiter) void {
        const self: *Room = @fieldParentPtr("waiter", w);
        self.runs += 1;
    }
};

test "a waiter runs once its own data fits, and not before" {
    var budget = IngressBudget.init(4, 1_000_000);
    defer budget.deinit();
    var held: [4]IngressBudget.Admission = undefined;
    held[0] = budget.admit(key_a, 1).?;
    held[1] = budget.admit(key_a, 1).?;
    held[2] = budget.admit(key_b, 1).?;
    held[3] = budget.admit(key_b, 1).?;

    // A waits for room for one more of its own.
    var r: Room = .{};
    r.waiter.key = key_a;
    r.waiter.len = 1;
    budget.notifyRoom(&r.waiter);
    try testing.expectEqual(@as(u32, 0), r.runs);
    // B's release leaves A at its fair share of two peers: still no room.
    budget.release(held[2]);
    try testing.expectEqual(@as(u32, 0), r.runs);
    // A's own release makes room.
    budget.release(held[0]);
    try testing.expectEqual(@as(u32, 1), r.runs);
    try testing.expect(!r.waiter.queued);

    // With room now, it runs at once; cancelled, it never runs.
    budget.notifyRoom(&r.waiter);
    try testing.expectEqual(@as(u32, 2), r.runs);
    _ = budget.admit(key_a, 1).?;
    budget.notifyRoom(&r.waiter);
    try testing.expect(r.waiter.queued);
    budget.cancelRoom(&r.waiter);
    budget.release(held[1]);
    try testing.expectEqual(@as(u32, 2), r.runs);
}

test "the peer key is the RTPS header's GuidPrefix, or the source without one" {
    var msg: [20]u8 = undefined;
    @memcpy(msg[0..4], "RTPS");
    msg[4..8].* = .{ 2, 5, 0x01, 0x0f };
    for (msg[8..20], 0..) |*b, i| b.* = @intCast(i);
    const here = Locator.udp4(.{ 10, 0, 0, 1 }, 7410);
    const there = Locator.udp4(.{ 10, 0, 0, 2 }, 7412);
    // The same participant from any source.
    try testing.expectEqual(IngressBudget.peerKey(&msg, here), IngressBudget.peerKey(&msg, there));
    var other = msg;
    other[19] ^= 0xff;
    try testing.expect(IngressBudget.peerKey(&msg, here) != IngressBudget.peerKey(&other, here));
    // Not RTPS: told apart by source.
    try testing.expectEqual(IngressBudget.peerKey("hello", here), IngressBudget.peerKey("other", here));
    try testing.expect(IngressBudget.peerKey("hello", here) != IngressBudget.peerKey("hello", there));
}
