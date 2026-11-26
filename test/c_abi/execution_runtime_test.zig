//! zzdds.idl's ExecutionRuntime and the factory's runtime selection
//! (docs/design/concurrency/extension-api.md#first-shipped-subset-versus-complete-design).
//!
//! Each runtime is created on the testing allocator, so a runtime that is not
//! finished and freed by the call that releases its last owner shows up as a
//! leak.

const std = @import("std");
const testing = std.testing;
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = zzdds.ZZDDS;
const zidl_bindings = @import("zidl_bindings");
const extensions = zzdds.c_abi.extensions;
const ExecutionRuntimeImpl = zzdds.dcps.execution_runtime.ExecutionRuntimeImpl;
const runtime = zzdds.runtime;

const supported = runtime.poll_backend.supported;
const monotonicNs = zzdds.util.time.monotonicNs;

fn config(mode: ZZDDS.RuntimeMode, workers: u32) ZZDDS.RuntimeConfig {
    var c = ZZDDS.RuntimeConfig.default();
    c.mode = mode;
    c.hosted_workers = workers;
    return c;
}

const infinite: DDS.Duration_t = .{ .sec = DDS.DURATION_INFINITE_SEC, .nanosec = DDS.DURATION_INFINITE_NSEC };
const no_wait: DDS.Duration_t = .{ .sec = 0, .nanosec = 0 };

/// Two participants on `factory` with a writer and a reader on one topic.
const Pair = struct {
    dds_factory: DDS.DomainParticipantFactory,
    dp_w: DDS.DomainParticipant,
    dp_r: DDS.DomainParticipant,
    dw: DDS.DataWriter,

    fn init(factory: ZZDDS.DomainParticipantFactory) !Pair {
        const dds_factory = factory.vtable.as_DomainParticipantFactory(factory.ptr);
        const domain: DDS.DomainId_t = @intCast(test_domain.get());
        const dp_w = dds_factory.create_participant(domain, .{}, null, 0);
        try testing.expect((dp_w).ptr != zzdds.dcps.NIL_PTR);
        const dp_r = dds_factory.create_participant(domain, .{}, null, 0);
        try testing.expect((dp_r).ptr != zzdds.dcps.NIL_PTR);
        const topic_w = dp_w.create_topic("ExecutionRuntimeT", "ExecutionRuntimeType", .{}, null, 0);
        const topic_r = dp_r.create_topic("ExecutionRuntimeT", "ExecutionRuntimeType", .{}, null, 0);
        const pub_ = dp_w.create_publisher(.{}, null, 0);
        const sub = dp_r.create_subscriber(.{}, null, 0);
        const dw = pub_.create_datawriter(topic_w, .{}, null, 0);
        try testing.expect((dw).ptr != zzdds.dcps.NIL_PTR);
        const td = @as(*zzdds.dcps.TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
        const dr = sub.create_datareader(td, .{}, null, 0);
        try testing.expect((dr).ptr != zzdds.dcps.NIL_PTR);
        return .{ .dds_factory = dds_factory, .dp_w = dp_w, .dp_r = dp_r, .dw = dw };
    }

    fn matched(self: *const Pair) bool {
        var status: DDS.PublicationMatchedStatus = .{};
        if (self.dw.get_publication_matched_status(&status) != DDS.RETCODE_OK) return false;
        return status.current_count == 1;
    }

    fn deinit(self: *Pair) void {
        _ = self.dp_w.delete_contained_entities();
        _ = self.dp_r.delete_contained_entities();
        _ = self.dds_factory.delete_participant(self.dp_w);
        _ = self.dds_factory.delete_participant(self.dp_r);
    }
};

test "a manual runtime selected by a factory runs its participants only in drive" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    try testing.expectEqual(ZZDDS.RuntimeMode.RUNTIME_MODE_MANUAL, rt.get_mode());
    try testing.expectEqual(ZZDDS.RuntimeState.RUNTIME_STATE_RUNNING, rt.get_state());

    const factory = try extensions.createFactory(null);
    defer factory.vtable.deinit(factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(rt));
    try testing.expectEqual(rt.ptr, factory.get_default_runtime().ptr);

    var pair = try Pair.init(factory);
    // Discovery runs only when driven.
    var result: ZZDDS.DriveResult = .{};
    const deadline = monotonicNs() + 20 * std.time.ns_per_s;
    while (!pair.matched()) {
        try testing.expectEqual(DDS.RETCODE_OK, rt.drive(64, .{ .sec = 0, .nanosec = 20_000_000 }, &result));
        if (monotonicNs() > deadline) return error.Timeout;
    }
    try testing.expectEqual(ZZDDS.RuntimeState.RUNTIME_STATE_RUNNING, result.state);
    try testing.expect(!result.retirement_pending);

    // Strict: participants and the factory still use it.
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, rt.destroy());
    pair.deinit();
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, rt.destroy());
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(zzdds.dcps.execution_runtime.nil_execution_runtime));
    try testing.expect((factory.get_default_runtime()).ptr == zzdds.dcps.NIL_PTR);
    try testing.expectEqual(DDS.RETCODE_OK, rt.destroy());
}

test "a hosted runtime runs its participants without drive, and goes with its last participant" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_HOSTED, 1));
    try testing.expectEqual(ZZDDS.RuntimeMode.RUNTIME_MODE_HOSTED, rt.get_mode());
    var result: ZZDDS.DriveResult = .{};
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, rt.drive(1, no_wait, &result));

    const factory = try extensions.createFactory(null);
    defer factory.vtable.deinit(factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(rt));
    // The factory holds it now; the handle's hold goes.
    rt.release();

    var pair = try Pair.init(factory);
    const deadline = monotonicNs() + 20 * std.time.ns_per_s;
    while (!pair.matched()) {
        std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake) catch {};
        if (monotonicNs() > deadline) return error.Timeout;
    }
    // Still selected, so still there to see.
    try testing.expectEqual(ZZDDS.RuntimeState.RUNTIME_STATE_RUNNING, factory.get_default_runtime().get_state());
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(zzdds.dcps.execution_runtime.nil_execution_runtime));
    // The last participant's deletion joins the workers and frees it.
    pair.deinit();
}

test "a manual runtime released while in use finishes when its last participant goes" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    const factory = try extensions.createFactory(null);
    defer factory.vtable.deinit(factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(rt));
    var pair = try Pair.init(factory);
    rt.release();
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(zzdds.dcps.execution_runtime.nil_execution_runtime));
    // No driver is left: the last release drains it.
    pair.deinit();
}

test "a factory's release lets go of its selected runtime" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    const factory = try extensions.createFactory(null);
    try testing.expectEqual(DDS.RETCODE_OK, factory.set_default_runtime(rt));
    try testing.expectEqual(DDS.RETCODE_PRECONDITION_NOT_MET, rt.destroy());
    factory.vtable.deinit(factory.ptr);
    try testing.expectEqual(DDS.RETCODE_OK, rt.destroy());
}

test "runtime config, drive and selection reject invalid arguments" {
    if (!supported) return error.SkipZigTest;
    try testing.expectError(error.BadParameter, ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_HOSTED, 0)));
    try testing.expectError(error.BadParameter, ZZDDS.ExecutionRuntime.create(testing.allocator, config(@fromBackingInt(@intCast(9)), 1)));
    // BUILD_DEFAULT is hosted here.
    const hosted = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_BUILD_DEFAULT, 1));
    try testing.expectEqual(ZZDDS.RuntimeMode.RUNTIME_MODE_HOSTED, hosted.get_mode());
    try testing.expectEqual(DDS.RETCODE_OK, hosted.destroy());

    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    defer testing.expectEqual(DDS.RETCODE_OK, rt.destroy()) catch {};
    var result: ZZDDS.DriveResult = .{};
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rt.drive(0, no_wait, &result));
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, rt.drive(1, .{ .sec = -1, .nanosec = 0 }, &result));
    try testing.expectEqual(DDS.RETCODE_OK, rt.drive(1, no_wait, &result));
    try testing.expectEqual(@as(u32, 0), result.turns);

    // The nil runtime.
    const none = zzdds.dcps.execution_runtime.nil_execution_runtime;
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, none.destroy());
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, none.drive(1, infinite, &result));
    try testing.expectEqual(ZZDDS.RuntimeState.RUNTIME_STATE_STOPPED, none.get_state());
    try testing.expectEqual(ZZDDS.RuntimeMode.RUNTIME_MODE_BUILD_DEFAULT, none.get_mode());
    none.release();

    // Only zzdds's own runtimes can be selected.
    const factory = try extensions.createFactory(null);
    defer factory.vtable.deinit(factory.ptr);
    const foreign = ZZDDS.ExecutionRuntime{ .ptr = rt.ptr, .vtable = &foreign_vtable };
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, factory.set_default_runtime(foreign));
    const nil_factory = ZZDDS.DomainParticipantFactory{ .ptr = zzdds.dcps.NIL_PTR, .vtable = factory.vtable };
    try testing.expectEqual(DDS.RETCODE_BAD_PARAMETER, nil_factory.set_default_runtime(rt));
    try testing.expect((nil_factory.get_default_runtime()).ptr == zzdds.dcps.NIL_PTR);
}

const foreign_vtable = blk: {
    var v = ExecutionRuntimeImpl.vtable;
    v.release = struct {
        fn f(_: *anyopaque) void {}
    }.f;
    break :blk v;
};

// The final release on one of the runtime's own turns cannot drain it
// there: the registry takes it and finishes it from a later call.
test "a runtime whose last owner goes on its own turn is finished by the registry" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    const impl: *ExecutionRuntimeImpl = @ptrCast(@alignCast(rt.ptr));
    const core_rt = impl.runtime();

    const Releaser = struct {
        var handle: ZZDDS.ExecutionRuntime = undefined;
        var adopted: bool = false;
        fn run(_: *runtime.Request, _: *runtime.Turn) runtime.Outcome {
            handle.release();
            return .done;
        }
    };
    Releaser.handle = rt;
    var ctx = runtime.Context.init(core_rt, 4);
    var req = runtime.Request.init(Releaser.run);
    try core_rt.submit(null, &ctx, &req);
    _ = try core_rt.drive(1, 0);
    ctx.deinit();
    runtime.default_registry.global.reap(false);
}

// Work still queued when the last owner goes: no driver is left, so the
// release runs it before freeing the runtime.
test "the last release of a manual runtime runs the work still queued on it" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    const impl: *ExecutionRuntimeImpl = @ptrCast(@alignCast(rt.ptr));
    const Queued = struct {
        var ran: bool = false;
        fn run(_: *runtime.Request, _: *runtime.Turn) runtime.Outcome {
            ran = true;
            return .done;
        }
    };
    var ctx = runtime.Context.init(impl.runtime(), 4);
    var req = runtime.Request.init(Queued.run);
    try impl.runtime().submit(null, &ctx, &req);
    try testing.expect(!Queued.ran);
    rt.release();
    try testing.expect(Queued.ran);
    ctx.deinit();
}

test "a runtime that cannot be created frees what it allocated" {
    if (!supported) return error.SkipZigTest;
    for ([_]ZZDDS.RuntimeMode{ .RUNTIME_MODE_MANUAL, .RUNTIME_MODE_HOSTED }) |mode| {
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
            const rt = ZZDDS.ExecutionRuntime.create(failing.allocator(), config(mode, 2)) catch |err| {
                try testing.expect(err == error.OutOfMemory or err == error.WorkersUnavailable or err == error.SystemResources);
                continue;
            };
            try testing.expectEqual(DDS.RETCODE_OK, rt.destroy());
            break;
        }
    }
}

test "a runtime's C handle is boxed once, on its own allocator" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    const h = rt.vtable.get_c_abi_handle(rt.ptr);
    try testing.expectEqual(h, rt.vtable.get_c_abi_handle(rt.ptr));
    try testing.expectEqual(testing.allocator.ptr, rt.vtable.get_allocator(rt.ptr).ptr);
    rt.vtable.deinit(rt.ptr);
}

// A turn's completion hook runs after the turn has released its context, but
// still on the thread serving the runtime: a final release there is on the
// runtime's own turn, so the registry finishes it after the drive returns.
test "a runtime whose last owner goes in a turn's completion hook is finished by the registry" {
    if (!supported) return error.SkipZigTest;
    const rt = try ZZDDS.ExecutionRuntime.create(testing.allocator, config(.RUNTIME_MODE_MANUAL, 0));
    const impl: *ExecutionRuntimeImpl = @ptrCast(@alignCast(rt.ptr));
    const core_rt = impl.runtime();
    const Hooked = struct {
        var handle: ZZDDS.ExecutionRuntime = undefined;
        fn run(_: *runtime.Request, _: *runtime.Turn) runtime.Outcome {
            return .done;
        }
        fn done(_: *runtime.Request) void {
            handle.release();
        }
    };
    Hooked.handle = rt;
    var ctx = runtime.Context.init(core_rt, 4);
    var req = runtime.Request.init(Hooked.run);
    req.on_done = Hooked.done;
    try core_rt.submit(null, &ctx, &req);
    _ = try core_rt.drive(1, 0);
    // The drive returned on storage the release did not free.
    try testing.expect(core_rt.getState() != .running);
    ctx.deinit();
    runtime.default_registry.global.reap(false);
}
