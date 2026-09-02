//! stress-tests/zig/entity_lifecycle_stress -- multi-process port of
//! OpenDDS's tests/DCPS/EntityLifecycleStress.
//!
//! One binary; `run.py` spawns N `--role pub` + M `--role sub` processes,
//! interleaved, on one (per-run-unique) domain. Each process stands up the
//! full entity graph, does its work (write 750 small / 4 large samples;
//! wait for the first valid sample), then tears down -- either explicitly
//! child-first or leaning on `delete_contained_entities()` -- while its
//! peers are still discovering/matching/leaving.
//!
//! Faithful to OpenDDS: the entity graph, the keyed `Message` type, the
//! sample profiles, subscriber-waits-for-first-valid-sample, and a monitor
//! thread that warns if teardown drags. Different from OpenDDS: the cleanup
//! path is a deterministic flag (not `pid % 3`), a `DebugAllocator` makes a
//! leak/UAF a hard exit failure, and every process ends with a structured
//!   SUMMARY: OK role=<r> teardown_ms=<n> entities_created=<n> samples=<n>
//! line the harness asserts on.
//!
//! Any failure path prints a line starting "FAIL:" and exits nonzero.
//! Linux-only (uses getpid for the process label); the stress harness runs
//! on Linux CI.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const gen = @import("messenger_gen");

const TOPIC_NAME = "Movie Discussion List";
const TYPE_NAME = "Message";
const KEY_SUBJECT_ID: i32 = 16;

// ── time (std.time.sleep / nanoTimestamp don't exist in this Zig) ────────────

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

// ── args ────────────────────────────────────────────────────────────────────

const Role = enum { writer, reader };
const Cleanup = enum { explicit, cascade };

const Config = struct {
    role: Role,
    domain: u32 = 31,
    samples: u32 = 750,
    large: bool = false,
    cleanup: Cleanup = .explicit,
    churn: bool = false,
    churn_iters: u32 = 20,
    wait_ms: u32 = 7500,
    slow_teardown_warn_ms: u32 = 3000,
    seed: u64 = 0,
};

fn usage() noreturn {
    std.debug.print(
        \\usage: elc_stress --role pub|sub [options]
        \\  --domain N                 DDS domain id (default 31)
        \\  --samples N                publisher: samples to write (default 750)
        \\  --large                    publisher: 4 x 4000-byte samples, 2s apart
        \\  --cleanup explicit|cascade explicit deletes children first; cascade
        \\                             relies on delete_contained_entities (default explicit)
        \\  --churn                    after main work, create/delete a DW/DR on the
        \\                             live participant during teardown
        \\  --churn-iters N            churn loop count (default 20)
        \\  --wait-ms N                subscriber: wait for first valid sample (default 7500)
        \\  --slow-teardown-warn-ms N  monitor-thread warn threshold (default 3000)
        \\  --seed N                   RNG seed for reproducible interleaving
        \\
    , .{});
    std.process.exit(2);
}

fn parseArgs(raw: std.process.Args) Config {
    var it = std.process.Args.Iterator.init(raw);
    _ = it.skip(); // program name
    var role: ?Role = null;
    var cfg = Config{ .role = undefined };
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--role")) {
            const v = it.next() orelse usage();
            role = if (std.mem.eql(u8, v, "pub")) .writer else if (std.mem.eql(u8, v, "sub")) .reader else usage();
        } else if (std.mem.eql(u8, a, "--domain")) {
            cfg.domain = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--samples")) {
            cfg.samples = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--large")) {
            cfg.large = true;
        } else if (std.mem.eql(u8, a, "--cleanup")) {
            const v = it.next() orelse usage();
            cfg.cleanup = if (std.mem.eql(u8, v, "explicit")) .explicit else if (std.mem.eql(u8, v, "cascade")) .cascade else usage();
        } else if (std.mem.eql(u8, a, "--churn")) {
            cfg.churn = true;
        } else if (std.mem.eql(u8, a, "--churn-iters")) {
            cfg.churn_iters = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--wait-ms")) {
            cfg.wait_ms = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--slow-teardown-warn-ms")) {
            cfg.slow_teardown_warn_ms = std.fmt.parseInt(u32, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "--seed")) {
            cfg.seed = std.fmt.parseInt(u64, it.next() orelse usage(), 10) catch usage();
        } else if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
            usage();
        } else {
            std.debug.print("FAIL: unknown argument '{s}'\n", .{a});
            usage();
        }
    }
    cfg.role = role orelse usage();
    if (cfg.large) cfg.samples = 4;
    return cfg;
}

// ── teardown monitor (OpenDDS's cleanup_monitor thread) ─────────────────────

const Monitor = struct {
    io: std.Io,
    started_ns: i64,
    warn_after_ms: u32,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Monitor) void {
        var warned = false;
        while (!self.done.load(.acquire)) {
            sleepNs(self.io, std.time.ns_per_s);
            if (self.done.load(.acquire)) break;
            const elapsed_ms = @divTrunc(monoNs(self.io) - self.started_ns, std.time.ns_per_ms);
            if (!warned and elapsed_ms >= self.warn_after_ms) {
                warned = true;
                std.debug.print("SLOW_TEARDOWN: still cleaning up after {d}ms\n", .{elapsed_ms});
            }
        }
    }
};

// ── subscriber listener state ──────────────────────────────────────────────

const SubState = struct {
    alloc: std.mem.Allocator,
    valid_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn onDataAvailable(state: *SubState, dr: DDS.DataReader) void {
    var reader = gen.MessageDataReader.init(dr, state.alloc);
    while (true) {
        var value: gen.Message = .{};
        var info: DDS.SampleInfo = .{};
        const got = reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;
        _ = state.count.fetchAdd(1, .monotonic);
        state.valid_seen.store(true, .release);
    }
}

// ── shared setup ───────────────────────────────────────────────────────────

const Setup = struct {
    dpf: DDS.DomainParticipantFactory,
    dp: DDS.DomainParticipant,
    topic: DDS.Topic,
};

/// `factory` and `ts_alloc` are caller-owned storage that must outlive
/// everything (the TypeSupport ctx is a `*const std.mem.Allocator` the
/// generated key-hash path dereferences on every keyed write).
fn commonSetup(
    factory: *zzdds.DomainParticipantFactory,
    ts_alloc: *std.mem.Allocator,
    cfg: Config,
) Setup {
    factory.* = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(cfg.domain, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{cfg.domain});
        std.process.exit(1);
    }

    if (!zzdds.registerTypeSupport(dp, TYPE_NAME, .{
        .ctx = @ptrCast(ts_alloc),
        .compute_key_hash = gen.Message.computeKeyHashFromCdr,
        .has_key = gen.Message.has_key,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic(TOPIC_NAME, TYPE_NAME, .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    return .{ .dpf = dpf, .dp = dp, .topic = topic };
}

// ── main ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        if (gpa.deinit() == .leak) {
            std.debug.print("FAIL: DebugAllocator detected a leak at exit\n", .{});
            std.process.exit(1);
        }
    }
    const alloc = gpa.allocator();

    const cfg = parseArgs(init.minimal.args);
    switch (cfg.role) {
        .writer => try runPub(io, alloc, cfg),
        .reader => try runSub(io, alloc, cfg),
    }
}

fn pid() i32 {
    return std.os.linux.getpid();
}

fn runPub(io: std.Io, alloc: std.mem.Allocator, cfg: Config) !void {
    var factory: zzdds.DomainParticipantFactory = undefined;
    var ts_alloc = alloc;
    const s = commonSetup(&factory, &ts_alloc, cfg);

    const publisher = s.dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dw_qos.history.depth = 16;

    const dw = publisher.create_datawriter(s.topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    var entities_created: u32 = 4; // participant, topic, publisher, datawriter

    const writer = gen.MessageDataWriter.init(dw, alloc);

    var msg = gen.Message{ .subject_id = KEY_SUBJECT_ID, .count = 0 };
    var from_buf: [32]u8 = undefined;
    msg.from = @TypeOf(msg.from).fromSlice(std.fmt.bufPrint(&from_buf, "{d}", .{pid()}) catch "pub") catch .{};
    msg.subject = @TypeOf(msg.subject).fromSlice("Review") catch .{};
    const large_text = [_]u8{'Z'} ** 4000;
    msg.text = @TypeOf(msg.text).fromSlice(if (cfg.large) large_text[0..] else "Wash. Rinse. Repeat.") catch .{};

    const handle = writer.register_instance(msg);

    const delay_ns: u64 = if (cfg.large) 2 * std.time.ns_per_s else 10 * std.time.ns_per_ms;
    var i: u32 = 0;
    while (i < cfg.samples) : (i += 1) {
        sleepNs(io, delay_ns);
        msg.count += 1;
        writer.write(msg, handle) catch {
            std.debug.print("FAIL: write() failed at count={d}\n", .{msg.count});
            std.process.exit(1);
        };
    }
    std.debug.print("Publisher {d} is done. Exiting.\n", .{pid()});

    if (cfg.churn) entities_created += churnWriter(io, s.dp, s.topic, cfg.churn_iters);

    const teardown_ms = teardown(io, .{
        .cfg = cfg,
        .factory = &factory,
        .dpf = s.dpf,
        .dp = s.dp,
        .topic = s.topic,
        .kind = .{ .writer = .{ .publisher = publisher, .dw = dw } },
    });

    std.debug.print(
        "SUMMARY: OK role=pub teardown_ms={d} entities_created={d} samples={d}\n",
        .{ teardown_ms, entities_created, cfg.samples },
    );
}

fn runSub(io: std.Io, alloc: std.mem.Allocator, cfg: Config) !void {
    var factory: zzdds.DomainParticipantFactory = undefined;
    var ts_alloc = alloc;
    const s = commonSetup(&factory, &ts_alloc, cfg);

    const subscriber = s.dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_LAST_HISTORY_QOS;
    dr_qos.history.depth = 16;

    var state = SubState{ .alloc = alloc };
    const listener = DDS.dataReaderListener(&state, .{ .on_data_available = onDataAvailable });

    const topic_desc = s.dp.lookup_topicdescription(TOPIC_NAME);
    const dr = subscriber.create_datareader(topic_desc, dr_qos, listener, DDS.DATA_AVAILABLE_STATUS);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    var entities_created: u32 = 4; // participant, topic, subscriber, datareader

    const deadline = monoNs(io) + @as(i64, cfg.wait_ms) * std.time.ns_per_ms;
    while (!state.valid_seen.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: no valid sample within {d}ms\n", .{cfg.wait_ms});
            std.process.exit(1);
        }
        sleepNs(io, 20 * std.time.ns_per_ms);
    }
    std.debug.print("Subscriber {d} got new message data. Exiting.\n", .{pid()});

    if (cfg.churn) entities_created += churnReader(io, s.dp, cfg.churn_iters);

    const teardown_ms = teardown(io, .{
        .cfg = cfg,
        .factory = &factory,
        .dpf = s.dpf,
        .dp = s.dp,
        .topic = s.topic,
        .kind = .{ .reader = .{ .subscriber = subscriber, .dr = dr } },
    });

    std.debug.print(
        "SUMMARY: OK role=sub teardown_ms={d} entities_created={d} samples={d}\n",
        .{ teardown_ms, entities_created, state.count.load(.monotonic) },
    );
}

// ── churn: create/delete a child entity repeatedly on the live participant ──

fn churnWriter(io: std.Io, dp: DDS.DomainParticipant, topic: DDS.Topic, iters: u32) u32 {
    var made: u32 = 0;
    var qos = DDS.DataWriterQos{};
    qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    var k: u32 = 0;
    while (k < iters) : (k += 1) {
        const p = dp.create_publisher(.{}, null, 0);
        if (p.ptr == zzdds.dcps.NIL_PTR) continue;
        const w = p.create_datawriter(topic, qos, null, 0);
        if (w.ptr != zzdds.dcps.NIL_PTR) {
            made += 2;
            _ = p.delete_datawriter(w);
        }
        _ = dp.delete_publisher(p);
        sleepNs(io, 2 * std.time.ns_per_ms);
    }
    return made;
}

fn churnReader(io: std.Io, dp: DDS.DomainParticipant, iters: u32) u32 {
    var made: u32 = 0;
    var qos = DDS.DataReaderQos{};
    qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const td = dp.lookup_topicdescription(TOPIC_NAME);
    var k: u32 = 0;
    while (k < iters) : (k += 1) {
        const sub = dp.create_subscriber(.{}, null, 0);
        if (sub.ptr == zzdds.dcps.NIL_PTR) continue;
        const r = sub.create_datareader(td, qos, null, 0);
        if (r.ptr != zzdds.dcps.NIL_PTR) {
            made += 2;
            _ = sub.delete_datareader(r);
        }
        _ = dp.delete_subscriber(sub);
        sleepNs(io, 2 * std.time.ns_per_ms);
    }
    return made;
}

// ── teardown (timed, monitored) ────────────────────────────────────────────

const TeardownArgs = struct {
    cfg: Config,
    factory: *zzdds.DomainParticipantFactory,
    dpf: DDS.DomainParticipantFactory,
    dp: DDS.DomainParticipant,
    topic: DDS.Topic,
    kind: union(enum) {
        writer: struct { publisher: DDS.Publisher, dw: DDS.DataWriter },
        reader: struct { subscriber: DDS.Subscriber, dr: DDS.DataReader },
    },
};

fn teardown(io: std.Io, a: TeardownArgs) i64 {
    const start = monoNs(io);
    var mon = Monitor{ .io = io, .started_ns = start, .warn_after_ms = a.cfg.slow_teardown_warn_ms };
    const mon_thread = std.Thread.spawn(.{}, Monitor.run, .{&mon}) catch null;

    if (a.cfg.cleanup == .explicit) {
        switch (a.kind) {
            .writer => |p| {
                _ = p.publisher.delete_datawriter(p.dw);
                _ = a.dp.delete_publisher(p.publisher);
            },
            .reader => |sub| {
                _ = sub.subscriber.delete_datareader(sub.dr);
                _ = a.dp.delete_subscriber(sub.subscriber);
            },
        }
        _ = a.dp.delete_topic(a.topic);
    }

    _ = a.dp.delete_contained_entities();
    _ = a.dpf.delete_participant(a.dp);
    a.factory.deinit();

    mon.done.store(true, .release);
    if (mon_thread) |t| t.join();

    return @divTrunc(monoNs(io) - start, std.time.ns_per_ms);
}
