//! SubscriberImpl — DCPS Subscriber implementation.
//!
//! A Subscriber groups DataReaders and provides access control.
//!
//! Entity lifecycle:
//!   create_datareader   → allocates DataReaderImpl + ProtocolReader via participant cbs
//!   delete_datareader   → destroys DataReaderImpl + retracts from discovery via participant cbs

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const proto = @import("../protocol/interface.zig");
const reader_mod = @import("reader.zig");
const topic_mod = @import("topic.zig");
const filter_mod = @import("filter.zig");
const waitset = @import("waitset.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const time_mod = @import("../util/time.zig");

/// Callbacks from the owning DomainParticipant, supplied at construction time.
pub const ParticipantCbs = struct {
    ctx: *anyopaque,

    /// Allocate and start an RTPS ProtocolReader for a topic.
    create_proto_reader: *const fn (
        ctx: *anyopaque,
        topic_name: []const u8,
        type_name: []const u8,
        qos: DDS.DataReaderQos,
        handle: DDS.InstanceHandle_t,
    ) anyerror!proto.ProtocolReader,

    /// Tear down the ProtocolReader identified by handle.
    destroy_proto_reader: *const fn (ctx: *anyopaque, handle: DDS.InstanceHandle_t) void,

    /// Assign a fresh unique InstanceHandle_t.
    next_handle: *const fn (ctx: *anyopaque) DDS.InstanceHandle_t,

    /// Register an incompatible-QoS notification callback for a reader.
    /// Called once per DataReader after create_proto_reader succeeds.
    /// Participant stores the callback and invokes it when a discovered writer's
    /// QoS is incompatible with this reader's requested QoS.
    register_incompat_qos: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, policy_id: i32) void,
    ) void,

    /// Register a subscription-matched notification callback for a reader.
    /// Participant calls this when a remote DataWriter matches or unmatches.
    register_matched_notify: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, remote_handle: DDS.InstanceHandle_t, added: bool) void,
    ) void,

    /// Announce the reader identified by handle to the discovery layer.
    /// Called after register_incompat_qos so that synchronous discovery
    /// callbacks (e.g. DirectDiscovery) fire with the incompat callback already set.
    announce_reader: *const fn (ctx: *anyopaque, handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) void,

    /// Clock passed to DataReaderImpl for DEADLINE interval timers.
    timer_clock: time_mod.Clock,

    /// Register a timer-check callback (DEADLINE) for a reader.
    /// Called once per DataReader after create_proto_reader succeeds.
    register_timer_notify: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, now_ns: i64) void,
    ) void,

    /// Look up the optional get_field function for a given type name.
    /// Returns null when no TypeSupport with a get_field fn is registered.
    get_field_fn: *const fn (
        ctx: *anyopaque,
        type_name: []const u8,
    ) ?*const fn (payload: []const u8, field: []const u8) ?filter_mod.FilterValue,
};

pub const SubscriberImpl = struct {
    alloc: std.mem.Allocator,
    participant: DDS.DomainParticipant,
    cbs: ParticipantCbs,
    qos: DDS.SubscriberQos,
    listener: DDS.SubscriberListener,
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,

    default_dr_qos: DDS.DataReaderQos,

    /// Active DataReader instances owned by this subscriber; guarded by `mu`.
    readers: std.ArrayListUnmanaged(*reader_mod.DataReaderImpl),
    mu: Mutex,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        participant: DDS.DomainParticipant,
        cbs: ParticipantCbs,
        qos: DDS.SubscriberQos,
        listener: DDS.SubscriberListener,
        mask: DDS.StatusMask,
        handle: DDS.InstanceHandle_t,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .participant = participant,
            .cbs = cbs,
            .qos = .{},
            .listener = listener,
            .listener_mask = mask,
            .instance_handle = handle,
            .status_changes = 0,
            .status_cond = null,
            .default_dr_qos = .{},
            .readers = .empty,
            .mu = .{},
        };
        self.qos = try qos.clone(alloc);
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.status_cond) |sc| sc.deinit();
        for (self.readers.items) |r| {
            self.cbs.destroy_proto_reader(self.cbs.ctx, r.instance_handle);
            r.deinit();
        }
        self.readers.deinit(self.alloc);
        self.qos.deinit(self.alloc);
        self.default_dr_qos.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn toDDSSubscriber(self: *Self) DDS.Subscriber {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    // ── Entity vtable ─────────────────────────────────────────────────────────

    const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
    };

    // ── DDS.Subscriber vtable ─────────────────────────────────────────────────

    const vtable = DDS.Subscriber.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .create_datareader = vtCreateDataReader,
        .delete_datareader = vtDeleteDataReader,
        .delete_contained_entities = vtDeleteContained,
        .lookup_datareader = vtLookupDataReader,
        .get_datareaders = vtGetDataReaders,
        .notify_datareaders = vtNotifyDataReaders,
        .set_qos = vtSetQos,
        .get_qos = vtGetQos,
        .set_listener = vtSetListener,
        .get_listener = vtGetListener,
        .begin_access = vtBeginAccess,
        .end_access = vtEndAccess,
        .get_participant = vtGetParticipant,
        .set_default_datareader_qos = vtSetDefaultDrQos,
        .get_default_datareader_qos = vtGetDefaultDrQos,
        .copy_from_topic_qos = vtCopyFromTopicQos,
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

    fn vtCreateDataReader(
        ctx: *anyopaque,
        a_topic: DDS.TopicDescription,
        qos: *const DDS.DataReaderQos,
        a_listener: ?*const DDS.DataReaderListener,
        mask: DDS.StatusMask,
    ) DDS.DataReader {
        const self = cast(ctx);
        const sub_handle = self.cbs.next_handle(self.cbs.ctx);
        const topic_name = a_topic.get_name();
        const type_name = a_topic.get_type_name();
        const pr = self.cbs.create_proto_reader(
            self.cbs.ctx,
            topic_name,
            type_name,
            qos.*,
            sub_handle,
        ) catch return nil.nil_datareader;
        const dr = reader_mod.DataReaderImpl.init(
            self.alloc,
            a_topic,
            self.toDDSSubscriber(),
            pr,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_DataReaderListener,
            mask,
            sub_handle,
            self.cbs.timer_clock,
        ) catch {
            self.cbs.destroy_proto_reader(self.cbs.ctx, sub_handle);
            return nil.nil_datareader;
        };
        self.cbs.register_incompat_qos(
            self.cbs.ctx,
            sub_handle,
            dr,
            reader_mod.DataReaderImpl.notifyIncompatibleQos,
        );
        self.cbs.register_matched_notify(
            self.cbs.ctx,
            sub_handle,
            dr,
            reader_mod.DataReaderImpl.notifySubscriptionMatched,
        );
        self.cbs.register_timer_notify(
            self.cbs.ctx,
            sub_handle,
            dr,
            reader_mod.DataReaderImpl.checkTimersFn,
        );
        // Wire up get_field_fn for QueryCondition evaluation (always, when available).
        dr.get_field_fn = self.cbs.get_field_fn(self.cbs.ctx, type_name);
        // Store subscriber's presentation QoS for coherent-set buffering decisions.
        dr.subscriber_presentation = self.qos.presentation;
        // Wire up ContentFilteredTopic if the topic description is a CFT.
        if (topic_mod.asCft(a_topic)) |cft| {
            if (dr.get_field_fn) |get_field| {
                dr.cft_filter = .{ .cft_ptr = cft, .get_field_fn = get_field };
            }
        }
        // Convert partition name StringSeq (C extern struct) to []const []const u8 for announce_reader.
        const pname_seq = &self.qos.partition.name;
        const pname_count: u32 = if (pname_seq._buffer != null) pname_seq._length else 0;
        var pname_buf: [64][]const u8 = undefined;
        const pname_slice = pname_buf[0..@min(pname_count, pname_buf.len)];
        if (pname_seq._buffer) |b| for (pname_slice, 0..) |*s, i| {
            s.* = std.mem.span(b[i]);
        };
        self.cbs.announce_reader(self.cbs.ctx, sub_handle, pname_slice, self.qos.presentation);
        self.mu.lock();
        self.readers.append(self.alloc, dr) catch {
            self.mu.unlock();
            self.cbs.destroy_proto_reader(self.cbs.ctx, sub_handle);
            dr.deinit();
            return nil.nil_datareader;
        };
        self.mu.unlock();
        return dr.toDDSDataReader();
    }

    fn vtDeleteDataReader(ctx: *anyopaque, a_datareader: DDS.DataReader) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.readers.items, 0..) |r, i| {
            if (r.toDDSDataReader().ptr == a_datareader.ptr) {
                _ = self.readers.swapRemove(i);
                self.cbs.destroy_proto_reader(self.cbs.ctx, r.instance_handle);
                r.deinit();
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtDeleteContained(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.readers.items) |r| {
            self.cbs.destroy_proto_reader(self.cbs.ctx, r.instance_handle);
            r.deinit();
        }
        self.readers.clearRetainingCapacity();
        return DDS.RETCODE_OK;
    }

    fn vtLookupDataReader(ctx: *anyopaque, topic_name: [*:0]const u8) DDS.DataReader {
        const self = cast(ctx);
        const tn_s = std.mem.span(topic_name);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.readers.items) |r| {
            if (std.mem.eql(u8, r.topic_desc.get_name(), tn_s)) {
                return r.toDDSDataReader();
            }
        }
        return nil.nil_datareader;
    }

    fn vtGetDataReaders(
        ctx: *anyopaque,
        readers: ?*DDS.DataReaderSeq,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
    ) DDS.ReturnCode_t {
        const seq = readers orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        // Reset the sequence output.
        seq.* = .{};
        // Pending samples are always NOT_READ / NEW / ALIVE.
        const want_not_read = (sample_states & DDS.NOT_READ_SAMPLE_STATE) != 0;
        const want_new = (view_states & DDS.NEW_VIEW_STATE) != 0;
        const want_alive = (instance_states & DDS.ALIVE_INSTANCE_STATE) != 0;
        // Collect matching readers into a temporary list, then assign to the seq.
        var tmp = std.ArrayListUnmanaged(DDS.DataReader).empty;
        defer tmp.deinit(self.alloc);
        for (self.readers.items) |r| {
            if (want_not_read and want_new and want_alive and r.hasPendingData()) {
                tmp.append(self.alloc, r.toDDSDataReader()) catch return DDS.RETCODE_OUT_OF_RESOURCES;
            }
        }
        if (tmp.items.len > 0) {
            const buf = self.alloc.dupe(DDS.DataReader, tmp.items) catch return DDS.RETCODE_OUT_OF_RESOURCES;
            seq._buffer = buf.ptr;
            seq._length = @intCast(buf.len);
            seq._maximum = @intCast(buf.len);
            seq._release = true;
        }
        return DDS.RETCODE_OK;
    }

    fn vtNotifyDataReaders(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.readers.items) |r| {
            if (r.listener_mask & DDS.DATA_AVAILABLE_STATUS != 0) {
                const dr = r.toDDSDataReader();
                if (r.listener.on_data_available) |cb| cb(dr, r.listener.listener_data);
            }
        }
        return DDS.RETCODE_OK;
    }

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.SubscriberQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.qos.deinit(self.alloc);
        self.qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.SubscriberQos) DDS.ReturnCode_t {
        qos.* = cast(ctx).qos;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.SubscriberListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.listener = if (a_listener) |l| l.* else DDS.noop_SubscriberListener;
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.SubscriberListener {
        return cast(ctx).listener;
    }

    fn vtBeginAccess(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        const pres = self.qos.presentation;
        if (!pres.coherent_access and !pres.ordered_access) return DDS.RETCODE_OK;

        // Snapshot of listener state for readers that received a coherent commit.
        // Captured under subscriber.mu so we can fire callbacks safely after the
        // lock is released.  Avoids use-after-free from a concurrent delete_datareader:
        // delete_datareader must acquire subscriber.mu, so it cannot free a reader
        // while we are still accessing its fields inside the lock.
        const ListenerSnap = struct { listener: DDS.DataReaderListener, dr: DDS.DataReader };
        var listener_snaps: std.ArrayListUnmanaged(ListenerSnap) = .empty;
        defer listener_snaps.deinit(self.alloc);

        self.mu.lock();

        // COHERENT ACCESS: commit all complete coherent sets atomically so the
        // application sees a consistent view across all readers.
        // Only commit when ALL readers have a complete set ready — partial commits
        // would deliver an incomplete group.
        if (pres.coherent_access) {
            var all_ready = true;
            var any_committed = false;
            for (self.readers.items) |r| {
                r.mu.lock();
                // Block if any reader has incomplete WIP from any writer — delivering
                // a committed set while another writer's contribution is still in
                // transit would violate GROUP atomicity.
                if (r.coherent_wip.count() > 0) all_ready = false;
                if (r.coherent_committed_ready) any_committed = true;
                r.mu.unlock();
            }
            // Nothing to commit if no reader has a complete set ready.
            if (!any_committed) all_ready = false;
            if (all_ready and self.readers.items.len > 0) {
                for (self.readers.items) |r| {
                    r.mu.lock();
                    r.commitCoherentPendingLocked();
                    // Only notify if this reader actually has samples after commit — a
                    // reader with no WIP and no committed data passes the all_ready check
                    // but must not generate a spurious on_data_available or WaitSet wakeup.
                    const has_data = r.pending.items.len > 0;
                    // Fire WaitSet wakeups while subscriber.mu is held to prevent
                    // use-after-free from a concurrent delete_datareader.
                    // data_notifiers are exclusively WaitSet-internal wakeup callbacks
                    // (registered only by ReadConditionImpl/QueryConditionImpl via
                    // addDataNotifier).  They acquire only WaitSet.cv_mu — never
                    // subscriber.mu or reader.mu — so holding both locks here is safe.
                    if (has_data) {
                        for (r.data_notifiers.items) |n| n.on_data(n.ctx);
                    }
                    r.mu.unlock();
                    if (has_data) {
                        r.last_received_ns.store(r.timer_clock.nowNs(), .monotonic);
                        if (r.status_cond) |sc| sc.notifyWakeup();
                        if (r.listener_mask & DDS.DATA_AVAILABLE_STATUS != 0) {
                            listener_snaps.append(self.alloc, .{
                                .listener = r.listener,
                                .dr = r.toDDSDataReader(),
                            }) catch {};
                        }
                    }
                }
            }
        }

        // ORDERED ACCESS: sort each reader's pending queue so that take() returns
        // samples in presentation order.  Must happen after coherent commit so
        // newly committed samples are included.
        if (pres.ordered_access) {
            for (self.readers.items) |r| {
                r.mu.lock();
                switch (pres.access_scope) {
                    // INSTANCE: group samples by instance handle so all samples of
                    // instance X are consecutive; break ties with group_seq_num.
                    .INSTANCE_PRESENTATION_QOS => std.mem.sort(
                        reader_mod.PendingChange,
                        r.pending.items,
                        {},
                        pendingInstanceLessThan,
                    ),
                    // TOPIC / GROUP: preserve publisher write order across instances.
                    else => std.mem.sort(
                        reader_mod.PendingChange,
                        r.pending.items,
                        {},
                        pendingLessThan,
                    ),
                }
                r.mu.unlock();
            }
        }

        self.mu.unlock();

        // Fire listener callbacks without any lock held, using pre-captured snapshots.
        // Listener context validity is the application's responsibility (standard DDS
        // contract: don't delete a reader while its callbacks may be in-flight).
        for (listener_snaps.items) |snap| {
            if (snap.listener.on_data_available) |cb| cb(snap.dr, snap.listener.listener_data);
        }
        return DDS.RETCODE_OK;
    }

    fn vtEndAccess(ctx: *anyopaque) DDS.ReturnCode_t {
        _ = ctx;
        return DDS.RETCODE_OK;
    }

    fn pendingLessThan(_: void, a: reader_mod.PendingChange, b: reader_mod.PendingChange) bool {
        const a_gsn = a.group_seq_num orelse std.math.maxInt(i64);
        const b_gsn = b.group_seq_num orelse std.math.maxInt(i64);
        return a_gsn < b_gsn;
    }

    fn pendingInstanceLessThan(_: void, a: reader_mod.PendingChange, b: reader_mod.PendingChange) bool {
        if (a.info.instance_handle != b.info.instance_handle)
            return a.info.instance_handle < b.info.instance_handle;
        const a_gsn = a.group_seq_num orelse std.math.maxInt(i64);
        const b_gsn = b.group_seq_num orelse std.math.maxInt(i64);
        return a_gsn < b_gsn;
    }

    fn vtGetParticipant(ctx: *anyopaque) DDS.DomainParticipant {
        return cast(ctx).participant;
    }

    fn vtSetDefaultDrQos(ctx: *anyopaque, qos: *const DDS.DataReaderQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.default_dr_qos.deinit(self.alloc);
        self.default_dr_qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultDrQos(ctx: *anyopaque, qos: *DDS.DataReaderQos) DDS.ReturnCode_t {
        qos.* = cast(ctx).default_dr_qos;
        return DDS.RETCODE_OK;
    }

    fn vtCopyFromTopicQos(_: *anyopaque, dr_qos: *DDS.DataReaderQos, topic_qos: *const DDS.TopicQos) DDS.ReturnCode_t {
        // Copy the subset of TopicQos fields that apply to DataReader.
        dr_qos.durability = topic_qos.durability;
        dr_qos.deadline = topic_qos.deadline;
        dr_qos.latency_budget = topic_qos.latency_budget;
        dr_qos.liveliness = topic_qos.liveliness;
        dr_qos.reliability = topic_qos.reliability;
        dr_qos.destination_order = topic_qos.destination_order;
        dr_qos.history = topic_qos.history;
        dr_qos.resource_limits = topic_qos.resource_limits;
        dr_qos.ownership = topic_qos.ownership;
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn getStatusFn(entity_ptr: *anyopaque) DDS.StatusMask {
        return cast(entity_ptr).status_changes;
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
