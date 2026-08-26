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
const c_abi_handle = @import("../util/c_abi_handle.zig");
const ListenerBox = @import("../util/listener_box.zig").ListenerBox;
const listener_fallback = @import("../util/listener_fallback.zig");
const participant_mod = @import("participant.zig");
const config_mod = @import("../config/schema.zig");
const generated_config_mod = @import("../config/generated.zig");

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
        presentation: DDS.PresentationQosPolicy,
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
    /// quiesce_acquire/quiesce_release let checkTimers() hold the reader's
    /// EntityQuiesce reference across its own unlock-then-dispatch window --
    /// see DataReaderImpl.quiesceAcquireFn's doc comment.
    register_timer_notify: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, now_ns: i64) void,
        quiesce_acquire: *const fn (notify_ctx: *anyopaque) bool,
        quiesce_release: *const fn (notify_ctx: *anyopaque) void,
    ) void,

    /// Registers a callback so a later registerTypeSupport() replacement for
    /// this reader's type can push the new get_field getter in, instead of
    /// leaving the reader's cached copy pointing at a freed TypeSupport ctx
    /// -- and, in the SAME participant-lock critical section, invokes
    /// `refresh_fn` with type_name's *current* get_field getter (this is the
    /// reader's initial refresh). Bundling both into one call, with
    /// `refresh_fn` invoked synchronously rather than the current getter
    /// being returned for the caller to assign afterwards, closes a race: an
    /// out-of-line "return, then caller assigns" step would leave a window,
    /// after this call releases the participant lock but before the caller's
    /// assignment runs, in which a concurrent registerTypeSupport()
    /// replacement could refresh the reader through `refresh_fn` and free
    /// the old ctx -- only for the caller's now-stale assignment to
    /// overwrite that fresh value right back with a getter into freed
    /// memory. Routing the initial value through the same `refresh_fn` used
    /// by the replacement path means whichever one runs first (they're
    /// mutually excluded by the participant lock) always wins, with no
    /// separate unsynchronized step after it -- see participant.zig's
    /// subRegisterReaderGetFieldRefresh.
    register_get_field_refresh: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        type_name: []const u8,
        notify_ctx: *anyopaque,
        refresh_fn: *const fn (notify_ctx: *anyopaque, new_get_field: ?filter_mod.CdrFieldGetter) void,
    ) void,

    /// Register a WLP (RTPS §8.4.13) alive-notification callback for a
    /// reader. Called by participant.zig's wlpAliveFromDiscovery when an
    /// incoming ParticipantMessageData asserts liveliness for a remote
    /// participant this reader may have matched writers from.
    register_wlp_alive_notify: *const fn (
        ctx: *anyopaque,
        handle: DDS.InstanceHandle_t,
        notify_ctx: *anyopaque,
        notify_fn: *const fn (notify_ctx: *anyopaque, prefix: proto.GuidPrefix, kind: u8) void,
    ) void,
};

pub const SubscriberImpl = struct {
    alloc: std.mem.Allocator,
    participant: DDS.DomainParticipant,
    cbs: ParticipantCbs,
    qos: DDS.SubscriberQos,
    listener_box: *ListenerBox(DDS.SubscriberListener),
    /// Guards `listener_box` swaps/acquires only — never held across a
    /// dispatch or any other call (see listener_box.zig).
    listener_mu: Mutex = .{},
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,

    default_dr_qos: DDS.DataReaderQos,

    /// Active DataReader instances owned by this subscriber; guarded by `mu`.
    readers: std.ArrayListUnmanaged(*reader_mod.DataReaderImpl),
    mu: Mutex,

    /// One box for the whole object, shared across every interface view
    /// (Subscriber, Entity) — see `views` below and zidl/docs/roadmap.md
    /// "Binding design review: decision".
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        participant: DDS.DomainParticipant,
        cbs: ParticipantCbs,
        qos_defaults: config_mod.QosDefaults,
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
            .listener_box = undefined,
            .listener_mask = mask,
            .instance_handle = handle,
            .status_changes = 0,
            .status_cond = null,
            .default_dr_qos = .{},
            .readers = .empty,
            .mu = .{},
        };
        errdefer alloc.destroy(self);
        self.listener_box = try ListenerBox(DDS.SubscriberListener).create(alloc, listener);
        errdefer alloc.destroy(self.listener_box);
        self.qos = try qos.clone(alloc);
        errdefer self.qos.deinit(alloc);
        // See config/generated.zig's applyQosDefaults doc comment: this is the
        // one place a config-file QosDefaults value reaches get_default_datareader_qos().
        generated_config_mod.applyQosDefaults(&self.default_dr_qos, &qos_defaults);
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.listener_box.releaseRef(self.alloc);
        if (self.status_cond) |sc| sc.deinit();
        self.c_abi.free(self.alloc);
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

    pub fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    // ── Entity vtable ─────────────────────────────────────────────────────────

    pub const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

    // ── DDS.Subscriber vtable ─────────────────────────────────────────────────

    pub const vtable = DDS.Subscriber.Vtable{
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
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_Entity = vtAsEntity,
    };

    /// One `CAbiViews` value for the whole object (see `zidl_rt.unboxAsView`).
    pub const views = DDS.Subscriber.CAbiViews{
        .base = .{ .flat_vtable = &entity_vtable },
        .flat_vtable = &vtable,
    };

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
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
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        return self.status_changes;
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
        const presentation = self.qos.presentation;
        const pr = self.cbs.create_proto_reader(
            self.cbs.ctx,
            topic_name,
            type_name,
            qos.*,
            sub_handle,
            presentation,
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
            reader_mod.DataReaderImpl.quiesceAcquireFn,
            reader_mod.DataReaderImpl.quiesceReleaseFn,
        );
        // Store subscriber's presentation QoS for coherent-set buffering decisions.
        dr.subscriber_presentation = presentation;
        // Record the ContentFilteredTopic association (if any) before the
        // get_field registration below, so its synchronous initial refresh
        // (which runs refreshGetFieldFn) can build cft_filter from it.
        if (topic_mod.asCft(a_topic)) |cft| {
            dr.cft_ptr = cft;
        }
        // Wire up get_field_fn (and cft_filter, via cft_ptr above) for
        // QueryCondition/CFT evaluation, and arm this reader for a later
        // TypeSupport re-registration to refresh them instead of leaving
        // them pointing at a freed ctx -- see reader.zig's refreshGetFieldFn.
        // Both the registration and the initial refresh happen in one call
        // (one participant-lock critical section, refresh_fn invoked
        // synchronously) so a concurrent registerTypeSupport() can never
        // land in between and have its own refresh overwritten by a stale
        // value here -- see ParticipantCbs.register_get_field_refresh's doc
        // comment.
        self.cbs.register_get_field_refresh(
            self.cbs.ctx,
            sub_handle,
            type_name,
            dr,
            reader_mod.DataReaderImpl.refreshGetFieldFn,
        );
        self.cbs.register_wlp_alive_notify(
            self.cbs.ctx,
            sub_handle,
            dr,
            reader_mod.DataReaderImpl.onParticipantAliveCb,
        );
        // Convert partition name StringSeq (C extern struct) to []const []const u8 for announce_reader.
        const pname_seq = &self.qos.partition.name;
        const pname_count: u32 = if (pname_seq._buffer != null) pname_seq._length else 0;
        var pname_buf: [64][]const u8 = undefined;
        const pname_slice = pname_buf[0..@min(pname_count, pname_buf.len)];
        if (pname_seq._buffer) |b| for (pname_slice, 0..) |*s, i| {
            s.* = std.mem.span(b[i]);
        };
        self.cbs.announce_reader(self.cbs.ctx, sub_handle, pname_slice, presentation);
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
                // Spec §2.2.2.5.2.6: PRECONDITION_NOT_MET if the reader has
                // outstanding loans -- check before touching anything.
                const precondition = r.checkDeletePrecondition();
                if (precondition != DDS.RETCODE_OK) return precondition;
                _ = self.readers.swapRemove(i);
                self.cbs.destroy_proto_reader(self.cbs.ctx, r.instance_handle);
                r.deinit();
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_BAD_PARAMETER;
    }

    /// Checks every reader's delete precondition without tearing anything
    /// down -- shared by `vtDeleteContained` below and by
    /// `participant.zig`'s own cascade, which needs an all-or-nothing check
    /// across every subscriber before any of them start tearing down.
    pub fn checkDeleteContainedPrecondition(self: *Self) DDS.ReturnCode_t {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.readers.items) |r| {
            const precondition = r.checkDeletePrecondition();
            if (precondition != DDS.RETCODE_OK) return precondition;
        }
        return DDS.RETCODE_OK;
    }

    fn vtDeleteContained(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        const precondition = self.checkDeleteContainedPrecondition();
        if (precondition != DDS.RETCODE_OK) return precondition;
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
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
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
            const dr = r.toDDSDataReader();
            _ = r.dispatchListener("on_data_available", DDS.DATA_AVAILABLE_STATUS, dr.vtable.get_c_abi_handle(dr.ptr), .{});
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
        const self = cast(ctx);
        qos.* = self.qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.SubscriberListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.swapListener(if (a_listener) |l| l.* else DDS.noop_SubscriberListener);
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.SubscriberListener {
        const self = cast(ctx);
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.listener;
    }

    /// Installs `new_listener`, releasing whatever it replaces. Safe against
    /// a concurrently in-flight dispatch acquired via `acquireListener` (see
    /// listener_box.zig).
    fn swapListener(self: *Self, new_listener: DDS.SubscriberListener) void {
        const new_box = ListenerBox(DDS.SubscriberListener).create(self.alloc, new_listener) catch
            @panic("zzdds: out of memory boxing listener");
        self.listener_mu.lock();
        const old_box = self.listener_box;
        self.listener_box = new_box;
        self.listener_mu.unlock();
        old_box.releaseRef(self.alloc);
    }

    /// Call with no lock held. Returns a box the caller may safely read/
    /// dispatch through with no lock held; must call `releaseRef` on it when
    /// done (see listener_box.zig). `pub`: also used by `reader.zig`'s
    /// DDS 1.4 §2.2.4.1.5 "nearest enclosing non-null listener" fallback,
    /// and by this file's own coherent-access batch dispatch
    /// (`resolveDataAvailableFallback`).
    pub fn acquireListener(self: *Self) *ListenerBox(DDS.SubscriberListener) {
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.acquireLocked();
    }

    /// Second link in the DDS 1.4 §2.2.4.1.5 "nearest enclosing non-null
    /// listener" fallback chain for a contained DataReader's status events —
    /// consulted only after the reader itself had no usable listener for
    /// `field`. `handle` remains the originating reader's own handle (per
    /// spec — the callback that runs still receives the entity whose status
    /// actually changed). Safe to downcast `self.participant.ptr`: see
    /// `publisher.zig`'s `dispatchWriterFallback` doc comment for why the
    /// parent is guaranteed alive for the whole of this call — the same
    /// reasoning applies symmetrically here.
    pub fn dispatchReaderFallback(self: *Self, comptime field: []const u8, bit: DDS.StatusMask, handle: anytype, args: anytype) bool {
        const box = self.acquireListener();
        defer box.releaseRef(self.alloc);
        if (listener_fallback.tryDispatch(field, self.listener_mask, bit, box.listener, handle, args)) return true;
        if (nil.isNil(self.participant)) return false;
        const p: *participant_mod.DomainParticipantImpl = @ptrCast(@alignCast(self.participant.ptr));
        return p.dispatchFallback(field, bit, handle, args);
    }

    /// The outcome of resolving (but not yet firing) `on_data_available`'s
    /// DDS 1.4 §2.2.4.1.5 fallback chain for one reader — see
    /// `resolveDataAvailableFallback`. `cb`/`listener_data` are `null`/
    /// `null` iff no level in the chain had a usable listener, matching
    /// this codebase's pre-existing "nobody wants it" behavior. Whichever
    /// level's box was acquired to produce this resolution (possibly none,
    /// if the reader itself won) is released exactly once via `release()`.
    const DataAvailableResolution = struct {
        cb: ?*const fn (*anyopaque, ?*anyopaque) callconv(.c) void,
        listener_data: ?*anyopaque,
        owner: union(enum) {
            none,
            reader: struct { box: *ListenerBox(DDS.DataReaderListener), alloc: std.mem.Allocator },
            subscriber: struct { box: *ListenerBox(DDS.SubscriberListener), alloc: std.mem.Allocator },
            participant: struct { box: *ListenerBox(DDS.DomainParticipantListener), alloc: std.mem.Allocator },
        },

        fn release(self: DataAvailableResolution) void {
            switch (self.owner) {
                .none => {},
                .reader => |o| o.box.releaseRef(o.alloc),
                .subscriber => |o| o.box.releaseRef(o.alloc),
                .participant => |o| o.box.releaseRef(o.alloc),
            }
        }
    };

    /// Resolves (without firing) the DDS 1.4 §2.2.4.1.5 "nearest enclosing
    /// non-null listener" chain for `r`'s `on_data_available`, walking
    /// `r` -> `self` (this Subscriber) -> `self`'s participant. Boxes are
    /// acquired eagerly (cheap: a mutex + refcount bump per level, no user
    /// code runs) so the caller — `vtBeginAccess`'s coherent-access batch
    /// dispatch — can defer the actual `cb()` call until after releasing
    /// `subscriber.mu`, while still safely holding whichever box "won"
    /// against a concurrent delete_datareader/delete_subscriber/
    /// delete_participant (matches this call site's pre-existing reason for
    /// pre-acquiring `r`'s own box before deferring the fire). Call with
    /// `subscriber.mu` held (matches the call site; `self`/`self`'s
    /// participant are therefore guaranteed alive per `publisher.zig`'s
    /// `dispatchWriterFallback` doc comment).
    fn resolveDataAvailableFallback(self: *Self, r: *reader_mod.DataReaderImpl) DataAvailableResolution {
        const rbox = r.acquireListener();
        if (listener_fallback.peek("on_data_available", r.listener_mask, DDS.DATA_AVAILABLE_STATUS, rbox.listener)) |cb| {
            return .{ .cb = cb, .listener_data = rbox.listener.listener_data, .owner = .{ .reader = .{ .box = rbox, .alloc = r.alloc } } };
        }
        rbox.releaseRef(r.alloc);

        const sbox = self.acquireListener();
        if (listener_fallback.peek("on_data_available", self.listener_mask, DDS.DATA_AVAILABLE_STATUS, sbox.listener)) |cb| {
            return .{ .cb = cb, .listener_data = sbox.listener.listener_data, .owner = .{ .subscriber = .{ .box = sbox, .alloc = self.alloc } } };
        }
        sbox.releaseRef(self.alloc);

        if (nil.isNil(self.participant)) return .{ .cb = null, .listener_data = null, .owner = .none };
        const p: *participant_mod.DomainParticipantImpl = @ptrCast(@alignCast(self.participant.ptr));
        const pbox = p.acquireListener();
        if (listener_fallback.peek("on_data_available", p.listener_mask, DDS.DATA_AVAILABLE_STATUS, pbox.listener)) |cb| {
            return .{ .cb = cb, .listener_data = pbox.listener.listener_data, .owner = .{ .participant = .{ .box = pbox, .alloc = p.alloc } } };
        }
        pbox.releaseRef(p.alloc);

        return .{ .cb = null, .listener_data = null, .owner = .none };
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
        //
        // `resolution` is already the outcome of the full DDS 1.4 §2.2.4.1.5
        // reader -> subscriber -> participant fallback walk (see
        // `resolveDataAvailableFallback`), not just the reader's own box —
        // resolved eagerly here (cheap: mutex + refcount bump per level, no
        // user code runs) so the walk itself, like the reader-only box
        // acquire it replaces, doesn't need to touch `r`/`self`/the
        // participant again after the lock below is released.
        const ListenerSnap = struct {
            dr: DDS.DataReader,
            resolution: DataAvailableResolution,
        };
        var listener_snaps: std.ArrayListUnmanaged(ListenerSnap) = .empty;
        // Each entry's acquired box reference is released by the dispatch
        // loop below (the normal path) or, if this function returns before
        // reaching it, by this defer instead — never both: the dispatch
        // loop clears the list after releasing, so this is a no-op then.
        defer {
            for (listener_snaps.items) |snap| snap.resolution.release();
            listener_snaps.deinit(self.alloc);
        }

        // Snapshot time before acquiring any lock — nanoTimestamp() is a vDSO call
        // but still avoids holding the lock longer than necessary.  All readers in
        // the loop are evaluated against the same instant, which is more consistent.
        const now_ns = time_mod.nanoTimestamp();
        // Maximum time to wait for the first DATA of a new coherent set before
        // assuming the writer is idle and releasing the begin_access gate.
        const coherent_idle_gate_ns: i64 = 5 * std.time.ns_per_s;

        self.mu.lock();

        // COHERENT ACCESS: commit complete coherent sets so the application sees a
        // consistent view.  Per DDS PRESENTATION QoS (§2.2.3.6), cross-reader
        // synchronization — waiting for every reader's set before committing any
        // of them — is only required for GROUP_PRESENTATION.  For INSTANCE/TOPIC
        // scope, each DataReader's coherent set is independent and must commit as
        // soon as it is complete, without waiting on sibling readers (which may be
        // matched to entirely different, independently-paced remote writers).
        if (pres.coherent_access) {
            const group_scope = pres.access_scope == .GROUP_PRESENTATION_QOS;
            var all_ready = true;
            var any_committed = false;
            for (self.readers.items) |r| {
                r.mu.lock();
                const coherent_guids_pending = r.coherent_writer_guids.count() > 0 and
                    r.pending.items.len == 0 and
                    (now_ns - r.last_coherent_wip_start_ns < coherent_idle_gate_ns);
                if (!r.coherent_committed_ready and r.sub_matched_current > 0 and
                    (r.coherent_wip.count() > 0 or coherent_guids_pending))
                {
                    // Block when a coherent set is in-flight for this reader.
                    // coherent_wip.count() > 0: end-marker hasn't arrived yet.
                    // coherent_guids_pending: at least one currently-matched writer is
                    //   coherent but its next set DATA hasn't arrived yet (sequential
                    //   vtEndCoherent timing).  The 5 s window on last_coherent_wip_start_ns
                    //   ensures an idle writer that stops sending never permanently stalls
                    //   begin_access — after 5 s without a new WIP entry the gate opens.
                    //   coherent_writer_guids is also cleared on writer departure for the
                    //   same reason.  Requiring pending to be empty avoids stalling when a
                    //   non-coherent writer has buffered data.
                    all_ready = false;
                }
                if (r.coherent_committed_ready) any_committed = true;
                r.mu.unlock();
            }
            // Nothing to commit if no reader has a complete set ready.
            if (!any_committed) all_ready = false;
            if (self.readers.items.len > 0) {
                for (self.readers.items) |r| {
                    r.mu.lock();
                    const coherent_guids_pending = r.coherent_writer_guids.count() > 0 and
                        r.pending.items.len == 0 and
                        (now_ns - r.last_coherent_wip_start_ns < coherent_idle_gate_ns);
                    const reader_ready = r.coherent_committed_ready or
                        !(r.sub_matched_current > 0 and (r.coherent_wip.count() > 0 or coherent_guids_pending));
                    // GROUP scope: commit only once every reader is ready (all_ready).
                    // INSTANCE/TOPIC scope: commit this reader independently once it,
                    // specifically, is ready.
                    const should_commit = if (group_scope) all_ready else reader_ready;
                    if (!should_commit) {
                        r.mu.unlock();
                        continue;
                    }
                    r.commitCoherentPendingLocked();
                    // Only notify if this reader actually has samples after commit — a
                    // reader with no WIP and no committed data passes the ready check
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
                        const resolution = self.resolveDataAvailableFallback(r);
                        listener_snaps.append(self.alloc, .{
                            .dr = r.toDDSDataReader(),
                            .resolution = resolution,
                        }) catch resolution.release();
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
                        *reader_mod.PendingChange,
                        r.pending.items,
                        {},
                        pendingInstanceLessThan,
                    ),
                    // TOPIC / GROUP: preserve publisher write order across instances.
                    else => std.mem.sort(
                        *reader_mod.PendingChange,
                        r.pending.items,
                        {},
                        pendingLessThan,
                    ),
                }
                // Watermark: only serve samples present at begin_access time.
                // New samples appended by the inbound path after this sort are
                // withheld until end_access() clears the watermark, preventing
                // unsorted arrivals from breaking the presentation-order guarantee.
                r.ordered_access_watermark = r.pending.items.len;
                r.mu.unlock();
            }
        }

        self.mu.unlock();

        // Fire listener callbacks without any lock held, using pre-captured
        // snapshots — each carrying its own acquired ListenerBox reference,
        // so a concurrent replace/delete on the owning reader can't free the
        // listener's native context out from under this dispatch (see
        // listener_box.zig). Released here, then the list is cleared so the
        // top-level defer (a safety net for an early-return path) doesn't
        // double-release.
        for (listener_snaps.items) |snap| {
            if (snap.resolution.cb) |cb| cb(snap.dr.vtable.get_c_abi_handle(snap.dr.ptr), snap.resolution.listener_data);
            snap.resolution.release();
        }
        listener_snaps.clearRetainingCapacity();
        return DDS.RETCODE_OK;
    }

    fn vtEndAccess(ctx: *anyopaque) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const pres: DDS.PresentationQosPolicy = self.qos.presentation;
        if (pres.ordered_access) {
            for (self.readers.items) |r| {
                r.mu.lock();
                r.ordered_access_watermark = null;
                // Items that arrived after begin_access() are now available.
                // Re-arm DATA_AVAILABLE_STATUS so StatusCondition users wake
                // on the next wait rather than missing the deferred samples.
                if (r.pending.items.len > 0) {
                    r.status_changes |= DDS.DATA_AVAILABLE_STATUS;
                    if (r.status_cond) |sc| sc.notifyWakeup();
                }
                r.mu.unlock();
            }
        }
        return DDS.RETCODE_OK;
    }

    fn pendingLessThan(_: void, a: *reader_mod.PendingChange, b: *reader_mod.PendingChange) bool {
        const a_gsn = a.group_seq_num orelse std.math.maxInt(i64);
        const b_gsn = b.group_seq_num orelse std.math.maxInt(i64);
        return a_gsn < b_gsn;
    }

    fn pendingInstanceLessThan(_: void, a: *reader_mod.PendingChange, b: *reader_mod.PendingChange) bool {
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
        const self = cast(ctx);
        qos.* = self.default_dr_qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
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
        const self = cast(entity_ptr);
        self.mu.lock();
        defer self.mu.unlock();
        return self.status_changes;
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
