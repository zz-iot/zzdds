//! zig/participant-config -- publisher.
//!
//! Two mutually exclusive modes, matching this example's two config paths:
//!
//!   Default (no --config): programmatic mode. Builds a
//!   `zzdds.ZZDDS.DomainParticipantConfig` value in-process, round-trips it
//!   through `set_default_participant_config`/`get_default_participant_config`
//!   (asserting the read-back value matches what was set), then creates the
//!   participant via `create_participant_ex` using that same config.
//!
//!   --config <path>: file mode. Loads `path` (a zzdds.toml-style file) via
//!   `zzdds.process_config.configureFromFile` before the factory is created,
//!   then creates the participant the plain way. Point this at
//!   `config/tcp-non-discovery.toml` (repo root) to see user-data traffic
//!   move to TCP while discovery stays on UDP.
//!
//! Both modes then run the same minimal reliable write loop (3 samples) as
//! zig/hello_world, to prove the configured participant actually works, not
//! just that it was constructed.
//!
//! Required stdout markers: "Create topic:", "Create writer for topic:",
//! "on_reliable_reader_ready", "Publisher: wrote count=", "Publisher: done."
//! Programmatic mode additionally prints "Config round-trip OK: ...". Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const ping_gen = @import("config_ping_gen");

const SAMPLE_COUNT: i32 = 3;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

// Distinctive values for the programmatic round-trip check -- one plain
// string field, one scalar field in an all-primitive nested struct, so a
// mismatch in either is unambiguous about which kind of field broke.
const CONFIG_PARTICIPANT_NAME = "participant-config-example";
const CONFIG_FRAGMENT_SIZE: u16 = 9000;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const State = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onReliableReaderReady(state: *State, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
    std.debug.print("on_reliable_reader_ready() is_ready={}\n", .{is_ready});
}

fn onPublicationMatched(state: *State, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
    std.debug.print("on_publication_matched() current_count={d}\n", .{status.current_count});
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

    // Must run before the first factory is created in this process -- see
    // zzdds's src/config/process.zig. Deliberately std.heap.c_allocator, not
    // `alloc` (this program's own DebugAllocator): the resolved config
    // becomes a process-wide singleton with no matching "destroy" call, by
    // design (matches zig/shape's own dds_impl.zig reasoning).
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
        // Programmatic mode: build a config value, round-trip it through
        // set_default_participant_config/get_default_participant_config,
        // then create the participant with it via create_participant_ex.
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

    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: ConfigPing\n", .{});

    var state = State{};
    const zdw = zzdds.asZzddsDataWriter(dw) orelse {
        std.debug.print("FAIL: asZzddsDataWriter() failed\n", .{});
        std.process.exit(1);
    };
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(&state, .{
        .on_publication_matched = onPublicationMatched,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_listener_ex failed\n", .{});
        std.process.exit(1);
    }

    const writer = ping_gen.ConfigPingDataWriter.init(dw, alloc);

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    var i: i32 = 0;
    while (i < SAMPLE_COUNT) : (i += 1) {
        writer.write(.{ .count = i }, 0) catch {
            std.debug.print("FAIL: write() failed at count={d}\n", .{i});
            std.process.exit(1);
        };
        std.debug.print("Publisher: wrote count={d}\n", .{i});
    }

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (!(state.ever_matched.load(.acquire) and state.matched_current_count.load(.acquire) == 0)) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Publisher: done.\n", .{});
}
