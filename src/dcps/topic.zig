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
const c_abi_handle = @import("../util/c_abi_handle.zig");
const ListenerBox = @import("../util/listener_box.zig").ListenerBox;
const Mutex = @import("../util/mutex.zig").Mutex;
const extensions_mod = @import("../c_abi/extensions.zig");

// Forward reference: participant is defined in participant.zig.
// We use *anyopaque here to avoid a circular import; the vtable forwarding
// functions cast it to the correct participant type before returning a DDS handle.
// The participant is owned externally; TopicImpl borrows it.

pub const TopicImpl = struct {
    alloc: std.mem.Allocator,
    topic_name: [:0]u8, // owned, null-terminated for C API compatibility
    type_name: [:0]u8, // owned, null-terminated for C API compatibility
    participant_ptr: *anyopaque, // borrowed — points to ParticipantImpl
    get_participant_fn: *const fn (*anyopaque) DDS.DomainParticipant,
    qos: DDS.TopicQos,
    listener_box: *ListenerBox(DDS.TopicListener),
    /// Guards `listener_box` swaps/acquires only — never held across a
    /// dispatch or any other call (see listener_box.zig).
    listener_mu: Mutex = .{},
    /// Guards status_changes/inconsistent -- mirrors writer.zig's `mu`
    /// (added for the same reason: an unlocked cross-thread getter racing a
    /// locked mutator, confirmed via TSan there; TopicImpl had no
    /// general-purpose mutex at all before this).
    mu: Mutex = .{},
    /// No topic-listener dispatch path reads this today, but it is the same
    /// concept as the writer/reader/publisher/subscriber/participant
    /// `listener_mask` (all made `@atomicStore`/`@atomicLoad` `.monotonic`
    /// after a stress-test TSan finding) -- kept atomic here too so a
    /// future `on_inconsistent_topic` fallback path can't reintroduce the
    /// race. Initialisers stay plain.
    listener_mask: DDS.StatusMask,
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
        qos: DDS.TopicQos,
        listener: DDS.TopicListener,
        mask: DDS.StatusMask,
        instance_handle: DDS.InstanceHandle_t,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        const tn = try alloc.dupeZ(u8, topic_name);
        errdefer alloc.free(tn);
        const tt = try alloc.dupeZ(u8, type_name);
        errdefer alloc.free(tt);
        var qos_clone = try qos.clone(alloc);
        errdefer qos_clone.deinit(alloc);
        const listener_box = try ListenerBox(DDS.TopicListener).create(alloc, listener);
        errdefer alloc.destroy(listener_box);
        self.* = .{
            .alloc = alloc,
            .topic_name = tn,
            .type_name = tt,
            .participant_ptr = participant_ptr,
            .get_participant_fn = get_participant_fn,
            .qos = qos_clone,
            .listener_box = listener_box,
            .listener_mask = mask,
            .instance_handle = instance_handle,
            .status_changes = 0,
            .status_cond = null,
            .inconsistent = .{},
        };
        const sc = try waitset.StatusConditionImpl.init(alloc, self.toEntity(), getStatusFn);
        self.status_cond = sc;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.listener_box.releaseRef(self.alloc);
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

    fn vtGetTypeName(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).type_name.ptr;
    }

    fn vtGetName(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).topic_name.ptr;
    }

    fn vtGetParticipant(ctx: *anyopaque) DDS.DomainParticipant {
        const self = cast(ctx);
        return self.get_participant_fn(self.participant_ptr);
    }

    fn vtSetQos(ctx: *anyopaque, qos: *const DDS.TopicQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        const new_qos = qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        self.qos.deinit(self.alloc);
        self.qos = new_qos;
        return DDS.RETCODE_OK;
    }

    fn vtGetQos(ctx: *anyopaque, qos: *DDS.TopicQos) DDS.ReturnCode_t {
        const self = cast(ctx);
        qos.* = self.qos.clone(self.alloc) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        return DDS.RETCODE_OK;
    }

    fn vtSetListener(ctx: *anyopaque, a_listener: ?*const DDS.TopicListener, mask: DDS.StatusMask) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.swapListener(if (a_listener) |l| l.* else DDS.noop_TopicListener);
        @atomicStore(DDS.StatusMask, &self.listener_mask, mask, .monotonic);
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.TopicListener {
        const self = cast(ctx);
        self.listener_mu.lock();
        defer self.listener_mu.unlock();
        return self.listener_box.listener;
    }

    /// Installs `new_listener`, releasing whatever it replaces. Safe against
    /// a concurrently in-flight dispatch acquired via `acquireListener` (see
    /// listener_box.zig).
    fn swapListener(self: *Self, new_listener: DDS.TopicListener) void {
        const new_box = ListenerBox(DDS.TopicListener).create(self.alloc, new_listener) catch
            @panic("zzdds: out of memory boxing listener");
        self.listener_mu.lock();
        const old_box = self.listener_box;
        self.listener_box = new_box;
        self.listener_mu.unlock();
        old_box.releaseRef(self.alloc);
    }

    fn vtGetInconsistent(ctx: *anyopaque, a_status: *DDS.InconsistentTopicStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.mu.lock();
        defer self.mu.unlock();
        a_status.* = self.inconsistent;
        // Clear the change count after read-out (DDS §2.2.4.1.4).
        self.inconsistent.total_count_change = 0;
        self.status_changes &= ~DDS.INCONSISTENT_TOPIC_STATUS;
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
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

/// A ContentFilteredTopic restricts the set of samples delivered to a DataReader
/// to those that match a filter expression (SQL-subset on topic fields).
pub const ContentFilteredTopicImpl = struct {
    alloc: std.mem.Allocator,
    name: [:0]u8, // owned, null-terminated for C API
    filter_expr: [:0]u8, // owned, null-terminated for C API
    expr_params: std.ArrayListUnmanaged([]u8), // owned copies
    /// Guards `expr_params` only. `set_expression_parameters` runs on an
    /// application thread and frees + replaces the whole list; `matchSample`
    /// runs on the RTPS receive thread that delivers a sample to a reader
    /// built on this CFT and reads the list by reference for the duration of
    /// `filter_mod.eval`. Without this, a concurrent reconfigure frees the
    /// strings mid-evaluation (found by the `lifecycle_churn --scenario cft`
    /// stress test: SEGV in `parseFloat` on a freed parameter). Evaluation
    /// for one CFT is already serialised by the single receive thread, so a
    /// plain mutex (vs. an rwlock) costs nothing in practice; only the rare
    /// reconfigure writer ever blocks. `filter_expr`/`parsed_expr` are set
    /// once at init and need no guard.
    params_lock: Mutex = .{},
    related: DDS.Topic,
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
        related: DDS.Topic,
        filter_expr: []const u8,
        expr_params: DDS.StringSeq,
        participant: DDS.DomainParticipant,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const name_copy = try alloc.dupeZ(u8, name);
        errdefer alloc.free(name_copy);
        const expr_copy = try alloc.dupeZ(u8, filter_expr);
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
            .related = related,
            .participant = participant,
            .parsed_expr = parsed,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        // Free the AST before the expression string (AST slices borrow from it).
        if (self.parsed_expr) |ast| filter_mod.freeAst(self.alloc, ast);
        self.c_abi.free(self.alloc);
        for (self.expr_params.items) |p| self.alloc.free(p);
        self.expr_params.deinit(self.alloc);
        self.alloc.free(self.filter_expr);
        self.alloc.free(self.name);
        self.alloc.destroy(self);
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
    pub const views = DDS.ContentFilteredTopic.CAbiViews{
        .base = .{ .flat_vtable = &td_vtable },
        .flat_vtable = &cft_vtable,
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
        return cast(ctx).filter_expr.ptr;
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
            buf[i] = (self.alloc.dupeZ(u8, p) catch {
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
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
