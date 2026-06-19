//! PublisherImpl — DCPS Publisher implementation.
//!
//! A Publisher groups DataWriters under a common QoS policy and provides
//! coherent-change semantics (deferred to a later phase).
//!
//! Entity lifecycle:
//!   create_datawriter   → allocates DataWriterImpl + ProtocolWriter via participant cbs
//!   delete_datawriter   → destroys DataWriterImpl + retracts from discovery via participant cbs

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const proto = @import("../protocol/interface.zig");
const writer_mod = @import("writer.zig");
const waitset = @import("waitset.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const time_mod = @import("../util/time.zig");

/// Callbacks from the owning DomainParticipant, supplied at construction time.
/// All function pointers must remain valid for the lifetime of the PublisherImpl.
pub const ParticipantCbs = struct {
    ctx: *anyopaque,

    /// Allocate and start an RTPS ProtocolWriter for a topic.
    /// Called on create_datawriter; the returned ProtocolWriter is owned by
    /// the DataWriterImpl.
    create_proto_writer: *const fn (
        ctx: *anyopaque,
        topic_name: []const u8,
        type_name: []const u8,
        qos: DDS.DataWriterQos,
        handle: DDS.InstanceHandle_t,
    ) anyerror!proto.ProtocolWriter,

    /// Tear down the ProtocolWriter identified by handle.
    /// Called on delete_datawriter.
    destroy_proto_writer: *const fn (ctx: *anyopaque, handle: DDS.InstanceHandle_t) void,

    /// Assign a fresh unique InstanceHandle_t (monotonically increasing counter).
    next_handle: *const fn (ctx: *anyopaque) DDS.InstanceHandle_t,

    /// Register an incompatible-QoS notification callback for a writer.
    /// Called once per DataWriter after create_proto_writer succeeds.
    /// Participant stores the callback and invokes it when a discovered reader's
    /// QoS is incompatible with this writer's offered QoS.
    register_incompat_qos: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, policy_id: i32) void,
    ) void,

    /// Register a publication-matched notification callback for a writer.
    /// Participant calls this when a remote DataReader matches or unmatches.
    register_matched_notify: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, remote_handle: DDS.InstanceHandle_t, added: bool) void,
    ) void,

    /// Announce the writer identified by handle to the discovery layer.
    /// Called after register_incompat_qos so that synchronous discovery
    /// callbacks (e.g. DirectDiscovery) fire with the incompat callback already set.
    announce_writer: *const fn (ctx: *anyopaque, handle: DDS.InstanceHandle_t, publisher_handle: DDS.InstanceHandle_t, partition_names: []const []const u8, presentation: DDS.PresentationQosPolicy) void,

    /// Clock passed to DataWriterImpl for DEADLINE and LIVELINESS interval timers.
    timer_clock: time_mod.Clock,

    /// Register a timer-check callback (DEADLINE + LIVELINESS) for a writer.
    /// Called once per DataWriter after create_proto_writer succeeds.
    register_timer_notify: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, now_ns: i64) void,
    ) void,

    /// Register a liveliness-assert callback for a writer.
    /// Called by participant.assert_liveliness() to propagate to all writers.
    register_liveliness_assert: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        assert_fn: *const fn (notify_ctx: *anyopaque) void,
    ) void,
};

pub const PublisherImpl = struct {
    alloc: std.mem.Allocator,
    participant: DDS.DomainParticipant,
    cbs: ParticipantCbs,
    qos: DDS.PublisherQos,
    listener: DDS.PublisherListener,
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,

    default_dw_qos: DDS.DataWriterQos,

    /// Active DataWriter instances owned by this publisher; guarded by `mu`.
    writers: std.ArrayListUnmanaged(*writer_mod.DataWriterImpl),
    mu: Mutex,

    /// Nesting counter for begin/end_coherent_changes.  The coherent set on the
    /// underlying writers is opened at depth 0→1 and closed at depth 1→0.
    coherent_depth: u32,
    /// True while suspend_publications is in effect.  Tracked separately from
    /// coherent_active on the writers so that end_coherent_changes can re-open
    /// the suspension window after flushing the coherent set.
    suspend_active: bool,
    /// Shared group sequence number counter advanced across all writers during
    /// begin/end_coherent_changes.  Passed by pointer to each writer's endCoherentSet
    /// so that multiple writers in the same GROUP_PRESENTATION coherent set receive
    /// globally unique, write-ordered GSNs rather than independent per-writer sequences.
    group_seq_num_counter: i64,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        participant: DDS.DomainParticipant,
        cbs: ParticipantCbs,
        qos: DDS.PublisherQos,
        listener: DDS.PublisherListener,
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
            .default_dw_qos = .{},
            .writers = .empty,
            .mu = .{},
            .coherent_depth = 0,
            .suspend_active = false,
            .group_seq_num_counter = 0,
        };
        errdefer alloc.destroy(self);
        self.qos = try qos.clone(alloc);
        errdefer self.qos.deinit(alloc);
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.status_cond) |sc| sc.deinit();
        // Destroy all remaining DataWriters.
        for (self.writers.items) |w| {
            self.cbs.destroy_proto_writer(self.cbs.ctx, w.instance_handle);
            w.deinit();
        }
        self.writers.deinit(self.alloc);
        self.qos.deinit(self.alloc);
        self.default_dw_qos.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn toDDSPublisher(self: *Self) DDS.Publisher {
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

    // ── DDS.Publisher vtable ──────────────────────────────────────────────────

    const vtable = DDS.Publisher.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .create_datawriter = vtCreateDataWriter,
        .delete_datawriter = vtDeleteDataWriter,
        .lookup_datawriter = vtLookupDataWriter,
        .delete_contained_entities = vtDeleteContained,
        .set_qos = vtSetQos,
        .get_qos = vtGetQos,
        .set_listener = vtSetListener,
        .get_listener = vtGetListener,
        .suspend_publications = vtSuspendPublications,
        .resume_publications = vtResumePublications,
        .begin_coherent_changes = vtBeginCoherent,
        .end_coherent_changes = vtEndCoherent,
        .wait_for_acknowledgments = vtWaitForAck,
        .get_participant = vtGetParticipant,
        .set_default_datawriter_qos = vtSetDefaultDwQos,
        .get_default_datawriter_qos = vtGetDefaultDwQos,
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

    fn vtCreateDataWriter(
        ctx: *anyopaque,
        a_topic: DDS.Topic,
        qos: *const DDS.DataWriterQos,
        a_listener: ?*const DDS.DataWriterListener,
        mask: DDS.StatusMask,
    ) DDS.DataWriter {
        const self = cast(ctx);
        const pub_handle = self.cbs.next_handle(self.cbs.ctx);
        const topic_name = a_topic.get_name();
        const type_name = a_topic.get_type_name();
        const pw = self.cbs.create_proto_writer(
            self.cbs.ctx,
            topic_name,
            type_name,
            qos.*,
            pub_handle,
        ) catch return nil.nil_datawriter;
        const dw = writer_mod.DataWriterImpl.init(
            self.alloc,
            a_topic,
            self.toDDSPublisher(),
            pw,
            qos.*,
            if (a_listener) |l| l.* else DDS.noop_DataWriterListener,
            mask,
            pub_handle,
            self.cbs.timer_clock,
        ) catch {
            self.cbs.destroy_proto_writer(self.cbs.ctx, pub_handle);
            return nil.nil_datawriter;
        };
        self.cbs.register_incompat_qos(
            self.cbs.ctx,
            pub_handle,
            dw,
            writer_mod.DataWriterImpl.notifyIncompatibleQos,
        );
        self.cbs.register_matched_notify(
            self.cbs.ctx,
            pub_handle,
            dw,
            writer_mod.DataWriterImpl.notifyPublicationMatched,
        );
        self.cbs.register_timer_notify(
            self.cbs.ctx,
            pub_handle,
            dw,
            writer_mod.DataWriterImpl.checkTimersFn,
        );
        self.cbs.register_liveliness_assert(
            self.cbs.ctx,
            pub_handle,
            dw,
            writer_mod.DataWriterImpl.assertLivelinessFn,
        );
        const pname_seq = &self.qos.partition.name;
        const pname_count: u32 = if (pname_seq._buffer != null) pname_seq._length else 0;
        var pname_buf: [64][]const u8 = undefined;
        const pname_slice = pname_buf[0..@min(pname_count, pname_buf.len)];
        if (pname_seq._buffer) |b| for (pname_slice, 0..) |*s, i| {
            s.* = std.mem.span(b[i]);
        };
        self.cbs.announce_writer(self.cbs.ctx, pub_handle, self.instance_handle, pname_slice, self.qos.presentation);
        self.mu.lock();
        self.writers.append(self.alloc, dw) catch {
            self.mu.unlock();
            self.cbs.destroy_proto_writer(self.cbs.ctx, pub_handle);
            dw.deinit();
            return nil.nil_datawriter;
        };
        self.mu.unlock();
        return dw.toDDSDataWriter();
    }

    fn vtDeleteDataWriter(ctx: *anyopaque, a_datawriter: DDS.DataWriter) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.writers.items, 0..) |w, i| {
            if (w.toDDSDataWriter().ptr == a_datawriter.ptr) {
                _ = self.writers.swapRemove(i);
                self.cbs.destroy_proto_writer(self.cbs.ctx, w.instance_handle);
                w.deinit();
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    fn vtLookupDataWriter(ctx: *anyopaque, topic_name: [*:0]const u8) DDS.DataWriter {
        const self = cast(ctx);
        const tn_s = std.mem.span(topic_name);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.writers.items) |w| {
            if (std.mem.eql(u8, w.topic_name, tn_s)) {
                return w.toDDSDataWriter();
            }
        }
        return nil.nil_datawriter;
    }

    fn vtDeleteContained(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        for (self.writers.items) |w| {
            self.cbs.destroy_proto_writer(self.cbs.ctx, w.instance_handle);
            w.deinit();
        }
        self.writers.clearRetainingCapacity();
        return DDS.RETCODE_OK;
    }

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.PublisherQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.qos.deinit(self.alloc);
        self.qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.PublisherQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.PublisherListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.listener = if (a_listener) |l| l.* else DDS.noop_PublisherListener;
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.PublisherListener {
        return cast(ctx).listener;
    }

    fn vtSuspendPublications(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        self.suspend_active = true;
        for (self.writers.items) |w| w.proto_writer.beginCoherentSet(false);
        return DDS.RETCODE_OK;
    }

    fn vtResumePublications(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        self.suspend_active = false;
        // If begin_coherent_changes is active, the coherent window owns the deferred
        // writes — don't flush them here; end_coherent_changes will do it correctly.
        // Only flush with .none when there is no open coherent window.
        if (self.coherent_depth == 0) {
            for (self.writers.items) |w| w.proto_writer.endCoherentSet(.none, false, null, 0, false);
        }
        return DDS.RETCODE_OK;
    }

    fn vtBeginCoherent(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.coherent_depth == 0) {
            for (self.writers.items) |w| w.proto_writer.beginCoherentSet(true);
        }
        self.coherent_depth += 1;
        return DDS.RETCODE_OK;
    }

    fn vtEndCoherent(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        if (self.coherent_depth == 0) return DDS.RETCODE_PRECONDITION_NOT_MET;
        self.coherent_depth -= 1;
        if (self.coherent_depth == 0) {
            const mode: proto.CoherentFlushMode = if (self.qos.presentation.coherent_access)
                if (self.qos.presentation.access_scope == .GROUP_PRESENTATION_QOS) .full else .coherent_only
            else
                .group_seq_only;
            // Pre-count total coherent-window samples across all writers to compute
            // the group-wide last GSN for PID_GROUP_COHERENT_SET.  This lets the
            // initial DATA send (and retransmits) carry the correct group end marker.
            // The TOCTOU window between count and flush is negligible in practice:
            // concurrent writes during end_coherent_changes are application-level
            // misuse that the DDS spec does not require implementations to handle.
            var total_n: i64 = 0;
            for (self.writers.items) |w| total_n += @intCast(w.proto_writer.coherentWindowCount());
            const global_last_gsn = self.group_seq_num_counter + total_n;
            // Pass suspend_active as `resuspend` so the flush and re-arm happen
            // atomically inside writer.mu — no window where coherent_active=false.
            // Pass &group_seq_num_counter so all writers share a monotone GSN space.
            //
            // For GROUP presentation, use a two-phase flush: send DATA for all writers
            // first (defer_eoc=true), then send EOC+HB for all writers together.  This
            // keeps per-writer EOC packets close together on the wire even when the
            // sequential endCoherentSet calls are spread out in time (e.g. under TSAN).
            const defer_eoc = mode == .full;
            for (self.writers.items) |w| w.proto_writer.endCoherentSet(mode, self.suspend_active, &self.group_seq_num_counter, global_last_gsn, defer_eoc);
            if (defer_eoc) {
                for (self.writers.items) |w| w.proto_writer.flushGroupEOC();
            }
        }
        return DDS.RETCODE_OK;
    }

    fn vtWaitForAck(ctx: *anyopaque, timeout: *const DDS.Duration_t) DDS.ReturnCode_t {
        const self = cast(ctx);
        const POLL_NS: u64 = 1_000_000; // 1 ms
        const deadline_ns: ?i64 = if (timeout.sec == DDS.DURATION_INFINITE_SEC and
            timeout.nanosec == DDS.DURATION_INFINITE_NSEC)
            null
        else blk: {
            const now = time_mod.nanoTimestamp();
            break :blk now +
                @as(i64, timeout.sec) * std.time.ns_per_s +
                @as(i64, timeout.nanosec);
        };

        while (true) {
            self.mu.lock();
            var all_done = true;
            for (self.writers.items) |w| {
                if (w.qos.reliability.kind != .BEST_EFFORT_RELIABILITY_QOS and !w.allAcked()) {
                    all_done = false;
                    break;
                }
            }
            self.mu.unlock();
            if (all_done) return DDS.RETCODE_OK;
            if (deadline_ns) |dl| {
                if (time_mod.nanoTimestamp() >= dl) return DDS.RETCODE_TIMEOUT;
            }
            time_mod.sleepNs(POLL_NS);
        }
    }

    fn vtGetParticipant(ctx: *anyopaque) DDS.DomainParticipant {
        return cast(ctx).participant;
    }

    fn vtSetDefaultDwQos(ctx: *anyopaque, qos: *const DDS.DataWriterQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.default_dw_qos.deinit(self.alloc);
        self.default_dw_qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetDefaultDwQos(ctx: *anyopaque, qos: *DDS.DataWriterQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.default_dw_qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtCopyFromTopicQos(_: *anyopaque, dw_qos: *DDS.DataWriterQos, topic_qos: *const DDS.TopicQos) DDS.ReturnCode_t {
        // Copy the subset of Topic QoS fields that apply to DataWriter.
        dw_qos.durability = topic_qos.durability;
        dw_qos.deadline = topic_qos.deadline;
        dw_qos.latency_budget = topic_qos.latency_budget;
        dw_qos.liveliness = topic_qos.liveliness;
        dw_qos.reliability = topic_qos.reliability;
        dw_qos.destination_order = topic_qos.destination_order;
        dw_qos.history = topic_qos.history;
        dw_qos.resource_limits = topic_qos.resource_limits;
        dw_qos.transport_priority = topic_qos.transport_priority;
        dw_qos.lifespan = topic_qos.lifespan;
        dw_qos.ownership = topic_qos.ownership;
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
