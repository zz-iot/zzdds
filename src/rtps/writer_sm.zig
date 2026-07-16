//! RTPS Writer state machines (RTPS 2.5 §8.4.8, §8.4.9).
//!
//! StatelessWriter: best-effort, no acknowledgment tracking. Used for SPDP.
//!   - Sends to a fixed set of reader locators.
//!   - No per-reader state; all data goes to all locators.
//!
//! StatefulWriter: reliable, per-reader ACK tracking. Used for SEDP and data.
//!   - Maintains a ReaderProxy per matched reader.
//!   - Sends Heartbeat, handles NACK (retransmit).

const std = @import("std");
const log = @import("../log.zig");
const trace = @import("../trace.zig");
const mutex_mod = @import("../util/mutex.zig");
const condvar_mod = @import("../util/condvar.zig");
const history_mod = @import("history.zig");
const guid_mod = @import("guid.zig");
const sn_mod = @import("sequence_number.zig");
const time_mod = @import("../util/time.zig");
const msg = @import("message/root.zig");
const iface = @import("../transport/interface.zig");

const MessageBuilder = msg.builder.MessageBuilder;
const SCRATCH_SIZE = msg.builder.SCRATCH_SIZE;
const IoVec = msg.builder.IoVec;

pub const HistoryCache = history_mod.HistoryCache;
pub const CacheChange = history_mod.CacheChange;
pub const ChangeKind = history_mod.ChangeKind;
pub const InstanceHandle = history_mod.InstanceHandle;
pub const Guid = guid_mod.Guid;
pub const GuidPrefix = guid_mod.GuidPrefix;
pub const EntityId = guid_mod.EntityId;
pub const SequenceNumber = sn_mod.SequenceNumber;
pub const RtpsTimestamp = time_mod.RtpsTimestamp;
pub const Transport = iface.Transport;
pub const Locator = iface.Locator;

// ── Helpers ───────────────────────────────────────────────────────────────────

/// Convert ChangeKind to the PID_STATUS_INFO value for inline QoS.
/// Returns null for .alive (no STATUS_INFO needed).
fn statusInfoFromKind(kind: ChangeKind) ?u32 {
    return switch (kind) {
        .alive => null,
        .not_alive_disposed => 0x00000001,
        .not_alive_unregistered => 0x00000002,
    };
}

// ── Message send helper ───────────────────────────────────────────────────────

/// Maximum flat buffer size for a single send. Each DATA_FRAG fragment is
/// sized by `StatefulWriter.frag_size` (default 16384) which is well under
/// this limit, so fragmented writes never hit it. Unfragmented sends
/// (payload ≤ frag_size) still return error.MessageTooLarge if the total
/// RTPS message exceeds 65536 bytes — that is the correct safety net.
pub const MAX_SEND_BYTES: usize = 65536;

/// Default fragment size used when no explicit value is provided.
pub const DEFAULT_FRAG_SIZE: u16 = 16384;

/// Flatten scatter-gather iovecs into a stack buffer and deliver via transport.
pub fn sendIovecs(transport: Transport, locator: *const Locator, iovecs: []const IoVec) !void {
    var buf: [MAX_SEND_BYTES]u8 = undefined;
    var pos: usize = 0;
    for (iovecs) |iov| {
        const src = iov.base[0..iov.len];
        if (pos + src.len > buf.len) return error.MessageTooLarge;
        @memcpy(buf[pos..][0..src.len], src);
        pos += src.len;
    }
    try transport.send(locator, buf[0..pos]);
}

// ── StatelessWriter ───────────────────────────────────────────────────────────

/// A reader endpoint for the stateless writer to deliver data to.
pub const ReaderLocator = struct {
    locator: Locator,
    expects_inline_qos: bool = false,
};

/// Best-effort writer. Sends changes to a fixed set of locators; no ACK tracking.
/// Typical use: SPDP participant announcement.
///
/// Thread-safe: all public methods lock `mu`.
pub const StatelessWriter = struct {
    alloc: std.mem.Allocator,
    guid: Guid,
    transport: Transport,
    cache: HistoryCache,
    reader_locators: std.ArrayListUnmanaged(ReaderLocator),
    /// Entity ID used as the reader entity ID in DATA submessages.
    reader_entity_id: EntityId,
    mu: mutex_mod.Mutex,
    tracer: trace.Tracer,

    const Self = @This();

    /// Allocates and initializes a StatelessWriter on the heap.
    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        transport: Transport,
        cache_depth: u32,
        reader_entity_id: EntityId,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .guid = guid,
            .transport = transport,
            .cache = HistoryCache.init(alloc, .keep_last, cache_depth),
            .reader_locators = .empty,
            .reader_entity_id = reader_entity_id,
            .mu = .{},
            .tracer = trace.Tracer.noop(),
        };
        return self;
    }

    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    pub fn deinit(self: *Self) void {
        self.cache.deinit();
        self.reader_locators.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    /// Add a locator that will receive all future (and existing) history.
    pub fn addReaderLocator(self: *Self, rl: ReaderLocator) !void {
        self.mu.lock();
        defer self.mu.unlock();
        // Deduplicate by locator bytes.
        for (self.reader_locators.items) |ex| {
            if (ex.locator.eql(rl.locator)) return;
        }
        try self.reader_locators.append(self.alloc, rl);
    }

    pub fn removeReaderLocator(self: *Self, locator: Locator) void {
        self.mu.lock();
        defer self.mu.unlock();
        var i: usize = self.reader_locators.items.len;
        while (i > 0) {
            i -= 1;
            if (self.reader_locators.items[i].locator.eql(locator)) {
                _ = self.reader_locators.swapRemove(i);
            }
        }
    }

    /// Add a change to the cache. Does NOT send immediately; call `sendAll`.
    pub fn write(
        self: *Self,
        kind: ChangeKind,
        source_timestamp: RtpsTimestamp,
        instance_handle: InstanceHandle,
        key_hash: [16]u8,
        data: []const u8,
    ) !SequenceNumber {
        self.mu.lock();
        defer self.mu.unlock();
        return self.cache.addWriterChange(kind, self.guid, source_timestamp, instance_handle, key_hash, data);
    }

    /// Send all cached changes to all registered reader locators.
    /// Called on a timer by SPDP to re-announce the participant.
    pub fn sendAll(self: *Self) void {
        self.mu.lock();
        defer self.mu.unlock();

        var scratch: [SCRATCH_SIZE]u8 = undefined;

        for (self.reader_locators.items) |rl| {
            for (self.cache.changes.items) |*ch| {
                var builder = MessageBuilder.init(&scratch, self.guid.prefix);
                builder.addInfoTs(ch.source_timestamp);
                builder.addData(.{
                    .reader_entity_id = self.reader_entity_id,
                    .writer_entity_id = self.guid.entity_id,
                    .writer_sn = ch.sequence_number,
                    .key_hash = if (!std.mem.eql(u8, &ch.key_hash, &std.mem.zeroes([16]u8)))
                        ch.key_hash
                    else
                        null,
                    .is_key = ch.kind != .alive,
                    .status_info = statusInfoFromKind(ch.kind),
                }, ch.data);
                self.tracer.submit(.{ .send_data = .{
                    .src_prefix = self.guid.prefix,
                    .writer_eid = self.guid.entity_id,
                    .reader_eid = self.reader_entity_id,
                    .sn = ch.sequence_number,
                    .key_hash = ch.key_hash,
                    .data_len = @intCast(ch.data.len),
                } });
                sendIovecs(self.transport, &rl.locator, builder.iovecs()) catch |err| switch (err) {
                    error.UnsupportedLocatorKind => {},
                    else => log.rtps.warn("StatelessWriter.sendAll: send error: {}", .{err}),
                };
            }
        }
    }
};

// ── ReaderProxy (StatefulWriter) ──────────────────────────────────────────────

/// State that a StatefulWriter tracks for each matched reader.
pub const ReaderProxy = struct {
    guid: Guid,
    unicast_locators: std.ArrayListUnmanaged(Locator),
    multicast_locators: std.ArrayListUnmanaged(Locator),
    expects_inline_qos: bool,
    /// True when the matched reader is RELIABLE; false for BEST_EFFORT.
    /// BEST_EFFORT proxies never send AckNack so they are excluded from
    /// wait_for_acknowledgments checks.
    reliable: bool,
    /// Highest SN the reader has cumulatively acknowledged.
    highest_acked_sn: SequenceNumber,
    /// First SN this reader is eligible to receive. Set to 1 for
    /// TRANSIENT_LOCAL+ (gets full history). Set to cache.next_sn at match
    /// time for VOLATILE writers (late joiners skip historical data).
    start_sn: SequenceNumber,
    /// Last accepted ACKNACK count for stale-submessage suppression (§8.3.7.1).
    /// Null until the first ACKNACK that causes a retransmit is accepted.
    /// Updated only when data or a trailing HB is actually sent; this lets a
    /// reader that repeats the same count (to probe availability) keep getting
    /// processed until our reply is successfully delivered.
    last_ack_nack_count: ?i32,
    /// Last accepted NACK_FRAG count for stale-submessage suppression (§8.3.8.12).
    /// Null until the first NACK_FRAG from this reader is accepted.
    last_nack_frag_count: ?i32,
    /// When true, suppress all DATA sends to this proxy until it sends a
    /// non-final ACKNACK with highest_sn >= history_floor_sn.  Cleared only
    /// on a non-final NACK so that RTI Connext has time to flush its durability
    /// history buffer to the DataReader before the first live sample arrives.
    /// A final NACK means "I'm satisfied" — not "send me live data" — so it
    /// must not clear this flag.
    suppress_live_data: bool,
    /// cache.maxSn() at the time this proxy was created with suppress_live_data.
    /// Threshold for clearing suppress_live_data: the reader's cumulative ack
    /// must reach this SN on a non-final NACK before live data is unblocked.
    history_floor_sn: SequenceNumber,
    /// Non-zero while a liveness probe is active for this reader proxy.
    /// Monotonic deadline (ns): if no ACKNACK arrives before this time, the
    /// heartbeat thread evicts the proxy and fires the probe-result callback.
    /// Cleared immediately on any incoming ACKNACK (reader is alive).
    probe_deadline_ns: i64,
    /// firstSN of the first Heartbeat actually sent to this proxy (set once,
    /// at match time, in `addMatchedReader`/`replayHistoryToProxyLocked`).
    /// Null until that first Heartbeat is sent. Used as the correlation floor
    /// for `protocol_ready`: a RELIABLE proxy is considered protocol-ready once
    /// an AckNack's `highest_sn` reaches this floor, proving the reader has
    /// processed the initial Heartbeat handshake (not just SEDP discovery).
    first_sent_hb_first_sn: ?SequenceNumber = null,
    /// True once this proxy has completed the RELIABLE readiness handshake
    /// (or, for BEST_EFFORT proxies, immediately at match — no handshake
    /// exists). Sticky: never cleared by a later stale/duplicate AckNack.
    /// Drives the `on_reliable_reader_ready` extended listener callback.
    protocol_ready: bool = false,
    /// True when this specific reader requested TRANSIENT_LOCAL+ durability
    /// and therefore wants historical replay. A reader requesting VOLATILE
    /// never wants replay regardless of what durability the writer offers
    /// (DDS DURABILITY §2.2.3.4), so it must not be held in
    /// `suppress_live_data` waiting for an ACKNACK it has no reason to send.
    /// Defaults to true so existing callers that don't track per-reader
    /// durability keep today's behavior.
    wants_replay: bool = true,
    /// See protocol.MatchedReaderInfo.needs_pid_coherent_set_marker. Set from
    /// vtAddMatchedReader; defaults to false (Example 3, the smaller spec-legal
    /// end-of-coherent-set form) for readers with no known quirk.
    needs_pid_coherent_set_marker: bool = false,

    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        unicast_locators: []const Locator,
        multicast_locators: []const Locator,
        expects_inline_qos: bool,
        reliable: bool,
    ) !ReaderProxy {
        var self = ReaderProxy{
            .guid = guid,
            .unicast_locators = .empty,
            .multicast_locators = .empty,
            .expects_inline_qos = expects_inline_qos,
            .reliable = reliable,
            .highest_acked_sn = 0,
            .start_sn = 1,
            .last_ack_nack_count = null,
            .last_nack_frag_count = null,
            .suppress_live_data = false,
            .history_floor_sn = 0,
            .probe_deadline_ns = 0,
        };
        try self.unicast_locators.appendSlice(alloc, unicast_locators);
        errdefer self.unicast_locators.deinit(alloc);
        try self.multicast_locators.appendSlice(alloc, multicast_locators);
        return self;
    }

    pub fn deinit(self: *ReaderProxy, alloc: std.mem.Allocator) void {
        self.unicast_locators.deinit(alloc);
        self.multicast_locators.deinit(alloc);
    }

    /// Primary locator for sending: first unicast, else first multicast.
    pub fn primaryLocator(self: *const ReaderProxy) ?Locator {
        if (self.unicast_locators.items.len > 0) return self.unicast_locators.items[0];
        if (self.multicast_locators.items.len > 0) return self.multicast_locators.items[0];
        return null;
    }

    /// All locators to deliver to: unicast list if non-empty, else multicast list.
    /// RTPS requires sending to every locator in the list so that peers with
    /// multiple interfaces (e.g. OpenDDS advertising both a VPN and a LAN address)
    /// receive the datagram on whichever interface is actually reachable.
    pub fn effectiveLocators(self: *const ReaderProxy) []const Locator {
        if (self.unicast_locators.items.len > 0) return self.unicast_locators.items;
        return self.multicast_locators.items;
    }
};

// ── StatefulWriter ────────────────────────────────────────────────────────────

/// Reliable writer with per-reader ACK tracking.
/// Typical use: SEDP publications/subscriptions announcements, user data.
///
/// Thread-safe: all public methods lock `mu`.
pub const StatefulWriter = struct {
    alloc: std.mem.Allocator,
    guid: Guid,
    transport: Transport,
    cache: HistoryCache,
    reader_proxies: std.ArrayListUnmanaged(ReaderProxy),
    /// Entity ID used in DATA/HEARTBEAT submessages as reader entity ID.
    reader_entity_id: EntityId,
    mu: mutex_mod.Mutex,
    ack_cond: condvar_mod.Condvar,
    /// Monotonically increasing count for HEARTBEAT / HEARTBEAT_FRAG submessages.
    hb_count: i32,
    tracer: trace.Tracer,
    /// Fragment size in bytes. Payloads larger than this are sent as DATA_FRAG
    /// submessages. Configured per writer; fixed for the writer's lifetime.
    frag_size: u16,
    /// When true, replay history cache to newly matched readers (TRANSIENT_LOCAL
    /// and above). When false (VOLATILE), skip replay — late joiners only receive
    /// data written after they matched.
    replay_on_match: bool,
    /// Background thread that sends non-final HEARTBEATs periodically so readers
    /// can NACK and recover if any initial DATA or HEARTBEAT was dropped.
    /// Null until the first reader proxy is added.
    hb_thread: ?std.Thread,
    hb_stopping: std.atomic.Value(bool),
    /// When true, write() defers DATA sends and accumulates SNs in
    /// coherent_pending_sns.  Cleared by endCoherentSet().
    coherent_active: bool,
    /// SNs written since the last beginCoherentSet() call; flushed in endCoherentSet().
    coherent_pending_sns: std.ArrayListUnmanaged(SequenceNumber),
    /// Index into coherent_pending_sns where the actual coherent window begins.
    /// Non-zero only when suspend_publications was active before begin_coherent_changes:
    /// items [0..coherent_window_start) were written during suspension and are flushed
    /// without coherent QoS; items [coherent_window_start..) are the true coherent set.
    coherent_window_start: usize,
    /// Highest SN actually delivered to readers via sendChangeToAllLocked (i.e. sent
    /// on the wire, not merely buffered in coherent_pending_sns).  Used to cap the
    /// background heartbeat's last_sn during coherent-set buffering so that the HB
    /// does not advertise unsent SNs that would poison subscriber WIP flush_target_sn.
    last_flushed_sn: SequenceNumber,
    /// Per-publisher group sequence number counter (starts at 0; first emitted GSN = 1).
    /// Incremented by N after each group coherent set of N samples is flushed.
    group_seq_num_counter: i64,
    /// EOC SN allocated by endCoherentSet(defer_eoc=true) but not yet sent.
    /// Consumed and cleared by flushGroupEOCHBOnly().
    /// Kept non-null from endCoherentSet() through to flushGroupEOCHBOnly() so
    /// the background HB thread never sends a premature GAP for the EOC SN.
    pending_eoc_sn: ?SequenceNumber,
    /// Optional callback fired when a liveness probe resolves.
    /// Called with (ctx, prefix, alive): alive=true means an ACKNACK was received;
    /// alive=false means the probe deadline expired and the proxy was removed.
    probe_result_fn: ?*const fn (*anyopaque, GuidPrefix, bool) void,
    probe_result_ctx: ?*anyopaque,
    /// Optional callback fired when a reader proxy's `protocol_ready` state
    /// transitions. Called with (ctx, guid, ready): ready=true when the
    /// RELIABLE handshake completes (or immediately at match for BEST_EFFORT);
    /// ready=false when the proxy is removed after having been ready.
    protocol_ready_fn: ?*const fn (*anyopaque, Guid, bool) void,
    protocol_ready_ctx: ?*anyopaque,
    /// PID_LIFESPAN QoS, sent as inline QoS on every alive DATA submessage (not just
    /// via SEDP writer announcement) — some readers only apply lifespan-based expiry
    /// to samples that carry it inline. null = no lifespan configured.
    lifespan: ?time_mod.RtpsDuration,

    const Self = @This();

    /// Interval between periodic HEARTBEAT probes.
    const HB_INTERVAL_MS: u64 = 200;

    pub fn init(
        alloc: std.mem.Allocator,
        guid: Guid,
        transport: Transport,
        cache_kind: history_mod.HistoryKind,
        cache_depth: u32,
        reader_entity_id: EntityId,
        frag_size: u16,
        replay_on_match: bool,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .guid = guid,
            .transport = transport,
            .cache = HistoryCache.init(alloc, cache_kind, cache_depth),
            .reader_proxies = .empty,
            .reader_entity_id = reader_entity_id,
            .mu = .{},
            .ack_cond = .{},
            .hb_count = 0,
            .tracer = trace.Tracer.noop(),
            .frag_size = frag_size,
            .replay_on_match = replay_on_match,
            .hb_thread = null,
            .hb_stopping = std.atomic.Value(bool).init(false),
            .coherent_active = false,
            .coherent_pending_sns = .empty,
            .coherent_window_start = 0,
            .last_flushed_sn = 0,
            .group_seq_num_counter = 0,
            .pending_eoc_sn = null,
            .probe_result_fn = null,
            .probe_result_ctx = null,
            .protocol_ready_fn = null,
            .protocol_ready_ctx = null,
            .lifespan = null,
        };
        return self;
    }

    pub fn setLifespan(self: *Self, ls: ?time_mod.RtpsDuration) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.lifespan = ls;
    }

    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    /// Register a callback that fires when a liveness probe resolves.
    /// Must be called before any reader proxies are added (before the HB thread starts).
    pub fn setProbeResult(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, GuidPrefix, bool) void,
    ) void {
        self.probe_result_fn = fn_ptr;
        self.probe_result_ctx = ctx;
    }

    /// Register a callback that fires when a reader proxy's protocol-ready
    /// state transitions. Must be called before any reader proxies are added.
    pub fn setProtocolReadyCallback(
        self: *Self,
        ctx: *anyopaque,
        fn_ptr: *const fn (*anyopaque, Guid, bool) void,
    ) void {
        self.protocol_ready_fn = fn_ptr;
        self.protocol_ready_ctx = ctx;
    }

    /// Start a liveness probe for all reader proxies matching `prefix`.
    /// The heartbeat thread will send periodic non-final HBs (as it already does)
    /// and evict the proxy if no ACKNACK arrives before `deadline_ns` (monotonic ns).
    pub fn beginProbe(self: *Self, prefix: GuidPrefix, deadline_ns: i64) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.reader_proxies.items) |*rp| {
            if (rp.guid.prefix.eql(prefix) and rp.reliable) {
                rp.probe_deadline_ns = deadline_ns;
            }
        }
    }

    /// Signal and join the heartbeat thread, without freeing anything else.
    /// Idempotent — safe to call more than once (e.g. once from a graceful
    /// `stop()` and again from `deinit()`): after the first join, `hb_thread`
    /// is null and subsequent calls are a no-op.
    ///
    /// Callers that register `probe_result_fn`/`probe_result_ctx` pointing at
    /// an object they're about to tear down (e.g. a DomainParticipantImpl)
    /// MUST call this — or `deinit()` — before freeing that object: the
    /// heartbeat thread fires that callback on its own schedule and doesn't
    /// otherwise know the target is gone.
    pub fn stopHeartbeat(self: *Self) void {
        self.hb_stopping.store(true, .release);
        if (self.hb_thread) |t| {
            t.join();
            self.hb_thread = null;
        }
    }

    pub fn deinit(self: *Self) void {
        self.stopHeartbeat();
        for (self.reader_proxies.items) |*rp| rp.deinit(self.alloc);
        self.reader_proxies.deinit(self.alloc);
        self.coherent_pending_sns.deinit(self.alloc);
        self.cache.deinit();
        self.alloc.destroy(self);
    }

    /// Returns true when every RELIABLE reader proxy has cumulatively acked
    /// all changes up to and including `target_sn`.  BEST_EFFORT proxies are
    /// excluded since they never send AckNack.  Returns true immediately when
    /// there are no RELIABLE proxies or `target_sn` is 0.
    /// Caller must hold `mu`.
    fn allProxiesAckedLocked(self: *Self, target_sn: SequenceNumber) bool {
        if (target_sn == 0) return true;
        for (self.reader_proxies.items) |rp| {
            if (rp.reliable and rp.highest_acked_sn < target_sn) return false;
        }
        return true;
    }

    pub fn allProxiesAcked(self: *Self, target_sn: SequenceNumber) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.allProxiesAckedLocked(target_sn);
    }

    /// Block until every RELIABLE matched reader has cumulatively acked all
    /// changes up to and including `target_sn`, or until `deadline_ns`
    /// (monotonic ns) is reached.  Null means wait indefinitely.
    /// Returns true on success, false on timeout.
    pub fn waitAllAcked(self: *Self, target_sn: SequenceNumber, deadline_ns: ?i64) bool {
        self.mu.lock();
        defer self.mu.unlock();
        while (true) {
            if (self.allProxiesAckedLocked(target_sn)) return true;
            if (deadline_ns) |dl| {
                const now = time_mod.nanoTimestamp();
                if (now >= dl) return false;
                const remaining: u64 = @intCast(dl - now);
                self.ack_cond.timedWaitNs(&self.mu, remaining) catch {};
                // Re-check after timeout: an ACK may have arrived just as the
                // condvar re-acquired mu, satisfying the condition already.
            } else {
                self.ack_cond.wait(&self.mu);
            }
        }
    }

    /// Add a matched reader. When a proxy with the same GUID already exists,
    /// acts as a lease refresh: updates locators and metadata but preserves
    /// `highest_acked_sn` and `start_sn`.  History replay and heartbeats are
    /// skipped for re-matches; the periodic heartbeat thread will resync the
    /// reader at the next interval.
    ///
    /// For new readers: when `replay_on_match` is true (TRANSIENT_LOCAL+), the
    /// full history cache is replayed.  For VOLATILE writers `start_sn` is set to
    /// the writer's next SN so the reader only sees future data, and a Heartbeat
    /// is sent to communicate this range.
    pub fn addMatchedReader(self: *Self, proxy: ReaderProxy) !void {
        self.mu.lock();
        for (self.reader_proxies.items) |*rp| {
            if (rp.guid.eql(proxy.guid)) {
                // Lease refresh: update locators/metadata, preserve ack state.
                rp.unicast_locators.deinit(self.alloc);
                rp.multicast_locators.deinit(self.alloc);
                rp.unicast_locators = proxy.unicast_locators;
                rp.multicast_locators = proxy.multicast_locators;
                rp.reliable = proxy.reliable;
                rp.expects_inline_qos = proxy.expects_inline_qos;
                rp.wants_replay = proxy.wants_replay;
                // Dispose the incoming proxy's empty locator lists.
                var discarded = proxy;
                discarded.unicast_locators = .empty;
                discarded.multicast_locators = .empty;
                discarded.deinit(self.alloc);
                self.mu.unlock();
                return;
            }
        }
        self.reader_proxies.append(self.alloc, proxy) catch |err| {
            self.mu.unlock();
            return err;
        };
        const new_rp = &self.reader_proxies.items[self.reader_proxies.items.len - 1];
        // Replay only applies when BOTH the writer offers TRANSIENT_LOCAL+ AND
        // this specific reader requested it. A VOLATILE-requesting reader has
        // no use for history and must not be held back waiting for an ACKNACK
        // it has no spec-driven reason to send.
        const should_replay = self.replay_on_match and new_rp.wants_replay;
        if (!should_replay) new_rp.start_sn = self.cache.next_sn;
        // Record the correlating floor for the RELIABLE readiness handshake,
        // matching whatever firstSN the HB sent below will actually carry (see
        // hbFirstSn). BEST_EFFORT proxies never ACKNACK, so there is no
        // handshake to wait for — they become ready immediately instead,
        // fired after mu is released below (never while holding it).
        new_rp.first_sent_hb_first_sn = hbFirstSn(self.cache.minSn(), self.cache.maxSn(), new_rp.start_sn, null);
        const newly_ready_guid: ?Guid = blk: {
            if (!new_rp.reliable) {
                new_rp.protocol_ready = true;
                break :blk new_rp.guid;
            }
            break :blk null;
        };
        // Set suppress_live_data before replay so the flag is visible to any
        // write() that acquires mu after we release it.  The replay sends
        // directly to the proxy (not through sendChangeToAllLocked) so it is
        // unaffected by the flag itself.
        //
        // BEST_EFFORT readers are excluded here even when should_replay is true:
        // suppress_live_data exists to hold live data back until an ACKNACK proves
        // the reader caught up, but BEST_EFFORT readers never ACKNACK, so a replayed
        // history can race with concurrent live writes for them. That's acceptable —
        // BEST_EFFORT already permits gaps and reordering — not a bug to fix here.
        if (new_rp.reliable and should_replay and self.cache.changes.items.len > 0) {
            new_rp.suppress_live_data = true;
            new_rp.history_floor_sn = self.cache.maxSn();
        }
        if (should_replay) self.replayHistoryToProxyLocked(new_rp) else if (new_rp.reliable) self.sendHeartbeatToProxyLocked(new_rp, false);
        // Start the periodic heartbeat thread on the first matched reader so
        // that dropped DATA or HEARTBEAT packets can be recovered via NACK.
        if (self.hb_thread == null) {
            self.hb_thread = std.Thread.spawn(.{}, heartbeatThread, .{self}) catch null;
        }
        self.mu.unlock();

        if (newly_ready_guid) |guid| {
            if (self.protocol_ready_fn) |f| f(self.protocol_ready_ctx.?, guid, true);
        }
    }

    /// Send all cached changes to a single reader proxy (called under mu).
    fn replayHistoryToProxyLocked(self: *Self, rp: *const ReaderProxy) void {
        const locs = rp.effectiveLocators();
        if (locs.len == 0) {
            log.rtps.debug("StatefulWriter({x}): replayHistory: no locator for proxy {x}", .{
                self.guid.entity_id.entity_key,
                rp.guid.entity_id.entity_key,
            });
            return;
        }
        log.rtps.debug("StatefulWriter({x}): replaying {} change(s) to {} locator(s) (proxy {x}|{x:0>2})", .{
            self.guid.entity_id.entity_key,
            self.cache.changes.items.len,
            locs.len,
            rp.guid.entity_id.entity_key,
            rp.guid.entity_id.entity_kind,
        });
        // Send HEARTBEAT before any DATA so the reader knows first_sn before
        // samples arrive. Without this, a reader that has not yet seen a heartbeat
        // from this writer may deliver the first DATA it receives immediately,
        // without knowing that earlier samples (e.g. SN=1) are expected.
        // BEST_EFFORT readers never AckNack; skip to avoid synchronous re-entry
        // deadlock when using in-process (MemoryTransport) delivery.
        if (rp.reliable) self.sendHeartbeatToProxyLocked(rp, false);
        // Reliable readers use NACK-driven history delivery: the HB above
        // announces the range; the reader's NACK drives actual DATA sends.
        // Exception: for fragmented history, prime the reader with fragment 1
        // of the first fragmented change so it learns frag_size/data_size and
        // can immediately issue NACK_FRAG (~12ms) instead of waiting ~1.5s for
        // nackResponseDelay to fire a NON-FINAL ACKNACK with zero fragments.
        if (rp.reliable) {
            var scratch: [SCRATCH_SIZE]u8 = undefined;
            for (self.cache.changes.items) |*ch| {
                if (ch.data.len <= self.frag_size) continue;
                self.hb_count += 1;
                self.sendFrag1ToProxyLocked(rp, ch, self.hb_count, &scratch);
                break; // only the first fragmented change needs priming
            }
            return;
        }
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        for (self.cache.changes.items) |*ch| {
            self.tracer.submit(.{ .send_data = .{
                .src_prefix = self.guid.prefix,
                .writer_eid = self.guid.entity_id,
                .reader_eid = rp.guid.entity_id,
                .sn = ch.sequence_number,
                .key_hash = ch.key_hash,
                .data_len = @intCast(ch.data.len),
            } });
            if (ch.data.len > self.frag_size) {
                self.hb_count += 1;
                self.sendFragsToProxyLocked(rp, ch, self.hb_count, &scratch);
            } else {
                var b = MessageBuilder.init(&scratch, self.guid.prefix);
                b.addInfoDst(rp.guid.prefix);
                b.addInfoTs(ch.source_timestamp);
                b.addData(.{
                    .reader_entity_id = rp.guid.entity_id,
                    .writer_entity_id = self.guid.entity_id,
                    .writer_sn = ch.sequence_number,
                    .key_hash = if (!std.mem.eql(u8, &ch.key_hash, &std.mem.zeroes([16]u8)))
                        ch.key_hash
                    else
                        null,
                    .is_key = ch.kind != .alive,
                    .status_info = statusInfoFromKind(ch.kind),
                    .lifespan = if (ch.kind == .alive) self.lifespan else null,
                }, ch.data);
                for (locs) |loc| {
                    sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                        error.UnsupportedLocatorKind => {},
                        else => log.rtps.warn("StatefulWriter.addMatchedReader: replay error: {}", .{err}),
                    };
                }
            }
        }
    }

    /// Send a Heartbeat to a single reader proxy (called under mu).
    /// Uses rp.start_sn as the floor for first_sn so VOLATILE readers see
    /// the correct range and do not NACK data written before they matched.
    /// `final=true` tells the reader it need not reply (used to signal
    /// history-delivery completion before live data begins flowing).
    fn sendHeartbeatToProxyLocked(self: *Self, rp: *const ReaderProxy, final: bool) void {
        const cache_last = self.cache.maxSn();
        self.sendHeartbeatToProxyLockedWithLastSn(rp, final, cache_last, null);
    }

    /// Like sendHeartbeatToProxyLocked but caps last_sn at `last_sn_cap`.
    /// Used while suppress_live_data to avoid revealing live SNs to a reader
    /// whose DataReader has not yet flushed the history replay.
    fn sendHeartbeatToProxyLockedCapped(self: *Self, rp: *const ReaderProxy, final: bool, last_sn_cap: SequenceNumber) void {
        const cache_last = self.cache.maxSn();
        const capped = if (cache_last > 0) @min(cache_last, last_sn_cap) else cache_last;
        self.sendHeartbeatToProxyLockedWithLastSn(rp, final, capped, null);
    }

    fn sendHeartbeatToProxyLockedWithLastSn(self: *Self, rp: *const ReaderProxy, final: bool, last_sn: SequenceNumber, extra_gap_sn: ?SequenceNumber) void {
        self.sendHeartbeatToProxyLockedWithLastSnAndFirstSn(rp, final, last_sn, extra_gap_sn, null);
    }

    /// firstSN a Heartbeat to `rp` would carry, given the writer's current
    /// cache bounds. When `last_sn=0` (empty-cache / coherent-write-in-progress
    /// convention), always 1 regardless of `start_sn` — an empty HB announces
    /// writer presence; using start_sn here poisons Connext's GROUP coherent
    /// set floor before any data arrives, causing it to reject GROUP
    /// deliveries whose coherent_set_sn < start_sn. `first_sn_override`, when
    /// set, wins unconditionally (GROUP EOC flush with a late-matching
    /// VOLATILE reader — see the GAP-emission callers below).
    fn hbFirstSn(cache_first: SequenceNumber, last_sn: SequenceNumber, start_sn: SequenceNumber, first_sn_override: ?SequenceNumber) SequenceNumber {
        return first_sn_override orelse
            if (last_sn == 0) @as(SequenceNumber, 1) else @max(if (cache_first == 0) 1 else cache_first, start_sn);
    }

    fn sendHeartbeatToProxyLockedWithLastSnAndFirstSn(self: *Self, rp: *const ReaderProxy, final: bool, last_sn: SequenceNumber, extra_gap_sn: ?SequenceNumber, first_sn_override: ?SequenceNumber) void {
        const locs = rp.effectiveLocators();
        const cache_first = self.cache.minSn();
        const hb_first_sn = hbFirstSn(cache_first, last_sn, rp.start_sn, first_sn_override);
        if (locs.len == 0) return;
        self.hb_count += 1;
        const first_sn = hb_first_sn;
        // Guard: RTPS requires first_sn <= last_sn (except the empty-cache
        // convention first=1, last=0).  A capped last_sn combined with
        // KEEP_LAST eviction can push cache_first past last_sn — skip the HB
        // rather than send a malformed submessage.
        if (last_sn > 0 and first_sn > last_sn) return;
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(rp.guid.prefix);
        // When first_sn is overridden below rp.start_sn (GROUP EOC flush with a
        // late-matching VOLATILE reader), send a GAP for the pre-match range
        // [first_sn_override, rp.start_sn) so the reader retires those SNs
        // rather than NACKing them indefinitely.  The writer cannot retransmit
        // them (start_sn guard), so the GAP is the only way to unblock delivery.
        if (first_sn_override) |fsn| {
            if (rp.start_sn > 0 and fsn < rp.start_sn) {
                const pre_start_gap = msg.submessage.SequenceNumberSet{
                    .base = rp.start_sn,
                    .num_bits = 0,
                    .bitmap = std.mem.zeroes([8]u32),
                };
                b.addGap(rp.guid.entity_id, self.guid.entity_id, fsn, pre_start_gap);
            }
        }
        // Send an explicit GAP for KEEP_LAST-evicted SNs alongside the HB so
        // readers permanently retire missing SNs and avoid accumulating state.
        if (cache_first > 0 and rp.start_sn > 0 and cache_first > rp.start_sn) {
            const gap_list = msg.submessage.SequenceNumberSet{
                .base = cache_first,
                .num_bits = 0,
                .bitmap = std.mem.zeroes([8]u32),
            };
            b.addGap(rp.guid.entity_id, self.guid.entity_id, rp.start_sn, gap_list);
        }
        // Optional point GAP for the EOC SN (allocated via allocSn but never in
        // cache).  Reliable readers that miss the EOC DATA packet would otherwise
        // NACK this SN forever; the GAP lets them retire it and unblock delivery
        // of all subsequent non-coherent samples buffered in pending_changes.
        if (extra_gap_sn) |eoc_sn| {
            const eoc_gap_list = msg.submessage.SequenceNumberSet{
                .base = eoc_sn + 1,
                .num_bits = 0,
                .bitmap = std.mem.zeroes([8]u32),
            };
            b.addGap(rp.guid.entity_id, self.guid.entity_id, eoc_sn, eoc_gap_list);
        }
        b.addHeartbeat(
            rp.guid.entity_id,
            self.guid.entity_id,
            first_sn,
            last_sn,
            self.hb_count,
            final,
        );
        for (locs) |loc| {
            sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                error.UnsupportedLocatorKind => {},
                else => log.rtps.warn("StatefulWriter.addMatchedReader: heartbeat error: {}", .{err}),
            };
        }
    }

    pub fn removeMatchedReader(self: *Self, guid: Guid) void {
        self.mu.lock();
        var was_ready = false;
        var i: usize = self.reader_proxies.items.len;
        while (i > 0) {
            i -= 1;
            if (self.reader_proxies.items[i].guid.eql(guid)) {
                was_ready = was_ready or self.reader_proxies.items[i].protocol_ready;
                self.reader_proxies.items[i].deinit(self.alloc);
                _ = self.reader_proxies.swapRemove(i);
            }
        }
        // Wake any thread blocked in waitAllAcked: removing a reliable reader
        // may satisfy the all-acked condition even without an explicit ACKNACK.
        self.ack_cond.broadcast();
        self.mu.unlock();

        if (was_ready) {
            if (self.protocol_ready_fn) |f| f(self.protocol_ready_ctx.?, guid, false);
        }
    }

    /// Store a new change and send it immediately to all matched readers.
    /// When a coherent set is active (beginCoherentSet called), the DATA send
    /// is deferred until endCoherentSet().
    pub fn write(
        self: *Self,
        kind: ChangeKind,
        source_timestamp: RtpsTimestamp,
        instance_handle: InstanceHandle,
        key_hash: [16]u8,
        data: []const u8,
    ) !SequenceNumber {
        self.mu.lock();
        defer self.mu.unlock();
        const sn = try self.cache.addWriterChange(kind, self.guid, source_timestamp, instance_handle, key_hash, data);
        if (self.coherent_active) {
            self.coherent_pending_sns.append(self.alloc, sn) catch |err| {
                // Roll back the cache entry so the orphaned SN is never advertised
                // in heartbeats and cannot be retransmitted as plain DATA outside
                // the coherent window.
                self.cache.removeChange(sn);
                return err;
            };
        } else if (self.cache.getChange(sn)) |ch| {
            self.sendChangeToAllLocked(ch, true);
        }
        return sn;
    }

    /// Send a Heartbeat to all matched readers.
    /// `final = true` means readers need not reply; `false` requires an ACKNACK.
    /// Uses per-proxy start_sn as the floor for first_sn so VOLATILE readers
    /// do not see or NACK data written before they matched.
    pub fn sendHeartbeat(self: *Self, final: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.hb_count += 1;
        const cache_first = self.cache.minSn();
        const cache_last = self.cache.maxSn();
        var scratch: [SCRATCH_SIZE]u8 = undefined;

        // When a coherent set is in progress, coherent_pending_sns holds SNs that
        // have been allocated and added to the cache but NOT yet sent to readers
        // (held until endCoherentSet).  Advertising those SNs in a background HB
        // causes subscriber WIPs to record a flush_target_sn that exceeds the
        // current CS's data range, permanently stalling the commit.
        //
        // Cap last_sn to last_flushed_sn — the highest SN actually delivered to
        // readers so far.  This ensures the background HB only describes data the
        // subscriber can achieve as WIP highest_sn (EOC SNs are gapped, not data).
        //
        // After a two-phase GROUP EOC flush (pending_eoc_sn cleared by flushGroupEOCHBOnly),
        // include the sent EOC SN in the advertised range: cache.next_sn - 1 is the EOC
        // marker that was sent via sendCombinedEOCData.  This lets readers NACK the EOC SN
        // if they missed it; the NACK handler then responds with GAP(eoc_sn) — the only
        // race-free way to retire an uncached EOC SN.
        const allocated_last = self.cache.next_sn -% 1;
        const adj_last: SequenceNumber = if (self.coherent_active)
            self.last_flushed_sn
        else if (self.pending_eoc_sn == null and allocated_last > cache_last)
            allocated_last
        else
            cache_last;

        for (self.reader_proxies.items) |*rp| {
            if (!rp.reliable) continue; // BEST_EFFORT readers do not use HEARTBEAT/ACKNACK
            const locs = rp.effectiveLocators();
            if (locs.len == 0) continue;
            const last_sn = adj_last;
            // When last_sn=0 (empty or coherent-write-in-progress), force firstSN=1
            // to avoid poisoning Connext's GROUP coherent set floor with rp.start_sn.
            const first_sn = if (last_sn == 0)
                @as(SequenceNumber, 1)
            else
                @max(if (cache_first == 0) 1 else cache_first, rp.start_sn);
            // RTPS requires first_sn <= last_sn (except the empty-cache first=1,last=0
            // convention).  The coherent cap can push last_sn below the proxy's start_sn
            // — skip rather than send a malformed submessage.
            if (last_sn > 0 and first_sn > last_sn) continue;
            var b = MessageBuilder.init(&scratch, self.guid.prefix);
            b.addInfoDst(rp.guid.prefix);
            // When KEEP_LAST eviction has moved the cache floor above the reader's
            // start_sn, send an explicit GAP so the reader permanently retires the
            // missing SNs instead of accumulating unbounded pending-SN state that
            // can corrupt OpenDDS's reliability internals (SIGSEGV observed).
            if (cache_first > 0 and rp.start_sn > 0 and cache_first > rp.start_sn) {
                const gap_list = msg.submessage.SequenceNumberSet{
                    .base = cache_first,
                    .num_bits = 0,
                    .bitmap = std.mem.zeroes([8]u32),
                };
                b.addGap(rp.guid.entity_id, self.guid.entity_id, rp.start_sn, gap_list);
            }
            b.addHeartbeat(
                rp.guid.entity_id,
                self.guid.entity_id,
                first_sn,
                last_sn,
                self.hb_count,
                final,
            );
            self.tracer.submit(.{ .send_heartbeat = .{
                .src_prefix = self.guid.prefix,
                .writer_eid = self.guid.entity_id,
                .reader_eid = rp.guid.entity_id,
                .first_sn = first_sn,
                .last_sn = last_sn,
                .count = self.hb_count,
                .flags = if (final) 2 else 0,
            } });
            for (locs) |loc| {
                sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                    error.UnsupportedLocatorKind => {},
                    else => log.rtps.warn("StatefulWriter.sendHeartbeat: {}", .{err}),
                };
            }
        }
    }

    /// Handle an incoming ACKNACK from a reader.
    /// Updates the proxy's ACK state and retransmits requested changes.
    ///
    /// Per RTPS §8.3.7.1.2: if `is_final` is false, the writer MUST send all
    /// cached changes with SN > (nack_set.base − 1), even if the bitmap is empty.
    pub fn handleAckNack(
        self: *Self,
        reader_guid: Guid,
        highest_sn: SequenceNumber,
        nack_set: msg.submessage.SequenceNumberSet,
        count: i32,
        is_final: bool,
    ) void {
        // Validity checks (§8.3.7.1.3): drop ill-formed ACKNACKs silently.
        // Note: base=0 is non-conformant per spec (must be >= 1) but RTI Connext
        // uses it as a "I've received nothing" probe.  We accept it; SN=0 is never
        // in cache so it is harmless.  Negative base is definitively malformed.
        if (nack_set.base < 0) return;
        if (nack_set.num_bits > 256) return; // spec maximum bitmap size

        self.mu.lock();

        var probe_cleared: ?GuidPrefix = null;
        var newly_ready_guid: ?Guid = null;

        for (self.reader_proxies.items) |*rp| {
            if (!rp.guid.eql(reader_guid)) continue;
            // Any ACKNACK confirms the reader is alive — clear the probe immediately
            // regardless of whether this ACKNACK is stale or duplicate.
            if (rp.probe_deadline_ns > 0) {
                probe_cleared = rp.guid.prefix;
                rp.probe_deadline_ns = 0;
            }
            // Stale / duplicate suppression — only while suppress_live_data is
            // inactive.  While suppress is set, allowing duplicate NACKs to trigger
            // retransmits gives the remote DataReader more time to flush history
            // before the first live sample arrives (empirically required for RTI
            // Connext TRANSIENT_LOCAL durability).  Once live data is unblocked,
            // dedup prevents the two-interface duplicate storm.
            if (!rp.suppress_live_data) {
                if (rp.last_ack_nack_count) |last| {
                    const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
                    if (diff <= 0) continue; // stale or duplicate
                }
            }
            rp.highest_acked_sn = @max(rp.highest_acked_sn, highest_sn);
            self.ack_cond.broadcast();
            // RELIABLE protocol-ready handshake: the first AckNack whose base
            // (next-expected SN) reaches the firstSN of the Heartbeat we sent
            // this proxy at match time proves the reader processed that
            // Heartbeat (not just SEDP discovery). Sticky — never re-checked
            // once true. Deliberately compares against `nack_set.base`, not
            // `highest_sn` (cumulative ack): for an empty-cache writer the
            // floor is 1 (the empty-HB convention), which `highest_sn` can
            // never reach since nothing was ever written — but a caught-up
            // reader's ACKNACK still legitimately reports `base=1` ("I have
            // nothing, next expect SN 1"), which correctly satisfies the
            // handshake.
            if (!rp.protocol_ready) {
                if (rp.first_sent_hb_first_sn) |floor| {
                    if (nack_set.base >= floor) {
                        rp.protocol_ready = true;
                        newly_ready_guid = rp.guid;
                    }
                }
            }
            // Clear suppress_live_data when either:
            // (a) The reader sends a NON-FINAL NACK with cumAck >= history floor:
            //     RTI is actively requesting live samples, meaning its DataReader
            //     has finished flushing history.  A FINAL NACK must NOT clear
            //     the flag because RTI may still be flushing internally then.
            // (b) KEEP_LAST eviction has moved the entire cache past the floor:
            //     there is no history left to protect, so suppressing live data
            //     serves no purpose and would produce malformed capped HBs.
            if (rp.suppress_live_data) {
                const evicted_past_floor = self.cache.minSn() > rp.history_floor_sn;
                if (evicted_past_floor or (!is_final and highest_sn >= rp.history_floor_sn)) {
                    rp.suppress_live_data = false;
                }
            }

            self.tracer.submit(.{ .recv_acknack = .{
                .src_prefix = reader_guid.prefix,
                .reader_eid = reader_guid.entity_id,
                .writer_eid = self.guid.entity_id,
                .base_sn = nack_set.base,
                .bitmap = nack_set,
                .count = count,
                .final = is_final,
            } });

            var scratch: [SCRATCH_SIZE]u8 = undefined;
            const locs = rp.effectiveLocators();
            if (locs.len == 0) break; // probe already cleared above; no locators to retransmit to

            var retransmit_count: usize = 0;

            // Helper: retransmit one change to this proxy (fragmented or not).
            //
            // `frag_budget` controls fragmented-sample retransmit behaviour:
            //   > 0 → send frag 1 + HEARTBEAT_FRAG (primes the reader's
            //         frag layout so it can issue NACK_FRAG immediately),
            //         then decrement budget.
            //   = 0 → send HEARTBEAT_FRAG only.
            //
            // Sending all DATA_FRAGs for every missing fragmented SN in one
            // ACKNACK response floods the reader's UDP receive buffer (default
            // ~208 KB; 500 × 7 × 16 KB = ~56 MB in one burst).  Limiting full
            // retransmits to one sample per ACKNACK cycle paces delivery:
            // each DATA_FRAG burst primes the reader with fragment layout so it
            // can NACK_FRAG the specific missing pieces, and the base advances
            // by one SN per cycle.  HEARTBEAT_FRAG for the rest lets the reader
            // request fragments it already has partial info for via NACK_FRAG.
            const retransmitChange = struct {
                fn call(w: *Self, proxy: *const ReaderProxy, ch: *const CacheChange, s: *[SCRATCH_SIZE]u8, frag_budget: *usize) void {
                    w.tracer.submit(.{ .send_data = .{
                        .src_prefix = w.guid.prefix,
                        .writer_eid = w.guid.entity_id,
                        .reader_eid = proxy.guid.entity_id,
                        .sn = ch.sequence_number,
                        .key_hash = ch.key_hash,
                        .data_len = @intCast(ch.data.len),
                    } });
                    if (ch.data.len > w.frag_size) {
                        const num_frags: u32 = @intCast(
                            (ch.data.len + @as(usize, w.frag_size) - 1) / @as(usize, w.frag_size),
                        );
                        if (frag_budget.* > 0) {
                            frag_budget.* -= 1;
                            w.hb_count += 1;
                            w.sendFrag1ToProxyLocked(proxy, ch, w.hb_count, s);
                        } else {
                            w.hb_count += 1;
                            var b = MessageBuilder.init(s, w.guid.prefix);
                            b.addInfoDst(proxy.guid.prefix);
                            b.addHeartbeatFrag(proxy.guid.entity_id, w.guid.entity_id, ch.sequence_number, num_frags, w.hb_count);
                            for (proxy.effectiveLocators()) |loc| sendIovecs(w.transport, &loc, b.iovecs()) catch {};
                        }
                    } else {
                        var b = MessageBuilder.init(s, w.guid.prefix);
                        b.addInfoDst(proxy.guid.prefix);
                        b.addInfoTs(ch.source_timestamp);
                        b.addData(.{
                            .reader_entity_id = proxy.guid.entity_id,
                            .writer_entity_id = w.guid.entity_id,
                            .writer_sn = ch.sequence_number,
                            .is_key = ch.kind != .alive,
                            .status_info = statusInfoFromKind(ch.kind),
                            .coherent_set_sn = ch.coherent_set_sn,
                            .group_seq_num = ch.group_seq_num,
                            .group_coherent_sn = ch.group_coherent_sn,
                            .lifespan = if (ch.kind == .alive) w.lifespan else null,
                        }, ch.data);
                        for (proxy.effectiveLocators()) |loc| sendIovecs(w.transport, &loc, b.iovecs()) catch {};
                    }
                }
            }.call;

            // Retransmit explicitly NACKed changes (bitmap bits set to 1).
            // rp.start_sn guards against replaying pre-match data to VOLATILE readers.
            // Allow one full DATA_FRAG burst for the first fragmented SN the reader
            // has explicitly NACKed; this primes the reader with the fragment layout
            // it needs to construct NACK_FRAGs for any missing pieces.
            {
                var bitmap_frag_budget: usize = 1;
                var sn: SequenceNumber = nack_set.base;
                var bit: u32 = 0;
                while (bit < nack_set.num_bits) : ({
                    sn += 1;
                    bit += 1;
                }) {
                    if (!nack_set.contains(sn)) continue;
                    if (sn < rp.start_sn) continue;
                    // Don't retransmit changes that are still inside a coherent window.
                    if (self.isCoherentPendingSn(sn)) continue;
                    const ch = self.cache.getChange(sn) orelse {
                        // SN is allocated but absent from the history cache — it was
                        // reserved via allocSn() for a wire-only EOC marker.  Reply with
                        // a GAP so the reader can retire the SN and unblock pending_changes.
                        // Skip if this is the pending two-phase EOC: sendCombinedEOCData() +
                        // flushGroupEOCHBOnly() will send the EOC DATA + HB shortly; a premature
                        // GAP here would cause Connext to discard the EOC and never close the
                        // coherent set.
                        if (sn < self.cache.next_sn and sn != (self.pending_eoc_sn orelse 0)) {
                            const eoc_gap = msg.submessage.SequenceNumberSet{
                                .base = sn + 1,
                                .num_bits = 0,
                                .bitmap = std.mem.zeroes([8]u32),
                            };
                            var eg = MessageBuilder.init(&scratch, self.guid.prefix);
                            eg.addInfoDst(rp.guid.prefix);
                            eg.addGap(rp.guid.entity_id, self.guid.entity_id, sn, eoc_gap);
                            for (locs) |loc|
                                sendIovecs(self.transport, &loc, eg.iovecs()) catch {};
                            retransmit_count += 1;
                        }
                        continue;
                    };
                    retransmitChange(self, rp, ch, &scratch, &bitmap_frag_budget);
                    retransmit_count += 1;
                }
            }

            // Per §8.3.7.1.2: non-final AckNack requires sending ALL changes
            // with SN >= nack_set.base not yet acknowledged by this proxy.
            if (!is_final) {
                // While suppress_live_data: do NOT send the pre-burst HB that
                // would reveal the live range (last_sn > history_floor_sn).
                // The reader already knows [first_sn, history_floor_sn] from
                // the HB sent during replayHistoryToProxyLocked; re-announcing
                // the full live range here would prompt the reader to NACK for
                // live data before its DataReader has flushed history.
                if (!rp.suppress_live_data) {
                    const effective_base = @max(nack_set.base, rp.start_sn);
                    if (self.cache.maxSn() >= effective_base and rp.reliable)
                        self.sendHeartbeatToProxyLocked(rp, false);
                }
                // For fragmented samples outside the explicit NACK bitmap, send
                // HEARTBEAT_FRAG only (budget=0): the reader either has partial
                // fragments (and will NACK_FRAG the missing ones after the
                // HEARTBEAT_FRAG) or will get a full retransmit on the next
                // ACKNACK cycle once its base advances to that SN.
                var nonfinal_frag_budget: usize = 0;
                for (self.cache.changes.items) |*ch| {
                    if (ch.sequence_number < nack_set.base) continue;
                    if (ch.sequence_number < rp.start_sn) continue;
                    // Don't retransmit changes that are still inside a coherent window.
                    if (self.isCoherentPendingSn(ch.sequence_number)) continue;
                    // While suppress_live_data: skip live SNs beyond history_floor_sn.
                    // Sending live data here races with the DataReader's history flush.
                    if (rp.suppress_live_data and ch.sequence_number > rp.history_floor_sn) continue;
                    // Skip if already covered by the NACK bitmap above.
                    const offset = ch.sequence_number - nack_set.base;
                    if (offset < nack_set.num_bits and nack_set.contains(ch.sequence_number)) continue;
                    retransmitChange(self, rp, ch, &scratch, &nonfinal_frag_budget);
                    retransmit_count += 1;
                }
            }
            // When data was retransmitted, follow with a Heartbeat so the reader
            // learns the current [first_sn, last_sn] range.  Required for KEEP_LAST
            // scenarios where first_sn > 1: the reader needs the Heartbeat to know
            // that early SNs are permanently evicted (virtual GAP unblocks buffered
            // pending changes).  Only sent when data was actually retransmitted to
            // avoid an AckNack ↔ Heartbeat busyloop when there is nothing to send.
            // While suppress_live_data, cap last_sn at history_floor_sn: the reader
            // needs the gap signal (first_sn for KEEP_LAST) but must not learn about
            // live SNs before the DataReader has flushed history.
            if (retransmit_count > 0) rp.last_ack_nack_count = count;
            if (retransmit_count > 0 and rp.reliable) {
                if (rp.suppress_live_data) {
                    self.sendHeartbeatToProxyLockedCapped(rp, false, rp.history_floor_sn);
                } else {
                    self.sendHeartbeatToProxyLocked(rp, false);
                }
            }
            break; // GUIDs are unique; no need to scan further
        }

        self.mu.unlock();

        if (probe_cleared) |prefix| {
            if (self.probe_result_fn) |f| f(self.probe_result_ctx.?, prefix, true);
        }
        if (newly_ready_guid) |guid| {
            if (self.protocol_ready_fn) |f| f(self.protocol_ready_ctx.?, guid, true);
        }
    }

    fn sendChangeToAllLocked(self: *Self, ch: *const CacheChange, send_trailing_hb: bool) void {
        log.rtps.debug("StatefulWriter({x}): sendChangeToAll sn={} to {} readers", .{
            self.guid.entity_id.entity_key, ch.sequence_number, self.reader_proxies.items.len,
        });
        const fragmented = ch.data.len > self.frag_size;
        if (fragmented) {
            // Increment once; all proxies share the same HEARTBEAT_FRAG count for
            // this send event (mirrors how sendHeartbeat works for HEARTBEAT).
            self.hb_count += 1;
        }
        const hb_count_snap = self.hb_count;
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        for (self.reader_proxies.items) |*rp| {
            if (rp.suppress_live_data) continue;
            const locs = rp.effectiveLocators();
            if (locs.len == 0) continue;
            log.rtps.debug("StatefulWriter({x}): sending sn={} to {} locator(s) reader_eid={x}|{x:0>2}", .{
                self.guid.entity_id.entity_key, ch.sequence_number,            locs.len,
                rp.guid.entity_id.entity_key,   rp.guid.entity_id.entity_kind,
            });
            self.tracer.submit(.{ .send_data = .{
                .src_prefix = self.guid.prefix,
                .writer_eid = self.guid.entity_id,
                .reader_eid = rp.guid.entity_id,
                .sn = ch.sequence_number,
                .key_hash = ch.key_hash,
                .data_len = @intCast(ch.data.len),
            } });
            if (fragmented) {
                // Reliable readers: send only frag 1 + HEARTBEAT_FRAG.  The reader
                // NACK_FRAGs the remaining fragments on demand.  Sending all N frags
                // in the live path would saturate the reader's UDP recv buffer when
                // a NACK_FRAG recovery burst (N-1 frags) is still in flight.
                if (rp.reliable) {
                    self.sendFrag1ToProxyLocked(rp, ch, hb_count_snap, &scratch);
                } else {
                    self.sendFragsToProxyLocked(rp, ch, hb_count_snap, &scratch);
                }
            } else {
                var b = MessageBuilder.init(&scratch, self.guid.prefix);
                b.addInfoDst(rp.guid.prefix);
                b.addInfoTs(ch.source_timestamp);
                b.addData(.{
                    .reader_entity_id = rp.guid.entity_id,
                    .writer_entity_id = self.guid.entity_id,
                    .writer_sn = ch.sequence_number,
                    .key_hash = if (!std.mem.eql(u8, &ch.key_hash, &std.mem.zeroes([16]u8)))
                        ch.key_hash
                    else
                        null,
                    .is_key = ch.kind != .alive,
                    .status_info = statusInfoFromKind(ch.kind),
                    .coherent_set_sn = ch.coherent_set_sn,
                    .group_seq_num = ch.group_seq_num,
                    .group_coherent_sn = ch.group_coherent_sn,
                    .lifespan = if (ch.kind == .alive) self.lifespan else null,
                }, ch.data);
                for (locs) |loc| {
                    sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                        // SEDP already filtered proxy locators to those canReach(); this is defence-in-depth.
                        error.UnsupportedLocatorKind => {},
                        else => log.rtps.warn("StatefulWriter.write: send error: {}", .{err}),
                    };
                }
                // Follow each DATA with a non-final HEARTBEAT so the reader learns
                // the current [first_sn, last_sn] range and replies with ACKNACK.
                // Required for reliable delivery: implementations such as OpenDDS
                // gate sample delivery on receiving a confirming HEARTBEAT.
                // Skip for BEST_EFFORT proxies: they never send AckNack, and sending
                // a Heartbeat would trigger a synchronous AckNack round-trip when
                // using MemoryTransport, re-entering the writer's mutex.
                // Callers that flush a whole coherent set at once pass false here and
                // send ONE heartbeat after all samples instead; this prevents the
                // per-DATA heartbeat from triggering a premature coherent WIP flush
                // on the subscriber side before all set samples have arrived.
                if (rp.reliable and send_trailing_hb) self.sendHeartbeatToProxyLocked(rp, false);
            }
        }
        if (ch.sequence_number > self.last_flushed_sn)
            self.last_flushed_sn = ch.sequence_number;
    }

    /// Send a fragmented change to a single reader proxy as N DATA_FRAG datagrams
    /// followed by one HEARTBEAT_FRAG (§8.4.14).  Called under self.mu.
    fn sendFragsToProxyLocked(
        self: *Self,
        rp: *const ReaderProxy,
        ch: *const CacheChange,
        hb_count: i32,
        scratch: *[SCRATCH_SIZE]u8,
    ) void {
        const locs = rp.effectiveLocators();
        if (locs.len == 0) return;

        const frag_size: usize = self.frag_size;
        const data_size: u32 = @intCast(ch.data.len);
        const num_frags: u32 = @intCast((ch.data.len + frag_size - 1) / frag_size);

        var frag_num: u32 = 1;
        var offset: usize = 0;
        while (offset < ch.data.len) : ({
            frag_num += 1;
            offset += frag_size;
        }) {
            const this_len = @min(frag_size, ch.data.len - offset);
            var b = MessageBuilder.init(scratch, self.guid.prefix);
            b.addInfoDst(rp.guid.prefix);
            if (frag_num == 1) b.addInfoTs(ch.source_timestamp);
            // Inline QoS (RTPS §9.6.3) belongs only on fragment 1 — later fragments
            // are pure data continuation; the reassembled sample carries the QoS.
            b.addDataFrag(.{
                .reader_entity_id = rp.guid.entity_id,
                .writer_entity_id = self.guid.entity_id,
                .writer_sn = ch.sequence_number,
                .fragment_starting_num = frag_num,
                .fragments_in_submessage = 1,
                .fragment_size = @intCast(frag_size),
                .data_size = data_size,
                .key_hash = if (frag_num == 1 and !std.mem.eql(u8, &ch.key_hash, &std.mem.zeroes([16]u8)))
                    ch.key_hash
                else
                    null,
                .status_info = if (frag_num == 1) statusInfoFromKind(ch.kind) else null,
                .coherent_set_sn = if (frag_num == 1) ch.coherent_set_sn else null,
                .group_seq_num = if (frag_num == 1) ch.group_seq_num else null,
                .group_coherent_sn = if (frag_num == 1) ch.group_coherent_sn else null,
                .lifespan = if (frag_num == 1 and ch.kind == .alive) self.lifespan else null,
            }, ch.data[offset..][0..this_len]);
            for (locs) |loc| sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                error.UnsupportedLocatorKind => {}, // same defence-in-depth as DATA path above
                else => log.rtps.warn("StatefulWriter: DATA_FRAG {}/{} send error: {}", .{ frag_num, num_frags, err }),
            };
        }

        // HEARTBEAT_FRAG tells the reader all fragments 1..num_frags are available.
        var b = MessageBuilder.init(scratch, self.guid.prefix);
        b.addInfoDst(rp.guid.prefix);
        b.addHeartbeatFrag(rp.guid.entity_id, self.guid.entity_id, ch.sequence_number, num_frags, hb_count);
        for (locs) |loc| sendIovecs(self.transport, &loc, b.iovecs()) catch {};
    }

    /// Send only fragment 1 of a fragmented change followed by a HEARTBEAT_FRAG.
    /// Used for reliable readers in the live write path so that a NACK_FRAG
    /// recovery burst (frags 2..N) already in flight cannot overlap with a fresh
    /// full-fragment burst and overflow the reader's UDP recv buffer.
    fn sendFrag1ToProxyLocked(
        self: *Self,
        rp: *const ReaderProxy,
        ch: *const CacheChange,
        hb_count: i32,
        scratch: *[SCRATCH_SIZE]u8,
    ) void {
        const locs = rp.effectiveLocators();
        if (locs.len == 0) return;

        const frag_size: usize = self.frag_size;
        const num_frags: u32 = @intCast((ch.data.len + frag_size - 1) / frag_size);

        {
            var b = MessageBuilder.init(scratch, self.guid.prefix);
            b.addInfoDst(rp.guid.prefix);
            b.addInfoTs(ch.source_timestamp);
            b.addDataFrag(.{
                .reader_entity_id = rp.guid.entity_id,
                .writer_entity_id = self.guid.entity_id,
                .writer_sn = ch.sequence_number,
                .fragment_starting_num = 1,
                .fragments_in_submessage = 1,
                .fragment_size = @intCast(frag_size),
                .data_size = @intCast(ch.data.len),
                .key_hash = if (!std.mem.eql(u8, &ch.key_hash, &std.mem.zeroes([16]u8)))
                    ch.key_hash
                else
                    null,
                .status_info = statusInfoFromKind(ch.kind),
                .coherent_set_sn = ch.coherent_set_sn,
                .group_seq_num = ch.group_seq_num,
                .group_coherent_sn = ch.group_coherent_sn,
                .lifespan = if (ch.kind == .alive) self.lifespan else null,
            }, ch.data[0..@min(frag_size, ch.data.len)]);
            for (locs) |loc| sendIovecs(self.transport, &loc, b.iovecs()) catch |err| switch (err) {
                error.UnsupportedLocatorKind => {},
                else => log.rtps.warn("StatefulWriter: DATA_FRAG 1/{} send error: {}", .{ num_frags, err }),
            };
        }
        {
            var hb = MessageBuilder.init(scratch, self.guid.prefix);
            hb.addInfoDst(rp.guid.prefix);
            hb.addHeartbeatFrag(rp.guid.entity_id, self.guid.entity_id, ch.sequence_number, num_frags, hb_count);
            for (locs) |loc| sendIovecs(self.transport, &loc, hb.iovecs()) catch {};
        }
    }

    /// Handle an incoming NACK_FRAG from a matched reader.
    /// Retransmits the specific fragments requested by the bitmap.
    pub fn handleNackFrag(
        self: *Self,
        reader_guid: Guid,
        writer_sn: SequenceNumber,
        frag_set: msg.submessage.FragmentNumberSet,
        count: i32,
    ) void {
        self.mu.lock();
        defer self.mu.unlock();

        const ch = self.cache.getChange(writer_sn) orelse return;
        const frag_size: usize = self.frag_size;
        if (ch.data.len <= frag_size) return; // not a fragmented change

        for (self.reader_proxies.items) |*rp| {
            if (!rp.guid.eql(reader_guid)) continue;

            // Stale NACK_FRAG suppression (§8.3.8.12): ignore if count is not
            // strictly greater than the last accepted count from this reader.
            if (rp.last_nack_frag_count) |last| {
                const diff: i32 = @bitCast(@as(u32, @bitCast(count)) -% @as(u32, @bitCast(last)));
                if (diff <= 0) return;
            }
            rp.last_nack_frag_count = count;
            const locs = rp.effectiveLocators();
            if (locs.len == 0) return;

            var scratch: [SCRATCH_SIZE]u8 = undefined;
            const data_size: u32 = @intCast(ch.data.len);
            const num_frags: u32 = @intCast((ch.data.len + frag_size - 1) / frag_size);

            var frag_num: u32 = frag_set.base;
            const end_frag = frag_set.base + frag_set.num_bits;
            while (frag_num < end_frag) : (frag_num += 1) {
                if (!frag_set.contains(frag_num)) continue;
                const offset: usize = @as(usize, frag_num - 1) * frag_size;
                if (offset >= ch.data.len) break;
                const this_len = @min(frag_size, ch.data.len - offset);
                var b = MessageBuilder.init(&scratch, self.guid.prefix);
                b.addInfoDst(rp.guid.prefix);
                b.addDataFrag(.{
                    .reader_entity_id = rp.guid.entity_id,
                    .writer_entity_id = self.guid.entity_id,
                    .writer_sn = writer_sn,
                    .fragment_starting_num = frag_num,
                    .fragments_in_submessage = 1,
                    .fragment_size = @intCast(frag_size),
                    .data_size = data_size,
                    .key_hash = if (frag_num == 1 and !std.mem.eql(u8, &ch.key_hash, &std.mem.zeroes([16]u8)))
                        ch.key_hash
                    else
                        null,
                    .status_info = if (frag_num == 1) statusInfoFromKind(ch.kind) else null,
                    .coherent_set_sn = if (frag_num == 1) ch.coherent_set_sn else null,
                    .group_seq_num = if (frag_num == 1) ch.group_seq_num else null,
                    .group_coherent_sn = if (frag_num == 1) ch.group_coherent_sn else null,
                    .lifespan = if (frag_num == 1 and ch.kind == .alive) self.lifespan else null,
                }, ch.data[offset..][0..this_len]);
                for (locs) |loc| sendIovecs(self.transport, &loc, b.iovecs()) catch {};
            }

            // Follow retransmit with a HEARTBEAT_FRAG.
            self.hb_count += 1;
            var b = MessageBuilder.init(&scratch, self.guid.prefix);
            b.addInfoDst(rp.guid.prefix);
            b.addHeartbeatFrag(rp.guid.entity_id, self.guid.entity_id, writer_sn, num_frags, self.hb_count);
            for (locs) |loc| sendIovecs(self.transport, &loc, b.iovecs()) catch {};
            return;
        }
    }

    /// Returns true if `sn` is inside the current coherent window and should
    /// not be sent or retransmitted until endCoherentSet() is called.
    fn isCoherentPendingSn(self: *const Self, sn: SequenceNumber) bool {
        if (!self.coherent_active) return false;
        for (self.coherent_pending_sns.items) |pending| {
            if (pending == sn) return true;
        }
        return false;
    }

    /// Start a coherent set window.
    /// `is_coherent_window`: true when called from begin_coherent_changes (marks the
    /// current buffer depth as the coherent window start so that pre-suspension writes
    /// are not incorrectly tagged as part of the coherent set on endCoherentSet).
    /// false when called from suspend_publications (activates buffering only).
    pub fn beginCoherentSet(self: *Self, is_coherent_window: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (is_coherent_window and self.coherent_active) {
            // Already buffering from suspend_publications — record where the actual
            // coherent window begins so pre-window writes flush without coherent QoS.
            self.coherent_window_start = self.coherent_pending_sns.items.len;
        } else {
            self.coherent_active = true;
        }
    }

    /// Returns the number of samples buffered in the coherent window (i.e. those that
    /// will be tagged with coherent-set inline QoS on the next endCoherentSet).
    /// Used by the publisher to pre-compute the group-wide last GSN before flushing.
    pub fn coherentWindowPendingCount(self: *Self) usize {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.coherent_pending_sns.items.len < self.coherent_window_start) return 0;
        return self.coherent_pending_sns.items.len - self.coherent_window_start;
    }

    /// Flush a deferred coherent/ordered batch.
    ///   .full           — PID_COHERENT_SET + PID_GROUP_SEQ_NUM + PID_GROUP_COHERENT_SET (GROUP scope)
    ///   .coherent_only  — PID_COHERENT_SET only (INSTANCE/TOPIC scope coherent_access)
    ///   .group_seq_only — PID_GROUP_SEQ_NUM only (ordered_access without coherent_access)
    ///   .none           — no inline QoS (resume_publications)
    /// `resuspend`: if true, re-arms coherent_active=true before releasing the lock so
    /// that concurrent write() calls never observe a window where suspension is inactive.
    ///
    /// When coherent_window_start > 0, items [0..coherent_window_start) were written
    /// during suspension before begin_coherent_changes and are flushed without coherent
    /// QoS; only items [coherent_window_start..) belong to the coherent set.
    /// `publisher_gsn`: when non-null, points to the publisher's shared GSN counter.
    /// All writers in the same publisher flush with sequentially assigned GSNs drawn
    /// from this shared counter, ensuring global write-order across writers in a
    /// GROUP_PRESENTATION coherent set.  When null, the writer uses its own per-writer
    /// counter (standalone writer usage — single-writer publishers or direct tests).
    /// `global_last_gsn`: the group-wide last GSN across ALL writers in the publisher's
    /// coherent set.  Written into PID_GROUP_COHERENT_SET on the last sample from this
    /// writer so the receiver knows when the full group set has arrived.  0 = use the
    /// per-writer last GSN (standalone/single-writer path where they are equal).
    pub fn endCoherentSet(self: *Self, mode: history_mod.CoherentFlushMode, resuspend: bool, publisher_gsn: ?*i64, global_last_gsn: i64, defer_eoc: bool) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.coherent_active = false;
        defer if (resuspend) {
            self.coherent_active = true;
        };

        const window_start = self.coherent_window_start;
        self.coherent_window_start = 0;

        const all_sns = self.coherent_pending_sns.items;
        if (all_sns.len == 0) return;

        // Flush pre-window writes (from suspension before begin_coherent_changes)
        // without coherent QoS — they are not part of the coherent set.
        for (all_sns[0..window_start]) |sn| {
            if (self.cache.getChange(sn)) |ch| self.sendChangeToAllLocked(ch, true);
        }

        const coherent_sns = all_sns[window_start..];
        if (coherent_sns.len == 0) {
            self.coherent_pending_sns.clearRetainingCapacity();
            return;
        }

        const last_sn = coherent_sns[coherent_sns.len - 1];
        const first_sn = coherent_sns[0];
        const n: i64 = @intCast(coherent_sns.len);
        if (mode != .none) {
            // PID_COHERENT_SET: stamp the first SN of the coherent window on all
            // samples.  RTI Connext groups samples by this value and treats a
            // CS transition (new value arriving) as the end-of-set signal.
            if (mode == .full or mode == .coherent_only) {
                for (coherent_sns) |sn| {
                    for (self.cache.changes.items) |*ch| {
                        if (ch.sequence_number == sn) {
                            ch.coherent_set_sn = first_sn;
                            break;
                        }
                    }
                }
            }
            // PID_GROUP_SEQ_NUM / PID_GROUP_COHERENT_SET: GROUP-scope and ordered-access
            // only.  Always assign even when no readers are matched — late-joining
            // KEEP_ALL readers will receive history with correct inline QoS via NACK repair.
            if (mode == .full or mode == .group_seq_only) {
                const base_gsn = if (publisher_gsn) |pg| pg.* else self.group_seq_num_counter;
                const last_gsn = base_gsn + n;
                const group_end_gsn = if (global_last_gsn != 0) global_last_gsn else last_gsn;
                for (coherent_sns, 1..) |sn, i| {
                    const gsn: i64 = base_gsn + @as(i64, @intCast(i));
                    for (self.cache.changes.items) |*ch| {
                        if (ch.sequence_number == sn) {
                            ch.group_seq_num = gsn;
                            if (mode == .full and sn == last_sn) ch.group_coherent_sn = group_end_gsn;
                            break;
                        }
                    }
                }
                if (publisher_gsn) |pg| {
                    pg.* += n;
                } else {
                    self.group_seq_num_counter += n;
                }
            }
        }
        for (coherent_sns) |sn| {
            if (self.cache.getChange(sn)) |ch| {
                // No per-DATA heartbeat: send one HB after all coherent samples so the
                // subscriber's coherent WIP is not flushed prematurely on the first sample.
                self.sendChangeToAllLocked(ch, false);
            }
        }
        // End-of-coherent-set marker: a DATA with DataFlag=0 and no inline QoS.
        // Per RTPS §9.6.4.2 Table 9.22 (Example 3), this is the minimal explicit
        // end-of-set signal — any DATA from this writer without PID_COHERENT_SET
        // tells the receiver the previous coherent set is complete.  Sent before
        // the per-proxy HEARTBEATs so best-effort readers also get it.
        // Only meaningful for coherent-access modes; .none and .group_seq_only
        // do not use PID_COHERENT_SET so there is no coherent set to terminate.
        if (mode == .coherent_only or mode == .full) {
            const eoc_sn = self.cache.allocSn();
            if (defer_eoc) {
                // Phase 1 of a two-phase flush (all coherent-access scopes): stash the
                // EOC SN and return.  sendCombinedEOCData() + flushGroupEOCHBOnly() send
                // EOC DATA + HBs for all writers together so Connext completes all per-reader
                // coherent sets at roughly the same time, preventing a subscriber poll from
                // splitting a multi-topic coherent window.
                self.pending_eoc_sn = eoc_sn;
                self.coherent_pending_sns.clearRetainingCapacity();
                return;
            }
            var eoc_scratch: [SCRATCH_SIZE]u8 = undefined;
            for (self.reader_proxies.items) |*rp| {
                if (rp.suppress_live_data) continue;
                const locs = rp.effectiveLocators();
                if (locs.len == 0) continue;
                var b = MessageBuilder.init(&eoc_scratch, self.guid.prefix);
                b.addInfoDst(rp.guid.prefix);
                b.addData(.{
                    .reader_entity_id = rp.guid.entity_id,
                    .writer_entity_id = self.guid.entity_id,
                    .writer_sn = eoc_sn,
                    .no_payload = true,
                }, &.{});
                for (locs) |loc| sendIovecs(self.transport, &loc, b.iovecs()) catch {};
            }
            // One heartbeat after all coherent-set samples so reliable readers learn the
            // full [first_sn, last_sn] range and the subscriber can commit the complete WIP.
            // Also include a GAP for eoc_sn so readers that missed the EOC DATA can retire
            // it and unblock delivery of subsequent non-coherent samples.
            const cache_last = self.cache.maxSn();
            for (self.reader_proxies.items) |*rp| {
                if (!rp.reliable) continue;
                const proxy_eoc_sn = if (!rp.suppress_live_data) eoc_sn else null;
                self.sendHeartbeatToProxyLockedWithLastSn(rp, false, cache_last, proxy_eoc_sn);
            }
        } else {
            // Non-coherent modes (.none, .group_seq_only): no EOC, but still send HB.
            const cache_last = self.cache.maxSn();
            for (self.reader_proxies.items) |*rp| {
                if (!rp.reliable) continue;
                self.sendHeartbeatToProxyLockedWithLastSn(rp, false, cache_last, null);
            }
        }
        self.coherent_pending_sns.clearRetainingCapacity();
    }

    /// Phase 3 of a publisher-level combined EOC flush (all coherent-access scopes).
    /// Called after the publisher has sent the combined EOC DATA via sendCombinedEOCData().
    /// Sends per-proxy HBs using the EOC SN stashed by takeEOCProxyInfos(), then clears it.
    /// No-op if no pending EOC is set.
    pub fn flushGroupEOCHBOnly(self: *Self) void {
        self.mu.lock();
        defer self.mu.unlock();
        const eoc_sn = self.pending_eoc_sn orelse return;
        self.pending_eoc_sn = null;
        // Advertise lastSN=eoc_sn (not just cache.maxSn()) so Connext learns the full
        // committed range including the EOC marker.  If Connext missed the EOC DATA
        // packet it will NACK eoc_sn; the NACK handler responds with GAP(eoc_sn) which
        // is the only safe time to retire it — after the DATA has been in flight long
        // enough for Connext to have received it (pull-based recovery, no race).
        const cache_last = eoc_sn;
        const cache_first = self.cache.minSn();
        // Override first_sn to cache.minSn() rather than max(cache.minSn(), rp.start_sn):
        // all coherent SNs are sent to readers regardless of start_sn (sendChangeToAllLocked
        // has no start_sn guard), so advertising firstSN=start_sn would make Connext think
        // the coherent set started after the coherent_set_sn, causing it to reject GROUP delivery.
        const first_sn_override: ?SequenceNumber = if (cache_first > 0) cache_first else 1;
        for (self.reader_proxies.items) |*rp| {
            if (!rp.reliable) continue;
            // Skip history-replaying proxies: they never received the coherent DATA or EOC
            // (sendChangeToAllLocked and takeEOCProxyInfos both skip suppress_live_data).
            // Advertising eoc_sn to them would trigger an unnecessary NACK round-trip for an
            // SN they can never receive.  The background HB handles their history range.
            if (rp.suppress_live_data) continue;
            self.sendHeartbeatToProxyLockedWithLastSnAndFirstSn(rp, false, cache_last, null, first_sn_override);
        }
    }

    /// Background thread: sends a non-final HEARTBEAT every HB_INTERVAL_MS ms.
    /// Readers reply with ACKNACK; writer retransmits any missing data.
    /// Also checks probe deadlines: evicts proxies that haven't ACK'd in time.
    /// Stopped by setting hb_stopping before calling hb_thread.join().
    fn heartbeatThread(self: *Self) void {
        while (!self.hb_stopping.load(.acquire)) {
            var slept_ms: u64 = 0;
            while (slept_ms < HB_INTERVAL_MS and !self.hb_stopping.load(.acquire)) {
                time_mod.sleepNs(50 * std.time.ns_per_ms);
                slept_ms += 50;
            }
            if (self.hb_stopping.load(.acquire)) break;
            self.sendHeartbeat(false);
            self.checkProbeDeadlines();
        }
    }

    /// Evict any reader proxies whose liveness-probe deadline has passed.
    /// Fires the probe_result_fn callback (alive=false) for each evicted proxy.
    /// Called under no lock; acquires and releases self.mu internally.
    pub fn checkProbeDeadlines(self: *Self) void {
        const now_ns = time_mod.monotonicClock().nowNs();

        var evicted: std.ArrayListUnmanaged(GuidPrefix) = .empty;
        defer evicted.deinit(self.alloc);

        self.mu.lock();
        var i: usize = self.reader_proxies.items.len;
        while (i > 0) {
            i -= 1;
            const rp = &self.reader_proxies.items[i];
            if (rp.probe_deadline_ns > 0 and now_ns >= rp.probe_deadline_ns) {
                evicted.append(self.alloc, rp.guid.prefix) catch {};
                rp.deinit(self.alloc);
                _ = self.reader_proxies.swapRemove(i);
            }
        }
        self.mu.unlock();

        for (evicted.items) |prefix| {
            if (self.probe_result_fn) |f| f(self.probe_result_ctx.?, prefix, false);
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

// Minimal no-op transport for testing.
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

test "StatelessWriter init/deinit" {
    const guid = makeGuid(1, 0xC3);
    const reid = guid_mod.EntityIds.spdp_builtin_participant_reader;
    const w = try StatelessWriter.init(testing.allocator, guid, null_transport, 1, reid);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.reader_locators.items.len);
}

test "StatelessWriter write stores change" {
    const guid = makeGuid(2, 0xC3);
    const reid = guid_mod.EntityIds.spdp_builtin_participant_reader;
    const w = try StatelessWriter.init(testing.allocator, guid, null_transport, 10, reid);
    defer w.deinit();
    const sn = try w.write(.alive, ZERO_TS, NIL_IH, NIL_KH, "payload");
    try testing.expectEqual(@as(SequenceNumber, 1), sn);
    w.mu.lock();
    const found = w.cache.getChange(1) != null;
    w.mu.unlock();
    try testing.expect(found);
}

test "StatefulWriter init/deinit" {
    const guid = makeGuid(3, 0xC2);
    const reid = guid_mod.EntityIds.sedp_builtin_publications_reader;
    const w = try StatefulWriter.init(testing.allocator, guid, null_transport, .keep_all, 0, reid, DEFAULT_FRAG_SIZE, true);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.reader_proxies.items.len);
}

test "StatefulWriter addMatchedReader and removeMatchedReader" {
    const guid = makeGuid(4, 0xC2);
    const reid = guid_mod.EntityIds.sedp_builtin_publications_reader;
    const w = try StatefulWriter.init(testing.allocator, guid, null_transport, .keep_all, 0, reid, DEFAULT_FRAG_SIZE, true);
    defer w.deinit();

    const rg = makeGuid(9, 0xC7);
    const rp = try ReaderProxy.init(testing.allocator, rg, &.{}, &.{}, false, true);
    try w.addMatchedReader(rp);
    try testing.expectEqual(@as(usize, 1), w.reader_proxies.items.len);
    w.removeMatchedReader(rg);
    try testing.expectEqual(@as(usize, 0), w.reader_proxies.items.len);
}

test "ReaderProxy primaryLocator" {
    const rg = makeGuid(5, 0xC7);
    const loc = Locator.udp4(.{ 192, 168, 1, 1 }, 7412);
    var rp = try ReaderProxy.init(testing.allocator, rg, &.{loc}, &.{}, false, true);
    defer rp.deinit(testing.allocator);
    const primary = rp.primaryLocator().?;
    try testing.expect(loc.eql(primary));
}
