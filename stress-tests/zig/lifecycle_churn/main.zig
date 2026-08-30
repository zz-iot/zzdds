//! stress-tests/zig/lifecycle_churn -- in-process, N-thread entity /
//! listener / lifecycle churn. Generalizes the single hand-built scenario
//! in zzdds/test/dcps/participant_vtable_test.zig ("reentrant
//! delete_participant from a timer-driven listener") into a load test.
//!
//! `DebugAllocator` is *the* allocator: any leak / double-free / UAF in
//! churned teardown fails the process at exit. Runs standalone; run.py
//! sweeps scenarios and (in CI) also builds it once under
//! `-Dsanitize-thread` for the data-race lane.
//!
//! Scenarios:
//!   entities   -- N threads create -> use -> delete DataWriter/DataReader/
//!                 Publisher/Subscriber on a shared participant while SEDP
//!                 matching is active, for --duration seconds.
//!   reentrant  -- N threads, --iterations each: stand up participant +
//!                 publisher + datawriter whose DEADLINE listener (fired
//!                 from the participant's own timer thread) reentrantly
//!                 deletes the whole graph including the participant.
//!
//! Ends with `SUMMARY: OK scenario=<s> ops=<n>` or a `FAIL:`/panic + exit 1.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const gen = @import("messenger_gen");

const TYPE_NAME = "Message";

fn sleepMs(io: std.Io, ms: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ms * std.time.ns_per_ms) }, .clock = .awake }).sleep(io) catch {};
}
fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

const Scenario = enum { entities, reentrant };

const Config = struct {
    scenario: Scenario,
    threads: u32 = 6,
    iterations: u32 = 40,
    duration_s: u32 = 8,
    domain: u32 = 71,
    seed: u64 = 0,
};

fn usage() noreturn {
    std.debug.print(
        \\usage: churn_stress --scenario entities|reentrant [options]
        \\  --threads N       concurrent churn threads (default 6)
        \\  --iterations N    reentrant: cycles per thread (default 40)
        \\  --duration N      entities: seconds to churn (default 8)
        \\  --domain N        DDS domain id (default 71)
        \\  --seed N          RNG seed
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(raw: std.process.Args) Config {
    var it = std.process.Args.Iterator.init(raw);
    _ = it.skip();
    var scenario: ?Scenario = null;
    var cfg = Config{ .scenario = undefined };
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--scenario")) {
            const v = it.next() orelse usage();
            scenario = if (std.mem.eql(u8, v, "entities")) .entities else if (std.mem.eql(u8, v, "reentrant")) .reentrant else usage();
        } else if (std.mem.eql(u8, a, "--threads")) {
            cfg.threads = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--iterations")) {
            cfg.iterations = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--duration")) {
            cfg.duration_s = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--domain")) {
            cfg.domain = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--seed")) {
            cfg.seed = std.fmt.parseInt(u64, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
        } else {
            std.debug.print("FAIL: unknown argument '{s}'\n", .{a});
            usage();
        }
    }
    cfg.scenario = scenario orelse usage();
    return cfg;
}

var g_alloc: std.mem.Allocator = undefined;
var g_ts_alloc: std.mem.Allocator = undefined;
var g_ops = std.atomic.Value(u64).init(0);
var g_fail = std.atomic.Value(bool).init(false);

fn fail(comptime msg: []const u8) void {
    std.debug.print("FAIL: " ++ msg ++ "\n", .{});
    g_fail.store(true, .release);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("FAIL: DebugAllocator detected a leak at exit\n", .{});
            std.process.exit(1);
        }
    }
    g_alloc = gpa.allocator();
    g_ts_alloc = g_alloc;

    const cfg = parseArgs(init.minimal.args);

    switch (cfg.scenario) {
        .entities => try runEntities(io, cfg),
        .reentrant => try runReentrant(io, cfg),
    }

    if (g_fail.load(.acquire)) std.process.exit(1);
    std.debug.print("SUMMARY: OK scenario={s} ops={d}\n", .{ @tagName(cfg.scenario), g_ops.load(.monotonic) });
}

// ── scenario: entities ─────────────────────────────────────────────────────
//
// One shared participant + topic. N threads each spin create -> delete of a
// Publisher+DataWriter or Subscriber+DataReader while the others do the
// same, so SEDP is continuously (un)matching. A leak or UAF in any teardown
// path shows up as a DebugAllocator failure or a crash.

const EntitiesCtx = struct {
    io: std.Io,
    dp: DDS.DomainParticipant,
    topic: DDS.Topic,
    td: DDS.TopicDescription,
    deadline_ns: i64,
    idx: u32,
};

fn entitiesThread(ctx: EntitiesCtx) void {
    var local: u64 = 0;
    while (monoNs(ctx.io) < ctx.deadline_ns and !g_fail.load(.acquire)) {
        if (ctx.idx % 2 == 0) {
            const p = ctx.dp.create_publisher(.{}, null, 0);
            if (p.ptr == zzdds.dcps.NIL_PTR) {
                fail("create_publisher returned nil under churn");
                return;
            }
            var qos = DDS.DataWriterQos{};
            qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
            const w = p.create_datawriter(ctx.topic, qos, null, 0);
            if (w.ptr != zzdds.dcps.NIL_PTR) _ = p.delete_datawriter(w);
            _ = ctx.dp.delete_publisher(p);
        } else {
            const sub = ctx.dp.create_subscriber(.{}, null, 0);
            if (sub.ptr == zzdds.dcps.NIL_PTR) {
                fail("create_subscriber returned nil under churn");
                return;
            }
            var qos = DDS.DataReaderQos{};
            qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
            const r = sub.create_datareader(ctx.td, qos, null, 0);
            if (r.ptr != zzdds.dcps.NIL_PTR) _ = sub.delete_datareader(r);
            _ = ctx.dp.delete_subscriber(sub);
        }
        local += 1;
        sleepMs(ctx.io, 1);
    }
    _ = g_ops.fetchAdd(local, .monotonic);
}

fn runEntities(io: std.Io, cfg: Config) !void {
    var factory = zzdds.createFactory() catch {
        fail("createFactory");
        return;
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_participant");
        return;
    }
    defer _ = dpf.delete_participant(dp);

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(&g_ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
    })) {
        fail("registerTypeSupport");
        return;
    }

    const topic = dp.create_topic("ChurnTopic", TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        fail("create_topic");
        return;
    }
    defer _ = dp.delete_topic(topic);
    const td = dp.lookup_topicdescription("ChurnTopic");

    const deadline_ns = monoNs(io) + @as(i64, cfg.duration_s) * std.time.ns_per_s;

    const threads = try g_alloc.alloc(std.Thread, cfg.threads);
    defer g_alloc.free(threads);
    for (threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, entitiesThread, .{EntitiesCtx{
            .io = io,
            .dp = dp,
            .topic = topic,
            .td = td,
            .deadline_ns = deadline_ns,
            .idx = @intCast(i),
        }});
    }
    for (threads) |t| t.join();
}

// ── scenario: reentrant ────────────────────────────────────────────────────
//
// The seed test, run --threads-wide and --iterations-deep. Each cycle: a
// DEADLINE listener fired from the participant's own timer thread reentrantly
// deletes datawriter -> publisher -> topic -> participant. The teardown
// therefore runs *on the timer thread deinit() is trying to stop* -- the
// exact self-join / self-free hazard.

const ReentrantCtx = struct {
    factory: DDS.DomainParticipantFactory,
    dp: DDS.DomainParticipant,
    pub_: DDS.Publisher,
    topic: DDS.Topic,
    dw: DDS.DataWriter,
    ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    fired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onDeadlineMissed(_: *anyopaque, _: *const DDS.OfferedDeadlineMissedStatus, ld: ?*anyopaque) callconv(.c) void {
    const ctx: *ReentrantCtx = @ptrCast(@alignCast(ld));
    if (!ctx.ready.load(.acquire)) return;
    if (ctx.fired.swap(true, .acq_rel)) return;
    _ = ctx.pub_.delete_datawriter(ctx.dw);
    _ = ctx.dp.delete_publisher(ctx.pub_);
    _ = ctx.dp.delete_topic(ctx.topic);
    _ = ctx.factory.delete_participant(ctx.dp);
    ctx.done.store(true, .release);
}

fn reentrantThread(io: std.Io, cfg: Config) void {
    var it: u32 = 0;
    while (it < cfg.iterations and !g_fail.load(.acquire)) : (it += 1) {
        var factory = zzdds.createFactory() catch {
            fail("reentrant: createFactory");
            return;
        };
        const dpf = factory.toDDSFactory();
        const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
        if (dp.ptr == zzdds.dcps.NIL_PTR) {
            fail("reentrant: create_participant");
            factory.deinit();
            return;
        }
        const pub_ = dp.create_publisher(.{}, null, 0);
        const topic = dp.create_topic("ReentrantTopic", TYPE_NAME, .{}, null, 0);

        var ctx = ReentrantCtx{ .factory = dpf, .dp = dp, .pub_ = pub_, .topic = topic, .dw = undefined };
        var dw_qos = DDS.DataWriterQos{};
        dw_qos.deadline.period = .{ .sec = 0, .nanosec = 50_000_000 }; // 50ms
        const dw = pub_.create_datawriter(topic, dw_qos, DDS.DataWriterListener{
            .listener_data = &ctx,
            .on_offered_deadline_missed = onDeadlineMissed,
        }, DDS.OFFERED_DEADLINE_MISSED_STATUS);
        ctx.dw = dw;
        ctx.ready.store(true, .release);

        const deadline = monoNs(io) + 5 * std.time.ns_per_s;
        while (!ctx.done.load(.acquire)) {
            if (monoNs(io) >= deadline) {
                fail("reentrant: listener never fired within 5s (self-join deadlock?)");
                return;
            }
            sleepMs(io, 10);
        }
        // The detached timer thread still has a little unwinding + its own
        // alloc.destroy(self) to do after ctx.done flips; give it room so
        // the next iteration doesn't race it on the shared DebugAllocator.
        // Generous, not tight.
        sleepMs(io, 50);
        // The listener deleted the participant; this destroys the now-empty
        // FactoryOwner. (In the seed unit test this is `defer factory.deinit()`.)
        factory.deinit();
        _ = g_ops.fetchAdd(1, .monotonic);
    }
}

fn runReentrant(io: std.Io, cfg: Config) !void {
    const threads = try g_alloc.alloc(std.Thread, cfg.threads);
    defer g_alloc.free(threads);
    for (threads) |*t| t.* = try std.Thread.spawn(.{}, reentrantThread, .{ io, cfg });
    for (threads) |t| t.join();
}
