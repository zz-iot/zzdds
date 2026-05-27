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
    /// Last accepted NACK_FRAG count for stale-submessage suppression (§8.3.8.12).
    /// Null until the first NACK_FRAG from this reader is accepted.
    last_nack_frag_count: ?i32,
    /// When true, suppress all DATA sends to this proxy until it sends a
    /// non-final ACKNACK with highest_sn >= history_floor_sn.  Cleared only
    /// on a non-final NACK so that RTI Connext has time to flush its durability
    /// history buffer to the DataReader before the first live sample arrives.
    /// A final NACK means "I'm satisfied" — not "send me live data" — so it
    /// must not clear this flag.
    awaiting_first_ack: bool,
    /// cache.maxSn() at the time this proxy was created with awaiting_first_ack.
    /// Threshold for clearing awaiting_first_ack: the reader's cumulative ack
    /// must reach this SN on a non-final NACK before live data is unblocked.
    history_floor_sn: SequenceNumber,

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
            .last_nack_frag_count = null,
            .awaiting_first_ack = false,
            .history_floor_sn = 0,
        };
        try self.unicast_locators.appendSlice(alloc, unicast_locators);
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
            .hb_count = 0,
            .tracer = trace.Tracer.noop(),
            .frag_size = frag_size,
            .replay_on_match = replay_on_match,
            .hb_thread = null,
            .hb_stopping = std.atomic.Value(bool).init(false),
        };
        return self;
    }

    pub fn setTracer(self: *Self, t: trace.Tracer) void {
        self.tracer = t;
    }

    pub fn deinit(self: *Self) void {
        self.hb_stopping.store(true, .release);
        if (self.hb_thread) |t| {
            t.join();
            self.hb_thread = null;
        }
        for (self.reader_proxies.items) |*rp| rp.deinit(self.alloc);
        self.reader_proxies.deinit(self.alloc);
        self.cache.deinit();
        self.alloc.destroy(self);
    }

    /// Returns true when every RELIABLE reader proxy has cumulatively acked
    /// all changes up to and including `target_sn`.  BEST_EFFORT proxies are
    /// excluded since they never send AckNack.  Returns true immediately when
    /// there are no RELIABLE proxies or `target_sn` is 0.
    pub fn allProxiesAcked(self: *Self, target_sn: SequenceNumber) bool {
        if (target_sn == 0) return true;
        self.mu.lock();
        defer self.mu.unlock();
        for (self.reader_proxies.items) |rp| {
            if (rp.reliable and rp.highest_acked_sn < target_sn) return false;
        }
        return true;
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
        defer self.mu.unlock();
        for (self.reader_proxies.items) |*rp| {
            if (rp.guid.eql(proxy.guid)) {
                // Lease refresh: update locators/metadata, preserve ack state.
                rp.unicast_locators.deinit(self.alloc);
                rp.multicast_locators.deinit(self.alloc);
                rp.unicast_locators = proxy.unicast_locators;
                rp.multicast_locators = proxy.multicast_locators;
                rp.reliable = proxy.reliable;
                rp.expects_inline_qos = proxy.expects_inline_qos;
                // Dispose the incoming proxy's empty locator lists.
                var discarded = proxy;
                discarded.unicast_locators = .empty;
                discarded.multicast_locators = .empty;
                discarded.deinit(self.alloc);
                return;
            }
        }
        try self.reader_proxies.append(self.alloc, proxy);
        const new_rp = &self.reader_proxies.items[self.reader_proxies.items.len - 1];
        if (!self.replay_on_match) new_rp.start_sn = self.cache.next_sn;
        // Set awaiting_first_ack before replay so the flag is visible to any
        // write() that acquires mu after we release it.  The replay sends
        // directly to the proxy (not through sendChangeToAllLocked) so it is
        // unaffected by the flag itself.
        if (new_rp.reliable and self.replay_on_match and self.cache.changes.items.len > 0) {
            new_rp.awaiting_first_ack = true;
            new_rp.history_floor_sn = self.cache.maxSn();
        }
        if (self.replay_on_match) self.replayHistoryToProxyLocked(new_rp) else if (new_rp.reliable) self.sendHeartbeatToProxyLocked(new_rp, false);
        // Start the periodic heartbeat thread on the first matched reader so
        // that dropped DATA or HEARTBEAT packets can be recovered via NACK.
        if (self.hb_thread == null) {
            self.hb_thread = std.Thread.spawn(.{}, heartbeatThread, .{self}) catch null;
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
        // For reliable readers: send HB only and let the NACK cycle handle data
        // delivery.  The proxy on the remote side may not yet exist when the
        // HB+DATA burst arrives (SEDP matching is async), so eagerly sending DATA
        // risks the reader receiving samples before it has seen any HB — causing
        // immediate delivery without gap detection on some implementations.
        // The NACK triggered by the HB proves the proxy exists and gives us a
        // chance to send a leading HB (in handleAckNack) before retransmitting,
        // guaranteeing the reader has context before any DATA arrives.
        // BEST_EFFORT readers never NACK, so we must still send DATA eagerly.
        if (rp.reliable) return;
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
                    .status_info = statusInfoFromKind(ch.kind),
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
        const locs = rp.effectiveLocators();
        if (locs.len == 0) return;
        self.hb_count += 1;
        const cache_first = self.cache.minSn();
        const cache_last = self.cache.maxSn();
        const first_sn = @max(if (cache_first == 0) 1 else cache_first, rp.start_sn);
        const last_sn = if (cache_last == 0) 0 else cache_last;
        var scratch: [SCRATCH_SIZE]u8 = undefined;
        var b = MessageBuilder.init(&scratch, self.guid.prefix);
        b.addInfoDst(rp.guid.prefix);
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
        defer self.mu.unlock();
        var i: usize = self.reader_proxies.items.len;
        while (i > 0) {
            i -= 1;
            if (self.reader_proxies.items[i].guid.eql(guid)) {
                self.reader_proxies.items[i].deinit(self.alloc);
                _ = self.reader_proxies.swapRemove(i);
            }
        }
    }

    /// Store a new change and send it immediately to all matched readers.
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
        if (self.cache.getChange(sn)) |ch| {
            self.sendChangeToAllLocked(ch);
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

        for (self.reader_proxies.items) |*rp| {
            if (!rp.reliable) continue; // BEST_EFFORT readers do not use HEARTBEAT/ACKNACK
            const locs = rp.effectiveLocators();
            if (locs.len == 0) continue;
            const first_sn = @max(if (cache_first == 0) 1 else cache_first, rp.start_sn);
            const last_sn = if (cache_last == 0) 0 else cache_last;
            var b = MessageBuilder.init(&scratch, self.guid.prefix);
            b.addInfoDst(rp.guid.prefix);
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
        self.mu.lock();
        defer self.mu.unlock();

        for (self.reader_proxies.items) |*rp| {
            if (!rp.guid.eql(reader_guid)) continue;
            rp.highest_acked_sn = @max(rp.highest_acked_sn, highest_sn);
            // Only unblock live data once the reader sends a NON-FINAL NACK
            // with highest_sn at or past the history floor.  A non-final NACK
            // means RTI is actively requesting live samples (it has finished
            // flushing durability history to the DataReader and is now asking
            // for more).  A final NACK ("I'm satisfied") must NOT clear the
            // flag: RTI may still be flushing history internally when it sends
            // a final NACK, and unblocking there races live DATA ahead of [1].
            if (rp.awaiting_first_ack and !is_final and highest_sn >= rp.history_floor_sn) {
                rp.awaiting_first_ack = false;
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
            if (locs.len == 0) return;

            var retransmit_count: usize = 0;

            // Helper: retransmit one change to this proxy (fragmented or not).
            const retransmitChange = struct {
                fn call(w: *Self, proxy: *const ReaderProxy, ch: *const CacheChange, s: *[SCRATCH_SIZE]u8) void {
                    w.tracer.submit(.{ .send_data = .{
                        .src_prefix = w.guid.prefix,
                        .writer_eid = w.guid.entity_id,
                        .reader_eid = proxy.guid.entity_id,
                        .sn = ch.sequence_number,
                        .key_hash = ch.key_hash,
                        .data_len = @intCast(ch.data.len),
                    } });
                    if (ch.data.len > w.frag_size) {
                        w.hb_count += 1;
                        w.sendFragsToProxyLocked(proxy, ch, w.hb_count, s);
                    } else {
                        var b = MessageBuilder.init(s, w.guid.prefix);
                        b.addInfoDst(proxy.guid.prefix);
                        b.addInfoTs(ch.source_timestamp);
                        b.addData(.{
                            .reader_entity_id = proxy.guid.entity_id,
                            .writer_entity_id = w.guid.entity_id,
                            .writer_sn = ch.sequence_number,
                            .status_info = statusInfoFromKind(ch.kind),
                        }, ch.data);
                        for (proxy.effectiveLocators()) |loc| sendIovecs(w.transport, &loc, b.iovecs()) catch {};
                    }
                }
            }.call;

            // Retransmit explicitly NACKed changes (bitmap bits set to 1).
            // rp.start_sn guards against replaying pre-match data to VOLATILE readers.
            {
                var sn: SequenceNumber = nack_set.base;
                var bit: u32 = 0;
                while (bit < nack_set.num_bits) : ({
                    sn += 1;
                    bit += 1;
                }) {
                    if (!nack_set.contains(sn)) continue;
                    if (sn < rp.start_sn) continue;
                    const ch = self.cache.getChange(sn) orelse continue;
                    retransmitChange(self, rp, ch, &scratch);
                    retransmit_count += 1;
                }
            }

            // Per §8.3.7.1.2: non-final AckNack requires sending ALL changes
            // with SN >= nack_set.base not yet acknowledged by this proxy.
            if (!is_final) {
                // Send a HEARTBEAT before the burst so the reader learns
                // [first_sn, last_sn] before DATA arrives.  A reader proxy
                // that was just created (e.g. NACK with base=0 as first contact)
                // has no prior HB context; receiving DATA without it can cause
                // immediate delivery without gap detection.  Only sent when
                // there are changes to retransmit to avoid a non-final
                // ACKNACK ↔ HEARTBEAT busyloop when the cache has nothing at
                // or beyond nack_set.base.
                const effective_base = @max(nack_set.base, rp.start_sn);
                if (self.cache.maxSn() >= effective_base and rp.reliable)
                    self.sendHeartbeatToProxyLocked(rp, false);
                for (self.cache.changes.items) |*ch| {
                    if (ch.sequence_number < nack_set.base) continue;
                    if (ch.sequence_number < rp.start_sn) continue;
                    // Skip if already covered by the NACK bitmap above.
                    const offset = ch.sequence_number - nack_set.base;
                    if (offset < nack_set.num_bits and nack_set.contains(ch.sequence_number)) continue;
                    retransmitChange(self, rp, ch, &scratch);
                    retransmit_count += 1;
                }
            }
            // When data was retransmitted, follow with a Heartbeat so the reader
            // learns the current [first_sn, last_sn] range.  Required for KEEP_LAST
            // scenarios where first_sn > 1: the reader needs the Heartbeat to know
            // that early SNs are permanently evicted (virtual GAP unblocks buffered
            // pending changes).  Only sent when data was actually retransmitted to
            // avoid an AckNack ↔ Heartbeat busyloop when there is nothing to send.
            if (retransmit_count > 0 and rp.reliable) self.sendHeartbeatToProxyLocked(rp, false);
        }
    }

    fn sendChangeToAllLocked(self: *Self, ch: *const CacheChange) void {
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
            if (rp.awaiting_first_ack) continue;
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
                self.sendFragsToProxyLocked(rp, ch, hb_count_snap, &scratch);
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
                    .status_info = statusInfoFromKind(ch.kind),
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
                if (rp.reliable) self.sendHeartbeatToProxyLocked(rp, false);
            }
        }
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
            b.addDataFrag(.{
                .reader_entity_id = rp.guid.entity_id,
                .writer_entity_id = self.guid.entity_id,
                .writer_sn = ch.sequence_number,
                .fragment_starting_num = frag_num,
                .fragments_in_submessage = 1,
                .fragment_size = @intCast(frag_size),
                .data_size = data_size,
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

    /// Background thread: sends a non-final HEARTBEAT every HB_INTERVAL_MS ms.
    /// Readers reply with ACKNACK; writer retransmits any missing data.
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
