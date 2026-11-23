//! RTPS Reader state machines (RTPS 2.5 §8.4.10, §8.4.11).
//!
//! StatelessReader: best-effort, no acknowledgment. Used for SPDP reception.
//!   Delivers received DATA directly to a callback; no history cache.
//!
//! StatefulReader: reliable, per-writer ACK tracking. Used for SEDP reception.
//!   Stores changes in a history cache; sends ACKNACK in response to HEARTBEAT.

const std = @import("std");
const history_wait = @import("../protocol/history_wait.zig");
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
const reassembly_mod = @import("reassembly.zig");
const unmatched_mod = @import("unmatched_cache.zig");

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
pub const ReassemblyEntry = reassembly_mod.ReassemblyEntry;
pub const ReassemblyLimits = reassembly_mod.Limits;
pub const UnmatchedCache = unmatched_mod.UnmatchedCache;
pub const Prematch = unmatched_mod.Prematch;
pub const MatchCommit = writer_sm.MatchCommit;
pub const UnmatchCommit = writer_sm.UnmatchCommit;
pub const MatchResult = writer_sm.MatchResult;
const keyHashFromInlineQos = reassembly_mod.keyHashFromInlineQos;

// ── Delivery callback ─────────────────────────────────────────────────────────

/// Called when a change is ready for delivery to the application layer.
/// on_data and on_eoc are invoked under the state machine's
/// lock, must NOT call back into the SM, and must not reach application
/// code: they hand over, and on_flush (after the lock is released) acts.
pub const DataCallback = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, change: *const CacheChange) void,
    /// Called after the state machine's lock is released.
    on_sample_lost: ?*const fn (ctx: *anyopaque, count: i32) void = null,
    /// Called when an end-of-coherent-set marker arrives (see isEndMarker).
    /// The DCPS layer registers this to end the writer's coherent set.
    /// If null, EOC packets are silently dropped — correct for RTPS-level consumers.
    on_eoc: ?*const fn (ctx: *anyopaque, change: *const CacheChange) void = null,
    /// Called after the state machine's lock is released, by any operation
    /// that called on_data/on_eoc while holding it; see
    /// protocol.DataCallback.on_flush.
    on_flush: ?*const fn (ctx: *anyopaque) void = null,
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

/// An end-of-coherent-set marker: an alive DATA without a payload that either
/// carries no PID_COHERENT_SET (RTPS 2.5 §9.6.4.2 Table 9.22, Examples 2 and
/// 3; SEQUENCENUMBER_UNKNOWN decodes to null) or is a GROUP End Coherent Set
/// sample, which carries PID_GROUP_COHERENT_SET (§8.7.6) and may also repeat
/// the set's PID_COHERENT_SET (§9.6.4.3 Table 9.23).
pub fn isEndMarker(change: *const CacheChange) bool {
    return change.kind == .alive and change.data.len == 0 and
        (change.coherent_set_sn == null or change.group_coherent_sn != null);
}

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
    /// Last accepted heartbeat count for duplicate suppression (§8.3.5.10).
    /// Null until the first heartbeat from this writer is accepted.
    last_hb_count: ?i32,
    /// Last accepted HEARTBEAT_FRAG count for stale-submessage suppression (§8.3.8.13).
    /// Null until the first HEARTBEAT_FRAG from this writer is accepted.
    last_hb_frag_count: ?i32,
    /// True when the remote writer offers RELIABLE delivery.
    reliable: bool,
    /// Which match of the writer this is: a new match gets a new one.
    match_id: u64 = 0,
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
    reassembly: std.AutoArrayHashMapUnmanaged(SequenceNumber, ReassemblyEntry),
    /// True once this proxy has completed the reader-side readiness signal
    /// (or, for BEST_EFFORT proxies, immediately at match -- no handshake
    /// exists). Sticky: never cleared by a later stale/duplicate HEARTBEAT.
    /// Drives the `on_reliable_writer_ready` extended listener callback --
    /// the reader-side counterpart of ReaderProxy.protocol_ready
    /// (writer_sm.zig). Set true when a HEARTBEAT's readerId names this
    /// reader specifically (RTPS §8.3.7.5), never on a wildcard
    /// ENTITYID_UNKNOWN heartbeat, which proves nothing about per-reader
    /// registration.
    protocol_ready: bool = false,
    /// True when this proxy represents the writer's OWN local participant --
    /// i.e. it exists only to bootstrap same-participant builtin-endpoint
    /// matching (see combined.zig's `self_data` call), not a genuinely remote
    /// writer reachable over a lossy network. Set by BuiltinPair.matchRemote.
    /// Suppresses the one-shot match-time AckNack in addMatchedWriter, which
    /// would otherwise be sent, pointlessly, to this participant's own port
    /// forever (RTPS's ACK/NACK retry protocol exists to recover from real
    /// media loss; a same-process match can't lose anything that way).
    is_local: bool = false,

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
        for (self.reassembly.values()) |*entry| entry.deinit(alloc);
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

        // Set bits for SNs we have NOT received. A partly reassembled SN is
        // not negatively acknowledged: its missing fragments go in a
        // NACK_FRAG instead (RTPS 2.5 §8.4.14.1.4).
        var offset: u32 = 0;
        while (offset < num_bits) : (offset += 1) {
            const sn: SequenceNumber = base + @as(i64, offset);
            if (!self.received.contains(sn) and !self.reassembly.contains(sn)) {
                const word: u32 = offset / 32;
                const bit: u5 = @intCast(31 - (offset % 32)); // MSB-first
                bitmap[word] |= @as(u32, 1) << bit;
            }
        }
        return .{ .base = base, .num_bits = num_bits, .bitmap = bitmap };
    }
};

// ── StatefulReader ────────────────────────────────────────────────────────────

/// Bounded, synchronous wire transform, installed before publication. It may not
/// call DDS APIs, block, retain buffers or run cleanup. The participant owns ctx
/// through reader retirement. Failure precedes sequence/history admission.
pub const SampleProcessor = struct {
    ctx: *anyopaque,
    process: *const fn (*anyopaque, []const u8, ChangeKind, [16]u8) anyerror![16]u8,
    retain: ?*const fn (*anyopaque) void = null,
    release: ?*const fn (*anyopaque) void = null,
};

/// Reliable reader with per-writer tracking and ACKNACK generation.
/// Typical use: SEDP endpoint discovery reception.
/// Thread-safe: all public methods lock `mu`.
pub const StatefulReader = struct {
    alloc: std.mem.Allocator,
    guid: Guid,
    transport: Transport,
    cache: HistoryCache,
    writer_proxies: std.ArrayListUnmanaged(WriterProxy),
    callback: ?DataCallback,
    sample_processor: ?SampleProcessor = null,
    /// Per matched writer (see setReassemblyLimits).
    reassembly_limits: ReassemblyLimits = .{},
    mu: mutex_mod.Mutex,
    tracer: trace.Tracer,
    /// When true, out-of-order changes are buffered per WriterProxy and
    /// delivered only when the sequence is contiguous (RTPS §8.4.8 RELIABLE semantics).
    /// When false, changes are delivered immediately on arrival (BEST_EFFORT).
    reliable: bool,
    /// Monotonically increasing count for ACKNACK / NACK_FRAG submessages,
    /// shared by every writer this reader sends them to, as hb_count is in
    /// StatefulWriter. A writer drops counts no higher than the last it
    /// acted on from this reader, and keeps that record when only this
    /// side unmatches it: a count kept per WriterProxy would restart on
    /// rematch, and the writer would ignore this reader until it climbed
    /// back past the old one. Wraps: writers compare counts modulo 2^32.
    ack_count: i32 = 0,
    /// The last WriterProxy.match_id given.
    last_match_id: u64 = 0,
    /// The historical-data waits this reader has still to settle
    /// (`beginHistoryWait`), and whether `closeHistoryWaits` has run.
    /// Guarded by `mu`.
    history_waits: std.ArrayListUnmanaged(*history_wait.Capture) = .empty,
    history_waits_closed: bool = false,
    /// Callback fired when a writer proxy's protocol-ready state
    /// transitions. Mirrors StatefulWriter's identical field.
    protocol_ready_fn: ?*const fn (*anyopaque, Guid, bool) void = null,
    /// Set (under `mu`) whenever on_data/on_eoc ran; the entry
    /// point that then releases `mu` calls on_flush (see takeFlushLocked).
    flush_pending: bool = false,
    protocol_ready_ctx: ?*anyopaque = null,

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

    /// Set before the reader is published.
    pub fn setReassemblyLimits(self: *Self, limits: ReassemblyLimits) void {
        self.reassembly_limits = limits;
    }

    /// Install before the protocol reader is published. Its independent pin
    /// survives deferred adapter teardown and a participant's own release.
    pub fn setSampleProcessor(self: *Self, processor: ?SampleProcessor) void {
        std.debug.assert(self.sample_processor == null);
        if (processor) |p| {
            std.debug.assert((p.retain == null) == (p.release == null));
            if (p.retain) |retain| retain(p.ctx);
        }
        self.sample_processor = processor;
    }

    pub fn deinit(self: *Self) void {
        for (self.writer_proxies.items) |*wp| wp.deinit(self.alloc);
        self.writer_proxies.deinit(self.alloc);
        std.debug.assert(self.history_waits.items.len == 0);
        self.history_waits.deinit(self.alloc);
        self.cache.deinit();
        self.mu.deinit();
        if (self.sample_processor) |p| if (p.release) |release| release(p.ctx);
        self.alloc.destroy(self);
    }

    pub fn setCallback(self: *Self, cb: DataCallback) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.callback = cb;
    }

    /// Under `mu`: if a data callback ran since the last flush, clears the
    /// flag and returns the callback whose on_flush the caller must run after
    /// releasing `mu` (via runFlush). The data callbacks hand changes over
    /// under the lock, which keeps them in order; on_flush is where anything
    /// that reaches application code (listeners) runs.
    fn takeFlushLocked(self: *Self) ?DataCallback {
        if (!self.flush_pending) return null;
        self.flush_pending = false;
        const cb = self.callback orelse return null;
        return if (cb.on_flush != null) cb else null;
    }

    fn runFlush(flush: ?DataCallback) void {
        if (flush) |cb| cb.on_flush.?(cb.ctx);
    }

    /// Register a callback that fires when a writer proxy's protocol-ready
    /// state transitions. Safe to call concurrently with a live receive
    /// thread already dispatching into this reader (addMatchedWriter/
    /// handleHeartbeat/removeMatchedWriter capture protocol_ready_fn/ctx
    /// under self.mu before firing -- see their comments); no ordering
    /// requirement relative to when writer proxies are added. Mirrors
    /// StatefulWriter.setProtocolReadyCallback.
    pub fn setProtocolReadyCallback(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, Guid, bool) void,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.protocol_ready_fn = fn_ptr;
        self.protocol_ready_ctx = ctx;
    }

    /// Like addOrRefreshMatchedWriter, for callers that don't need to know whether the
    /// match was new.
    pub fn addMatchedWriter(self: *Self, proxy: WriterProxy) !void {
        _ = try self.addOrRefreshMatchedWriter(proxy);
    }

    /// addOrRefreshMatchedWriterWith, with nothing held from before the match
    /// and nothing installed alongside: true when the writer is newly matched.
    pub fn addOrRefreshMatchedWriter(self: *Self, proxy: WriterProxy) !bool {
        return try self.addOrRefreshMatchedWriterWith(proxy, null, null) == .added;
    }

    /// Add a matched writer. For a new RELIABLE writer, sends an initial
    /// non-final AckNack to solicit available data (RTPS 2.5 §8.4.2.3); a
    /// BEST_EFFORT reader sends none.
    ///
    /// Re-announcements from an already-matched writer act as lease refreshes:
    /// locators and metadata are updated but the received set, pending_changes,
    /// last_hb_count, and reassembly state are preserved.  This prevents
    /// spurious retransmit bursts caused by re-discovery (e.g. dual network interfaces
    /// presenting the same participant twice).
    ///
    /// A newly matched writer's data that arrived before the match is taken
    /// from `prematch` (see unmatched_cache.zig), if given.
    ///
    /// With `commit`, the match is made only while `commit.is_current`, and
    /// `commit.install` runs with it, in the same critical section (see
    /// MatchCommit): for a new writer, before anything held from it is taken.
    pub fn addOrRefreshMatchedWriterWith(self: *Self, proxy: WriterProxy, prematch: ?*const Prematch, commit: ?MatchCommit) !MatchResult {
        self.mu.lock();
        if (commit) |c| if (!c.is_current(c.ctx)) {
            var discarded = proxy;
            discarded.deinit(self.alloc);
            self.mu.unlock();
            return .superseded;
        };
        for (self.writer_proxies.items) |*wp| {
            if (wp.guid.eql(proxy.guid)) {
                // Lease refresh: update locators/metadata, preserve sequence state
                // (including protocol_ready -- an already-ready proxy stays ready).
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
                wp.is_local = proxy.is_local;
                // Dispose the incoming proxy's empty tracking fields cleanly.
                var discarded = proxy;
                discarded.unicast_locators = .empty;
                discarded.multicast_locators = .empty;
                discarded.selected_locators = .empty;
                discarded.deinit(self.alloc);
                if (commit) |c| c.install(c.ctx, false);
                self.mu.unlock();
                return .refreshed;
            }
        }
        self.writer_proxies.append(self.alloc, proxy) catch |err| {
            self.mu.unlock();
            return err;
        };
        if (commit) |c| c.install(c.ctx, true);
        const new_wp = &self.writer_proxies.items[self.writer_proxies.items.len - 1];
        self.last_match_id += 1;
        new_wp.match_id = self.last_match_id;

        // BEST_EFFORT proxies have no AckNack/Heartbeat handshake (RTPS
        // §8.4.15) to prove targeted delivery, so there's nothing to wait
        // for -- ready immediately. Mirrors StatefulWriter.addMatchedReader's
        // identical BEST_EFFORT branch for on_reliable_reader_ready. Fired
        // after self.mu is released below (never while holding it).
        const newly_ready_guid: ?Guid = blk: {
            if (!new_wp.reliable) {
                new_wp.protocol_ready = true;
                break :blk new_wp.guid;
            }
            break :blk null;
        };

        // Take what the writer sent before the match, as if it had arrived
        // just after it.  Under self.mu, so it all comes ahead of anything the
        // writer sends next.
        const prematch_lost = if (prematch) |pm| self.takePrematchLocked(new_wp, pm) else 0;
        // A pre-emptive ACKNACK on discovering the writer, which RTPS 2.5
        // §8.4.2.3 allows "as an optimization".  RELIABLE only: "A best-effort
        // Reader is completely passive as it only receives data and does not
        // send messages itself" (same section).
        //
        // Skipped for is_local proxies: same-participant matches (see WriterProxy.is_local)
        // can't race a writer-side replay against a lossy network -- write() delivers
        // straight through the normal reliable-writer path over loopback, so there's
        // nothing here to compensate for, only a self-addressed AckNack to send forever.
        if (self.reliable and !new_wp.is_local) self.sendAckNackUnlocked(new_wp, 0, false);
        // Captured under the lock, not re-read from self after unlocking --
        // setProtocolReadyCallback can run concurrently from another thread
        // (it takes the same lock), so self.protocol_ready_fn/ctx are only
        // well-defined to read while self.mu is held.
        const ready_fn = self.protocol_ready_fn;
        const ready_ctx = self.protocol_ready_ctx;
        // Replaying buffered changes above may have delivered data.
        const flush = self.takeFlushLocked();
        const lost_cb = if (prematch_lost > 0) self.callback else null;
        self.mu.unlock();

        if (newly_ready_guid) |guid| {
            if (ready_fn) |f| f(ready_ctx.?, guid, true);
        }
        runFlush(flush);
        if (lost_cb) |cb| if (cb.on_sample_lost) |f| f(cb.ctx, prematch_lost);
        return .added;
    }

    /// A pending on_reliable_writer_ready(false) transition, returned instead
    /// of fired immediately -- see removeMatchedWriterDeferred.
    pub const DeferredReady = struct {
        fn_ptr: *const fn (*anyopaque, Guid, bool) void,
        ctx: *anyopaque,
    };

    /// A pending on_sample_lost report, returned instead of fired
    /// immediately -- see removeMatchedWriterDeferred.
    pub const DeferredLost = struct {
        fn_ptr: *const fn (ctx: *anyopaque, count: i32) void,
        ctx: *anyopaque,
        count: i32,
    };

    /// What removeMatchedWriterDeferred did.
    pub const Removed = struct {
        /// A proxy was removed.
        removed: bool = false,
        ready: ?DeferredReady = null,
        /// History the removed writer announced but never delivered.
        lost: ?DeferredLost = null,
    };

    /// Like removeMatchedWriter, but performs the removal immediately (under
    /// self.mu, as normal) and returns the resulting ready=false transition
    /// instead of firing it -- for callers that need this removal kept
    /// serialized with their OWN external lock (e.g.
    /// DomainParticipantImpl.mu in onWriterLost/onParticipantLost: without
    /// this, a concurrent rediscovery could re-add the same writer between
    /// that lock being released and a deferred plain removeMatchedWriter
    /// call actually running, and the stale removal would wrongly undo the
    /// fresh match) while still firing the callback only once that external
    /// lock is released. Caller must fire the returned transition itself.
    /// When a proxy is removed, `unmatch` (if given) removes the caller's own
    /// state for the writer in the same critical section. History the writer
    /// announced but never delivered can no longer arrive, so it is returned
    /// as lost: the historical-data wait stops counting the writer, and
    /// SAMPLE_LOST shows what it never got.
    pub fn removeMatchedWriterDeferred(self: *Self, guid: Guid, unmatch: ?UnmatchCommit) Removed {
        self.mu.lock();
        defer self.mu.unlock();
        var out: Removed = .{};
        var was_ready = false;
        var lost: i32 = 0;
        var i: usize = self.writer_proxies.items.len;
        while (i > 0) {
            i -= 1;
            if (self.writer_proxies.items[i].guid.eql(guid)) {
                was_ready = was_ready or self.writer_proxies.items[i].protocol_ready;
                lost +|= undeliveredHistory(&self.writer_proxies.items[i]);
                self.writer_proxies.items[i].deinit(self.alloc);
                _ = self.writer_proxies.swapRemove(i);
                out.removed = true;
            }
        }
        if (out.removed) if (unmatch) |u| u.remove(u.ctx, guid);
        if (out.removed) self.settleHistoryWaitsLocked();
        if (lost > 0) if (self.callback) |cb| if (cb.on_sample_lost) |f| {
            out.lost = .{ .fn_ptr = f, .ctx = cb.ctx, .count = lost };
        };
        if (!was_ready) return out;
        const f = self.protocol_ready_fn orelse return out;
        out.ready = .{ .fn_ptr = f, .ctx = self.protocol_ready_ctx.? };
        return out;
    }

    pub fn removeMatchedWriter(self: *Self, guid: Guid) void {
        // Fired after self.mu is released (never while holding it) -- mirrors
        // StatefulWriter.removeMatchedReader's identical pattern. Lets an
        // application using on_reliable_writer_ready know a writer it was
        // told is ready has gone away, rather than staying convinced it's
        // still ready indefinitely.
        const r = self.removeMatchedWriterDeferred(guid, null);
        if (r.lost) |l| l.fn_ptr(l.ctx, l.count);
        if (r.ready) |d| d.fn_ptr(d.ctx, guid, false);
    }

    /// Samples up to `wp`'s history floor never delivered: those that never
    /// arrived, plus those held behind them in `pending_changes`. SNs a GAP
    /// already marked (and counted) lost are neither. Zero until the first
    /// HEARTBEAT sets the floor, and for writers with no history to deliver
    /// (their floor stays 0).
    fn undeliveredHistory(wp: *const WriterProxy) i32 {
        if (!wp.history_established) return 0;
        const ack = wp.received.cumulativeAck();
        const floor = wp.history_floor_sn;
        if (floor <= ack) return 0;
        var n = (floor - ack) - wp.received.countBetween(ack + 1, floor);
        for (wp.pending_changes.items) |*ch| {
            if (ch.sequence_number <= floor and !isEndMarker(ch)) n += 1;
        }
        return @intCast(@min(n, std.math.maxInt(i32)));
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
    /// BEST_EFFORT (reliable=false): adds to cache and delivers immediately,
    /// unless its SN is at or below the highest received from that writer
    /// (RTPS 2.5 §8.4.12.1.4, T2), in which case it is dropped.
    /// RELIABLE (reliable=true): buffers out-of-order changes per WriterProxy;
    /// fires the callback only when the sequence is contiguous (RTPS §8.4.8).
    /// Data from a writer not yet matched is ignored here; the participant
    /// holds it until the match (see addOrRefreshMatchedWriterWith).
    pub fn handleData(self: *Self, writer_guid: Guid, change: CacheChange) !void {
        self.mu.lock();
        defer {
            const flush = self.takeFlushLocked();
            self.mu.unlock();
            runFlush(flush);
        }

        var wp: ?*WriterProxy = null;
        for (self.writer_proxies.items) |*w| {
            if (w.guid.eql(writer_guid)) {
                wp = w;
                break;
            }
        }
        // Data from a writer not matched yet: the participant holds it, if
        // anything is to (see unmatched_cache.zig).
        if (wp == null) return;

        const sn = change.sequence_number;
        if (wp.?.received.contains(sn)) {
            self.tracer.submit(.{ .recv_data_dup = .{
                .src_prefix = writer_guid.prefix,
                .dst_prefix = self.guid.prefix,
                .writer_eid = writer_guid.entity_id,
                .sn = sn,
            } });
            return;
        }
        try self.deliverChangeLocked(wp.?, change);
    }

    /// Handle a received DATA_FRAG submessage.  Accumulates fragments into a
    /// reassembly buffer; delivers the complete change once all fragments arrive.
    /// Fragments from a writer not yet matched are ignored, as in handleData.
    pub fn handleDataFrag(self: *Self, writer_guid: Guid, source_timestamp: time_mod.RtpsTimestamp, df: msg.submessage.DataFragSubmessage) !void {
        self.mu.lock();
        // As in handleGap.
        var samples_lost: i32 = 0;
        defer {
            const lost_cb = if (samples_lost > 0) self.callback else null;
            const flush = self.takeFlushLocked();
            self.mu.unlock();
            runFlush(flush);
            if (lost_cb) |cb| if (cb.on_sample_lost) |f| f(cb.ctx, samples_lost);
        }

        var wp: ?*WriterProxy = null;
        for (self.writer_proxies.items) |*w| {
            if (w.guid.eql(writer_guid)) {
                wp = w;
                break;
            }
        }
        // As for handleData.
        if (wp == null) return;

        const sn = df.writer_sn;
        if (wp.?.received.contains(sn)) return; // already delivered
        // BEST_EFFORT: a sample at or below the highest received can no
        // longer be delivered (see deliverChangeLocked); don't reassemble it.
        if (!self.reliable and sn <= wp.?.received.max()) return;

        // Validate fragment parameters to avoid divide-by-zero or huge allocs.
        if (df.fragment_size == 0 or df.data_size == 0) return;

        const total_frags: u32 = (df.data_size + df.fragment_size - 1) / df.fragment_size;

        if (wp.?.reassembly.getPtr(sn) == null) {
            switch (self.admitReassemblyLocked(wp.?, sn, df.data_size)) {
                .start => {},
                .skip => return,
                .never => {
                    samples_lost = self.settleTooLargeLocked(wp.?, sn, df.data_size);
                    return;
                },
            }
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
        entry.captureInlineQos(df);
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
            .coherent_set_sn = entry.coherent_set_sn,
            .group_seq_num = entry.group_seq_num,
            .group_coherent_sn = entry.group_coherent_sn,
        };
        // Retire the completed buffer even when validation/admission fails. A
        // retransmission may rebuild it; no stale completed buffer pins memory.
        defer {
            var removed = wp.?.reassembly.fetchSwapRemove(sn).?;
            removed.value.received.deinit();
            self.alloc.free(removed.value.data);
        }
        try self.deliverChangeLocked(wp.?, change);
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

    const Admission = enum { start, skip, never };

    /// Whether `wp` may start reassembling `sn`, which declares `size` bytes,
    /// within `reassembly_limits`. Past a limit, the held sample furthest
    /// from delivery goes, or `sn` is skipped when it is furthest. Reliable
    /// delivery waits on the lowest SN, so the highest is furthest from it;
    /// best effort keeps the newest, so there the lowest is.
    fn admitReassemblyLocked(self: *Self, wp: *WriterProxy, sn: SequenceNumber, size: u32) Admission {
        const lim = self.reassembly_limits;
        if (lim.max_bytes != 0 and size > lim.max_bytes) return .never;
        const map = &wp.reassembly;
        while (true) {
            var bytes: u64 = size;
            for (map.values()) |e| bytes += e.data_size;
            const full = (lim.max_samples != 0 and map.count() >= lim.max_samples) or
                (lim.max_bytes != 0 and bytes > lim.max_bytes);
            if (!full) return .start;
            var far: ?usize = null;
            var far_sn = sn;
            for (map.keys(), 0..) |k, i| {
                if (if (self.reliable) k > far_sn else k < far_sn) {
                    far = i;
                    far_sn = k;
                }
            }
            const i = far orelse return .skip;
            map.values()[i].deinit(self.alloc);
            map.swapRemoveAt(i);
        }
    }

    /// Settles `sn`, which declares more bytes than reassembly allows, as a
    /// GAP would: asking for it again cannot help. Returns the samples lost:
    /// 1, or 0 for a best-effort reader, which never asks again anyway.
    fn settleTooLargeLocked(self: *Self, wp: *WriterProxy, sn: SequenceNumber, size: u32) i32 {
        if (!self.reliable) return 0;
        log.rtps.warn("StatefulReader({x}): sample {d} declares {d} bytes, past the reassembly limit of {d}; counted lost", .{
            self.guid.entity_id.entity_key, sn, size, self.reassembly_limits.max_bytes,
        });
        const prev_highest = wp.received.cumulativeAck();
        if (!(wp.received.insert(self.alloc, sn) catch return 0)) return 0;
        self.deliverPendingLocked(wp, prev_highest);
        return 1;
    }

    /// NACK_FRAGs for the partly reassembled SNs up to `last_sn`. A HEARTBEAT
    /// lists only SNs with every fragment available (RTPS 2.5 §8.4.14.1.4).
    fn sendPartialNackFragsLocked(self: *Self, wp: *WriterProxy, last_sn: SequenceNumber) void {
        const floor = wp.received.cumulativeAck();
        var it = wp.reassembly.iterator();
        while (it.next()) |e| {
            const sn = e.key_ptr.*;
            if (sn <= floor or sn > last_sn or wp.received.contains(sn)) continue;
            self.sendNackFragLocked(wp, sn, e.value_ptr, e.value_ptr.total_frags);
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

        self.ack_count +%= 1;
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(wp.guid.prefix);
        b.addNackFrag(self.guid.entity_id, wp.guid.entity_id, writer_sn, frag_set, self.ack_count);
        for (locs) |loc| writer_sm.sendIovecs(self.transport, &loc, b.iovecs()) catch {};
    }

    /// Deliver a complete change (DATA or fully-assembled DATA_FRAG) to the cache
    /// and callback.  Handles RELIABLE ordering and BEST_EFFORT immediate delivery.
    /// Called under self.mu.  Does NOT check for duplicates — callers must guard.
    fn deliverChangeLocked(self: *Self, wp: *WriterProxy, incoming: CacheChange) !void {
        var change = incoming;
        // Applies to DATA, reassembled DATA_FRAG and prematch replay alike.
        // End markers are protocol metadata, not application samples.
        if (!isEndMarker(&change)) if (self.sample_processor) |processor| {
            change.key_hash = try processor.process(processor.ctx, change.data, change.kind, change.key_hash);
        };
        const sn = change.sequence_number;

        // A BEST_EFFORT reader takes only SNs above the highest it has had
        // from this writer (RTPS 2.5 §8.4.12.1.4, T2): no duplicates, and
        // nothing out of order.
        if (!self.reliable and sn <= wp.received.max()) {
            self.tracer.submit(.{ .recv_data_dup = .{
                .src_prefix = change.writer_guid.prefix,
                .dst_prefix = self.guid.prefix,
                .writer_eid = change.writer_guid.entity_id,
                .sn = sn,
            } });
            return;
        }

        self.tracer.submit(.{ .recv_data = .{
            .src_prefix = change.writer_guid.prefix,
            .dst_prefix = self.guid.prefix,
            .writer_eid = change.writer_guid.entity_id,
            .reader_eid = self.guid.entity_id,
            .sn = sn,
            .key_hash = change.key_hash,
            .data_len = @intCast(change.data.len),
        } });

        // End-of-coherent-set marker: track the SN in received (to avoid
        // perpetual NACKs) but never add it to the application-visible cache;
        // the DCPS layer gets it through on_eoc instead of on_data.
        const is_eoc = isEndMarker(&change);

        if (self.reliable) {
            const prev_highest = wp.received.cumulativeAck();
            if (sn == prev_highest + 1) {
                _ = wp.received.insert(self.alloc, sn) catch {};
                if (!is_eoc) {
                    try self.cache.addReaderChange(change);
                    if (self.callback) |cb| {
                        if (self.cache.getChangeForWriter(change.writer_guid, sn)) |cached| cb.on_data(cb.ctx, cached);
                        self.flush_pending = true;
                    }
                } else {
                    // EOC marker: not cached, but notify the DCPS layer so it can
                    // flush the coherent WIP without adding a data sample to pending.
                    if (self.callback) |cb| if (cb.on_eoc) |f| {
                        f(cb.ctx, &change);
                        self.flush_pending = true;
                    };
                }
                self.deliverPendingLocked(wp, sn);
            } else {
                // Out-of-order: check if already buffered.
                for (wp.pending_changes.items) |pc| {
                    if (pc.sequence_number == sn) return;
                }
                // Buffer the change (including EOC markers, which have data.len == 0)
                // so deliverPendingLocked can fire on_eoc when the gap fills.  Without
                // buffering the EOC, the writer's coherent set would never end.
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
            dropReassemblyBelow(self.alloc, wp, sn);
            if (!is_eoc) {
                try self.cache.addReaderChange(change);
                if (self.callback) |cb| {
                    if (self.cache.getChangeForWriter(change.writer_guid, sn)) |ch| cb.on_data(cb.ctx, ch);
                    self.flush_pending = true;
                }
            } else if (self.callback) |cb| if (cb.on_eoc) |f| {
                f(cb.ctx, &change);
                self.flush_pending = true;
            };
        }
    }

    /// Frees a BEST_EFFORT proxy's partly reassembled samples below `sn`:
    /// once `sn` is received they can no longer be delivered.
    /// Takes `pm`'s copies of what `wp`'s writer sent this reader before the
    /// match: samples are delivered in SN order, so a BEST_EFFORT reader
    /// drops none of them as out of order (see deliverChangeLocked), and
    /// partly reassembled ones carry on in `wp`.  Out of memory, it takes
    /// nothing: a RELIABLE reader then gets it all by repair.
    /// Returns the samples it counted lost.
    fn takePrematchLocked(self: *Self, wp: *WriterProxy, pm: *const Prematch) i32 {
        var held: unmatched_mod.Collected = .{};
        defer held.deinit(self.alloc);
        pm.collect(self.alloc, wp.guid, self.guid.entity_id, &held) catch return 0;
        var lost: i32 = 0;
        for (held.samples.items) |ch| {
            if (wp.received.contains(ch.sequence_number)) continue;
            self.deliverChangeLocked(wp, ch) catch {};
        }
        var i = held.partials.items.len;
        while (i > 0) {
            i -= 1;
            const p = &held.partials.items[i];
            if (wp.received.contains(p.sn) or wp.reassembly.contains(p.sn)) continue;
            if (!self.reliable and p.sn <= wp.received.max()) continue;
            switch (self.admitReassemblyLocked(wp, p.sn, p.entry.data_size)) {
                .start => {},
                .skip => continue,
                .never => {
                    lost += self.settleTooLargeLocked(wp, p.sn, p.entry.data_size);
                    continue;
                },
            }
            wp.reassembly.put(self.alloc, p.sn, p.entry) catch continue;
            // Now wp's.
            _ = held.partials.swapRemove(i);
        }
        return lost;
    }

    /// Frees partly reassembled samples a GAP settled: their SNs are now
    /// accounted for, so the rest of their fragments never arrives.
    fn dropSettledReassembly(alloc: std.mem.Allocator, wp: *WriterProxy) void {
        dropReassemblyIf(alloc, wp, 0, struct {
            fn settled(w: *const WriterProxy, sn: SequenceNumber, _: SequenceNumber) bool {
                return w.received.contains(sn);
            }
        }.settled);
    }

    fn dropReassemblyBelow(alloc: std.mem.Allocator, wp: *WriterProxy, sn: SequenceNumber) void {
        dropReassemblyIf(alloc, wp, sn, struct {
            fn below(_: *const WriterProxy, k: SequenceNumber, limit: SequenceNumber) bool {
                return k < limit;
            }
        }.below);
    }

    /// Frees `wp`'s partly reassembled samples whose SN `drop` picks, in one
    /// pass: walking down, a swap-remove moves in only an entry already seen.
    fn dropReassemblyIf(
        alloc: std.mem.Allocator,
        wp: *WriterProxy,
        arg: SequenceNumber,
        comptime drop: fn (*const WriterProxy, SequenceNumber, SequenceNumber) bool,
    ) void {
        var i = wp.reassembly.count();
        while (i > 0) {
            i -= 1;
            if (!drop(wp, wp.reassembly.keys()[i], arg)) continue;
            wp.reassembly.values()[i].deinit(alloc);
            wp.reassembly.swapRemoveAt(i);
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
                    const is_eoc = isEndMarker(&pending_ch);
                    if (!is_eoc) {
                        self.cache.addReaderChange(pending_ch) catch {};
                        if (self.callback) |cb| {
                            if (self.cache.getChangeForWriter(pending_ch.writer_guid, next_sn)) |cached| {
                                cb.on_data(cb.ctx, cached);
                            }
                            self.flush_pending = true;
                        }
                    } else {
                        if (self.callback) |cb| if (cb.on_eoc) |f| {
                            f(cb.ctx, &pending_ch);
                            self.flush_pending = true;
                        };
                    }
                    break;
                }
            }
        }
        // Delivered in order up to here: the history a wait counts on may
        // now be in the cache.
        self.settleHistoryWaitsLocked();
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
        reader_id: EntityId,
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

        // Fired after self.mu is released below (never while holding it):
        // this reaches arbitrary user listener code via DataReaderImpl.
        // notifyWriterProtocolReady, which must never run under this lock.
        var newly_ready_guid: ?Guid = null;
        // Reported after self.mu is released below, like newly_ready_guid:
        // on_sample_lost reaches the DCPS reader's listener (application
        // code), which must not run under this lock.
        var samples_lost: i32 = 0;

        for (self.writer_proxies.items) |*wp| {
            if (!wp.guid.eql(writer_guid)) continue;

            // Duplicate / stale heartbeat suppression.
            if (wp.last_hb_count) |last| {
                const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
                if (diff <= 0) {
                    self.tracer.submit(.{ .recv_heartbeat_dup = .{
                        .src_prefix = writer_guid.prefix,
                        .dst_prefix = self.guid.prefix,
                        .writer_eid = writer_guid.entity_id,
                        .count = count,
                    } });
                    continue; // stale or duplicate
                }
            }
            const is_first_hb = wp.last_hb_count == null;
            wp.last_hb_count = count;

            // reader_id names this reader specifically (RTPS §8.3.7.5): the
            // writer could only construct that if it already has a
            // ReaderProxy for us, so this is retroactive proof
            // addMatchedReader has already run on the writer's side. A
            // wildcard ENTITYID_UNKNOWN heartbeat proves nothing about
            // per-reader registration and must not trigger this -- see
            // docs/design/discovery-association-race-testing.md.
            if (!wp.protocol_ready and reader_id.eql(self.guid.entity_id)) {
                wp.protocol_ready = true;
                newly_ready_guid = wp.guid;
            }

            // On the first HEARTBEAT from a transient-local writer, record last_sn as
            // the floor: the reader needs to receive every SN up to that point before
            // wait_for_historical_data can return.
            if (is_first_hb and !wp.history_established) {
                wp.history_floor_sn = last_sn;
                wp.history_established = true;
                // The history may be none, or here already.
                self.settleHistoryWaitsLocked();
            }

            self.tracer.submit(.{ .recv_heartbeat = .{
                .src_prefix = writer_guid.prefix,
                .dst_prefix = self.guid.prefix,
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
                dropSettledReassembly(self.alloc, wp);
                self.deliverPendingLocked(wp, prev_highest);
                samples_lost += lost_count;
            }

            // Only RELIABLE readers send ACKNACK; BEST_EFFORT readers ignore HEARTBEATs.
            if (!self.reliable) continue;

            // Send ACKNACK if: non-final heartbeat, or we have missing SNs.
            const has_missing = wp.received.cumulativeAck() < last_sn;
            if (!final or has_missing) {
                self.sendAckNackLocked(wp, last_sn, !has_missing);
                self.sendPartialNackFragsLocked(wp, last_sn);
            }
        }

        // See addMatchedWriter's matching comment: capture under the lock.
        const ready_fn = self.protocol_ready_fn;
        const ready_ctx = self.protocol_ready_ctx;
        const lost_cb = if (samples_lost > 0) self.callback else null;
        const flush = self.takeFlushLocked();
        self.mu.unlock();

        if (newly_ready_guid) |guid| {
            if (ready_fn) |f| f(ready_ctx.?, guid, true);
        }
        runFlush(flush);
        if (lost_cb) |cb| if (cb.on_sample_lost) |f| f(cb.ctx, samples_lost);
    }

    /// Handle a received GAP: treat the listed SNs as irreversibly unavailable.
    pub fn handleGap(
        self: *Self,
        writer_guid: Guid,
        gap_start: SequenceNumber,
        gap_list: SequenceNumberSet,
    ) void {
        self.mu.lock();
        // Reported after self.mu is released: on_sample_lost reaches the DCPS
        // reader's listener (application code), which must not run under
        // this lock.
        var samples_lost: i32 = 0;
        defer {
            const lost_cb = if (samples_lost > 0) self.callback else null;
            const flush = self.takeFlushLocked();
            self.mu.unlock();
            runFlush(flush);
            if (lost_cb) |cb| if (cb.on_sample_lost) |f| f(cb.ctx, samples_lost);
        }

        for (self.writer_proxies.items) |*wp| {
            if (!wp.guid.eql(writer_guid)) continue;
            self.tracer.submit(.{ .recv_gap = .{
                .src_prefix = writer_guid.prefix,
                .dst_prefix = self.guid.prefix,
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
            dropSettledReassembly(self.alloc, wp);
            // Deliver any buffered pending changes that are now contiguous.
            if (self.reliable) self.deliverPendingLocked(wp, prev_highest);
            samples_lost += lost_count;
        }
    }

    /// Whether `wp` still owes this reader history: its first HEARTBEAT has
    /// not set how much, or what it set has not all been delivered in
    /// order. A writer with no history to deliver never does.
    fn owesHistory(wp: *const WriterProxy) bool {
        return !wp.history_established or wp.received.cumulativeAck() < wp.history_floor_sn;
    }

    /// Begins `cap`, a reader's part of a historical-data wait: captures
    /// the matched writers that owe it history, and keeps `cap` to settle
    /// once none does
    /// (docs/design/concurrency/operations.md#historical-data-wait-contract).
    /// Settles it at once if none owes any, or `closed` if the reader has
    /// closed. `cap.waiter` must expect it; `endHistoryWait` ends it either
    /// way.
    pub fn beginHistoryWait(self: *Self, cap: *history_wait.Capture) error{OutOfMemory}!void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.history_waits_closed) return cap.waiter.settle(.closed);
        var n: usize = 0;
        for (self.writer_proxies.items) |*wp| {
            if (owesHistory(wp)) n += 1;
        }
        if (n == 0) return cap.waiter.satisfied();
        const sources = try self.alloc.alloc(history_wait.Capture.Source, n);
        errdefer self.alloc.free(sources);
        try self.history_waits.append(self.alloc, cap);
        n = 0;
        for (self.writer_proxies.items) |*wp| {
            if (!owesHistory(wp)) continue;
            sources[n] = .{ .guid = wp.guid, .match_id = wp.match_id };
            n += 1;
        }
        cap.sources = sources;
        cap.registered = true;
    }

    /// Ends `cap`, settled or not: the reader no longer settles it.
    pub fn endHistoryWait(self: *Self, cap: *history_wait.Capture) void {
        {
            self.mu.lock();
            defer self.mu.unlock();
            if (cap.registered) {
                const i = std.mem.indexOfScalar(*history_wait.Capture, self.history_waits.items, cap).?;
                _ = self.history_waits.swapRemove(i);
                cap.registered = false;
            }
        }
        self.alloc.free(cap.sources);
        cap.sources = &.{};
    }

    /// Settles every historical-data wait not yet settled `closed` as the
    /// reader closes, before its writers go. A later `beginHistoryWait`
    /// settles at once.
    pub fn closeHistoryWaits(self: *Self) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.history_waits_closed = true;
        for (self.history_waits.items) |cap| {
            cap.registered = false;
            cap.waiter.settleClose(.closed);
        }
        self.history_waits.clearRetainingCapacity();
    }

    /// Settles the historical-data waits whose captured writers have each
    /// delivered their history: satisfied, or timed out once past the
    /// deadline. One whose writer unmatched first, even to match again, is
    /// `part_failed`: that match's history can no longer arrive. Caller
    /// must hold `mu`.
    fn settleHistoryWaitsLocked(self: *Self) void {
        var i = self.history_waits.items.len;
        while (i > 0) {
            i -= 1;
            const cap = self.history_waits.items[i];
            const outcome = self.historyOutcomeLocked(cap) orelse continue;
            _ = self.history_waits.swapRemove(i);
            cap.registered = false;
            switch (outcome) {
                .satisfied => if (cap.waiter.expired()) cap.waiter.settle(.timed_out) else cap.waiter.satisfied(),
                else => cap.waiter.settle(outcome),
            }
        }
    }

    /// The outcome `cap` is settled with now, or null while a captured
    /// writer still owes history.
    /// A writer that has delivered stays done, whatever happens to it after.
    fn historyOutcomeLocked(self: *Self, cap: *history_wait.Capture) ?history_wait.Outcome {
        var owed = false;
        for (cap.sources) |*src| {
            if (src.done) continue;
            const wp = self.writerProxyLocked(src.guid) orelse return .part_failed;
            if (wp.match_id != src.match_id) return .part_failed;
            if (owesHistory(wp)) owed = true else src.done = true;
        }
        return if (owed) null else .satisfied;
    }

    fn writerProxyLocked(self: *Self, guid: Guid) ?*const WriterProxy {
        for (self.writer_proxies.items) |*wp| {
            if (wp.guid.eql(guid)) return wp;
        }
        return null;
    }

    fn sendAckNackLocked(self: *Self, wp: *WriterProxy, last_sn: SequenceNumber, final: bool) void {
        const locs = wp.effectiveLocators();
        if (locs.len == 0) return;
        self.ack_count +%= 1;
        const sns = wp.missingSnSet(last_sn);
        self.tracer.submit(.{ .send_acknack = .{
            .src_prefix = self.guid.prefix,
            .dst_prefix = wp.guid.prefix,
            .reader_eid = self.guid.entity_id,
            .writer_eid = wp.guid.entity_id,
            .base_sn = sns.base,
            .bitmap = sns,
            .count = self.ack_count,
            .final = final,
        } });
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(wp.guid.prefix);
        b.addAckNack(
            self.guid.entity_id,
            wp.guid.entity_id,
            sns,
            self.ack_count,
            final,
        );
        for (locs) |loc| {
            writer_sm.sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                error.UnsupportedLocatorKind => {},
                else => log.rtps.warn("StatefulReader.sendAckNack: {}", .{err}),
            };
        }
    }

    /// Like sendAckNackLocked, but for callers where it is the last thing
    /// done before returning (currently just addMatchedWriter): releases
    /// self.mu before touching the transport, then reacquires it so the
    /// caller's own `defer self.mu.unlock()` still balances correctly.
    ///
    /// Why: MemoryTransport (used by IntraProcessDelivery, zzdds's own DCPS
    /// conformance-testing harness) delivers synchronously and can reenter
    /// the matched writer's own locked code (StatefulWriter.handleAckNack)
    /// from inside this call -- which, combined with the writer's own
    /// writer.mu -> reader.mu path (write() -> sendChangeToAllLocked), is a
    /// genuine reader.mu <-> writer.mu lock-order cycle (confirmed via
    /// TSan). Not applied to sendAckNackLocked itself or its other caller
    /// (handleHeartbeat, which loops over self.writer_proxies.items and
    /// would need the whole list snapshotted first to release the lock
    /// safely there too -- out of scope for this fix).
    fn sendAckNackUnlocked(self: *Self, wp: *WriterProxy, last_sn: SequenceNumber, final: bool) void {
        const locs = wp.effectiveLocators();
        if (locs.len == 0) return;
        self.ack_count +%= 1;
        const sns = wp.missingSnSet(last_sn);
        const count = self.ack_count;
        self.tracer.submit(.{ .send_acknack = .{
            .src_prefix = self.guid.prefix,
            .dst_prefix = wp.guid.prefix,
            .reader_eid = self.guid.entity_id,
            .writer_eid = wp.guid.entity_id,
            .base_sn = sns.base,
            .bitmap = sns,
            .count = count,
            .final = final,
        } });
        // locs is a slice into wp.selected_locators -- copy the values out
        // before releasing self.mu, since a concurrent mutation of wp's
        // locators while unlocked would otherwise invalidate this slice.
        var locs_buf: [8]Locator = undefined;
        const n_locs = @min(locs.len, locs_buf.len);
        @memcpy(locs_buf[0..n_locs], locs[0..n_locs]);
        const self_guid = self.guid;
        const wp_guid = wp.guid;
        const transport = self.transport;

        self.mu.unlock();
        defer self.mu.lock();

        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self_guid.prefix);
        b.addInfoDst(wp_guid.prefix);
        b.addAckNack(self_guid.entity_id, wp_guid.entity_id, sns, count, final);
        for (locs_buf[0..n_locs]) |loc| {
            writer_sm.sendIovecs(transport, &loc, b.iovecs()) catch |err| switch (err) {
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
        .prefix = .{ .bytes = @as([12]u8, @splat(b)) },
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
pub const test_null_vtable = Transport.Vtable{
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

test "StatefulReader BEST_EFFORT drops duplicates and earlier SNs after a late first sample" {
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

    // An earlier SN arriving after it is dropped too: a BEST_EFFORT reader
    // takes only SNs above the highest received (RTPS 2.5 §8.4.12.1.4, T2).
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
    try testing.expectEqual(@as(usize, 1), deliveries);
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

const test_unmatched_limits = unmatched_mod.Limits{ .max_bytes = 1 << 20, .max_writers = 8, .max_samples_per_writer = 64, .max_partials_per_writer = 4 };

test "StatefulReader takes data held from before the match on addOrRefreshMatchedWriterWith" {
    // DATA arriving before the match is held by the participant (here, put
    // straight into the cache) and taken on the match.  For in-order SN=1
    // it is delivered at once.
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

    // DATA arrives before the writer is matched: the reader ignores it.
    try reader.handleData(writer_guid, change);
    try testing.expectEqual(@as(usize, 0), delivered);
    var held = UnmatchedCache.init(testing.allocator, test_unmatched_limits);
    defer held.deinit();
    held.put(writer_guid, guid_mod.EntityIds.unknown, &change, true, 0, std.time.ns_per_s);

    // The match takes SN=1 from the cache, in order → delivered, after the
    // caller's state for the writer is installed.
    const Install = struct {
        delivered: *usize,
        delivered_at_install: ?usize = null,
        fn isCurrent(_: *anyopaque) bool {
            return true;
        }
        fn install(ctx: *anyopaque, _: bool) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.delivered_at_install = self.delivered.*;
        }
    };
    var install: Install = .{ .delivered = &delivered };
    const proxy = try WriterProxy.init(testing.allocator, writer_guid, &.{}, &.{}, true);
    _ = try reader.addOrRefreshMatchedWriterWith(proxy, &.{ .cache = &held }, .{ .ctx = &install, .is_current = Install.isCurrent, .install = Install.install });
    try testing.expectEqual(@as(?usize, 0), install.delivered_at_install);
    try testing.expectEqual(@as(usize, 1), delivered);
    // Left for any other reader that matches the writer.
    try testing.expectEqual(@as(usize, 1), held.writerCount());
}

test "StatefulReader held data from before the match: out-of-order SN delivered by heartbeat GAP fill" {
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

    // SN=30 arrives before the writer is matched, and is held.
    var held = UnmatchedCache.init(testing.allocator, test_unmatched_limits);
    defer held.deinit();
    held.put(writer_guid, guid_mod.EntityIds.unknown, &change, true, 0, std.time.ns_per_s);

    // The match takes SN=30, out of order (cumAck=0, need SN=1 first).
    const proxy = try WriterProxy.init(testing.allocator, writer_guid, &.{}, &.{}, true);
    _ = try reader.addOrRefreshMatchedWriterWith(proxy, &.{ .cache = &held }, null);
    try testing.expectEqual(@as(usize, 0), delivered); // still waiting for gap fill

    // Empty HEARTBEAT (first_sn=30, last_sn=29): writer history starts at SN=30,
    // so SNs 1-29 never existed.  Virtual GAP fill advances cumAck to 29 →
    // deliverPendingLocked delivers the buffered SN=30.
    reader.handleHeartbeat(writer_guid, guid_mod.EntityIds.unknown, 30, 29, 1, true);
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

test "StatefulReader DATA_FRAG: source_timestamp and key_hash preserved through reassembly held from before the match" {
    // Same as above but the writer is not yet matched when fragments arrive:
    // reassembled in the cache, then taken on the match.  The assembled
    // CacheChange must carry the original timestamp and key_hash, not defaults.
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
    var held = UnmatchedCache.init(testing.allocator, test_unmatched_limits);
    defer held.deinit();
    held.putFrag(wguid, guid_mod.EntityIds.unknown, frag1, expected_ts, 0, std.time.ns_per_s);
    held.putFrag(wguid, guid_mod.EntityIds.unknown, frag2, ZERO_TS, 0, std.time.ns_per_s);

    // The match takes SN=1, in order → delivered immediately.
    const proxy = try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, true);
    _ = try reader.addOrRefreshMatchedWriterWith(proxy, &.{ .cache = &held }, null);

    try testing.expectEqual(expected_ts, ctx.ts);
    try testing.expectEqual(expected_kh, ctx.kh);
}

test "StatefulReader DATA_FRAG: a reassembly started before the match finishes after it" {
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };
    const reader = try StatefulReader.init(testing.allocator, makeGuid(32, 0xC7), null_transport, .keep_all, 0, false);
    defer reader.deinit();

    const Ctx = struct {
        data: [8]u8 = undefined,
        n: usize = 0,
        fn onData(ctx: *anyopaque, change: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            @memcpy(&self.data, change.data[0..8]);
            self.n += 1;
        }
    };
    var ctx = Ctx{};
    reader.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData });

    const wguid = makeGuid(32, 0xC2);
    var frag1_bytes = [_]u8{ 1, 2, 3, 4 };
    var frag2_bytes = [_]u8{ 5, 6, 7, 8 };
    var frag = msg.submessage.DataFragSubmessage{
        .flags = 0,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = 1,
        .fragment_starting_num = 1,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 8,
        .inline_qos = null,
        .serialized_payload = &frag1_bytes,
    };
    var held = UnmatchedCache.init(testing.allocator, test_unmatched_limits);
    defer held.deinit();
    held.putFrag(wguid, guid_mod.EntityIds.unknown, frag, ZERO_TS, 0, std.time.ns_per_s);

    const proxy = try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, false);
    _ = try reader.addOrRefreshMatchedWriterWith(proxy, &.{ .cache = &held }, null);
    try testing.expectEqual(@as(usize, 0), ctx.n);

    frag.fragment_starting_num = 2;
    frag.serialized_payload = &frag2_bytes;
    try reader.handleDataFrag(wguid, ZERO_TS, frag);
    try testing.expectEqual(@as(usize, 1), ctx.n);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &ctx.data);
}

/// Records each message a reader sends, for tests that check its replies.
const CaptureTransport = struct {
    msgs: [8][512]u8 = undefined,
    lens: [8]usize = undefined,
    n: usize = 0,

    fn send(ctx: *anyopaque, _: *const Locator, bytes: []const u8) anyerror!void {
        const self: *CaptureTransport = @ptrCast(@alignCast(ctx));
        if (self.n == self.msgs.len or bytes.len > 512) return error.TestCaptureFull;
        @memcpy(self.msgs[self.n][0..bytes.len], bytes);
        self.lens[self.n] = bytes.len;
        self.n += 1;
    }

    const vtable = Transport.Vtable{
        .capabilities = .{},
        .can_reach = TestNullCtx.canReach,
        .send = send,
        .listen = TestNullCtx.listen,
        .join_multicast = TestNullCtx.joinMulticast,
        .leave_multicast = TestNullCtx.leaveMulticast,
        .unlisten = TestNullCtx.unlisten,
        .unicast_locators = TestNullCtx.unicastLocators,
        .set_locator_change_handler = TestNullCtx.setLocatorChangeHandler,
        .close = TestNullCtx.close,
    };

    fn transport(self: *CaptureTransport) Transport {
        return .{ .ctx = self, .vtable = &vtable };
    }

    /// The submessages sent, in order, other than INFO_DST.
    fn submessages(self: *CaptureTransport, out: []msg.SubMessage) !usize {
        var params: [4]msg.InlineQosParam = undefined;
        var k: usize = 0;
        for (self.msgs[0..self.n], self.lens[0..self.n]) |*m, len| {
            var it = try msg.MessageIterator.init(m[0..len]);
            while (try it.next(&params)) |sm| {
                if (sm == .info_dst) continue;
                out[k] = sm;
                k += 1;
            }
        }
        return k;
    }
};

fn testFrag(sn: SequenceNumber, frag: u32, payload: []const u8) msg.submessage.DataFragSubmessage {
    return .{
        .flags = 0,
        .reader_entity_id = std.mem.zeroes(EntityId),
        .writer_entity_id = std.mem.zeroes(EntityId),
        .writer_sn = sn,
        .fragment_starting_num = frag,
        .fragments_in_submessage = 1,
        .fragment_size = 4,
        .data_size = 12,
        .inline_qos = null,
        .serialized_payload = payload,
    };
}

test "StatefulReader HEARTBEAT: a partly reassembled SN gets a NACK_FRAG, not a whole-SN NACK" {
    // RTPS 2.5 §8.4.14.1.4: an SN is negatively acknowledged only when all its
    // fragments are missing; a NACK_FRAG asks for the rest. Asking for the
    // whole SN again repeats the burst whose tail was lost.
    var cap: CaptureTransport = .{};
    const reader = try StatefulReader.init(testing.allocator, makeGuid(40, 0xC7), cap.transport(), .keep_all, 0, true);
    defer reader.deinit();

    const wguid = makeGuid(41, 0xC2);
    const loc = Locator{ .udp_v4 = .{ .addr = .{ 10, 0, 0, 1 }, .port = 7411 } };
    try reader.addMatchedWriter(try WriterProxy.init(testing.allocator, wguid, &.{loc}, &.{}, true));
    cap.n = 0;

    // SN 1: fragment 1 of 3 arrives. SN 2: nothing arrives.
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(1, 1, &.{ 1, 2, 3, 4 }));
    reader.handleHeartbeat(wguid, reader.guid.entity_id, 1, 2, 1, false);

    var sms: [8]msg.SubMessage = undefined;
    const n = try cap.submessages(&sms);
    try testing.expectEqual(@as(usize, 2), n);

    const an = sms[0].acknack.reader_sn_state;
    try testing.expectEqual(@as(SequenceNumber, 1), an.base);
    try testing.expect(!an.contains(1));
    try testing.expect(an.contains(2));

    const nf = sms[1].nack_frag;
    try testing.expectEqual(@as(SequenceNumber, 1), nf.writer_sn);
    try testing.expect(!nf.fragment_number_state.contains(1));
    try testing.expect(nf.fragment_number_state.contains(2));
    try testing.expect(nf.fragment_number_state.contains(3));
}

test "StatefulReader GAP frees a partly reassembled SN" {
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };
    const reader = try StatefulReader.init(testing.allocator, makeGuid(42, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();

    const wguid = makeGuid(43, 0xC2);
    try reader.addMatchedWriter(try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, true));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(1, 1, &.{ 1, 2, 3, 4 }));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(3, 1, &.{ 1, 2, 3, 4 }));
    try testing.expectEqual(@as(usize, 2), reader.writer_proxies.items[0].reassembly.count());

    // The writer no longer has SN 1; SN 3 is still coming.
    reader.handleGap(wguid, 1, .{ .base = 2, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) });
    const wp = &reader.writer_proxies.items[0];
    try testing.expectEqual(@as(usize, 1), wp.reassembly.count());
    try testing.expect(wp.reassembly.contains(3));
}

test "StatefulReader GAP frees every partly reassembled SN it settles, among many" {
    var null_ctx: TestNullCtx = .{};
    const null_transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };
    const reader = try StatefulReader.init(testing.allocator, makeGuid(44, 0xC7), null_transport, .keep_all, 0, true);
    defer reader.deinit();
    reader.setReassemblyLimits(.{ .max_samples = 0, .max_bytes = 0 });

    const wguid = makeGuid(45, 0xC2);
    try reader.addMatchedWriter(try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, true));
    var sn: SequenceNumber = 1;
    while (sn <= 150) : (sn += 1) try reader.handleDataFrag(wguid, ZERO_TS, testFrag(sn, 1, &.{ 1, 2, 3, 4 }));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(200, 1, &.{ 1, 2, 3, 4 }));

    reader.handleGap(wguid, 1, .{ .base = 151, .num_bits = 0, .bitmap = std.mem.zeroes([8]u32) });
    const wp = &reader.writer_proxies.items[0];
    try testing.expectEqual(@as(usize, 1), wp.reassembly.count());
    try testing.expect(wp.reassembly.contains(200));
}

/// A reader matched with one writer, for the reassembly limit tests.
fn limitedReader(id: u8, reliable: bool, limits: ReassemblyLimits) !*StatefulReader {
    const null_transport = Transport{ .ctx = undefined, .vtable = &test_null_vtable };
    const reader = try StatefulReader.init(testing.allocator, makeGuid(id, 0xC7), null_transport, .keep_all, 0, reliable);
    errdefer reader.deinit();
    reader.setReassemblyLimits(limits);
    try reader.addMatchedWriter(try WriterProxy.init(testing.allocator, makeGuid(id, 0xC2), &.{}, &.{}, reliable));
    return reader;
}

fn expectReassembling(reader: *StatefulReader, sns: []const SequenceNumber) !void {
    const wp = &reader.writer_proxies.items[0];
    try testing.expectEqual(sns.len, wp.reassembly.count());
    for (sns) |sn| try testing.expect(wp.reassembly.contains(sn));
}

test "StatefulReader reassembly limit: a reliable reader keeps the lowest SNs" {
    const reader = try limitedReader(46, true, .{ .max_samples = 2, .max_bytes = 0 });
    defer reader.deinit();
    const wguid = makeGuid(46, 0xC2);
    const bytes = [_]u8{ 1, 2, 3, 4 };

    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(2, 1, &bytes));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(3, 1, &bytes));
    // SN 4 is furthest from delivery, so it waits.
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(4, 1, &bytes));
    try expectReassembling(reader, &.{ 2, 3 });
    // SN 1 is nearer than SN 3, which makes room.
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(1, 1, &bytes));
    try expectReassembling(reader, &.{ 1, 2 });
}

test "StatefulReader reassembly limit: a best-effort reader keeps the newest SNs" {
    const reader = try limitedReader(47, false, .{ .max_samples = 2, .max_bytes = 0 });
    defer reader.deinit();
    const wguid = makeGuid(47, 0xC2);
    const bytes = [_]u8{ 1, 2, 3, 4 };

    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(2, 1, &bytes));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(3, 1, &bytes));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(1, 1, &bytes));
    try expectReassembling(reader, &.{ 2, 3 });
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(4, 1, &bytes));
    try expectReassembling(reader, &.{ 3, 4 });
}

test "StatefulReader reassembly limit: the declared bytes are bounded" {
    // testFrag declares 12 bytes per sample: two fit.
    const reader = try limitedReader(48, true, .{ .max_samples = 0, .max_bytes = 24 });
    defer reader.deinit();
    const wguid = makeGuid(48, 0xC2);
    const bytes = [_]u8{ 1, 2, 3, 4 };

    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(1, 1, &bytes));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(2, 1, &bytes));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(3, 1, &bytes));
    try expectReassembling(reader, &.{ 1, 2 });
}

test "StatefulReader reassembly limit: a reliable sample too large for it is counted lost" {
    const reader = try limitedReader(49, true, .{ .max_bytes = 12 });
    defer reader.deinit();
    const Ctx = struct {
        delivered: usize = 0,
        lost: i32 = 0,
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.delivered += 1;
        }
        fn onLost(ctx: *anyopaque, count: i32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.lost += count;
        }
    };
    var ctx: Ctx = .{};
    reader.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData, .on_sample_lost = Ctx.onLost });
    const wguid = makeGuid(49, 0xC2);

    // SN 2 completes, but waits on SN 1.
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(2, 1, &.{ 1, 2, 3, 4 }));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(2, 2, &.{ 5, 6, 7, 8 }));
    try reader.handleDataFrag(wguid, ZERO_TS, testFrag(2, 3, &.{ 9, 10, 11, 12 }));
    try testing.expectEqual(@as(usize, 0), ctx.delivered);

    var big = testFrag(1, 1, &.{ 1, 2, 3, 4 });
    big.data_size = 16;
    try reader.handleDataFrag(wguid, ZERO_TS, big);
    try testing.expectEqual(@as(i32, 1), ctx.lost);
    try testing.expectEqual(@as(usize, 1), ctx.delivered);
    try expectReassembling(reader, &.{});
    try testing.expectEqual(@as(SequenceNumber, 2), reader.writer_proxies.items[0].received.cumulativeAck());

    // Settled: its other fragments change nothing.
    try reader.handleDataFrag(wguid, ZERO_TS, big);
    try testing.expectEqual(@as(i32, 1), ctx.lost);
}

test "StatefulReader reassembly limit: a best-effort sample too large for it is dropped" {
    const reader = try limitedReader(50, false, .{ .max_bytes = 8 });
    defer reader.deinit();
    try reader.handleDataFrag(makeGuid(50, 0xC2), ZERO_TS, testFrag(1, 1, &.{ 1, 2, 3, 4 }));
    try expectReassembling(reader, &.{});
    try testing.expectEqual(@as(SequenceNumber, 0), reader.writer_proxies.items[0].received.max());
}

test "StatefulReader reassembly limit: a reassembly held from before the match counts toward it" {
    const reader = try limitedReader(51, true, .{ .max_samples = 1, .max_bytes = 0 });
    defer reader.deinit();
    const wguid = makeGuid(52, 0xC2);
    var held = UnmatchedCache.init(testing.allocator, test_unmatched_limits);
    defer held.deinit();
    // The match takes the later-held first: SN 1, then SN 2, which waits.
    held.putFrag(wguid, guid_mod.EntityIds.unknown, testFrag(2, 1, &.{ 1, 2, 3, 4 }), ZERO_TS, 0, std.time.ns_per_s);
    held.putFrag(wguid, guid_mod.EntityIds.unknown, testFrag(1, 1, &.{ 1, 2, 3, 4 }), ZERO_TS, 0, std.time.ns_per_s);

    const proxy = try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, true);
    _ = try reader.addOrRefreshMatchedWriterWith(proxy, &.{ .cache = &held }, null);
    const wp = for (reader.writer_proxies.items) |*w| {
        if (w.guid.eql(wguid)) break w;
    } else unreachable;
    try testing.expectEqual(@as(usize, 1), wp.reassembly.count());
    try testing.expect(wp.reassembly.contains(1));
}

test "StatefulReader reassembly limit: a reliable sample held from before the match, too large for it, is counted lost" {
    const reader = try limitedReader(53, true, .{ .max_bytes = 12 });
    defer reader.deinit();
    const Ctx = struct {
        delivered: usize = 0,
        lost: i32 = 0,
        fn onData(ctx: *anyopaque, _: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.delivered += 1;
        }
        fn onLost(ctx: *anyopaque, count: i32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.lost += count;
        }
    };
    var ctx: Ctx = .{};
    reader.setCallback(.{ .ctx = &ctx, .on_data = Ctx.onData, .on_sample_lost = Ctx.onLost });

    const wguid = makeGuid(54, 0xC2);
    var held = UnmatchedCache.init(testing.allocator, test_unmatched_limits);
    defer held.deinit();
    // SN 2 completes while held; SN 1 is held part-received and too large.
    held.putFrag(wguid, guid_mod.EntityIds.unknown, testFrag(2, 1, &.{ 1, 2, 3, 4 }), ZERO_TS, 0, std.time.ns_per_s);
    held.putFrag(wguid, guid_mod.EntityIds.unknown, testFrag(2, 2, &.{ 5, 6, 7, 8 }), ZERO_TS, 0, std.time.ns_per_s);
    held.putFrag(wguid, guid_mod.EntityIds.unknown, testFrag(2, 3, &.{ 9, 10, 11, 12 }), ZERO_TS, 0, std.time.ns_per_s);
    var big = testFrag(1, 1, &.{ 1, 2, 3, 4 });
    big.data_size = 16;
    held.putFrag(wguid, guid_mod.EntityIds.unknown, big, ZERO_TS, 0, std.time.ns_per_s);

    const proxy = try WriterProxy.init(testing.allocator, wguid, &.{}, &.{}, true);
    _ = try reader.addOrRefreshMatchedWriterWith(proxy, &.{ .cache = &held }, null);
    try testing.expectEqual(@as(i32, 1), ctx.lost);
    try testing.expectEqual(@as(usize, 1), ctx.delivered);
    const wp = for (reader.writer_proxies.items) |*w| {
        if (w.guid.eql(wguid)) break w;
    } else unreachable;
    try testing.expectEqual(@as(usize, 0), wp.reassembly.count());
    try testing.expectEqual(@as(SequenceNumber, 2), wp.received.cumulativeAck());
}

test "checked sample processing precedes sequence accounting for DATA and fragments" {
    const Processor = struct {
        calls: usize = 0,
        deliveries: usize = 0,
        fn process(ctx: *anyopaque, data: []const u8, _: ChangeKind, _: [16]u8) anyerror![16]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (data.len == 0 or data[0] != 1) return error.InvalidSample;
            var hash: [16]u8 = @splat(0);
            hash[0] = 42;
            return hash;
        }
        fn onData(ctx: *anyopaque, change: *const CacheChange) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            std.debug.assert(change.key_hash[0] == 42);
            self.deliveries += 1;
        }
    };
    for ([_]bool{ false, true }) |reliable| {
        var null_ctx = TestNullCtx{};
        const transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };
        const reader = try StatefulReader.init(testing.allocator, makeGuid(71, 0x07), transport, .keep_all, 0, reliable);
        defer reader.deinit();
        var processor = Processor{};
        reader.sample_processor = .{ .ctx = &processor, .process = Processor.process };
        reader.setCallback(.{ .ctx = &processor, .on_data = Processor.onData });
        const writer = makeGuid(72, 0x02);
        try reader.addMatchedWriter(try WriterProxy.init(testing.allocator, writer, &.{}, &.{}, reliable));
        var change = CacheChange{
            .kind = .alive,
            .writer_guid = writer,
            .sequence_number = 1,
            .source_timestamp = ZERO_TS,
            .instance_handle = NIL_IH,
            .key_hash = NIL_KH,
            .data = &.{0xff},
        };
        try testing.expectError(error.InvalidSample, reader.handleData(writer, change));
        try testing.expect(!reader.writer_proxies.items[0].received.contains(1));
        try testing.expectEqual(@as(usize, 0), processor.deliveries);
        change.data = &.{1};
        try reader.handleData(writer, change);
        try testing.expect(reader.writer_proxies.items[0].received.contains(1));
        try testing.expectEqual(@as(usize, 1), processor.deliveries);
        var first = msg.submessage.DataFragSubmessage{
            .flags = 0,
            .reader_entity_id = guid_mod.EntityIds.unknown,
            .writer_entity_id = writer.entity_id,
            .writer_sn = 2,
            .fragment_starting_num = 1,
            .fragments_in_submessage = 1,
            .fragment_size = 1,
            .data_size = 2,
            .inline_qos = null,
            .serialized_payload = &.{0xff},
        };
        var second = first;
        second.fragment_starting_num = 2;
        second.serialized_payload = &.{0};
        try reader.handleDataFrag(writer, ZERO_TS, first);
        try testing.expectError(error.InvalidSample, reader.handleDataFrag(writer, ZERO_TS, second));
        try testing.expect(!reader.writer_proxies.items[0].received.contains(2));
        try testing.expectEqual(@as(usize, 0), reader.writer_proxies.items[0].reassembly.count());
        first.serialized_payload = &.{1};
        try reader.handleDataFrag(writer, ZERO_TS, first);
        try reader.handleDataFrag(writer, ZERO_TS, second);
        try testing.expectEqual(@as(usize, 2), processor.deliveries);
        try testing.expect(reader.writer_proxies.items[0].received.contains(2));
    }
}

test "checked sample processing also rejects malformed data held before matching" {
    const Processor = struct {
        calls: usize = 0,
        fn process(ctx: *anyopaque, _: []const u8, _: ChangeKind, _: [16]u8) anyerror![16]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            return error.InvalidSample;
        }
    };
    var null_ctx = TestNullCtx{};
    const transport = Transport{ .ctx = &null_ctx, .vtable = &test_null_vtable };
    const reader = try StatefulReader.init(testing.allocator, makeGuid(73, 0x07), transport, .keep_all, 0, true);
    defer reader.deinit();
    var processor = Processor{};
    reader.sample_processor = .{ .ctx = &processor, .process = Processor.process };
    var cache = unmatched_mod.UnmatchedCache.init(testing.allocator, .{ .max_bytes = 1024, .max_writers = 4, .max_samples_per_writer = 4, .max_partials_per_writer = 4 });
    defer cache.deinit();
    const writer = makeGuid(74, 0x02);
    const change = CacheChange{
        .kind = .alive,
        .writer_guid = writer,
        .sequence_number = 1,
        .source_timestamp = ZERO_TS,
        .instance_handle = NIL_IH,
        .key_hash = NIL_KH,
        .data = &.{0xff},
    };
    cache.put(writer, guid_mod.EntityIds.unknown, &change, true, 0, 1000000);
    const prematch = Prematch{ .cache = &cache };
    _ = try reader.addOrRefreshMatchedWriterWith(try WriterProxy.init(testing.allocator, writer, &.{}, &.{}, true), &prematch, null);
    try testing.expectEqual(@as(usize, 1), processor.calls);
    try testing.expect(!reader.writer_proxies.items[0].received.contains(1));
}
