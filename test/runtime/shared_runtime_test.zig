//! Participants on the shared runtime, in the `-Dshared-runtime` migration
//! build (docs/design/concurrency/runtime.md#coexistence-during-migration):
//! runtime selection, the default runtime, operational ownership and
//! automatic retirement (#selected-selection-hierarchy,
//! #default-registry-and-implicit-construction,
//! #operational-ownership-versus-storage-retention), and in-process delivery
//! through each receiving participant's ingress context (#ingress), timed
//! work on the runtime clock, and listeners run apart from the work that
//! changes their statuses
//! (docs/design/concurrency/listeners.md#inline-path-and-pending-work), and
//! blocking calls that help a manual runtime
//! (docs/design/concurrency/operations.md#stable-helping-policy), and deletion
//! that waits for a running listener. The last
//! section runs the whole slice, the same way, under each driver.
//!
//! Built against a second library graph with the switch on, so these run in
//! every `zig build test` while the switch exists.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const rt = zzdds.runtime;

const IntraProcessDelivery = zzdds.intraprocess.IntraProcessDelivery;
const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const DirectDiscovery = zzdds.intraprocess.DirectDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const WaitSetImpl = zzdds.dcps.WaitSetImpl;
const GuardConditionImpl = zzdds.dcps.GuardConditionImpl;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history = zzdds.rtps.history;
const StatefulWriter = zzdds.rtps.StatefulWriter;
const GuidPrefix = zzdds.rtps.GuidPrefix;
const Locator = zzdds.transport.Locator;
const noop_security = zzdds.noop_security.noop_security_plugins;
const nil_participant = zzdds.dcps.nil_participant;

const testing = std.testing;
const alloc = testing.allocator;

comptime {
    if (!rt.enabled) @compileError("built against the library with -Dshared-runtime off");
}

/// A manual runtime over the scripted backend. Must not move after `init`.
const Manual = struct {
    sb: rt.ScriptedBackend,
    runtime: rt.Runtime,

    fn init(self: *Manual) void {
        self.sb = rt.ScriptedBackend.init(1_000);
        self.runtime = rt.Runtime.init(self.sb.clock(), self.sb.backend(), .{ .mode = .manual });
    }

    fn now(self: *Manual) i64 {
        return self.runtime.clock.nowNs();
    }
};

/// One participant's in-process transport, discovery and factory.
const Node = struct {
    transport: *MemoryTransport,
    discovery: *DirectDiscovery,
    factory: *DomainParticipantFactoryImpl,

    fn init(delivery: *IntraProcessDelivery) !Node {
        return initWith(delivery, false, false);
    }

    /// `threaded_*` presents the plugin as one that runs its own threads.
    fn initWith(delivery: *IntraProcessDelivery, threaded_transport: bool, threaded_discovery: bool) !Node {
        const t = try delivery.newTransport();
        errdefer t.deinit();
        const d = try delivery.newDiscovery();
        errdefer d.deinit();
        var transport = t.transport();
        if (threaded_transport) transport.vtable = &threaded_transport_vtable;
        var discovery = d.toDiscovery();
        if (threaded_discovery) discovery.vtable = &threaded_discovery_vtable;
        const f = try DomainParticipantFactoryImpl.init(alloc, transport, discovery, noop_security, .spec_random, .{});
        return .{ .transport = t, .discovery = d, .factory = f };
    }

    fn deinit(self: *Node) void {
        self.factory.deinit();
        self.discovery.deinit();
        self.transport.deinit();
    }

    fn create(self: *Node) DDS.DomainParticipant {
        return self.factory.toDDSFactory().create_participant(0, .{}, null, 0);
    }

    fn delete(self: *Node, dp: DDS.DomainParticipant) !void {
        try testing.expectEqual(DDS.RETCODE_OK, self.factory.toDDSFactory().delete_participant(dp));
    }
};

var threaded_transport_vtable: zzdds.transport.Transport.Vtable = undefined;
var threaded_discovery_vtable: zzdds.discovery.Discovery.Vtable = undefined;

fn presentAsThreaded(delivery: *IntraProcessDelivery) !void {
    const t = try delivery.newTransport();
    defer t.deinit();
    const d = try delivery.newDiscovery();
    defer d.deinit();
    threaded_transport_vtable = t.transport().vtable.*;
    threaded_transport_vtable.shared_runtime_ready = false;
    threaded_discovery_vtable = d.toDiscovery().vtable.*;
    threaded_discovery_vtable.shared_runtime_ready = false;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

/// The refused creations below log why; that is expected here.
fn quietRefusals() std.log.Level {
    const prev = std.testing.log_level;
    std.testing.log_level = .err;
    return prev;
}

test "a factory's selected runtime overrides the default" {
    defer resetDefault();
    var set: Nodes(2) = undefined;
    try set.init();
    defer set.deinit();
    const selecting = &set.nodes[0];
    const following = &set.nodes[1];

    var m: Manual = undefined;
    m.init();
    defer m.runtime.deinit();
    try selecting.factory.selectRuntime(&m.runtime);
    m.runtime.releaseOwner();
    const before = registry.generations;
    const dp = selecting.create();
    try testing.expectEqual(&m.runtime, runtimeOf(dp) orelse return error.TestUnexpectedResult);
    try testing.expectEqual(before, registry.generations);

    // Without a selection, creation resolves the default.
    const implicit = following.create();
    const implicit_rt = runtimeOf(implicit) orelse return error.TestUnexpectedResult;
    try testing.expect(implicit_rt != &m.runtime);
    try testing.expectEqual(before + 1, registry.generations);

    try selecting.factory.selectRuntime(null);
    try selecting.delete(dp);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    try following.delete(implicit);
}

test "a transport or discovery plugin with threads of its own fails creation" {
    const prev_log_level = quietRefusals();
    defer std.testing.log_level = prev_log_level;
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    try presentAsThreaded(&delivery);
    var m: Manual = undefined;
    m.init();
    defer m.runtime.deinit();

    for ([_][2]bool{ .{ true, false }, .{ false, true } }) |threaded| {
        var node = try Node.initWith(&delivery, threaded[0], threaded[1]);
        defer node.deinit();
        try node.factory.selectRuntime(&m.runtime);
        try testing.expectEqual(nil_participant.ptr, node.create().ptr);
    }
    // The failed creations took no owner reference: the application's is the
    // last, and releasing it stops the runtime.
    m.runtime.releaseOwner();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
}

test "participants keep the runtime operating, and deleting the last retires it" {
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var a = try Node.init(&delivery);
    defer a.deinit();
    var b = try Node.init(&delivery);
    defer b.deinit();
    var m: Manual = undefined;
    m.init();
    defer m.runtime.deinit();

    try a.factory.selectRuntime(&m.runtime);
    try b.factory.selectRuntime(&m.runtime);
    const pa = a.create();
    const pb = b.create();
    try testing.expect(pa.ptr != nil_participant.ptr and pb.ptr != nil_participant.ptr);

    // Neither the application nor the factories keep it operating.
    m.runtime.releaseOwner();
    try a.factory.selectRuntime(null);
    try b.factory.selectRuntime(null);
    try testing.expectEqual(rt.State.running, m.runtime.getState());

    try a.delete(pa);
    try testing.expectEqual(rt.State.running, m.runtime.getState());
    try b.delete(pb);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
}

test "a retiring runtime cannot be selected, and a selected one keeps operating" {
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var node = try Node.init(&delivery);
    defer node.deinit();

    var kept: Manual = undefined;
    kept.init();
    defer kept.runtime.deinit();
    try node.factory.selectRuntime(&kept.runtime);
    kept.runtime.releaseOwner();
    try testing.expectEqual(rt.State.running, kept.runtime.getState());

    var retired: Manual = undefined;
    retired.init();
    defer retired.runtime.deinit();
    retired.runtime.releaseOwner();
    try testing.expectError(error.Retiring, node.factory.selectRuntime(&retired.runtime));

    // The failed selection left the earlier one in place.
    const dp = node.create();
    try testing.expect(dp.ptr != nil_participant.ptr);
    try node.delete(dp);
    try node.factory.selectRuntime(null);
    try testing.expectEqual(rt.State.backend_stopped, kept.runtime.getState());
}

// ── The default runtime ───────────────────────────────────────────────────────

const registry = &rt.default_registry.global;

/// Empties the default slot and reclaims every implicit runtime, for the next
/// test.
fn resetDefault() void {
    registry.clear();
    registry.reap(true);
}

fn runtimeOf(dp: DDS.DomainParticipant) ?*rt.Runtime {
    if (dp.ptr == nil_participant.ptr) return null;
    return @as(*DomainParticipantImpl, @ptrCast(@alignCast(dp.ptr))).runtime;
}

/// `n` nodes on one delivery, each with room for one participant at a time.
/// Must not move after `init`.
fn Nodes(comptime n: usize) type {
    return struct {
        delivery: IntraProcessDelivery,
        nodes: [n]Node,

        fn init(self: *@This()) !void {
            self.delivery = try IntraProcessDelivery.init(alloc);
            errdefer self.delivery.deinit();
            for (&self.nodes, 0..) |*node, i| {
                errdefer for (self.nodes[0..i]) |*done| done.deinit();
                node.* = try Node.init(&self.delivery);
            }
        }

        fn deinit(self: *@This()) void {
            for (&self.nodes) |*node| node.deinit();
            self.delivery.deinit();
        }
    };
}

test "creation without a selection starts a hosted default, and a fresh one after it retires" {
    defer resetDefault();
    var set: Nodes(2) = undefined;
    try set.init();
    defer set.deinit();

    const before = registry.generations;
    const a = set.nodes[0].create();
    const b = set.nodes[1].create();
    const first = runtimeOf(a) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(first, runtimeOf(b) orelse return error.TestUnexpectedResult);
    try testing.expectEqual(before + 1, registry.generations);
    // Hosted: its workers make progress, and waits only observe it.
    try testing.expect(!first.canHelp());

    try set.nodes[0].delete(a);
    try testing.expectEqual(rt.State.running, first.getState());
    try set.nodes[1].delete(b);
    // The registry kept no operational reference.
    try testing.expect(first.getState() != .running);

    const c = set.nodes[0].create();
    const second = runtimeOf(c) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(before + 2, registry.generations);
    try testing.expectEqual(rt.State.running, second.getState());
    try set.nodes[0].delete(c);

    resetDefault();
    try testing.expectEqual(registry.generations, registry.reclaimed);
}

test "concurrent first creations share one default runtime" {
    defer resetDefault();
    var set: Nodes(4) = undefined;
    try set.init();
    defer set.deinit();

    const Creator = struct {
        fn run(n: *Node, out: *DDS.DomainParticipant) void {
            out.* = n.create();
        }
    };
    const before = registry.generations;
    var dps: [4]DDS.DomainParticipant = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, &dps, &set.nodes) |*t, *dp, *node| t.* = try std.Thread.spawn(.{}, Creator.run, .{ node, dp });
    for (threads) |t| t.join();

    try testing.expectEqual(before + 1, registry.generations);
    const shared = runtimeOf(dps[0]) orelse return error.TestUnexpectedResult;
    for (dps) |dp| try testing.expectEqual(shared, runtimeOf(dp) orelse return error.TestUnexpectedResult);
    for (dps, &set.nodes) |dp, *node| try node.delete(dp);
}

test "an installed runtime is the default until it retires, and nothing replaces it" {
    const prev_log_level = quietRefusals();
    defer std.testing.log_level = prev_log_level;
    defer resetDefault();
    var set: Nodes(2) = undefined;
    try set.init();
    defer set.deinit();
    const node = &set.nodes[0];

    var retired: Manual = undefined;
    retired.init();
    defer retired.runtime.deinit();
    retired.runtime.releaseOwner();
    try testing.expectError(error.Retiring, registry.install(&retired.runtime));

    // Installing does not move a participant already on an implicit runtime.
    const implicit = set.nodes[1].create();
    const implicit_rt = runtimeOf(implicit) orelse return error.TestUnexpectedResult;
    var m: Manual = undefined;
    m.init();
    defer m.runtime.deinit();
    try registry.install(&m.runtime);
    const before = registry.generations;
    const dp = node.create();
    try testing.expectEqual(&m.runtime, runtimeOf(dp) orelse return error.TestUnexpectedResult);
    try testing.expectEqual(implicit_rt, runtimeOf(implicit) orelse return error.TestUnexpectedResult);
    try testing.expectEqual(rt.State.running, implicit_rt.getState());
    try set.nodes[1].delete(implicit);

    m.runtime.releaseOwner();
    try node.delete(dp);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    // Creation fails rather than falling back to an implicit runtime...
    try testing.expectEqual(nil_participant.ptr, node.create().ptr);
    try testing.expectEqual(before, registry.generations);
    // ...until the slot is cleared.
    registry.clear();
    const fresh = node.create();
    try testing.expect(fresh.ptr != nil_participant.ptr);
    try testing.expectEqual(before + 1, registry.generations);
    try node.delete(fresh);

    resetDefault();
    try testing.expectEqual(registry.generations, registry.reclaimed);
}

test "a disabled default fails creation until the slot is cleared" {
    const prev_log_level = quietRefusals();
    defer std.testing.log_level = prev_log_level;
    defer resetDefault();
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var node = try Node.init(&delivery);
    defer node.deinit();

    registry.disable();
    const before = registry.generations;
    try testing.expectEqual(nil_participant.ptr, node.create().ptr);
    try testing.expectEqual(before, registry.generations);
    registry.clear();
    const dp = node.create();
    try testing.expect(dp.ptr != nil_participant.ptr);
    try node.delete(dp);
}

test "a WaitSet's wait never starts a default runtime" {
    defer resetDefault();
    const gc = try GuardConditionImpl.init(alloc);
    const ws = try WaitSetImpl.init(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));
    const before = registry.generations;
    var active: DDS.ConditionSeq = .{};
    defer freeActive(&active);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, ws.toDDSWaitSet().wait(&active, .{ .sec = 0, .nanosec = 0 }));
    try testing.expectEqual(before, registry.generations);
    try testing.expectEqual(.unconfigured, std.meta.activeTag(registry.slot));

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(gc.toCondition()));
    ws.deinit();
    gc.deinit();
}

test "a WaitSet made without a runtime helps an installed manual default, on its clock" {
    defer resetDefault();
    var m: Manual = undefined;
    m.init();
    try registry.install(&m.runtime);
    var pair: Pair = undefined;
    try pair.init(null, .RELIABLE_RELIABILITY_QOS, null);
    try testing.expectEqual(&m.runtime, runtimeOf(pair.dp_w) orelse return error.TestUnexpectedResult);
    m.runtime.releaseOwner();
    try settle(&m);

    const gc = try GuardConditionImpl.init(alloc);
    const ws = try WaitSetImpl.init(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));
    const start = m.now();
    const first_hb = m.runtime.nextDeadline() orelse return error.TestUnexpectedResult;

    var active: DDS.ConditionSeq = .{};
    defer freeActive(&active);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, ws.toDDSWaitSet().wait(&active, seconds(1)));
    try testing.expectEqual(start + SEC, m.now());
    const next_hb = m.runtime.nextDeadline() orelse return error.TestUnexpectedResult;
    try testing.expect(next_hb > first_hb + StatefulWriter.HB_INTERVAL_NS);
    try testing.expectEqual(@as(u32, 0), m.sb.unbounded_waits);

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(gc.toCondition()));
    ws.deinit();
    gc.deinit();
    registry.clear();
    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a GuardCondition set on another thread ends a wait helping the default" {
    defer resetDefault();
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .manual });
    try registry.install(&runtime);
    const gc = try GuardConditionImpl.init(alloc);
    const ws = try WaitSetImpl.init(alloc);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));

    const Waiter = struct {
        fn run(w: DDS.WaitSet, rc: *DDS.ReturnCode_t) void {
            var active: DDS.ConditionSeq = .{};
            defer freeActive(&active);
            // Gives up after 10 s rather than hanging.
            rc.* = w.wait(&active, seconds(10));
        }
    };
    var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
    const start = runtime.clock.nowNs();
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ ws.toDDSWaitSet(), &rc });
    // Waiting in the runtime's backend: it is helping.
    while (backend.waiters.load(.seq_cst) == 0) std.Thread.yield() catch {};
    try testing.expectEqual(DDS.RETCODE_OK, gc.toDDSGuardCondition().set_trigger_value(true));
    waiter.join();
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expect(runtime.clock.nowNs() - start < 10 * SEC);

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(gc.toCondition()));
    ws.deinit();
    gc.deinit();
    registry.clear();
    runtime.releaseOwner();
    try testing.expectEqual(rt.State.backend_stopped, (try runtime.drive(1, 0)).state);
    runtime.deinit();
}

// ── In-process delivery ───────────────────────────────────────────────────────

const samples_n = 20;

/// How a `Pair`'s endpoints are made.
const PairOptions = struct {
    dw_qos: DDS.DataWriterQos = .{},
    dr_qos: DDS.DataReaderQos = .{},
    dw_listener: ?DDS.DataWriterListener = null,
    dw_mask: DDS.StatusMask = 0,
    dr_listener: ?DDS.DataReaderListener = null,
    dr_mask: DDS.StatusMask = 0,

    /// Both endpoints BEST_EFFORT, so no heartbeat is armed.
    fn bestEffort() PairOptions {
        var o: PairOptions = .{};
        o.dw_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
        o.dr_qos.reliability.kind = .BEST_EFFORT_RELIABILITY_QOS;
        return o;
    }
};

/// A writer on one participant matched with a reader on another, both on
/// one runtime. Must not move after `init`.
const Pair = struct {
    delivery: IntraProcessDelivery,
    w: Node,
    r: Node,
    dp_w: DDS.DomainParticipant,
    dp_r: DDS.DomainParticipant,
    dw_h: DDS.DataWriter,
    dw: *DataWriterImpl,
    dr: *DataReaderImpl,

    /// KEEP_ALL endpoints of `reliability`.
    /// A null `runtime`: the participants resolve the default.
    fn init(self: *Pair, runtime: ?*rt.Runtime, reliability: DDS.ReliabilityQosPolicyKind, listener: ?*const DDS.DataReaderListener) !void {
        var o: PairOptions = .{};
        o.dw_qos.reliability.kind = reliability;
        o.dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        o.dr_qos.reliability.kind = reliability;
        o.dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        if (listener) |l| {
            o.dr_listener = l.*;
            o.dr_mask = DDS.DATA_AVAILABLE_STATUS;
        }
        return self.initWith(runtime, o);
    }

    fn initWith(self: *Pair, runtime: ?*rt.Runtime, o: PairOptions) !void {
        self.delivery = try IntraProcessDelivery.init(alloc);
        self.w = try Node.init(&self.delivery);
        self.r = try Node.init(&self.delivery);
        // Only the participants keep the runtime operating.
        if (runtime) |r| try self.w.factory.selectRuntime(r);
        if (runtime) |r| try self.r.factory.selectRuntime(r);
        self.dp_w = self.w.create();
        self.dp_r = self.r.create();
        try self.w.factory.selectRuntime(null);
        try self.r.factory.selectRuntime(null);
        try testing.expect(self.dp_w.ptr != nil_participant.ptr and self.dp_r.ptr != nil_participant.ptr);

        const topic_w = self.dp_w.create_topic("SliceTopic", "SliceType", .{}, null, 0);
        const topic_r = self.dp_r.create_topic("SliceTopic", "SliceType", .{}, null, 0);
        const sub = self.dp_r.create_subscriber(.{}, null, 0);
        const desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
        const dr = sub.create_datareader(desc_r, o.dr_qos, o.dr_listener, o.dr_mask);
        self.dr = @ptrCast(@alignCast(dr.ptr));
        const publisher = self.dp_w.create_publisher(.{}, null, 0);
        self.dw_h = publisher.create_datawriter(topic_w, o.dw_qos, o.dw_listener, o.dw_mask);
        self.dw = @ptrCast(@alignCast(self.dw_h.ptr));
    }

    fn write(self: *Pair, i: usize) !void {
        const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, @truncate(i) };
        _ = try self.dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &payload);
    }

    /// Deletes both participants: the runtime's last owners.
    fn deinit(self: *Pair) !void {
        try testing.expectEqual(DDS.RETCODE_OK, self.dp_w.delete_contained_entities());
        try testing.expectEqual(DDS.RETCODE_OK, self.dp_r.delete_contained_entities());
        try self.w.delete(self.dp_w);
        try self.r.delete(self.dp_r);
        self.freeNodes();
    }

    /// Once both participants are deleted.
    fn freeNodes(self: *Pair) void {
        self.w.deinit();
        self.r.deinit();
        self.delivery.deinit();
    }
};

/// Takes every available sample into `got`, by its payload index. Skips
/// state-only samples, such as the one when the writer is deleted.
fn takeInto(dr: *DataReaderImpl, got: *std.ArrayListUnmanaged(u8)) !void {
    while (dr.takeRaw()) |sample| {
        defer alloc.free(sample.data);
        if (sample.info.valid_data) try got.append(alloc, sample.data[4]);
    }
}

fn expectInOrder(got: []const u8, n: usize) !void {
    try testing.expectEqual(n, got.len);
    for (got, 0..) |v, i| try testing.expectEqual(@as(u8, @truncate(i)), v);
}

test "a reliable pair delivers every sample, in order, through a manual runtime" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();

    for (0..samples_n) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    // Delivery is queued for the reader's participant: nothing arrives
    // until the runtime is driven.
    try takeInto(pair.dr, &got);
    try testing.expectEqual(@as(usize, 0), got.items.len);

    var drives: usize = 0;
    while (got.items.len < samples_n and drives < 100) : (drives += 1) {
        _ = try m.runtime.drive(64, 0);
        try takeInto(pair.dr, &got);
    }
    try expectInOrder(got.items, samples_n);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

/// Takes samples from its listener, which runs in the reader participant's
/// listener turns, and sets `done` once all have arrived.
const Collector = struct {
    io: std.Io,
    dr: *DataReaderImpl = undefined,
    got: std.ArrayListUnmanaged(u8) = .empty,
    failed: bool = false,
    done: std.Io.Event = .unset,

    fn listener(self: *Collector) DDS.DataReaderListener {
        return .{ .listener_data = self, .on_data_available = onDataAvailable };
    }

    fn onDataAvailable(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        const self: *Collector = @ptrCast(@alignCast(ld.?));
        takeInto(self.dr, &self.got) catch {
            self.failed = true;
        };
        if (self.got.items.len >= samples_n or self.failed) self.done.set(self.io);
    }
};

test "a reliable pair delivers every sample, in order, to a listener on hosted workers" {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var backend = rt.IoBackend.init(io);
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted });
    var hosted = try rt.Hosted.init(alloc, io, &runtime, 2);
    hosted.start() catch |err| {
        runtime.releaseOwner();
        hosted.join();
        return err;
    };

    var c = Collector{ .io = io };
    defer c.got.deinit(alloc);
    const listener = c.listener();
    var pair: Pair = undefined;
    pair.init(&runtime, .RELIABLE_RELIABILITY_QOS, &listener) catch |err| {
        runtime.releaseOwner();
        hosted.join();
        return err;
    };
    c.dr = pair.dr;
    runtime.releaseOwner();

    for (0..samples_n) |i| try pair.write(i);
    try c.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    try testing.expect(!c.failed);
    try expectInOrder(c.got.items, samples_n);

    // Deleting the last participant retires the runtime; its workers exit.
    try pair.deinit();
    hosted.join();
    try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
    runtime.deinit();
}

test "deleting a participant drops the deliveries queued for it" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();

    for (0..samples_n) |i| try pair.write(i);
    // The testing allocator reports any queued datagram not freed.
    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "datagrams past the ingress bound are dropped, as a full receive buffer drops them" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .BEST_EFFORT_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();

    const limit = DomainParticipantImpl.ingress_pending_limit;
    const written = limit + 10;
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    for (0..written) |i| {
        const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, @truncate(i) };
        _ = try pair.dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &payload);
    }
    var drives: usize = 0;
    while (drives < 20) : (drives += 1) {
        _ = try m.runtime.drive(64, 0);
        try takeInto(pair.dr, &got);
    }
    try testing.expectEqual(@as(usize, limit), got.items.len);
    const reader_participant: *DomainParticipantImpl = @ptrCast(@alignCast(pair.dp_r.ptr));
    try testing.expectEqual(@as(u64, written - limit), reader_participant.ingress_drops.load(.monotonic));
    try testing.expectEqual(@as(usize, 0), reader_participant.ingress_bytes.load(.monotonic));

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

/// Deletes its participant from inside a listener: the final deletion runs
/// in one of the participant's own listener turns.
const SelfDelete = struct {
    node: *Node,
    dp: DDS.DomainParticipant = undefined,
    deleted: bool = false,
    rc: DDS.ReturnCode_t = DDS.RETCODE_OK,

    fn listener(self: *SelfDelete) DDS.DataReaderListener {
        return .{ .listener_data = self, .on_data_available = onDataAvailable };
    }

    fn writerListener(self: *SelfDelete) DDS.DataWriterListener {
        return .{ .listener_data = self, .on_offered_deadline_missed = onDeadlineMissed };
    }

    fn onDataAvailable(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        deleteOnce(@ptrCast(@alignCast(ld.?)));
    }

    fn onDeadlineMissed(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
        deleteOnce(@ptrCast(@alignCast(ld.?)));
    }

    fn deleteOnce(self: *SelfDelete) void {
        if (self.deleted) return;
        self.deleted = true;
        self.rc = self.dp.delete_contained_entities();
        if (self.rc == DDS.RETCODE_OK) self.rc = self.node.factory.toDDSFactory().delete_participant(self.dp);
    }
};

test "a participant deleted from its own listener is freed after that turn" {
    var m: Manual = undefined;
    m.init();
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var w = try Node.init(&delivery);
    defer w.deinit();
    var r = try Node.init(&delivery);
    defer r.deinit();
    try w.factory.selectRuntime(&m.runtime);
    try r.factory.selectRuntime(&m.runtime);
    const dp_w = w.create();
    const dp_r = r.create();
    try w.factory.selectRuntime(null);
    try r.factory.selectRuntime(null);
    m.runtime.releaseOwner();

    var sd = SelfDelete{ .node = &r, .dp = dp_r };
    const topic_w = dp_w.create_topic("SliceTopic", "SliceType", .{}, null, 0);
    const topic_r = dp_r.create_topic("SliceTopic", "SliceType", .{}, null, 0);
    const sub = dp_r.create_subscriber(.{}, null, 0);
    const desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
    _ = sub.create_datareader(desc_r, .{}, sd.listener(), DDS.DATA_AVAILABLE_STATUS);
    const publisher = dp_w.create_publisher(.{}, null, 0);
    const dw: *DataWriterImpl = @ptrCast(@alignCast(publisher.create_datawriter(topic_w, .{}, null, 0).ptr));

    // Two samples: the second is queued behind the turn that deletes.
    for (0..2) |i| {
        const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, @intCast(i) };
        _ = try dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &payload);
    }
    var drives: usize = 0;
    while (!sd.deleted and drives < 100) : (drives += 1) _ = try m.runtime.drive(64, 0);
    try testing.expect(sd.deleted);
    try testing.expectEqual(DDS.RETCODE_OK, sd.rc);
    try testing.expectEqual(rt.State.running, m.runtime.getState());

    try testing.expectEqual(DDS.RETCODE_OK, dp_w.delete_contained_entities());
    try w.delete(dp_w);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "heartbeats on the runtime clock repair datagrams dropped at the reader's ingress" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();
    // Settle the match first: the reader's opening ACKNACK draws a HEARTBEAT
    // that would otherwise announce the whole burst below.
    while ((try m.runtime.drive(64, 0)).immediate_work) {}

    // More datagrams than the reader's participant can queue: the tail is
    // dropped, the reader's ACKNACKs for the rest are final, and only the
    // writer's periodic HEARTBEAT can reveal the gap.
    const written = DomainParticipantImpl.ingress_pending_limit + 40;
    for (0..written) |i| try pair.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const reader_participant: *DomainParticipantImpl = @ptrCast(@alignCast(pair.dp_r.ptr));

    // Each drive that finds nothing to run waits on the scripted clock until
    // the next timer: no wall-clock time passes.
    const start = m.now();
    var drives: usize = 0;
    while (got.items.len < written and drives < 1000) : (drives += 1) {
        _ = try m.runtime.drive(64, std.time.ns_per_s);
        try takeInto(pair.dr, &got);
    }
    try testing.expect(reader_participant.ingress_drops.load(.monotonic) > 0);
    try expectInOrder(got.items, written);
    try testing.expect(m.now() > start);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "the writer heartbeat recurs on the runtime clock until no reliable reader is matched" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();
    while ((try m.runtime.drive(64, 0)).immediate_work) {}

    // Only the heartbeat is armed: each wait ends at its next fire, and each
    // fire arms the next one interval on.
    for (0..3) |_| {
        const due = m.runtime.nextDeadline() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(m.now() + StatefulWriter.HB_INTERVAL_NS, due);
        _ = try m.runtime.drive(64, std.time.ns_per_s);
        try testing.expectEqual(due, m.now());
        while ((try m.runtime.drive(64, 0)).immediate_work) {}
    }

    // With the reader gone, the fire already armed is the last. The
    // unmatch queues the writer's listener first.
    try testing.expectEqual(DDS.RETCODE_OK, pair.dp_r.delete_contained_entities());
    while ((try m.runtime.drive(64, 0)).immediate_work) {}
    _ = try m.runtime.drive(64, std.time.ns_per_s);
    while ((try m.runtime.drive(64, 0)).immediate_work) {}
    try testing.expectEqual(@as(?i64, null), m.runtime.nextDeadline());

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a best-effort match arms no writer heartbeat" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .BEST_EFFORT_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();
    while ((try m.runtime.drive(64, 0)).immediate_work) {}
    try testing.expectEqual(@as(?i64, null), m.runtime.nextDeadline());

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

// ── Timed QoS ─────────────────────────────────────────────────────────────────

fn onOfferedDeadlineMissed(_: *anyopaque, st: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*i32, @ptrCast(@alignCast(ld.?))).* = st.total_count;
}

fn onLivelinessChanged(_: *anyopaque, st: *const DDS.LivelinessChangedStatus, ld: ?*anyopaque) callconv(.c) void {
    @as(*DDS.LivelinessChangedStatus, @ptrCast(@alignCast(ld.?))).* = st.*;
}

/// Drives until nothing is runnable now, without waiting.
fn settle(m: *Manual) !void {
    while ((try m.runtime.drive(64, 0)).immediate_work) {}
}

const SEC: i64 = std.time.ns_per_s;

test "a missed offered deadline is reported on the runtime clock, at the deadline" {
    var m: Manual = undefined;
    m.init();
    var missed: i32 = 0;
    var o = PairOptions.bestEffort();
    o.dw_qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    o.dw_listener = .{ .listener_data = &missed, .on_offered_deadline_missed = onOfferedDeadlineMissed };
    o.dw_mask = DDS.OFFERED_DEADLINE_MISSED_STATUS;
    const t0 = m.now();
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    try settle(&m);

    // Nothing written: each period from creation is a miss, checked when due
    // rather than polled.
    for (1..3) |n| {
        try testing.expectEqual(@as(?i64, t0 + @as(i64, @intCast(n)) * SEC), m.runtime.nextDeadline());
        _ = try m.runtime.drive(64, 10 * SEC);
        try settle(&m);
        try testing.expectEqual(t0 + @as(i64, @intCast(n)) * SEC, m.now());
        try testing.expectEqual(@as(i32, @intCast(n)), missed);
    }

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "shortening a deadline with set_qos brings its check forward" {
    var m: Manual = undefined;
    m.init();
    var o = PairOptions.bestEffort();
    o.dw_qos.deadline.period = .{ .sec = 10, .nanosec = 0 };
    const t0 = m.now();
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    try settle(&m);
    try testing.expectEqual(@as(?i64, t0 + 10 * SEC), m.runtime.nextDeadline());

    var qos = o.dw_qos;
    qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.set_qos(qos));
    try settle(&m);
    try testing.expectEqual(@as(?i64, t0 + SEC), m.runtime.nextDeadline());

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a reader sees a matched writer's lease run out on the runtime clock" {
    var m: Manual = undefined;
    m.init();
    var status = DDS.LivelinessChangedStatus{};
    var o = PairOptions.bestEffort();
    o.dr_listener = .{ .listener_data = &status, .on_liveliness_changed = onLivelinessChanged };
    o.dr_mask = DDS.LIVELINESS_CHANGED_STATUS;
    const t0 = m.now();
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    try settle(&m);
    try testing.expectEqual(@as(?i64, null), m.runtime.nextDeadline());

    // A writer with a lease, matched once the reader's checks have nothing
    // to do: the match itself has to arm them.
    var qos = o.dw_qos;
    qos.liveliness.kind = .AUTOMATIC_LIVELINESS_QOS;
    qos.liveliness.lease_duration = .{ .sec = 1, .nanosec = 0 };
    _ = pair.dw_h.get_publisher().create_datawriter(pair.dw_h.get_topic(), qos, null, 0);
    try settle(&m);
    try testing.expectEqual(@as(i32, 1), status.alive_count);

    _ = try m.runtime.drive(64, 10 * SEC);
    try settle(&m);
    try testing.expectEqual(t0 + SEC, m.now());
    try testing.expectEqual(@as(i32, 0), status.alive_count);
    try testing.expectEqual(@as(i32, 1), status.not_alive_count);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

/// One RTPS message: DATA for `sn` from `writer`, to every reader.
fn rtpsData(buf: *std.ArrayListUnmanaged(u8), writer: GuidPrefix, writer_eid: [4]u8, sn: u32) !void {
    const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, 0xAB };
    try buf.appendSlice(alloc, "RTPS");
    try buf.appendSlice(alloc, &[_]u8{ 2, 3, 0x01, 0x10 });
    try buf.appendSlice(alloc, &writer.bytes);
    // Little-endian, data present.
    var smh = [_]u8{ 0x15, 0x05, 0, 0 };
    std.mem.writeInt(u16, smh[2..4], 20 + payload.len, .little);
    try buf.appendSlice(alloc, &smh);
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0x10, 0 });
    try buf.appendSlice(alloc, &[_]u8{ 0, 0, 0, 0 });
    try buf.appendSlice(alloc, &writer_eid);
    var sn_bytes: [8]u8 = undefined;
    std.mem.writeInt(i32, sn_bytes[0..4], 0, .little);
    std.mem.writeInt(u32, sn_bytes[4..8], sn, .little);
    try buf.appendSlice(alloc, &sn_bytes);
    try buf.appendSlice(alloc, &payload);
}

test "data held for an unannounced writer is dropped on the runtime clock when it expires" {
    var m: Manual = undefined;
    m.init();
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var node = try Node.init(&delivery);
    defer node.deinit();
    try node.factory.selectRuntime(&m.runtime);
    const dp = node.create();
    try node.factory.selectRuntime(null);
    m.runtime.releaseOwner();
    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    const topic = dp.create_topic("Held", "T", .{}, null, 0);
    const desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
    _ = dp.create_subscriber(.{}, null, 0).create_datareader(desc, .{}, null, 0);
    try settle(&m);
    try testing.expectEqual(@as(?i64, null), m.runtime.nextDeadline());

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try rtpsData(&buf, .{ .bytes = @splat(0x57) }, .{ 0, 0, 1, 0x02 }, 1);
    try node.transport.transport().send(&Locator.udp4(.{ 127, 0, 0, 1 }, dp_impl.data_listen_port), buf.items);
    try settle(&m);
    try testing.expect(dp_impl.unmatched.byteCount() > 0);

    // The check is armed for when the hold runs out, and drops it then.
    const due = m.runtime.nextDeadline() orelse return error.TestUnexpectedResult;
    _ = try m.runtime.drive(64, 3600 * SEC);
    try settle(&m);
    try testing.expectEqual(due, m.now());
    try testing.expectEqual(@as(usize, 0), dp_impl.unmatched.byteCount());
    try testing.expectEqual(@as(?i64, null), m.runtime.nextDeadline());

    try testing.expectEqual(DDS.RETCODE_OK, dp.delete_contained_entities());
    try node.delete(dp);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "checks armed for something else still drop held data when it expires" {
    var m: Manual = undefined;
    m.init();
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var node = try Node.init(&delivery);
    defer node.deinit();
    try node.factory.selectRuntime(&m.runtime);
    const dp = node.create();
    try node.factory.selectRuntime(null);
    m.runtime.releaseOwner();
    const dp_impl: *DomainParticipantImpl = @ptrCast(@alignCast(dp.ptr));
    const topic = dp.create_topic("Held", "T", .{}, null, 0);
    const desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();
    _ = dp.create_subscriber(.{}, null, 0).create_datareader(desc, .{}, null, 0);
    // A deadline checked every 3 s, which the hold's expiry falls between.
    var qos = DDS.DataWriterQos{};
    qos.deadline.period = .{ .sec = 3, .nanosec = 0 };
    _ = dp.create_publisher(.{}, null, 0).create_datawriter(topic, qos, null, 0);
    try settle(&m);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);
    try rtpsData(&buf, .{ .bytes = @splat(0x57) }, .{ 0, 0, 1, 0x02 }, 1);
    const held_at = m.now();
    try node.transport.transport().send(&Locator.udp4(.{ 127, 0, 0, 1 }, dp_impl.data_listen_port), buf.items);
    try settle(&m);
    try testing.expect(dp_impl.unmatched.byteCount() > 0);
    const lease_ns = @as(i64, dp_impl.config.participant.lease_duration_ms) * std.time.ns_per_ms;
    try testing.expect(@mod(lease_ns, 3 * SEC) != 0);

    var drives: usize = 0;
    while (dp_impl.unmatched.byteCount() > 0 and drives < 1000) : (drives += 1) {
        _ = try m.runtime.drive(64, 3600 * SEC);
        try settle(&m);
    }
    try testing.expectEqual(held_at + lease_ns, m.now());

    try testing.expectEqual(DDS.RETCODE_OK, dp.delete_contained_entities());
    try node.delete(dp);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a participant deleted from its own deadline listener is freed after that turn" {
    var m: Manual = undefined;
    m.init();
    var delivery = try IntraProcessDelivery.init(alloc);
    defer delivery.deinit();
    var node = try Node.init(&delivery);
    defer node.deinit();
    try node.factory.selectRuntime(&m.runtime);
    const dp = node.create();
    try node.factory.selectRuntime(null);
    m.runtime.releaseOwner();

    var sd = SelfDelete{ .node = &node, .dp = dp };
    var qos = DDS.DataWriterQos{};
    qos.deadline.period = .{ .sec = 1, .nanosec = 0 };
    const topic = dp.create_topic("SliceTopic", "SliceType", .{}, null, 0);
    const publisher = dp.create_publisher(.{}, null, 0);
    _ = publisher.create_datawriter(topic, qos, sd.writerListener(), DDS.OFFERED_DEADLINE_MISSED_STATUS);
    try settle(&m);
    try testing.expect(!sd.deleted);

    _ = try m.runtime.drive(64, 10 * SEC);
    try testing.expect(sd.deleted);
    try testing.expectEqual(DDS.RETCODE_OK, sd.rc);
    // The participant was the runtime's last owner.
    try settle(&m);
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

// ── Listener separation ───────────────────────────────────────────────────────

/// Records the listener calls it receives, in order, and whether each ran as
/// a turn of `lane`: its entity's participant's listener context.
const Recorder = struct {
    lane: ?*rt.Context = null,
    calls: [16]Call = undefined,
    n: usize = 0,
    all_in_lane: bool = true,
    /// Set while no call may arrive.
    quiet: bool = false,
    called_while_quiet: bool = false,
    matched_current: i32 = 0,
    writer_ready: bool = false,
    /// Deletes `dr` from the call it names.
    delete_on: ?Call = null,
    dr: DDS.DataReader = undefined,
    delete_rc: DDS.ReturnCode_t = DDS.RETCODE_OK,
    /// Creates a writer like `dw` from its first match call.
    match_another: bool = false,
    dw: DDS.DataWriter = undefined,

    const Call = enum { matched, liveliness, data, pub_matched, writer_ready };

    const reader_statuses = DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.LIVELINESS_CHANGED_STATUS | DDS.DATA_AVAILABLE_STATUS;

    fn readerListener(self: *Recorder) DDS.DataReaderListener {
        return .{
            .listener_data = self,
            .on_subscription_matched = onSubscriptionMatched,
            .on_liveliness_changed = onLiveliness,
            .on_data_available = onData,
        };
    }

    fn writerListener(self: *Recorder) DDS.DataWriterListener {
        return .{ .listener_data = self, .on_publication_matched = onPublicationMatched };
    }

    fn of(ld: ?*anyopaque) *Recorder {
        return @ptrCast(@alignCast(ld.?));
    }

    fn onSubscriptionMatched(_: *anyopaque, st: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
        of(ld).matched_current = st.current_count;
        of(ld).record(.matched);
    }

    fn onLiveliness(_: *anyopaque, _: *const DDS.LivelinessChangedStatus, ld: ?*anyopaque) callconv(.c) void {
        of(ld).record(.liveliness);
    }

    fn onData(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        of(ld).record(.data);
    }

    fn onPublicationMatched(_: *anyopaque, _: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
        of(ld).record(.pub_matched);
    }

    fn onWriterReady(_: DDS.InstanceHandle_t, ready: bool, ld: ?*anyopaque) callconv(.c) void {
        if (ready) of(ld).writer_ready = true;
        of(ld).record(.writer_ready);
    }

    fn record(self: *Recorder, call: Call) void {
        const in_lane = if (self.lane) |l| l.isRunningHere() else false;
        if (!in_lane) self.all_in_lane = false;
        if (self.quiet) self.called_while_quiet = true;
        if (self.n < self.calls.len) {
            self.calls[self.n] = call;
            self.n += 1;
        }
        if (self.delete_on == call) self.delete_rc = self.dr.get_subscriber().delete_datareader(self.dr);
        if (call == .matched and self.match_another) {
            self.match_another = false;
            var qos: DDS.DataWriterQos = .{};
            _ = self.dw.get_qos(&qos);
            _ = self.dw.get_publisher().create_datawriter(self.dw.get_topic(), qos, null, 0);
        }
    }

    fn slice(self: *const Recorder) []const Call {
        return self.calls[0..self.n];
    }
};

fn listenersOf(dp: DDS.DomainParticipant) *rt.Context {
    return &@as(*DomainParticipantImpl, @ptrCast(@alignCast(dp.ptr))).listeners;
}

test "listeners run as listener turns, oldest change first, and internal work runs none" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{};
    var wr: Recorder = .{};
    var o = PairOptions.bestEffort();
    o.dr_listener = rr.readerListener();
    o.dr_mask = Recorder.reader_statuses;
    o.dw_listener = wr.writerListener();
    o.dw_mask = DDS.PUBLICATION_MATCHED_STATUS;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    rr.lane = listenersOf(pair.dp_r);
    wr.lane = listenersOf(pair.dp_w);
    // Matching ran on this thread and only queued its listeners.
    try testing.expectEqual(@as(usize, 0), rr.n + wr.n);

    // Internal work alone delivers the sample but runs no listener.
    try pair.write(0);
    while (m.runtime.runNextInternal()) {}
    try testing.expectEqual(@as(usize, 0), rr.n + wr.n);
    try testing.expect(pair.dr.toDDSDataReader().get_status_changes() & DDS.DATA_AVAILABLE_STATUS != 0);

    // The match became pending first, though its status bit is the higher.
    try settle(&m);
    try testing.expectEqualSlices(Recorder.Call, &.{ .matched, .data }, rr.slice());
    try testing.expectEqualSlices(Recorder.Call, &.{.pub_matched}, wr.slice());
    try testing.expect(rr.all_in_lane and wr.all_in_lane);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a status getter called before the listener's turn takes the change" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{};
    var o = PairOptions.bestEffort();
    o.dr_listener = rr.readerListener();
    o.dr_mask = DDS.SUBSCRIPTION_MATCHED_STATUS;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();

    var st: DDS.SubscriptionMatchedStatus = .{};
    try testing.expectEqual(DDS.RETCODE_OK, pair.dr.toDDSDataReader().get_subscription_matched_status(&st));
    try testing.expectEqual(@as(i32, 1), st.current_count_change);
    try settle(&m);
    try testing.expectEqual(@as(usize, 0), rr.n);

    // A later change is a fresh opportunity.
    _ = pair.dw_h.get_publisher().create_datawriter(pair.dw_h.get_topic(), o.dw_qos, null, 0);
    try settle(&m);
    try testing.expectEqualSlices(Recorder.Call, &.{.matched}, rr.slice());
    try testing.expectEqual(@as(i32, 2), rr.matched_current);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a change made during an entity's listener turn gets a turn of its own" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{ .match_another = true };
    var o = PairOptions.bestEffort();
    o.dr_listener = rr.readerListener();
    o.dr_mask = DDS.SUBSCRIPTION_MATCHED_STATUS;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    rr.dw = pair.dw_h;

    // The first call matches a second writer before it returns.
    try settle(&m);
    try testing.expectEqualSlices(Recorder.Call, &.{ .matched, .matched }, rr.slice());
    try testing.expectEqual(@as(i32, 2), rr.matched_current);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "deleting a writer raises the reader's listeners on the runtime, not on the deleting thread" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{};
    var o = PairOptions.bestEffort();
    o.dr_listener = rr.readerListener();
    o.dr_mask = DDS.SUBSCRIPTION_MATCHED_STATUS | DDS.DATA_AVAILABLE_STATUS;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    rr.lane = listenersOf(pair.dp_r);
    try pair.write(0);
    try settle(&m);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    try takeInto(pair.dr, &got);
    const before = rr.n;

    // In-process discovery unmatches on this thread.
    rr.quiet = true;
    try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.get_publisher().delete_datawriter(pair.dw_h));
    rr.quiet = false;
    try settle(&m);
    try testing.expect(!rr.called_while_quiet);
    try testing.expectEqualSlices(Recorder.Call, &.{ .matched, .data }, rr.slice()[before..]);
    try testing.expectEqual(@as(i32, 0), rr.matched_current);
    try testing.expect(rr.all_in_lane);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a builtin reader's listener runs on the runtime, not on the thread that deleted the endpoint" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, PairOptions.bestEffort());
    m.runtime.releaseOwner();
    try settle(&m);

    const publications = @as(*DomainParticipantImpl, @ptrCast(@alignCast(pair.dp_r.ptr))).builtin_sub.?.pub_dr;
    var rr: Recorder = .{ .lane = listenersOf(pair.dp_r) };
    try testing.expectEqual(DDS.RETCODE_OK, publications.toDDSDataReader().set_listener(rr.readerListener(), DDS.DATA_AVAILABLE_STATUS));
    try settle(&m);
    while (publications.takeRaw()) |sample| alloc.free(sample.data);
    const before = rr.n;

    // In-process discovery reports the writer's disposal on this thread.
    rr.quiet = true;
    try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.get_publisher().delete_datawriter(pair.dw_h));
    rr.quiet = false;
    try settle(&m);
    try testing.expect(!rr.called_while_quiet);
    try testing.expectEqualSlices(Recorder.Call, &.{.data}, rr.slice()[before..]);
    try testing.expect(rr.all_in_lane);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a reader deleted while its listeners are queued never hears them, and is freed" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{};
    var o = PairOptions.bestEffort();
    o.dr_listener = rr.readerListener();
    o.dr_mask = Recorder.reader_statuses;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    try pair.write(0);
    while (m.runtime.runNextInternal()) {}

    rr.quiet = true;
    const dr = pair.dr.toDDSDataReader();
    try testing.expectEqual(DDS.RETCODE_OK, dr.get_subscriber().delete_datareader(dr));
    try settle(&m);
    try testing.expectEqual(@as(usize, 0), rr.n);

    // The testing allocator reports the reader if its queued turn kept it.
    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a reader deleted from its own listener hears nothing after that call" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{ .delete_on = .matched };
    var o = PairOptions.bestEffort();
    o.dr_listener = rr.readerListener();
    o.dr_mask = Recorder.reader_statuses;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    rr.dr = pair.dr.toDDSDataReader();
    rr.lane = listenersOf(pair.dp_r);
    try pair.write(0);
    while (m.runtime.runNextInternal()) {}
    try settle(&m);

    // The data was pending in the same turn, behind the match.
    try testing.expectEqualSlices(Recorder.Call, &.{.matched}, rr.slice());
    try testing.expectEqual(DDS.RETCODE_OK, rr.delete_rc);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a reliable-ready event reaches the reader's extension listener as a listener turn" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();
    var rr: Recorder = .{ .lane = listenersOf(pair.dp_r) };
    pair.dr.setListenerEx(.{ .listener_data = &rr, .on_reliable_writer_ready = Recorder.onWriterReady }, 0);

    var drives: usize = 0;
    while (!rr.writer_ready and drives < 20) : (drives += 1) {
        _ = try m.runtime.drive(64, std.time.ns_per_s);
    }
    try testing.expect(rr.writer_ready);
    try testing.expect(rr.all_in_lane);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

// ── Helping waits ─────────────────────────────────────────────────────────────

fn seconds(n: i32) DDS.Duration_t {
    return .{ .sec = n, .nanosec = 0 };
}

fn freeActive(active: *DDS.ConditionSeq) void {
    if (active._release) if (active._buffer) |b| alloc.free(b[0..active._maximum]);
}

test "a helping WaitSet wakes when data is committed, before the reader's listener runs" {
    var m: Manual = undefined;
    m.init();
    var rr: Recorder = .{};
    const l = rr.readerListener();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, &l);
    m.runtime.releaseOwner();
    try settle(&m);

    const ws = try WaitSetImpl.initHelping(alloc, &m.runtime);
    const sc = pair.dr.toDDSDataReader().get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, sc.set_enabled_statuses(DDS.DATA_AVAILABLE_STATUS));
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(sc.as_Condition()));

    // Nothing drives the runtime but the wait, and the delivery needs no
    // time to pass.
    try pair.write(0);
    const start = m.now();
    rr.quiet = true;
    var active: DDS.ConditionSeq = .{};
    defer freeActive(&active);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().wait(&active, seconds(1)));
    try testing.expectEqual(@as(u32, 1), active._length);
    try testing.expectEqual(start, m.now());
    try testing.expect(!rr.called_while_quiet);

    rr.quiet = false;
    try settle(&m);
    try testing.expectEqualSlices(Recorder.Call, &.{.data}, rr.slice());

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(sc.as_Condition()));
    ws.deinit();
    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a helping WaitSet times out on the runtime clock, firing the timers due meanwhile" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();
    try settle(&m);

    const gc = try GuardConditionImpl.init(alloc);
    const ws = try WaitSetImpl.initHelping(alloc, &m.runtime);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));
    const start = m.now();
    const first_hb = m.runtime.nextDeadline() orelse return error.TestUnexpectedResult;

    var active: DDS.ConditionSeq = .{};
    defer freeActive(&active);
    try testing.expectEqual(DDS.RETCODE_TIMEOUT, ws.toDDSWaitSet().wait(&active, seconds(1)));
    try testing.expectEqual(@as(u32, 0), active._length);
    try testing.expectEqual(start + SEC, m.now());
    // The heartbeat kept recurring through the wait.
    const next_hb = m.runtime.nextDeadline() orelse return error.TestUnexpectedResult;
    try testing.expect(next_hb > first_hb + StatefulWriter.HB_INTERVAL_NS);
    try testing.expectEqual(@as(u32, 0), m.sb.unbounded_waits);

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(gc.toCondition()));
    ws.deinit();
    gc.deinit();
    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a GuardCondition set on another thread ends a helping WaitSet's wait" {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .manual });
    const gc = try GuardConditionImpl.init(alloc);
    const ws = try WaitSetImpl.initHelping(alloc, &runtime);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(gc.toCondition()));

    const Waiter = struct {
        fn run(w: DDS.WaitSet, rc: *DDS.ReturnCode_t) void {
            var active: DDS.ConditionSeq = .{};
            defer freeActive(&active);
            // Gives up after 10 s rather than hanging.
            rc.* = w.wait(&active, seconds(10));
        }
    };
    var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
    const start = runtime.clock.nowNs();
    const waiter = try std.Thread.spawn(.{}, Waiter.run, .{ ws.toDDSWaitSet(), &rc });
    while (backend.waiters.load(.seq_cst) == 0) std.Thread.yield() catch {};
    try testing.expectEqual(DDS.RETCODE_OK, gc.toDDSGuardCondition().set_trigger_value(true));
    waiter.join();
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    // Woken by the trigger, not ended by the deadline.
    try testing.expect(runtime.clock.nowNs() - start < 10 * SEC);

    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(gc.toCondition()));
    ws.deinit();
    gc.deinit();
    runtime.releaseOwner();
    try testing.expectEqual(rt.State.backend_stopped, (try runtime.drive(1, 0)).state);
    runtime.deinit();
}

test "a WaitSet cannot help a hosted runtime" {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted });
    try testing.expectError(error.HostedRuntime, WaitSetImpl.initHelping(alloc, &runtime));
    runtime.releaseOwner();
    var hosted = try rt.Hosted.init(alloc, threaded.io(), &runtime, 1);
    try hosted.start();
    hosted.join();
    runtime.deinit();
}

test "waiting for acknowledgments helps the runtime until the reader has acknowledged" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    try pair.init(&m.runtime, .RELIABLE_RELIABILITY_QOS, null);
    m.runtime.releaseOwner();
    try settle(&m);

    for (0..samples_n) |i| try pair.write(i);
    try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.wait_for_acknowledgments(seconds(1)));
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    try takeInto(pair.dr, &got);
    try expectInOrder(got.items, samples_n);

    // The publisher's wait helps the same way.
    for (samples_n..2 * samples_n) |i| try pair.write(i);
    try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.get_publisher().wait_for_acknowledgments(seconds(1)));
    try takeInto(pair.dr, &got);
    try expectInOrder(got.items, 2 * samples_n);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

test "a late reader's wait for historical data helps the runtime until the history arrives" {
    var m: Manual = undefined;
    m.init();
    var o: PairOptions = .{};
    o.dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    o.dw_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    o.dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    o.dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    o.dr_qos.durability.kind = .TRANSIENT_LOCAL_DURABILITY_QOS;
    o.dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    var pair: Pair = undefined;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();
    for (0..samples_n) |i| try pair.write(i);
    try settle(&m);

    // The writer replays its history to a reader created now.
    const first = pair.dr.toDDSDataReader();
    const late_h = first.get_subscriber().create_datareader(first.get_topicdescription(), o.dr_qos, null, 0);
    const late: *DataReaderImpl = @ptrCast(@alignCast(late_h.ptr));
    try testing.expectEqual(DDS.RETCODE_OK, late_h.wait_for_historical_data(seconds(1)));
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    try takeInto(late, &got);
    try expectInOrder(got.items, samples_n);

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

/// From the writer's match listener, writes and waits for the reader to
/// acknowledge.
const AckFromListener = struct {
    pair: *Pair,
    rr: *Recorder,
    rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    reader_heard: bool = false,

    fn listener(self: *AckFromListener) DDS.DataWriterListener {
        return .{ .listener_data = self, .on_publication_matched = onMatched };
    }

    fn onMatched(_: *anyopaque, st: *const DDS.PublicationMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
        const self: *AckFromListener = @ptrCast(@alignCast(ld.?));
        if (st.current_count_change <= 0) return;
        self.pair.write(0) catch return;
        self.rc = self.pair.dw_h.wait_for_acknowledgments(seconds(1));
        self.reader_heard = self.rr.n > 0;
    }
};

test "a wait from a listener helps internal work and runs no other listener" {
    var m: Manual = undefined;
    m.init();
    var pair: Pair = undefined;
    var rr: Recorder = .{};
    var ack: AckFromListener = .{ .pair = &pair, .rr = &rr };
    var o: PairOptions = .{};
    o.dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    o.dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    o.dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    o.dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
    o.dw_listener = ack.listener();
    o.dw_mask = DDS.PUBLICATION_MATCHED_STATUS;
    o.dr_listener = rr.readerListener();
    o.dr_mask = DDS.DATA_AVAILABLE_STATUS;
    try pair.initWith(&m.runtime, o);
    m.runtime.releaseOwner();

    try settle(&m);
    try testing.expectEqual(DDS.RETCODE_OK, ack.rc);
    try testing.expect(!ack.reader_heard);
    try testing.expectEqualSlices(Recorder.Call, &.{.data}, rr.slice());

    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, m.runtime.getState());
    m.runtime.deinit();
}

// ── Deletion and running listeners ────────────────────────────────────────────

/// A hosted runtime and its workers. Must not move after `init`.
const HostedRuntime = struct {
    threaded: std.Io.Threaded,
    backend: rt.IoBackend,
    runtime: rt.Runtime,
    hosted: rt.Hosted,

    fn init(self: *HostedRuntime, workers: u32) !void {
        self.threaded = .init(alloc, .{});
        self.backend = rt.IoBackend.init(self.threaded.io());
        self.runtime = rt.Runtime.init(self.backend.clock(), self.backend.backend(), .{ .mode = .hosted });
        self.hosted = try rt.Hosted.init(alloc, self.threaded.io(), &self.runtime, workers);
        self.hosted.start() catch |err| {
            self.runtime.releaseOwner();
            self.hosted.join();
            return err;
        };
    }

    fn io(self: *HostedRuntime) std.Io {
        return self.threaded.io();
    }

    /// Once the runtime's owners are released: waits for its workers to exit.
    fn deinit(self: *HostedRuntime) !void {
        self.hosted.join();
        try testing.expectEqual(rt.State.backend_stopped, self.runtime.getState());
        self.runtime.deinit();
        self.threaded.deinit();
    }
};

const ten_seconds: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } };

/// A listener whose first call holds until released, then calls back into
/// its entity's parent, as application code may.
const Held = struct {
    io: std.Io,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    returned: std.Io.Event = .unset,
    calls: u32 = 0,
    release_timed_out: bool = false,
    /// Set once the deletion of the listener's entity has returned.
    deleted: std.atomic.Value(bool) = .init(false),
    /// The deletion deletes the parent's contents rather than the entity.
    contained: bool = false,
    deleted_before_return: bool = false,
    dr: DDS.DataReader = undefined,
    dw: DDS.DataWriter = undefined,

    fn readerListener(self: *Held) DDS.DataReaderListener {
        return .{ .listener_data = self, .on_data_available = onData };
    }

    fn writerListener(self: *Held) DDS.DataWriterListener {
        return .{ .listener_data = self, .on_offered_deadline_missed = onDeadlineMissed };
    }

    fn onData(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        const self: *Held = @ptrCast(@alignCast(ld.?));
        if (!self.hold()) return;
        _ = self.dr.get_subscriber().lookup_datareader("SliceTopic");
        self.returned.set(self.io);
    }

    fn onDeadlineMissed(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
        const self: *Held = @ptrCast(@alignCast(ld.?));
        if (!self.hold()) return;
        _ = self.dw.get_publisher().lookup_datawriter("SliceTopic");
        self.returned.set(self.io);
    }

    /// False for calls after the first.
    fn hold(self: *Held) bool {
        self.calls += 1;
        if (self.calls > 1) return false;
        self.entered.set(self.io);
        self.release.waitTimeout(self.io, ten_seconds) catch {
            self.release_timed_out = true;
        };
        self.deleted_before_return = self.deleted.load(.acquire);
        return true;
    }

    fn deleteReader(self: *Held, rc: *DDS.ReturnCode_t) void {
        const sub = self.dr.get_subscriber();
        rc.* = if (self.contained) sub.delete_contained_entities() else sub.delete_datareader(self.dr);
        self.deleted.store(true, .release);
    }

    fn deleteWriter(self: *Held, rc: *DDS.ReturnCode_t) void {
        const publisher = self.dw.get_publisher();
        rc.* = if (self.contained) publisher.delete_contained_entities() else publisher.delete_datawriter(self.dw);
        self.deleted.store(true, .release);
    }

    /// Releases the listener once `pending`'s deletion is waiting for it, or
    /// has returned without waiting.
    fn releaseOnceWaitedFor(self: *Held, pending: anytype) void {
        while (pending.waiting.load(.seq_cst) == 0 and !self.deleted.load(.acquire)) std.Thread.yield() catch {};
        self.release.set(self.io);
    }
};

const Endpoint = enum { reader, writer };

/// Deletes an endpoint from another application thread while its listener
/// runs on a hosted worker, by deleting it or its parent's contents.
fn expectDeletionWaitsForListener(endpoint: Endpoint, contained: bool) !void {
    var h: HostedRuntime = undefined;
    try h.init(2);
    var held: Held = .{ .io = h.io(), .contained = contained };
    var o = PairOptions.bestEffort();
    switch (endpoint) {
        .reader => {
            o.dr_listener = held.readerListener();
            o.dr_mask = DDS.DATA_AVAILABLE_STATUS;
        },
        .writer => {
            o.dw_listener = held.writerListener();
            o.dw_mask = DDS.OFFERED_DEADLINE_MISSED_STATUS;
        },
    }
    var pair: Pair = undefined;
    try pair.initWith(&h.runtime, o);
    h.runtime.releaseOwner();
    held.dr = pair.dr.toDDSDataReader();
    held.dw = pair.dw_h;

    switch (endpoint) {
        .reader => try pair.write(0),
        .writer => {
            var qos: DDS.DataWriterQos = undefined;
            try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.get_qos(&qos));
            qos.deadline.period = Slice.deadline;
            try testing.expectEqual(DDS.RETCODE_OK, pair.dw_h.set_qos(qos));
        },
    }
    try held.entered.waitTimeout(h.io(), ten_seconds);
    var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
    const deleter = switch (endpoint) {
        .reader => try std.Thread.spawn(.{}, Held.deleteReader, .{ &held, &rc }),
        .writer => try std.Thread.spawn(.{}, Held.deleteWriter, .{ &held, &rc }),
    };
    // The listener holds the endpoint's storage until it returns.
    switch (endpoint) {
        .reader => held.releaseOnceWaitedFor(&pair.dr.listeners),
        .writer => held.releaseOnceWaitedFor(&pair.dw.listeners),
    }
    deleter.join();
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expect(!held.release_timed_out);
    try testing.expect(!held.deleted_before_return);
    // It called back into the parent while the deletion waited.
    try testing.expect(held.returned.isSet());

    try pair.deinit();
    try h.deinit();
}

test "deleting a reader from outside a callback waits for its running listener to return" {
    try expectDeletionWaitsForListener(.reader, false);
}

test "deleting a writer from outside a callback waits for its running listener to return" {
    try expectDeletionWaitsForListener(.writer, false);
}

test "deleting a subscriber's contents from outside a callback waits for a reader's running listener" {
    try expectDeletionWaitsForListener(.reader, true);
}

test "deleting a publisher's contents from outside a callback waits for a writer's running listener" {
    try expectDeletionWaitsForListener(.writer, true);
}

test "deleting a reader from outside a callback waits for its listener called by notify_datareaders" {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    var backend = rt.IoBackend.init(threaded.io());
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .manual });
    var held: Held = .{ .io = threaded.io() };
    var o: PairOptions = .{};
    o.dr_listener = held.readerListener();
    o.dr_mask = DDS.DATA_AVAILABLE_STATUS;
    var pair: Pair = undefined;
    try pair.initWith(&runtime, o);
    runtime.releaseOwner();
    held.dr = pair.dr.toDDSDataReader();

    // The helping wait commits the sample and leaves its listener queued.
    const ws = try WaitSetImpl.initHelping(alloc, &runtime);
    const sc = held.dr.get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, sc.set_enabled_statuses(DDS.DATA_AVAILABLE_STATUS));
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().attach_condition(sc.as_Condition()));
    try pair.write(0);
    var active: DDS.ConditionSeq = .{};
    defer freeActive(&active);
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().wait(&active, seconds(10)));
    try testing.expectEqual(DDS.RETCODE_OK, ws.toDDSWaitSet().detach_condition(sc.as_Condition()));
    ws.deinit();

    // Another application thread delivers it inline instead.
    const Notifier = struct {
        fn run(sub: DDS.Subscriber) void {
            _ = sub.notify_datareaders();
        }
    };
    const notifier = try std.Thread.spawn(.{}, Notifier.run, .{held.dr.get_subscriber()});
    try held.entered.waitTimeout(held.io, ten_seconds);
    var rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR;
    const deleter = try std.Thread.spawn(.{}, Held.deleteReader, .{ &held, &rc });
    held.releaseOnceWaitedFor(&pair.dr.listeners);
    deleter.join();
    notifier.join();
    try testing.expectEqual(DDS.RETCODE_OK, rc);
    try testing.expect(!held.release_timed_out);
    try testing.expect(!held.deleted_before_return);

    // The queued listener turn finds its reader deleted.
    while ((try runtime.drive(64, 0)).immediate_work) {}
    try testing.expectEqual(@as(u32, 1), held.calls);
    try pair.deinit();
    try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
    runtime.deinit();
}

/// Deletes `held`'s reader from its own reader's listener, then releases
/// `held`.
const DeleteFromListener = struct {
    held: *Held,
    rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    done: std.Io.Event = .unset,

    fn listener(self: *DeleteFromListener) DDS.DataReaderListener {
        return .{ .listener_data = self, .on_data_available = onData };
    }

    fn onData(_: *anyopaque, ld: ?*anyopaque) callconv(.c) void {
        const self: *DeleteFromListener = @ptrCast(@alignCast(ld.?));
        if (self.done.isSet()) return;
        self.held.deleteReader(&self.rc);
        self.held.release.set(self.held.io);
        self.done.set(self.held.io);
    }
};

test "deleting a reader from another participant's listener does not wait for the reader's listener" {
    var h: HostedRuntime = undefined;
    try h.init(2);
    var held: Held = .{ .io = h.io() };
    var deleting: DeleteFromListener = .{ .held = &held };

    var o: PairOptions = .{};
    o.dr_listener = held.readerListener();
    o.dr_mask = DDS.DATA_AVAILABLE_STATUS;
    var target: Pair = undefined;
    try target.initWith(&h.runtime, o);
    held.dr = target.dr.toDDSDataReader();
    o.dr_listener = deleting.listener();
    var other: Pair = undefined;
    try other.initWith(&h.runtime, o);
    h.runtime.releaseOwner();

    try target.write(0);
    try held.entered.waitTimeout(h.io(), ten_seconds);
    // If the deletion waited, the held listener would wait for it in turn
    // until its release timed out.
    try other.write(0);
    try deleting.done.waitTimeout(h.io(), ten_seconds);
    try held.returned.waitTimeout(h.io(), ten_seconds);
    try testing.expectEqual(DDS.RETCODE_OK, deleting.rc);
    try testing.expect(!held.release_timed_out);
    try testing.expect(held.deleted_before_return);

    try target.deinit();
    try other.deinit();
    try h.deinit();
}

// ── The slice under each driver ───────────────────────────────────────────────

/// A reliable pair taken through the first slice: match, delivery, the
/// acknowledgment and data waits, a missed deadline, then retirement begun
/// from listeners. The writer's participant deletes itself at its first
/// missed deadline; that unmatches the reader, whose participant, the
/// runtime's last owner, then deletes itself. The application observes the
/// same trace under a manual and a hosted driver.
const Slice = struct {
    pair: Pair = undefined,
    /// Set from the reader's listener once its participant is deleted.
    io: ?std.Io = null,
    done: std.Io.Event = .unset,

    // Recorded by the application thread.
    publication_matched: i32 = 0,
    ack_rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    data_rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    got: std.ArrayListUnmanaged(u8) = .empty,

    // Recorded by the listeners. On a hosted runtime the writer's and the
    // reader's run on different workers, so each has fields of its own.
    deadline_calls: u32 = 0,
    deadline_total: i32 = 0,
    writer_in_lane: bool = false,
    writer_delete_rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,
    reader_matched: [4]i32 = undefined,
    reader_calls: usize = 0,
    reader_in_lane: bool = false,
    reader_delete_rc: DDS.ReturnCode_t = DDS.RETCODE_ERROR,

    const deadline: DDS.Duration_t = .{ .sec = 0, .nanosec = 100 * std.time.ns_per_ms };

    /// Creates the pair on `runtime`, which then has the participants as
    /// its only owners.
    fn init(self: *Slice, runtime: *rt.Runtime) !void {
        var o: PairOptions = .{};
        o.dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        o.dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        o.dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        o.dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        o.dw_listener = .{ .listener_data = self, .on_offered_deadline_missed = onDeadlineMissed };
        o.dw_mask = DDS.OFFERED_DEADLINE_MISSED_STATUS;
        o.dr_listener = .{ .listener_data = self, .on_subscription_matched = onSubscriptionMatched };
        o.dr_mask = DDS.SUBSCRIPTION_MATCHED_STATUS;
        try self.pair.initWith(runtime, o);
        runtime.releaseOwner();
    }

    /// The application's part, waiting through `ws`. Returns once the
    /// writer has a deadline to miss.
    fn run(self: *Slice, ws: *WaitSetImpl) !void {
        const waitset = ws.toDDSWaitSet();
        var active: DDS.ConditionSeq = .{};
        defer freeActive(&active);

        const wc = self.pair.dw_h.get_statuscondition();
        try testing.expectEqual(DDS.RETCODE_OK, wc.set_enabled_statuses(DDS.PUBLICATION_MATCHED_STATUS));
        try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(wc.as_Condition()));
        try testing.expectEqual(DDS.RETCODE_OK, waitset.wait(&active, seconds(10)));
        var matched: DDS.PublicationMatchedStatus = undefined;
        try testing.expectEqual(DDS.RETCODE_OK, self.pair.dw_h.get_publication_matched_status(&matched));
        self.publication_matched = matched.current_count;
        try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(wc.as_Condition()));

        // Each wait follows the writes it depends on, so on a hosted runtime
        // it usually finds them still in flight and blocks.
        const half = samples_n / 2;
        for (0..half) |i| try self.pair.write(i);
        self.ack_rc = self.pair.dw_h.wait_for_acknowledgments(seconds(10));
        // Acknowledged samples are in the reader's history.
        try takeInto(self.pair.dr, &self.got);
        try testing.expectEqual(@as(usize, half), self.got.items.len);

        const rc = self.pair.dr.toDDSDataReader().get_statuscondition();
        try testing.expectEqual(DDS.RETCODE_OK, rc.set_enabled_statuses(DDS.DATA_AVAILABLE_STATUS));
        try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(rc.as_Condition()));
        for (half..samples_n) |i| try self.pair.write(i);
        self.data_rc = DDS.RETCODE_OK;
        while (self.got.items.len < samples_n and self.data_rc == DDS.RETCODE_OK) {
            self.data_rc = waitset.wait(&active, seconds(10));
            try takeInto(self.pair.dr, &self.got);
        }
        try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(rc.as_Condition()));

        var qos: DDS.DataWriterQos = undefined;
        try testing.expectEqual(DDS.RETCODE_OK, self.pair.dw_h.get_qos(&qos));
        qos.deadline.period = deadline;
        try testing.expectEqual(DDS.RETCODE_OK, self.pair.dw_h.set_qos(qos));
    }

    fn onDeadlineMissed(_: *anyopaque, st: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
        const self: *Slice = @ptrCast(@alignCast(ld.?));
        self.deadline_calls += 1;
        if (self.deadline_calls > 1) return;
        self.deadline_total = st.total_count;
        self.writer_in_lane = listenersOf(self.pair.dp_w).isRunningHere();
        self.writer_delete_rc = deleteParticipant(&self.pair.w, self.pair.dp_w);
    }

    fn onSubscriptionMatched(_: *anyopaque, st: *const DDS.SubscriptionMatchedStatus, ld: ?*anyopaque) callconv(.c) void {
        const self: *Slice = @ptrCast(@alignCast(ld.?));
        if (self.reader_calls < self.reader_matched.len) self.reader_matched[self.reader_calls] = st.current_count;
        self.reader_calls += 1;
        if (st.current_count != 0) return;
        self.reader_in_lane = listenersOf(self.pair.dp_r).isRunningHere();
        self.reader_delete_rc = deleteParticipant(&self.pair.r, self.pair.dp_r);
        if (self.io) |io| self.done.set(io);
    }

    fn deleteParticipant(node: *Node, dp: DDS.DomainParticipant) DDS.ReturnCode_t {
        const rc = dp.delete_contained_entities();
        if (rc != DDS.RETCODE_OK) return rc;
        return node.factory.toDDSFactory().delete_participant(dp);
    }

    fn expectTrace(self: *const Slice, runtime: *rt.Runtime) !void {
        try testing.expectEqual(@as(i32, 1), self.publication_matched);
        try testing.expectEqual(DDS.RETCODE_OK, self.ack_rc);
        try testing.expectEqual(DDS.RETCODE_OK, self.data_rc);
        try expectInOrder(self.got.items, samples_n);
        try testing.expectEqual(@as(u32, 1), self.deadline_calls);
        try testing.expect(self.deadline_total >= 1);
        try testing.expect(self.writer_in_lane);
        try testing.expectEqual(DDS.RETCODE_OK, self.writer_delete_rc);
        try testing.expectEqualSlices(i32, &.{ 1, 0 }, self.reader_matched[0..self.reader_calls]);
        try testing.expect(self.reader_in_lane);
        try testing.expectEqual(DDS.RETCODE_OK, self.reader_delete_rc);
        try testing.expectEqual(rt.State.backend_stopped, runtime.getState());
    }

    fn deinit(self: *Slice) void {
        self.got.deinit(alloc);
        self.pair.freeNodes();
    }
};

test "the slice under a manual driver: the application's waits help, and listeners retire the runtime" {
    var m: Manual = undefined;
    m.init();
    var s: Slice = .{};
    try s.init(&m.runtime);
    const t0 = m.now();

    const ws = try WaitSetImpl.initHelping(alloc, &m.runtime);
    try s.run(ws);
    ws.deinit();
    // Nothing above needed time to pass.
    try testing.expectEqual(t0, m.now());

    var drives: usize = 0;
    while (m.runtime.getState() != .backend_stopped and drives < 100) : (drives += 1) {
        _ = try m.runtime.drive(64, 10 * SEC);
    }
    try s.expectTrace(&m.runtime);
    // The deadline was missed when due on the runtime clock.
    try testing.expectEqual(t0 + Slice.deadline.nanosec, m.now());
    s.deinit();
    m.runtime.deinit();
}

test "the slice under a hosted driver: the application's waits observe, and listeners retire the runtime" {
    var threaded: std.Io.Threaded = .init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var backend = rt.IoBackend.init(io);
    var runtime = rt.Runtime.init(backend.clock(), backend.backend(), .{ .mode = .hosted });
    var hosted = try rt.Hosted.init(alloc, io, &runtime, 2);
    hosted.start() catch |err| {
        runtime.releaseOwner();
        hosted.join();
        return err;
    };
    var s: Slice = .{ .io = io };
    s.init(&runtime) catch |err| {
        runtime.releaseOwner();
        hosted.join();
        return err;
    };

    const ws = try WaitSetImpl.init(alloc);
    try s.run(ws);
    ws.deinit();

    try s.done.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
    // The workers exit once the runtime stops.
    hosted.join();
    try s.expectTrace(&runtime);
    s.deinit();
    runtime.deinit();
}
