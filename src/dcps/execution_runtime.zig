//! zzdds.idl's ExecutionRuntime: a runtime of the application's own
//! (docs/design/concurrency/extension-api.md#first-shipped-subset-versus-complete-design).
//!
//! The handle holds one operational owner reference, as each participant on
//! the runtime and each factory selecting it does. Whoever releases the last
//! one finishes the runtime where it can: drains a manual one, joins a hosted
//! one's workers, then frees it. On one of the runtime's own turns it cannot,
//! so the default registry reclaims the runtime from a later call.

const std = @import("std");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const nil = @import("nil.zig");
const c_abi_handle = @import("../util/c_abi_handle.zig");
const core = @import("../runtime/core.zig");
const owned_mod = @import("../runtime/owned.zig");
const default_registry = @import("../runtime/default_registry.zig");
const writer_mod = @import("writer.zig");

pub const ExecutionRuntimeImpl = struct {
    alloc: std.mem.Allocator,
    owned: *owned_mod.OwnedRuntime,
    c_abi: c_abi_handle.CachedCAbiHandle = .{},

    const Self = @This();

    pub const CreateError = error{ BadParameter, OutOfMemory, WorkersUnavailable, SystemResources };

    pub fn create(alloc: std.mem.Allocator, config: *const ZZDDS.RuntimeConfig) CreateError!*Self {
        const mode: core.Mode = switch (config.mode) {
            .RUNTIME_MODE_BUILD_DEFAULT, .RUNTIME_MODE_HOSTED => .hosted,
            .RUNTIME_MODE_MANUAL => .manual,
            _ => return error.BadParameter,
        };
        if (mode == .hosted and config.hosted_workers == 0) return error.BadParameter;
        const self = try alloc.create(Self);
        errdefer alloc.destroy(self);
        const owned = try owned_mod.OwnedRuntime.create(alloc, .{
            .mode = mode,
            .workers = config.hosted_workers,
            .inline_turns = config.inline_turns,
        });
        self.* = .{ .alloc = alloc, .owned = owned };
        owned.runtime.on_final_release = .{ .ctx = self, .run = onFinalRelease };
        return self;
    }

    /// The runtime factories and participants select.
    pub fn runtime(self: *Self) *core.Runtime {
        return &self.owned.runtime;
    }

    pub fn toExecutionRuntime(self: *Self) ZZDDS.ExecutionRuntime {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The last owner is gone: no handle, factory or participant refers to
    /// this object any more, so it goes now; the runtime goes too unless
    /// this is one of its turns.
    fn onFinalRelease(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const owned = self.owned;
        self.c_abi.retire();
        self.c_abi.free(self.alloc);
        self.alloc.destroy(self);
        if (owned.canFinishHere()) owned.finish() else default_registry.global.adopt(owned);
    }

    pub const vtable = ZZDDS.ExecutionRuntime.Vtable{
        .destroy = vtDestroy,
        .release = vtRelease,
        .get_state = vtGetState,
        .get_mode = vtGetMode,
        .drive = vtDrive,
        .deinit = vtRelease,
        .get_c_abi_handle = vtGetCAbiHandle,
        .get_allocator = vtGetAllocator,
    };

    fn cast(ctx: *anyopaque) ?*Self {
        if (ctx == nil.NIL_PTR) return null;
        return @ptrCast(@alignCast(ctx));
    }

    /// Strict: refuses while anything else owns the runtime.
    fn vtDestroy(ctx: *anyopaque) DDS.ReturnCode_t {
        const self = cast(ctx) orelse return DDS.RETCODE_BAD_PARAMETER;
        if (!self.owned.runtime.releaseSoleOwner()) return DDS.RETCODE_PRECONDITION_NOT_MET;
        return DDS.RETCODE_OK;
    }

    fn vtRelease(ctx: *anyopaque) void {
        const self = cast(ctx) orelse return;
        self.owned.runtime.releaseOwner();
    }

    fn vtGetState(ctx: *anyopaque) ZZDDS.RuntimeState {
        const self = cast(ctx) orelse return .RUNTIME_STATE_STOPPED;
        return stateOf(self.owned.runtime.getState());
    }

    fn stateOf(s: core.State) ZZDDS.RuntimeState {
        return switch (s) {
            .running => .RUNTIME_STATE_RUNNING,
            .retiring => .RUNTIME_STATE_RETIRING,
            .backend_stopped => .RUNTIME_STATE_STOPPED,
        };
    }

    fn vtGetMode(ctx: *anyopaque) ZZDDS.RuntimeMode {
        const self = cast(ctx) orelse return .RUNTIME_MODE_BUILD_DEFAULT;
        return switch (self.owned.runtime.options.mode) {
            .hosted => .RUNTIME_MODE_HOSTED,
            .manual => .RUNTIME_MODE_MANUAL,
        };
    }

    fn vtDrive(ctx: *anyopaque, max_turns: u32, max_wait: *const DDS.Duration_t, result: *ZZDDS.DriveResult) DDS.ReturnCode_t {
        const self = cast(ctx) orelse return DDS.RETCODE_BAD_PARAMETER;
        const wait_ns = (writer_mod.waitTimeoutNs(max_wait.*) catch return DDS.RETCODE_BAD_PARAMETER) orelse std.math.maxInt(i64);
        const r = self.owned.runtime.drive(max_turns, wait_ns) catch |err| return switch (err) {
            error.InvalidBudget => DDS.RETCODE_BAD_PARAMETER,
            error.PreconditionNotMet => DDS.RETCODE_PRECONDITION_NOT_MET,
        };
        result.* = .{
            .turns = r.turns,
            .immediate_work = r.immediate_work,
            .state = stateOf(r.state),
            .retirement_pending = r.retirement_pending,
        };
        return DDS.RETCODE_OK;
    }

    fn vtGetCAbiHandle(ctx: *anyopaque) *anyopaque {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.c_abi.get(self.alloc, ctx, &vtable);
    }

    fn vtGetAllocator(ctx: *anyopaque) std.mem.Allocator {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.alloc;
    }
};

pub const nil_execution_runtime = ZZDDS.ExecutionRuntime{ .ptr = nil.NIL_PTR, .vtable = &ExecutionRuntimeImpl.vtable };
