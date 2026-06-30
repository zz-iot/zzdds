//! TopicImpl — DDS Topic and TopicDescription implementation.
//!
//! A Topic is the named, typed channel within a DomainParticipant.
//! It implements both the DDS.Topic and DDS.TopicDescription vtable interfaces.
//! The same heap-allocated TopicImpl is exposed as either handle — callers
//! select the view they need via toDDSTopic() / toTopicDescription().

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const waitset = @import("waitset.zig");
const filter_mod = @import("filter.zig");

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
    listener: DDS.TopicListener,
    listener_mask: DDS.StatusMask,
    instance_handle: DDS.InstanceHandle_t,
    status_changes: DDS.StatusMask,
    status_cond: ?*waitset.StatusConditionImpl,
    inconsistent: DDS.InconsistentTopicStatus,

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
        self.* = .{
            .alloc = alloc,
            .topic_name = tn,
            .type_name = tt,
            .participant_ptr = participant_ptr,
            .get_participant_fn = get_participant_fn,
            .qos = qos_clone,
            .listener = listener,
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
        if (self.status_cond) |sc| sc.deinit();
        self.qos.deinit(self.alloc);
        self.alloc.free(self.topic_name);
        self.alloc.free(self.type_name);
        self.alloc.destroy(self);
    }

    // ── DDS.Topic vtable ──────────────────────────────────────────────────────

    pub fn toDDSTopic(self: *Self) DDS.Topic {
        return .{ .ptr = self, .vtable = &topic_vtable };
    }

    const topic_vtable = DDS.Topic.Vtable{
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
        self.listener = if (a_listener) |l| l.* else DDS.noop_TopicListener;
        self.listener_mask = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetListener(ctx: *anyopaque) DDS.TopicListener {
        return cast(ctx).listener;
    }

    fn vtGetInconsistent(ctx: *anyopaque, a_status: *DDS.InconsistentTopicStatus) DDS.ReturnCode_t {
        const self = cast(ctx);
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

    const td_vtable = DDS.TopicDescription.Vtable{
        .get_type_name = vtGetTypeName,
        .get_name = vtGetName,
        .get_participant = vtGetParticipant,
        .deinit = vtDeinit,
    };

    // ── helpers ───────────────────────────────────────────────────────────────

    pub fn toEntity(self: *Self) DDS.Entity {
        return .{ .ptr = self, .vtable = &entity_vtable };
    }

    const entity_vtable = DDS.Entity.Vtable{
        .enable = vtEnable,
        .get_statuscondition = vtGetStatusCond,
        .get_status_changes = vtGetStatusChanges,
        .get_instance_handle = vtGetHandle,
        .deinit = vtDeinit,
    };

    fn getStatusFn(entity_ptr: *anyopaque) DDS.StatusMask {
        return cast(entity_ptr).status_changes;
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
    related: DDS.Topic,
    participant: DDS.DomainParticipant,
    /// Parsed AST of `filter_expr`; null when expression is empty or the
    /// content-subscription profile is disabled.  AST node slices borrow from
    /// `filter_expr`, so this must be freed before `filter_expr`.
    parsed_expr: ?*filter_mod.AstNode,

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
        self: *const Self,
        accessor: filter_mod.FieldAccessor,
    ) bool {
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
    const td_vtable = DDS.TopicDescription.Vtable{
        .get_type_name = tdGetTypeName,
        .get_name = tdGetRelatedName,
        .get_participant = tdGetParticipant,
        .deinit = tdDeinit,
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

    const cft_vtable = DDS.ContentFilteredTopic.Vtable{
        .get_type_name = tdGetTypeName,
        .get_name = tdGetName,
        .get_participant = tdGetParticipant,
        .get_filter_expression = cftGetExpr,
        .get_expression_parameters = cftGetParams,
        .set_expression_parameters = cftSetParams,
        .get_related_topic = cftGetRelated,
        .deinit = cftDeinit,
    };

    fn cftGetExpr(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).filter_expr.ptr;
    }

    fn cftGetParams(ctx: *anyopaque, out: ?*DDS.StringSeq) DDS.ReturnCode_t {
        const seq = out orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
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
        // All copies succeeded — swap in and free old.
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
