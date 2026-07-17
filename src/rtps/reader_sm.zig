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
const locator_selector = @import("../transport/locator_selector.zig");
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
    /// Called when a valid (non-duplicate) HEARTBEAT is received from a writer.
    /// Invoked under the state machine's lock; must NOT call back into the SM.
    on_heartbeat: ?*const fn (ctx: *anyopaque, writer_guid: Guid, last_sn: SequenceNumber) void = null,
    /// Called when an end-of-coherent-set marker arrives (zero-payload alive DATA,
    /// no PID_COHERENT_SET).  The DCPS layer registers this to flush the coherent WIP.
    /// If null, EOC packets are silently dropped — correct for RTPS-level consumers.
    on_eoc: ?*const fn (ctx: *anyopaque, change: *const CacheChange) void = null,
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

fn keyHashFromInlineQos(inline_qos: ?msg.submessage.InlineQos) [16]u8 {
    if (inline_qos) |iq| {
        if (iq.get(.key_hash)) |bytes| {
            if (bytes.len == 16) return bytes[0..16].*;
        }
    }
    return std.mem.zeroes([16]u8);
}

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
    /// Source timestamp from the INFO_TS submessage preceding the first DATA_FRAG
    /// fragment. Carried forward to the assembled CacheChange for BY_SOURCE_TIMESTAMP
    /// destination-order QoS and history-cache ordering.
    source_timestamp: time_mod.RtpsTimestamp,
    /// MD5 key hash from PID_KEY_HASH inline QoS, if present in the first fragment.
    key_hash: [16]u8,

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
    /// Ranked, cached subset of unicast_locators (or multicast_locators as
    /// fallback) actually used for sends. See transport.locator_selector.
    /// Recomputed only when unicast_locators/multicast_locators change (at
    /// construction, and moved on lease refresh in addMatchedWriter) — never
    /// per-send.
    selected_locators: std.ArrayListUnmanaged(Locator),
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
    /// Highest sequence number of the writer's history at match time, as reported in the
    /// first HEARTBEAT.  Only meaningful when history_established is true.
    history_floor_sn: SequenceNumber,
    /// False when this writer offered TRANSIENT_LOCAL history that has not yet been fully
    /// delivered to this reader.  Set to true on the first accepted HEARTBEAT; also true
    /// by default for writers that do not require history tracking.
    history_established: bool,
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
            .selected_locators = .empty,
            .received = .empty,
            .pending_changes = .empty,
            .ack_count = 0,
            .last_hb_count = null,
            .last_hb_frag_count = null,
            .reassembly = .empty,
            .reliable = reliable,
            .history_floor_sn = 0,
            .history_established = true,
        };
        try self.unicast_locators.appendSlice(alloc, unicast_locators);
        errdefer self.unicast_locators.deinit(alloc);
        try self.multicast_locators.appendSlice(alloc, multicast_locators);
        errdefer self.multicast_locators.deinit(alloc);
        // Selection failure must not fail proxy construction — fall back to
        // an empty selected_locators (effectiveLocators() then returns
        // nothing, which every call site already handles gracefully).
        locator_selector.selectInto(&self.selected_locators, alloc, self.unicast_locators.items, self.multicast_locators.items) catch {};
        return self;
    }

    pub fn deinit(self: *WriterProxy, alloc: std.mem.Allocator) void {
        self.unicast_locators.deinit(alloc);
        self.multicast_locators.deinit(alloc);
        self.selected_locators.deinit(alloc);
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

    /// Ranked subset of locators to deliver to — see transport.locator_selector.
    /// Cached at construction/lease-refresh time; O(1) per call.
    pub fn effectiveLocators(self: *const WriterProxy) []const Locator {
        return self.selected_locators.items;
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
    /// DATA received before the sending writer's proxy was established.
    /// Keyed by writer GUID; drained and replayed in addMatchedWriter.
    /// Bounded at MAX_UNMATCHED_BUFFER entries per writer to limit memory use.
    pending_unmatched: std.AutoHashMapUnmanaged(Guid, std.ArrayListUnmanaged(CacheChange)),
    /// In-progress DATA_FRAG reassembly for unmatched writers.
    /// Keyed by writer GUID then SN. Completed assemblies move to pending_unmatched;
    /// in-progress entries are migrated into the new WriterProxy in addMatchedWriter.
    pending_unmatched_reassembly: std.AutoHashMapUnmanaged(Guid, std.AutoHashMapUnmanaged(SequenceNumber, ReassemblyEntry)),

    const Self = @This();
    const MAX_UNMATCHED_BUFFER: usize = 64;
    /// Maximum number of distinct writer GUIDs buffered across pending_unmatched
    /// and pending_unmatched_reassembly. Prevents unbounded map growth from
    /// spoofed or misbehaving senders flooding with synthetic GUIDs.
    const MAX_UNMATCHED_WRITERS: usize = 32;

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
            .pending_unmatched = .empty,
            .pending_unmatched_reassembly = .empty,
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
        var pu_it = self.pending_unmatched.valueIterator();
        while (pu_it.next()) |list| {
            for (list.items) |ch| self.alloc.free(ch.data);
            list.deinit(self.alloc);
        }
        self.pending_unmatched.deinit(self.alloc);
        var pur_it = self.pending_unmatched_reassembly.iterator();
        while (pur_it.next()) |outer| {
            var inner_it = outer.value_ptr.valueIterator();
            while (inner_it.next()) |entry| entry.deinit(self.alloc);
            outer.value_ptr.deinit(self.alloc);
        }
        self.pending_unmatched_reassembly.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn setCallback(self: *Self, cb: DataCallback) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.callback = cb;
    }

    /// Add a matched writer. For new writers, sends an initial non-final AckNack
    /// to solicit available data (RTPS §8.4.10.3): RELIABLE writers respond by
    /// retransmitting missing cached changes, and TRANSIENT_LOCAL BEST_EFFORT
    /// writers use this as a one-time cue to replay the currently cached history.
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
                // proxy.selected_locators was already computed against
                // proxy.unicast_locators/multicast_locators by WriterProxy.init,
                // so it moves alongside them rather than being recomputed here.
                wp.unicast_locators.deinit(self.alloc);
                wp.multicast_locators.deinit(self.alloc);
                wp.selected_locators.deinit(self.alloc);
                wp.unicast_locators = proxy.unicast_locators;
                wp.multicast_locators = proxy.multicast_locators;
                wp.selected_locators = proxy.selected_locators;
                wp.reliable = proxy.reliable;
                // Dispose the incoming proxy's empty tracking fields cleanly.
                var discarded = proxy;
                discarded.unicast_locators = .empty;
                discarded.multicast_locators = .empty;
                discarded.selected_locators = .empty;
                discarded.deinit(self.alloc);
                return;
            }
        }
        try self.writer_proxies.append(self.alloc, proxy);
        const new_wp = &self.writer_proxies.items[self.writer_proxies.items.len - 1];
        // Replay any DATA that arrived in the window between first receiving data
        // from this writer and the writer proxy being established (SEDP race).
        // deliverChangeLocked makes its own copy, so we free our buffered copy afterward.
        if (self.pending_unmatched.fetchRemove(new_wp.guid)) |kv| {
            var pending = kv.value;
            defer pending.deinit(self.alloc);
            for (pending.items) |pending_change| {
                defer self.alloc.free(pending_change.data);
                if (new_wp.received.contains(pending_change.sequence_number)) continue;
                self.deliverChangeLocked(new_wp, pending_change) catch {};
            }
        }
        // Migrate any in-progress DATA_FRAG reassembly that arrived before the proxy.
        if (self.pending_unmatched_reassembly.fetchRemove(new_wp.guid)) |kv| {
            var frag_map = kv.value;
            var frag_it = frag_map.iterator();
            while (frag_it.next()) |frag_entry| {
                new_wp.reassembly.put(self.alloc, frag_entry.key_ptr.*, frag_entry.value_ptr.*) catch {
                    frag_entry.value_ptr.deinit(self.alloc);
                };
            }
            frag_map.deinit(self.alloc);
        }
        // AckNack triggers TRANSIENT_LOCAL replay from both RELIABLE and BEST_EFFORT
        // writers.  For RELIABLE writers the heartbeat cycle also covers this; for
        // BEST_EFFORT writers (no periodic heartbeats per §8.4.15) this is the only
        // trigger that compensates for the race between writer-side replay and
        // reader-side proxy setup.
        self.sendAckNackLocked(new_wp, 0, false);
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
        if (wp == null) {
            // For reliable readers, buffer the change so it can be replayed once the
            // writer proxy is established (SEDP race: data arrives before discovery
            // completes and addMatchedWriter is called).
            if (self.reliable) self.bufferUnmatchedLocked(writer_guid, change) catch {};
            return;
        }

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

    /// Count distinct writer GUIDs buffered across both unmatched maps.
    /// A GUID that appears in both maps is counted only once.
    fn unmatchedGuidCount(self: *Self) usize {
        var n = self.pending_unmatched.count();
        var it = self.pending_unmatched_reassembly.keyIterator();
        while (it.next()) |k| {
            if (!self.pending_unmatched.contains(k.*)) n += 1;
        }
        return n;
    }

    /// Buffer a change whose writer proxy has not yet been established.
    /// Called under self.mu. Evicts the oldest entry when the per-writer cap is hit.
    /// Drops the change if the combined unmatched-writer GUID count is at capacity.
    /// A GUID already present in either map is not considered "new" — only GUIDs
    /// absent from both maps are counted against MAX_UNMATCHED_WRITERS, preventing
    /// a spoofed sender from exploiting two separate maps to double the limit.
    fn bufferUnmatchedLocked(self: *Self, writer_guid: Guid, change: CacheChange) !void {
        if (!self.pending_unmatched.contains(writer_guid) and
            !self.pending_unmatched_reassembly.contains(writer_guid) and
            self.unmatchedGuidCount() >= MAX_UNMATCHED_WRITERS) return;
        const entry = try self.pending_unmatched.getOrPut(self.alloc, writer_guid);
        const pu_inserted = !entry.found_existing;
        if (pu_inserted) entry.value_ptr.* = .empty;
        // errdefer at function scope so it fires for any error below (dupe, append),
        // not just errors inside the if block (which has none).
        errdefer if (pu_inserted) {
            _ = self.pending_unmatched.remove(writer_guid);
        };
        const list = entry.value_ptr;
        for (list.items) |existing| {
            if (existing.sequence_number == change.sequence_number) return;
        }
        if (list.items.len >= MAX_UNMATCHED_BUFFER) {
            const evicted = list.orderedRemove(0);
            self.alloc.free(evicted.data);
        }
        const data_copy = try self.alloc.dupe(u8, change.data);
        var owned = change;
        owned.data = data_copy;
        list.append(self.alloc, owned) catch {
            self.alloc.free(data_copy);
            return error.OutOfMemory;
        };
    }

    /// Buffer a DATA_FRAG from an unmatched writer into pending_unmatched_reassembly.
    /// Called under self.mu. When all fragments arrive the assembled change is moved
    /// to pending_unmatched for replay in addMatchedWriter; otherwise the in-progress
    /// ReassemblyEntry is migrated directly into the new WriterProxy.
    fn bufferUnmatchedFragLocked(self: *Self, writer_guid: Guid, source_timestamp: time_mod.RtpsTimestamp, df: msg.submessage.DataFragSubmessage) !void {
        if (df.fragment_size == 0 or df.data_size == 0) return;
        const sn = df.writer_sn;
        const total_frags: u32 = (df.data_size + df.fragment_size - 1) / df.fragment_size;

        if (!self.pending_unmatched_reassembly.contains(writer_guid) and
            !self.pending_unmatched.contains(writer_guid) and
            self.unmatchedGuidCount() >= MAX_UNMATCHED_WRITERS) return;
        const outer = try self.pending_unmatched_reassembly.getOrPut(self.alloc, writer_guid);
        const pur_inserted = !outer.found_existing;
        if (pur_inserted) outer.value_ptr.* = .empty;
        errdefer if (pur_inserted) {
            _ = self.pending_unmatched_reassembly.remove(writer_guid);
        };

        if (outer.value_ptr.getPtr(sn) == null) {
            const data = try self.alloc.alloc(u8, df.data_size);
            errdefer self.alloc.free(data);
            var received = try std.DynamicBitSet.initEmpty(self.alloc, total_frags);
            errdefer received.deinit();
            const key_hash = keyHashFromInlineQos(df.inline_qos);
            try outer.value_ptr.put(self.alloc, sn, .{
                .data = data,
                .data_size = df.data_size,
                .fragment_size = df.fragment_size,
                .total_frags = total_frags,
                .received = received,
                .source_timestamp = source_timestamp,
                .key_hash = key_hash,
            });
        }

        const entry = outer.value_ptr.getPtr(sn).?;
        entry.receiveFrag(df.fragment_starting_num, df.fragments_in_submessage, df.serialized_payload);

        if (!entry.isComplete()) return;

        // Assembled — promote to pending_unmatched so addMatchedWriter replays it.
        // bufferUnmatchedLocked dupes entry.data, so we free the original afterward.
        const change = CacheChange{
            .kind = .alive,
            .writer_guid = writer_guid,
            .sequence_number = sn,
            .source_timestamp = entry.source_timestamp,
            .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
            .key_hash = entry.key_hash,
            .data = entry.data,
        };
        self.bufferUnmatchedLocked(writer_guid, change) catch {};
        var removed = outer.value_ptr.fetchRemove(sn).?;
        removed.value.received.deinit();
        self.alloc.free(removed.value.data);
        // Remove the outer GUID entry when the inner map is now empty so the slot
        // is not permanently consumed against MAX_UNMATCHED_WRITERS.
        if (outer.value_ptr.count() == 0) {
            outer.value_ptr.deinit(self.alloc);
            _ = self.pending_unmatched_reassembly.remove(writer_guid);
        }
    }

    /// Handle a received DATA_FRAG submessage.  Accumulates fragments into a
    /// reassembly buffer; delivers the complete change once all fragments arrive.
    /// For reliable readers, fragments from unmatched writers are buffered in
    /// pending_unmatched_reassembly and migrated to the WriterProxy in addMatchedWriter.
    pub fn handleDataFrag(self: *Self, writer_guid: Guid, source_timestamp: time_mod.RtpsTimestamp, df: msg.submessage.DataFragSubmessage) !void {
        self.mu.lock();
        defer self.mu.unlock();

        var wp: ?*WriterProxy = null;
        for (self.writer_proxies.items) |*w| {
            if (w.guid.eql(writer_guid)) {
                wp = w;
                break;
            }
        }
        if (wp == null) {
            if (self.reliable) self.bufferUnmatchedFragLocked(writer_guid, source_timestamp, df) catch {};
            return;
        }

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
            const key_hash = keyHashFromInlineQos(df.inline_qos);
            try wp.?.reassembly.put(self.alloc, sn, .{
                .data = data,
                .data_size = df.data_size,
                .fragment_size = df.fragment_size,
                .total_frags = total_frags,
                .received = received,
                .source_timestamp = source_timestamp,
                .key_hash = key_hash,
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
            .source_timestamp = entry.source_timestamp,
            .instance_handle = history_mod.INSTANCE_HANDLE_NIL,
            .key_hash = entry.key_hash,
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

        // EOC marker (§9.6.4.2 Table 9.22 Example 3): alive change with empty
        // data and no PID_COHERENT_SET.  Track the SN in received (to avoid
        // perpetual NACKs) but never add to the application-visible cache or
        // fire the data callback — the DCPS layer handles EOC in onDataCb.
        const is_eoc = change.kind == .alive and change.data.len == 0 and change.coherent_set_sn == null;

        if (self.reliable) {
            const prev_highest = wp.received.cumulativeAck();
            if (sn == prev_highest + 1) {
                _ = wp.received.insert(self.alloc, sn) catch {};
                if (!is_eoc) {
                    try self.cache.addReaderChange(change);
                    if (self.callback) |cb| {
                        if (self.cache.getChangeForWriter(change.writer_guid, sn)) |cached| cb.on_data(cb.ctx, cached);
                    }
                } else {
                    // EOC marker: not cached, but notify the DCPS layer so it can
                    // flush the coherent WIP without adding a data sample to pending.
                    if (self.callback) |cb| if (cb.on_eoc) |f| f(cb.ctx, &change);
                }
                self.deliverPendingLocked(wp, sn);
            } else {
                // Out-of-order: check if already buffered.
                for (wp.pending_changes.items) |pc| {
                    if (pc.sequence_number == sn) return;
                }
                // Buffer the change (including EOC markers, which have data.len == 0)
                // so deliverPendingLocked can fire on_eoc when the gap fills.  Without
                // buffering the EOC, a writer that already appears in coherent_eoc_writers
                // (HB flushing suppressed) would leave its WIP permanently stuck.
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
            if (!is_eoc) {
                try self.cache.addReaderChange(change);
                if (self.callback) |cb| {
                    if (self.cache.getChangeForWriter(change.writer_guid, sn)) |ch| cb.on_data(cb.ctx, ch);
                }
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
                    const is_eoc = pending_ch.kind == .alive and
                        pending_ch.data.len == 0 and
                        pending_ch.coherent_set_sn == null;
                    if (!is_eoc) {
                        self.cache.addReaderChange(pending_ch) catch {};
                        if (self.callback) |cb| {
                            if (self.cache.getChangeForWriter(pending_ch.writer_guid, next_sn)) |cached| {
                                cb.on_data(cb.ctx, cached);
                            }
                        }
                    } else {
                        if (self.callback) |cb| if (cb.on_eoc) |f| f(cb.ctx, &pending_ch);
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
        // Validity checks (§8.3.7.5.3): drop ill-formed Heartbeats silently.
        // first_sn must be >= 1; last_sn must be >= first_sn - 1 (the only
        // exception is the empty-cache convention: first_sn=1, last_sn=0).
        if (first_sn <= 0 or last_sn < first_sn - 1) return;

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
            const is_first_hb = wp.last_hb_count == null;
            wp.last_hb_count = count;

            // On the first HEARTBEAT from a transient-local writer, record last_sn as
            // the floor: the reader needs to receive every SN up to that point before
            // wait_for_historical_data can return.
            if (is_first_hb and !wp.history_established) {
                wp.history_floor_sn = last_sn;
                wp.history_established = true;
            }

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
                var lost_count: i32 = 0;
                var sn = prev_highest + 1;
                while (sn < first_sn) : (sn += 1) {
                    if (!wp.received.contains(sn)) lost_count += 1;
                    _ = wp.received.insert(self.alloc, sn) catch {};
                }
                self.deliverPendingLocked(wp, prev_highest);
                if (lost_count > 0) {
                    if (self.callback) |cb| {
                        if (cb.on_sample_lost) |f| f(cb.ctx, lost_count);
                    }
                }
            }

            // Notify the DDS layer that a valid HB arrived.  Used to flush
            // coherent WIP when no subsequent set will trigger a CS transition.
            if (self.callback) |cb| {
                if (cb.on_heartbeat) |f| f(cb.ctx, writer_guid, last_sn);
            }

            // Only RELIABLE readers send ACKNACK; BEST_EFFORT readers ignore HEARTBEATs.
            if (!self.reliable) continue;

            // Send ACKNACK if: non-final heartbeat, or we have missing SNs.
            const has_missing = wp.received.cumulativeAck() < last_sn;
            if (!final or has_missing) {
                self.sendAckNackLocked(wp, last_sn, !has_missing);
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

    /// Returns true when all matched writers with history_expected have delivered their
    /// complete history (cumulativeAck >= history_floor_sn).  Writers without history
    /// tracking (history_established = true from the start) are always counted as done.
    /// Returns true immediately when no writers are matched.
    pub fn historicalDelivered(self: *Self) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.writer_proxies.items) |*wp| {
            if (!wp.history_established) return false;
            if (wp.received.cumulativeAck() < wp.history_floor_sn) return false;
        }
        return true;
    }

    fn sendAckNackLocked(self: *Self, wp: *WriterProxy, last_sn: SequenceNumber, final: bool) void {
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
            .final = final,
        } });
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(wp.guid.prefix);
        b.addAckNack(
            self.guid.entity_id,
            wp.guid.entity_id,
            sns,
            wp.ack_count,
            final,
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

// Stateless null transport for unit tests that don't exercise network I/O.
const TestNullCtx = struct {
    fn canReach(_: *anyopaque, _: *const Locator) bool {
        return false;
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
const test_null_vtable = Transport.Vtable{
    .capabilities = .{},
    .can_reach = TestNullCtx.canReach,
    .send = TestNullCtx.send,
    .listen = TestNullCtx.listen,
    .join_multicast = TestNullCtx.joinMulticast,
    .leave_multicast = TestNullCtx.leaveMulticast,
    .unlisten = TestNullCtx.unlisten,
    .unicast_locators = TestNullCtx.unicastLocators,
    .set_locator_change_handler = TestNullCtx.setLocatorChangeHandler,
    .close = TestNullCtx.close,
};

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

test "StatefulReader buffers data from unmatched writer and replays on addMatchedWriter" {
    // Regression: DATA arriving before addMatchedWriter was silently dropped.
    // The fix buffers the change in pending_unmatched and drains it when the
    // writer proxy is established.  For in-order SN=1 the replay delivers immediately.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(10, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    var delivered: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    reader.setCallback(.{ .ctx = &delivered, .on_data = Cb.onData });

    const writer_guid = makeGuid(10, 0xC2);
    var payload = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const change = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &payload,
    };

    // DATA arrives before writer proxy exists — must be buffered, not dropped.
    try reader.handleData(writer_guid, change);
    try testing.expectEqual(@as(usize, 0), delivered);

    // addMatchedWriter drains the buffer and replays SN=1 in-order → delivered.
    const proxy = try WriterProxy.init(testing.allocator, writer_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy);
    try testing.expectEqual(@as(usize, 1), delivered);
}

test "StatefulReader pending_unmatched: out-of-order replay delivered by heartbeat GAP fill" {
    // Reproduces the CS_7 TSAN failure: DATA SN=30 arrives ~27ms before the
    // writer proxy is established (SEDP processing delayed by TSAN overhead and
    // participant.mu contention).  The change is buffered, then replayed as
    // out-of-order when addMatchedWriter is called.  A subsequent empty HEARTBEAT
    // (first_sn=30, last_sn=29) fills SNs 1-29 as virtual GAPs → cumulativeAck=29
    // → deliverPendingLocked fires and delivers the buffered SN=30.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(11, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    var delivered: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    reader.setCallback(.{ .ctx = &delivered, .on_data = Cb.onData });

    const writer_guid = makeGuid(11, 0xC2);
    var payload = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    const change = CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 30,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &payload,
    };

    // SN=30 arrives before writer proxy — buffered in pending_unmatched.
    try reader.handleData(writer_guid, change);
    try testing.expectEqual(@as(usize, 0), delivered);

    // addMatchedWriter: SN=30 replayed as out-of-order (cumAck=0, need SN=1 first).
    const proxy = try WriterProxy.init(testing.allocator, writer_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy);
    try testing.expectEqual(@as(usize, 0), delivered); // still waiting for gap fill

    // Empty HEARTBEAT (first_sn=30, last_sn=29): writer history starts at SN=30,
    // so SNs 1-29 never existed.  Virtual GAP fill advances cumAck to 29 →
    // deliverPendingLocked delivers the buffered SN=30.
    reader.handleHeartbeat(writer_guid, 30, 29, 1, true);
    try testing.expectEqual(@as(usize, 1), delivered);
}

test "StatefulReader pending_unmatched: GUID cap drops 33rd unmatched writer" {
    // MAX_UNMATCHED_WRITERS=32 limits distinct GUID buckets. The 33rd unmatched
    // writer's data must be silently dropped rather than causing unbounded growth.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(20, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    var delivered: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    reader.setCallback(.{ .ctx = &delivered, .on_data = Cb.onData });

    var payload = [_]u8{ 0x00, 0x01, 0x02, 0x03 };

    // Fill all 32 GUID slots with one change each.
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        const wguid = makeGuid(i, 0xC2);
        const ch = CacheChange{ .kind = .alive, .writer_guid = wguid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = &payload };
        try reader.handleData(wguid, ch);
    }

    // 33rd writer — must be dropped.
    const extra_guid = makeGuid(200, 0xC2);
    const extra_ch = CacheChange{ .kind = .alive, .writer_guid = extra_guid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = &payload };
    try reader.handleData(extra_guid, extra_ch);

    // Match the 33rd writer — it should get no replay (change was dropped).
    const proxy33 = try WriterProxy.init(testing.allocator, extra_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy33);
    try testing.expectEqual(@as(usize, 0), delivered);

    // Match the first writer — it should get its buffered change.
    const first_guid = makeGuid(0, 0xC2);
    const proxy0 = try WriterProxy.init(testing.allocator, first_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy0);
    reader.handleHeartbeat(first_guid, 1, 1, 1, true);
    try testing.expectEqual(@as(usize, 1), delivered);
}

test "StatefulReader pending_unmatched_reassembly: outer entry removed after assembly completes" {
    // When a DATA_FRAG from an unmatched writer completes reassembly, the outer
    // GUID entry in pending_unmatched_reassembly must be removed.  If it is left
    // as a ghost, the combined GUID cap counts it twice (once in
    // pending_unmatched_reassembly, once in pending_unmatched after promotion),
    // prematurely exhausting the 32-slot budget.
    //
    // Strategy: fill 31 slots with incomplete (2-fragment) reassemblies.  Complete
    // slot 0 — promotes writer 0 to pending_unmatched and removes its outer entry,
    // keeping combined = 31.  A 32nd unique GUID must then be accepted.
    // Without the outer-entry cleanup, combined = 32 after completion and the 32nd
    // GUID is incorrectly dropped.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(21, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    var delivered: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    reader.setCallback(.{ .ctx = &delivered, .on_data = Cb.onData });

    // 2-fragment message (8 bytes, 4-byte fragments).
    var frag1_bytes = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var frag2_bytes = [_]u8{ 0x05, 0x06, 0x07, 0x08 };
    const frag1 = msg.submessage.DataFragSubmessage{ .flags = 0, .reader_entity_id = std.mem.zeroes(EntityId), .writer_entity_id = std.mem.zeroes(EntityId), .writer_sn = 1, .fragment_starting_num = 1, .fragments_in_submessage = 1, .fragment_size = 4, .data_size = 8, .inline_qos = null, .serialized_payload = &frag1_bytes };
    const frag2 = msg.submessage.DataFragSubmessage{ .flags = 0, .reader_entity_id = std.mem.zeroes(EntityId), .writer_entity_id = std.mem.zeroes(EntityId), .writer_sn = 1, .fragment_starting_num = 2, .fragments_in_submessage = 1, .fragment_size = 4, .data_size = 8, .inline_qos = null, .serialized_payload = &frag2_bytes };

    // Fill 31 slots with incomplete reassemblies (only frag 1 sent).
    var i: u8 = 0;
    while (i < 31) : (i += 1) {
        try reader.handleDataFrag(makeGuid(i, 0xC3), ZERO_TS, frag1);
    }

    // Complete slot 0: frag 2 → assembly finishes → promoted to pending_unmatched,
    // outer entry removed.  combined = pending_unmatched(1) + pending_unmatched_reassembly(30) = 31.
    // Without the fix: ghost persists → 1 + 31 = 32, blocking the 32nd GUID.
    try reader.handleDataFrag(makeGuid(0, 0xC3), ZERO_TS, frag2);

    // 32nd unique GUID — must be accepted (slot correctly reclaimed).
    var single_payload = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    const single_frag = msg.submessage.DataFragSubmessage{ .flags = 0, .reader_entity_id = std.mem.zeroes(EntityId), .writer_entity_id = std.mem.zeroes(EntityId), .writer_sn = 1, .fragment_starting_num = 1, .fragments_in_submessage = 1, .fragment_size = 4, .data_size = 4, .inline_qos = null, .serialized_payload = &single_payload };
    const extra_guid = makeGuid(201, 0xC3);
    try reader.handleDataFrag(extra_guid, ZERO_TS, single_frag);

    // Match the 32nd writer and confirm its change is delivered.
    const proxy32 = try WriterProxy.init(testing.allocator, extra_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy32);
    reader.handleHeartbeat(extra_guid, 1, 1, 1, true);
    try testing.expectEqual(@as(usize, 1), delivered);
}

test "StatefulReader pending_unmatched: GUID cap is shared across DATA and DATA_FRAG maps" {
    // MAX_UNMATCHED_WRITERS applies to the combined GUID count across
    // pending_unmatched and pending_unmatched_reassembly. A spoofed sender must
    // not be able to occupy 32 slots in each map for a total of 64 GUIDs.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(22, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    var delivered: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    reader.setCallback(.{ .ctx = &delivered, .on_data = Cb.onData });

    var payload = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    // Fill 16 slots via DATA (pending_unmatched).
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        const wguid = makeGuid(i, 0xC4);
        const ch = CacheChange{ .kind = .alive, .writer_guid = wguid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = &payload };
        try reader.handleData(wguid, ch);
    }

    // Fill 16 more slots via incomplete DATA_FRAG (pending_unmatched_reassembly).
    // Combined total is now 32 — at the cap.
    var frag1_bytes = [_]u8{ 0x0A, 0x0B, 0x0C, 0x0D };
    const frag1 = msg.submessage.DataFragSubmessage{ .flags = 0, .reader_entity_id = std.mem.zeroes(EntityId), .writer_entity_id = std.mem.zeroes(EntityId), .writer_sn = 1, .fragment_starting_num = 1, .fragments_in_submessage = 1, .fragment_size = 4, .data_size = 8, .inline_qos = null, .serialized_payload = &frag1_bytes };
    while (i < 32) : (i += 1) {
        const wguid = makeGuid(i, 0xC4);
        try reader.handleDataFrag(wguid, ZERO_TS, frag1);
    }

    // 33rd unique GUID must be dropped — both DATA and DATA_FRAG paths.
    const extra_data_guid = makeGuid(200, 0xC4);
    const ch33 = CacheChange{ .kind = .alive, .writer_guid = extra_data_guid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = &payload };
    try reader.handleData(extra_data_guid, ch33);

    const extra_frag_guid = makeGuid(201, 0xC4);
    try reader.handleDataFrag(extra_frag_guid, ZERO_TS, frag1);

    // Neither extra GUID delivered after matching.
    const proxy_data = try WriterProxy.init(testing.allocator, extra_data_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy_data);
    reader.handleHeartbeat(extra_data_guid, 1, 1, 1, true);
    try testing.expectEqual(@as(usize, 0), delivered);

    const proxy_frag = try WriterProxy.init(testing.allocator, extra_frag_guid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy_frag);
    reader.handleHeartbeat(extra_frag_guid, 1, 1, 1, true);
    try testing.expectEqual(@as(usize, 0), delivered);
}

test "StatefulReader pending_unmatched: GUID cap counts unique GUIDs across both maps" {
    // Regression: old code summed pending_unmatched.count() + pending_unmatched_reassembly.count(),
    // double-counting a GUID present in both maps.  With 31 DATA-buffered GUIDs and one of
    // those same GUIDs also in pending_unmatched_reassembly, the old sum reached 32 and
    // wrongly blocked the 32nd unique GUID.  The fix counts unique GUIDs via unmatchedGuidCount.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(23, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    var delivered: usize = 0;
    const Cb = struct {
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const n: *usize = @ptrCast(@alignCast(ctx));
            n.* += 1;
        }
    };
    reader.setCallback(.{ .ctx = &delivered, .on_data = Cb.onData });

    var payload = [_]u8{ 0x01, 0x02, 0x03, 0x04 };

    // Fill 31 slots via DATA (pending_unmatched).
    var i: u8 = 0;
    while (i < 31) : (i += 1) {
        const wguid = makeGuid(i, 0xC5);
        const ch = CacheChange{ .kind = .alive, .writer_guid = wguid, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = &payload };
        try reader.handleData(wguid, ch);
    }

    // Add GUID 0 (already in pending_unmatched) to pending_unmatched_reassembly via
    // an incomplete DATA_FRAG.  Old code: 31+1=32 → cap hit.  New code: 31 unique → no cap.
    var frag_bytes = [_]u8{ 0x0A, 0x0B, 0x0C, 0x0D };
    const half_frag = msg.submessage.DataFragSubmessage{
        .flags = 0,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = 2,
        .fragment_starting_num = 1,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8, // two frags needed; only sending one
        .inline_qos = null,
        .serialized_payload = &frag_bytes,
    };
    try reader.handleDataFrag(makeGuid(0, 0xC5), ZERO_TS, half_frag);

    // 32nd unique GUID — must be accepted because there are only 31 unique GUIDs buffered.
    const guid32 = makeGuid(200, 0xC5);
    const ch32 = CacheChange{ .kind = .alive, .writer_guid = guid32, .sequence_number = 1, .source_timestamp = ZERO_TS, .instance_handle = NIL_IH, .key_hash = NIL_KH, .data = &payload };
    try reader.handleData(guid32, ch32);

    const proxy32 = try WriterProxy.init(testing.allocator, guid32, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy32);
    reader.handleHeartbeat(guid32, 1, 1, 1, true);
    try testing.expectEqual(@as(usize, 1), delivered);
}

test "StatefulReader DATA_FRAG: source_timestamp and key_hash preserved through matched reassembly" {
    // Verifies that the assembled CacheChange carries the source_timestamp from
    // the first fragment's INFO_TS and the key_hash from PID_KEY_HASH inline QoS,
    // not RtpsTimestamp.now() / zeroes as before this fix.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    // best-effort: deliverChangeLocked fires immediately without a heartbeat.
    const reader = try StatefulReader.init(testing.allocator, makeGuid(30, 0xC7), null_transport, .keep_all, 0, false);
    defer reader.deinit();

    const Ctx = struct {
        ts: time_mod.RtpsTimestamp = ZERO_TS,
        kh: [16]u8 = NIL_KH,
        fn onData(ctx: *anyopaque, change: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ts = change.source_timestamp;
            self.kh = change.key_hash;
        }
    };
    var ctx = Ctx{};
    reader.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData });

    const wguid = makeGuid(30, 0xC2);
    const proxy = try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, false);
    try reader.addMatchedWriter(proxy);

    const expected_ts = time_mod.RtpsTimestamp{ .seconds = 12345, .fraction = 67890 };
    const expected_kh = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };

    var kh_bytes = expected_kh;
    const iq_params = [_]msg.submessage.InlineQosParam{.{ .pid = .key_hash, .value = &kh_bytes }};
    const iq = msg.submessage.InlineQos{ .params = @constCast(&iq_params) };

    var frag1_bytes = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD };
    var frag2_bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    // Inline QoS only on first fragment — key_hash from first frag must survive.
    const frag1 = msg.submessage.DataFragSubmessage{
        .flags = msg.submessage.DataFragFlags.inline_qos,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = 1,
        .fragment_starting_num = 1,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8,
        .inline_qos = iq,
        .serialized_payload = &frag1_bytes,
    };
    const frag2 = msg.submessage.DataFragSubmessage{
        .flags = 0,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = 1,
        .fragment_starting_num = 2,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8,
        .inline_qos = null,
        .serialized_payload = &frag2_bytes,
    };

    try reader.handleDataFrag(wguid, expected_ts, frag1);
    try reader.handleDataFrag(wguid, ZERO_TS, frag2); // second frag has no INFO_TS

    try testing.expectEqual(expected_ts, ctx.ts);
    try testing.expectEqual(expected_kh, ctx.kh);
}

test "StatefulReader DATA_FRAG: source_timestamp and key_hash preserved through unmatched-buffer reassembly" {
    // Same as above but the writer is not yet matched when fragments arrive.
    // Assembly completes in bufferUnmatchedFragLocked → promoted to pending_unmatched
    // → replayed in addMatchedWriter.  The assembled CacheChange must carry the
    // original timestamp and key_hash, not defaults.
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };

    const reader = try StatefulReader.init(testing.allocator, makeGuid(31, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    const Ctx = struct {
        ts: time_mod.RtpsTimestamp = ZERO_TS,
        kh: [16]u8 = NIL_KH,
        fn onData(ctx: *anyopaque, change: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.ts = change.source_timestamp;
            self.kh = change.key_hash;
        }
    };
    var ctx = Ctx{};
    reader.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData });

    const wguid = makeGuid(31, 0xC2);
    const expected_ts = time_mod.RtpsTimestamp{ .seconds = 99999, .fraction = 11111 };
    const expected_kh = [16]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE, 0xBA, 0xBE, 0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF };

    var kh_bytes = expected_kh;
    const iq_params = [_]msg.submessage.InlineQosParam{.{ .pid = .key_hash, .value = &kh_bytes }};
    const iq = msg.submessage.InlineQos{ .params = @constCast(&iq_params) };

    var frag1_bytes = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    var frag2_bytes = [_]u8{ 0x55, 0x66, 0x77, 0x88 };
    const frag1 = msg.submessage.DataFragSubmessage{
        .flags = msg.submessage.DataFragFlags.inline_qos,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = 1,
        .fragment_starting_num = 1,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8,
        .inline_qos = iq,
        .serialized_payload = &frag1_bytes,
    };
    const frag2 = msg.submessage.DataFragSubmessage{
        .flags = 0,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = 1,
        .fragment_starting_num = 2,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8,
        .inline_qos = null,
        .serialized_payload = &frag2_bytes,
    };

    // Both fragments arrive before the writer is matched.
    try reader.handleDataFrag(wguid, expected_ts, frag1);
    try reader.handleDataFrag(wguid, ZERO_TS, frag2);

    // addMatchedWriter drains pending_unmatched; SN=1 is in-order → delivered immediately.
    const proxy = try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, true);
    try reader.addMatchedWriter(proxy);

    try testing.expectEqual(expected_ts, ctx.ts);
    try testing.expectEqual(expected_kh, ctx.kh);
}
