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
const nil = @import("nil.zig");
const proto = @import("../protocol/interface.zig");
const history_mod = @import("../rtps/history.zig");
const filter_mod = @import("filter.zig");
const topic_mod = @import("topic.zig");
const waitset = @import("waitset.zig");
const writer_mod = @import("writer.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const time_mod = @import("../util/time.zig");

const Guid = proto.Guid;

/// CFT filter state held on the DataReaderImpl.
/// Non-null only when the reader was created from a ContentFilteredTopic and a
/// get_field function is available for this type.
pub const CftFilterState = struct {
    cft_ptr: *topic_mod.ContentFilteredTopicImpl,
    get_field_fn: *const fn (payload: []const u8, field: []const u8) ?filter_mod.FilterValue,

    pub fn matches(self: *const CftFilterState, payload: []const u8) bool {
        var ctx = FieldCtx{ .payload = payload, .get_fn = self.get_field_fn };
        const accessor = filter_mod.FieldAccessor{
            .ctx = &ctx,
            .get = FieldCtx.get,
        };
        return self.cft_ptr.matchSample(accessor);
    }

    const FieldCtx = struct {
        payload: []const u8,
        get_fn: *const fn ([]const u8, []const u8) ?filter_mod.FilterValue,

        fn get(ctx: *anyopaque, field: []const u8) ?filter_mod.FilterValue {
            const self: *const FieldCtx = @ptrCast(@alignCast(ctx));
            return self.get_fn(self.payload, field);
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

    pub fn deinit(self: PendingChange) void {
        self.alloc.free(self.data);
    }
};

/// Ownership by the caller of data returned from takeRaw().
pub const TakenSample = struct {
    /// Serialized CDR payload; caller must free with the reader's allocator.
    /// Empty slice for NOT_ALIVE_* changes (check info.valid_data).
    data: []u8,
    info: DDS.SampleInfo,
};

/// Per-instance tracking used to compute view_state.
const InstanceEntry = struct {
    instance_state: DDS.InstanceStateKind,
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
    get_field_fn: ?*const fn ([]const u8, []const u8) ?filter_mod.FilterValue,
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
    listener: DDS.DataReaderListener,
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,

    /// Cumulative count of incompatible-QoS events; guarded by `mu`.
    incompat_total: i32 = 0,
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

    /// Pending incoming samples; guarded by `mu`.
    pending: std.ArrayListUnmanaged(PendingChange),
    /// Working buffer for the currently-receiving coherent set.
    /// Samples are appended here as they arrive. When the end marker is received
    /// Keyed by writer GUID so that concurrent coherent sets from different writers
    /// accumulate independently and commit only when each writer's own set is complete.
    coherent_wip: std.AutoHashMapUnmanaged(Guid, std.ArrayListUnmanaged(PendingChange)),
    /// Queue of complete coherent sets awaiting delivery via begin_access().
    /// Each element is one complete set (filled when its end marker arrives).
    /// commitCoherentPendingLocked() pops ONLY the first entry per call so that
    /// each begin_access/end_access cycle exposes exactly one coherent set,
    /// even when multiple sets accumulated during a late-join history replay.
    coherent_committed: std.ArrayListUnmanaged(std.ArrayListUnmanaged(PendingChange)),
    /// True when `coherent_committed` contains at least one complete set.
    coherent_committed_ready: bool,
    mu: Mutex,

    /// Presentation QoS from the owning Subscriber; set once after init.
    subscriber_presentation: DDS.PresentationQosPolicy = .{},

    /// ContentFilteredTopic filter; null when no CFT or no get_field fn registered.
    /// Set once after init by the subscriber; read-only thereafter.
    cft_filter: ?CftFilterState = null,

    /// Field accessor for QueryCondition evaluation at read/take time.
    /// Set from TypeSupport.get_field when available; null otherwise.
    /// Set once after init by the subscriber; read-only thereafter.
    get_field_fn: ?*const fn ([]const u8, []const u8) ?filter_mod.FilterValue = null,

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
            .listener = listener,
            .listener_mask = mask,
            .instance_handle = instance_handle,
            .status_changes = 0,
            .status_cond = null,
            .data_notifiers = .empty,
            .pending = .empty,
            .coherent_wip = .{},
            .coherent_committed = .empty,
            .coherent_committed_ready = false,
            .mu = .{},
            .timer_clock = timer_clock,
            .last_received_ns = .init(timer_clock.nowNs()),
            .seen_instances = .empty,
        };
        self.qos = try qos.clone(alloc);
        // Register delivery callback with the RTPS layer.
        proto_reader.setDataCallback(.{
            .ctx = self,
            .on_data = onDataCb,
            .on_sample_lost = onSampleLostCb,
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

    pub fn deinit(self: *Self) void {
        if (self.status_cond) |sc| sc.deinit();
        self.data_notifiers.deinit(self.alloc);
        // Drain pending queues (including coherent buffers).
        for (self.pending.items) |p| p.deinit();
        self.pending.deinit(self.alloc);
        var wip_it = self.coherent_wip.valueIterator();
        while (wip_it.next()) |v| {
            for (v.items) |p| p.deinit();
            v.deinit(self.alloc);
        }
        self.coherent_wip.deinit(self.alloc);
        for (self.coherent_committed.items) |*s| {
            for (s.items) |p| p.deinit();
            s.deinit(self.alloc);
        }
        self.coherent_committed.deinit(self.alloc);
        self.tbf_map.deinit(self.alloc);
        self.writer_strengths.deinit(self.alloc);
        self.writer_liveliness.deinit(self.alloc);
        self.owner_map.deinit(self.alloc);
        {
            var wi_it = self.writer_instances.valueIterator();
            while (wi_it.next()) |inner| inner.deinit(self.alloc);
        }
        self.writer_instances.deinit(self.alloc);
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
    ) struct { view: DDS.ViewStateKind, instance_state: DDS.InstanceStateKind } {
        const new_state: DDS.InstanceStateKind = switch (kind) {
            .alive => DDS.ALIVE_INSTANCE_STATE,
            .not_alive_disposed => DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE,
            .not_alive_unregistered => DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE,
        };
        if (self.seen_instances.getPtr(ih)) |entry| {
            // Resurrection: instance was not alive but a new alive sample arrived.
            const view: DDS.ViewStateKind = if (entry.instance_state != DDS.ALIVE_INSTANCE_STATE and kind == .alive)
                DDS.NEW_VIEW_STATE
            else
                DDS.NOT_NEW_VIEW_STATE;
            entry.instance_state = new_state;
            return .{ .view = view, .instance_state = new_state };
        } else {
            self.seen_instances.put(self.alloc, ih, .{ .instance_state = new_state }) catch {};
            return .{ .view = DDS.NEW_VIEW_STATE, .instance_state = new_state };
        }
    }

    /// Inject a CDR sample directly, bypassing the RTPS layer.
    /// Used by the built-in subscriber to push discovery-sourced samples.
    /// `cdr` is borrowed; it is copied internally.
    pub fn pushCdr(self: *Self, cdr: []const u8) void {
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
        if (self.listener_mask & DDS.DATA_AVAILABLE_STATUS != 0) {
            if (self.listener.on_data_available) |cb| cb(self.toDDSDataReader(), self.listener.listener_data);
        }
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
    /// Matches the DataCallback.on_data function pointer signature.
    /// Must not block; must not call back into the ProtocolReader.
    fn onDataCb(ctx: *anyopaque, change: *const history_mod.CacheChange) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
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
            const states = self.determineStatesLocked(ih, change.kind);
            const src_time = change.source_timestamp.toTime();
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
                },
                .group_seq_num = change.group_seq_num,
            };
            if (tbf_active) self.tbf_map.put(self.alloc, ih, tbf_src_ns) catch {};
            if (change.kind != .alive) {
                _ = self.tbf_map.remove(ih);
                _ = self.owner_map.remove(ih);
            }
            const wip_entry = self.coherent_wip.getOrPut(self.alloc, change.writer_guid) catch {
                self.mu.unlock();
                self.alloc.free(copy);
                return;
            };
            if (!wip_entry.found_existing) wip_entry.value_ptr.* = .empty;
            wip_entry.value_ptr.append(self.alloc, pc) catch {
                self.mu.unlock();
                self.alloc.free(copy);
                return;
            };
            const is_set_end = (change.sequence_number == change.coherent_set_sn.?);
            // commit_succeeded: true only when the completed set was successfully
            // enqueued in coherent_committed.  Used to gate both the in-lock flag
            // update and the post-lock notifications — if OOM discards the set we
            // must not set coherent_committed_ready or fire spurious notifications,
            // because there is nothing for begin_access() to deliver.
            var commit_succeeded = false;
            if (is_set_end) {
                // Zero-copy: take ownership of this writer's wip list and enqueue
                // it as one complete set.  Other writers' in-progress sets are
                // unaffected.  Subscriber.begin_access() pops one set at a time.
                var completed_set = wip_entry.value_ptr.*;
                _ = self.coherent_wip.remove(change.writer_guid);
                if (self.coherent_committed.append(self.alloc, completed_set)) {
                    commit_succeeded = true;
                } else |_| {
                    for (completed_set.items) |cppc| cppc.deinit();
                    completed_set.deinit(self.alloc);
                }
                if (commit_succeeded) {
                    self.coherent_committed_ready = true;
                    // Signal that a complete set is ready for begin_access().  Mirrors
                    // the notification pattern on the normal (non-coherent) data path.
                    self.status_changes |= DDS.DATA_AVAILABLE_STATUS;
                    for (self.data_notifiers.items) |n| n.on_data(n.ctx);
                }
            }
            self.mu.unlock();
            self.last_received_ns.store(self.timer_clock.nowNs(), .monotonic);
            if (is_set_end and commit_succeeded) {
                if (self.status_cond) |sc| sc.notifyWakeup();
                if (self.listener_mask & DDS.DATA_AVAILABLE_STATUS != 0) {
                    if (self.listener.on_data_available) |cb| cb(self.toDDSDataReader(), self.listener.listener_data);
                }
            }
            return;
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
            const fire = self.listener_mask & DDS.SAMPLE_REJECTED_STATUS != 0;
            if (fire) {
                self.sample_rejected_total_change = 0;
                self.status_changes &= ~DDS.SAMPLE_REJECTED_STATUS;
            }
            self.mu.unlock();
            self.alloc.free(copy);
            if (self.status_cond) |sc| sc.notifyWakeup();
            if (fire) {
                if (self.listener.on_sample_rejected) |cb| cb(self.toDDSDataReader(), &.{
                    .total_count = self.sample_rejected_total,
                    .total_count_change = 1,
                    .last_reason = reason,
                    .last_instance_handle = ih,
                }, self.listener.listener_data);
            }
            return;
        }

        // Build SampleInfo from the CacheChange.
        const states = self.determineStatesLocked(ih, change.kind);
        const src_time = change.source_timestamp.toTime();
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
            },
            .group_seq_num = change.group_seq_num,
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
        if (self.listener_mask & DDS.DATA_AVAILABLE_STATUS != 0) {
            const dr = self.toDDSDataReader();
            if (self.listener.on_data_available) |cb| cb(dr, self.listener.listener_data);
        }
    }

    // ── Ownership tracking ─────────────────────────────────────────────────────

    fn onWriterMatchedCb(ctx: *anyopaque, info: *const proto.MatchedWriterInfo) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        self.writer_strengths.put(self.alloc, info.guid, info.ownership_strength) catch return;
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
        self.mu.lock();
        _ = self.writer_strengths.remove(guid);
        // Discard any in-progress coherent set from this writer.  If the writer
        // crashed or was deleted mid-set, the partial wip would otherwise stay
        // in the map indefinitely — one leaked entry per connect/disconnect cycle.
        if (self.coherent_wip.fetchRemove(guid)) |kv| {
            var wip = kv.value;
            for (wip.items) |pc| pc.deinit();
            wip.deinit(self.alloc);
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
            if (self.listener_mask & DDS.DATA_AVAILABLE_STATUS != 0) {
                if (self.listener.on_data_available) |cb| cb(self.toDDSDataReader(), self.listener.listener_data);
            }
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
    /// when a WaitSet attaches the condition.  Guarded by mu (caller holds it).
    pub fn addDataNotifier(ctx: *anyopaque, n: waitset.DataNotifyFn) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        self.data_notifiers.append(self.alloc, n) catch {};
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

    /// Dequeue one sample.  Returns null if the queue is empty.
    /// The caller owns TakenSample.data and must free it with the reader's allocator.
    pub fn takeRaw(self: *Self) ?TakenSample {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.pending.items.len == 0) return null;
        const pc = self.pending.orderedRemove(0);
        if (self.pending.items.len == 0) {
            self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
        }
        return .{ .data = pc.data, .info = pc.info };
    }

    /// DDS take_next_instance semantics: dequeue one sample belonging to the
    /// "next" instance in handle order after `prev_instance_handle`.
    /// If prev == 0 (HANDLE_NIL), dequeue from whatever instance appears first.
    /// Returns null when the queue has no qualifying sample.
    /// The caller owns TakenSample.data and must free with the reader's allocator.
    pub fn takeNextInstanceRaw(self: *Self, prev_instance_handle: DDS.InstanceHandle_t) ?TakenSample {
        self.mu.lock();
        defer self.mu.unlock();

        // Find the target instance handle.
        var target_ih: ?DDS.InstanceHandle_t = null;
        for (self.pending.items) |pc| {
            const ih = pc.info.instance_handle;
            if (prev_instance_handle == 0) {
                target_ih = ih; // take from whichever instance appears first
                break;
            } else if (ih > prev_instance_handle) {
                if (target_ih == null or ih < target_ih.?) target_ih = ih;
            }
        }
        const tgt = target_ih orelse return null;

        for (self.pending.items, 0..) |pc, i| {
            if (pc.info.instance_handle == tgt) {
                const s = TakenSample{ .data = pc.data, .info = pc.info };
                _ = self.pending.orderedRemove(i);
                if (self.pending.items.len == 0) {
                    self.status_changes &= ~DDS.DATA_AVAILABLE_STATUS;
                }
                return s;
            }
        }
        return null;
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
        const limit: usize = if (max_samples < 0) std.math.maxInt(usize) else @intCast(max_samples);
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
        const limit: usize = if (max_samples < 0) std.math.maxInt(usize) else @intCast(max_samples);

        // Count matches first so we can reserve out capacity before mutating pending.
        var match_count: usize = 0;
        for (self.pending.items) |pc| {
            if (match_count >= limit) break;
            if (matchesSample(pc, sample_mask, view_mask, instance_mask, maybe_ih) and
                matchesQuery(pc, maybe_qc, self.get_field_fn)) match_count += 1;
        }
        try out.ensureUnusedCapacity(self.alloc, match_count);

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
    }

    pub fn toDDSDataReader(self: *Self) DDS.DataReader {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    /// Called by participant when a discovered remote writer's QoS is incompatible
    /// with this reader's requested QoS (DDS v1.4 §2.2.4.4).
    /// Updates counters and fires on_requested_incompatible_qos if registered.
    /// May be called while participant.mu is held; must not re-enter participant.
    pub fn notifyIncompatibleQos(ctx: *anyopaque, policy_id: i32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        self.incompat_total += 1;
        self.incompat_total_change += 1;
        self.incompat_last_policy = policy_id;
        self.status_changes |= DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS;
        const fire = self.listener_mask & DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS != 0;
        if (fire) {
            self.incompat_total_change = 0;
            self.status_changes &= ~DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS;
        }
        self.mu.unlock();

        if (self.status_cond) |sc| sc.notifyWakeup();

        if (fire) {
            var status = DDS.RequestedIncompatibleQosStatus{};
            status.total_count = self.incompat_total;
            status.total_count_change = 1;
            status.last_policy_id = policy_id;
            if (self.listener.on_requested_incompatible_qos) |cb| cb(self.toDDSDataReader(), &status, self.listener.listener_data);
        }
    }

    /// Called by participant when a remote DataWriter matches or unmatches this reader.
    /// Updates SubscriptionMatched counters and fires on_subscription_matched if registered.
    /// May be called while participant.mu is held; must not re-enter participant.
    pub fn notifySubscriptionMatched(ctx: *anyopaque, remote_handle: DDS.InstanceHandle_t, added: bool) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const delta: i32 = if (added) 1 else -1;
        self.mu.lock();
        if (added) self.sub_matched_total += 1;
        self.sub_matched_total_change += if (added) 1 else 0;
        self.sub_matched_current += delta;
        self.sub_matched_current_change += delta;
        self.sub_matched_last_handle = remote_handle;
        self.status_changes |= DDS.SUBSCRIPTION_MATCHED_STATUS;
        const fire = self.listener_mask & DDS.SUBSCRIPTION_MATCHED_STATUS != 0;
        self.mu.unlock();

        if (self.status_cond) |sc| sc.notifyWakeup();

        if (fire) {
            const status = DDS.SubscriptionMatchedStatus{
                .total_count = self.sub_matched_total,
                .total_count_change = if (added) 1 else 0,
                .current_count = self.sub_matched_current,
                .current_count_change = delta,
                .last_publication_handle = remote_handle,
            };
            self.mu.lock();
            self.status_changes &= ~DDS.SUBSCRIPTION_MATCHED_STATUS;
            self.sub_matched_total_change = 0;
            self.sub_matched_current_change = 0;
            self.mu.unlock();
            if (self.listener.on_subscription_matched) |cb| cb(self.toDDSDataReader(), &status, self.listener.listener_data);
        }
    }

    /// Called by the on_sample_lost DataCallback when GAP processing marks SNs as lost.
    fn onSampleLostCb(ctx: *anyopaque, count: i32) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.notifySampleLost(count);
    }

    pub fn notifySampleLost(self: *Self, count: i32) void {
        self.mu.lock();
        self.sample_lost_total += count;
        self.sample_lost_total_change += count;
        self.status_changes |= DDS.SAMPLE_LOST_STATUS;
        const fire = self.listener_mask & DDS.SAMPLE_LOST_STATUS != 0;
        if (fire) {
            self.sample_lost_total_change = 0;
            self.status_changes &= ~DDS.SAMPLE_LOST_STATUS;
        }
        self.mu.unlock();
        if (self.status_cond) |sc| sc.notifyWakeup();
        if (fire) {
            if (self.listener.on_sample_lost) |cb| cb(self.toDDSDataReader(), &.{
                .total_count = self.sample_lost_total,
                .total_count_change = count,
            }, self.listener.listener_data);
        }
    }

    fn notifyLivelinessChanged(self: *Self) void {
        self.status_changes |= DDS.LIVELINESS_CHANGED_STATUS;
        if (self.status_cond) |sc| sc.notifyWakeup();
        if (self.listener_mask & DDS.LIVELINESS_CHANGED_STATUS != 0) {
            const status = DDS.LivelinessChangedStatus{
                .alive_count = self.liveliness_alive_count,
                .not_alive_count = self.liveliness_not_alive_count,
                .alive_count_change = self.liveliness_alive_count_change,
                .not_alive_count_change = self.liveliness_not_alive_count_change,
                .last_publication_handle = self.liveliness_last_handle,
            };
            self.liveliness_alive_count_change = 0;
            self.liveliness_not_alive_count_change = 0;
            self.status_changes &= ~DDS.LIVELINESS_CHANGED_STATUS;
            if (self.listener.on_liveliness_changed) |cb| cb(self.toDDSDataReader(), &status, self.listener.listener_data);
        }
    }

    /// Fire on_requested_deadline_missed if the listener is registered for it.
    /// May be called while participant.mu is held; must not re-enter participant.
    pub fn notifyDeadlineMissed(self: *Self) void {
        self.deadline_missed_total += 1;
        self.deadline_missed_total_change += 1;
        self.status_changes |= DDS.REQUESTED_DEADLINE_MISSED_STATUS;
        if (self.status_cond) |sc| sc.notifyWakeup();
        if (self.listener_mask & DDS.REQUESTED_DEADLINE_MISSED_STATUS != 0) {
            var status = DDS.RequestedDeadlineMissedStatus{};
            status.total_count = self.deadline_missed_total;
            status.total_count_change = 1;
            self.deadline_missed_total_change = 0;
            self.status_changes &= ~DDS.REQUESTED_DEADLINE_MISSED_STATUS;
            if (self.listener.on_requested_deadline_missed) |cb| cb(self.toDDSDataReader(), &status, self.listener.listener_data);
        }
    }

    /// Called by participant.checkTimers() for each active reader.
    /// Checks DEADLINE and LIVELINESS lease expiry; fires notifications when thresholds exceeded.
    /// Called while participant.mu is held; must not re-enter participant.
    pub fn checkTimersFn(ctx: *anyopaque, now_ns: i64) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

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

    // ── Entity vtable ─────────────────────────────────────────────────────────

    const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
    };

    // ── DDS.DataReader vtable ─────────────────────────────────────────────────

    const vtable = DDS.DataReader.Vtable{
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
    };

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
        ) catch return nil.nil_readcondition;
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
        ) catch return nil.nil_querycondition;
        return qc.toDDSQueryCondition();
    }

    fn vtDeleteReadCondition(_: *anyopaque, a_condition: DDS.ReadCondition) DDS.ReturnCode_t {
        // Destroy the condition via its vtable.
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
        qos.* = cast(ctx).qos;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.DataReaderListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.listener = if (a_listener) |l| l.* else DDS.noop_DataReaderListener;
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.DataReaderListener {
        return cast(ctx).listener;
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
            .total_count = self.incompat_total,
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
