//! WaitSet, ReadCondition, GuardCondition, StatusCondition implementations.
//!
//! Phase 21: condvar-based WaitSet.wait() with push notification.
//!
//! Notification architecture:
//!   - GuardCondition / StatusCondition hold a WakeupList; WaitSet registers a
//!     WakeupHandle when attaching.  On trigger, notifyAll() wakes the condvar.
//!   - ReadCondition uses a DataNotifyFn round-trip through DataReader: WaitSet
//!     registers via add_notify_fn; DataReader calls on_data on every delivery.
//!
//! Lock ordering (no cycles):
//!   WaitSet.mu (conditions) → Reader.mu (data_notifiers) → WaitSet.cv_mu
//!   WakeupList.mu → WaitSet.cv_mu

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const nil = @import("nil.zig");
const filter_mod = @import("filter.zig");
const Mutex = @import("../util/mutex.zig").Mutex;
const Condvar = @import("../util/condvar.zig").Condvar;
const time_mod = @import("../util/time.zig");

// ── Push-notification types ───────────────────────────────────────────────────

/// Wakeup callback registered by a WaitSet with a Guard/StatusCondition.
pub const WakeupHandle = struct {
    ctx: *anyopaque,
    wake: *const fn (*anyopaque) void,
};

/// Callback registered by a WaitSet (via ReadCondition) in the DataReader.
/// DataReader calls `on_data(ctx)` each time new data arrives.
pub const DataNotifyFn = struct {
    ctx: *anyopaque,
    on_data: *const fn (*anyopaque) void,
};

/// Fixed-size registry of WakeupHandle registrations, protected by its own mutex.
/// Supports up to WAKEUP_SLOTS concurrent WaitSets per condition.
const WAKEUP_SLOTS = 4;
pub const WakeupList = struct {
    slots: [WAKEUP_SLOTS]?WakeupHandle = [_]?WakeupHandle{null} ** WAKEUP_SLOTS,
    mu: Mutex = .{},

    pub fn register(self: *WakeupList, h: WakeupHandle) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.slots) |*s| {
            if (s.* == null) {
                s.* = h;
                return true;
            }
        }
        return false;
    }

    pub fn unregister(self: *WakeupList, ctx: *anyopaque) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (&self.slots) |*s| {
            if (s.*) |h| {
                if (h.ctx == ctx) {
                    s.* = null;
                    return;
                }
            }
        }
    }

    /// Call wake() on every registered handle.
    /// Holds self.mu while doing so; callee must not re-acquire self.mu.
    pub fn notifyAll(self: *WakeupList) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.slots) |maybe_h| {
            if (maybe_h) |h| h.wake(h.ctx);
        }
    }
};

// ── WaitSetImpl ───────────────────────────────────────────────────────────────

pub const WaitSetImpl = struct {
    alloc: std.mem.Allocator,
    conditions: std.ArrayListUnmanaged(DDS.Condition),
    mu: Mutex, // protects `conditions`
    cv_mu: Mutex, // protects `notified`
    cv_cond: Condvar,
    notified: bool,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .conditions = .empty,
            .mu = .{},
            .cv_mu = .{},
            .cv_cond = .{},
            .notified = false,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.conditions.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    pub fn toDDSWaitSet(self: *Self) DDS.WaitSet {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = DDS.WaitSet.Vtable{
        .wait = vtWait,
        .attach_condition = vtAttach,
        .detach_condition = vtDetach,
        .get_conditions = vtGetConditions,
        .deinit = vtDeinit,
    };

    /// Condvar-based wait: blocks until at least one attached condition is
    /// triggered or the timeout elapses.  Triggered conditions are appended
    /// to `active_conditions`.  Uses a `notified` flag to prevent missed
    /// wakeups in the window between the condition check and the condvar wait.
    fn vtWait(ctx: *anyopaque, active: ?*DDS.ConditionSeq, timeout: *const DDS.Duration_t) DDS.ReturnCode_t {
        const seq = active orelse return DDS.RETCODE_BAD_PARAMETER;
        const self: *Self = @ptrCast(@alignCast(ctx));
        // Reset the output sequence so stale entries from a prior call don't accumulate.
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const deadline_ns: ?i64 = blk: {
            if (timeout.sec == DDS.DURATION_INFINITE_SEC and
                timeout.nanosec == DDS.DURATION_INFINITE_NSEC)
            {
                break :blk null;
            }
            const now = time_mod.nanoTimestamp();
            break :blk now +
                @as(i64, timeout.sec) * std.time.ns_per_s +
                @as(i64, timeout.nanosec);
        };

        while (true) {
            // Collect triggered conditions under the conditions lock.
            self.mu.lock();
            var any = false;
            for (self.conditions.items) |cond| {
                if (cond.get_trigger_value()) {
                    // Grow sequence by one.
                    const old_n = seq._length;
                    const new_buf = self.alloc.alloc(DDS.Condition, old_n + 1) catch {
                        if (seq._release) {
                            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
                        }
                        seq.* = .{};
                        self.mu.unlock();
                        return DDS.RETCODE_OUT_OF_RESOURCES;
                    };
                    if (seq._buffer) |ob| @memcpy(new_buf[0..old_n], ob[0..old_n]);
                    if (seq._release) {
                        if (seq._buffer) |ob| self.alloc.free(ob[0..old_n]);
                    }
                    new_buf[old_n] = cond;
                    seq._buffer = new_buf.ptr;
                    seq._length = old_n + 1;
                    seq._maximum = old_n + 1;
                    seq._release = true;
                    any = true;
                }
            }
            self.mu.unlock();
            if (any) return DDS.RETCODE_OK;

            // Block until notification or deadline.
            self.cv_mu.lock();
            // Consume a pending notification instead of waiting.
            if (self.notified) {
                self.notified = false;
                self.cv_mu.unlock();
                continue;
            }
            if (deadline_ns) |dl| {
                const now = time_mod.nanoTimestamp();
                if (now >= dl) {
                    self.cv_mu.unlock();
                    return DDS.RETCODE_TIMEOUT;
                }
                const remaining: u64 = @intCast(dl - now);
                self.cv_cond.timedWaitNs(&self.cv_mu, remaining) catch {
                    // TIMEDOUT: cv_mu is still held.
                    self.notified = false;
                    self.cv_mu.unlock();
                    return DDS.RETCODE_TIMEOUT;
                };
            } else {
                self.cv_cond.wait(&self.cv_mu);
            }
            self.notified = false;
            self.cv_mu.unlock();
        }
    }

    fn vtAttach(ctx: *anyopaque, cond: DDS.Condition) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.conditions.items) |c| {
            if (c.ptr == cond.ptr) return DDS.RETCODE_OK;
        }
        self.conditions.append(self.alloc, cond) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        // Register push-notification with the condition.
        const h = WakeupHandle{ .ctx = self, .wake = wakeNotify };
        if (cond.vtable == &ReadConditionImpl.cond_vtable) {
            const rc: *ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
            rc.add_notify_fn(rc.reader_ctx, DataNotifyFn{ .ctx = self, .on_data = wakeNotify });
        } else if (cond.vtable == &StatusConditionImpl.cond_vtable) {
            const sc: *StatusConditionImpl = @ptrCast(@alignCast(cond.ptr));
            _ = sc.wakeups.register(h);
        } else if (cond.vtable == &GuardConditionImpl.cond_vtable) {
            const gc: *GuardConditionImpl = @ptrCast(@alignCast(cond.ptr));
            _ = gc.wakeups.register(h);
        }
        return DDS.RETCODE_OK;
    }

    fn vtDetach(ctx: *anyopaque, cond: DDS.Condition) DDS.ReturnCode_t {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        for (self.conditions.items, 0..) |c, i| {
            if (c.ptr == cond.ptr) {
                _ = self.conditions.swapRemove(i);
                // Unregister push-notification from the condition.
                if (cond.vtable == &ReadConditionImpl.cond_vtable) {
                    const rc: *ReadConditionImpl = @ptrCast(@alignCast(cond.ptr));
                    rc.remove_notify_fn(rc.reader_ctx, self);
                } else if (cond.vtable == &StatusConditionImpl.cond_vtable) {
                    const sc: *StatusConditionImpl = @ptrCast(@alignCast(cond.ptr));
                    sc.wakeups.unregister(self);
                } else if (cond.vtable == &GuardConditionImpl.cond_vtable) {
                    const gc: *GuardConditionImpl = @ptrCast(@alignCast(cond.ptr));
                    gc.wakeups.unregister(self);
                }
                return DDS.RETCODE_OK;
            }
        }
        return DDS.RETCODE_PRECONDITION_NOT_MET;
    }

    fn vtGetConditions(ctx: *anyopaque, out: ?*DDS.ConditionSeq) DDS.ReturnCode_t {
        const seq = out orelse return DDS.RETCODE_BAD_PARAMETER;
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.mu.lock();
        defer self.mu.unlock();
        if (seq._release) {
            if (seq._buffer) |ob| self.alloc.free(ob[0..seq._maximum]);
        }
        seq.* = .{};
        const n = self.conditions.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.dupe(DDS.Condition, self.conditions.items) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        seq._buffer = buf.ptr;
        seq._length = @intCast(n);
        seq._maximum = @intCast(n);
        seq._release = true;
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    /// Called from condition notification paths to unblock vtWait.
    fn wakeNotify(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.cv_mu.lock();
        self.notified = true;
        self.cv_cond.broadcast();
        self.cv_mu.unlock();
    }
};

// ── GuardConditionImpl ────────────────────────────────────────────────────────

pub const GuardConditionImpl = struct {
    alloc: std.mem.Allocator,
    trigger: bool,
    wakeups: WakeupList,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !*Self {
        const self = try alloc.create(Self);
        self.* = .{ .alloc = alloc, .trigger = false, .wakeups = .{} };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.alloc.destroy(self);
    }

    pub fn toDDSGuardCondition(self: *Self) DDS.GuardCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toCondition(self: *Self) DDS.Condition {
        return .{ .ptr = self, .vtable = &cond_vtable };
    }

    const vtable = DDS.GuardCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .set_trigger_value = vtSetTrigger,
        .deinit = vtDeinit,
    };

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
    };

    fn vtGetTrigger(ctx: *anyopaque) bool {
        return cast(ctx).trigger;
    }

    fn vtSetTrigger(ctx: *anyopaque, value: bool) DDS.ReturnCode_t {
        const self = cast(ctx);
        self.trigger = value;
        if (value) self.wakeups.notifyAll();
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// ── ReadConditionImpl ─────────────────────────────────────────────────────────

/// A ReadCondition is triggered when its DataReader has at least one sample
/// matching the state mask triple.
///
/// Push notification is routed through the DataReader: when a WaitSet
/// attaches this condition, `add_notify_fn` registers a `DataNotifyFn` in the
/// DataReader's `data_notifiers` list.  On each delivery `on_data` fires,
/// which calls `WaitSetImpl.wakeNotify` to broadcast the condvar.
pub const ReadConditionImpl = struct {
    alloc: std.mem.Allocator,
    reader: DDS.DataReader,
    sample_state_mask: DDS.SampleStateMask,
    view_state_mask: DDS.ViewStateMask,
    instance_state_mask: DDS.InstanceStateMask,
    /// Returns true if the reader has pending data matching the masks.
    has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
    /// Opaque pointer to the owning DataReaderImpl (used by add/remove_notify_fn).
    reader_ctx: *anyopaque,
    /// Called by vtAttach: adds a DataNotifyFn to the DataReader.
    add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) void,
    /// Called by vtDetach: removes the DataNotifyFn keyed by waitset_ctx pointer.
    remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        reader: DDS.DataReader,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
        has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
        reader_ctx: *anyopaque,
        add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) void,
        remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .reader = reader,
            .sample_state_mask = sample_states,
            .view_state_mask = view_states,
            .instance_state_mask = instance_states,
            .has_data_fn = has_data_fn,
            .reader_ctx = reader_ctx,
            .add_notify_fn = add_notify_fn,
            .remove_notify_fn = remove_notify_fn,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.alloc.destroy(self);
    }

    pub fn toDDSReadCondition(self: *Self) DDS.ReadCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toCondition(self: *Self) DDS.Condition {
        return .{ .ptr = self, .vtable = &cond_vtable };
    }

    const vtable = DDS.ReadCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_sample_state_mask = vtGetSampleMask,
        .get_view_state_mask = vtGetViewMask,
        .get_instance_state_mask = vtGetInstMask,
        .get_datareader = vtGetReader,
        .deinit = vtDeinit,
    };

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
    };

    fn vtGetTrigger(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.has_data_fn(self.reader.ptr);
    }

    fn vtGetSampleMask(ctx: *anyopaque) DDS.SampleStateMask {
        return cast(ctx).sample_state_mask;
    }

    fn vtGetViewMask(ctx: *anyopaque) DDS.ViewStateMask {
        return cast(ctx).view_state_mask;
    }

    fn vtGetInstMask(ctx: *anyopaque) DDS.InstanceStateMask {
        return cast(ctx).instance_state_mask;
    }

    fn vtGetReader(ctx: *anyopaque) DDS.DataReader {
        return cast(ctx).reader;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// ── StatusConditionImpl ───────────────────────────────────────────────────────

/// Bound to a single DDS entity.  Triggered when
/// (entity.status_changes & enabled_statuses) != 0.
pub const StatusConditionImpl = struct {
    alloc: std.mem.Allocator,
    entity: DDS.Entity,
    enabled_statuses: DDS.StatusMask,
    get_status_fn: *const fn (entity_ptr: *anyopaque) DDS.StatusMask,
    wakeups: WakeupList,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        entity: DDS.Entity,
        get_status_fn: *const fn (entity_ptr: *anyopaque) DDS.StatusMask,
    ) !*Self {
        const self = try alloc.create(Self);
        self.* = .{
            .alloc = alloc,
            .entity = entity,
            .enabled_statuses = DDS_STATUS_MASK_ANY,
            .get_status_fn = get_status_fn,
            .wakeups = .{},
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.alloc.destroy(self);
    }

    /// Call after updating the entity's status_changes to wake any attached WaitSets.
    pub fn notifyWakeup(self: *Self) void {
        self.wakeups.notifyAll();
    }

    pub fn toDDSStatusCondition(self: *Self) DDS.StatusCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn toCondition(self: *Self) DDS.Condition {
        return .{ .ptr = self, .vtable = &cond_vtable };
    }

    const vtable = DDS.StatusCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_enabled_statuses = vtGetEnabled,
        .set_enabled_statuses = vtSetEnabled,
        .get_entity = vtGetEntity,
        .deinit = vtDeinit,
    };

    pub const cond_vtable = DDS.Condition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .deinit = vtDeinit,
    };

    fn vtGetTrigger(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return (self.get_status_fn(self.entity.ptr) & self.enabled_statuses) != 0;
    }

    fn vtGetEnabled(ctx: *anyopaque) DDS.StatusMask {
        return cast(ctx).enabled_statuses;
    }

    fn vtSetEnabled(ctx: *anyopaque, mask: DDS.StatusMask) DDS.ReturnCode_t {
        cast(ctx).enabled_statuses = mask;
        return DDS.RETCODE_OK;
    }

    fn vtGetEntity(ctx: *anyopaque) DDS.Entity {
        return cast(ctx).entity;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};

// All status bits defined by DDS v1.4 §2.2.4 — used as default enabled mask.
const DDS_STATUS_MASK_ANY: DDS.StatusMask = 0x7FFF;

// ── QueryConditionImpl ────────────────────────────────────────────────────────

/// A QueryCondition is a ReadCondition augmented with a SQL-subset query
/// expression and parameters.  The trigger semantics are identical to
/// ReadCondition (has pending data matching the state masks).  SQL evaluation
/// is applied at read/take time when a get_field function is available for
/// the reader's type (registered via TypeSupport).
///
/// WaitSet attachment: `toCondition()` returns the embedded ReadConditionImpl's
/// condition interface, so WaitSetImpl.vtAttach handles it like a ReadCondition.
pub const QueryConditionImpl = struct {
    alloc: std.mem.Allocator,
    rc: ReadConditionImpl,
    query_expression: [:0]u8, // null-terminated for C API
    query_parameters: std.ArrayListUnmanaged([]u8),
    /// Parsed AST of `query_expression`.  Null when the expression is empty
    /// or the content_subscription_profile is disabled.  A malformed expression
    /// returns error.ParseError from init, so the caller returns NIL.
    /// AST node slices borrow from `query_expression`; free before it.
    parsed_expr: ?*filter_mod.AstNode,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        reader: DDS.DataReader,
        sample_states: DDS.SampleStateMask,
        view_states: DDS.ViewStateMask,
        instance_states: DDS.InstanceStateMask,
        query_expression: []const u8,
        query_parameters: DDS.StringSeq,
        has_data_fn: *const fn (reader_ptr: *anyopaque) bool,
        reader_ctx: *anyopaque,
        add_notify_fn: *const fn (reader_ctx: *anyopaque, n: DataNotifyFn) void,
        remove_notify_fn: *const fn (reader_ctx: *anyopaque, waitset_ctx: *anyopaque) void,
    ) !*Self {
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);

        const expr_copy = try alloc.dupeZ(u8, query_expression);
        errdefer alloc.free(expr_copy);

        var params: std.ArrayListUnmanaged([]u8) = .empty;
        errdefer {
            for (params.items) |p| alloc.free(p);
            params.deinit(alloc);
        }
        if (query_parameters._buffer) |b| {
            for (b[0..query_parameters._length]) |p| {
                const copy = try alloc.dupe(u8, std.mem.span(p));
                errdefer alloc.free(copy);
                try params.append(alloc, copy);
            }
        }

        const parsed = try filter_mod.parse(alloc, expr_copy);

        self.* = .{
            .alloc = alloc,
            .rc = .{
                .alloc = alloc,
                .reader = reader,
                .sample_state_mask = sample_states,
                .view_state_mask = view_states,
                .instance_state_mask = instance_states,
                .has_data_fn = has_data_fn,
                .reader_ctx = reader_ctx,
                .add_notify_fn = add_notify_fn,
                .remove_notify_fn = remove_notify_fn,
            },
            .query_expression = expr_copy,
            .query_parameters = params,
            .parsed_expr = parsed,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.parsed_expr) |ast| filter_mod.freeAst(self.alloc, ast);
        for (self.query_parameters.items) |p| self.alloc.free(p);
        self.query_parameters.deinit(self.alloc);
        self.alloc.free(self.query_expression);
        self.alloc.destroy(self);
    }

    /// Returns true if `payload` passes the query expression, or if the
    /// expression cannot be evaluated (no field accessor or empty expression).
    pub fn matchSample(
        self: *const Self,
        payload: []const u8,
        get_field_fn: *const fn ([]const u8, []const u8) ?filter_mod.FilterValue,
    ) bool {
        var ctx = FieldCtx{ .payload = payload, .get_fn = get_field_fn };
        const accessor = filter_mod.FieldAccessor{ .ctx = &ctx, .get = FieldCtx.get };
        const params_slice: []const []const u8 = @ptrCast(self.query_parameters.items);
        return filter_mod.eval(self.parsed_expr, accessor, params_slice);
    }

    const FieldCtx = struct {
        payload: []const u8,
        get_fn: *const fn ([]const u8, []const u8) ?filter_mod.FilterValue,

        fn get(ctx: *anyopaque, field: []const u8) ?filter_mod.FilterValue {
            const self: *const FieldCtx = @ptrCast(@alignCast(ctx));
            return self.get_fn(self.payload, field);
        }
    };

    pub fn toDDSQueryCondition(self: *Self) DDS.QueryCondition {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Returns a Condition interface backed by the embedded ReadConditionImpl so
    /// that WaitSet attachment/notification works identically to ReadCondition.
    pub fn toCondition(self: *Self) DDS.Condition {
        return self.rc.toCondition();
    }

    const vtable = DDS.QueryCondition.Vtable{
        .get_trigger_value = vtGetTrigger,
        .get_sample_state_mask = vtGetSampleMask,
        .get_view_state_mask = vtGetViewMask,
        .get_instance_state_mask = vtGetInstMask,
        .get_datareader = vtGetReader,
        .get_query_expression = vtGetExpression,
        .get_query_parameters = vtGetParams,
        .set_query_parameters = vtSetParams,
        .deinit = vtDeinit,
    };

    fn vtGetTrigger(ctx: *anyopaque) bool {
        const self = cast(ctx);
        return self.rc.has_data_fn(self.rc.reader.ptr);
    }

    fn vtGetSampleMask(ctx: *anyopaque) DDS.SampleStateMask {
        return cast(ctx).rc.sample_state_mask;
    }
    fn vtGetViewMask(ctx: *anyopaque) DDS.ViewStateMask {
        return cast(ctx).rc.view_state_mask;
    }
    fn vtGetInstMask(ctx: *anyopaque) DDS.InstanceStateMask {
        return cast(ctx).rc.instance_state_mask;
    }
    fn vtGetReader(ctx: *anyopaque) DDS.DataReader {
        return cast(ctx).rc.reader;
    }
    fn vtGetExpression(ctx: *anyopaque) [*:0]const u8 {
        return cast(ctx).query_expression.ptr;
    }

    fn vtGetParams(ctx: *anyopaque, out: ?*DDS.StringSeq) DDS.ReturnCode_t {
        const seq = out orelse return DDS.RETCODE_BAD_PARAMETER;
        const self = cast(ctx);
        if (seq._release) {
            if (seq._buffer) |b| {
                for (b[0..seq._length]) |s| self.alloc.free(std.mem.span(s));
                self.alloc.free(b[0..seq._maximum]);
            }
        }
        seq.* = .{};
        const n = self.query_parameters.items.len;
        if (n == 0) return DDS.RETCODE_OK;
        const buf = self.alloc.alloc([*:0]const u8, n) catch return DDS.RETCODE_OUT_OF_RESOURCES;
        for (self.query_parameters.items, 0..) |p, i| {
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

    fn vtSetParams(ctx: *anyopaque, params: ?*const DDS.StringSeq) DDS.ReturnCode_t {
        const self = cast(ctx);
        for (self.query_parameters.items) |p| self.alloc.free(p);
        self.query_parameters.clearRetainingCapacity();
        const seq = params orelse return DDS.RETCODE_OK;
        if (seq._buffer) |b| {
            for (b[0..seq._length]) |p| {
                const copy = self.alloc.dupe(u8, std.mem.span(p)) catch return DDS.RETCODE_OUT_OF_RESOURCES;
                self.query_parameters.append(self.alloc, copy) catch {
                    self.alloc.free(copy);
                    return DDS.RETCODE_OUT_OF_RESOURCES;
                };
            }
        }
        return DDS.RETCODE_OK;
    }

    fn vtDeinit(ctx: *anyopaque) void {
        cast(ctx).deinit();
    }

    fn cast(ctx: *anyopaque) *Self {
        return @ptrCast(@alignCast(ctx));
    }
};
