//! DataReaderImpl — DCPS DataReader implementation.
//!
//! DataReaderImpl owns a ProtocolReader (backed by a StatefulReader / RTPS).
//! Incoming CDR samples arrive via the DataCallback from the RTPS layer and
//! are enqueued in `pending`.  The typed takeRaw() method dequeues them;
//! it is called by the zidl-generated typed wrapper.
//!
//! Read path:
//!   transport → StatefulReader.handleData() → DataCallback.on_data()
//!             → DataReaderImpl.onDataCb() → pending queue
//!
//! Take path:
//!   zidl wrapper → takeRaw() → dequeue from pending

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const nil = @import("nil.zig");
const proto = @import("../protocol/interface.zig");
const history_mod = @import("../rtps/history.zig");
const filter_mod = @import("filter.zig");
const topic_mod = @import("topic.zig");
const waitset = @import("waitset.zig");
const writer_mod = @import("writer.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const time_mod = @import("../util/time.zig");
const c_abi_handle = @import("../util/c_abi_handle.zig");
const ListenerBox = @import("../util/listener_box.zig").ListenerBox;
const listener_fallback = @import("../util/listener_fallback.zig");
const subscriber_mod = @import("subscriber.zig");
const EntityQuiesce = @import("../util/entity_quiesce.zig").EntityQuiesce;
const extensions_mod = @import("../c_abi/extensions.zig");

const Guid = proto.Guid;

/// CFT filter state held on the DataReaderImpl.
/// Non-null only when the reader was created from a ContentFilteredTopic and a
/// get_field function is available for this type.
pub const CftFilterState = struct {
    cft_ptr: *topic_mod.ContentFilteredTopicImpl,
    get_field_fn: filter_mod.CdrFieldGetter,

    pub fn matches(self: *const CftFilterState, payload: []const u8) bool {
        var pool = filter_mod.ScratchPool{};
        var ctx = FieldCtx{ .payload = payload, .get_fn = self.get_field_fn, .pool = &pool };
        const accessor = filter_mod.FieldAccessor{
            .ctx = &ctx,
            .get = FieldCtx.get,
        };
        return self.cft_ptr.matchSample(accessor);
    }

    const FieldCtx = struct {
        payload: []const u8,
        get_fn: filter_mod.CdrFieldGetter,
        pool: *filter_mod.ScratchPool,

        fn get(ctx: *anyopaque, field: []const u8) ?filter_mod.FilterValue {
            const self: *const FieldCtx = @ptrCast(@alignCast(ctx));
            return self.get_fn.get(self.payload, field, self.pool.nextSlot());
        }
    };
};

/// Per-writer liveliness tracking entry.
const WriterLivelinessEntry = struct {
    lease_ns: i64, // 0 = infinite (no expiry)
    last_alive_ns: i64,
    is_alive: bool,
};

fn durationIsActive(d: DDS.Duration_t) bool {
    if (d.sec == 0 and d.nanosec == 0) return false;
    if (d.sec == DDS.DURATION_INFINITE_SEC and d.nanosec == DDS.DURATION_INFINITE_NSEC) return false;
    return true;
}

/// A raw serialized sample waiting in the queue.
pub const PendingChange = struct {
    /// Full CDR payload (4-byte encap header + CDR bytes).  Owned by this struct.
    /// Empty for NOT_ALIVE_DISPOSED / NOT_ALIVE_UNREGISTERED changes.
    data: []u8,
    /// Allocator used to free `data`.
    alloc: std.mem.Allocator,
    /// DDS sample metadata stamped at enqueue time.
    info: DDS.SampleInfo,
    /// Per-publisher group sequence number from PID_GROUP_SEQ_NUM inline QoS.
    /// Used to sort samples in ordered GROUP_PRESENTATION access windows.
    group_seq_num: ?i64 = null,
    /// Wall-clock nanosecond timestamp after which this sample is expired (LIFESPAN QoS).
    /// Null means no expiry (infinite lifespan or NOT_ALIVE change).
    expiry_ns: ?i64 = null,

    pub fn deinit(self: PendingChange) void {
        self.alloc.free(self.data);
    }
};

/// In-progress coherent set accumulator for one writer (keyed by writer GUID in
/// `coherent_wip`).  Tracks the coherent_set_sn that all buffered samples share
/// so that a CS-value transition can be detected and the previous set committed.
pub const CoherentWipEntry = struct {
    /// coherent_set_sn of the samples currently buffered (CS = first SN of the set,
    /// per RTI Connext convention).
    cs: history_mod.SequenceNumber,
    /// Highest RTPS sequence number received into this WIP so far.
    highest_sn: history_mod.SequenceNumber = 0,
    /// Minimum last_sn seen from any HEARTBEAT while this WIP is non-empty.
    /// When non-null, onDataCb flushes as soon as highest_sn >= flush_target_sn.
    /// Guards against the race where the HB arrives before the last DATA packet
    /// and subsequent non-coherent writes advance cache.maxSn() past the coherent
    /// set end — without this field, no future HB ever satisfies the flush condition.
    flush_target_sn: ?history_mod.SequenceNumber = null,
    samples: std.ArrayListUnmanaged(PendingChange) = .empty,
};

/// Ownership by the caller of data returned from takeRaw().
pub const TakenSample = struct {
    /// Serialized CDR payload; caller must free with the reader's allocator.
    /// Empty slice for NOT_ALIVE_* changes (check info.valid_data).
    data: []u8,
    info: DDS.SampleInfo,
};

/// Per-instance tracking used to compute view_state and get_key_value.
const InstanceEntry = struct {
    instance_state: DDS.InstanceStateKind,
    /// Full CDR payload of the first alive sample for this instance.
    /// Used by getKeyValueRaw. Null until the first alive sample arrives.
    key_cdr: ?[]u8 = null,
    /// Number of times this instance has become ALIVE after being disposed / after
    /// having no writers, respectively (DDS spec §2.2.2.5.4). Stamped onto each
    /// sample's SampleInfo at receipt time.
    disposed_generation_count: i32 = 0,
    no_writers_generation_count: i32 = 0,
};

fn matchesSample(
    pc: PendingChange,
    sample_mask: DDS.SampleStateMask,
    view_mask: DDS.ViewStateMask,
    instance_mask: DDS.InstanceStateMask,
    maybe_ih: ?DDS.InstanceHandle_t,
) bool {
    if (pc.info.sample_state & sample_mask == 0) return false;
    if (pc.info.view_state & view_mask == 0) return false;
    if (pc.info.instance_state & instance_mask == 0) return false;
    if (maybe_ih) |ih| if (pc.info.instance_handle != ih) return false;
    return true;
}

fn matchesQuery(
    pc: PendingChange,
    maybe_qc: ?*const waitset.QueryConditionImpl,
    get_field_fn: ?filter_mod.CdrFieldGetter,
) bool {
    const qc = maybe_qc orelse return true;
    const gff = get_field_fn orelse return true;
    return qc.matchSample(pc.data, gff);
}

pub const DataReaderImpl = struct {
    alloc: std.mem.Allocator,
    topic_desc: DDS.TopicDescription,
    subscriber: DDS.Subscriber,
    proto_reader: proto.ProtocolReader,
    qos: DDS.DataReaderQos,
    listener_box: *ListenerBox(DDS.DataReaderListener),
    /// Guards `listener_box` swaps/acquires only — never held across a
    /// dispatch or any other call, so it can never participate in a
    /// deadlock with `mu` or any other lock (see listener_box.zig).
    listener_mu: Mutex = .{},
    /// Guards this entity's own lifetime against a background-thread
    /// callback (RTPS receive, timer, discovery) racing `deinit()` — see
    /// entity_quiesce.zig.
    quiesce: EntityQuiesce = .{},
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,

    /// Cumulative count of incompatible-QoS events; incompat_total_change/
    /// incompat_last_policy are guarded by `mu`. incompat_total itself is
    /// additionally polled lock-free by tests waiting for the event to fire
    /// (see loopback_test.zig) -- an atomic (rather than plain i32) makes
    /// that unlocked cross-thread read well-defined instead of a data race
    /// (confirmed via TSan against notifyIncompatibleQos's locked writer).
    incompat_total: std.atomic.Value(i32) = .init(0),
    incompat_total_change: i32 = 0,
    incompat_last_policy: i32 = 0,

    /// SubscriptionMatched status counters. Guarded by `mu`.
    sub_matched_total: i32 = 0,
    sub_matched_total_change: i32 = 0,
    sub_matched_current: i32 = 0,
    sub_matched_current_change: i32 = 0,
    sub_matched_last_handle: DDS.InstanceHandle_t = 0,

    /// SampleRejected status counters. Guarded by `mu`.
    sample_rejected_total: i32 = 0,
    sample_rejected_total_change: i32 = 0,
    sample_rejected_last_reason: DDS.SampleRejectedStatusKind = .NOT_REJECTED,
    sample_rejected_last_handle: DDS.InstanceHandle_t = 0,

    /// Cumulative count of requested-deadline-missed events; written from
    /// participant.checkTimers() (participant.mu held).
    deadline_missed_total: i32 = 0,
    deadline_missed_total_change: i32 = 0,

    /// Clock used for deadline interval timers.
    timer_clock: time_mod.Clock,

    /// Monotonic timestamp of the last sample received; used by DEADLINE checks.
    /// Initialized to creation time so the first deadline window starts at entity creation.
    last_received_ns: std.atomic.Value(i64),

    /// WaitSet notification callbacks registered by attached ReadConditions.
    /// Guarded by `mu`.
    data_notifiers: std.ArrayListUnmanaged(waitset.DataNotifyFn),

    /// Every ReadCondition/QueryCondition created against this reader that
    /// hasn't been explicitly deleted via delete_readcondition() yet.
    /// Guarded by `mu`. Torn down (each condition's real deinit(), which
    /// detaches it from any attached WaitSet) in reallyDeinit() so deleting
    /// the reader without deleting its conditions first is safe rather than
    /// leaking them or leaving a WaitSet with a dangling entry.
    read_conditions: std.ArrayListUnmanaged(DDS.Condition),

    /// Pending incoming samples; guarded by `mu`.
    pending: std.ArrayListUnmanaged(PendingChange),
    /// Working buffer for the currently-receiving coherent set.
    /// Samples are appended here as they arrive. When the end marker is received
    /// Keyed by writer GUID so that concurrent coherent sets from different writers
    /// accumulate independently and commit only when each writer's own set is complete.
    coherent_wip: std.AutoHashMapUnmanaged(Guid, CoherentWipEntry),
    /// Queue of complete coherent sets awaiting delivery via begin_access().
    /// Each element is one complete set (filled when its end marker arrives).
    /// commitCoherentPendingLocked() pops ONLY the first entry per call so that
    /// each begin_access/end_access cycle exposes exactly one coherent set,
    /// even when multiple sets accumulated during a late-join history replay.
    coherent_committed: std.ArrayListUnmanaged(std.ArrayListUnmanaged(PendingChange)),
    /// True when `coherent_committed` contains at least one complete set.
    coherent_committed_ready: bool,
    /// Set of writer GUIDs that have sent at least one DATA sample with PID_COHERENT_SET
    /// and are still matched.  Entries are added on first coherent sample from a writer
    /// and removed in onWriterUnmatchedCb.  Non-empty means "at least one currently-matched
    /// writer participates in coherent sets," used by Subscriber.begin_access to gate
    /// commits: when this set is non-empty and pending is empty, a coherent set may be
    /// about to arrive (sequential vtEndCoherent timing).  Cleared on writer departure so
    /// a stale flag never permanently blocks begin_access.  Guarded by `mu`.
    coherent_writer_guids: std.AutoHashMapUnmanaged(Guid, void) = .empty,
    /// Writers known to use a Connext-style zero-payload alive DATA as end-of-set marker
    /// (§9.6.4.2 Table 9.22 Example 3).  Once a writer sends its first EOC packet, it is
    /// added here and HB-based WIP commits are suppressed for that writer — EOC is the
    /// authoritative flush trigger, and intermediate HBs would otherwise cause premature
    /// partial commits.  Entries removed on writer departure.  Guarded by `mu`.
    coherent_eoc_writers: std.AutoHashMapUnmanaged(Guid, void) = .empty,
    /// Timestamp (ns) when the most recent coherent WIP entry was created for any writer.
    /// Reset when a new entry is added; used by Subscriber.begin_access to detect idle
    /// coherent writers that never send a new set (preventing a permanent gate stall).
    last_coherent_wip_start_ns: i64 = 0,
    mu: Mutex,

    /// Presentation QoS from the owning Subscriber; set once after init.
    subscriber_presentation: DDS.PresentationQosPolicy = .{},

    /// ContentFilteredTopic this reader was created against, if any. Set once
    /// by the subscriber before the first refreshGetFieldFn call and never
    /// mutated after -- unlike cft_filter/get_field_fn below, this is safe to
    /// read without `mu`. Kept separate from cft_filter so that losing (and
    /// later regaining) a get_field getter doesn't lose the CFT association:
    /// refreshGetFieldFn derives cft_filter from this pointer every time
    /// rather than mutating a previously-built CftFilterState in place.
    cft_ptr: ?*topic_mod.ContentFilteredTopicImpl = null,

    /// ContentFilteredTopic filter; null when no CFT or no get_field fn
    /// currently registered. Populated/refreshed exclusively by
    /// refreshGetFieldFn, under `mu` -- read under `mu` everywhere else
    /// (on_receive's CFT check, readFiltered/takeFiltered's QueryCondition
    /// evaluation).
    cft_filter: ?CftFilterState = null,

    /// Field accessor for QueryCondition evaluation at read/take time.
    /// Set from TypeSupport.get_field when available; null otherwise.
    /// Populated/refreshed exclusively by refreshGetFieldFn, under `mu`.
    get_field_fn: ?filter_mod.CdrFieldGetter = null,

    /// SampleLost status counters. Guarded by `mu`.
    sample_lost_total: i32 = 0,
    sample_lost_total_change: i32 = 0,

    /// LivelinessChanged status counters. Guarded by `mu`.
    liveliness_alive_count: i32 = 0,
    liveliness_alive_count_change: i32 = 0,
    liveliness_not_alive_count: i32 = 0,
    liveliness_not_alive_count_change: i32 = 0,
    liveliness_last_handle: DDS.InstanceHandle_t = 0,

    /// Per-writer liveliness state for writers with a finite lease.
    /// Guarded by `mu`.
    writer_liveliness: std.AutoHashMapUnmanaged(Guid, WriterLivelinessEntry) = .empty,

    /// Per-writer lifespan in nanoseconds (0 = infinite). Guarded by `mu`.
    writer_lifespans: std.AutoHashMapUnmanaged(Guid, i64) = .empty,

    /// Set by Subscriber.begin_access() after sorting pending for ordered access.
    /// takeRaw() returns null once this many items have been consumed, so that
    /// samples appended by the inbound network path after the sort are not served
    /// until end_access() clears this field (null = no limit).  Guarded by `mu`.
    ordered_access_watermark: ?usize = null,

    // ── OWNERSHIP tracking ────────────────────────────────────────────────────
    // Only used when qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS.
    // Guarded by `mu`.

    /// Ownership strength of each matched writer.
    writer_strengths: std.AutoHashMapUnmanaged(Guid, i32) = .empty,
    /// Per-instance ownership: maps instance handle → {guid, strength} of the
    /// current owner.  Ownership is per-instance: two writers with different
    /// key values (different instances) are each the sole owner of their own
    /// instance, even if one has lower strength than the other.
    owner_map: std.AutoHashMapUnmanaged(DDS.InstanceHandle_t, OwnerEntry) = .empty,

    /// Per-writer set of instance handles written to via alive changes.
    /// Guarded by `mu`. Used in onWriterUnmatchedCb to synthesize NOT_ALIVE_NO_WRITERS
    /// when a writer disappears without an explicit unregister.
    writer_instances: std.AutoHashMapUnmanaged(Guid, std.AutoHashMapUnmanaged(DDS.InstanceHandle_t, void)) = .empty,

    // ── TIME_BASED_FILTER tracking ────────────────────────────────────────────
    // Guarded by `mu`. Per-instance: each instance independently tracks the
    // source timestamp of its last delivered sample.

    /// Source timestamp (ns) of the last sample that passed the TBF window,
    /// keyed by instance handle. Absent = no sample delivered yet for that instance.
    tbf_map: std.AutoHashMapUnmanaged(DDS.InstanceHandle_t, i64) = .empty,

    // ── Instance lifecycle tracking ───────────────────────────────────────────
    // Guarded by `mu`.

    /// Tracks the current instance_state for each known instance handle.
    /// Used to determine view_state (NEW_VIEW vs NOT_NEW_VIEW) at enqueue time.
    seen_instances: std.AutoHashMapUnmanaged(DDS.InstanceHandle_t, InstanceEntry),

    /// One box for the whole object, shared across every interface view
    /// (DataReader, Entity, and ZZDDS.DataReader — see src/c_abi/extensions.zig)
    /// — see `views` below and zidl/docs/roadmap.md "Binding design review:
    /// decision".
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const OwnerEntry = struct { guid: Guid, strength: i32 };
    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        topic_desc: DDS.TopicDescription,
        subscriber: DDS.Subscriber,
        proto_reader: proto.ProtocolReader,
        qos: DDS.DataReaderQos,
        listener: DDS.DataReaderListener,
        mask: DDS.StatusMask,
        instance_handle: DDS.InstanceHandle_t,
        timer_clock: time_mod.Clock,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .topic_desc = topic_desc,
            .subscriber = subscriber,
            .proto_reader = proto_reader,
            .qos = .{},
            .listener_box = undefined,
            .listener_mask = mask,
            .instance_handle = instance_handle,
            .status_changes = 0,
            .status_cond = null,
            .data_notifiers = .empty,
            .read_conditions = .empty,
            .pending = .empty,
            .coherent_wip = .{},
            .coherent_committed = .empty,
            .coherent_committed_ready = false,
            .mu = .{},
            .timer_clock = timer_clock,
            .last_received_ns = .init(timer_clock.nowNs()),
            .seen_instances = .empty,
        };
        errdefer alloc.destroy(self);
        self.listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, listener);
        errdefer alloc.destroy(self.listener_box);
        self.qos = try qos.clone(alloc);
        errdefer self.qos.deinit(alloc);
        // Register delivery callback with the RTPS layer.
        proto_reader.setDataCallback(.{
            .ctx = self,
            .on_data = onDataCb,
            .on_sample_lost = onSampleLostCb,
            .on_heartbeat = onHeartbeatCb,
            .on_eoc = onEocCb,
        });
        // Register writer-match callback for OWNERSHIP and LIVELINESS tracking.
        proto_reader.setWriterMatchCallback(.{
            .ctx = self,
            .on_writer_matched = onWriterMatchedCb,
            .on_writer_unmatched = onWriterUnmatchedCb,
            .on_writer_alive = onWriterAliveCb,
        });
        // Wire up StatusCondition.
        const sc = try waitset.StatusConditionImpl.init(
            alloc,
            self.toEntity(),
            getStatusFn,
        );
        self.status_cond = sc;
        return self;
    }

    /// Drops this entity's own quiesce reference; the real teardown
    /// (`reallyDeinit`) runs immediately unless a background callback is
    /// genuinely in flight, in which case that callback's own release runs
    /// it instead once it finishes (see entity_quiesce.zig).
    pub fn deinit(self: *Self) void {
        self.quiesce.beginTeardown(self, reallyDeinit);
    }

    fn reallyDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.listener_box.releaseRef(self.alloc);
        if (self.status_cond) |sc| sc.deinit();
        self.c_abi.free(self.alloc);
        // Tear down any ReadCondition/QueryCondition the app never explicitly
        // deleted via delete_readcondition(). Each condition's own teardown
        // detaches it from any WaitSet that still has it attached, removes
        // its data_notifiers registration, and calls back into
        // removeReadCondition() to remove itself from read_conditions — so
        // this must run before data_notifiers.deinit() and before `self` is
        // freed. Take ownership of the list and reset the field to .empty
        // first: mutating (swapRemove) the very list a `for` loop is
        // iterating over would skip or double-visit entries. Locked: this
        // reader's own quiesce reference is already down to zero by the time
        // reallyDeinit runs (see vtCreateReadCondition/vtCreateQueryCondition,
        // which hold a reference across their own tracking append, and
        // ReadConditionImpl.deinit()/QueryConditionImpl.deinit() in
        // waitset.zig, which now do the same across delete_readcondition()
        // or a direct .deinit() call), but removeReadCondition() only locks
        // this same mu, not this reader's quiesce -- so this snapshot must
        // lock it too, or the two could still corrupt read_conditions's
        // ArrayList fields concurrently.
        self.mu.lock();
        var conditions_to_free = self.read_conditions;
        self.read_conditions = .empty;
        self.mu.unlock();
        // Calls …AssumeReaderQuiescing() directly, not the public deinit():
        // this reader's quiesce reference is already down to zero here (see
        // above), so a fresh acquire would always fail, silently skipping
        // every condition's real teardown. `cond.ptr` is always a
        // *ReadConditionImpl -- QueryConditionImpl.toCondition() returns a
        // view backed by its own embedded `rc` (see owner_qc's doc comment)
        // -- so owner_qc tells us which concrete deinitAssumeReaderQuiescing
        // actually owns the allocation.
        for (conditions_to_free.items) |cond| {
            const rc: *waitset.ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
            if (rc.owner_qc) |qc| {
                qc.deinitAssumeReaderQuiescing();
            } else {
                rc.deinitAssumeReaderQuiescing();
            }
        }
        conditions_to_free.deinit(self.alloc);
        self.data_notifiers.deinit(self.alloc);
        // Drain pending queues (including coherent buffers).
        for (self.pending.items) |p| p.deinit();
        self.pending.deinit(self.alloc);
        var wip_it = self.coherent_wip.valueIterator();
        while (wip_it.next()) |v| {
            for (v.samples.items) |p| p.deinit();
            v.samples.deinit(self.alloc);
        }
        self.coherent_wip.deinit(self.alloc);
        self.coherent_writer_guids.deinit(self.alloc);
        self.coherent_eoc_writers.deinit(self.alloc);
        for (self.coherent_committed.items) |*s| {
            for (s.items) |p| p.deinit();
            s.deinit(self.alloc);
        }
        self.coherent_committed.deinit(self.alloc);
        self.tbf_map.deinit(self.alloc);
        self.writer_strengths.deinit(self.alloc);
        self.writer_liveliness.deinit(self.alloc);
        self.writer_lifespans.deinit(self.alloc);
        self.owner_map.deinit(self.alloc);
        {
            var wi_it = self.writer_instances.valueIterator();
            while (wi_it.next()) |inner| inner.deinit(self.alloc);
        }
        self.writer_instances.deinit(self.alloc);
        {
            var si_it = self.seen_instances.valueIterator();
            while (si_it.next()) |entry| {
                if (entry.key_cdr) |kc| self.alloc.free(kc);
            }
        }
        self.seen_instances.deinit(self.alloc);
        self.qos.deinit(self.alloc);
        // NOTE: proto_reader lifecycle is owned by the participant (via
        // subDestroyProtoReader callback), not by DataReaderImpl.
        // The participant's destroy_proto_reader callback frees it.
        self.alloc.destroy(self);
    }

    /// Determine view_state and instance_state for an incoming change.
    /// Must be called with `mu` held.
    fn determineStatesLocked(
        self: *Self,
        ih: DDS.InstanceHandle_t,
        kind: history_mod.ChangeKind,
    ) struct {
        view: DDS.ViewStateKind,
        instance_state: DDS.InstanceStateKind,
        disposed_generation_count: i32,
        no_writers_generation_count: i32,
    } {
        const new_state: DDS.InstanceStateKind = switch (kind) {
            .alive => DDS.ALIVE_INSTANCE_STATE,
            .not_alive_disposed => DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE,
            .not_alive_unregistered => DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE,
        };
        if (self.seen_instances.getPtr(ih)) |entry| {
            // Resurrection: instance was not alive but a new alive sample arrived.
            const was_not_alive = entry.instance_state != DDS.ALIVE_INSTANCE_STATE;
            const view: DDS.ViewStateKind = if (was_not_alive and kind == .alive)
                DDS.NEW_VIEW_STATE
            else
                DDS.NOT_NEW_VIEW_STATE;
            if (was_not_alive and kind == .alive) {
                if (entry.instance_state == DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE) {
                    entry.disposed_generation_count += 1;
                } else if (entry.instance_state == DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE) {
                    entry.no_writers_generation_count += 1;
                }
            }
            entry.instance_state = new_state;
            return .{
                .view = view,
                .instance_state = new_state,
                .disposed_generation_count = entry.disposed_generation_count,
                .no_writers_generation_count = entry.no_writers_generation_count,
            };
        } else {
            self.seen_instances.put(self.alloc, ih, .{ .instance_state = new_state }) catch {};
            return .{
                .view = DDS.NEW_VIEW_STATE,
                .instance_state = new_state,
                .disposed_generation_count = 0,
                .no_writers_generation_count = 0,
            };
        }
    }

    /// Store `data` as the key CDR for `ih` if not already set.
    /// Must be called with `mu` held.
    fn storeKeyIfNeededLocked(self: *Self, ih: DDS.InstanceHandle_t, data: []const u8) void {
        if (self.seen_instances.getPtr(ih)) |entry| {
            if (entry.key_cdr == null) {
                entry.key_cdr = self.alloc.dupe(u8, data) catch null;
            }
        }
    }

    /// Inject a CDR sample directly, bypassing the RTPS layer.
    /// Used by the built-in subscriber to push discovery-sourced samples.
    /// `cdr` is borrowed; it is copied internally.
    pub fn pushCdr(self: *Self, cdr: []const u8) void {
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        const copy = self.alloc.dupe(u8, cdr) catch return;
        self.mu.lock();
        const ih = writer_mod.keyHashToHandle(std.mem.zeroes([16]u8));
        const states = self.determineStatesLocked(ih, .alive);
        const info = DDS.SampleInfo{
            .sample_state = DDS.NOT_READ_SAMPLE_STATE,
            .view_state = states.view,
            .instance_state = states.instance_state,
            .instance_handle = ih,
            .valid_data = true,
            .disposed_generation_count = states.disposed_generation_count,
            .no_writers_generation_count = states.no_writers_generation_count,
        };
        const pc = PendingChange{ .data = copy, .alloc = self.alloc, .info = info };
        const max = self.qos.resource_limits.max_samples;
        if (max > 0 and self.pending.items.len >= @as(usize, @intCast(max))) {
            self.mu.unlock();
            self.alloc.free(copy);
            return;
        }
        self.pending.append(self.alloc, pc) catch {
            self.mu.unlock();
            self.alloc.free(copy);
            return;
        };
        self.status_changes |= DDS.DATA_AVAILABLE_STATUS;
        for (self.data_notifiers.items) |n| n.on_data(n.ctx);
        self.mu.unlock();
        self.last_received_ns.store(self.timer_clock.nowNs(), .monotonic);
        if (self.status_cond) |sc| sc.notifyWakeup();
        _ = self.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, vtable.get_c_abi_handle(self), .{});
    }

    // ── Data delivery ─────────────────────────────────────────────────────────

    /// Record that `guid` has published an alive sample for instance `ih`.
    /// Must be called with `mu` held.  Used by onWriterUnmatchedCb.
    fn trackWriterInstanceLocked(self: *Self, guid: Guid, ih: DDS.InstanceHandle_t) void {
        const gop = self.writer_instances.getOrPut(self.alloc, guid) catch return;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.put(self.alloc, ih, {}) catch {};
    }

    /// Called from the RTPS receive thread when a new sample arrives.
    /// Matches the DataCallback.on_eoc function pointer signature.
    /// Called by reader_sm when a Connext-style zero-payload alive DATA arrives (no
    /// PID_COHERENT_SET) — the end-of-coherent-set signal.  Flushes the coherent WIP
    /// for this writer without adding a sample to the pending queue.
    fn onEocCb(ctx: *anyopaque, change: *const history_mod.CacheChange) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        if (!self.subscriber_presentation.coherent_access) return;
        self.mu.lock();
        // Remember this writer uses EOC so onHeartbeatCb stops issuing premature commits.
        self.coherent_eoc_writers.put(self.alloc, change.writer_guid, {}) catch {};
        const committed = if (self.coherent_wip.fetchRemove(change.writer_guid)) |kv|
            self.commitCoherentWipSamplesLocked(kv.value.samples)
        else
            false;
        self.mu.unlock();
        if (committed) {
            if (self.status_cond) |sc| sc.notifyWakeup();
            _ = self.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, vtable.get_c_abi_handle(self), .{});
        }
    }

    /// Matches the DataCallback.on_data function pointer signature.
    /// Must not block; must not call back into the ProtocolReader.
    fn onDataCb(ctx: *anyopaque, change: *const history_mod.CacheChange) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);

        const copy = self.alloc.dupe(u8, change.data) catch return;
        self.mu.lock();

        // Compute instance handle first — needed by both ownership and resource-limit checks.
        const ih = writer_mod.keyHashToHandle(change.key_hash);

        // Track writer→instance before any filter so that ownership-dropped writes
        // still mark the instance as covered (prevents spurious NOT_ALIVE_NO_WRITERS
        // when the owner leaves but another writer is still publishing to the instance).
        if (change.kind == .alive) trackWriterInstanceLocked(self, change.writer_guid, ih);

        // OWNERSHIP: per-instance exclusive ownership check.
        // A writer owns an instance if it is the highest-strength writer that has
        // written to that instance.  Different instances are independently owned,
        // so a lower-strength writer that publishes a distinct instance is never
        // blocked by a higher-strength writer on a different instance.
        if (self.qos.ownership.kind == .EXCLUSIVE_OWNERSHIP_QOS) {
            const incoming_strength = self.writer_strengths.get(change.writer_guid) orelse 0;
            const accepted = blk: {
                if (self.owner_map.getPtr(ih)) |entry| {
                    if (entry.guid.eql(change.writer_guid)) {
                        // Same writer — always accept; refresh cached strength.
                        entry.strength = incoming_strength;
                        break :blk true;
                    } else if (incoming_strength > entry.strength) {
                        // Higher strength — take ownership of this instance.
                        entry.* = .{ .guid = change.writer_guid, .strength = incoming_strength };
                        break :blk true;
                    } else {
                        // Lower or equal strength from a different writer — drop.
                        break :blk false;
                    }
                } else {
                    // No owner yet for this instance — first writer claims it.
                    self.owner_map.put(self.alloc, ih, .{
                        .guid = change.writer_guid,
                        .strength = incoming_strength,
                    }) catch {};
                    break :blk true;
                }
            };
            if (!accepted) {
                self.mu.unlock();
                self.alloc.free(copy);
                return;
            }
        }

        // TIME_BASED_FILTER: suppress alive samples whose source timestamp is within
        // minimum_separation of the last accepted sample for this instance.
        // Lifecycle changes (dispose/unregister) bypass TBF: suppressing them would
        // leave instance state stuck as ALIVE and leak tbf_map/owner_map entries.
        // tbf_map is updated only after a successful append (below), so a sample
        // rejected by CFT, resource-limits, or OOM does not advance the window.
        const min_sep = self.qos.time_based_filter.minimum_separation;
        const tbf_active = change.kind == .alive and (min_sep.sec != 0 or min_sep.nanosec != 0);
        const tbf_src_ns: i64 = if (tbf_active) change.source_timestamp.toTime().toNs() else 0;
        if (tbf_active) {
            const sep_ns = @as(i64, min_sep.sec) * std.time.ns_per_s + @as(i64, min_sep.nanosec);
            if (self.tbf_map.get(ih)) |last| {
                if (tbf_src_ns - last < sep_ns) {
                    self.mu.unlock();
                    self.alloc.free(copy);
                    return;
                }
            }
        }

        // CONTENT_FILTER: only alive samples are filtered. Lifecycle changes
        // (dispose/unregister) must pass through regardless of the expression so
        // that the subscriber's instance state machine stays consistent and the
        // per-instance tbf_map/owner_map cleanup below is reached.
        if (self.cft_filter) |*cft| {
            if (change.kind == .alive and !cft.matches(change.data)) {
                self.mu.unlock();
                self.alloc.free(copy);
                return;
            }
        }

        // COHERENT SET BUFFERING: when the subscriber has coherent_access and the
        // change carries PID_COHERENT_SET, buffer until the end marker arrives.
        // "End marker" = the sample whose own SN equals the set's declared last SN.
        //
        // GROUP_PRESENTATION: do NOT auto-commit; mark the set complete and let
        // Subscriber.begin_access() commit all readers atomically (cross-reader
        // coordination avoids a race where the subscriber reads between individual
        // reader commits).
        // INSTANCE/TOPIC: auto-commit when the end marker arrives (per-reader
        // coordination is sufficient).
        if (self.subscriber_presentation.coherent_access and
            change.coherent_set_sn != null)
        {
            self.coherent_writer_guids.put(self.alloc, change.writer_guid, {}) catch {};
            const states = self.determineStatesLocked(ih, change.kind);
            if (change.kind == .alive) self.storeKeyIfNeededLocked(ih, copy);
            const src_time = change.source_timestamp.toTime();
            const coh_expiry: ?i64 = if (change.kind == .alive)
                // Prefer this sample's own PID_LIFESPAN inline QoS (RTPS §8.7.2 Table
                // 8.85) over the SEDP-discovered default — inline QoS takes effect
                // immediately and reflects the writer's QoS at the time this sample
                // was written, which may differ from what discovery last announced.
                if (change.inline_lifespan_ns orelse self.writer_lifespans.get(change.writer_guid)) |ls_ns|
                    src_time.toNs() + ls_ns
                else
                    null
            else
                null;
            const pc = PendingChange{
                .data = copy,
                .alloc = self.alloc,
                .info = .{
                    .sample_state = DDS.NOT_READ_SAMPLE_STATE,
                    .view_state = states.view,
                    .instance_state = states.instance_state,
                    .source_timestamp = .{ .sec = src_time.sec, .nanosec = src_time.nanosec },
                    .instance_handle = ih,
                    .publication_handle = writer_mod.guidToHandle(change.writer_guid),
                    .valid_data = change.kind == .alive,
                    .disposed_generation_count = states.disposed_generation_count,
                    .no_writers_generation_count = states.no_writers_generation_count,
                },
                .group_seq_num = change.group_seq_num,
                .expiry_ns = coh_expiry,
            };
            if (tbf_active) self.tbf_map.put(self.alloc, ih, tbf_src_ns) catch {};
            if (change.kind != .alive) {
                _ = self.tbf_map.remove(ih);
                _ = self.owner_map.remove(ih);
            }
            const new_cs = change.coherent_set_sn.?;
            const gop = self.coherent_wip.getOrPut(self.alloc, change.writer_guid) catch {
                self.mu.unlock();
                self.alloc.free(copy);
                return;
            };
            // CS transition: the incoming sample belongs to a new coherent set.
            // Commit the previous WIP before starting the new one.
            var transition_committed = false;
            if (gop.found_existing and gop.value_ptr.cs != new_cs) {
                var prev = gop.value_ptr.samples;
                // If a prior HB told us the set had more samples than we received
                // (flush_target_sn set but not yet reached), the previous set is
                // incomplete.  Delivering a partial coherent set violates the coherency
                // contract, so discard it rather than commit.
                const prev_complete = gop.value_ptr.flush_target_sn == null or
                    gop.value_ptr.highest_sn >= gop.value_ptr.flush_target_sn.?;
                gop.value_ptr.samples = .empty;
                gop.value_ptr.cs = new_cs;
                gop.value_ptr.highest_sn = 0;
                gop.value_ptr.flush_target_sn = null;
                if (prev_complete) {
                    transition_committed = self.commitCoherentWipSamplesLocked(prev);
                } else {
                    for (prev.items) |stale| stale.deinit();
                    prev.deinit(self.alloc);
                }
                self.last_coherent_wip_start_ns = time_mod.nanoTimestamp();
            } else if (!gop.found_existing) {
                gop.value_ptr.* = .{ .cs = new_cs };
                self.last_coherent_wip_start_ns = time_mod.nanoTimestamp();
            }
            gop.value_ptr.samples.append(self.alloc, pc) catch {
                self.mu.unlock();
                self.alloc.free(copy);
                return;
            };
            if (change.sequence_number > gop.value_ptr.highest_sn)
                gop.value_ptr.highest_sn = change.sequence_number;
            // If a prior HB deferred the flush (highest_sn was < last_sn at HB time),
            // check whether this DATA packet completes the set.
            // Skip for EOC writers: their set ends only when the EOC packet arrives.
            const data_committed = if (gop.value_ptr.flush_target_sn) |target|
                if (self.coherent_eoc_writers.get(change.writer_guid) == null and
                    gop.value_ptr.highest_sn >= target)
                blk2: {
                    const kv2 = self.coherent_wip.fetchRemove(change.writer_guid).?;
                    break :blk2 self.commitCoherentWipSamplesLocked(kv2.value.samples);
                } else false
            else
                false;
            self.mu.unlock();
            self.last_received_ns.store(self.timer_clock.nowNs(), .monotonic);
            if (transition_committed or data_committed) {
                if (self.status_cond) |sc| sc.notifyWakeup();
                _ = self.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, vtable.get_c_abi_handle(self), .{});
            }
            return;
        }

        // Non-coherent DATA with a pending coherent WIP for this writer: any DATA
        // without PID_COHERENT_SET signals end-of-coherent-set (RTPS §9.6.4.2).
        // Flush the WIP now; the notification fires at the end of this path.
        if (self.subscriber_presentation.coherent_access) {
            if (self.coherent_wip.fetchRemove(change.writer_guid)) |kv| {
                _ = self.commitCoherentWipSamplesLocked(kv.value.samples);
            }
        }

        // KEEP_LAST: if history depth is limited, evict the oldest pending sample
        // for this instance when the per-instance count reaches depth.  This is a
        // silent replacement, not a rejection — on_sample_rejected is NOT fired.
        if (self.qos.history.kind == .KEEP_LAST_HISTORY_QOS) {
            const depth: usize = @intCast(@max(1, self.qos.history.depth));
            var instance_count: usize = 0;
            for (self.pending.items) |pc| {
                if (pc.info.instance_handle == ih) instance_count += 1;
            }
            if (instance_count >= depth) {
                // Remove oldest pending sample for this instance.
                var i: usize = 0;
                while (i < self.pending.items.len) : (i += 1) {
                    if (self.pending.items[i].info.instance_handle == ih) {
                        const evicted = self.pending.orderedRemove(i);
                        evicted.deinit();
                        break;
                    }
                }
            }
        }

        // RESOURCE_LIMITS: check all three limits in priority order.
        // Rejection is notified via on_sample_rejected; sample is dropped.
        //
        // Ordering invariant: KEEP_LAST eviction above must run first.  The
        // three axes cannot produce a silent loss after that eviction:
        //   max_instances   — only checked when ih is a NEW instance; KEEP_LAST
        //                     only fires when ih already exists in pending, so
        //                     post-eviction current_distinct+1 equals the
        //                     pre-eviction count, which was already ≤ max_instances.
        //   max_samples_per_instance — post-eviction per-instance count is depth-1;
        //                     the spec QoS consistency rule (depth ≤ max_samples_per_instance)
        //                     guarantees depth-1 < max_samples_per_instance.
        //   max_samples     — eviction removes 1, addition adds 1; net zero, so
        //                     the total never exceeds the pre-eviction level.
        const rl = self.qos.resource_limits;
        const reject_reason: ?DDS.SampleRejectedStatusKind = blk: {
            if (rl.max_instances > 0) {
                // Would this sample introduce a new instance that pushes us over the limit?
                var is_new_instance = true;
                for (self.pending.items) |pc| {
                    if (pc.info.instance_handle == ih) {
                        is_new_instance = false;
                        break;
                    }
                }
                if (is_new_instance) {
                    // Count distinct instance handles currently in pending (O(n²), n is bounded by limits).
                    var current_distinct: usize = 0;
                    for (self.pending.items, 0..) |pc, i| {
                        var seen = false;
                        for (self.pending.items[0..i]) |prev| {
                            if (prev.info.instance_handle == pc.info.instance_handle) {
                                seen = true;
                                break;
                            }
                        }
                        if (!seen) current_distinct += 1;
                    }
                    if (current_distinct + 1 > @as(usize, @intCast(rl.max_instances)))
                        break :blk .REJECTED_BY_INSTANCE_LIMIT;
                }
            }
            if (rl.max_samples_per_instance > 0) {
                var count: usize = 0;
                for (self.pending.items) |pc| {
                    if (pc.info.instance_handle == ih) count += 1;
                }
                if (count >= @as(usize, @intCast(rl.max_samples_per_instance)))
                    break :blk .REJECTED_BY_SAMPLES_PER_INSTANCE_LIMIT;
            }
            if (rl.max_samples > 0 and
                self.pending.items.len >= @as(usize, @intCast(rl.max_samples)))
                break :blk .REJECTED_BY_SAMPLES_LIMIT;
            break :blk null;
        };
        if (reject_reason) |reason| {
            self.sample_rejected_total += 1;
            self.sample_rejected_total_change += 1;
            self.sample_rejected_last_reason = reason;
            self.sample_rejected_last_handle = ih;
            self.status_changes |= DDS.SAMPLE_REJECTED_STATUS;
            self.mu.unlock();
            self.alloc.free(copy);
            if (self.status_cond) |sc| sc.notifyWakeup();
            // Always attempt dispatch -- DDS 1.4 §2.2.4.1.5's fallback chain
            // means a delivery can happen even when this reader's own
            // `listener_mask` doesn't include the bit. Only reset the
            // change-counters (under `mu`, matching `vtGetSampleRejected`'s
            // own locking) if delivery actually happened somewhere in the
            // chain.
            const delivered = self.dispatchListener("on_sample_rejected", DDS.SAMPLE_REJECTED_STATUS, vtable.get_c_abi_handle(self), .{&DDS.SampleRejectedStatus{
                .total_count = self.sample_rejected_total,
                .total_count_change = self.sample_rejected_total_change,
                .last_reason = reason,
                .last_instance_handle = ih,
            }});
            if (delivered) {
                self.mu.lock();
                self.sample_rejected_total_change = 0;
                self.status_changes &= ~DDS.SAMPLE_REJECTED_STATUS;
                self.mu.unlock();
            }
            return;
        }

        // Build SampleInfo from the CacheChange.
        const states = self.determineStatesLocked(ih, change.kind);
        if (change.kind == .alive) self.storeKeyIfNeededLocked(ih, copy);
        const src_time = change.source_timestamp.toTime();
        const expiry: ?i64 = if (change.kind == .alive)
            // See the coherent-set branch above: inline PID_LIFESPAN takes
            // precedence over the SEDP-discovered default when present.
            if (change.inline_lifespan_ns orelse self.writer_lifespans.get(change.writer_guid)) |ls_ns|
                src_time.toNs() + ls_ns
            else
                null
        else
            null;
        const pc = PendingChange{
            .data = copy,
            .alloc = self.alloc,
            .info = .{
                .sample_state = DDS.NOT_READ_SAMPLE_STATE,
                .view_state = states.view,
                .instance_state = states.instance_state,
                .source_timestamp = .{ .sec = src_time.sec, .nanosec = src_time.nanosec },
                .instance_handle = ih,
                .publication_handle = writer_mod.guidToHandle(change.writer_guid),
                .valid_data = change.kind == .alive,
                .disposed_generation_count = states.disposed_generation_count,
                .no_writers_generation_count = states.no_writers_generation_count,
            },
            .group_seq_num = change.group_seq_num,
            .expiry_ns = expiry,
        };

        self.pending.append(self.alloc, pc) catch {
            self.mu.unlock();
            self.alloc.free(copy);
            return;
        };
        // Stamp the TBF window now that the sample is committed to pending.
        if (tbf_active) self.tbf_map.put(self.alloc, ih, tbf_src_ns) catch {};
        // Instance going non-alive: release per-instance filter/ownership state.
        // If the instance is later re-registered, fresh entries will be created.
        if (change.kind != .alive) {
            _ = self.tbf_map.remove(ih);
            _ = self.owner_map.remove(ih);
        }
        self.status_changes |= DDS.DATA_AVAILABLE_STATUS;
        // Wake any ReadCondition WaitSets while mu is held (safe: wakeNotify
        // only acquires WaitSet.cv_mu, never reader.mu).
        for (self.data_notifiers.items) |n| n.on_data(n.ctx);
        self.mu.unlock();
        self.last_received_ns.store(self.timer_clock.nowNs(), .monotonic);

        // Wake StatusCondition WaitSets (after releasing mu).
        if (self.status_cond) |sc| sc.notifyWakeup();

        // Fire listener if registered for DATA_AVAILABLE.
        _ = self.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, vtable.get_c_abi_handle(self), .{});
    }

    // ── Coherent set helpers ───────────────────────────────────────────────────

    /// Enqueue a completed coherent WIP samples list into coherent_committed.
    /// Must be called with self.mu held.  Takes ownership of `samples`; frees it
    /// on OOM.  Returns true if the commit succeeded.
    fn commitCoherentWipSamplesLocked(
        self: *Self,
        samples: std.ArrayListUnmanaged(PendingChange),
    ) bool {
        if (self.coherent_committed.append(self.alloc, samples)) {
            self.coherent_committed_ready = true;
            self.status_changes |= DDS.DATA_AVAILABLE_STATUS;
            for (self.data_notifiers.items) |n| n.on_data(n.ctx);
            return true;
        } else |_| {
            for (samples.items) |pc| pc.deinit();
            var s = samples;
            s.deinit(self.alloc);
            return false;
        }
    }

    /// Called when a valid HEARTBEAT arrives from a matched writer.
    /// Flushes the coherent WIP for that writer only when we have received every
    /// sample the writer has declared (highest_sn >= last_sn).  Guarding on
    /// last_sn prevents committing a partial set when the HEARTBEAT arrives before
    /// all DATA datagrams on a real UDP network where datagrams may reorder.
    fn onHeartbeatCb(ctx: *anyopaque, writer_guid: Guid, last_sn: history_mod.SequenceNumber) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        if (!self.subscriber_presentation.coherent_access) return;
        self.mu.lock();
        const committed = if (self.coherent_wip.getPtr(writer_guid)) |entry| blk: {
            // Stale HB guard: a HEARTBEAT from the previous coherent set can arrive
            // after a CS transition has already started the next set.  Such a HB has
            // last_sn < entry.cs (the first SN of the current set), and committing it
            // would prematurely flush an in-progress set.  Drop it.
            if (last_sn < entry.cs) break :blk false;
            // EOC writers use a zero-payload DATA as the definitive end-of-set signal.
            // Intermediate HBs from these writers carry a partial last_sn that would
            // commit the WIP too early.  Skip HB-based flush entirely for them.
            if (self.coherent_eoc_writers.get(writer_guid) != null) {
                self.mu.unlock();
                return;
            }
            if (entry.highest_sn < last_sn) {
                // Missing DATA packets — can't flush yet.  Record the minimum last_sn
                // we've seen so onDataCb can trigger the flush when the missing packets arrive.
                const cur = entry.flush_target_sn orelse last_sn;
                entry.flush_target_sn = if (last_sn < cur) last_sn else cur;
                self.mu.unlock();
                return;
            }
            const kv = self.coherent_wip.fetchRemove(writer_guid).?;
            break :blk self.commitCoherentWipSamplesLocked(kv.value.samples);
        } else false;
        self.mu.unlock();
        if (committed) {
            if (self.status_cond) |sc| sc.notifyWakeup();
            _ = self.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, vtable.get_c_abi_handle(self), .{});
        }
    }

    // ── Ownership tracking ─────────────────────────────────────────────────────

    fn onWriterMatchedCb(ctx: *anyopaque, info: *const proto.MatchedWriterInfo) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        self.mu.lock();
        defer self.mu.unlock();
        self.writer_strengths.put(self.alloc, info.guid, info.ownership_strength) catch return;
        if (info.lifespan_ns > 0)
            self.writer_lifespans.put(self.alloc, info.guid, info.lifespan_ns) catch {}
        else
            _ = self.writer_lifespans.remove(info.guid);
        // Track liveliness for writers with a finite lease.
        if (info.liveliness_lease_ns > 0) {
            const prev = self.writer_liveliness.get(info.guid);
            self.writer_liveliness.put(self.alloc, info.guid, .{
                .lease_ns = info.liveliness_lease_ns,
                .last_alive_ns = self.timer_clock.nowNs(),
                .is_alive = true,
            }) catch {};
            if (prev == null) {
                // Newly matched writer.
                self.liveliness_alive_count += 1;
                self.liveliness_alive_count_change += 1;
                self.liveliness_last_handle = writer_mod.guidToHandle(info.guid);
                self.status_changes |= DDS.LIVELINESS_CHANGED_STATUS;
            } else if (!prev.?.is_alive) {
                // Re-announced after lease expiry — same transition as onWriterAliveCb.
                self.liveliness_alive_count += 1;
                self.liveliness_alive_count_change += 1;
                self.liveliness_not_alive_count -= 1;
                self.liveliness_not_alive_count_change -= 1;
                self.liveliness_last_handle = writer_mod.guidToHandle(info.guid);
                self.status_changes |= DDS.LIVELINESS_CHANGED_STATUS;
            }
            // else: re-announcement of an already-alive writer; update lease/timestamp only.
        }
    }

    fn onWriterAliveCb(ctx: *anyopaque, guid: Guid) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.writer_liveliness.getPtr(guid)) |entry| {
            entry.last_alive_ns = self.timer_clock.nowNs();
            if (!entry.is_alive) {
                entry.is_alive = true;
                self.liveliness_alive_count += 1;
                self.liveliness_alive_count_change += 1;
                self.liveliness_not_alive_count -= 1;
                self.liveliness_not_alive_count_change -= 1;
                self.liveliness_last_handle = writer_mod.guidToHandle(guid);
                self.status_changes |= DDS.LIVELINESS_CHANGED_STATUS;
            }
        }
    }

    fn onWriterUnmatchedCb(ctx: *anyopaque, guid: Guid) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        self.mu.lock();
        _ = self.writer_strengths.remove(guid);
        _ = self.writer_lifespans.remove(guid);
        // Discard any in-progress coherent set from this writer.  If the writer
        // crashed or was deleted mid-set, the partial wip would otherwise stay
        // in the map indefinitely — one leaked entry per connect/disconnect cycle.
        _ = self.coherent_writer_guids.remove(guid);
        _ = self.coherent_eoc_writers.remove(guid);
        if (self.coherent_wip.fetchRemove(guid)) |kv| {
            var wip = kv.value;
            for (wip.samples.items) |pc| pc.deinit();
            wip.samples.deinit(self.alloc);
        }
        // Clean up liveliness tracking for this writer.
        if (self.writer_liveliness.fetchRemove(guid)) |kv| {
            if (kv.value.is_alive) {
                self.liveliness_alive_count -= 1;
                self.liveliness_alive_count_change -= 1;
            } else {
                self.liveliness_not_alive_count -= 1;
                self.liveliness_not_alive_count_change -= 1;
            }
            self.liveliness_last_handle = writer_mod.guidToHandle(guid);
            self.status_changes |= DDS.LIVELINESS_CHANGED_STATUS;
        }
        // Release ownership of any instances this writer held.  Collect keys
        // first (can't remove while iterating), then remove.  The next sample
        // from any remaining writer for those instances will re-claim them.
        var to_remove: std.ArrayListUnmanaged(DDS.InstanceHandle_t) = .empty;
        defer to_remove.deinit(self.alloc);
        {
            var it = self.owner_map.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.guid.eql(guid)) {
                    to_remove.append(self.alloc, entry.key_ptr.*) catch {};
                }
            }
        }
        for (to_remove.items) |ih| _ = self.owner_map.remove(ih);

        // Synthesize NOT_ALIVE_NO_WRITERS for each instance this writer had
        // published to that no longer has any other live writer.
        var had_synthetic = false;
        if (self.writer_instances.fetchRemove(guid)) |kv| {
            var inner = kv.value;
            defer inner.deinit(self.alloc);
            var ih_it = inner.keyIterator();
            while (ih_it.next()) |ih_ptr| {
                const ih = ih_ptr.*;
                // Another remaining writer covers this instance — no orphan.
                var covered = false;
                var wi_it = self.writer_instances.valueIterator();
                while (wi_it.next()) |other| {
                    if (other.contains(ih)) {
                        covered = true;
                        break;
                    }
                }
                if (covered) continue;
                // Instance already non-alive (disposed/unregistered) — skip.
                const si = self.seen_instances.get(ih) orelse continue;
                if (si.instance_state != DDS.ALIVE_INSTANCE_STATE) continue;
                // Build synthetic change.
                const empty = self.alloc.dupe(u8, &.{}) catch continue;
                const states = self.determineStatesLocked(ih, .not_alive_unregistered);
                const now = time_mod.Time.now();
                const pc = PendingChange{
                    .data = empty,
                    .alloc = self.alloc,
                    .info = .{
                        .sample_state = DDS.NOT_READ_SAMPLE_STATE,
                        .view_state = states.view,
                        .instance_state = states.instance_state,
                        .instance_handle = ih,
                        .source_timestamp = .{ .sec = now.sec, .nanosec = now.nanosec },
                        .publication_handle = writer_mod.guidToHandle(guid),
                        .valid_data = false,
                        .disposed_generation_count = states.disposed_generation_count,
                        .no_writers_generation_count = states.no_writers_generation_count,
                    },
                };
                self.pending.append(self.alloc, pc) catch {
                    self.alloc.free(empty);
                    continue;
                };
                had_synthetic = true;
            }
        }
        if (had_synthetic) {
            self.status_changes |= DDS.DATA_AVAILABLE_STATUS;
            for (self.data_notifiers.items) |n| n.on_data(n.ctx);
        }
        self.mu.unlock();
        if (had_synthetic) {
            self.last_received_ns.store(self.timer_clock.nowNs(), .monotonic);
            if (self.status_cond) |sc| sc.notifyWakeup();
            _ = self.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, vtable.get_c_abi_handle(self), .{});
        }
    }

    /// Expose the OLDEST committed coherent set to `pending`.
    /// Called by Subscriber.vtBeginAccess() while self.mu is held.
    /// Pops exactly one complete set from the front of the queue; if more sets
    /// remain, coherent_committed_ready stays true so the next begin_access call
    /// can deliver the next set.  This ensures each begin_access/end_access cycle
    /// delivers exactly one coherent set regardless of how many accumulated.
    /// Caller fires data-available callbacks AFTER releasing mu.
    pub fn commitCoherentPendingLocked(self: *Self) void {
        if (self.coherent_committed.items.len == 0) return;
        var first_set = self.coherent_committed.orderedRemove(0);
        // Pre-allocate so the append loop is all-or-nothing.  On OOM the entire
        // set is discarded rather than partially committed.
        self.pending.ensureUnusedCapacity(self.alloc, first_set.items.len) catch {
            for (first_set.items) |cppc| cppc.deinit();
            first_set.deinit(self.alloc);
            return;
        };
        for (first_set.items) |cppc| {
            self.pending.appendAssumeCapacity(cppc);
        }
        first_set.deinit(self.alloc);
        self.coherent_committed_ready = self.coherent_committed.items.len > 0;
        self.status_changes |= DDS.DATA_AVAILABLE_STATUS;
        // data_notifiers are fired by the subscriber after releasing all locks.
    }

    /// Returns true if there is at least one pending sample.
    /// Used as the `has_data_fn` in ReadConditionImpl.
    /// ctx is a *DataReaderImpl.
    pub fn hasPendingDataFn(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        return self.pending.items.len > 0;
    }

    pub fn hasPendingData(self: *Self) bool {
        self.mu.lock();
        defer self.mu.unlock();
        return self.pending.items.len > 0;
    }

    /// Returns the number of matched writers (remote DataWriters paired via SEDP).
    pub fn matchedWriterCount(self: *Self) usize {
        var guids: std.ArrayListUnmanaged(Guid) = .empty;
        defer guids.deinit(self.alloc);
        self.proto_reader.listMatchedWriters(self.alloc, &guids) catch return 0;
        return guids.items.len;
    }

    /// Register a WaitSet notification callback.  Called by ReadConditionImpl
    /// when a WaitSet attaches the condition.  Returns false if the
    /// allocator couldn't grow `data_notifiers` -- the caller (vtAttach) must
    /// treat that as attachment failure and roll back, not report
    /// RETCODE_OK for a WaitSet that will never see a real data-arrival
    /// wakeup.
    pub fn addDataNotifier(ctx: *anyopaque, n: waitset.DataNotifyFn) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        self.data_notifiers.append(self.alloc, n) catch return false;
        return true;
    }

    /// ReadConditionImpl/QueryConditionImpl's `reader_quiesce_acquire` --
    /// held across their own deinit() so it can never race this reader's
    /// own reallyDeinit() (see there, and ReadConditionImpl.deinit()'s doc
    /// comment).
    pub fn readerQuiesceAcquire(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.quiesce.acquire();
    }

    /// Pairs with a successful readerQuiesceAcquire above.
    pub fn readerQuiesceRelease(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.quiesce.release(self, reallyDeinit);
    }

    /// Remove the notification callback for `waitset_ctx`.  Called by
    /// ReadConditionImpl when a WaitSet detaches.
    pub fn removeDataNotifier(ctx: *anyopaque, waitset_ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.data_notifiers.items, 0..) |n, i| {
            if (n.ctx == waitset_ctx) {
                _ = self.data_notifiers.swapRemove(i);
                return;
            }
        }
    }

    /// Computes sample_rank/generation_rank/absolute_generation_rank for a just-collected
    /// batch (DDS spec §2.2.2.5.4). O(n²) is fine — batch size is bounded by max_samples /
    /// resource limits, same precedent as the KEEP_LAST/resource-limit checks in onDataCb.
    /// Must be called with `mu` held (reads `seen_instances` for the live baseline).
    fn finalizeGenerationRanksLocked(self: *Self, out: []TakenSample) void {
        for (out, 0..) |*s, i| {
            const ih = s.info.instance_handle;
            const this_sum: i64 = @as(i64, s.info.disposed_generation_count) + s.info.no_writers_generation_count;
            var mrsic_sum = this_sum;
            var sample_rank: i32 = 0;
            for (out[i + 1 ..]) |later| {
                if (later.info.instance_handle != ih) continue;
                sample_rank += 1;
                const later_sum: i64 = @as(i64, later.info.disposed_generation_count) + later.info.no_writers_generation_count;
                if (later_sum > mrsic_sum) mrsic_sum = later_sum;
            }
            s.info.sample_rank = sample_rank;
            s.info.generation_rank = std.math.lossyCast(i32, mrsic_sum - this_sum);
            const live_sum: i64 = if (self.seen_instances.get(ih)) |entry|
                @as(i64, entry.disposed_generation_count) + entry.no_writers_generation_count
            else
                this_sum;
            s.info.absolute_generation_rank = std.math.lossyCast(i32, live_sum - this_sum);
        }
    }

    /// Dequeue one sample.  Returns null if the queue is empty.
    /// Expired samples (LIFESPAN QoS) are silently discarded.
    /// The caller owns TakenSample.data and must free it with the reader's allocator.
    pub fn takeRaw(self: *Self) ?TakenSample {
        self.mu.lock();
        defer self.mu.unlock();
        const now_ns = time_mod.nanoTimestamp();
        while (self.pending.items.len > 0) {
            // Honour the ordered-access window set by Subscriber.begin_access().
            // Samples appended after the sort (new network arrivals during the window
            // between begin_access and end_access) must not leak into the sorted batch.
            // Clear DATA_AVAILABLE_STATUS so StatusCondition users don't busy-spin
            // while waiting for end_access() to open the next window.
            if (self.ordered_access_watermark) |wm| if (wm == 0) {
                self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
                return null;
            };
            const pc = self.pending.orderedRemove(0);
            if (self.ordered_access_watermark) |*wm| wm.* -= 1;
            if (pc.expiry_ns) |exp| {
                if (now_ns >= exp) {
                    pc.deinit();
                    continue;
                }
            }
            if (self.pending.items.len == 0) {
                self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
            }
            var result = [1]TakenSample{.{ .data = pc.data, .info = pc.info }};
            self.finalizeGenerationRanksLocked(&result);
            return result[0];
        }
        self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        return null;
    }

    /// DDS take_next_instance semantics: dequeue one sample belonging to the
    /// "next" instance in handle order after `prev_instance_handle`.
    /// If prev == 0 (HANDLE_NIL), dequeue from whatever instance appears first.
    /// Expired samples (LIFESPAN QoS) are silently purged during the scan.
    /// Returns null when the queue has no qualifying sample.
    /// The caller owns TakenSample.data and must free with the reader's allocator.
    pub fn takeNextInstanceRaw(self: *Self, prev_instance_handle: DDS.InstanceHandle_t) ?TakenSample {
        self.mu.lock();
        defer self.mu.unlock();

        const now_ns = time_mod.nanoTimestamp();

        // Purge expired samples before scanning for the target instance.
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const pc = &self.pending.items[i];
            if (pc.expiry_ns) |exp| {
                if (now_ns >= exp) {
                    const expired = self.pending.orderedRemove(i);
                    expired.deinit();
                    continue;
                }
            }
            i += 1;
        }

        // Find the target instance handle.
        var target_ih: ?DDS.InstanceHandle_t = null;
        for (self.pending.items) |pc| {
            const ih = pc.info.instance_handle;
            if (prev_instance_handle == 0) {
                if (target_ih == null or ih < target_ih.?) target_ih = ih;
            } else if (ih > prev_instance_handle) {
                if (target_ih == null or ih < target_ih.?) target_ih = ih;
            }
        }
        const tgt = target_ih orelse {
            if (self.pending.items.len == 0) self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
            return null;
        };

        for (self.pending.items, 0..) |pc, idx| {
            if (pc.info.instance_handle == tgt) {
                var result = [1]TakenSample{.{ .data = pc.data, .info = pc.info }};
                _ = self.pending.orderedRemove(idx);
                if (self.pending.items.len == 0) {
                    self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
                }
                self.finalizeGenerationRanksLocked(&result);
                return result[0];
            }
        }
        return null;
    }

    /// Non-destructive analog to takeNextInstanceRaw: return (without removing) one
    /// sample from the "next" instance in handle order after `prev_instance_handle`.
    /// The sample's sample_state is updated to READ_SAMPLE_STATE in-place.
    /// Returns null when no qualifying sample exists.
    /// The caller owns TakenSample.data and must free with the reader's allocator.
    pub fn readNextInstanceRaw(self: *Self, prev_instance_handle: DDS.InstanceHandle_t) ?TakenSample {
        self.mu.lock();
        defer self.mu.unlock();

        const now_ns = time_mod.nanoTimestamp();

        // Purge expired samples before scanning.
        var i: usize = 0;
        while (i < self.pending.items.len) {
            const pc = &self.pending.items[i];
            if (pc.expiry_ns) |exp| {
                if (now_ns >= exp) {
                    const expired = self.pending.orderedRemove(i);
                    expired.deinit();
                    continue;
                }
            }
            i += 1;
        }

        // Find the target instance handle (smallest ih > prev, or smallest overall if prev == 0).
        var target_ih: ?DDS.InstanceHandle_t = null;
        for (self.pending.items) |pc| {
            const ih = pc.info.instance_handle;
            if (prev_instance_handle == 0) {
                if (target_ih == null or ih < target_ih.?) target_ih = ih;
            } else if (ih > prev_instance_handle) {
                if (target_ih == null or ih < target_ih.?) target_ih = ih;
            }
        }
        const tgt = target_ih orelse return null;

        for (self.pending.items) |*pc| {
            if (pc.info.instance_handle == tgt) {
                const clone = self.alloc.dupe(u8, pc.data) catch return null;
                pc.info.sample_state = DDS.READ_SAMPLE_STATE;
                var result = [1]TakenSample{.{ .data = clone, .info = pc.info }};
                self.finalizeGenerationRanksLocked(&result);
                return result[0];
            }
        }
        return null;
    }

    /// DDS `take_next_instance_w_condition` semantics: like `takeNextInstanceRaw`,
    /// but instance selection AND per-sample inclusion are both restricted to
    /// samples matching `sample_mask`/`view_mask`/`instance_mask` (and
    /// `maybe_qc`'s query expression, if given) -- per spec §2.2.2.5.3.19, the
    /// target instance is the smallest instance_handle > `prev_instance_handle`
    /// *among instances that have at least one sample satisfying the
    /// condition*, not just the next instance with any sample at all. Appends
    /// every matching sample of that one instance (up to `max_samples`) to
    /// `out`. Mirrors `takeFiltered`'s locking/expiry-purge/in-place-compaction
    /// shape, restricted to the selected instance.
    pub fn takeNextInstanceFiltered(
        self: *Self,
        out: *std.ArrayListUnmanaged(TakenSample),
        prev_instance_handle: DDS.InstanceHandle_t,
        sample_mask: DDS.SampleStateMask,
        view_mask: DDS.ViewStateMask,
        instance_mask: DDS.InstanceStateMask,
        max_samples: i32,
        maybe_qc: ?*const waitset.QueryConditionImpl,
    ) anyerror!void {
        self.mu.lock();
        defer self.mu.unlock();
        const now_ns = time_mod.nanoTimestamp();

        var ei: usize = 0;
        while (ei < self.pending.items.len) {
            if (self.pending.items[ei].expiry_ns) |exp| {
                if (now_ns >= exp) {
                    const expired = self.pending.orderedRemove(ei);
                    expired.deinit();
                    continue;
                }
            }
            ei += 1;
        }
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }

        // Smallest instance_handle > prev (or overall smallest if prev == 0)
        // among instances with at least one sample matching the condition.
        var target_ih: ?DDS.InstanceHandle_t = null;
        for (self.pending.items) |pc| {
            const ih = pc.info.instance_handle;
            if (prev_instance_handle != 0 and ih <= prev_instance_handle) continue;
            if (target_ih != null and ih >= target_ih.?) continue;
            if (!matchesSample(pc, sample_mask, view_mask, instance_mask, null)) continue;
            if (!matchesQuery(pc, maybe_qc, self.get_field_fn)) continue;
            target_ih = ih;
        }
        const tgt = target_ih orelse return;

        const limit: usize = if (max_samples < 0) std.math.maxInt(usize) else @intCast(max_samples);

        var match_count: usize = 0;
        for (self.pending.items) |pc| {
            if (match_count >= limit) break;
            if (pc.info.instance_handle != tgt) continue;
            if (matchesSample(pc, sample_mask, view_mask, instance_mask, null) and
                matchesQuery(pc, maybe_qc, self.get_field_fn)) match_count += 1;
        }
        try out.ensureUnusedCapacity(self.alloc, match_count);
        const start = out.items.len;

        var write: usize = 0;
        var taken: usize = 0;
        for (self.pending.items) |pc| {
            if (pc.info.instance_handle == tgt and taken < limit and
                matchesSample(pc, sample_mask, view_mask, instance_mask, null) and
                matchesQuery(pc, maybe_qc, self.get_field_fn))
            {
                out.appendAssumeCapacity(.{ .data = pc.data, .info = pc.info });
                taken += 1;
            } else {
                self.pending.items[write] = pc;
                write += 1;
            }
        }
        self.pending.items.len = write;
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }
        self.finalizeGenerationRanksLocked(out.items[start..]);
    }

    /// Non-destructive analog to `takeNextInstanceFiltered` -- see its doc
    /// comment for the instance-selection semantics. Matching samples are
    /// cloned into `out` and marked READ_SAMPLE_STATE in-place, same as `readRaw`.
    pub fn readNextInstanceFiltered(
        self: *Self,
        out: *std.ArrayListUnmanaged(TakenSample),
        prev_instance_handle: DDS.InstanceHandle_t,
        sample_mask: DDS.SampleStateMask,
        view_mask: DDS.ViewStateMask,
        instance_mask: DDS.InstanceStateMask,
        max_samples: i32,
        maybe_qc: ?*const waitset.QueryConditionImpl,
    ) anyerror!void {
        self.mu.lock();
        defer self.mu.unlock();
        const now_ns = time_mod.nanoTimestamp();

        var ei: usize = 0;
        while (ei < self.pending.items.len) {
            if (self.pending.items[ei].expiry_ns) |exp| {
                if (now_ns >= exp) {
                    const expired = self.pending.orderedRemove(ei);
                    expired.deinit();
                    continue;
                }
            }
            ei += 1;
        }
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }

        var target_ih: ?DDS.InstanceHandle_t = null;
        for (self.pending.items) |pc| {
            const ih = pc.info.instance_handle;
            if (prev_instance_handle != 0 and ih <= prev_instance_handle) continue;
            if (target_ih != null and ih >= target_ih.?) continue;
            if (!matchesSample(pc, sample_mask, view_mask, instance_mask, null)) continue;
            if (!matchesQuery(pc, maybe_qc, self.get_field_fn)) continue;
            target_ih = ih;
        }
        const tgt = target_ih orelse return;

        const limit: usize = if (max_samples < 0) std.math.maxInt(usize) else @intCast(max_samples);
        const start = out.items.len;
        var count: usize = 0;
        for (self.pending.items) |*pc| {
            if (count >= limit) break;
            if (pc.info.instance_handle != tgt) continue;
            if (!matchesSample(pc.*, sample_mask, view_mask, instance_mask, null)) continue;
            if (!matchesQuery(pc.*, maybe_qc, self.get_field_fn)) continue;
            const clone = try self.alloc.dupe(u8, pc.data);
            errdefer self.alloc.free(clone);
            try out.append(self.alloc, .{ .data = clone, .info = pc.info });
            pc.info.sample_state = DDS.READ_SAMPLE_STATE;
            count += 1;
        }
        self.finalizeGenerationRanksLocked(out.items[start..]);
    }

    /// Return the stored CDR payload for the given instance handle, or null if
    /// no alive sample has arrived for this instance.
    /// The returned slice is valid until the next write to this reader or deinit.
    pub fn getKeyValueRaw(self: *Self, handle: DDS.InstanceHandle_t) ?[]u8 {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.seen_instances.get(handle)) |entry| {
            return entry.key_cdr;
        }
        return null;
    }

    /// Return true if `handle` refers to a known ALIVE instance.
    pub fn lookupInstance(self: *Self, handle: DDS.InstanceHandle_t) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.seen_instances.get(handle)) |entry| {
            return entry.instance_state == DDS.ALIVE_INSTANCE_STATE;
        }
        return false;
    }

    /// Non-destructively read samples matching the given state masks.
    ///
    /// Each matching sample's sample_state is set to READ_SAMPLE_STATE in-place in
    /// the pending queue.  A clone of the sample (info + data) is appended to `out`.
    /// The caller owns the cloned TakenSample.data values and must free them with
    /// the same allocator used to create this DataReaderImpl.
    ///
    /// `max_samples` < 0 means no limit.  `maybe_ih` restricts to a single instance.
    pub fn readRaw(
        self: *Self,
        out: *std.ArrayListUnmanaged(TakenSample),
        sample_mask: DDS.SampleStateMask,
        view_mask: DDS.ViewStateMask,
        instance_mask: DDS.InstanceStateMask,
        max_samples: i32,
        maybe_ih: ?DDS.InstanceHandle_t,
        maybe_qc: ?*const waitset.QueryConditionImpl,
    ) anyerror!void {
        self.mu.lock();
        defer self.mu.unlock();
        const now_ns = time_mod.nanoTimestamp();
        var ei: usize = 0;
        while (ei < self.pending.items.len) {
            if (self.pending.items[ei].expiry_ns) |exp| {
                if (now_ns >= exp) {
                    const expired = self.pending.orderedRemove(ei);
                    expired.deinit();
                    continue;
                }
            }
            ei += 1;
        }
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }
        const limit: usize = if (max_samples < 0) std.math.maxInt(usize) else @intCast(max_samples);
        const start = out.items.len;
        var count: usize = 0;
        for (self.pending.items) |*pc| {
            if (count >= limit) break;
            if (!matchesSample(pc.*, sample_mask, view_mask, instance_mask, maybe_ih)) continue;
            if (!matchesQuery(pc.*, maybe_qc, self.get_field_fn)) continue;
            const clone = try self.alloc.dupe(u8, pc.data);
            errdefer self.alloc.free(clone);
            try out.append(self.alloc, .{ .data = clone, .info = pc.info });
            pc.info.sample_state = DDS.READ_SAMPLE_STATE;
            count += 1;
        }
        self.finalizeGenerationRanksLocked(out.items[start..]);
    }

    /// Remove and return samples matching the given state masks.
    ///
    /// The caller owns the returned TakenSample.data values and must free them with
    /// the same allocator used to create this DataReaderImpl.
    ///
    /// `max_samples` < 0 means no limit.  `maybe_ih` restricts to a single instance.
    pub fn takeFiltered(
        self: *Self,
        out: *std.ArrayListUnmanaged(TakenSample),
        sample_mask: DDS.SampleStateMask,
        view_mask: DDS.ViewStateMask,
        instance_mask: DDS.InstanceStateMask,
        max_samples: i32,
        maybe_ih: ?DDS.InstanceHandle_t,
        maybe_qc: ?*const waitset.QueryConditionImpl,
    ) anyerror!void {
        self.mu.lock();
        defer self.mu.unlock();
        const now_ns = time_mod.nanoTimestamp();
        var ei: usize = 0;
        while (ei < self.pending.items.len) {
            if (self.pending.items[ei].expiry_ns) |exp| {
                if (now_ns >= exp) {
                    const expired = self.pending.orderedRemove(ei);
                    expired.deinit();
                    continue;
                }
            }
            ei += 1;
        }
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }
        const limit: usize = if (max_samples < 0) std.math.maxInt(usize) else @intCast(max_samples);

        // Count matches first so we can reserve out capacity before mutating pending.
        var match_count: usize = 0;
        for (self.pending.items) |pc| {
            if (match_count >= limit) break;
            if (matchesSample(pc, sample_mask, view_mask, instance_mask, maybe_ih) and
                matchesQuery(pc, maybe_qc, self.get_field_fn)) match_count += 1;
        }
        try out.ensureUnusedCapacity(self.alloc, match_count);
        const start = out.items.len;

        // In-place compaction: matching items move to out, rest stay in pending.
        var write: usize = 0;
        var taken: usize = 0;
        for (self.pending.items) |pc| {
            if (taken < limit and
                matchesSample(pc, sample_mask, view_mask, instance_mask, maybe_ih) and
                matchesQuery(pc, maybe_qc, self.get_field_fn))
            {
                out.appendAssumeCapacity(.{ .data = pc.data, .info = pc.info });
                taken += 1;
            } else {
                self.pending.items[write] = pc;
                write += 1;
            }
        }
        self.pending.items.len = write;
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }
        self.finalizeGenerationRanksLocked(out.items[start..]);
    }

    pub fn toDDSDataReader(self: *Self) DDS.DataReader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    /// Called by participant when a discovered remote writer's QoS is incompatible
    /// with this reader's requested QoS (DDS v1.4 §2.2.4.4).
    /// Updates counters and fires on_requested_incompatible_qos if registered.
    /// May be called while participant.mu is held; must not re-enter participant.
    pub fn notifyIncompatibleQos(ctx: *anyopaque, policy_id: i32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        // Capture the fields status needs while still holding the lock --
        // reading self.incompat_total/incompat_total_change again after
        // unlocking would race a concurrent call to this same function
        // (e.g. two incompatible remote writers discovered around the same
        // time) doing its own locked increment (confirmed via TSan).
        self.mu.lock();
        self.incompat_total_change += 1;
        self.incompat_last_policy = policy_id;
        self.status_changes |= DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS;
        // Release ordering: publishes the plain-field writes above (program
        // order on this thread) to any thread that observes this value via
        // a paired .acquire load, without requiring that thread to take `mu`.
        const new_total = self.incompat_total.load(.monotonic) + 1;
        self.incompat_total.store(new_total, .release);
        var status = DDS.RequestedIncompatibleQosStatus{};
        status.total_count = new_total;
        status.total_count_change = self.incompat_total_change;
        status.last_policy_id = policy_id;
        self.mu.unlock();

        if (self.status_cond) |sc| sc.notifyWakeup();

        // Always attempt dispatch -- DDS 1.4 §2.2.4.1.5's fallback chain
        // means a delivery can happen even when this reader's own
        // `listener_mask` doesn't include the bit. Only reset the
        // change-counters if delivery actually happened somewhere in the
        // chain.
        if (self.dispatchListener("on_requested_incompatible_qos", DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS, vtable.get_c_abi_handle(self), .{&status})) {
            self.mu.lock();
            self.incompat_total_change = 0;
            self.status_changes &= ~DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS;
            self.mu.unlock();
        }
    }

    /// Called by participant when a remote DataWriter matches or unmatches this reader.
    /// Updates SubscriptionMatched counters and fires on_subscription_matched if registered.
    /// May be called while participant.mu is held; must not re-enter participant.
    pub fn notifySubscriptionMatched(ctx: *anyopaque, remote_handle: DDS.InstanceHandle_t, added: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        const delta: i32 = if (added) 1 else -1;
        self.mu.lock();
        if (added) self.sub_matched_total += 1;
        self.sub_matched_total_change += if (added) 1 else 0;
        self.sub_matched_current += delta;
        self.sub_matched_current_change += delta;
        self.sub_matched_last_handle = remote_handle;
        self.status_changes |= DDS.SUBSCRIPTION_MATCHED_STATUS;
        self.mu.unlock();

        if (self.status_cond) |sc| sc.notifyWakeup();

        // Always attempt dispatch -- see notifyIncompatibleQos's comment on
        // why this can't be gated on this reader's own `listener_mask`.
        const status = DDS.SubscriptionMatchedStatus{
            .total_count = self.sub_matched_total,
            .total_count_change = self.sub_matched_total_change,
            .current_count = self.sub_matched_current,
            .current_count_change = self.sub_matched_current_change,
            .last_publication_handle = remote_handle,
        };
        if (self.dispatchListener("on_subscription_matched", DDS.SUBSCRIPTION_MATCHED_STATUS, vtable.get_c_abi_handle(self), .{&status})) {
            self.mu.lock();
            self.status_changes &= ~DDS.SUBSCRIPTION_MATCHED_STATUS;
            self.sub_matched_total_change = 0;
            self.sub_matched_current_change = 0;
            self.mu.unlock();
        }
    }

    /// Called by the on_sample_lost DataCallback when GAP processing marks SNs as lost.
    fn onSampleLostCb(ctx: *anyopaque, count: i32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.notifySampleLost(count);
    }

    pub fn notifySampleLost(self: *Self, count: i32) void {
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        self.mu.lock();
        self.sample_lost_total += count;
        self.sample_lost_total_change += count;
        self.status_changes |= DDS.SAMPLE_LOST_STATUS;
        self.mu.unlock();
        if (self.status_cond) |sc| sc.notifyWakeup();
        // Always attempt dispatch -- see notifyIncompatibleQos's comment on
        // why this can't be gated on this reader's own `listener_mask`.
        const delivered = self.dispatchListener("on_sample_lost", DDS.SAMPLE_LOST_STATUS, vtable.get_c_abi_handle(self), .{&DDS.SampleLostStatus{
            .total_count = self.sample_lost_total,
            .total_count_change = self.sample_lost_total_change,
        }});
        if (delivered) {
            self.mu.lock();
            self.sample_lost_total_change = 0;
            self.status_changes &= ~DDS.SAMPLE_LOST_STATUS;
            self.mu.unlock();
        }
    }

    fn notifyLivelinessChanged(self: *Self) void {
        self.status_changes |= DDS.LIVELINESS_CHANGED_STATUS;
        if (self.status_cond) |sc| sc.notifyWakeup();
        // Always attempt dispatch -- see notifyIncompatibleQos's comment on
        // why this can't be gated on this reader's own `listener_mask`.
        const status = DDS.LivelinessChangedStatus{
            .alive_count = self.liveliness_alive_count,
            .not_alive_count = self.liveliness_not_alive_count,
            .alive_count_change = self.liveliness_alive_count_change,
            .not_alive_count_change = self.liveliness_not_alive_count_change,
            .last_publication_handle = self.liveliness_last_handle,
        };
        if (self.dispatchListener("on_liveliness_changed", DDS.LIVELINESS_CHANGED_STATUS, vtable.get_c_abi_handle(self), .{&status})) {
            self.liveliness_alive_count_change = 0;
            self.liveliness_not_alive_count_change = 0;
            self.status_changes &= ~DDS.LIVELINESS_CHANGED_STATUS;
        }
    }

    /// Fire on_requested_deadline_missed if the listener is registered for it.
    /// Only called from checkTimersFn, with participant.mu NOT held -- see
    /// that function's doc comment.
    pub fn notifyDeadlineMissed(self: *Self) void {
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);
        self.deadline_missed_total += 1;
        self.deadline_missed_total_change += 1;
        self.status_changes |= DDS.REQUESTED_DEADLINE_MISSED_STATUS;
        if (self.status_cond) |sc| sc.notifyWakeup();
        // Always attempt dispatch -- see notifyIncompatibleQos's comment on
        // why this can't be gated on this reader's own `listener_mask`.
        var status = DDS.RequestedDeadlineMissedStatus{};
        status.total_count = self.deadline_missed_total;
        status.total_count_change = self.deadline_missed_total_change;
        if (self.dispatchListener("on_requested_deadline_missed", DDS.REQUESTED_DEADLINE_MISSED_STATUS, vtable.get_c_abi_handle(self), .{&status})) {
            self.deadline_missed_total_change = 0;
            self.status_changes &= ~DDS.REQUESTED_DEADLINE_MISSED_STATUS;
        }
    }

    /// Registered alongside checkTimersFn so that participant.checkTimers()
    /// can hold a quiesce reference across its own unlock-then-dispatch
    /// window, not just the one checkTimersFn takes internally below. A raw
    /// `ctx` pointer copied out of the participant's map while `mu` is held
    /// isn't itself protected from becoming dangling before checkTimersFn
    /// ever runs -- EntityQuiesce can't protect a pointer that's already
    /// invalid before acquire() is called on it (see entity_quiesce.zig's
    /// module doc comment). Calling this (while `mu` is still held, so the
    /// entity is provably still live) and holding it until after `check`
    /// returns closes that gap.
    pub fn quiesceAcquireFn(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.quiesce.acquire();
    }

    pub fn quiesceReleaseFn(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.quiesce.release(self, reallyDeinit);
    }

    /// Called by participant.checkTimers() for each active reader.
    /// Checks DEADLINE and LIVELINESS lease expiry; fires notifications when thresholds exceeded.
    /// Called with participant.mu NOT held (checkTimers() collects the due
    /// callbacks under the lock, then releases it before calling any of
    /// them) -- safe for this (and notifyDeadlineMissed/notifyLivelinessChanged
    /// below, which this may call) to re-enter the participant, e.g. if a
    /// user listener reacts to a deadline-missed notification by deleting
    /// the reader/participant.
    pub fn checkTimersFn(ctx: *anyopaque, now_ns: i64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        if (!self.quiesce.acquire()) return;
        defer self.quiesce.release(self, reallyDeinit);

        // DEADLINE check.
        const dl = self.qos.deadline.period;
        if (durationIsActive(dl)) {
            const period_ns = @as(i64, dl.sec) * std.time.ns_per_s + @as(i64, dl.nanosec);
            const last = self.last_received_ns.load(.monotonic);
            if (now_ns - last >= period_ns) {
                self.last_received_ns.store(now_ns, .monotonic);
                self.notifyDeadlineMissed();
            }
        }

        // LIVELINESS lease expiry check.
        self.mu.lock();
        var liveliness_changed = false;
        var it = self.writer_liveliness.iterator();
        while (it.next()) |kv| {
            const entry = kv.value_ptr;
            if (!entry.is_alive) continue;
            if (entry.lease_ns <= 0) continue;
            if (now_ns - entry.last_alive_ns >= entry.lease_ns) {
                entry.is_alive = false;
                self.liveliness_alive_count -= 1;
                self.liveliness_alive_count_change -= 1;
                self.liveliness_not_alive_count += 1;
                self.liveliness_not_alive_count_change += 1;
                self.liveliness_last_handle = writer_mod.guidToHandle(kv.key_ptr.*);
                liveliness_changed = true;
            }
        }
        self.mu.unlock();
        if (liveliness_changed) self.notifyLivelinessChanged();
    }

    /// Registered with the participant (see participant.zig's
    /// subRegisterReaderGetFieldRefresh / ActiveReader.refresh_get_field) so
    /// that re-registering TypeSupport for this reader's type can push the
    /// new get_field getter in -- without this, get_field_fn (and
    /// cft_filter.get_field_fn, if this reader was created against a
    /// ContentFilteredTopic) would keep pointing at the old TypeSupport's
    /// ctx after registerTypeSupport() frees it, and the next CFT/
    /// QueryCondition evaluation would dereference freed memory.
    pub fn refreshGetFieldFn(ctx: *anyopaque, new_get_field: ?filter_mod.CdrFieldGetter) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        // get_field_fn and cft_filter are read under self.mu everywhere else
        // (on_receive's CFT check, readFiltered/takeFiltered's QueryCondition
        // evaluation) -- take it here too, or a concurrent evaluation can
        // observe a torn/inconsistent write to either field.
        self.mu.lock();
        defer self.mu.unlock();
        self.get_field_fn = new_get_field;
        // Always derive cft_filter from cft_ptr (immutable, set once at
        // creation) rather than mutating/dropping a previously-built
        // CftFilterState -- CftFilterState.get_field_fn is non-optional, so
        // there's no shape for "CFT but no getter", but dropping cft_ptr
        // along with it (as a prior version of this function did) would
        // permanently disable CFT filtering for this reader the moment a
        // TypeSupport re-registration transiently had no get_field, even if
        // a later re-registration brought one back.
        if (self.cft_ptr) |cft_ptr| {
            self.cft_filter = if (new_get_field) |gf|
                .{ .cft_ptr = cft_ptr, .get_field_fn = gf }
            else
                null;
        }
    }

    // ── Entity vtable ─────────────────────────────────────────────────────────

    pub const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
    };

    // ── DDS.DataReader vtable ─────────────────────────────────────────────────

    pub const vtable = DDS.DataReader.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .create_readcondition = vtCreateReadCondition,
        .create_querycondition = vtCreateQueryCondition,
        .delete_readcondition = vtDeleteReadCondition,
        .delete_contained_entities = vtDeleteContained,
        .set_qos = vtSetQos,
        .get_qos = vtGetQos,
        .set_listener = vtSetListener,
        .get_listener = vtGetListener,
        .get_topicdescription = vtGetTopicDesc,
        .get_subscriber = vtGetSubscriber,
        .get_sample_rejected_status = vtGetSampleRejected,
        .get_liveliness_changed_status = vtGetLivelinessChanged,
        .get_requested_deadline_missed_status = vtGetDeadlineMissed,
        .get_requested_incompatible_qos_status = vtGetIncompatQos,
        .get_subscription_matched_status = vtGetSubMatched,
        .get_sample_lost_status = vtGetSampleLost,
        .wait_for_historical_data = vtWaitForHistorical,
        .get_matched_publications = vtGetMatchedPubs,
        .get_matched_publication_data = vtGetMatchedPubData,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .as_Entity = vtAsEntity,
    };

    /// One `CAbiViews` value for the whole object, covering all three
    /// interface views it presents (Entity, DataReader, and — via
    /// `extensions.zig`'s `readerGetCAbiHandleZzdds`, which shares this same
    /// `c_abi` field/`views` value — ZZDDS.DataReader too). See
    /// `GuardConditionImpl.views`'s identical-shape doc comment for the
    /// general mechanism.
    pub const views = ZZDDS.DataReader.CAbiViews{
        .base = .{
            .base = .{ .flat_vtable = &entity_vtable },
            .flat_vtable = &vtable,
        },
        .flat_vtable = &extensions_mod.reader_vtable,
    };

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtAsEntity(ctx: *anyopaque) DDS.Entity {
        return .{ .ptr = ctx, .vtable = &entity_vtable };
    }

    fn vtEnable(_: *anyopaque) DDS.ReturnCode_t {
        return DDS.RETCODE_OK;
    }

    fn vtGetStatusCond(ctx: *anyopaque) DDS.StatusCondition {
        const self = cast(ctx);
        if (self.status_cond) |sc| return sc.toDDSStatusCondition();
        return nil.nil_status_condition;
    }

    fn vtGetStatusChanges(ctx: *anyopaque) DDS.StatusMask {
        return cast(ctx).status_changes;
    }

    fn vtGetHandle(ctx: *anyopaque) DDS.InstanceHandle_t {
        return cast(ctx).instance_handle;
    }

    fn vtCreateReadCondition(
        ctx: *anyopaque,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
    ) DDS.ReadCondition {
        const self = cast(ctx);
        // Without this, a create racing this reader's own deinit() could
        // track a new condition into read_conditions after reallyDeinit()
        // already snapshotted-and-cleared it (never torn down, holding a
        // reader_ctx pointing at freed memory once the reader is gone) --
        // or race the snapshot itself, corrupting read_conditions's
        // internal ArrayList fields with no synchronization at all. Holding
        // a quiesce reference across trackReadCondition() below guarantees
        // reallyDeinit() (which only runs once the last reference is
        // released) can't observe a half-updated list, and can't run at
        // all until this create has either tracked the condition or given
        // up -- so it's always still in the loop reallyDeinit() sees when
        // teardown didn't already win the race.
        if (!self.quiesce.acquire()) return nil.nil_readcondition;
        defer self.quiesce.release(self, reallyDeinit);
        const rc = waitset.ReadConditionImpl.init(
            self.alloc,
            self.toDDSDataReader(),
            sample_states,
            view_states,
            instance_states,
            hasPendingDataFn,
            self,
            addDataNotifier,
            removeDataNotifier,
            removeReadCondition,
            readerQuiesceAcquire,
            readerQuiesceRelease,
        ) catch return nil.nil_readcondition;
        if (!self.trackReadCondition(rc.toCondition())) {
            rc.deinit();
            return nil.nil_readcondition;
        }
        return rc.toDDSReadCondition();
    }

    fn vtCreateQueryCondition(
        ctx: *anyopaque,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
        query_expression: [*:0]const u8,
        query_parameters: ?*const DDS.StringSeq,
    ) DDS.QueryCondition {
        const self = cast(ctx);
        const qe_s = std.mem.span(query_expression);
        // A non-empty expression requires field-level access to evaluate.
        // If no TypeSupport is registered for this reader's type, the filter
        // cannot be evaluated and would silently pass every sample.  Return NIL
        // rather than creating a condition that does nothing.
        if (qe_s.len > 0 and self.get_field_fn == null)
            return nil.nil_querycondition;
        // See vtCreateReadCondition's comment: same race, same fix.
        if (!self.quiesce.acquire()) return nil.nil_querycondition;
        defer self.quiesce.release(self, reallyDeinit);
        const empty_seq = DDS.StringSeq{};
        const qc = waitset.QueryConditionImpl.init(
            self.alloc,
            self.toDDSDataReader(),
            sample_states,
            view_states,
            instance_states,
            qe_s,
            if (query_parameters) |p| p.* else empty_seq,
            hasPendingDataFn,
            self,
            addDataNotifier,
            removeDataNotifier,
            removeReadCondition,
            readerQuiesceAcquire,
            readerQuiesceRelease,
        ) catch return nil.nil_querycondition;
        if (!self.trackReadCondition(qc.toCondition())) {
            qc.deinit();
            return nil.nil_querycondition;
        }
        return qc.toDDSQueryCondition();
    }

    /// Records a newly-created ReadCondition/QueryCondition so reallyDeinit()
    /// can tear it down safely if the app deletes this reader without first
    /// calling delete_readcondition() on it. Returns false on allocation
    /// failure -- the caller must not hand the condition back to the app in
    /// that case (see vtCreateReadCondition/vtCreateQueryCondition): an
    /// untracked condition would survive the reader's own teardown holding
    /// a reader_ctx/remove_notify_fn pointing at freed memory, since nothing
    /// would tear it down along with the reader.
    fn trackReadCondition(self: *Self, cond: DDS.Condition) bool {
        self.mu.lock();
        defer self.mu.unlock();
        self.read_conditions.append(self.alloc, cond) catch return false;
        return true;
    }

    /// Called by ReadConditionImpl/QueryConditionImpl's own deinit() — not by
    /// vtDeleteReadCondition directly — so this list stays correct whether a
    /// condition is destroyed via delete_readcondition() or a direct
    /// .deinit() call on the handle (both are valid; WaitSet/GuardCondition
    /// have no "delete" op at all and are only ever destroyed the latter way).
    /// ctx is a *DataReaderImpl; ptr matches a tracked DDS.Condition's own .ptr.
    pub fn removeReadCondition(ctx: *anyopaque, cond_ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.read_conditions.items, 0..) |c, i| {
            if (c.ptr == cond_ptr) {
                _ = self.read_conditions.swapRemove(i);
                return;
            }
        }
    }

    fn vtDeleteReadCondition(_: *anyopaque, a_condition: DDS.ReadCondition) DDS.ReturnCode_t {
        // Destroy the condition via its vtable — ReadConditionImpl.deinit()/
        // QueryConditionImpl.deinit() hold the owning reader's quiesce
        // reference themselves now (see waitset.zig), so this call can't
        // race reallyDeinit()'s bulk loop regardless of caller -- no guard
        // needed at this specific call site anymore. Also detaches from any
        // WaitSet that still has it attached and removes it from this
        // reader's read_conditions tracking list.
        a_condition.deinit();
        return DDS.RETCODE_OK;
    }

    fn vtDeleteContained(_: *anyopaque) DDS.ReturnCode_t {
        return DDS.RETCODE_OK;
    }

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.DataReaderQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.qos.deinit(self.alloc);
        self.qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.DataReaderQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.DataReaderListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.swapListener(if (a_listener) |l| l.* else DDS.noop_DataReaderListener);
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.DataReaderListener {
        const self = cast(ctx);
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.listener;
    }

    /// Installs `new_listener`, releasing whatever it replaces. Safe against
    /// a concurrently in-flight dispatch acquired via `acquireListener` (see
    /// listener_box.zig) — the entity's own "installed" reference is what
    /// gets dropped here; an in-flight dispatch's own extra reference keeps
    /// the old box (and its native context) alive until that dispatch
    /// finishes and releases it.
    fn swapListener(self: *Self, new_listener: DDS.DataReaderListener) void {
        const new_box = ListenerBox(DDS.DataReaderListener).create(self.alloc, new_listener) catch
            @panic("zzdds: out of memory boxing listener");
        self.listener_mu.lock();
        const old_box = self.listener_box;
        self.listener_box = new_box;
        self.listener_mu.unlock();
        old_box.releaseRef(self.alloc);
    }

    /// Call with no lock held. Returns a box the caller may safely read/
    /// dispatch through with no lock held; must call `releaseRef` on it when
    /// done (see listener_box.zig). `pub`: also used by `subscriber.zig`'s
    /// coherent-access batch dispatch, which snapshots multiple readers'
    /// listeners under `subscriber.mu` before firing any of them.
    pub fn acquireListener(self: *Self) *ListenerBox(DDS.DataReaderListener) {
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.acquireLocked();
    }

    /// Dispatches `field` (a `DDS.DataReaderListener` callback) if this
    /// reader's own listener has one installed and `self.listener_mask`
    /// includes `bit`; otherwise walks the DDS 1.4 §2.2.4.1.5 "nearest
    /// enclosing non-null listener" chain: this reader's Subscriber, then
    /// its DomainParticipant (see `subscriber.zig`'s
    /// `dispatchReaderFallback`). `handle` is always this reader's own
    /// C-ABI handle, regardless of which level's listener actually ends up
    /// running (per spec — the callback receives the entity whose status
    /// changed, not the entity whose listener happened to fire). `pub`:
    /// also used by `subscriber.zig`'s `notify_datareaders()`, which is a
    /// different spec operation but the identical "does this reader have a
    /// usable `on_data_available` listener" question.
    ///
    /// Returns `true` iff some level in the chain actually had a usable
    /// listener and it was invoked — callers that reset per-status change-
    /// counters (`_total_change`/`status_changes`) on delivery must gate
    /// that reset on this return value, not on `self.listener_mask` alone:
    /// a reader with no listener installed can still have its event
    /// consumed by its Subscriber's or DomainParticipant's listener, and
    /// *that* delivery is what the change-counters need to track.
    pub fn dispatchListener(self: *Self, comptime field: []const u8, bit: DDS.StatusMask, handle: *anyopaque, args: anytype) bool {
        const box = self.acquireListener();
        defer box.releaseRef(self.alloc);
        if (listener_fallback.tryDispatch(field, self.listener_mask, bit, box.listener, handle, args)) return true;
        if (nil.isNil(self.subscriber)) return false;
        const sub: *subscriber_mod.SubscriberImpl = @ptrCast(@alignCast(self.subscriber.ptr));
        return sub.dispatchReaderFallback(field, bit, handle, args);
    }

    fn vtGetTopicDesc(ctx: *anyopaque) DDS.TopicDescription {
        return cast(ctx).topic_desc;
    }

    fn vtGetSubscriber(ctx: *anyopaque) DDS.Subscriber {
        return cast(ctx).subscriber;
    }

    fn vtGetSampleRejected(ctx: *anyopaque, status: *DDS.SampleRejectedStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        status.* = .{
            .total_count = self.sample_rejected_total,
            .total_count_change = self.sample_rejected_total_change,
            .last_reason = self.sample_rejected_last_reason,
            .last_instance_handle = self.sample_rejected_last_handle,
        };
        self.sample_rejected_total_change = 0;
        self.status_changes &= ~DDS.SAMPLE_REJECTED_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtGetLivelinessChanged(ctx: *anyopaque, status: *DDS.LivelinessChangedStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        status.* = .{
            .alive_count = self.liveliness_alive_count,
            .not_alive_count = self.liveliness_not_alive_count,
            .alive_count_change = self.liveliness_alive_count_change,
            .not_alive_count_change = self.liveliness_not_alive_count_change,
            .last_publication_handle = self.liveliness_last_handle,
        };
        self.liveliness_alive_count_change = 0;
        self.liveliness_not_alive_count_change = 0;
        self.status_changes &= ~DDS.LIVELINESS_CHANGED_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtGetDeadlineMissed(ctx: *anyopaque, status: *DDS.RequestedDeadlineMissedStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
        status.* = .{
            .total_count = self.deadline_missed_total,
            .total_count_change = self.deadline_missed_total_change,
        };
        self.deadline_missed_total_change = 0;
        self.status_changes &= ~DDS.REQUESTED_DEADLINE_MISSED_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtGetIncompatQos(ctx: *anyopaque, status: *DDS.RequestedIncompatibleQosStatus) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        status.* = .{
            .total_count = self.incompat_total.load(.monotonic),
            .total_count_change = self.incompat_total_change,
            .last_policy_id = self.incompat_last_policy,
        };
        self.incompat_total_change = 0;
        self.status_changes &= ~DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtGetSubMatched(ctx: *anyopaque, status: *DDS.SubscriptionMatchedStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        status.* = .{
            .total_count = self.sub_matched_total,
            .total_count_change = self.sub_matched_total_change,
            .current_count = self.sub_matched_current,
            .current_count_change = self.sub_matched_current_change,
            .last_publication_handle = self.sub_matched_last_handle,
        };
        self.sub_matched_total_change = 0;
        self.sub_matched_current_change = 0;
        self.status_changes &= ~DDS.SUBSCRIPTION_MATCHED_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtGetSampleLost(ctx: *anyopaque, status: *DDS.SampleLostStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        status.* = .{
            .total_count = self.sample_lost_total,
            .total_count_change = self.sample_lost_total_change,
        };
        self.sample_lost_total_change = 0;
        self.status_changes &= ~DDS.SAMPLE_LOST_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtWaitForHistorical(ctx: *anyopaque, max_wait: *const DDS.Duration_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        if (self.qos.durability.kind == .VOLATILE_DURABILITY_QOS) return DDS.RETCODE_OK;

        const POLL_NS: i64 = 1_000_000; // 1 ms
        const deadline_ns: ?i64 = if (max_wait.sec == DDS.DURATION_INFINITE_SEC and
            max_wait.nanosec == DDS.DURATION_INFINITE_NSEC)
            null
        else blk: {
            break :blk self.timer_clock.nowNs() +
                @as(i64, max_wait.sec) * std.time.ns_per_s +
                @as(i64, max_wait.nanosec);
        };

        while (true) {
            if (self.proto_reader.historicalDelivered()) return DDS.RETCODE_OK;
            if (deadline_ns) |dl| {
                if (self.timer_clock.nowNs() >= dl) return DDS.RETCODE_TIMEOUT;
            }
            self.timer_clock.sleepNs(POLL_NS);
        }
    }

    fn vtGetMatchedPubs(ctx: *anyopaque, handles: ?*DDS.InstanceHandleSeq) DDS.ReturnCode_t {
        const seq = handles orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        var guids: std.ArrayListUnmanaged(Guid) = .empty;
        defer guids.deinit(self.alloc);
        self.proto_reader.listMatchedWriters(self.alloc, &guids) catch
            return DDS.RETCODE_OUT_OF_RESOURCES;
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const n = guids.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.alloc(DDS.InstanceHandle_t, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (guids.items, 0..) |guid, i| buf[i] = writer_mod.guidToHandle(guid);
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
        return DDS.RETCODE_OK;
    }

    fn vtGetMatchedPubData(ctx: *anyopaque, data: *DDS.PublicationBuiltinTopicData, handle: DDS.InstanceHandle_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        var guids: std.ArrayListUnmanaged(Guid) = .empty;
        defer guids.deinit(self.alloc);
        self.proto_reader.listMatchedWriters(self.alloc, &guids) catch
            return DDS.RETCODE_BAD_PARAMETER;
        for (guids.items) |guid| {
            if (writer_mod.guidToHandle(guid) == handle) {
                data.* = .{};
                data.key = writer_mod.guidToBuiltinKey(guid);
                data.topic_name = self.topic_desc.get_name();
                data.type_name = self.topic_desc.get_type_name();
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    // ── status helper for StatusConditionImpl ─────────────────────────────────

    fn getStatusFn(entity_ptr: *anyopaque) DDS.StatusMask {
        return cast(entity_ptr).status_changes;
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// ── Unit tests ────────────────────────────────────────────────────────────────

const testing = std.testing;
const time_test = @import("../util/time.zig");

test "coherent WIP: HB before last DATA still flushes via flush_target_sn" {
    // Reproduces the race: endCoherentSet sends ONE HB with last_sn = N+2 (the
    // last coherent SN), but the HB arrives before DATA N+2.  The writer then
    // writes a non-coherent N+3; every subsequent HB has last_sn >= N+3.
    // Without flush_target_sn the WIP hangs; with it, DATA N+2 triggers the flush.
    const alloc = testing.allocator;

    var clock = time_test.ManualClock.init(0);
    const pres = DDS.PresentationQosPolicy{ .coherent_access = true };

    var dr = DataReaderImpl{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .subscriber_presentation = pres,
        .seen_instances = .empty,
    };
    defer {
        var it = dr.coherent_wip.valueIterator();
        while (it.next()) |e| {
            for (e.samples.items) |pc| pc.deinit();
            e.samples.deinit(alloc);
        }
        dr.coherent_wip.deinit(alloc);
        for (dr.coherent_committed.items) |*set| {
            for (set.items) |pc| pc.deinit();
            set.deinit(alloc);
        }
        dr.coherent_committed.deinit(alloc);
        {
            var _si = dr.seen_instances.valueIterator();
            while (_si.next()) |_e| if (_e.key_cdr) |_kc| alloc.free(_kc);
        }
        dr.seen_instances.deinit(alloc);
        dr.listener_box.releaseRef(alloc);
    }

    const writer_guid = @import("../rtps/guid.zig").Guid{
        .prefix = .{ .bytes = [_]u8{0xAA} ** 12 },
        .entity_id = @import("../rtps/guid.zig").EntityIds.sedp_builtin_publications_writer,
    };

    // Simulate two coherent samples (SN 1 and 2) in WIP.
    // highest_sn = 1 (SN 2 DATA hasn't arrived yet).
    var entry = CoherentWipEntry{ .cs = 1, .highest_sn = 1 };
    const d1 = try alloc.dupe(u8, &.{0x01});
    try entry.samples.append(alloc, PendingChange{
        .data = d1,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = 1, .valid_data = true },
    });
    try dr.coherent_wip.put(alloc, writer_guid, entry);

    // HB arrives with last_sn=2 but highest_sn=1 — sets flush_target_sn=2, no flush yet.
    DataReaderImpl.onHeartbeatCb(@ptrCast(&dr), writer_guid, 2);
    {
        const e = dr.coherent_wip.get(writer_guid).?;
        try testing.expectEqual(@as(?history_mod.SequenceNumber, 2), e.flush_target_sn);
        try testing.expectEqual(@as(usize, 0), dr.coherent_committed.items.len);
    }

    // Non-coherent write at SN 3: subsequent HBs carry last_sn=3.
    // This HB must NOT flush (highest_sn=1 < 3) but must keep flush_target_sn=min(2,3)=2.
    DataReaderImpl.onHeartbeatCb(@ptrCast(&dr), writer_guid, 3);
    {
        const e = dr.coherent_wip.get(writer_guid).?;
        try testing.expectEqual(@as(?history_mod.SequenceNumber, 2), e.flush_target_sn);
        try testing.expectEqual(@as(usize, 0), dr.coherent_committed.items.len);
    }

    // DATA SN 2 arrives — advances highest_sn to 2 which equals flush_target_sn → flush.
    {
        const e = dr.coherent_wip.getPtr(writer_guid).?;
        if (2 > e.highest_sn) e.highest_sn = 2;
        const data_committed = if (e.flush_target_sn) |target|
            if (e.highest_sn >= target) blk: {
                const kv = dr.coherent_wip.fetchRemove(writer_guid).?;
                break :blk dr.commitCoherentWipSamplesLocked(kv.value.samples);
            } else false
        else
            false;
        try testing.expect(data_committed);
    }
    try testing.expectEqual(@as(usize, 0), dr.coherent_wip.count());
    try testing.expect(dr.coherent_committed_ready);
}

test "coherent WIP: CS transition discards incomplete previous WIP" {
    // Covers the discard branch (lines 606-610): when a new coherent set arrives
    // while the previous WIP has flush_target_sn set (incomplete), the previous
    // set is discarded rather than committed to preserve the coherency guarantee.
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const pres = DDS.PresentationQosPolicy{ .coherent_access = true };
    var dr = DataReaderImpl{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .subscriber_presentation = pres,
        .seen_instances = .empty,
    };
    defer {
        var it = dr.coherent_wip.valueIterator();
        while (it.next()) |e| {
            for (e.samples.items) |pc| pc.deinit();
            e.samples.deinit(alloc);
        }
        dr.coherent_wip.deinit(alloc);
        for (dr.coherent_committed.items) |*set| {
            for (set.items) |pc| pc.deinit();
            set.deinit(alloc);
        }
        dr.coherent_committed.deinit(alloc);
        {
            var _si = dr.seen_instances.valueIterator();
            while (_si.next()) |_e| if (_e.key_cdr) |_kc| alloc.free(_kc);
        }
        dr.seen_instances.deinit(alloc);
        dr.listener_box.releaseRef(alloc);
        dr.coherent_writer_guids.deinit(alloc);
        var wit = dr.writer_instances.valueIterator();
        while (wit.next()) |v| v.deinit(alloc);
        dr.writer_instances.deinit(alloc);
    }

    const guid_mod = @import("../rtps/guid.zig");
    const writer_guid = guid_mod.Guid{
        .prefix = .{ .bytes = [_]u8{0xCC} ** 12 },
        .entity_id = guid_mod.EntityIds.sedp_builtin_publications_writer,
    };

    // Seed a WIP entry with CS=1, one sample, flush_target_sn=5 (highest_sn=1 < 5 → incomplete).
    var entry = CoherentWipEntry{ .cs = 1, .highest_sn = 1, .flush_target_sn = 5 };
    const d1 = try alloc.dupe(u8, &.{0x01});
    try entry.samples.append(alloc, PendingChange{
        .data = d1,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = 1, .valid_data = true },
    });
    try dr.coherent_wip.put(alloc, writer_guid, entry);

    // CS=10 DATA arrives — triggers CS transition; prev (CS=1) is incomplete → discard.
    const change = history_mod.CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 10,
        .source_timestamp = .{ .seconds = 0, .fraction = 0 },
        .instance_handle = std.mem.zeroes(history_mod.InstanceHandle),
        .key_hash = std.mem.zeroes([16]u8),
        .data = &.{0x02},
        .coherent_set_sn = 10,
    };
    DataReaderImpl.onDataCb(@ptrCast(&dr), &change);

    try testing.expectEqual(@as(usize, 0), dr.coherent_committed.items.len);
    const e = dr.coherent_wip.get(writer_guid).?;
    try testing.expectEqual(@as(history_mod.SequenceNumber, 10), e.cs);
}

test "coherent WIP: flush_target_sn triggers flush when DATA reaches target SN" {
    // Covers lines 624-626: onDataCb advances highest_sn and flushes when it
    // reaches flush_target_sn that was previously set by a HEARTBEAT.
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const pres = DDS.PresentationQosPolicy{ .coherent_access = true };
    var dr = DataReaderImpl{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .subscriber_presentation = pres,
        .seen_instances = .empty,
    };
    defer {
        // dispatchListener() (DDS 1.4 §2.2.4.1.5 fallback) always resolves
        // this reader's own C-ABI handle before checking whether any level
        // in the chain has a usable listener -- unlike this test's
        // `nil.nil_dr_listener`/`listener_mask = 0`, which previously meant
        // `get_c_abi_handle` was never reached at all. Free the resulting
        // cached box the same way every real `deinit()` does.
        dr.c_abi.free(alloc);
        var it = dr.coherent_wip.valueIterator();
        while (it.next()) |e| {
            for (e.samples.items) |pc| pc.deinit();
            e.samples.deinit(alloc);
        }
        dr.coherent_wip.deinit(alloc);
        for (dr.coherent_committed.items) |*set| {
            for (set.items) |pc| pc.deinit();
            set.deinit(alloc);
        }
        dr.coherent_committed.deinit(alloc);
        {
            var _si = dr.seen_instances.valueIterator();
            while (_si.next()) |_e| if (_e.key_cdr) |_kc| alloc.free(_kc);
        }
        dr.seen_instances.deinit(alloc);
        dr.listener_box.releaseRef(alloc);
        dr.coherent_writer_guids.deinit(alloc);
        var wit = dr.writer_instances.valueIterator();
        while (wit.next()) |v| v.deinit(alloc);
        dr.writer_instances.deinit(alloc);
    }

    const guid_mod = @import("../rtps/guid.zig");
    const writer_guid = guid_mod.Guid{
        .prefix = .{ .bytes = [_]u8{0xDD} ** 12 },
        .entity_id = guid_mod.EntityIds.sedp_builtin_publications_writer,
    };

    // Seed WIP: CS=5, one sample (SN=1) already received, flush_target_sn=2.
    var entry = CoherentWipEntry{ .cs = 5, .highest_sn = 1, .flush_target_sn = 2 };
    const d1 = try alloc.dupe(u8, &.{0x01});
    try entry.samples.append(alloc, PendingChange{
        .data = d1,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = 1, .valid_data = true },
    });
    try dr.coherent_wip.put(alloc, writer_guid, entry);

    // DATA SN=2 (same CS=5) arrives — highest_sn reaches flush_target_sn → flush.
    const change = history_mod.CacheChange{
        .kind = .alive,
        .writer_guid = writer_guid,
        .sequence_number = 2,
        .source_timestamp = .{ .seconds = 0, .fraction = 0 },
        .instance_handle = std.mem.zeroes(history_mod.InstanceHandle),
        .key_hash = std.mem.zeroes([16]u8),
        .data = &.{0x02},
        .coherent_set_sn = 5,
    };
    DataReaderImpl.onDataCb(@ptrCast(&dr), &change);

    try testing.expectEqual(@as(usize, 0), dr.coherent_wip.count());
    try testing.expectEqual(@as(usize, 1), dr.coherent_committed.items.len);
}

test "takeRaw: expired LIFESPAN sample is silently discarded" {
    // Covers lines 1105-1107: a sample whose expiry_ns has passed is removed
    // from pending and takeRaw returns null rather than a stale sample.
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    var dr = DataReaderImpl{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };
    defer {
        for (dr.pending.items) |pc| pc.deinit();
        dr.pending.deinit(alloc);
        dr.coherent_wip.deinit(alloc);
        dr.coherent_committed.deinit(alloc);
        {
            var _si = dr.seen_instances.valueIterator();
            while (_si.next()) |_e| if (_e.key_cdr) |_kc| alloc.free(_kc);
        }
        dr.seen_instances.deinit(alloc);
        dr.listener_box.releaseRef(alloc);
    }

    const d = try alloc.dupe(u8, &.{0xAA});
    try dr.pending.append(alloc, PendingChange{
        .data = d,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = 1, .valid_data = true },
        .expiry_ns = 1, // nanosecond 1 — far in the past
    });

    try testing.expect(dr.takeRaw() == null);
    try testing.expectEqual(@as(usize, 0), dr.pending.items.len);
}

fn mkTestReaderForGenerationTests(alloc: std.mem.Allocator, clock: *time_test.ManualClock) DataReaderImpl {
    return DataReaderImpl{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener) catch unreachable,
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };
}

fn deinitTestReader(dr: *DataReaderImpl, alloc: std.mem.Allocator) void {
    for (dr.pending.items) |pc| pc.deinit();
    dr.pending.deinit(alloc);
    dr.coherent_wip.deinit(alloc);
    dr.coherent_committed.deinit(alloc);
    {
        var _si = dr.seen_instances.valueIterator();
        while (_si.next()) |_e| if (_e.key_cdr) |_kc| alloc.free(_kc);
    }
    dr.seen_instances.deinit(alloc);
    dr.listener_box.releaseRef(alloc);
}

test "determineStatesLocked: disposed_generation_count increments only on resurrection from DISPOSED" {
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    var dr = mkTestReaderForGenerationTests(alloc, &clock);
    defer deinitTestReader(&dr, alloc);

    const ih: DDS.InstanceHandle_t = 1;

    const s1 = dr.determineStatesLocked(ih, .alive);
    try testing.expectEqual(@as(i32, 0), s1.disposed_generation_count);
    try testing.expectEqual(@as(i32, 0), s1.no_writers_generation_count);

    // Disposing does not itself bump the counter — only resurrection does.
    const s2 = dr.determineStatesLocked(ih, .not_alive_disposed);
    try testing.expectEqual(@as(i32, 0), s2.disposed_generation_count);

    const s3 = dr.determineStatesLocked(ih, .alive);
    try testing.expectEqual(DDS.NEW_VIEW_STATE, s3.view);
    try testing.expectEqual(@as(i32, 1), s3.disposed_generation_count);
    try testing.expectEqual(@as(i32, 0), s3.no_writers_generation_count);
}

test "determineStatesLocked: no_writers_generation_count increments only on resurrection from NO_WRITERS" {
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    var dr = mkTestReaderForGenerationTests(alloc, &clock);
    defer deinitTestReader(&dr, alloc);

    const ih: DDS.InstanceHandle_t = 2;

    _ = dr.determineStatesLocked(ih, .alive);
    const s2 = dr.determineStatesLocked(ih, .not_alive_unregistered);
    try testing.expectEqual(@as(i32, 0), s2.no_writers_generation_count);

    const s3 = dr.determineStatesLocked(ih, .alive);
    try testing.expectEqual(DDS.NEW_VIEW_STATE, s3.view);
    try testing.expectEqual(@as(i32, 0), s3.disposed_generation_count);
    try testing.expectEqual(@as(i32, 1), s3.no_writers_generation_count);
}

test "readRaw: sample_rank/generation_rank/absolute_generation_rank span a generation boundary in one batch" {
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    var dr = mkTestReaderForGenerationTests(alloc, &clock);
    defer deinitTestReader(&dr, alloc);

    const ih: DDS.InstanceHandle_t = 7;

    // Three samples for the same instance, spanning one dispose/resurrect cycle:
    // gen 0 (alive) -> gen 0 (dispose) -> gen 1 (alive again).
    const d0 = try alloc.dupe(u8, &.{0x00});
    try dr.pending.append(alloc, PendingChange{
        .data = d0,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = ih, .valid_data = true, .disposed_generation_count = 0, .no_writers_generation_count = 0 },
    });
    const d1 = try alloc.dupe(u8, &.{});
    try dr.pending.append(alloc, PendingChange{
        .data = d1,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NOT_NEW_VIEW_STATE, .instance_state = DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE, .instance_handle = ih, .valid_data = false, .disposed_generation_count = 0, .no_writers_generation_count = 0 },
    });
    const d2 = try alloc.dupe(u8, &.{0x02});
    try dr.pending.append(alloc, PendingChange{
        .data = d2,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = ih, .valid_data = true, .disposed_generation_count = 1, .no_writers_generation_count = 0 },
    });

    // Live instance state matches the most recent (highest-generation) sample.
    try dr.seen_instances.put(alloc, ih, .{ .instance_state = DDS.ALIVE_INSTANCE_STATE, .disposed_generation_count = 1, .no_writers_generation_count = 0 });

    var out: std.ArrayListUnmanaged(TakenSample) = .empty;
    defer {
        for (out.items) |s| alloc.free(s.data);
        out.deinit(alloc);
    }
    try dr.readRaw(&out, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE, -1, null, null);

    try testing.expectEqual(@as(usize, 3), out.items.len);

    try testing.expectEqual(@as(i32, 2), out.items[0].info.sample_rank);
    try testing.expectEqual(@as(i32, 1), out.items[0].info.generation_rank);
    try testing.expectEqual(@as(i32, 1), out.items[0].info.absolute_generation_rank);

    try testing.expectEqual(@as(i32, 1), out.items[1].info.sample_rank);
    try testing.expectEqual(@as(i32, 1), out.items[1].info.generation_rank);
    try testing.expectEqual(@as(i32, 1), out.items[1].info.absolute_generation_rank);

    try testing.expectEqual(@as(i32, 0), out.items[2].info.sample_rank);
    try testing.expectEqual(@as(i32, 0), out.items[2].info.generation_rank);
    try testing.expectEqual(@as(i32, 0), out.items[2].info.absolute_generation_rank);
}

test "takeRaw: absolute_generation_rank reflects live generation ahead of a stale queued sample" {
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    var dr = mkTestReaderForGenerationTests(alloc, &clock);
    defer deinitTestReader(&dr, alloc);

    const ih: DDS.InstanceHandle_t = 9;
    const d = try alloc.dupe(u8, &.{0xAA});
    try dr.pending.append(alloc, PendingChange{
        .data = d,
        .alloc = alloc,
        .info = .{ .sample_state = DDS.NOT_READ_SAMPLE_STATE, .view_state = DDS.NEW_VIEW_STATE, .instance_state = DDS.ALIVE_INSTANCE_STATE, .instance_handle = ih, .valid_data = true, .disposed_generation_count = 0, .no_writers_generation_count = 0 },
    });
    // Instance has since disposed and resurrected once more, advancing the live count
    // past what this still-queued sample was stamped with at receipt time.
    try dr.seen_instances.put(alloc, ih, .{ .instance_state = DDS.ALIVE_INSTANCE_STATE, .disposed_generation_count = 1, .no_writers_generation_count = 0 });

    const taken = dr.takeRaw() orelse return error.TestExpectedNonNull;
    defer alloc.free(taken.data);
    try testing.expectEqual(@as(i32, 0), taken.info.sample_rank);
    try testing.expectEqual(@as(i32, 0), taken.info.generation_rank);
    try testing.expectEqual(@as(i32, 1), taken.info.absolute_generation_rank);
}

test "vtCreateReadCondition: a condition tracked while deinit() is racing is still torn down, not left dangling" {
    // Regression for a real race Greptile flagged on zzdds PR #60: without
    // vtCreateReadCondition holding a quiesce reference across its own
    // trackReadCondition() append, a create racing this reader's own
    // deinit() could track a new condition into read_conditions *after*
    // reallyDeinit() already snapshotted-and-cleared it -- left un-torn-
    // down, holding a reader_ctx pointing at freed memory the moment the
    // reader itself finished tearing down.
    //
    // A real two-thread version of this test isn't safe: an unsynchronized
    // delete_datareader() can legitimately win outright and free the whole
    // reader before a spawned thread doing the create is even scheduled --
    // a different, and for a raw handle with no other synchronization
    // fundamentally unfixable, hazard, not the one this fix addresses
    // (confirmed directly: a real-thread version of this test segfaulted on
    // quiesce.acquire() dereferencing an already-freed reader even with the
    // fix in place). Driving the exact interleaving deterministically by
    // hand -- mirroring vtCreateReadCondition's own acquire()/track/release
    // sequence -- tests the actual mechanism without depending on OS thread
    // scheduling luck, and without ever risking a genuinely dangling `dr`.
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const dr = try alloc.create(DataReaderImpl);
    dr.* = .{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };

    // Simulate vtCreateReadCondition's opening move: a create call has
    // validly entered (dr is still fully alive -- nothing has started
    // tearing it down yet) and successfully acquired a quiesce reference.
    try testing.expect(dr.quiesce.acquire());

    // Now race in the reader's own deinit(). Our simulated create above
    // still holds a reference, so this must NOT free `dr` yet -- if it did,
    // everything below would be a use-after-free.
    dr.deinit();

    // Simulate the rest of vtCreateReadCondition: build a real condition
    // and track it, exactly like trackReadCondition() does (inlined here
    // rather than calling it directly, to also exercise mu locking exactly
    // as production code does).
    const rc = try waitset.ReadConditionImpl.init(
        alloc,
        dr.toDDSDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        DataReaderImpl.hasPendingDataFn,
        dr,
        DataReaderImpl.addDataNotifier,
        DataReaderImpl.removeDataNotifier,
        DataReaderImpl.removeReadCondition,
        DataReaderImpl.readerQuiesceAcquire,
        DataReaderImpl.readerQuiesceRelease,
    );
    dr.mu.lock();
    try dr.read_conditions.append(alloc, rc.toCondition());
    dr.mu.unlock();

    // Release our simulated create's reference -- the last one outstanding
    // (deinit() already dropped its own), so this must synchronously
    // trigger reallyDeinit() now, which must find and tear down the
    // condition just tracked above.
    dr.quiesce.release(dr, DataReaderImpl.reallyDeinit);

    // If reallyDeinit() had incorrectly already run before the track above
    // (the bug this regresses), this test would already have use-after-freed
    // `dr` and leaked `rc` -- testing.allocator's DebugAllocator catches
    // both.
}

test "vtDeleteReadCondition: winning the race removes the condition before reallyDeinit's bulk loop can double-free it" {
    // Delete-side half of the same Greptile finding as the create-side test
    // above: without vtDeleteReadCondition holding a quiesce reference
    // across its own delete, reallyDeinit()'s bulk loop (from its own
    // already-taken read_conditions snapshot) and an explicit
    // delete_readcondition() call could independently decide to free the
    // same condition -- a double free.
    //
    // Driven deterministically for the same reason as the create-side test:
    // a real-thread version of this test also segfaults on
    // quiesce.acquire() dereferencing an already-freed reader whenever
    // delete_datareader() happens to win outright before the spawned
    // thread's delete_readcondition() call is even scheduled -- confirmed
    // directly, not hypothetically -- which is a different, out-of-scope
    // hazard, not the double-free this fix addresses.
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const dr = try alloc.create(DataReaderImpl);
    dr.* = .{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };

    // Create and track a real condition up front -- single-threaded, no
    // race yet. This is the condition both "sides" below race to free.
    const rc = try waitset.ReadConditionImpl.init(
        alloc,
        dr.toDDSDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        DataReaderImpl.hasPendingDataFn,
        dr,
        DataReaderImpl.addDataNotifier,
        DataReaderImpl.removeDataNotifier,
        DataReaderImpl.removeReadCondition,
        DataReaderImpl.readerQuiesceAcquire,
        DataReaderImpl.readerQuiesceRelease,
    );
    try dr.read_conditions.append(alloc, rc.toCondition());

    // Simulate vtDeleteReadCondition's opening move: a delete call has
    // validly entered (dr is still fully alive) and successfully acquired.
    try testing.expect(dr.quiesce.acquire());

    // Race in the reader's own deinit(). Our simulated delete above still
    // holds a reference, so this must NOT free `dr` (or touch `rc`) yet.
    dr.deinit();

    // Simulate the rest of vtDeleteReadCondition: actually delete the
    // condition. This removes it from dr.read_conditions (via
    // ReadConditionImpl.deinit() -> remove_condition_fn ->
    // removeReadCondition, mu-locked) and frees it.
    rc.toCondition().deinit();

    // Release our simulated delete's reference -- the last one outstanding
    // (deinit() already dropped its own), so this must synchronously
    // trigger reallyDeinit() now. Its bulk loop must find read_conditions
    // already empty (rc removed itself above) and must not try to free
    // `rc` a second time.
    dr.quiesce.release(dr, DataReaderImpl.reallyDeinit);

    // If reallyDeinit() had incorrectly also tried to free `rc` above (the
    // bug this regresses), this would be a double free --
    // testing.allocator's DebugAllocator catches it.
}

// The two tests above simulate vtCreateReadCondition's/vtDeleteReadCondition's
// own acquire()/…/release() sequence by hand -- they prove the *protocol*
// (quiesce coordination + read_conditions bookkeeping) is correct if
// followed, but calling dr.quiesce.acquire() directly means they'd still
// pass even if the real guard were deleted from those two functions. The
// two tests below close that gap: they call the real, public
// create_readcondition()/delete_readcondition() and check the guard is
// actually there, using a spare held reference (rather than a second
// thread) to keep `dr` alive past deinit() without ever risking the
// already-freed-pointer hazard explained above.

test "vtCreateReadCondition: refuses to create once reader teardown has started" {
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const dr = try alloc.create(DataReaderImpl);
    dr.* = .{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };

    // Hold a spare reference so deinit() below sets the tearing-down flag
    // without being able to free `dr` out from under this test yet.
    try testing.expect(dr.quiesce.acquire());
    dr.deinit();

    // With the fix, create_readcondition() must see the tearing-down flag
    // and refuse -- returning nil without ever touching read_conditions.
    // Without it, it would construct and track a real condition anyway
    // (dr.mu/read_conditions are still perfectly valid memory here, thanks
    // to the spare reference above), which no later snapshot could ever
    // find or tear down once this test's own release drops the reference.
    const rc = dr.toDDSDataReader().create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    try testing.expectEqual(nil.nil_readcondition.ptr, rc.ptr);
    try testing.expectEqual(@as(usize, 0), dr.read_conditions.items.len);

    // Release the spare reference -- the last one outstanding, so this
    // correctly and synchronously tears `dr` down now.
    dr.quiesce.release(dr, DataReaderImpl.reallyDeinit);
}

test "vtDeleteReadCondition: backs off entirely once reader teardown has started" {
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const dr = try alloc.create(DataReaderImpl);
    dr.* = .{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };

    // Create and track a real condition up front, single-threaded.
    const rc = try waitset.ReadConditionImpl.init(
        alloc,
        dr.toDDSDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        DataReaderImpl.hasPendingDataFn,
        dr,
        DataReaderImpl.addDataNotifier,
        DataReaderImpl.removeDataNotifier,
        DataReaderImpl.removeReadCondition,
        DataReaderImpl.readerQuiesceAcquire,
        DataReaderImpl.readerQuiesceRelease,
    );
    try dr.read_conditions.append(alloc, rc.toCondition());

    // Hold a spare reference so deinit() below sets the tearing-down flag
    // without being able to free `dr` (or tear down `rc` via its own bulk
    // loop) out from under this test yet.
    try testing.expect(dr.quiesce.acquire());
    dr.deinit();

    // With the fix, delete_readcondition() must see the tearing-down flag
    // and back off, touching neither `rc` nor read_conditions at all --
    // leaving `rc` for reallyDeinit()'s own bulk loop to free once this
    // test's release below lets it actually run. Without the fix, this call
    // would free `rc` here itself, and then reallyDeinit()'s bulk loop
    // would try to free the same (now-dangling) entry again.
    _ = dr.toDDSDataReader().delete_readcondition(rc.toDDSReadCondition());
    try testing.expectEqual(@as(usize, 1), dr.read_conditions.items.len);

    dr.quiesce.release(dr, DataReaderImpl.reallyDeinit);
}

test "ReadConditionImpl.deinit: a direct call (bypassing delete_readcondition) also backs off once reader teardown has started" {
    // A second real gap in the same Greptile finding as the two tests
    // above: vtDeleteReadCondition's own guard only covered
    // delete_readcondition() -- a direct `.deinit()` call on the handle is
    // an equally valid, documented way to destroy a condition (see
    // remove_condition_fn's doc comment; a Zig-native caller can reach it
    // without going through the C-ABI's delete_readcondition() at all), and
    // was still completely unguarded. Fixed by moving the guard down into
    // ReadConditionImpl.deinit()/QueryConditionImpl.deinit() themselves, so
    // every caller gets it regardless of entry point. This test is
    // identical to the one above except for calling `.deinit()` straight on
    // the handle instead of going through delete_readcondition().
    const alloc = testing.allocator;
    var clock = time_test.ManualClock.init(0);
    const dr = try alloc.create(DataReaderImpl);
    dr.* = .{
        .alloc = alloc,
        .topic_desc = nil.nil_topic_description,
        .subscriber = nil.nil_subscriber,
        .proto_reader = undefined,
        .qos = .{},
        .listener_box = try ListenerBox(DDS.DataReaderListener).create(alloc, nil.nil_dr_listener),
        .listener_mask = 0,
        .instance_handle = 1,
        .status_changes = 0,
        .status_cond = null,
        .timer_clock = clock.clock(),
        .last_received_ns = .init(clock.clock().nowNs()),
        .data_notifiers = .empty,
        .read_conditions = .empty,
        .pending = .empty,
        .coherent_wip = .{},
        .coherent_committed = .empty,
        .coherent_committed_ready = false,
        .mu = .{},
        .seen_instances = .empty,
    };

    const rc = try waitset.ReadConditionImpl.init(
        alloc,
        dr.toDDSDataReader(),
        DDS.ANY_SAMPLE_STATE,
        DDS.ANY_VIEW_STATE,
        DDS.ANY_INSTANCE_STATE,
        DataReaderImpl.hasPendingDataFn,
        dr,
        DataReaderImpl.addDataNotifier,
        DataReaderImpl.removeDataNotifier,
        DataReaderImpl.removeReadCondition,
        DataReaderImpl.readerQuiesceAcquire,
        DataReaderImpl.readerQuiesceRelease,
    );
    try dr.read_conditions.append(alloc, rc.toCondition());

    try testing.expect(dr.quiesce.acquire());
    dr.deinit();

    // Direct call, not through delete_readcondition()/vtDeleteReadCondition
    // at all -- must still see the tearing-down flag and back off.
    rc.deinit();
    try testing.expectEqual(@as(usize, 1), dr.read_conditions.items.len);

    dr.quiesce.release(dr, DataReaderImpl.reallyDeinit);
}
