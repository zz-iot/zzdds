//! zig/participant-config -- subscriber.
//!
//! Same two mutually exclusive modes as the publisher (see publisher.zig's
//! doc comment): programmatic (default) round-trips a config value through
//! set_default_participant_config/get_default_participant_config before
//! creating the participant via create_participant_ex; file mode
//! (--config <path>) loads a zzdds.toml-style file instead. Both then run
//! the same minimal reliable read loop (3 samples) as zig/hello_world.
//!
//! Required stdout markers: "Create topic:", "Create reader for topic:",
//! "Subscriber: received count=", "Subscriber: received all 3 samples in
//! order." Programmatic mode additionally prints "Config round-trip OK: ...".
//! Any failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const ping_gen = @import("config_ping_gen");

const EXPECTED_SAMPLES: i32 = 3;
const RECEIVE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

const CONFIG_PARTICIPANT_NAME = "participant-config-example";
const CONFIG_FRAGMENT_SIZE: u16 = 9000;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    expected_next: i32 = 0,
    all_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,
};

fn onDataAvailable(state: *State, dr: DDS.DataReader) void {
    var reader = ping_gen.ConfigPingDataReader.init(dr, state.alloc);
    while (true) {
        var value: ping_gen.ConfigPing = .{};
        var info: DDS.SampleInfo = .{};
        const got = reader.take_next_sample(&value, &info) catch {
            std.debug.print("FAIL: take_next_sample() CDR error\n", .{});
            std.process.exit(1);
        };
        if (!got) break;
        if (!info.valid_data) continue;

        if (value.count != state.expected_next) {
            std.debug.print("FAIL: expected count={d} but got count={d}\n", .{ state.expected_next, value.count });
            std.process.exit(1);
        }

        std.debug.print("Subscriber: received count={d}\n", .{value.count});
        state.expected_next += 1;

        if (state.expected_next == EXPECTED_SAMPLES) {
            state.all_received.store(true, .release);
        }
    }
}

const Options = struct {
    domain_id: u32 = 0,
    config_path: ?[]const u8 = null,
};

fn parseArgs(process_args: std.process.Args) Options {
    var opts = Options{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // program name
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            opts.domain_id = std.fmt.parseInt(u32, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--config")) {
            opts.config_path = it.next();
        }
    }
    return opts;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const opts = parseArgs(init.minimal.args);

    if (opts.config_path) |path| {
        zzdds.process_config.configureFromFile(std.heap.c_allocator, path) catch |err| {
            std.debug.print("FAIL: failed to load config file '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };
    }

    var factory = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    defer factory.deinit();

    var dp: DDS.DomainParticipant = undefined;
    if (opts.config_path == null) {
        var cfg: ZZDDS.DomainParticipantConfig = .{};
        cfg.participant.name = CONFIG_PARTICIPANT_NAME;
        cfg.rtps.fragment_size = CONFIG_FRAGMENT_SIZE;

        const zfactory = factory.toZZDDSFactory();
        if (zfactory.set_default_participant_config(cfg) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: set_default_participant_config() failed\n", .{});
            std.process.exit(1);
        }

        var readback: ZZDDS.DomainParticipantConfig = std.mem.zeroes(ZZDDS.DomainParticipantConfig);
        if (zfactory.get_default_participant_config(&readback) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: get_default_participant_config() failed\n", .{});
            std.process.exit(1);
        }
        defer readback.deinit(std.heap.c_allocator);

        if (!std.mem.eql(u8, readback.participant.name, CONFIG_PARTICIPANT_NAME)) {
            std.debug.print("FAIL: participant.name round-trip mismatch: expected '{s}', got '{s}'\n", .{ CONFIG_PARTICIPANT_NAME, readback.participant.name });
            std.process.exit(1);
        }
        if (readback.rtps.fragment_size != CONFIG_FRAGMENT_SIZE) {
            std.debug.print("FAIL: rtps.fragment_size round-trip mismatch: expected {d}, got {d}\n", .{ CONFIG_FRAGMENT_SIZE, readback.rtps.fragment_size });
            std.process.exit(1);
        }
        std.debug.print("Config round-trip OK: participant.name='{s}' rtps.fragment_size={d}\n", .{ readback.participant.name, readback.rtps.fragment_size });

        dp = zfactory.create_participant_ex(opts.domain_id, DDS.DomainParticipantQos{}, null, 0, cfg);
    } else {
        const dpf = factory.toDDSFactory();
        dp = dpf.create_participant(opts.domain_id, .{}, null, 0);
    }
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{opts.domain_id});
        std.process.exit(1);
    }
    defer _ = factory.toDDSFactory().delete_participant(dp);

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "ConfigPing", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = ping_gen.ConfigPing.computeKeyHashFromCdr,
    })) {
        std.debug.print("FAIL: registerTypeSupport() failed\n", .{});
        std.process.exit(1);
    }

    const topic = dp.create_topic("ConfigPing", "ConfigPing", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: ConfigPing\n", .{});

    const subscriber = dp.create_subscriber(.{}, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    var state = State{ .alloc = alloc };
    const dr_listener = DDS.dataReaderListener(&state, .{
        .on_data_available = onDataAvailable,
    });

    const topic_desc = dp.lookup_topicdescription("ConfigPing");
    const dr = subscriber.create_datareader(topic_desc, dr_qos, dr_listener, DDS.DATA_AVAILABLE_STATUS);
    if (dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: ConfigPing\n", .{});

    std.debug.print("Subscriber: waiting for {d} samples...\n", .{EXPECTED_SAMPLES});
    const deadline = monoNs(io) + RECEIVE_TIMEOUT_NS;
    while (!state.all_received.load(.acquire)) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: only received {d}/{d} samples within 30s\n", .{ state.expected_next, EXPECTED_SAMPLES });
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    _ = subscriber.delete_datareader(dr);

    std.debug.print("Subscriber: received all {d} samples in order.\n", .{EXPECTED_SAMPLES});
}
