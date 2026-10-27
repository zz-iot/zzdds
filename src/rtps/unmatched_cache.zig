//! Data held for writers that local readers have not matched yet.
//!
//! A writer can send to a reader before the reader has matched it: data
//! can arrive ahead of the writer's discovery announcement, and a
//! TRANSIENT_LOCAL writer sends a reader its history as soon as the writer
//! has matched that reader, whichever side matched first.  An RTPS
//! StatefulReader only takes data from a matched writer, so this one is held
//! here instead, and handed to each reader that then matches the writer,
//! which takes it as if it had arrived just after the match.  Nothing is
//! sent because of it, and a reader gets nothing a matched reader would not
//! have.  It saves a RELIABLE reader a repair round trip, and it is a
//! BEST_EFFORT reader's only way to get that history.
//!
//! One cache serves every reader of a participant, so data sent to all of
//! them (ENTITYID_UNKNOWN) is held once.  The participant decides what is
//! held (data from writers discovery has not yet announced and matched) and
//! when it is dropped (on the writer's announcement, the loss of the writer
//! or its participant, or expiry).  Everything held is bounded by Limits.

const std = @import("std");
const mutex_mod = @import("../util/mutex.zig");
const history_mod = @import("history.zig");
const guid_mod = @import("guid.zig");
const sn_mod = @import("sequence_number.zig");
const time_mod = @import("../util/time.zig");
const msg = @import("message/root.zig");
const reassembly_mod = @import("reassembly.zig");

const CacheChange = history_mod.CacheChange;
const Guid = guid_mod.Guid;
const GuidPrefix = guid_mod.GuidPrefix;
const EntityId = guid_mod.EntityId;
const EntityIds = guid_mod.EntityIds;
const SequenceNumber = sn_mod.SequenceNumber;
const ReassemblyEntry = reassembly_mod.ReassemblyEntry;

pub const Limits = struct {
    /// Bytes held across every writer: samples, plus the full declared size
    /// of each partly reassembled one.  Data that would exceed it is not
    /// held.
    max_bytes: usize,
    /// Writers data is held for at once.  Data from another is not held.
    max_writers: usize,
    /// Samples held per writer.  Past it, the earliest-arrived is dropped
    /// for the new one.
    max_samples_per_writer: usize,
    /// Partly reassembled samples held per writer.  Past it, the
    /// earliest-started is dropped for the new one.
    max_partials_per_writer: usize,
};

/// Computes a sample's key hash from its serialized payload: what a reader
/// uses for a held sample that arrived without PID_KEY_HASH.
pub const KeyHashFn = *const fn (ctx: *anyopaque, payload: []const u8) [16]u8;

/// A newly matched writer's held data, for one reader: passed with the
/// match (protocol.MatchedWriterInfo.prematch) for the reader to collect
/// under its own lock, so it takes the held data before anything the writer
/// sends next.
pub const Prematch = struct {
    cache: *UnmatchedCache,
    /// The reader's key-hash functions, for held samples that arrived
    /// without PID_KEY_HASH: key_hash_fn for an alive sample, and
    /// key_hash_only_fn for a dispose or unregister, whose payload is only
    /// the key.  Without one, the key hash stays zero.
    key_hash_ctx: *anyopaque = undefined,
    key_hash_fn: ?KeyHashFn = null,
    key_hash_only_fn: ?KeyHashFn = null,

    /// Appends copies of what `writer` sent `reader` (directly, or to every
    /// reader) to `out`, leaving the cache as it is: other readers can match
    /// the same writer.
    pub fn collect(self: *const Prematch, alloc: std.mem.Allocator, writer: Guid, reader: EntityId, out: *Collected) !void {
        try self.cache.collect(alloc, writer, reader, out);
        for (out.samples.items, out.sample_has_key_hash.items) |*ch, has| {
            if (has) continue;
            const f = if (ch.kind == .alive) self.key_hash_fn else self.key_hash_only_fn;
            if (f) |kh| ch.key_hash = kh(self.key_hash_ctx, ch.data);
        }
    }
};

/// What UnmatchedCache.collect copies out for one reader.  The caller owns
/// all of it: deinit frees what it has not taken.
pub const Collected = struct {
    /// In SN order, one per SN.
    samples: std.ArrayListUnmanaged(CacheChange) = .empty,
    /// Parallel to `samples`: whether the sample arrived with PID_KEY_HASH.
    sample_has_key_hash: std.ArrayListUnmanaged(bool) = .empty,
    partials: std.ArrayListUnmanaged(Partial) = .empty,

    pub const Partial = struct { sn: SequenceNumber, entry: ReassemblyEntry };

    pub fn deinit(self: *Collected, alloc: std.mem.Allocator) void {
        for (self.samples.items) |ch| alloc.free(ch.data);
        self.samples.deinit(alloc);
        self.sample_has_key_hash.deinit(alloc);
        for (self.partials.items) |*p| p.entry.deinit(alloc);
        self.partials.deinit(alloc);
    }
};

pub const UnmatchedCache = struct {
    alloc: std.mem.Allocator,
    limits: Limits,
    mu: mutex_mod.Mutex = .{},
    writers: std.AutoHashMapUnmanaged(Guid, Writer) = .empty,
    bytes: usize = 0,

    const Self = @This();

    const Sample = struct {
        /// Owns its data.
        change: CacheChange,
        has_key_hash: bool,
        /// The reader it was sent to, or ENTITYID_UNKNOWN for every reader.
        target: EntityId,
        expires_ns: i64,
    };

    const Partial = struct {
        sn: SequenceNumber,
        target: EntityId,
        expires_ns: i64,
        entry: ReassemblyEntry,
    };

    const Writer = struct {
        /// In arrival order.
        samples: std.ArrayListUnmanaged(Sample) = .empty,
        /// In the order they were started.
        partials: std.ArrayListUnmanaged(Partial) = .empty,

        fn isEmpty(self: *const Writer) bool {
            return self.samples.items.len == 0 and self.partials.items.len == 0;
        }
    };

    pub fn init(alloc: std.mem.Allocator, limits: Limits) Self {
        return .{ .alloc = alloc, .limits = limits };
    }

    pub fn deinit(self: *Self) void {
        var it = self.writers.valueIterator();
        while (it.next()) |w| self.freeWriter(w);
        self.writers.deinit(self.alloc);
        self.mu.deinit();
    }

    /// Holds a copy of `change`, from `writer` to `target` (ENTITYID_UNKNOWN
    /// for every reader), until `now_ns + ttl_ns`, unless a limit stops it.
    /// `has_key_hash`: whether the change arrived with PID_KEY_HASH, and
    /// `change.key_hash` is it.
    pub fn put(self: *Self, writer: Guid, target: EntityId, change: *const CacheChange, has_key_hash: bool, now_ns: i64, ttl_ns: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (change.data.len > self.limits.max_bytes) return;
        if (self.writers.getPtr(writer)) |w| {
            for (w.samples.items) |s| {
                if (s.change.sequence_number == change.sequence_number and s.target.eql(target)) return;
            }
        }
        // Before writerLocked: making room can expire writers left with
        // nothing, as a new one is until it gets this.
        if (!self.reserveLocked(change.data.len, now_ns)) return;
        const w = self.writerLocked(writer, now_ns) orelse return;
        defer self.dropIfEmptyLocked(writer);
        const data = self.alloc.dupe(u8, change.data) catch return;
        var held = change.*;
        held.data = data;
        if (!has_key_hash) held.key_hash = std.mem.zeroes([16]u8);
        self.appendSampleLocked(w, .{ .change = held, .has_key_hash = has_key_hash, .target = target, .expires_ns = now_ns + ttl_ns });
    }

    /// Like put, for one DATA_FRAG of a sample from `writer`: held as a
    /// partly reassembled sample, then as a sample once every fragment has
    /// arrived.
    pub fn putFrag(self: *Self, writer: Guid, target: EntityId, df: msg.submessage.DataFragSubmessage, source_timestamp: time_mod.RtpsTimestamp, now_ns: i64, ttl_ns: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        const sn = df.writer_sn;
        if (self.writers.getPtr(writer)) |w| {
            for (w.samples.items) |s| {
                if (s.change.sequence_number == sn and s.target.eql(target)) return;
            }
            for (w.partials.items, 0..) |p, i| {
                if (p.sn == sn and p.target.eql(target)) return self.receiveFragLocked(writer, w, i, df);
            }
        }
        if (df.data_size > self.limits.max_bytes) return;
        // Before writerLocked, as in put.
        if (!self.reserveLocked(df.data_size, now_ns)) return;
        const w = self.writerLocked(writer, now_ns) orelse return;
        defer self.dropIfEmptyLocked(writer);
        if (w.partials.items.len >= self.limits.max_partials_per_writer) {
            var evicted = w.partials.orderedRemove(0);
            self.bytes -= evicted.entry.data_size;
            evicted.entry.deinit(self.alloc);
        }
        const entry = (ReassemblyEntry.init(self.alloc, df, source_timestamp) catch return) orelse return;
        w.partials.append(self.alloc, .{ .sn = sn, .target = target, .expires_ns = now_ns + ttl_ns, .entry = entry }) catch {
            var e = entry;
            e.deinit(self.alloc);
            return;
        };
        self.bytes += df.data_size;
        self.receiveFragLocked(writer, w, w.partials.items.len - 1, df);
    }

    /// Adds `df` to `w.partials[idx]`, which becomes a sample once complete.
    fn receiveFragLocked(self: *Self, writer: Guid, w: *Writer, idx: usize, df: msg.submessage.DataFragSubmessage) void {
        const p = &w.partials.items[idx];
        p.entry.captureInlineQos(df);
        p.entry.receiveFrag(df.fragment_starting_num, df.fragments_in_submessage, df.serialized_payload);
        if (!p.entry.isComplete()) return;

        var done = w.partials.orderedRemove(idx);
        done.entry.received.deinit();
        // Its bytes, already counted, are counted again as the sample's.
        self.bytes -= done.entry.data_size;
        self.appendSampleLocked(w, .{
            .change = .{
                .kind = .alive,
                .writer_guid = writer,
                .sequence_number = done.sn,
                .source_timestamp = done.entry.source_timestamp,
                .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
                .key_hash = done.entry.key_hash,
                .data = done.entry.data,
                .coherent_set_sn = done.entry.coherent_set_sn,
                .group_seq_num = done.entry.group_seq_num,
                .group_coherent_sn = done.entry.group_coherent_sn,
            },
            // A reassembled sample's key hash is fragment 1's PID_KEY_HASH or
            // zero, as for one reassembled after the match.
            .has_key_hash = true,
            .target = done.target,
            .expires_ns = done.expires_ns,
        });
    }

    /// Appends copies of what `writer` sent `reader` (directly, or to every
    /// reader) to `out`: samples in SN order, one per SN, then partly
    /// reassembled samples.  Leaves the cache as it is.
    pub fn collect(self: *Self, alloc: std.mem.Allocator, writer: Guid, reader: EntityId, out: *Collected) !void {
        self.mu.lock();
        defer self.mu.unlock();
        const w = self.writers.getPtr(writer) orelse return;
        const first = out.samples.items.len;
        for (w.samples.items) |s| {
            if (!forReader(s.target, reader)) continue;
            const data = try alloc.dupe(u8, s.change.data);
            var copy = s.change;
            copy.data = data;
            out.samples.append(alloc, copy) catch {
                alloc.free(data);
                return error.OutOfMemory;
            };
            try out.sample_has_key_hash.append(alloc, s.has_key_hash);
        }
        sortAndDedupe(alloc, out, first);
        for (w.partials.items) |p| {
            if (!forReader(p.target, reader)) continue;
            var entry = try p.entry.clone(alloc);
            out.partials.append(alloc, .{ .sn = p.sn, .entry = entry }) catch {
                entry.deinit(alloc);
                return error.OutOfMemory;
            };
        }
    }

    /// Drops everything held from `writer`.
    pub fn dropWriter(self: *Self, writer: Guid) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.writers.fetchRemove(writer)) |kv| {
            var w = kv.value;
            self.freeWriter(&w);
        }
    }

    /// Drops everything held from the writers of participant `prefix`.
    pub fn dropPrefix(self: *Self, prefix: GuidPrefix) void {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            var it = self.writers.keyIterator();
            const g = while (it.next()) |k| {
                if (k.prefix.eql(prefix)) break k.*;
            } else return;
            var w = self.writers.fetchRemove(g).?.value;
            self.freeWriter(&w);
        }
    }

    /// Drops everything held whose time ran out at or before `now_ns`.
    pub fn expire(self: *Self, now_ns: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.expireLocked(now_ns);
    }

    /// When `expire` next has anything to drop, or null when nothing is held.
    pub fn nextExpiry(self: *Self) ?i64 {
        self.mu.lock();
        defer self.mu.unlock();
        var next: ?i64 = null;
        var it = self.writers.valueIterator();
        while (it.next()) |w| {
            for (w.samples.items) |sm| next = if (next) |n| @min(n, sm.expires_ns) else sm.expires_ns;
            for (w.partials.items) |pt| next = if (next) |n| @min(n, pt.expires_ns) else pt.expires_ns;
        }
        return next;
    }

    /// Bytes held, for tests.
    pub fn byteCount(self: *Self) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.bytes;
    }

    /// Writers with data held, for tests.
    pub fn writerCount(self: *Self) usize {
        self.mu.lock();
        defer self.mu.unlock();
        return self.writers.count();
    }

    fn forReader(target: EntityId, reader: EntityId) bool {
        return target.eql(EntityIds.unknown) or target.eql(reader);
    }

    /// Sorts out.samples[first..] by SN and drops repeats, which a sample
    /// sent both to every reader and directly to `reader` would be.
    fn sortAndDedupe(alloc: std.mem.Allocator, out: *Collected, first: usize) void {
        const items = out.samples.items[first..];
        const has = out.sample_has_key_hash.items[first..];
        // Insertion sort: at most max_samples_per_writer, mostly in order.
        var i: usize = 1;
        while (i < items.len) : (i += 1) {
            var j = i;
            while (j > 0 and items[j - 1].sequence_number > items[j].sequence_number) : (j -= 1) {
                std.mem.swap(CacheChange, &items[j - 1], &items[j]);
                std.mem.swap(bool, &has[j - 1], &has[j]);
            }
        }
        var kept: usize = 0;
        for (items, has, 0..) |ch, h, k| {
            if (kept > 0 and items[kept - 1].sequence_number == ch.sequence_number) {
                alloc.free(ch.data);
                continue;
            }
            items[kept] = items[k];
            has[kept] = h;
            kept += 1;
        }
        out.samples.items.len = first + kept;
        out.sample_has_key_hash.items.len = first + kept;
    }

    /// `writer`'s entry, made if need be, or null when max_writers are
    /// already held (after expiring what has run out at `now_ns`).
    fn writerLocked(self: *Self, writer: Guid, now_ns: i64) ?*Writer {
        if (self.writers.getPtr(writer)) |w| return w;
        if (self.writers.count() >= self.limits.max_writers) {
            self.expireLocked(now_ns);
            if (self.writers.count() >= self.limits.max_writers) return null;
        }
        const gop = self.writers.getOrPut(self.alloc, writer) catch return null;
        gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn dropIfEmptyLocked(self: *Self, writer: Guid) void {
        const w = self.writers.getPtr(writer) orelse return;
        if (!w.isEmpty()) return;
        self.freeWriter(w);
        _ = self.writers.remove(writer);
    }

    /// Whether `n` more bytes fit, expiring what has run out at `now_ns` if
    /// they do not yet.
    fn reserveLocked(self: *Self, n: usize, now_ns: i64) bool {
        if (self.bytes + n <= self.limits.max_bytes) return true;
        self.expireLocked(now_ns);
        return self.bytes + n <= self.limits.max_bytes;
    }

    /// Appends `s`, whose bytes the caller has reserved, dropping the
    /// earliest-arrived sample at max_samples_per_writer.
    fn appendSampleLocked(self: *Self, w: *Writer, s: Sample) void {
        if (w.samples.items.len >= self.limits.max_samples_per_writer) {
            const evicted = w.samples.orderedRemove(0);
            self.bytes -= evicted.change.data.len;
            self.alloc.free(evicted.change.data);
        }
        w.samples.append(self.alloc, s) catch {
            self.alloc.free(s.change.data);
            return;
        };
        self.bytes += s.change.data.len;
    }

    fn expireLocked(self: *Self, now_ns: i64) void {
        var it = self.writers.valueIterator();
        while (it.next()) |w| {
            var i: usize = 0;
            while (i < w.samples.items.len) {
                if (w.samples.items[i].expires_ns > now_ns) {
                    i += 1;
                    continue;
                }
                const s = w.samples.orderedRemove(i);
                self.bytes -= s.change.data.len;
                self.alloc.free(s.change.data);
            }
            i = 0;
            while (i < w.partials.items.len) {
                if (w.partials.items[i].expires_ns > now_ns) {
                    i += 1;
                    continue;
                }
                var p = w.partials.orderedRemove(i);
                self.bytes -= p.entry.data_size;
                p.entry.deinit(self.alloc);
            }
        }
        while (true) {
            var kit = self.writers.iterator();
            const g = while (kit.next()) |kv| {
                if (kv.value_ptr.isEmpty()) break kv.key_ptr.*;
            } else return;
            var w = self.writers.fetchRemove(g).?.value;
            self.freeWriter(&w);
        }
    }

    fn freeWriter(self: *Self, w: *Writer) void {
        for (w.samples.items) |s| {
            self.bytes -= s.change.data.len;
            self.alloc.free(s.change.data);
        }
        w.samples.deinit(self.alloc);
        for (w.partials.items) |*p| {
            self.bytes -= p.entry.data_size;
            p.entry.deinit(self.alloc);
        }
        w.partials.deinit(self.alloc);
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

const W1 = Guid{ .prefix = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } }, .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x02 } };
const W2 = Guid{ .prefix = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } }, .entity_id = .{ .entity_key = .{ 0, 0, 2 }, .entity_kind = 0x02 } };
const W3 = Guid{ .prefix = .{ .bytes = .{ 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 } }, .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x02 } };
const R1 = EntityId{ .entity_key = .{ 0, 0, 1 }, .entity_kind = 0x07 };
const R2 = EntityId{ .entity_key = .{ 0, 0, 2 }, .entity_kind = 0x07 };
const ANY = EntityIds.unknown;
const SEC: i64 = std.time.ns_per_s;

const roomy = Limits{ .max_bytes = 1 << 20, .max_writers = 8, .max_samples_per_writer = 8, .max_partials_per_writer = 2 };

fn sample(writer: Guid, sn: SequenceNumber, data: []const u8) CacheChange {
    return .{
        .kind = .alive,
        .writer_guid = writer,
        .sequence_number = sn,
        .source_timestamp = .{ .seconds = 0, .fraction = 0 },
        .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
        .key_hash = @splat(0xAB),
        .data = data,
    };
}

fn collectSns(c: *UnmatchedCache, writer: Guid, reader: EntityId, buf: []SequenceNumber) ![]SequenceNumber {
    var out: Collected = .{};
    defer out.deinit(testing.allocator);
    try c.collect(testing.allocator, writer, reader, &out);
    for (out.samples.items, 0..) |ch, i| buf[i] = ch.sequence_number;
    return buf[0..out.samples.items.len];
}

fn frag(sn: SequenceNumber, num: u32, payload: []const u8) msg.submessage.DataFragSubmessage {
    return .{
        .flags = 0x01,
        .reader_entity_id = ANY,
        .writer_entity_id = W1.entity_id,
        .writer_sn = sn,
        .fragment_starting_num = num,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8,
        .inline_qos = null,
        .serialized_payload = payload,
    };
}

test "UnmatchedCache: a reader collects what was sent to it or to every reader, in SN order" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 3, "c"), true, 0, SEC);
    c.put(W1, R2, &sample(W1, 2, "b"), true, 0, SEC);
    c.put(W1, ANY, &sample(W1, 1, "a"), true, 0, SEC);
    c.put(W1, R1, &sample(W1, 3, "c"), true, 0, SEC);

    var buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 3 }, try collectSns(&c, W1, R1, &buf));
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 2, 3 }, try collectSns(&c, W1, R2, &buf));
    // Collecting leaves it for the next reader.
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 3 }, try collectSns(&c, W1, R1, &buf));
    try testing.expectEqual(@as(usize, 0), (try collectSns(&c, W2, R1, &buf)).len);
}

test "UnmatchedCache: the same sample to the same reader is held once" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 1, "abc"), true, 0, SEC);
    c.put(W1, ANY, &sample(W1, 1, "abc"), true, 0, SEC);
    try testing.expectEqual(@as(usize, 3), c.byteCount());
}

test "UnmatchedCache: past max_samples_per_writer the earliest-arrived sample goes" {
    var limits = roomy;
    limits.max_samples_per_writer = 2;
    var c = UnmatchedCache.init(testing.allocator, limits);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 5, "a"), true, 0, SEC);
    c.put(W1, ANY, &sample(W1, 1, "b"), true, 0, SEC);
    c.put(W1, ANY, &sample(W1, 7, "c"), true, 0, SEC);
    var buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{ 1, 7 }, try collectSns(&c, W1, R1, &buf));
    try testing.expectEqual(@as(usize, 2), c.byteCount());
}

test "UnmatchedCache: data past max_bytes is not held, until expiry makes room" {
    var limits = roomy;
    limits.max_bytes = 4;
    var c = UnmatchedCache.init(testing.allocator, limits);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 1, "abc"), true, 0, SEC);
    c.put(W2, ANY, &sample(W2, 1, "de"), true, 0, SEC);
    c.put(W1, ANY, &sample(W1, 2, "toolarge"), true, 0, SEC);
    var buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{1}, try collectSns(&c, W1, R1, &buf));
    try testing.expectEqual(@as(usize, 0), (try collectSns(&c, W2, R1, &buf)).len);
    try testing.expectEqual(@as(usize, 1), c.writerCount());

    // At W1's sample's expiry, W2's fits.
    c.put(W2, ANY, &sample(W2, 1, "de"), true, SEC, SEC);
    try testing.expectEqual(@as(usize, 0), (try collectSns(&c, W1, R1, &buf)).len);
    try testing.expectEqualSlices(SequenceNumber, &.{1}, try collectSns(&c, W2, R1, &buf));
    try testing.expectEqual(@as(usize, 2), c.byteCount());
}

test "UnmatchedCache: past max_writers a new writer's data is not held, until expiry makes room" {
    var limits = roomy;
    limits.max_writers = 1;
    var c = UnmatchedCache.init(testing.allocator, limits);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 1, "a"), true, 0, SEC);
    c.put(W2, ANY, &sample(W2, 1, "b"), true, 0, SEC);
    try testing.expectEqual(@as(usize, 1), c.byteCount());
    c.put(W2, ANY, &sample(W2, 1, "b"), true, SEC, SEC);
    var buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{1}, try collectSns(&c, W2, R1, &buf));
    try testing.expectEqual(@as(usize, 1), c.writerCount());
}

test "UnmatchedCache: expire drops what has run out, and the writers left with nothing" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 1, "a"), true, 0, SEC);
    c.put(W1, ANY, &sample(W1, 2, "b"), true, SEC / 2, SEC);
    c.put(W2, ANY, &sample(W2, 1, "c"), true, 0, SEC);
    c.expire(SEC - 1);
    try testing.expectEqual(@as(usize, 3), c.byteCount());
    c.expire(SEC);
    var buf: [8]SequenceNumber = undefined;
    try testing.expectEqualSlices(SequenceNumber, &.{2}, try collectSns(&c, W1, R1, &buf));
    try testing.expectEqual(@as(usize, 1), c.writerCount());
    c.expire(SEC + SEC / 2);
    try testing.expectEqual(@as(usize, 0), c.writerCount());
    try testing.expectEqual(@as(usize, 0), c.byteCount());
}

test "UnmatchedCache: dropWriter and dropPrefix" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 1, "a"), true, 0, SEC);
    c.put(W2, ANY, &sample(W2, 1, "b"), true, 0, SEC);
    c.put(W3, ANY, &sample(W3, 1, "c"), true, 0, SEC);
    c.dropWriter(W2);
    try testing.expectEqual(@as(usize, 2), c.writerCount());
    c.dropPrefix(W1.prefix);
    try testing.expectEqual(@as(usize, 1), c.writerCount());
    try testing.expectEqual(@as(usize, 1), c.byteCount());
}

test "UnmatchedCache: fragments are reassembled, and a partial one is collected as one" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    c.putFrag(W1, ANY, frag(1, 1, "abcd"), .{ .seconds = 0, .fraction = 0 }, 0, SEC);
    c.putFrag(W1, ANY, frag(2, 2, "WXYZ"), .{ .seconds = 0, .fraction = 0 }, 0, SEC);
    c.putFrag(W1, ANY, frag(1, 2, "efgh"), .{ .seconds = 0, .fraction = 0 }, 0, SEC);
    // SN 1 whole (8) plus SN 2's declared size (8).
    try testing.expectEqual(@as(usize, 16), c.byteCount());

    var out: Collected = .{};
    defer out.deinit(testing.allocator);
    try c.collect(testing.allocator, W1, R1, &out);
    try testing.expectEqual(@as(usize, 1), out.samples.items.len);
    try testing.expectEqualStrings("abcdefgh", out.samples.items[0].data);
    try testing.expectEqual(@as(usize, 1), out.partials.items.len);
    try testing.expectEqual(@as(SequenceNumber, 2), out.partials.items[0].sn);
    try testing.expect(out.partials.items[0].entry.received.isSet(1));
    try testing.expect(!out.partials.items[0].entry.received.isSet(0));
}

test "UnmatchedCache: past max_partials_per_writer the earliest-started reassembly goes" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    const ts: time_mod.RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
    c.putFrag(W1, ANY, frag(1, 1, "abcd"), ts, 0, SEC);
    c.putFrag(W1, ANY, frag(2, 1, "abcd"), ts, 0, SEC);
    c.putFrag(W1, ANY, frag(3, 1, "abcd"), ts, 0, SEC);
    try testing.expectEqual(@as(usize, 16), c.byteCount());
    var out: Collected = .{};
    defer out.deinit(testing.allocator);
    try c.collect(testing.allocator, W1, R1, &out);
    try testing.expectEqual(@as(usize, 2), out.partials.items.len);
    try testing.expectEqual(@as(SequenceNumber, 2), out.partials.items[0].sn);
    try testing.expectEqual(@as(SequenceNumber, 3), out.partials.items[1].sn);
}

test "UnmatchedCache: a sample larger than max_bytes is not started" {
    var limits = roomy;
    limits.max_bytes = 7;
    var c = UnmatchedCache.init(testing.allocator, limits);
    defer c.deinit();
    c.putFrag(W1, ANY, frag(1, 1, "abcd"), .{ .seconds = 0, .fraction = 0 }, 0, SEC);
    try testing.expectEqual(@as(usize, 0), c.byteCount());
    try testing.expectEqual(@as(usize, 0), c.writerCount());
}

test "Prematch: a held sample without PID_KEY_HASH gets the reader's key hash" {
    var c = UnmatchedCache.init(testing.allocator, roomy);
    defer c.deinit();
    c.put(W1, ANY, &sample(W1, 1, "alive"), false, 0, SEC);
    var disposed = sample(W1, 2, "key");
    disposed.kind = .not_alive_disposed;
    c.put(W1, ANY, &disposed, false, 0, SEC);
    c.put(W1, ANY, &sample(W1, 3, "hashed"), true, 0, SEC);

    const H = struct {
        var unused: u8 = 0;
        fn full(_: *anyopaque, _: []const u8) [16]u8 {
            return @splat(1);
        }
        fn keyOnly(_: *anyopaque, _: []const u8) [16]u8 {
            return @splat(2);
        }
    };
    const pm = Prematch{ .cache = &c, .key_hash_ctx = &H.unused, .key_hash_fn = H.full, .key_hash_only_fn = H.keyOnly };
    var out: Collected = .{};
    defer out.deinit(testing.allocator);
    try pm.collect(testing.allocator, W1, R1, &out);
    try testing.expectEqual(@as([16]u8, @splat(1)), out.samples.items[0].key_hash);
    try testing.expectEqual(@as([16]u8, @splat(2)), out.samples.items[1].key_hash);
    try testing.expectEqual(@as([16]u8, @splat(0xAB)), out.samples.items[2].key_hash);
}
