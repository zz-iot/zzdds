//! set_listener from application code returns only once no callback still
//! uses the listener it replaced; from a callback it does not wait
//! (docs/design/concurrency/listeners.md#replacement-completion). Threaded
//! runtime: an in-process write delivers on the writer's thread, so a
//! listener blocked there stays in flight until released.
//! test/runtime/shared_runtime_test.zig covers the shared runtime.

const std = @import("std");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const noop_security = zzdds.noop_security.noop_security_plugins;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;
const listener_box = zzdds.util.listener_box;

const testing = std.testing;

const NIL_KEY: [16]u8 = std.mem.zeroes([16]u8);
const NIL_IH: history_mod.InstanceHandle = history_mod.INSTANCE_HANDLE_NIL;
const PAYLOAD = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0x2a };

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return t.vtable.as_TopicDescription(t.ptr);
}

const Fixture = struct {
    delivery: IntraProcessDelivery,
    t_w: *zzdds.intraprocess.MemoryTransport,
    d_w: *zzdds.intraprocess.DirectDiscovery,
    factory_w: *DomainParticipantFactoryImpl,
    dp_w: DDS.DomainParticipant,
    pub_w: DDS.Publisher,
    topic_w: DDS.Topic,
    t_r: *zzdds.intraprocess.MemoryTransport,
    d_r: *zzdds.intraprocess.DirectDiscovery,
    factory_r: *DomainParticipantFactoryImpl,
    dp_r: DDS.DomainParticipant,
    sub_r: DDS.Subscriber,
    topic_r: DDS.Topic,

    fn init(self: *Fixture, alloc: std.mem.Allocator) !void {
        self.delivery = try IntraProcessDelivery.init(alloc);
        self.t_w = try self.delivery.newTransport();
        self.d_w = try self.delivery.newDiscovery();
        self.factory_w = try DomainParticipantFactoryImpl.init(alloc, self.t_w.transport(), self.d_w.toDiscovery(), noop_security, .spec_random, .{});
        self.dp_w = self.factory_w.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        self.pub_w = self.dp_w.create_publisher(.{}, null, 0);
        self.topic_w = self.dp_w.create_topic("ReplaceTopic", "ReplaceType", .{}, null, 0);
        self.t_r = try self.delivery.newTransport();
        self.d_r = try self.delivery.newDiscovery();
        self.factory_r = try DomainParticipantFactoryImpl.init(alloc, self.t_r.transport(), self.d_r.toDiscovery(), noop_security, .spec_random, .{});
        self.dp_r = self.factory_r.toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
        self.sub_r = self.dp_r.create_subscriber(.{}, null, 0);
        self.topic_r = self.dp_r.create_topic("ReplaceTopic", "ReplaceType", .{}, null, 0);
    }

    fn deinit(self: *Fixture) void {
        _ = self.factory_w.toDDSFactory().delete_participant(self.dp_w);
        _ = self.factory_r.toDDSFactory().delete_participant(self.dp_r);
        self.factory_w.deinit();
        self.factory_r.deinit();
        self.d_w.deinit();
        self.d_r.deinit();
        self.t_w.deinit();
        self.t_r.deinit();
        self.delivery.deinit();
    }

    fn writer(self: *Fixture) *DataWriterImpl {
        const dw = self.pub_w.create_datawriter(self.topic_w, .{}, null, 0);
        return @ptrCast(@alignCast(dw.ptr));
    }
};

/// Polls `done` for up to ten seconds; false if it never held.
fn awaitTrue(comptime done: anytype, args: anytype) bool {
    var i: usize = 0;
    while (i < 10_000) : (i += 1) {
        if (@call(.auto, done, args)) return true;
        zzdds.util.time.sleepNs(std.time.ns_per_ms);
    }
    return false;
}

fn isSet(flag: *const std.atomic.Value(bool)) bool {
    return flag.load(.seq_cst);
}

fn setterWaiting() bool {
    return listener_box.waitingSetters() > 0;
}

/// A listener whose first on_data_available for `reader` blocks until
/// released. A participant listener also hears the builtin readers, so
/// calls for any other reader are ignored.
const Gate = struct {
    reader: ?*anyopaque = null,
    calls: std.atomic.Value(u32) = .init(0),
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    release_timed_out: bool = false,
    /// Set once the setter under test has returned.
    set_returned: std.atomic.Value(bool) = .init(false),
    set_returned_before_callback: bool = false,
    set_rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,

    fn onData(handle: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        const self: *Gate = @ptrCast(@alignCast(ld.?));
        if (zzdds.zidl_rt.unboxAsView(DDS.DataReader, handle).ptr != self.reader.?) return;
        if (self.calls.fetchAdd(1, .seq_cst) > 0) return;
        self.entered.store(true, .seq_cst);
        self.release_timed_out = !awaitTrue(isSet, .{&self.release});
        self.set_returned_before_callback = self.set_returned.load(.seq_cst);
    }

    fn write(dw: *DataWriterImpl) void {
        _ = dw.writeRaw(.alive, RtpsTimestamp.now(), NIL_IH, NIL_KEY, &PAYLOAD) catch {};
    }

    fn clearReader(self: *Gate, dr: DDS.DataReader) void {
        self.set_rc = dr.set_listener(null, 0);
        self.set_returned.store(true, .seq_cst);
    }

    fn clearParticipant(self: *Gate, dp: DDS.DomainParticipant) void {
        self.set_rc = dp.vtable.set_listener(dp.ptr, null, 0);
        self.set_returned.store(true, .seq_cst);
    }

    /// With the first callback blocked on the writer's thread, runs
    /// `clear` on another thread and releases the callback only once
    /// `clear` waits for it.
    fn expectSetterWaits(self: *Gate, dw: *DataWriterImpl, comptime clear: anytype, target: anytype) !void {
        const writer_thread = try std.Thread.spawn(.{}, write, .{dw});
        try testing.expect(awaitTrue(isSet, .{&self.entered}));
        const setter = try std.Thread.spawn(.{}, clear, .{ self, target });
        try testing.expect(awaitTrue(setterWaiting, .{}));
        try testing.expect(!self.set_returned.load(.seq_cst));
        self.release.store(true, .seq_cst);
        setter.join();
        writer_thread.join();
        try testing.expectEqual(DDS.RETCODE_OK, self.set_rc);
        try testing.expect(!self.release_timed_out);
        try testing.expect(!self.set_returned_before_callback);
    }
};

test "clearing a reader's listener from outside a callback waits for its running callback" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator);
    defer fx.deinit();

    var gate: Gate = .{};
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, .{
        .listener_data = &gate,
        .on_data_available = Gate.onData,
    }, DDS.DATA_AVAILABLE_STATUS);
    defer _ = fx.sub_r.delete_datareader(dr);
    gate.reader = dr.ptr;
    const dw = fx.writer();
    try gate.expectSetterWaits(dw, Gate.clearReader, dr);
}

test "clearing a participant's listener waits for its callback dispatched for a reader" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator);
    defer fx.deinit();

    var gate: Gate = .{};
    // Only the participant has a listener: the reader's status falls back to it.
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, null, 0);
    defer _ = fx.sub_r.delete_datareader(dr);
    gate.reader = dr.ptr;
    var dp_listener = DDS.DomainParticipantListener{ .listener_data = &gate, .on_data_available = Gate.onData };
    try testing.expectEqual(DDS.RETCODE_OK, fx.dp_r.vtable.set_listener(fx.dp_r.ptr, &dp_listener, DDS.DATA_AVAILABLE_STATUS));
    const dw = fx.writer();
    try gate.expectSetterWaits(dw, Gate.clearParticipant, fx.dp_r);
}

/// A listener that clears itself from its own callback.
const SelfClear = struct {
    dr: DDS.DataReader = undefined,
    calls: u32 = 0,
    rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    done: std.atomic.Value(bool) = .init(false),

    fn onData(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        const self: *SelfClear = @ptrCast(@alignCast(ld.?));
        self.calls += 1;
        self.rc = self.dr.set_listener(null, 0);
    }

    fn write(self: *SelfClear, dw: *DataWriterImpl) void {
        Gate.write(dw);
        self.done.store(true, .seq_cst);
    }
};

test "a listener clearing itself from its own callback does not wait for itself" {
    var fx: Fixture = undefined;
    try fx.init(testing.allocator);
    defer fx.deinit();

    var state: SelfClear = .{};
    const dr = fx.sub_r.create_datareader(topicDesc(fx.topic_r), .{}, .{
        .listener_data = &state,
        .on_data_available = SelfClear.onData,
    }, DDS.DATA_AVAILABLE_STATUS);
    defer _ = fx.sub_r.delete_datareader(dr);
    state.dr = dr;
    const dw = fx.writer();
    const writer_thread = try std.Thread.spawn(.{}, SelfClear.write, .{ &state, dw });
    // Waiting for itself would never return.
    if (!awaitTrue(isSet, .{&state.done})) @panic("set_listener from its own callback waited for itself");
    writer_thread.join();
    try testing.expectEqual(@as(u32, 1), state.calls);
    try testing.expectEqual(DDS.RETCODE_OK, state.rc);
    // A second write finds no listener.
    Gate.write(dw);
    try testing.expectEqual(@as(u32, 1), state.calls);
}
