//! RTPS discovery (SPDP, SEDP and WLP) on the shared runtime, in the
//! `-Dshared-runtime` migration build
//! (docs/design/concurrency/runtime.md#thread-mapping): announcements, lease
//! checks and the built-in writers' heartbeats are timers on the runtime
//! clock, and what discovery receives is processed in runtime contexts. On a
//! manual runtime over the in-process transport, virtual time alone drives
//! announcements, fast announcing, lease expiry and liveness probes; over
//! loopback UDP, participants discover each other on a manual driver with no
//! thread started by zzdds, and on hosted workers.

const std = @import("std");
const builtin = @import("builtin");
const test_domain = @import("test_domain");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const rt = zzdds.runtime;

const c = std.c;
const MemoryBus = zzdds.intraprocess.MemoryBus;
const MemoryTransport = zzdds.intraprocess.MemoryTransport;
const LossyTransport = zzdds.lossy_transport.LossyTransport;
const PacketPolicy = zzdds.lossy_transport.PacketPolicy;
const UdpTransport = zzdds.udp_transport.UdpTransport;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const Transport = zzdds.transport.Transport;
const Locator = zzdds.transport.Locator;
const Config = zzdds.config.Config;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DomainParticipantImpl = zzdds.dcps.DomainParticipantImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history = zzdds.rtps.history;
const noop_security = zzdds.noop_security.noop_security_plugins;
const nil_participant = zzdds.dcps.nil_participant;

const testing = std.testing;
const alloc = testing.allocator;

comptime {
    if (!rt.enabled) @compileError("built against the library with -Dshared-runtime off");
}

const SEC: i64 = std.time.ns_per_s;
const MS: i64 = std.time.ns_per_ms;

/// The in-process transport has no multicast: only the first participant
/// listens on the SPDP port, and the refusals for the rest are logged.
fn quietLogs() std.log.Level {
    const prev = std.testing.log_level;
    std.testing.log_level = .err;
    return prev;
}

/// Threads in this process, where the platform reports it.
fn threadCount() ?usize {
    if (builtin.os.tag != .linux) return null;
    const fd = c.open("/proc/self/status", .{}, @as(c.mode_t, 0));
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = c.read(fd, &buf, buf.len);
    if (n <= 0) return null;
    var lines = std.mem.splitScalar(u8, buf[0..@intCast(n)], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Threads:")) continue;
        return std.fmt.parseInt(usize, std.mem.trim(u8, line["Threads:".len..], " \t"), 10) catch null;
    }
    return null;
}

/// Remote participants `dp` has discovered.
fn discoveredCount(dp: DDS.DomainParticipant) !usize {
    var seq: DDS.InstanceHandleSeq = .{};
    try testing.expectEqual(DDS.RETCODE_OK, dp.get_discovered_participants(&seq));
    defer if (seq._buffer) |buf| alloc.free(buf[0..seq._maximum]);
    return seq._length;
}

/// A reliable KEEP_ALL writer on `pub_dp` and reader on `sub_dp`.
const Endpoints = struct {
    dw: *DataWriterImpl,
    dr: *DataReaderImpl,

    fn init(pub_dp: DDS.DomainParticipant, sub_dp: DDS.DomainParticipant) Endpoints {
        var dw_qos: DDS.DataWriterQos = .{};
        dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        var dr_qos: DDS.DataReaderQos = .{};
        dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;
        const topic_w = pub_dp.create_topic("DiscTopic", "DiscType", .{}, null, 0);
        const topic_r = sub_dp.create_topic("DiscTopic", "DiscType", .{}, null, 0);
        const sub = sub_dp.create_subscriber(.{}, null, 0);
        const desc_r = @as(*TopicImpl, @ptrCast(@alignCast(topic_r.ptr))).toTopicDescription();
        const publisher = pub_dp.create_publisher(.{}, null, 0);
        return .{
            .dr = @ptrCast(@alignCast(sub.create_datareader(desc_r, dr_qos, null, 0).ptr)),
            .dw = @ptrCast(@alignCast(publisher.create_datawriter(topic_w, dw_qos, null, 0).ptr)),
        };
    }

    fn write(self: *Endpoints, i: usize) !void {
        const payload = [_]u8{ 0x00, 0x01, 0x00, 0x00, @truncate(i) };
        _ = try self.dw.writeRaw(.alive, RtpsTimestamp.now(), history.INSTANCE_HANDLE_NIL, std.mem.zeroes([16]u8), &payload);
    }

    fn takeInto(self: *Endpoints, got: *std.ArrayListUnmanaged(u8)) !void {
        while (self.dr.takeRaw()) |sample| {
            defer alloc.free(sample.data);
            if (sample.info.valid_data) try got.append(alloc, sample.data[4]);
        }
    }

    fn matched(self: *Endpoints) bool {
        var st: DDS.PublicationMatchedStatus = undefined;
        _ = self.dw.toDDSDataWriter().get_publication_matched_status(&st);
        return st.current_count > 0;
    }
};

const samples_n = 20;

fn expectInOrder(got: []const u8) !void {
    try testing.expectEqual(@as(usize, samples_n), got.len);
    for (got, 0..) |v, i| try testing.expectEqual(@as(u8, @truncate(i)), v);
}

// ── In-process, on virtual time ───────────────────────────────────────────────

/// Drops everything a node sends while `silent`, or only its SPDP
/// announcements while `quiet`, and counts those it multicasts.
const Gate = struct {
    silent: bool = false,
    quiet: bool = false,
    announcements: u32 = 0,

    fn policy(self: *Gate) PacketPolicy {
        return .{ .ctx = self, .should_drop = shouldDrop };
    }

    fn shouldDrop(ctx: *anyopaque, loc: *const Locator, data: []const u8, _: u64) bool {
        const self: *Gate = @ptrCast(@alignCast(ctx));
        if (self.silent) return true;
        if (self.quiet and std.mem.indexOf(u8, data, &spdp_writer) != null) return true;
        if (loc.* == .udp_v4 and loc.udp_v4.port == spdp_port) self.announcements += 1;
        return false;
    }

    /// Domain 0's SPDP multicast port.
    const spdp_port = 7400;
    /// The SPDP writer's entity id, as every announcement carries it.
    const spdp_writer = [_]u8{ 0x00, 0x01, 0x00, 0xc2 };
};

/// The lossy shim, presented as runnable on the runtime: it has no work of
/// its own, and the memory transport under it neither.
var gated_vtable: Transport.Vtable = undefined;

/// One participant's in-process transport behind a gate, RTPS discovery and
/// factory. Must not move after `init`.
const Node = struct {
    gate: Gate = .{},
    memory: *MemoryTransport,
    lossy: *LossyTransport,
    disc: *SpdpSedpDiscovery,
    factory: *DomainParticipantFactoryImpl,
    dp: DDS.DomainParticipant = nil_participant,
    /// Freed before the pair is.
    freed: bool = false,

    fn init(self: *Node, bus: *MemoryBus, announcement_period_ms: u32) !void {
        self.* = .{ .memory = undefined, .lossy = undefined, .disc = undefined, .factory = undefined };
        self.memory = try bus.createTransport();
        errdefer self.memory.deinit();
        self.lossy = try LossyTransport.init(alloc, self.memory.transport(), self.gate.policy());
        errdefer self.lossy.deinit(alloc);
        var t = self.lossy.transport();
        gated_vtable = t.vtable.*;
        gated_vtable.shared_runtime_ready = true;
        t.vtable = &gated_vtable;
        self.disc = try SpdpSedpDiscovery.init(alloc, t, 0, announcement_period_ms);
        errdefer self.disc.deinit();
        self.factory = try DomainParticipantFactoryImpl.init(alloc, t, self.disc.toDiscovery(), noop_security, .spec_random, .{});
    }

    fn create(self: *Node, runtime: *rt.Runtime, lease_ms: u32) !void {
        var config = Config{};
        config.participant.lease_duration_ms = lease_ms;
        try self.factory.selectRuntime(runtime);
        defer self.factory.selectRuntime(null) catch {};
        const qos = DDS.DomainParticipantQos{};
        self.dp = self.factory.createParticipantWithConfig(0, &qos, null, 0, config);
        try testing.expect(self.dp.ptr != nil_participant.ptr);
    }

    fn delete(self: *Node) !void {
        if (self.dp.ptr == nil_participant.ptr) return;
        try testing.expectEqual(DDS.RETCODE_OK, self.dp.delete_contained_entities());
        try testing.expectEqual(DDS.RETCODE_OK, self.factory.toDDSFactory().delete_participant(self.dp));
        self.dp = nil_participant;
    }

    /// Frees what the factory does not: discovery may outlive the runtime.
    fn deinitPlugins(self: *Node) void {
        self.disc.deinit();
        self.lossy.deinit(alloc);
        self.memory.deinit();
    }
};

/// Drives `runtime` until `done(ctx)` or `limit_ns` on its clock; returns
/// whether `done`.
fn driveRuntimeUntil(runtime: *rt.Runtime, limit_ns: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) anyerror!bool) !bool {
    while (!try done(ctx)) {
        const left = limit_ns - runtime.clock.nowNs();
        if (left <= 0) return false;
        _ = try runtime.drive(64, left);
    }
    return true;
}

/// Drives `runtime` to `until_ns` on its clock, running everything due.
fn driveRuntimeTo(runtime: *rt.Runtime, until_ns: i64) !void {
    while (runtime.clock.nowNs() < until_ns) _ = try runtime.drive(64, until_ns - runtime.clock.nowNs());
    while ((try runtime.drive(64, 0)).turns > 0) {}
}

/// Two nodes on one bus and one manual runtime over the scripted backend,
/// whose waits advance its clock to the next deadline. Must not move after
/// `init`.
const Pair = struct {
    sb: rt.ScriptedBackend,
    runtime: rt.Runtime,
    bus: *MemoryBus,
    a: Node,
    b: Node,
    /// The application's owner reference is released.
    released: bool = false,

    fn init(self: *Pair, announcement_period_ms: u32) !void {
        self.released = false;
        self.sb = rt.ScriptedBackend.init(1_000);
        self.runtime = rt.Runtime.init(self.sb.clock(), self.sb.backend(), .{ .mode = .manual });
        self.bus = try MemoryBus.init(alloc);
        try self.a.init(self.bus, announcement_period_ms);
        try self.b.init(self.bus, announcement_period_ms);
    }

    fn now(self: *Pair) i64 {
        return self.runtime.clock.nowNs();
    }

    /// Creates both participants, `a` first: it alone listens on the SPDP
    /// port. The participants take the runtime's only owner references.
    fn create(self: *Pair, a_lease_ms: u32, b_lease_ms: u32) !void {
        try self.a.create(&self.runtime, a_lease_ms);
        try self.b.create(&self.runtime, b_lease_ms);
        self.release();
    }

    fn release(self: *Pair) void {
        if (self.released) return;
        self.released = true;
        self.runtime.releaseOwner();
    }

    fn driveUntil(self: *Pair, limit_ns: i64, ctx: anytype, comptime done: fn (@TypeOf(ctx)) anyerror!bool) !bool {
        return driveRuntimeUntil(&self.runtime, limit_ns, ctx, done);
    }

    fn driveTo(self: *Pair, until_ns: i64) !void {
        return driveRuntimeTo(&self.runtime, until_ns);
    }

    fn bothDiscovered(self: *Pair) anyerror!bool {
        return try discoveredCount(self.a.dp) == 1 and try discoveredCount(self.b.dp) == 1;
    }

    fn aLostB(self: *Pair) anyerror!bool {
        return try discoveredCount(self.a.dp) == 0;
    }

    /// Deletes both participants, the runtime's last owners, which retires it.
    fn deinit(self: *Pair) void {
        self.a.delete() catch {};
        self.b.delete() catch {};
        self.release();
        var turns: usize = 0;
        while (self.runtime.getState() != .backend_stopped and turns < 1000) : (turns += 1) {
            _ = self.runtime.drive(64, 0) catch break;
        }
        for ([_]*Node{ &self.a, &self.b }) |n| if (!n.freed) n.factory.deinit();
        // Discovery's teardown must not touch the runtime once its
        // participant is gone.
        self.runtime.deinit();
        self.runtime = undefined;
        for ([_]*Node{ &self.a, &self.b }) |n| if (!n.freed) n.deinitPlugins();
        self.bus.deinit();
    }
};

test "on a manual runtime, participants discover each other, match and exchange reliable data on virtual time, with no thread of discovery's own" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    const threads_before = threadCount();
    var p: Pair = undefined;
    try p.init(1_000);
    defer p.deinit();
    try p.create(10_000, 10_000);

    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));

    var ep = Endpoints.init(p.a.dp, p.b.dp);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &ep, struct {
        fn f(e: *Endpoints) anyerror!bool {
            return e.matched();
        }
    }.f));
    for (0..samples_n) |i| try ep.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const deadline = p.now() + 10 * SEC;
    while (got.items.len < samples_n and p.now() < deadline) {
        _ = try p.runtime.drive(64, deadline - p.now());
        try ep.takeInto(&got);
    }
    try expectInOrder(got.items);

    if (threads_before) |n| try testing.expect(threadCount().? <= n);
    // Discovery's timers keep a deadline armed: driving never waited
    // without one.
    try testing.expectEqual(@as(u32, 0), p.sb.unbounded_waits);
    try testing.expectEqual(@as(u64, 0), p.a.disc.spdp.rx.drops.load(.monotonic) + p.a.disc.sedp.rx.drops.load(.monotonic));
}

test "SPDP announces once a period on the runtime clock, and every half period while a new participant is announced to" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(1_000);
    defer p.deinit();
    try p.a.create(&p.runtime, 10_000);

    // Alone: the announcement at start, then one each period.
    const start = p.now();
    try testing.expectEqual(@as(u32, 1), p.a.gate.announcements);
    try p.driveTo(start + 10 * SEC + 500 * MS);
    try testing.expectEqual(@as(u32, 11), p.a.gate.announcements);

    // Discovering `b` starts two periods of announcing every half period:
    // four announcements where two would go out otherwise.
    try p.b.create(&p.runtime, 10_000);
    p.release();
    const before = p.a.gate.announcements;
    const fast_from = p.now();
    try testing.expect(try p.driveUntil(fast_from + 1 * SEC, &p, Pair.bothDiscovered));
    try p.driveTo(fast_from + 2 * SEC - 1);
    try testing.expectEqual(before + 4, p.a.gate.announcements);

    // Then once a period again.
    const after = p.a.gate.announcements;
    try p.driveTo(fast_from + 6 * SEC);
    try testing.expectEqual(after + 4, p.a.gate.announcements);
}

test "a participant that falls silent is lost when its lease expires, on the runtime clock" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    // `b`'s 2 s lease ends before a probe could: one starts after 1.5 s of
    // silence at the slowest and runs a further second.
    try p.create(10_000, 2_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));
    // Past fast announcing, so `b` announces each 500 ms.
    try p.driveTo(p.now() + 3 * SEC);

    p.b.gate.silent = true;
    const silent_at = p.now();
    try testing.expect(try p.driveUntil(silent_at + 10 * SEC, &p, Pair.aLostB));
    // `b` last announced within a period before falling silent.
    const lost_at = p.now();
    try testing.expect(lost_at >= silent_at + 1_500 * MS);
    try testing.expect(lost_at <= silent_at + 2 * SEC);
}

test "a participant that falls silent with a long lease is lost by the liveness probe, on the runtime clock" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    try p.create(10_000, 100_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));
    // Long enough at 500 ms for `a` to have measured that interval.
    try p.driveTo(p.now() + 5 * SEC);

    // A probe starts after three announcement intervals of silence, 1.5 s
    // from `b`'s last announcement, and evicts `b` once its one second has
    // passed unanswered on the runtime clock, at the next heartbeat: long
    // before the 100 s lease ends, and not as soon as the probe starts.
    p.b.gate.silent = true;
    const silent_at = p.now();
    try testing.expect(try p.driveUntil(silent_at + 10 * SEC, &p, Pair.aLostB));
    const lost_at = p.now();
    try testing.expect(lost_at >= silent_at + 1_900 * MS);
    try testing.expect(lost_at <= silent_at + 3 * SEC);
}

test "a participant that answers a liveness probe is probed again once it falls silent" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    try p.create(10_000, 100_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));
    try p.driveTo(p.now() + 5 * SEC);

    // `b` stops announcing, but its built-in readers still acknowledge: each
    // probe finds it alive.
    p.b.gate.quiet = true;
    try p.driveTo(p.now() + 5 * SEC);
    try testing.expectEqual(@as(usize, 1), try discoveredCount(p.a.dp));

    // Silent altogether, it is lost by the next probe, not by its lease.
    p.b.gate.silent = true;
    const silent_at = p.now();
    try testing.expect(try p.driveUntil(silent_at + 10 * SEC, &p, Pair.aLostB));
}

test "deleting a participant disarms its discovery's timers, and the runtime runs on for the rest" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    try p.create(10_000, 10_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));

    try p.a.delete();
    try testing.expect(!p.a.disc.spdp.announce_timer.armed and !p.a.disc.spdp.lease_timer.armed);
    // With `a` freed, the runtime runs on past every deadline `a` had, and
    // `b` loses it.
    p.a.factory.deinit();
    p.a.deinitPlugins();
    p.a.freed = true;
    try p.driveTo(p.now() + 15 * SEC);
    try testing.expectEqual(@as(usize, 0), try discoveredCount(p.b.dp));
}

/// Matches a writer on `pub_dp` with a reader on `sub_dp` and delivers
/// `samples_n` samples in order, driving `runtime`.
fn exchangeOn(runtime: *rt.Runtime, pub_dp: DDS.DomainParticipant, sub_dp: DDS.DomainParticipant) !void {
    var ep = Endpoints.init(pub_dp, sub_dp);
    try testing.expect(try driveRuntimeUntil(runtime, runtime.clock.nowNs() + 5 * SEC, &ep, struct {
        fn f(e: *Endpoints) anyerror!bool {
            return e.matched();
        }
    }.f));
    for (0..samples_n) |i| try ep.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    const deadline = runtime.clock.nowNs() + 10 * SEC;
    while (got.items.len < samples_n and runtime.clock.nowNs() < deadline) {
        _ = try runtime.drive(64, deadline - runtime.clock.nowNs());
        try ep.takeInto(&got);
    }
    try expectInOrder(got.items);
}

/// `a`'s discovery announces each period and checks `b`'s lease on
/// `runtime`'s clock.
fn expectTimersRun(p: *Pair, runtime: *rt.Runtime) !void {
    const before = p.a.gate.announcements;
    try driveRuntimeTo(runtime, runtime.clock.nowNs() + 3 * SEC);
    try testing.expect(p.a.gate.announcements >= before + 5);
    p.b.gate.silent = true;
    try testing.expect(try driveRuntimeUntil(runtime, runtime.clock.nowNs() + 10 * SEC, p, Pair.aLostB));
}

test "a participant created again on a running runtime, after the one before it was deleted, discovers its peer, announces and checks leases" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    try p.create(10_000, 10_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));

    // `b` keeps the runtime running. It loses the deleted participant to
    // a liveness probe, as nothing listens for the BYE on the in-process
    // transport.
    try p.a.delete();
    try p.a.create(&p.runtime, 10_000);
    try testing.expect(try p.driveUntil(p.now() + 15 * SEC, &p, Pair.bothDiscovered));
    try exchangeOn(&p.runtime, p.a.dp, p.b.dp);
    try expectTimersRun(&p, &p.runtime);
}

test "after their participants are deleted and their runtime retired, discovery plugins serve the next participants on another runtime" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    try p.create(10_000, 10_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));
    try p.a.delete();
    try p.b.delete();
    while (p.runtime.getState() != .backend_stopped) _ = try p.runtime.drive(64, 0);

    var sb = rt.ScriptedBackend.init(1_000);
    var second = rt.Runtime.init(sb.clock(), sb.backend(), .{ .mode = .manual });
    defer second.deinit();
    try p.a.create(&second, 10_000);
    try p.b.create(&second, 10_000);
    second.releaseOwner();
    try testing.expect(try driveRuntimeUntil(&second, second.clock.nowNs() + 5 * SEC, &p, Pair.bothDiscovered));
    try exchangeOn(&second, p.a.dp, p.b.dp);
    try expectTimersRun(&p, &second);
    try testing.expectEqual(@as(u64, 0), p.a.disc.spdp.rx.drops.load(.monotonic) + p.a.disc.sedp.rx.drops.load(.monotonic));

    try p.a.delete();
    try p.b.delete();
    while (second.getState() != .backend_stopped) _ = try second.drive(64, 0);
}

test "a participant created disabled and deleted leaves its discovery plugin to the next participant, on another runtime" {
    const prev = quietLogs();
    defer std.testing.log_level = prev;
    var p: Pair = undefined;
    try p.init(500);
    defer p.deinit();
    var sb = rt.ScriptedBackend.init(1_000);
    var other = rt.Runtime.init(sb.clock(), sb.backend(), .{ .mode = .manual });
    defer other.deinit();

    // Attached to `other` at creation, never started.
    const f = p.a.factory.toDDSFactory();
    var disabled: DDS.DomainParticipantFactoryQos = .{};
    disabled.entity_factory.autoenable_created_entities = false;
    try testing.expectEqual(DDS.RETCODE_OK, f.set_qos(disabled));
    try p.a.create(&other, 10_000);
    try testing.expectEqual(DDS.RETCODE_OK, f.delete_participant(p.a.dp));
    p.a.dp = nil_participant;
    other.releaseOwner();
    while (other.getState() != .backend_stopped) _ = try other.drive(64, 0);
    try testing.expectEqual(DDS.RETCODE_OK, f.set_qos(.{}));

    try p.create(10_000, 10_000);
    try testing.expect(try p.driveUntil(p.now() + 5 * SEC, &p, Pair.bothDiscovered));
    try exchangeOn(&p.runtime, p.a.dp, p.b.dp);
}

// ── Over loopback UDP ─────────────────────────────────────────────────────────

/// Two participants, each with its own UDP transport and RTPS discovery, and
/// a reliable writer and reader between them.
const UdpPair = struct {
    udp: [2]*UdpTransport,
    disc: [2]*SpdpSedpDiscovery,
    factory: [2]*DomainParticipantFactoryImpl,
    dp: [2]DDS.DomainParticipant,
    ep: Endpoints,

    fn init(self: *UdpPair, runtime: ?*rt.Runtime, pid_base: u32) !void {
        for (0..2) |i| {
            self.udp[i] = try UdpTransport.init(alloc, .{ .participant_id = pid_base + @as(u32, @intCast(i)) }, test_domain.get(), null);
            self.disc[i] = try SpdpSedpDiscovery.init(alloc, self.udp[i].transport(), test_domain.get(), 1_000);
            self.factory[i] = try DomainParticipantFactoryImpl.init(alloc, self.udp[i].transport(), self.disc[i].toDiscovery(), noop_security, .spec_random, .{});
        }
        try self.createParticipants(runtime);
    }

    /// The participants take `runtime`'s only owner references. A null
    /// `runtime`: they resolve the default.
    fn createParticipants(self: *UdpPair, runtime: ?*rt.Runtime) !void {
        for (0..2) |i| {
            if (runtime) |r| try self.factory[i].selectRuntime(r);
            self.dp[i] = self.factory[i].toDDSFactory().create_participant(test_domain.get(), .{}, null, 0);
            try self.factory[i].selectRuntime(null);
            try testing.expect(self.dp[i].ptr != nil_participant.ptr);
            // Announcements and lease checks are timers: no thread.
            try testing.expect(self.disc[i].spdp.timer_thread == null);
        }
        if (runtime) |r| r.releaseOwner();
        self.ep = Endpoints.init(self.dp[0], self.dp[1]);
    }

    /// Deletes both participants, the runtime's last owners.
    fn deleteParticipants(self: *UdpPair) !void {
        for (0..2) |i| {
            try testing.expectEqual(DDS.RETCODE_OK, self.dp[i].delete_contained_entities());
            try testing.expectEqual(DDS.RETCODE_OK, self.factory[i].toDDSFactory().delete_participant(self.dp[i]));
        }
    }

    fn deinit(self: *UdpPair) void {
        for (0..2) |i| {
            self.factory[i].deinit();
            self.disc[i].deinit();
            self.udp[i].deinit();
        }
    }
};

test "over loopback UDP, RTPS discovery runs on a manual runtime driven by drive() alone, with no thread started by zzdds" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    var io_impl: std.Io.Threaded = .init(alloc, .{});
    defer io_impl.deinit();
    var pb = try rt.PollBackend.init(alloc, io_impl.io());
    defer pb.deinit();
    var runtime = rt.Runtime.init(pb.clock(), pb.backend(), .{ .mode = .manual });
    defer runtime.deinit();

    const threads_before = threadCount();
    var pair: UdpPair = undefined;
    try pair.init(&runtime, 44);
    defer pair.deinit();

    const deadline = runtime.clock.nowNs() + 10 * SEC;
    while (!pair.ep.matched() and runtime.clock.nowNs() < deadline) _ = try runtime.drive(64, 100 * MS);
    try testing.expect(pair.ep.matched());
    for (0..samples_n) |i| try pair.ep.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    while (got.items.len < samples_n and runtime.clock.nowNs() < deadline) {
        _ = try runtime.drive(64, 100 * MS);
        try pair.ep.takeInto(&got);
    }
    try expectInOrder(got.items);
    // No more than before: a thread an earlier test joined may still be
    // listed in the first count.
    if (threads_before) |n| try testing.expect(threadCount().? <= n);

    try pair.deleteParticipants();
    try testing.expectEqual(@as(usize, 0), pb.sourceCount());
    while (runtime.getState() != .backend_stopped) _ = try runtime.drive(64, 0);
}

/// Matches the pair's writer and reader and delivers `samples_n` samples
/// in order, waiting on a WaitSet while hosted workers do the work.
fn exchangeHosted(pair: *UdpPair) !void {
    const ws = try zzdds.dcps.WaitSetImpl.init(alloc);
    defer ws.deinit();
    const waitset = ws.toDDSWaitSet();
    var active: DDS.ConditionSeq = .{};
    defer if (active._buffer) |buf| alloc.free(buf[0..active._maximum]);

    // Discovery matches them on the workers: the writer is volatile, so
    // what it wrote before would not be delivered.
    const matched = pair.ep.dw.toDDSDataWriter().get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, matched.set_enabled_statuses(DDS.PUBLICATION_MATCHED_STATUS));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(matched.as_Condition()));
    while (!pair.ep.matched()) try testing.expectEqual(DDS.RETCODE_OK, waitset.wait(&active, .{ .sec = 10, .nanosec = 0 }));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(matched.as_Condition()));

    const cond = pair.ep.dr.toDDSDataReader().get_statuscondition();
    try testing.expectEqual(DDS.RETCODE_OK, cond.set_enabled_statuses(DDS.DATA_AVAILABLE_STATUS));
    try testing.expectEqual(DDS.RETCODE_OK, waitset.attach_condition(cond.as_Condition()));
    for (0..samples_n) |i| try pair.ep.write(i);
    var got: std.ArrayListUnmanaged(u8) = .empty;
    defer got.deinit(alloc);
    while (got.items.len < samples_n) {
        try testing.expectEqual(DDS.RETCODE_OK, waitset.wait(&active, .{ .sec = 10, .nanosec = 0 }));
        try pair.ep.takeInto(&got);
    }
    try testing.expectEqual(DDS.RETCODE_OK, waitset.detach_condition(cond.as_Condition()));
    try expectInOrder(got.items);
}

test "over loopback UDP, RTPS discovery runs on the default runtime's hosted workers" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    const registry = &rt.default_registry.global;
    defer {
        registry.clear();
        registry.reap(true);
    }
    var pair: UdpPair = undefined;
    try pair.init(null, 46);
    defer pair.deinit();
    try exchangeHosted(&pair);
    try pair.deleteParticipants();
}

test "over loopback UDP, participants created again from the same factories, after the default runtime retired, run on its next generation" {
    if (!rt.poll_backend.supported) return error.SkipZigTest;
    const registry = &rt.default_registry.global;
    defer {
        registry.clear();
        registry.reap(true);
    }
    var pair: UdpPair = undefined;
    try pair.init(null, 48);
    defer pair.deinit();
    const generation = registry.generations;
    try exchangeHosted(&pair);
    // The participants were the default runtime's last owners.
    try pair.deleteParticipants();

    try pair.createParticipants(null);
    try testing.expectEqual(generation + 1, registry.generations);
    try exchangeHosted(&pair);
    try pair.deleteParticipants();
}
