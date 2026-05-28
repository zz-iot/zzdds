//! RTPS Reader state machines (RTPS 2.5 §8.4.10, §8.4.11).
//!
//! StatelessReader: best-effort, no acknowledgment. Used for SPDP reception.
//!   Delivers received DATA directly to a callback; no history cache.
//!
//! StatefulReader: reliable, per-writer ACK tracking. Used for SEDP reception.
//!   Stores changes in a history cache; sends ACKNACK in response to HEARTBEAT.

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const mutex_mod = @import("../util/mutex.zig");
const history_mod = @import("history.zig");
const guid_mod = @import("guid.zig");
const sn_mod = @import("sequence_number.zig");
const received_set_mod = @import("received_set.zig");
const time_mod = @import("../util/time.zig");
const msg = @import("message/root.zig");
const iface = @import("../transport/interface.zig");
const writer_sm = @import("writer_sm.zig");

const MessageBuilder = msg.builder.MessageBuilder;
const SCRATCH_SIZE = msg.builder.SCRATCH_SIZE;
const SequenceNumberSet = msg.submessage.SequenceNumberSet;
const FragmentNumberSet = msg.submessage.FragmentNumberSet;

pub const HistoryCache = history_mod.HistoryCache;
pub const CacheChange = history_mod.CacheChange;
pub const ChangeKind = history_mod.ChangeKind;
pub const InstanceHandle = history_mod.InstanceHandle;
pub const ReceivedSet = received_set_mod.ReceivedSet;
pub const Guid = guid_mod.Guid;
pub const GuidPrefix = guid_mod.GuidPrefix;
pub const EntityId = guid_mod.EntityId;
pub const SequenceNumber = sn_mod.SequenceNumber;
pub const RtpsTimestamp = time_mod.RtpsTimestamp;
pub const Transport = iface.Transport;
pub const Locator = iface.Locator;

// ── Delivery callback ─────────────────────────────────────────────────────────

/// Called when a change is ready for delivery to the application layer.
/// Invoked under the state machine's lock; must NOT call back into the SM.
pub const DataCallback = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, change: *const CacheChange) void,
    on_sample_lost: ?*const fn (ctx: *anyopaque, count: i32) void = null,
};

// ── StatelessReader ───────────────────────────────────────────────────────────

/// Best-effort reader. Delivers received DATA directly to the callback.
/// No history, no deduplication, no acknowledgment.
/// Typical use: SPDP participant announcement reception.
///
/// Thread-safe: the callback is protected by `mu`.
pub const StatelessReader = struct {
    guid: Guid,
    callback: ?DataCallback,
    mu: mutex_mod.Mutex,

    const Self = @This();

    pub fn init(guid: Guid) Self {
        return .{ .guid = guid, .callback = null, .mu = .{} };
    }

    pub fn deinit(_: *Self) void {}

    pub fn setCallback(self: *Self, cb: DataCallback) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.callback = cb;
    }

    /// Deliver a received change to the registered callback.
    pub fn handleData(self: *Self, change: *const CacheChange) void {
        self.mu.lock();
        const cb = self.callback;
        self.mu.unlock();
        if (cb) |c| c.on_data(c.ctx, change);
    }
};

// ── ReassemblyEntry ───────────────────────────────────────────────────────────

/// In-progress fragment reassembly for one (writer, sequence_number) pair.
/// Allocated when the first DATA_FRAG fragment arrives; freed on completion or
/// when the WriterProxy is removed.
pub const ReassemblyEntry = struct {
    data: []u8,
    data_size: u32,
    fragment_size: u16,
    total_frags: u32,
    received: std.DynamicBitSet,

    pub fn deinit(self: *ReassemblyEntry, alloc: std.mem.Allocator) void {
        alloc.free(self.data);
        self.received.deinit();
    }

    pub fn isComplete(self: *const ReassemblyEntry) bool {
        return self.received.count() == self.total_frags;
    }

    /// Copy fragment bytes into the buffer and mark received.
    /// Handles fragments_in_submessage > 1 (multiple fragments per DATA_FRAG).
    pub fn receiveFrag(
        self: *ReassemblyEntry,
        fragment_starting_num: u32,
        fragments_in_submessage: u16,
        payload: []const u8,
    ) void {
        var i: u32 = 0;
        while (i < fragments_in_submessage) : (i += 1) {
            const frag_idx = fragment_starting_num - 1 + i; // 0-based
            if (frag_idx >= self.total_frags) break;
            if (self.received.isSet(frag_idx)) continue;

            const data_offset: usize = @as(usize, frag_idx) * @as(usize, self.fragment_size);
            const src_offset: usize = @as(usize, i) * @as(usize, self.fragment_size);
            const frag_len = @min(
                @as(usize, self.fragment_size),
                @as(usize, self.data_size) - data_offset,
            );
            if (src_offset + frag_len <= payload.len) {
                @memcpy(self.data[data_offset..][0..frag_len], payload[src_offset..][0..frag_len]);
            }
            self.received.set(frag_idx);
        }
    }
};

// ── WriterProxy (StatefulReader) ──────────────────────────────────────────────

/// State that a StatefulReader tracks for each matched writer.
pub const WriterProxy = struct {
    guid: Guid,
    unicast_locators: std.ArrayListUnmanaged(Locator),
    multicast_locators: std.ArrayListUnmanaged(Locator),
    /// Disjoint set of all SNs received from this writer.
    /// cumulativeAck() gives the highest contiguous SN from SN 1.
    received: ReceivedSet,
    /// Out-of-order changes held for RELIABLE readers pending in-order delivery.
    /// Each entry owns its `data` slice; freed on deinit or on delivery.
    pending_changes: std.ArrayListUnmanaged(CacheChange),
    /// Monotonically increasing count for ACKNACK submessages.
    ack_count: i32,
    /// Last accepted heartbeat count for duplicate suppression (§8.3.5.10).
    /// Null until the first heartbeat from this writer is accepted.
    last_hb_count: ?i32,
    /// Last accepted HEARTBEAT_FRAG count for stale-submessage suppression (§8.3.8.13).
    /// Null until the first HEARTBEAT_FRAG from this writer is accepted.
    last_hb_frag_count: ?i32,
    /// True when the remote writer offers RELIABLE delivery.
    reliable: bool,
    /// In-progress fragment reassembly, keyed by writer sequence number.
    /// Each entry accumulates DATA_FRAG payloads until complete, then delivers
    /// the assembled change through the normal handleData path.
    reassembly: std.AutoHashMapUnmanaged(SequenceNumber, ReassemblyEntry),

    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        unicast_locators: []const Locator,
        multicast_locators: []const Locator,
        reliable: bool,
    ) !WriterProxy {
        var self = WriterProxy{
            .guid = guid,
            .unicast_locators = .empty,
            .multicast_locators = .empty,
            .received = .empty,
            .pending_changes = .empty,
            .ack_count = 0,
            .last_hb_count = null,
            .last_hb_frag_count = null,
            .reassembly = .empty,
            .reliable = reliable,
        };
        try self.unicast_locators.appendSlice(alloc, unicast_locators);
        try self.multicast_locators.appendSlice(alloc, multicast_locators);
        return self;
    }

    pub fn deinit(self: *WriterProxy, alloc: std.mem.Allocator) void {
        self.unicast_locators.deinit(alloc);
        self.multicast_locators.deinit(alloc);
        self.received.deinit(alloc);
        for (self.pending_changes.items) |*ch| alloc.free(ch.data);
        self.pending_changes.deinit(alloc);
        var it = self.reassembly.valueIterator();
        while (it.next()) |entry| entry.deinit(alloc);
        self.reassembly.deinit(alloc);
    }

    /// Primary locator: first unicast, else first multicast.
    pub fn primaryLocator(self: *const WriterProxy) ?Locator {
        if (self.unicast_locators.items.len > 0) return self.unicast_locators.items[0];
        if (self.multicast_locators.items.len > 0) return self.multicast_locators.items[0];
        return null;
    }

    /// All locators to deliver to: unicast list if non-empty, else multicast list.
    pub fn effectiveLocators(self: *const WriterProxy) []const Locator {
        if (self.unicast_locators.items.len > 0) return self.unicast_locators.items;
        return self.multicast_locators.items;
    }

    /// Build a SequenceNumberSet that represents the SNs this reader is missing
    /// from the writer's history, given that the writer has up to `last_sn`.
    ///
    /// A pure ACK (received everything up to last_sn) returns:
    ///   base = last_sn + 1, num_bits = 0
    pub fn missingSnSet(self: *const WriterProxy, last_sn: SequenceNumber) SequenceNumberSet {
        const base = self.received.cumulativeAck() + 1;
        if (base > last_sn) {
            // Pure ACK.
            return .{ .base = last_sn + 1, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) };
        }
        const span: u64 = @intCast(last_sn - base + 1);
        const num_bits: u32 = @intCast(@min(span, 256));
        var bitmap = std.mem.zeroes([8]u32);

        // Set bits for SNs we have NOT received.
        var offset: u32 = 0;
        while (offset < num_bits) : (offset += 1) {
            const sn: SequenceNumber = base + @as(i64, offset);
            if (!self.received.contains(sn)) {
                const word: u32 = offset / 32;
                const bit: u5 = @intCast(31 - (offset % 32)); // MSB-first
                bitmap[word] |= @as(u32, 1) << bit;
            }
        }
        return .{ .base = base, .num_bits = num_bits, .bitmap = bitmap };
    }
};

// ── StatefulReader ────────────────────────────────────────────────────────────

/// Reliable reader with per-writer tracking and ACKNACK generation.
/// Typical use: SEDP endpoint discovery reception.
///
/// Thread-safe: all public methods lock `mu`.
pub const StatefulReader = struct {
    alloc: std.mem.Allocator,
    guid: Guid,
    transport: Transport,
    cache: HistoryCache,
    writer_proxies: std.ArrayListUnmanaged(WriterProxy),
    callback: ?DataCallback,
    mu: mutex_mod.Mutex,
    tracer: trace.Tracer,
    /// When true, out-of-order changes are buffered per WriterProxy and
    /// delivered only when the sequence is contiguous (RTPS §8.4.8 RELIABLE semantics).
    /// When false, changes are delivered immediately on arrival (BEST_EFFORT).
    reliable: bool,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        transport: Transport,
        cache_kind: history_mod.HistoryKind,
        cache_depth: u32,
        reliable: bool,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .guid = guid,
            .transport = transport,
            .cache = HistoryCache.init(alloc, cache_kind, cache_depth),
            .writer_proxies = .empty,
            .callback = null,
            .mu = .{},
            .tracer = trace.Tracer.noop(),
            .reliable = reliable,
        };
        return self;
    }

    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    pub fn deinit(self: *Self) void {
        for (self.writer_proxies.items) |*wp| wp.deinit(self.alloc);
        self.writer_proxies.deinit(self.alloc);
        self.cache.deinit();
        self.alloc.destroy(self);
    }

    pub fn setCallback(self: *Self, cb: DataCallback) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.callback = cb;
    }

    /// Add a matched writer. For new writers, sends an initial non-final AckNack
    /// to solicit available data (RTPS §8.4.10.3): the writer responds by
    /// retransmitting any cached changes, necessary when the initial DATA/Heartbeat
    /// may have been dropped. BEST_EFFORT writers do not retransmit, so skipping
    /// the AckNack avoids a synchronous re-entry deadlock with in-process transports.
    ///
    /// Re-announcements from an already-matched writer act as lease refreshes:
    /// locators and metadata are updated but the received set, pending_changes,
    /// ack_count, last_hb_count, and reassembly state are preserved.  This prevents
    /// spurious retransmit bursts caused by re-discovery (e.g. dual network interfaces
    /// presenting the same participant twice).
    pub fn addMatchedWriter(self: *Self, proxy: WriterProxy) !void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.writer_proxies.items) |*wp| {
            if (wp.guid.eql(proxy.guid)) {
                // Lease refresh: update locators/metadata, preserve sequence state.
                wp.unicast_locators.deinit(self.alloc);
                wp.multicast_locators.deinit(self.alloc);
                wp.unicast_locators = proxy.unicast_locators;
                wp.multicast_locators = proxy.multicast_locators;
                wp.reliable = proxy.reliable;
                // Dispose the incoming proxy's empty tracking fields cleanly.
                var discarded = proxy;
                discarded.unicast_locators = .empty;
                discarded.multicast_locators = .empty;
                discarded.deinit(self.alloc);
                return;
            }
        }
        try self.writer_proxies.append(self.alloc, proxy);
        const new_wp = &self.writer_proxies.items[self.writer_proxies.items.len - 1];
        // AckNack triggers TRANSIENT_LOCAL replay from both RELIABLE and BEST_EFFORT
        // writers.  For RELIABLE writers the heartbeat cycle also covers this; for
        // BEST_EFFORT writers (no periodic heartbeats per §8.4.15) this is the only
        // trigger that compensates for the race between writer-side replay and
        // reader-side proxy setup.
        self.sendAckNackLocked(new_wp, 0);
    }

    pub fn removeMatchedWriter(self: *Self, guid: Guid) void {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = self.writer_proxies.items.len;
        while (i > 0) {
            i -= 1;
            if (self.writer_proxies.items[i].guid.eql(guid)) {
                self.writer_proxies.items[i].deinit(self.alloc);
                _ = self.writer_proxies.swapRemove(i);
            }
        }
    }

    /// Returns true if the given GUID is currently in the writer proxy list.
    /// Used by the RTPS message dispatcher to skip allocation for unmatched data.
    pub fn isWriterMatched(self: *Self, guid: Guid) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.writer_proxies.items) |*wp| {
            if (wp.guid.eql(guid)) return true;
        }
        return false;
    }

    /// Handle a received DATA submessage from a matched writer.
    ///
    /// BEST_EFFORT (reliable=false): adds to cache and delivers immediately.
    /// RELIABLE (reliable=true): buffers out-of-order changes per WriterProxy;
    /// fires the callback only when the sequence is contiguous (RTPS §8.4.8).
    /// Silently ignores data from unmatched writers.
    pub fn handleData(self: *Self, writer_guid: Guid, change: CacheChange) !void {
        self.mu.lock();
        defer self.mu.unlock();

        var wp: ?*WriterProxy = null;
        for (self.writer_proxies.items) |*w| {
            if (w.guid.eql(writer_guid)) {
                wp = w;
                break;
            }
        }
        if (wp == null) return;

        const sn = change.sequence_number;
        if (wp.?.received.contains(sn)) {
            self.tracer.submit(.{ .recv_data_dup = .{
                .src_prefix = writer_guid.prefix,
                .writer_eid = writer_guid.entity_id,
                .sn = sn,
            } });
            return;
        }
        try self.deliverChangeLocked(wp.?, change);
    }

    /// Handle a received DATA_FRAG submessage.  Accumulates fragments into a
    /// reassembly buffer; delivers the complete change once all fragments arrive.
    /// Silently ignores data from unmatched writers or already-delivered SNs.
    pub fn handleDataFrag(self: *Self, writer_guid: Guid, df: msg.submessage.DataFragSubmessage) !void {
        self.mu.lock();
        defer self.mu.unlock();

        var wp: ?*WriterProxy = null;
        for (self.writer_proxies.items) |*w| {
            if (w.guid.eql(writer_guid)) {
                wp = w;
                break;
            }
        }
        if (wp == null) return;

        const sn = df.writer_sn;
        if (wp.?.received.contains(sn)) return; // already delivered

        // Validate fragment parameters to avoid divide-by-zero or huge allocs.
        if (df.fragment_size == 0 or df.data_size == 0) return;

        const total_frags: u32 = (df.data_size + df.fragment_size - 1) / df.fragment_size;

        if (wp.?.reassembly.getPtr(sn) == null) {
            const data = try self.alloc.alloc(u8, df.data_size);
            errdefer self.alloc.free(data);
            var received = try std.DynamicBitSet.initEmpty(self.alloc, total_frags);
            errdefer received.deinit();
            try wp.?.reassembly.put(self.alloc, sn, .{
                .data = data,
                .data_size = df.data_size,
                .fragment_size = df.fragment_size,
                .total_frags = total_frags,
                .received = received,
            });
        }

        const entry = wp.?.reassembly.getPtr(sn).?;
        entry.receiveFrag(df.fragment_starting_num, df.fragments_in_submessage, df.serialized_payload);

        if (!entry.isComplete()) return;

        // Assembled — deliver through the normal DATA path.  The cache dupes
        // entry.data internally, so we can free it after delivery.
        const assembled_data = entry.data;
        const change = CacheChange{
            .kind = .alive,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = time_mod.RtpsTimestamp.now(),
            .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
            .key_hash = std.mem.zeroes([16]u8),
            .data = assembled_data,
        };
        try self.deliverChangeLocked(wp.?, change);

        // Remove the reassembly entry; cache already holds its own copy of data.
        var removed = wp.?.reassembly.fetchRemove(sn).?;
        removed.value.received.deinit();
        self.alloc.free(removed.value.data);
    }

    /// Handle a HEARTBEAT_FRAG from a matched writer.
    /// Sends a NACK_FRAG for any fragments not yet received.
    pub fn handleHeartbeatFrag(
        self: *Self,
        writer_guid: Guid,
        writer_sn: SequenceNumber,
        last_frag_num: msg.submessage.FragmentNumber,
        count: i32,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.writer_proxies.items) |*wp| {
            if (!wp.guid.eql(writer_guid)) continue;

            // Stale HEARTBEAT_FRAG suppression (§8.3.8.13): ignore if count is not
            // strictly greater than the last accepted count from this writer.
            if (wp.last_hb_frag_count) |last| {
                const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
                if (diff <= 0) return;
            }
            wp.last_hb_frag_count = count;

            if (wp.received.contains(writer_sn)) return; // already delivered

            const entry_ptr = wp.reassembly.getPtr(writer_sn);
            if (entry_ptr != null and entry_ptr.?.isComplete()) return;

            self.sendNackFragLocked(wp, writer_sn, entry_ptr, last_frag_num);
            return;
        }
    }

    /// Build and send a NACK_FRAG covering all missing fragments up to last_frag_num.
    /// `entry` is null when no fragments have been received yet (request everything).
    /// Called under self.mu.
    fn sendNackFragLocked(
        self: *Self,
        wp: *WriterProxy,
        writer_sn: SequenceNumber,
        entry: ?*const ReassemblyEntry,
        last_frag_num: msg.submessage.FragmentNumber,
    ) void {
        const locs = wp.effectiveLocators();
        if (locs.len == 0) return;

        // Build FragmentNumberSet for missing fragments.
        // Covers a window of up to 256 fragments starting at the first missing one.
        var frag_set = FragmentNumberSet{
            .base = 1,
            .num_bits = 0,
            .bitmap = std.mem.zeroes([8]u32),
        };
        var first_missing: ?u32 = null;

        var frag_num: u32 = 1;
        while (frag_num <= last_frag_num) : (frag_num += 1) {
            const idx = frag_num - 1;
            const received = if (entry) |e| (idx < e.total_frags and e.received.isSet(idx)) else false;
            if (received) continue;

            if (first_missing == null) {
                first_missing = frag_num;
                frag_set.base = frag_num;
            }
            const offset = frag_num - frag_set.base;
            if (offset >= 256) break; // window full; reader will send another NACK_FRAG after retransmit

            const word: u32 = offset / 32;
            const bit: u5 = @intCast(31 - (offset % 32));
            frag_set.bitmap[word] |= @as(u32, 1) << bit;
            frag_set.num_bits = @max(frag_set.num_bits, offset + 1);
        }

        if (first_missing == null) return; // nothing missing

        wp.ack_count += 1;
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(wp.guid.prefix);
        b.addNackFrag(self.guid.entity_id, wp.guid.entity_id, writer_sn, frag_set, wp.ack_count);
        for (locs) |loc| writer_sm.sendIovecs(self.transport, &loc, b.iovecs()) catch {};
    }

    /// Deliver a complete change (DATA or fully-assembled DATA_FRAG) to the cache
    /// and callback.  Handles RELIABLE ordering and BEST_EFFORT immediate delivery.
    /// Called under self.mu.  Does NOT check for duplicates — callers must guard.
    fn deliverChangeLocked(self: *Self, wp: *WriterProxy, change: CacheChange) !void {
        const sn = change.sequence_number;

        self.tracer.submit(.{ .recv_data = .{
            .src_prefix = change.writer_guid.prefix,
            .writer_eid = change.writer_guid.entity_id,
            .reader_eid = self.guid.entity_id,
            .sn = sn,
            .key_hash = change.key_hash,
            .data_len = @intCast(change.data.len),
        } });

        if (self.reliable) {
            const prev_highest = wp.received.cumulativeAck();
            if (sn == prev_highest + 1) {
                _ = wp.received.insert(self.alloc, sn) catch {};
                try self.cache.addReaderChange(change);
                if (self.callback) |cb| {
                    if (self.cache.getChangeForWriter(change.writer_guid, sn)) |cached| cb.on_data(cb.ctx, cached);
                }
                self.deliverPendingLocked(wp, sn);
            } else {
                // Out-of-order: check if already buffered.
                for (wp.pending_changes.items) |pc| {
                    if (pc.sequence_number == sn) return;
                }
                const data_copy = try self.alloc.dupe(u8, change.data);
                var owned = change;
                owned.data = data_copy;
                wp.pending_changes.append(self.alloc, owned) catch {
                    self.alloc.free(data_copy);
                    return;
                };
                _ = wp.received.insert(self.alloc, sn) catch {};
            }
        } else {
            _ = wp.received.insert(self.alloc, sn) catch {};
            try self.cache.addReaderChange(change);
            if (self.callback) |cb| {
                if (self.cache.getChangeForWriter(change.writer_guid, sn)) |ch| cb.on_data(cb.ctx, ch);
            }
        }
    }

    /// Deliver all buffered pending changes with SNs in (prev_delivered, cumulativeAck()].
    /// Called under self.mu. Only meaningful when self.reliable = true.
    fn deliverPendingLocked(self: *Self, wp: *WriterProxy, prev_delivered: SequenceNumber) void {
        var next_sn = prev_delivered + 1;
        while (next_sn <= wp.received.cumulativeAck()) : (next_sn += 1) {
            var i: usize = 0;
            while (i < wp.pending_changes.items.len) : (i += 1) {
                if (wp.pending_changes.items[i].sequence_number == next_sn) {
                    const pending_ch = wp.pending_changes.orderedRemove(i);
                    defer self.alloc.free(pending_ch.data);
                    self.cache.addReaderChange(pending_ch) catch {};
                    if (self.callback) |cb| {
                        if (self.cache.getChangeForWriter(pending_ch.writer_guid, next_sn)) |cached| {
                            cb.on_data(cb.ctx, cached);
                        }
                    }
                    break;
                }
            }
        }
    }

    /// Handle a received HEARTBEAT from a matched writer.
    /// Sends an ACKNACK (unless `final` is true and we have received everything).
    ///
    /// Heartbeat deduplication uses signed modular comparison (§8.3.5.10).
    /// Industry convention (Cyclone DDS, FastDDS): accept iff (i32)(new − old) > 0.
    /// This handles 32-bit rollover correctly: INT32_MAX + 1 wraps to INT32_MIN
    /// and is accepted as "newer".
    pub fn handleHeartbeat(
        self: *Self,
        writer_guid: Guid,
        first_sn: SequenceNumber,
        last_sn: SequenceNumber,
        count: i32,
        final: bool,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.writer_proxies.items) |*wp| {
            if (!wp.guid.eql(writer_guid)) continue;

            // Duplicate / stale heartbeat suppression.
            if (wp.last_hb_count) |last| {
                const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
                if (diff <= 0) {
                    self.tracer.submit(.{ .recv_heartbeat_dup = .{
                        .src_prefix = writer_guid.prefix,
                        .writer_eid = writer_guid.entity_id,
                        .count = count,
                    } });
                    continue; // stale or duplicate
                }
            }
            wp.last_hb_count = count;

            self.tracer.submit(.{ .recv_heartbeat = .{
                .src_prefix = writer_guid.prefix,
                .writer_eid = writer_guid.entity_id,
                .reader_eid = self.guid.entity_id,
                .first_sn = first_sn,
                .last_sn = last_sn,
                .count = count,
                .flags = if (final) 2 else 0,
            } });

            // For RELIABLE readers: if the writer's firstSN is beyond our next expected
            // SN, those earlier SNs have been evicted and will never arrive.  Treat them
            // as a virtual GAP so buffered out-of-order changes can be delivered.
            if (self.reliable and first_sn > wp.received.cumulativeAck() + 1) {
                const prev_highest = wp.received.cumulativeAck();
                var sn = prev_highest + 1;
                while (sn < first_sn) : (sn += 1) {
                    _ = wp.received.insert(self.alloc, sn) catch {};
                }
                self.deliverPendingLocked(wp, prev_highest);
            }

            // Only RELIABLE readers send ACKNACK; BEST_EFFORT readers ignore HEARTBEATs.
            if (!self.reliable) continue;

            // Send ACKNACK if: non-final heartbeat, or we have missing SNs.
            const has_missing = wp.received.cumulativeAck() < last_sn;
            if (!final or has_missing) {
                self.sendAckNackLocked(wp, last_sn);
            }
        }
    }

    /// Handle a received GAP: treat the listed SNs as irreversibly unavailable.
    pub fn handleGap(
        self: *Self,
        writer_guid: Guid,
        gap_start: SequenceNumber,
        gap_list: SequenceNumberSet,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();

        for (self.writer_proxies.items) |*wp| {
            if (!wp.guid.eql(writer_guid)) continue;
            self.tracer.submit(.{ .recv_gap = .{
                .src_prefix = writer_guid.prefix,
                .writer_eid = writer_guid.entity_id,
                .reader_eid = self.guid.entity_id,
                .gap_start = gap_start,
                .gap_list = gap_list,
            } });
            // Advance past all SNs in the gap so they don't appear as missing.
            const prev_highest = wp.received.cumulativeAck();
            var sn: SequenceNumber = gap_start;
            const bitmap_end: SequenceNumber = gap_list.base + @as(i64, gap_list.num_bits);
            var lost_count: i32 = 0;
            // SNs in [gap_start, gap_list.base-1] are all irreversibly missing.
            while (sn < gap_list.base) : (sn += 1) {
                if (!wp.received.contains(sn)) lost_count += 1;
                _ = wp.received.insert(self.alloc, sn) catch {};
            }
            // SNs in [gap_list.base, bitmap_end-1] where the bit is set are missing.
            while (sn < bitmap_end) : (sn += 1) {
                if (gap_list.contains(sn)) {
                    if (!wp.received.contains(sn)) lost_count += 1;
                    _ = wp.received.insert(self.alloc, sn) catch {};
                }
            }
            // Deliver any buffered pending changes that are now contiguous.
            if (self.reliable) self.deliverPendingLocked(wp, prev_highest);
            if (lost_count > 0) {
                if (self.callback) |cb| {
                    if (cb.on_sample_lost) |f| f(cb.ctx, lost_count);
                }
            }
        }
    }

    fn sendAckNackLocked(self: *Self, wp: *WriterProxy, last_sn: SequenceNumber) void {
        const locs = wp.effectiveLocators();
        if (locs.len == 0) return;
        wp.ack_count += 1;
        const sns = wp.missingSnSet(last_sn);
        self.tracer.submit(.{ .send_acknack = .{
            .src_prefix = self.guid.prefix,
            .reader_eid = self.guid.entity_id,
            .writer_eid = wp.guid.entity_id,
            .base_sn = sns.base,
            .bitmap = sns,
            .count = wp.ack_count,
            .final = false,
        } });
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(wp.guid.prefix);
        b.addAckNack(
            self.guid.entity_id,
            wp.guid.entity_id,
            sns,
            wp.ack_count,
            false, // not final: we may send again after timeout
        );
        for (locs) |loc| {
            writer_sm.sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                error.UnsupportedLocatorKind => {},
                else => log.rtps.warn("StatefulReader.sendAckNack: {}", .{err}),
            };
        }
    }
};

// ── Tests ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeGuid(b: u8, ek: u8) Guid {
    return .{
        .prefix = .{ .bytes = [_]u8{b} ** 12 },
        .entity_id = .{ .entity_key = .{ 0, 0, 1 }, .entity_kind = ek },
    };
}

const ZERO_TS: RtpsTimestamp = .{ .seconds = 0, .fraction = 0 };
const NIL_IH = history_mod.INSTANCE_HANDLE_NIL;
const NIL_KH = std.mem.zeroes([16]u8);

test "StatelessReader init and callback delivery" {
    var delivered: bool = false;

    const Ctx = struct {
        flag: *bool,
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.flag.* = true;
        }
    };
    var ctx = Ctx{ .flag = &delivered };

    const guid = makeGuid(1, 0xC7);
    var reader = StatelessReader.init(guid);
    defer reader.deinit();
    reader.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData });

    var payload = [_]u8{ 0x00, 0x07, 0x00, 0x00 };
    const ch = CacheChange{
        .kind = .alive,
        .writer_guid = makeGuid(2, 0xC2),
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &payload,
    };
    reader.handleData(&ch);
    try testing.expect(delivered);
}

test "WriterProxy received in-order coalesces" {
    var wp = try WriterProxy.init(testing.allocator, makeGuid(1, 0xC2), &.{}, &.{}, true);
    defer wp.deinit(testing.allocator);

    _ = try wp.received.insert(testing.allocator, 1);
    _ = try wp.received.insert(testing.allocator, 2);
    _ = try wp.received.insert(testing.allocator, 3);
    try testing.expectEqual(@as(SequenceNumber, 3), wp.received.cumulativeAck());
    try testing.expectEqual(@as(usize, 1), wp.received.ranges.items.len);
}

test "WriterProxy received out-of-order gap then fill" {
    var wp = try WriterProxy.init(testing.allocator, makeGuid(2, 0xC2), &.{}, &.{}, true);
    defer wp.deinit(testing.allocator);

    _ = try wp.received.insert(testing.allocator, 1);
    _ = try wp.received.insert(testing.allocator, 3); // gap at 2
    try testing.expectEqual(@as(SequenceNumber, 1), wp.received.cumulativeAck());
    try testing.expectEqual(@as(usize, 2), wp.received.ranges.items.len);

    _ = try wp.received.insert(testing.allocator, 2); // fills gap → coalesces to [1,3]
    try testing.expectEqual(@as(SequenceNumber, 3), wp.received.cumulativeAck());
    try testing.expectEqual(@as(usize, 1), wp.received.ranges.items.len);
}

test "WriterProxy missingSnSet pure ACK" {
    var wp = try WriterProxy.init(testing.allocator, makeGuid(3, 0xC2), &.{}, &.{}, true);
    defer wp.deinit(testing.allocator);

    _ = try wp.received.insert(testing.allocator, 1);
    _ = try wp.received.insert(testing.allocator, 2);
    const sns = wp.missingSnSet(2);
    try testing.expectEqual(@as(SequenceNumber, 3), sns.base);
    try testing.expectEqual(@as(u32, 0), sns.num_bits);
}

test "WriterProxy missingSnSet with gap" {
    var wp = try WriterProxy.init(testing.allocator, makeGuid(4, 0xC2), &.{}, &.{}, true);
    defer wp.deinit(testing.allocator);

    _ = try wp.received.insert(testing.allocator, 1);
    _ = try wp.received.insert(testing.allocator, 3); // SN 2 is missing
    const sns = wp.missingSnSet(3); // base = 2
    try testing.expectEqual(@as(SequenceNumber, 2), sns.base);
    try testing.expect(sns.contains(2)); // bit for SN 2 is set (missing)
    try testing.expect(!sns.contains(3)); // SN 3 is received (not NACKed)
}

test "StatefulReader init/deinit" {
    const NullCtx = struct {
        fn canReach(_: *anyopaque, _: *const Locator) bool {
            return true;
        }
        fn send(_: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {}
        fn listen(_: *anyopaque, _: *const Locator, _: iface.ReceiveHandler) anyerror!void {}
        fn joinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
        fn leaveMulticast(_: *anyopaque, _: *const Locator) void {}
        fn unlisten(_: *anyopaque, _: *const Locator, _: iface.ReceiveHandler) void {}
        fn unicastLocators(_: *anyopaque, out: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
            out.clearRetainingCapacity();
        }
        fn setLocatorChangeHandler(_: *anyopaque, _: ?iface.LocatorChangeHandler) void {}
        fn close(_: *anyopaque) void {}
    };
    const null_vtable = Transport.Vtable{
        .capabilities = .{},
        .can_reach = NullCtx.canReach,
        .send = NullCtx.send,
        .listen = NullCtx.listen,
        .join_multicast = NullCtx.joinMulticast,
        .leave_multicast = NullCtx.leaveMulticast,
        .unlisten = NullCtx.unlisten,
        .unicast_locators = NullCtx.unicastLocators,
        .set_locator_change_handler = NullCtx.setLocatorChangeHandler,
        .close = NullCtx.close,
    };
    var null_ctx: NullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &null_vtable };

    const guid = makeGuid(5, 0xC7);
    const reader = try StatefulReader.init(testing.allocator, guid, null_transport, .keep_all, 0, false);
    defer reader.deinit();
    try testing.expectEqual(@as(usize, 0), reader.writer_proxies.items.len);
}

test "StatefulReader BEST_EFFORT deduplicates out-of-order first sample" {
    // Regression test: a late-joining BEST_EFFORT subscriber first receives sn=47.
    // A second copy of the same SN (e.g. from the writer sending to multiple unicast
    // locators) must be dropped.  ReceivedSet.contains() covers both the contiguous
    // prefix and out-of-order SNs, so the duplicate is detected regardless of order.
    const NullCtx = struct {
        fn canReach(_: *anyopaque, _: *const Locator) bool {
            return true;
        }
        fn send(_: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {}
        fn listen(_: *anyopaque, _: *const Locator, _: iface.ReceiveHandler) anyerror!void {}
        fn joinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
        fn leaveMulticast(_: *anyopaque, _: *const Locator) void {}
        fn unlisten(_: *anyopaque, _: *const Locator, _: iface.ReceiveHandler) void {}
        fn unicastLocators(_: *anyopaque, out: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
            out.clearRetainingCapacity();
        }
        fn setLocatorChangeHandler(_: *anyopaque, _: ?iface.LocatorChangeHandler) void {}
        fn close(_: *anyopaque) void {}
    };
    const null_vtable = Transport.Vtable{
        .capabilities = .{},
        .can_reach = NullCtx.canReach,
        .send = NullCtx.send,
        .listen = NullCtx.listen,
        .join_multicast = NullCtx.joinMulticast,
        .leave_multicast = NullCtx.leaveMulticast,
        .unlisten = NullCtx.unlisten,
        .unicast_locators = NullCtx.unicastLocators,
        .set_locator_change_handler = NullCtx.setLocatorChangeHandler,
        .close = NullCtx.close,
    };
    var null_ctx: NullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &null_vtable };

    var deliveries: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const count: *usize = @ptrCast(@alignCast(ctx));
            count.* += 1;
        }
    };

    const reader_guid = makeGuid(6, 0xC7);
    const reader = try StatefulReader.init(testing.allocator, reader_guid, null_transport, .keep_all, 0, false);
    defer reader.deinit();
    reader.setCallback(.{ .ctx = &deliveries, .on_data = Cb.onData });

    const writer_guid = makeGuid(7, 0xC2);
    const proxy = try WriterProxy.init(testing.allocator, writer_guid, &.{}, &.{}, false);
    try reader.addMatchedWriter(proxy);

    var payload = [_]u8{ 0x00, 0x01, 0x00, 0x00 };
    const change = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 47,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &payload,
    };

    try reader.handleData(writer_guid, change);
    try testing.expectEqual(@as(usize, 1), deliveries);

    // Second copy of the same SN (duplicate from multi-locator send) must be dropped.
    try reader.handleData(writer_guid, change);
    try testing.expectEqual(@as(usize, 1), deliveries);

    // A genuinely distinct out-of-order SN from the same writer must still be delivered.
    var earlier_payload = [_]u8{ 0x00, 0x01, 0x00, 0x00 };
    const earlier_change = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 3,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &earlier_payload,
    };
    try reader.handleData(writer_guid, earlier_change);
    try testing.expectEqual(@as(usize, 2), deliveries);

    // Second copy of that out-of-order SN must also be dropped.
    try reader.handleData(writer_guid, earlier_change);
    try testing.expectEqual(@as(usize, 2), deliveries);
}

test "addMatchedWriter re-match preserves received set" {
    // Simulates a SPDP lease expiry + re-discovery scenario: a writer proxy is
    // already matched and has received several SNs.  When addMatchedWriter is
    // called again for the same GUID (lease refresh), the received set must be
    // preserved so that SNs already delivered are not counted as missing and
    // no spurious retransmit burst is triggered.
    const NullCtx = struct {
        sends: usize = 0,
        fn canReach(_: *anyopaque, _: *const Locator) bool {
            return true;
        }
        fn send(ctx: *anyopaque, _: *const Locator, _: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.sends += 1;
        }
        fn listen(_: *anyopaque, _: *const Locator, _: iface.ReceiveHandler) anyerror!void {}
        fn joinMulticast(_: *anyopaque, _: *const Locator) anyerror!void {}
        fn leaveMulticast(_: *anyopaque, _: *const Locator) void {}
        fn unlisten(_: *anyopaque, _: *const Locator, _: iface.ReceiveHandler) void {}
        fn unicastLocators(_: *anyopaque, out: *std.ArrayListUnmanaged(Locator), _: std.mem.Allocator) anyerror!void {
            out.clearRetainingCapacity();
        }
        fn setLocatorChangeHandler(_: *anyopaque, _: ?iface.LocatorChangeHandler) void {}
        fn close(_: *anyopaque) void {}
    };
    const null_vtable = Transport.Vtable{
        .capabilities = .{},
        .can_reach = NullCtx.canReach,
        .send = NullCtx.send,
        .listen = NullCtx.listen,
        .join_multicast = NullCtx.joinMulticast,
        .leave_multicast = NullCtx.leaveMulticast,
        .unlisten = NullCtx.unlisten,
        .unicast_locators = NullCtx.unicastLocators,
        .set_locator_change_handler = NullCtx.setLocatorChangeHandler,
        .close = NullCtx.close,
    };
    var null_ctx = NullCtx{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &null_vtable };

    const reader_guid = makeGuid(8, 0xC7);
    const reader = try StatefulReader.init(testing.allocator, reader_guid, null_transport, .keep_all, 0, true);
    defer reader.deinit();

    const loc = Locator{ .udp_v4 = .{ .addr = .{ 10, 0, 0, 1 }, .port = 7400 } };
    const writer_guid = makeGuid(9, 0xC2);

    // Initial match: writer with one unicast locator.
    const proxy1 = try WriterProxy.init(testing.allocator, writer_guid, &.{loc}, &.{}, true);
    try reader.addMatchedWriter(proxy1);
    // Initial match sends an AckNack to solicit data.
    const sends_after_first_match = null_ctx.sends;

    // Simulate receiving SNs 1-5 from the writer.
    var payload = [_]u8{0x01};
    for (1..6) |sn| {
        const ch = CacheChange{
            .kind = .alive,
            .writer_guid = writer_guid,
            .sequence_number = @intCast(sn),
            .source_timestamp = ZERO_TS,
            .instance_handle = NIL_IH,
            .key_hash = NIL_KH,
            .data = &payload,
        };
        try reader.handleData(writer_guid, ch);
    }

    // Inspect received set before re-match.
    const cum_ack_before: SequenceNumber = blk: {
        reader.mu.lock();
        defer reader.mu.unlock();
        break :blk reader.writer_proxies.items[0].received.cumulativeAck();
    };
    try testing.expectEqual(@as(SequenceNumber, 5), cum_ack_before);

    // Re-match (lease refresh): same GUID, possibly updated locators.
    const loc2 = Locator{ .udp_v4 = .{ .addr = .{ 10, 0, 0, 2 }, .port = 7400 } };
    const proxy2 = try WriterProxy.init(testing.allocator, writer_guid, &.{loc2}, &.{}, true);
    try reader.addMatchedWriter(proxy2);

    // Received set must be preserved: cumulativeAck still 5.
    const cum_ack_after: SequenceNumber = blk: {
        reader.mu.lock();
        defer reader.mu.unlock();
        break :blk reader.writer_proxies.items[0].received.cumulativeAck();
    };
    try testing.expectEqual(@as(SequenceNumber, 5), cum_ack_after);

    // Re-match must NOT send an extra AckNack (no retransmit burst).
    try testing.expectEqual(sends_after_first_match, null_ctx.sends);

    // Locator must be updated to the new one.
    const new_loc: Locator = blk: {
        reader.mu.lock();
        defer reader.mu.unlock();
        break :blk reader.writer_proxies.items[0].unicast_locators.items[0];
    };
    try testing.expectEqual(loc2, new_loc);

    // Only one proxy entry (no duplicate).
    reader.mu.lock();
    const proxy_count = reader.writer_proxies.items.len;
    reader.mu.unlock();
    try testing.expectEqual(@as(usize, 1), proxy_count);
}
