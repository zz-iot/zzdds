//! Protocol packaging interface.
//!
//! Sits between the DCPS layer and the wire protocol, providing the same
//! uniform API regardless of whether the underlying packaging is:
//!   - RTPS 2.5 (the default, via StatefulWriter/StatefulReader)
//!   - Zero-copy SHMEM fast path (no RTPS framing)
//!   - Future: QUIC, MQTT, custom hardware channel
//!
//! Data flow:
//!   DCPS DataWriter → ProtocolWriter.write(CDR bytes) → wire
//!   wire → ProtocolReader callback → DCPS DataReader
//!
//! Discovery (SPDP/SEDP) bypasses this interface and uses the RTPS state
//! machines directly. ProtocolWriter/ProtocolReader are for application data.

const std = @import("std");

const iface = @import("../transport/interface.zig");
const guid_mod = @import("../rtps/guid.zig");
const history_mod = @import("../rtps/history.zig");
const submsg_mod = @import("../rtps/message/submessage.zig");

pub const Guid = guid_mod.Guid;
pub const ChangeKind = history_mod.ChangeKind;
pub const InstanceHandle = history_mod.InstanceHandle;
pub const RtpsTimestamp = history_mod.RtpsTimestamp;
pub const SequenceNumber = history_mod.SequenceNumber;
pub const CacheChange = history_mod.CacheChange;
pub const CoherentFlushMode = history_mod.CoherentFlushMode;
pub const Locator = iface.Locator;
pub const SequenceNumberSet = submsg_mod.SequenceNumberSet;
pub const FragmentNumberSet = submsg_mod.FragmentNumberSet;
pub const DataFragSubmessage = submsg_mod.DataFragSubmessage;

// ── Matched endpoint information ──────────────────────────────────────────────

/// Reliability class for a matched endpoint.  Mirrors the DDS QoS value but
/// kept here to avoid a circular dependency on qos.zig.
pub const ReliabilityKind = enum(u8) { best_effort = 0, reliable = 1 };

/// What SEDP tells the protocol layer about a newly-matched remote reader.
pub const MatchedReaderInfo = struct {
    guid: Guid,
    unicast_locators: []const Locator,
    multicast_locators: []const Locator,
    expects_inline_qos: bool,
    reliability: ReliabilityKind,
};

/// What SEDP tells the protocol layer about a newly-matched remote writer.
pub const MatchedWriterInfo = struct {
    guid: Guid,
    unicast_locators: []const Locator,
    multicast_locators: []const Locator,
    reliability: ReliabilityKind,
    /// Only meaningful when the remote writer has EXCLUSIVE ownership.
    ownership_strength: i32 = 0,
    /// Liveliness lease duration in nanoseconds; 0 = infinite (no expiry tracking).
    liveliness_lease_ns: i64 = 0,
    /// Lifespan duration in nanoseconds; 0 = infinite (no expiry).
    lifespan_ns: i64 = 0,
    /// True when the writer offers TRANSIENT_LOCAL (or stronger) durability with RELIABLE
    /// reliability.  The reader must wait for history delivery before signalling completion
    /// of wait_for_historical_data.
    history_expected: bool = false,
};

// ── Data delivery callback ────────────────────────────────────────────────────

/// Invoked by the protocol reader when a complete, in-order change is ready.
/// Called under the protocol layer's internal lock; implementation must not
/// call back into the protocol reader.
pub const DataCallback = struct {
    ctx: *anyopaque,
    on_data: *const fn (ctx: *anyopaque, change: *const CacheChange) void,
    /// Optional: called when gap processing marks `count` sequence numbers as
    /// irreversibly lost (never delivered). Called under the same lock as on_data.
    on_sample_lost: ?*const fn (ctx: *anyopaque, count: i32) void = null,
    /// Optional: called when a valid (non-duplicate) HEARTBEAT arrives from a
    /// writer.  Used to flush coherent WIP when no CS transition follows the set.
    on_heartbeat: ?*const fn (ctx: *anyopaque, writer_guid: Guid, last_sn: SequenceNumber) void = null,
    /// Optional: called when a Connext-style zero-payload alive DATA arrives with
    /// no PID_COHERENT_SET — the end-of-coherent-set signal.  RTPS-level consumers
    /// leave this null; the DCPS layer registers it to flush the coherent WIP.
    on_eoc: ?*const fn (ctx: *anyopaque, change: *const CacheChange) void = null,
};

// ── ProtocolWriter ────────────────────────────────────────────────────────────

/// Write-side protocol abstraction. DCPS DataWriter holds one of these.
pub const ProtocolWriter = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Accept a new serialized sample. The protocol layer copies `data`
        /// into its history cache. Returns the sequence number assigned.
        write: *const fn (
            ctx: *anyopaque,
            kind: ChangeKind,
            source_timestamp: RtpsTimestamp,
            instance_handle: InstanceHandle,
            key_hash: [16]u8,
            data: []const u8,
        ) anyerror!SequenceNumber,

        /// SEDP matched a new remote reader. The protocol layer adds a proxy
        /// and begins sending cached history.
        add_matched_reader: *const fn (ctx: *anyopaque, info: *const MatchedReaderInfo) anyerror!void,

        /// SEDP removed a previously matched remote reader.
        remove_matched_reader: *const fn (ctx: *anyopaque, guid: Guid) void,

        /// Return the number of currently matched reader proxies.
        matched_reader_count: *const fn (ctx: *anyopaque) usize,

        /// Append the GUIDs of all currently matched reader proxies to `out`.
        list_matched_readers: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            out: *std.ArrayListUnmanaged(Guid),
        ) anyerror!void,

        /// Incoming ACKNACK from a matched reader. Updates proxy ACK state and
        /// retransmits requested changes per RTPS §8.3.7.1.2.
        handle_ack_nack: *const fn (
            ctx: *anyopaque,
            reader_guid: Guid,
            highest_sn: SequenceNumber,
            nack_set: SequenceNumberSet,
            count: i32,
            is_final: bool,
        ) void,

        /// Incoming NACK_FRAG from a matched reader. Retransmits the requested
        /// specific fragments for the given sequence number.
        handle_nack_frag: *const fn (
            ctx: *anyopaque,
            reader_guid: Guid,
            writer_sn: SequenceNumber,
            frag_set: FragmentNumberSet,
            count: i32,
        ) void,

        /// Returns true when every RELIABLE matched reader has acknowledged all
        /// changes up to and including `target_sn`.  BEST_EFFORT proxies are
        /// excluded.  Returns true immediately when `target_sn` is 0.
        all_acked: *const fn (ctx: *anyopaque, target_sn: SequenceNumber) bool,

        /// Block until every RELIABLE matched reader has acknowledged all changes
        /// up to and including `target_sn`, or until `deadline_ns` (monotonic ns)
        /// is reached.  Null `deadline_ns` waits indefinitely.
        /// Returns true on success, false on timeout.
        wait_all_acked: *const fn (ctx: *anyopaque, target_sn: SequenceNumber, deadline_ns: ?i64) bool,

        /// Return the current number of samples in the writer's history cache.
        /// Used to enforce RESOURCE_LIMITS.max_samples before writing.
        cache_len: *const fn (ctx: *anyopaque) usize,

        /// Begin a coherent set: subsequent write() calls are deferred until
        /// end_coherent_set().  `is_coherent_window` must be true when called from
        /// begin_coherent_changes (records the buffer depth as the coherent window
        /// start) and false when called from suspend_publications (activates buffering
        /// only, without marking a coherent window boundary).
        begin_coherent_set: *const fn (ctx: *anyopaque, is_coherent_window: bool) void,

        /// Returns the number of samples in the coherent window (used by the publisher
        /// to pre-compute the group-wide last GSN before flushing).
        coherent_window_count: *const fn (ctx: *anyopaque) usize,

        /// Flush a deferred coherent/ordered batch.  `mode` controls which
        /// inline QoS PIDs are emitted (see CoherentFlushMode).
        /// `global_last_gsn`: group-wide last GSN across all writers; 0 = per-writer.
        end_coherent_set: *const fn (ctx: *anyopaque, mode: CoherentFlushMode, resuspend: bool, publisher_gsn: ?*i64, global_last_gsn: i64) void,

        /// Destroy this writer and release its resources.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn write(
        self: ProtocolWriter,
        kind: ChangeKind,
        source_timestamp: RtpsTimestamp,
        instance_handle: InstanceHandle,
        key_hash: [16]u8,
        data: []const u8,
    ) anyerror!SequenceNumber {
        return self.vtable.write(self.ctx, kind, source_timestamp, instance_handle, key_hash, data);
    }

    pub fn addMatchedReader(self: ProtocolWriter, info: *const MatchedReaderInfo) anyerror!void {
        return self.vtable.add_matched_reader(self.ctx, info);
    }

    pub fn removeMatchedReader(self: ProtocolWriter, guid: Guid) void {
        self.vtable.remove_matched_reader(self.ctx, guid);
    }

    pub fn matchedReaderCount(self: ProtocolWriter) usize {
        return self.vtable.matched_reader_count(self.ctx);
    }

    pub fn listMatchedReaders(
        self: ProtocolWriter,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(Guid),
    ) anyerror!void {
        return self.vtable.list_matched_readers(self.ctx, alloc, out);
    }

    pub fn handleAckNack(
        self: ProtocolWriter,
        reader_guid: Guid,
        highest_sn: SequenceNumber,
        nack_set: SequenceNumberSet,
        count: i32,
        is_final: bool,
    ) void {
        self.vtable.handle_ack_nack(self.ctx, reader_guid, highest_sn, nack_set, count, is_final);
    }

    pub fn handleNackFrag(
        self: ProtocolWriter,
        reader_guid: Guid,
        writer_sn: SequenceNumber,
        frag_set: FragmentNumberSet,
        count: i32,
    ) void {
        self.vtable.handle_nack_frag(self.ctx, reader_guid, writer_sn, frag_set, count);
    }

    pub fn allAcked(self: ProtocolWriter, target_sn: SequenceNumber) bool {
        return self.vtable.all_acked(self.ctx, target_sn);
    }

    pub fn waitAllAcked(self: ProtocolWriter, target_sn: SequenceNumber, deadline_ns: ?i64) bool {
        return self.vtable.wait_all_acked(self.ctx, target_sn, deadline_ns);
    }

    pub fn cacheLen(self: ProtocolWriter) usize {
        return self.vtable.cache_len(self.ctx);
    }

    pub fn beginCoherentSet(self: ProtocolWriter, is_coherent_window: bool) void {
        self.vtable.begin_coherent_set(self.ctx, is_coherent_window);
    }

    pub fn coherentWindowCount(self: ProtocolWriter) usize {
        return self.vtable.coherent_window_count(self.ctx);
    }

    pub fn endCoherentSet(self: ProtocolWriter, mode: CoherentFlushMode, resuspend: bool, publisher_gsn: ?*i64, global_last_gsn: i64) void {
        self.vtable.end_coherent_set(self.ctx, mode, resuspend, publisher_gsn, global_last_gsn);
    }

    pub fn deinit(self: ProtocolWriter) void {
        self.vtable.deinit(self.ctx);
    }
};

/// Invoked by the protocol reader when a remote writer is matched or unmatched.
/// Carries the same MatchedWriterInfo used to create the proxy; allows the
/// DCPS DataReader to track per-writer ownership strength.
pub const WriterMatchCallback = struct {
    ctx: *anyopaque,
    on_writer_matched: *const fn (ctx: *anyopaque, info: *const MatchedWriterInfo) void,
    on_writer_unmatched: *const fn (ctx: *anyopaque, guid: Guid) void,
    /// Optional: called when a DATA or HEARTBEAT is received from the writer,
    /// indicating the writer is still alive. Used for LIVELINESS tracking.
    on_writer_alive: ?*const fn (ctx: *anyopaque, guid: Guid) void = null,
};

// ── ProtocolReader ────────────────────────────────────────────────────────────

/// Read-side protocol abstraction. DCPS DataReader holds one of these.
pub const ProtocolReader = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        /// Register the callback invoked when in-order data is ready for
        /// delivery to the application.  Replaces any previously set callback.
        set_data_callback: *const fn (ctx: *anyopaque, cb: DataCallback) void,

        /// Register the callback invoked when a remote writer is matched or
        /// unmatched.  Used by the DCPS layer for OWNERSHIP tracking.
        set_writer_match_callback: *const fn (ctx: *anyopaque, cb: WriterMatchCallback) void,

        /// SEDP matched a new remote writer. The protocol layer adds a proxy
        /// and begins accepting data from that writer.
        add_matched_writer: *const fn (ctx: *anyopaque, info: *const MatchedWriterInfo) anyerror!void,

        /// SEDP removed a previously matched remote writer.
        remove_matched_writer: *const fn (ctx: *anyopaque, guid: Guid) void,

        /// Return the number of currently matched writer proxies.
        matched_writer_count: *const fn (ctx: *anyopaque) usize,

        /// Append the GUIDs of all currently matched writer proxies to `out`.
        list_matched_writers: *const fn (
            ctx: *anyopaque,
            alloc: std.mem.Allocator,
            out: *std.ArrayListUnmanaged(Guid),
        ) anyerror!void,

        /// Called by the participant's RTPS message dispatcher when a DATA
        /// submessage arrives addressed to this reader.  `serialized_payload`
        /// is BORROWED — valid only for the duration of this call.
        /// The implementation copies it into the history cache if the writer
        /// is matched; otherwise it is a no-op.
        handle_incoming_change: *const fn (
            ctx: *anyopaque,
            writer_guid: Guid,
            sn: SequenceNumber,
            source_timestamp: RtpsTimestamp,
            key_hash: [16]u8,
            serialized_payload: []const u8,
            kind: ChangeKind,
            coherent_set_sn: ?SequenceNumber,
            group_seq_num: ?SequenceNumber,
        ) void,

        /// Called by the participant's RTPS message dispatcher when a HEARTBEAT
        /// submessage arrives. Triggers ACKNACK if the reader has gaps or the
        /// heartbeat is non-final.
        handle_heartbeat: *const fn (
            ctx: *anyopaque,
            writer_guid: Guid,
            first_sn: SequenceNumber,
            last_sn: SequenceNumber,
            count: i32,
            final: bool,
        ) void,

        /// Called when a DATA_FRAG submessage arrives. Accumulates fragments;
        /// delivers the reassembled change when all fragments have been received.
        handle_data_frag: *const fn (
            ctx: *anyopaque,
            writer_guid: Guid,
            df: DataFragSubmessage,
        ) void,

        /// Called when a HEARTBEAT_FRAG submessage arrives. Sends NACK_FRAG
        /// for any missing fragments.
        handle_heartbeat_frag: *const fn (
            ctx: *anyopaque,
            writer_guid: Guid,
            writer_sn: SequenceNumber,
            last_frag_num: u32,
            count: i32,
        ) void,

        /// Called when a GAP submessage arrives. Marks the listed SNs as
        /// irreversibly unavailable so the reader stops NACKing them.
        handle_gap: *const fn (
            ctx: *anyopaque,
            writer_guid: Guid,
            gap_start: SequenceNumber,
            gap_list: SequenceNumberSet,
        ) void,

        /// Returns true when all matched TRANSIENT_LOCAL writers have delivered their
        /// complete history up to the floor sequence number established by the first
        /// HEARTBEAT.  Writers that do not have history_expected set are always considered
        /// delivered.  Returns true immediately when no writers are matched.
        historical_delivered: *const fn (ctx: *anyopaque) bool,

        /// Destroy this reader and release its resources.
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn setDataCallback(self: ProtocolReader, cb: DataCallback) void {
        self.vtable.set_data_callback(self.ctx, cb);
    }

    pub fn setWriterMatchCallback(self: ProtocolReader, cb: WriterMatchCallback) void {
        self.vtable.set_writer_match_callback(self.ctx, cb);
    }

    pub fn addMatchedWriter(self: ProtocolReader, info: *const MatchedWriterInfo) anyerror!void {
        return self.vtable.add_matched_writer(self.ctx, info);
    }

    pub fn removeMatchedWriter(self: ProtocolReader, guid: Guid) void {
        self.vtable.remove_matched_writer(self.ctx, guid);
    }

    pub fn matchedWriterCount(self: ProtocolReader) usize {
        return self.vtable.matched_writer_count(self.ctx);
    }

    pub fn listMatchedWriters(
        self: ProtocolReader,
        alloc: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(Guid),
    ) anyerror!void {
        return self.vtable.list_matched_writers(self.ctx, alloc, out);
    }

    pub fn handleIncomingChange(
        self: ProtocolReader,
        writer_guid: Guid,
        sn: SequenceNumber,
        source_timestamp: RtpsTimestamp,
        key_hash: [16]u8,
        serialized_payload: []const u8,
        kind: ChangeKind,
        coherent_set_sn: ?SequenceNumber,
        group_seq_num: ?SequenceNumber,
    ) void {
        self.vtable.handle_incoming_change(
            self.ctx,
            writer_guid,
            sn,
            source_timestamp,
            key_hash,
            serialized_payload,
            kind,
            coherent_set_sn,
            group_seq_num,
        );
    }

    pub fn handleHeartbeat(
        self: ProtocolReader,
        writer_guid: Guid,
        first_sn: SequenceNumber,
        last_sn: SequenceNumber,
        count: i32,
        final: bool,
    ) void {
        self.vtable.handle_heartbeat(self.ctx, writer_guid, first_sn, last_sn, count, final);
    }

    pub fn handleDataFrag(
        self: ProtocolReader,
        writer_guid: Guid,
        df: DataFragSubmessage,
    ) void {
        self.vtable.handle_data_frag(self.ctx, writer_guid, df);
    }

    pub fn handleHeartbeatFrag(
        self: ProtocolReader,
        writer_guid: Guid,
        writer_sn: SequenceNumber,
        last_frag_num: u32,
        count: i32,
    ) void {
        self.vtable.handle_heartbeat_frag(self.ctx, writer_guid, writer_sn, last_frag_num, count);
    }

    pub fn handleGap(
        self: ProtocolReader,
        writer_guid: Guid,
        gap_start: SequenceNumber,
        gap_list: SequenceNumberSet,
    ) void {
        self.vtable.handle_gap(self.ctx, writer_guid, gap_start, gap_list);
    }

    pub fn historicalDelivered(self: ProtocolReader) bool {
        return self.vtable.historical_delivered(self.ctx);
    }

    pub fn deinit(self: ProtocolReader) void {
        self.vtable.deinit(self.ctx);
    }
};
