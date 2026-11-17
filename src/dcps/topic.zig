//! TopicImpl — DDS Topic and TopicDescription implementation.
//!
//! A Topic is the named, typed channel within a DomainParticipant.
//! It implements both the DDS.Topic and DDS.TopicDescription vtable interfaces.
//! The same heap-allocated TopicImpl is exposed as either handle — callers
//! select the view they need via toDDSTopic() / toTopicDescription().

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const nil = @import("nil.zig");
const waitset = @import("waitset.zig");
const filter_mod = @import("filter.zig");
const qos_change = @import("qos_change.zig");
const c_abi_handle = @import("../util/c_abi_handle.zig");
const listener_box_mod = @import("../util/listener_box.zig");
const listener_lane = @import("listener_lane.zig");
const listener_fallback = @import("../util/listener_fallback.zig");
const ListenerBox = listener_box_mod.ListenerBox;
const Mutex = @import("../util/mutex.zig").Mutex;
const extensions_mod = @import("../c_abi/extensions.zig");

// Forward reference: participant is defined in participant.zig.
// We use *anyopaque here to avoid a circular import; the vtable forwarding
// functions cast it to the correct participant type before returning a DDS handle.
// The participant is owned externally; TopicImpl borrows it.

/// A copy of a Topic's TOPIC_DATA bytes, owned, and their generation.
pub const TopicData = struct {
    bytes: []const u8 = &.{},
    gen: u32 = 0,
};

/// What a Topic's participant does with its DataWriters and DataReaders
/// when its TOPIC_DATA changes.
pub const Endpoints = struct {
    /// Prepares their announcements again with the Topic's TOPIC_DATA as it
    /// is now. On failure some may be prepared with it; preparing them
    /// again with the TOPIC_DATA restored undoes that.
    prepare: *const fn (participant: *anyopaque, topic: *TopicImpl) anyerror!void,
    /// Announces again those announced already.
    announce: *const fn (participant: *anyopaque, topic: *TopicImpl) void,
};

/// The callback type of `on_inconsistent_topic`.
pub const InconsistentTopicCb = listener_fallback.Callback(DDS.TopicListener, "on_inconsistent_topic");

/// A participant's listener for a status its Topic's own listener does not
/// take (DDS 1.4 §2.2.4.1.5), resolved but not invoked.
pub const ParticipantFallback = *const fn (participant: *anyopaque, bit: DDS.StatusMask) ?listener_fallback.Resolved(InconsistentTopicCb);

pub const TopicImpl = struct {
    alloc: std.mem.Allocator,
    topic_name: [:0]u8, // owned, null-terminated for C API compatibility
    type_name: [:0]u8, // owned, null-terminated for C API compatibility
    participant_ptr: *anyopaque, // borrowed — points to ParticipantImpl
    /// The DataWriters, DataReaders and ContentFilteredTopics using this
    /// Topic; `delete_topic` refuses while there are any (DDS 1.4
    /// 2.2.2.2.1.6). One stops counting when it is deleted, whether or not a
    /// background callback is still finishing inside it.
    users: std.atomic.Value(u32) = .init(0),
    /// One for the owning participant's list, and one for each user. A deleted
    /// user still finishing, such as a reader with a delivery in flight, keeps
    /// the Topic alive through its own until it is done.
    refs: std.atomic.Value(u32) = .init(1),
    get_participant_fn: *const fn (*anyopaque) DDS.DomainParticipant,
    /// Entity::enable()'s "factory not enabled" precondition -- reads the
    /// owning DomainParticipantImpl's `enabled` flag. A function pointer
    /// rather than an import of participant.zig, matching participant_ptr's
    /// existing opaque-pointer + accessor-function style.
    is_participant_enabled_fn: *const fn (*anyopaque) bool,
    /// Entity::enable() state. Seeded by vtCreateTopic (participant.zig)
    /// from the owning participant's `qos.entity_factory.autoenable_created_entities`.
    /// Topics have no wire footprint of their own -- unlike Publisher/
    /// Subscriber (whose DataWriters/DataReaders defer an outbound SEDP
    /// announcement while disabled), this flag only gates this Topic's own
    /// operations.
    enabled: std.atomic.Value(bool) = .init(true),
    /// Guarded by `qos_mu`.
    qos: DDS.TopicQos,
    /// A leaf: nothing else is locked while it is held, so the participant
    /// reads TOPIC_DATA under its own locks (topicData).
    qos_mu: Mutex = .{},
    /// Guarded by `qos_mu`. Changes with TOPIC_DATA, so an endpoint can tell
    /// whether what it announces is current without keeping a copy.
    topic_data_gen: u32 = 0,
    /// Orders `set_qos` calls, so one changing TOPIC_DATA has its
    /// endpoints' announcements prepared before the next takes effect.
    set_qos_mu: Mutex = .{},
    /// How a change of TOPIC_DATA reaches the announcements of this Topic's
    /// DataWriters and DataReaders. Set by vtCreateTopic (participant.zig).
    endpoints: ?Endpoints = null,
    listener_box: *ListenerBox(DDS.TopicListener),
    /// Replaced registrations whose callbacks may still be running.
    retired_listeners: listener_box_mod.Retired(DDS.TopicListener) = .{},
    /// Guards `listener_box` swaps/acquires only — never held across a
    /// dispatch or any other call (see listener_box.zig).
    listener_mu: Mutex = .{},
    /// Guards status_changes/inconsistent -- mirrors writer.zig's `mu`
    /// (added for the same reason: an unlocked cross-thread getter racing a
    /// locked mutator, confirmed via TSan there; TopicImpl had no
    /// general-purpose mutex at all before this).
    mu: Mutex = .{},
    /// Read by the INCONSISTENT_TOPIC dispatch with `@atomicLoad`
    /// `.monotonic`, as every entity's `listener_mask` is since a
    /// stress-test TSan finding. Initialisers stay plain.
    listener_mask: DDS.StatusMask,
    /// Runs this Topic's listener turns (listener_lane.zig). Each poster
    /// holds a reference, so the lane's owner reference is just another.
    listeners: listener_lane.PendingListeners = .{},
    /// Set by the participant: its listener, when this Topic's own does not
    /// take a status.
    participant_fallback: ?ParticipantFallback = null,
    /// Guarded by the participant's `mu`: INCONSISTENT_TOPIC changed and is
    /// raised once that is released (participant.zig's
    /// `raiseInconsistentTopics`).
    raise_pending: bool = false,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,
    inconsistent: DDS.InconsistentTopicStatus,
    // Topic's primary base is Entity (`Topic : Entity, TopicDescription` —
    // Entity listed first); TopicDescription is a *secondary* base and, per
    // zidl/docs/design/binding-c-abi-identity.md, can't share a
    // box with the primary chain — it keeps its own independent box
    // (`td_c_abi`/`td_views` below), permanently. `c_abi` is shared across
    // every view on the PRIMARY chain instead: Topic, Entity, and (see
    // `views` below and src/c_abi/extensions.zig) ZZDDS.Topic.
    c_abi: c_abi_handle.CachedCAbiHandle = .{},
    td_c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        topic_name: []const u8,
        type_name: []const u8,
        participant_ptr: *anyopaque,
        get_participant_fn: *const fn (*anyopaque) DDS.DomainParticipant,
        is_participant_enabled_fn: *const fn (*anyopaque) bool,
        qos: DDS.TopicQos,
        listener: DDS.TopicListener,
        mask: DDS.StatusMask,
        instance_handle: DDS.InstanceHandle_t,
    ) !*Self {
        // Owns `listener` from here, installed or not: a failure drops the
        // box's hold, which releases it.
        const listener_box = try ListenerBox(DDS.TopicListener).adopt(alloc, listener);
        errdefer listener_box.releaseHold(alloc);
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        const tn = try alloc.dupeSentinel(u8, topic_name, 0);
        errdefer alloc.free(tn);
        const tt = try alloc.dupeSentinel(u8, type_name, 0);
        errdefer alloc.free(tt);
        var qos_clone = try qos.clone(alloc);
        errdefer qos_clone.deinit(alloc);
        self.* = .{
            .alloc = alloc,
            .topic_name = tn,
            .type_name = tt,
            .participant_ptr = participant_ptr,
            .get_participant_fn = get_participant_fn,
            .is_participant_enabled_fn = is_participant_enabled_fn,
            .qos = qos_clone,
            .listener_box = listener_box,
            .listener_mask = mask,
            .instance_handle = instance_handle,
            .status_changes = 0,
            .status_cond = null,
            .inconsistent = .{},
            .listeners = .init(alloc, .{
                .ctx = undefined,
                .acquire = laneAcquire,
                .release = laneRelease,
                .status = dispatchStatusFn,
                .ready = dispatchReadyFn,
            }),
        };
        self.listeners.owner.ctx = self;
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        return self;
    }

    /// Counts a new endpoint or ContentFilteredTopic as using this Topic, and
    /// takes a reference for it. With the owning participant's `mu` held, and
    /// only for a Topic found in its list, so it cannot race `delete_topic`.
    pub fn retain(self: *Self) void {
        _ = self.users.fetchAdd(1, .monotonic);
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Whether anything still uses this Topic.
    pub fn inUse(self: *const Self) bool {
        return self.users.load(.acquire) != 0;
    }

    /// Takes a reference with the owning participant's `mu` held, for a
    /// Topic found in its list.
    pub fn pin(self: *Self) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// A user was deleted. Its reference stays until `release`.
    pub fn endUse(self: *Self) void {
        _ = self.users.fetchSub(1, .acq_rel);
    }

    /// Drops the owning participant's reference: this Topic is deleted, so its
    /// wrappers retire now, even if a deleted user still finishing keeps it
    /// alive a while longer.
    pub fn deleted(self: *Self) void {
        self.listeners.close();
        // Hold no lock here: the listener may call back into it.
        self.listeners.awaitIdle();
        self.c_abi.retire();
        self.td_c_abi.retire();
        if (self.status_cond) |sc| sc.c_abi.retire();
        self.release();
    }

    /// Drops a reference, freeing the Topic with the last one.
    pub fn release(self: *Self) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.destroy();
    }

    fn destroy(self: *Self) void {
        self.listeners.deinit();
        self.retired_listeners.deinit(self.alloc);
        self.listener_box.releaseHold(self.alloc);
        if (self.status_cond) |sc| sc.deinit();
        self.c_abi.free(self.alloc);
        self.td_c_abi.free(self.alloc);
        self.qos.deinit(self.alloc);
        self.alloc.free(self.topic_name);
        self.alloc.free(self.type_name);
        self.alloc.destroy(self);
    }

    // ── DDS.Topic vtable ──────────────────────────────────────────────────────

    pub fn toDDSTopic(self: *Self) DDS.Topic {
        return .{ .ptr = self, .vtable = &topic_vtable };
    }

    pub const topic_vtable = DDS.Topic.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .get_type_name = vtGetTypeName,
        .get_name = vtGetName,
        .get_participant = vtGetParticipant,
        .set_qos = vtSetQos,
        .get_qos = vtGetQos,
        .set_listener = vtSetListener,
        .get_listener = vtGetListener,
        .get_inconsistent_topic_status = vtGetInconsistent,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_Entity = vtAsEntity,
        .as_TopicDescription = vtAsTopicDescription,
    };

    /// One `CAbiViews` value for Topic's PRIMARY chain only (Entity, Topic,
    /// and — via `extensions.zig`'s `topicGetCAbiHandleZzdds`, which shares
    /// this same `c_abi` field/`views` value — ZZDDS.Topic). Does NOT cover
    /// the TopicDescription (secondary-base) view — see `td_views` below and
    /// the `c_abi`/`td_c_abi` field split above.
    pub const views = ZZDDS.Topic.CAbiViews{
        .base = .{
            .base = .{ .flat_vtable = &entity_vtable },
            .flat_vtable = &topic_vtable,
        },
        .flat_vtable = &extensions_mod.topic_vtable,
    };

    fn vtAsEntity(ctx: *anyopaque) DDS.Entity {
        return .{ .ptr = ctx, .vtable = &entity_vtable };
    }

    fn vtAsTopicDescription(ctx: *anyopaque) DDS.TopicDescription {
        return .{ .ptr = ctx, .vtable = &td_vtable };
    }

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
    }

    fn vtEnable(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx);
        if (self.enabled.load(.acquire)) return DDS.RETCODE_OK;
        if (!self.is_participant_enabled_fn(self.participant_ptr)) return DDS.RETCODE_PRECONDITION_NOT_MET;
        self.enabled.store(true, .release);
        // A disabled Topic's listener is not called: an inconsistency
        // counted meanwhile reaches it now.
        self.mu.lock();
        const pending = self.status_changes & DDS.INCONSISTENT_TOPIC_STATUS != 0;
        self.mu.unlock();
        if (pending) self.raiseInconsistent();
        return DDS.RETCODE_OK;
    }

    /// NOT_ENABLED precondition, mirroring participant.zig's identical helper.
    fn checkEnabledPrecondition(self: *Self) DDS.ReturnCode_t {
        return if (self.enabled.load(.acquire)) DDS.RETCODE_OK else DDS.RETCODE_NOT_ENABLED;
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

    fn vtGetTypeName(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).type_name.ptr;
    }

    fn vtGetName(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).topic_name.ptr;
    }

    // Not gated on enabled state -- see publisher.zig's vtGetParticipant
    // comment for why.
    fn vtGetParticipant(ctx: *anyopaque) DDS.DomainParticipant {
        const self = cast(ctx);
        return self.get_participant_fn(self.participant_ptr);
    }

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.TopicQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        if (!qos_change.consistent(DDS.TopicQos, qos)) return DDS.RETCODE_INCONSISTENT_POLICY;
        var new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        defer new_qos.deinit(self.alloc);
        const endpoints = self.endpoints orelse {
            self.swapQos(&new_qos);
            return DDS.RETCODE_OK;
        };
        var changed = false;
        {
            self.set_qos_mu.lock();
            defer self.set_qos_mu.unlock();
            changed = !qos_change.eql(DDS.TopicDataQosPolicy, &self.qos.topic_data, &new_qos.topic_data);
            self.swapQos(&new_qos);
            if (changed) endpoints.prepare(self.participant_ptr, self) catch {
                // Back to the TOPIC_DATA they announce, prepared again for
                // those prepared with the new one already.
                self.swapQos(&new_qos);
                endpoints.prepare(self.participant_ptr, self) catch {};
                return DDS.RETCODE_OUT_OF_RESOURCES;
            };
        }
        // Commits what is prepared last, so a later set_qos announcing
        // first leaves this one nothing to change.
        if (changed) endpoints.announce(self.participant_ptr, self);
        return DDS.RETCODE_OK;
    }

    /// Exchanges `qos` with this Topic's.
    fn swapQos(self: *Self, qos: *DDS.TopicQos) void {
        self.qos_mu.lock();
        defer self.qos_mu.unlock();
        if (!qos_change.eql(DDS.TopicDataQosPolicy, &self.qos.topic_data, &qos.topic_data)) self.topic_data_gen +%= 1;
        std.mem.swap(DDS.TopicQos, &self.qos, qos);
    }

    /// The generation of this Topic's TOPIC_DATA. Takes only `qos_mu`, as
    /// `topicData` does.
    pub fn topicDataGen(self: *Self) u32 {
        self.qos_mu.lock();
        defer self.qos_mu.unlock();
        return self.topic_data_gen;
    }

    /// A copy of this Topic's TOPIC_DATA, with its generation. Takes only
    /// `qos_mu`, so callers may hold their own locks.
    pub fn topicData(self: *Self, alloc: std.mem.Allocator) !TopicData {
        self.qos_mu.lock();
        defer self.qos_mu.unlock();
        const v = &self.qos.topic_data.value;
        const bytes: []const u8 = if (v._buffer) |b| b[0..v._length] else &.{};
        return .{ .bytes = if (bytes.len > 0) try alloc.dupe(u8, bytes) else &.{}, .gen = self.topic_data_gen };
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.TopicQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.qos_mu.lock();
        defer self.qos_mu.unlock();
        qos.* = self.qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.TopicListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        // A callback the setter waits for may delete this Topic: the
        // reference keeps it until the setter is done with it.
        _ = self.refs.fetchAdd(1, .monotonic);
        defer self.release();
        self.swapListener(if (a_listener) |l| l.* else DDS.noop_TopicListener, mask);
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.TopicListener {
        const self = cast(ctx);
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return listener_box_mod.handOut(self.listener_box.listener);
    }

    /// Installs `new_listener` and `mask`, retiring the registration it
    /// replaces (listener_box.zig's `Retired`): a dispatch already using
    /// that one keeps it alive until it returns.
    fn swapListener(self: *Self, new_listener: DDS.TopicListener, mask: DDS.StatusMask) void {
        const new_box = ListenerBox(DDS.TopicListener).create(self.alloc, new_listener) catch
            @panic("zzdds: out of memory boxing listener");
        const upto = self.retired_listeners.install(&self.listener_mu, &self.listener_box, new_box);
        @atomicStore(DDS.StatusMask, &self.listener_mask, mask, .monotonic);
        // From application code, returns once no callback uses what it
        // replaced (docs/design/concurrency/listeners.md#replacement-completion).
        self.retired_listeners.drain(self.alloc, &self.listener_mu, upto, !listener_lane.inCallbackChain());
    }

    fn vtGetInconsistent(ctx: *anyopaque, a_status: *DDS.InconsistentTopicStatus) DDS.ReturnCode_t {
        {
            const rc = cast(ctx).checkEnabledPrecondition();
            if (rc != DDS.RETCODE_OK) return rc;
        }
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        a_status.* = self.inconsistent;
        // Clear the change count after read-out (DDS §2.2.4.1.4).
        self.inconsistent.total_count_change = 0;
        self.status_changes &= ~DDS.INCONSISTENT_TOPIC_STATUS;
        return DDS.RETCODE_OK;
    }

    /// Counts `n` discovered DataWriters or DataReaders on this Topic's name
    /// with another type (DDS 1.4 §2.2.4.1, INCONSISTENT_TOPIC). The caller
    /// raises it afterwards with no participant lock held.
    pub fn recordInconsistent(self: *Self, n: i32) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.inconsistent.total_count += n;
        self.inconsistent.total_count_change += n;
        self.status_changes |= DDS.INCONSISTENT_TOPIC_STATUS;
    }

    /// Wakes the StatusCondition for INCONSISTENT_TOPIC, which changed, then
    /// raises its listener -- see `reader.zig`'s `raise`. The caller holds a
    /// reference.
    pub fn raiseInconsistent(self: *Self) void {
        if (self.status_cond) |sc| sc.notifyWakeup();
        if (!self.listeners.post(DDS.INCONSISTENT_TOPIC_STATUS)) dispatchStatusFn(self, DDS.INCONSISTENT_TOPIC_STATUS);
    }

    fn dispatchStatusFn(ctx: *anyopaque, kind: DDS.StatusMask) void {
        const self = cast(ctx);
        switch (kind) {
            DDS.INCONSISTENT_TOPIC_STATUS => self.dispatchInconsistent(),
            else => unreachable,
        }
    }

    /// A Topic has no reliable-ready events.
    fn dispatchReadyFn(_: *anyopaque, _: listener_lane.ReadyEvent) void {
        unreachable;
    }

    fn laneAcquire(ctx: *anyopaque) bool {
        cast(ctx).pin();
        return true;
    }

    fn laneRelease(ctx: *anyopaque) void {
        cast(ctx).release();
    }

    /// Resolves, then claims under `mu` and invokes after unlocking -- see
    /// `reader.zig`'s `resolveListener`. Not while disabled: `vtEnable`
    /// raises it again.
    fn dispatchInconsistent(self: *Self) void {
        const bit = DDS.INCONSISTENT_TOPIC_STATUS;
        if (!self.enabled.load(.acquire)) return;
        const target = self.resolveListener(bit);
        defer if (target) |t| t.release();
        self.mu.lock();
        const status = self.inconsistent;
        const claimed = target != null and self.status_changes & bit != 0;
        if (claimed) {
            self.status_changes &= ~bit;
            self.inconsistent.total_count_change = 0;
        }
        self.mu.unlock();
        if (claimed) target.?.invoke(vtGetCAbiHandle(self), .{&status});
    }

    /// This Topic's `on_inconsistent_topic`, if its listener has one and
    /// `listener_mask` includes `bit`, otherwise the participant's (DDS 1.4
    /// §2.2.4.1.5), or null. Release the result with no lock held.
    fn resolveListener(self: *Self, bit: DDS.StatusMask) ?listener_fallback.Resolved(InconsistentTopicCb) {
        const mask = @atomicLoad(DDS.StatusMask, &self.listener_mask, .monotonic);
        const r = listener_fallback.resolveBox(InconsistentTopicCb, "on_inconsistent_topic", mask, bit, self.acquireListener(), self.alloc) orelse blk: {
            const fallback = self.participant_fallback orelse return null;
            break :blk fallback(self.participant_ptr, bit) orelse return null;
        };
        // Its identity running elsewhere parks this turn: nothing to invoke.
        if (!listener_lane.admit(r)) {
            r.release();
            return null;
        }
        return r;
    }

    fn acquireListener(self: *Self) *ListenerBox(DDS.TopicListener) {
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.acquireLocked();
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deleted();
    }

    // ── DDS.TopicDescription vtable ──────────────────────────────────────────

    pub fn toTopicDescription(self: *Self) DDS.TopicDescription {
        return .{ .ptr = self, .vtable = &td_vtable };
    }

    pub const td_vtable = DDS.TopicDescription.Vtable{
        .get_type_name = vtGetTypeName,
        .get_name = vtGetName,
        .get_participant = vtGetParticipant,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandleTd,
        .get_allocator = vtGetAllocator,
    };

    /// TopicDescription's own (secondary-base, independently-boxed)
    /// `CAbiViews` — root-shaped since `TopicDescription` itself has no base.
    /// Not shared with `views` above — see the `c_abi`/`td_c_abi` field
    /// split's doc comment.
    const td_views = DDS.TopicDescription.CAbiViews{ .flat_vtable = &td_vtable };

    fn vtGetCAbiHandleTd(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.td_c_abi.get(self.alloc, ctx, &td_views);
    }

    // ── helpers ───────────────────────────────────────────────────────────────

    pub fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    pub const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

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

// ── ContentFilteredTopicImpl ──────────────────────────────────────────────────

/// Returns the ContentFilteredTopicImpl if `td` was created from a CFT, else null.
/// Used by the subscriber to detect CFT topics at DataReader creation time.
pub fn asCft(td: DDS.TopicDescription) ?*ContentFilteredTopicImpl {
    if (td.vtable == &ContentFilteredTopicImpl.td_vtable) {
        return @ptrCast(@alignCast(td.ptr));
    }
    return null;
}

/// A DataWriter's or DataReader's use of its topic. `.none` for an endpoint
/// whose topic is not a participant's: built-in readers, and test fixtures.
pub const TopicUse = union(enum) {
    none,
    topic: *TopicImpl,
    cft: *ContentFilteredTopicImpl,

    /// The endpoint is being deleted, so the topic can be too. Before the
    /// delete returns, which can be well before `release`.
    pub fn end(self: TopicUse) void {
        switch (self) {
            .none => {},
            .topic => |t| t.endUse(),
            .cft => |c| c.endUse(),
        }
    }

    /// Drops the endpoint's reference, at the end of its teardown.
    pub fn release(self: TopicUse) void {
        switch (self) {
            .none => {},
            .topic => |t| t.release(),
            .cft => |c| c.release(),
        }
    }

    /// The Topic whose TOPIC_DATA the endpoint announces: its own, or its
    /// ContentFilteredTopic's related Topic.
    pub fn topicImpl(self: TopicUse) ?*TopicImpl {
        return switch (self) {
            .none => null,
            .topic => |t| t,
            .cft => |c| c.related_impl,
        };
    }

    /// For an endpoint that was never created.
    pub fn abandon(self: TopicUse) void {
        self.end();
        self.release();
    }
};

/// A ContentFilteredTopic restricts the set of samples delivered to a DataReader
/// to those that match a filter expression (SQL-subset on topic fields).
pub const ContentFilteredTopicImpl = struct {
    alloc: std.mem.Allocator,
    name: [:0]u8, // owned, null-terminated for C API
    filter_expr: [:0]u8, // owned, null-terminated for C API
    expr_params: std.ArrayListUnmanaged([]u8), // owned copies
    /// Guards `filter_expr`, `parsed_expr` and `expr_params`.
    /// `set_expression_parameters` and zzdds's `set_filter_expression` run on
    /// an application thread and replace them; `matchSample` runs on the RTPS
    /// receive thread that delivers a sample to a reader built on this CFT
    /// and reads them by reference for the duration of `filter_mod.eval`.
    /// Without this, a concurrent reconfigure frees the strings
    /// mid-evaluation (found by the `lifecycle_churn --scenario cft` stress
    /// test: SEGV in `parseFloat` on a freed parameter). Evaluation for one
    /// CFT is already serialised by the single receive thread, so a plain
    /// mutex (vs. an rwlock) costs nothing in practice; only the rare
    /// reconfigure writer ever blocks.
    params_lock: Mutex = .{},
    /// Filter expressions replaced by `set_filter_expression`, freed at
    /// deinit: `get_filter_expression` returns a borrowed pointer to the
    /// current expression, which a caller may still hold after a change.
    /// One string per change. Guarded by `params_lock`.
    retired_exprs: std.ArrayListUnmanaged([:0]u8) = .empty,
    related: DDS.Topic,
    /// This ContentFilteredTopic's use of `related`, which ends when it is
    /// deleted, and the reference it holds on it until it is freed.
    related_impl: *TopicImpl,
    /// The DataReaders using this ContentFilteredTopic; see `TopicImpl.users`.
    users: std.atomic.Value(u32) = .init(0),
    /// One for the owning participant's list, and one for each user; see
    /// `TopicImpl.refs`. A reader still finishing evaluates the filter through
    /// its own.
    refs: std.atomic.Value(u32) = .init(1),
    participant: DDS.DomainParticipant,
    /// Parsed AST of `filter_expr`; null when expression is empty or the
    /// content-subscription profile is disabled.  AST node slices borrow from
    /// `filter_expr`, so this must be freed before `filter_expr`.
    parsed_expr: ?*filter_mod.AstNode,
    /// One box for the whole object, shared across both interface views
    /// (TopicDescription, ContentFilteredTopic) — see `views` below and
    /// zidl/docs/design/binding-c-abi-identity.md.
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        name: []const u8,
        related_impl: *TopicImpl,
        filter_expr: []const u8,
        expr_params: DDS.StringSeq,
        participant: DDS.DomainParticipant,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const name_copy = try alloc.dupeSentinel(u8, name, 0);
        errdefer alloc.free(name_copy);
        const expr_copy = try alloc.dupeSentinel(u8, filter_expr, 0);
        errdefer alloc.free(expr_copy);

        var params: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (params.items) |p| alloc.free(p);
            params.deinit(alloc);
        }
        // Convert StringSeq (C extern struct) to owned []u8 slices.
        if (expr_params._buffer) |b| {
            for (b[0..expr_params._length]) |p| {
                const copy = try alloc.dupe(u8, std.mem.span(p));
                errdefer alloc.free(copy);
                try params.append(alloc, copy);
            }
        }

        // Parse the filter expression (borrows slices from expr_copy).
        const parsed = try filter_mod.parse(alloc, expr_copy);

        self.* = .{
            .alloc = alloc,
            .name = name_copy,
            .filter_expr = expr_copy,
            .expr_params = params,
            .related = related_impl.toDDSTopic(),
            .related_impl = related_impl,
            .participant = participant,
            .parsed_expr = parsed,
        };
        return self;
    }

    /// Counts a new DataReader as using this ContentFilteredTopic, and takes a
    /// reference for it. With the owning participant's `mu` held, and only for
    /// one found in its list, so it cannot race `delete_contentfilteredtopic`.
    pub fn retain(self: *Self) void {
        _ = self.users.fetchAdd(1, .monotonic);
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Whether any DataReader still uses this ContentFilteredTopic.
    pub fn inUse(self: *const Self) bool {
        return self.users.load(.acquire) != 0;
    }

    /// A DataReader was deleted. Its reference stays until `release`.
    pub fn endUse(self: *Self) void {
        _ = self.users.fetchSub(1, .acq_rel);
    }

    /// Drops the owning participant's reference: this ContentFilteredTopic is
    /// deleted, so it no longer uses its related Topic and its wrapper retires,
    /// even if a reader still finishing keeps it alive a while longer.
    pub fn deleted(self: *Self) void {
        self.c_abi.retire();
        self.related_impl.endUse();
        self.release();
    }

    /// Drops a reference, freeing the ContentFilteredTopic with the last one,
    /// and with it the reference to its related Topic.
    pub fn release(self: *Self) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.destroy();
    }

    fn destroy(self: *Self) void {
        const related_impl = self.related_impl;
        // Free the AST before the expression string (AST slices borrow from it).
        if (self.parsed_expr) |ast| filter_mod.freeAst(self.alloc, ast);
        for (self.retired_exprs.items) |e| self.alloc.free(e);
        self.retired_exprs.deinit(self.alloc);
        self.c_abi.free(self.alloc);
        for (self.expr_params.items) |p| self.alloc.free(p);
        self.expr_params.deinit(self.alloc);
        self.alloc.free(self.filter_expr);
        self.alloc.free(self.name);
        self.alloc.destroy(self);
        related_impl.release();
    }

    /// Evaluate the filter expression against a sample.
    /// Returns true if the sample passes the filter (should be delivered).
    /// An empty expression or disabled profile always returns true.
    pub fn matchSample(
        self: *Self,
        accessor: filter_mod.FieldAccessor,
    ) bool {
        // Held across the whole eval: the AST holds `params_slice` entries
        // by reference (see `params_lock`).
        self.params_lock.lock();
        defer self.params_lock.unlock();
        const params_slice: []const []const u8 = @ptrCast(self.expr_params.items);
        return filter_mod.eval(self.parsed_expr, accessor, params_slice);
    }

    /// zzdds::ContentFilteredTopic::set_filter_expression: replaces the filter
    /// expression and its parameters together. Everything that can fail (parse,
    /// copies, retired-list capacity) happens before the swap, so on error the
    /// filter is unchanged: BAD_PARAMETER for a malformed expression,
    /// OUT_OF_RESOURCES otherwise.
    pub fn setFilterExpression(
        self: *Self,
        filter_expression: []const u8,
        expression_parameters: ?*const DDS.StringSeq,
    ) DDS.ReturnCode_t {
        const expr_copy = self.alloc.dupeSentinel(u8, filter_expression, 0) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        var expr_owned = true;
        defer if (expr_owned) self.alloc.free(expr_copy);
        const parsed = filter_mod.parse(self.alloc, expr_copy) catch |err| return switch (err) {
            error.OutOfMemory => DDS.RETCODE_OUT_OF_RESOURCES,
            else => DDS.RETCODE_BAD_PARAMETER,
        };
        var parsed_owned = true;
        defer if (parsed_owned) if (parsed) |ast| filter_mod.freeAst(self.alloc, ast);
        var params: std.ArrayListUnmanaged([]u8) = .empty;
        defer {
            for (params.items) |p| self.alloc.free(p);
            params.deinit(self.alloc);
        }
        if (expression_parameters) |seq| if (seq._buffer) |b| {
            for (b[0..seq._length]) |p| {
                const copy = self.alloc.dupe(u8, std.mem.span(p)) catch return DDS.RETCODE_OUT_OF_RESOURCES;
                params.append(self.alloc, copy) catch {
                    self.alloc.free(copy);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
            }
        };

        self.params_lock.lock();
        defer self.params_lock.unlock();
        self.retired_exprs.ensureUnusedCapacity(self.alloc, 1) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        // The old AST is unreachable once swapped out (matchSample holds this
        // lock while evaluating); the old string may still be borrowed.
        if (self.parsed_expr) |ast| filter_mod.freeAst(self.alloc, ast);
        self.retired_exprs.appendAssumeCapacity(self.filter_expr);
        self.filter_expr = expr_copy;
        self.parsed_expr = parsed;
        std.mem.swap(std.ArrayListUnmanaged([]u8), &self.expr_params, &params);
        expr_owned = false;
        parsed_owned = false;
        return DDS.RETCODE_OK;
    }

    pub fn toDDSContentFilteredTopic(self: *Self) DDS.ContentFilteredTopic {
        return .{ .ptr = self, .vtable = &cft_vtable };
    }

    /// Returns a TopicDescription for use as the `a_topic` argument to
    /// Subscriber.create_datareader.
    pub fn toTopicDescription(self: *Self) DDS.TopicDescription {
        return .{ .ptr = self, .vtable = &td_vtable };
    }

    // ── DDS.TopicDescription vtable ──────────────────────────────────────────

    // For RTPS subscription matching the DataReader must advertise the related
    // (underlying) topic name, not the CFT alias.  The DDS spec's `get_name()`
    // on ContentFilteredTopic returns the CFT name, but that name is only
    // meaningful at the application level; the wire protocol matches on the
    // related topic.  We therefore return the related topic name here so that
    // create_datareader can pass it straight through to create_proto_reader.
    pub const td_vtable = DDS.TopicDescription.Vtable{
        .get_type_name = tdGetTypeName,
        .get_name = tdGetRelatedName,
        .get_participant = tdGetParticipant,
        .deinit = tdDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

    fn tdGetTypeName(ctx: *anyopaque) [*:0]const u8 {
        const r = cast(ctx).related;
        return r.vtable.get_type_name(r.ptr);
    }
    fn tdGetName(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).name.ptr;
    }
    fn tdGetRelatedName(ctx: *anyopaque) [*:0]const u8 {
        const r = cast(ctx).related;
        return r.vtable.get_name(r.ptr);
    }
    fn tdGetParticipant(ctx: *anyopaque) DDS.DomainParticipant {
        return cast(ctx).participant;
    }
    fn tdDeinit(_: *anyopaque) void {} // lifecycle owned by participant via cft_topics list

    // ── DDS.ContentFilteredTopic vtable ──────────────────────────────────────

    pub const cft_vtable = DDS.ContentFilteredTopic.Vtable{
        .get_type_name = tdGetTypeName,
        .get_name = tdGetName,
        .get_participant = tdGetParticipant,
        .get_filter_expression = cftGetExpr,
        .get_expression_parameters = cftGetParams,
        .set_expression_parameters = cftSetParams,
        .get_related_topic = cftGetRelated,
        .deinit = cftDeinit,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
        .as_TopicDescription = cftAsTopicDescription,
    };

    /// One `CAbiViews` value for the whole object, shared between both
    /// interface views (TopicDescription, ContentFilteredTopic) — see
    /// `GuardConditionImpl.views`'s identical-shape doc comment.
    /// The zzdds::ContentFilteredTopic view (set_filter_expression) shares
    /// the same box.
    pub const views = ZZDDS.ContentFilteredTopic.CAbiViews{
        .base = .{
            .base = .{ .flat_vtable = &td_vtable },
            .flat_vtable = &cft_vtable,
        },
        .flat_vtable = &extensions_mod.cft_vtable,
    };

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self = cast(ctx);
        return self.c_abi.get(self.alloc, ctx, &views);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        return cast(ctx).alloc;
    }

    fn cftAsTopicDescription(ctx: *anyopaque) DDS.TopicDescription {
        return .{ .ptr = ctx, .vtable = &td_vtable };
    }

    fn cftGetExpr(ctx: *anyopaque) [*:0]const u8 {
        const self = cast(ctx);
        self.params_lock.lock();
        defer self.params_lock.unlock();
        return self.filter_expr.ptr;
    }

    fn cftGetParams(ctx: *anyopaque, out: ?*DDS.StringSeq) DDS.ReturnCode_t {
        const seq = out orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        self.params_lock.lock();
        defer self.params_lock.unlock();
        if (seq._release) {
            if (seq._buffer) |b| {
                for (b[0..seq._length]) |s| self.alloc.free(std.mem.span(s));
                self.alloc.free(b[0..seq._maximum]);
            }
        }
        seq.* = .{};
        const n = self.expr_params.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.alloc([*:0]const u8, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (self.expr_params.items, 0..) |p, i| {
            buf[i] = (self.alloc.dupeSentinel(u8, p, 0) catch {
                for (buf[0..i]) |s| self.alloc.free(std.mem.span(s));
                self.alloc.free(buf);
                return DDS.RETCODE_OUT_OF_RESOURCES;
            }).ptr;
        }
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
        return DDS.RETCODE_OK;
    }

    fn cftSetParams(ctx: *anyopaque, params: ?*const DDS.StringSeq) DDS.ReturnCode_t {
        const self = cast(ctx);
        // Build into a temporary list first so the old params survive any OOM.
        var tmp: std.ArrayListUnmanaged([]u8) = .empty;
        const seq = params orelse {
            self.params_lock.lock();
            defer self.params_lock.unlock();
            for (self.expr_params.items) |p| self.alloc.free(p);
            self.expr_params.clearRetainingCapacity();
            return DDS.RETCODE_OK;
        };
        if (seq._buffer) |b| {
            for (b[0..seq._length]) |p| {
                const copy = self.alloc.dupe(u8, std.mem.span(p)) catch {
                    for (tmp.items) |s| self.alloc.free(s);
                    tmp.deinit(self.alloc);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
                tmp.append(self.alloc, copy) catch {
                    self.alloc.free(copy);
                    for (tmp.items) |s| self.alloc.free(s);
                    tmp.deinit(self.alloc);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
            }
        }
        // All copies succeeded — swap in and free old under the exclusive
        // lock so no receive thread is mid-eval on the outgoing strings.
        self.params_lock.lock();
        defer self.params_lock.unlock();
        for (self.expr_params.items) |p| self.alloc.free(p);
        self.expr_params.deinit(self.alloc);
        self.expr_params = tmp;
        return DDS.RETCODE_OK;
    }

    fn cftGetRelated(ctx: *anyopaque) DDS.Topic {
        return cast(ctx).related;
    }
    fn cftDeinit(ctx: *anyopaque) void {
        cast(ctx).deleted();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
