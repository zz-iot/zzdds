//! zig/coherent-sets -- publisher.
//!
//! Publishes GROUP_COUNT ticks. Each tick is one coherent set spanning two
//! DataWriters under one Publisher (PRESENTATION access_scope=GROUP,
//! coherent_access=true, ordered_access=true): write Position, sleep
//! WRITE_GAP_NS, write Velocity, end the coherent set. See
//! docs/design/integration-test-tier.md for the full scenario spec.
//!
//! Required stdout markers: "Create topic:" x2, "Create writer for topic:"
//! x2, "Publisher: wrote group N", "Publisher: done." Any failure path
//! prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const zidl_rt = @import("zidl_rt");
const pose_group_gen = @import("pose_group_gen");

const GROUP_COUNT: i32 = 20;
const WRITE_GAP_NS: u64 = 8 * std.time.ns_per_ms;
const READER_READY_TIMEOUT_NS: i64 = 10 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

const WriterSyncState = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn onReliableReaderReady(state: *WriterSyncState, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
}

fn onPublicationMatched(state: *WriterSyncState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
}

fn parseDomain(process_args: std.process.Args) u32 {
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--domain")) {
            const v = it.next() orelse continue;
            return std.fmt.parseInt(u32, v, 10) catch 0;
        }
    }
    return 0;
}

fn setWriterListener(dw: DDS.DataWriter, state: *WriterSyncState) !void {
    const zdw = zzdds.asZzddsDataWriter(dw) orelse return error.AsZzddsDataWriterFailed;
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(state, .{
        .on_publication_matched = onPublicationMatched,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) return error.SetListenerExFailed;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const domain_id = parseDomain(init.minimal.args);

    var factory = zzdds.createFactory() catch {
        std.debug.print("FAIL: createFactory() failed\n", .{});
        std.process.exit(1);
    };
    defer factory.deinit();
    const dpf = factory.toDDSFactory();

    const dp = dpf.create_participant(domain_id, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{domain_id});
        std.process.exit(1);
    }
    defer _ = dpf.delete_participant(dp);

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "Position", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = pose_group_gen.Position.computeKeyHashFromCdr,
        .compute_key_hash_key_only = pose_group_gen.Position.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport(Position) failed\n", .{});
        std.process.exit(1);
    }
    if (!zzdds.registerTypeSupport(dp, "Velocity", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = pose_group_gen.Velocity.computeKeyHashFromCdr,
        .compute_key_hash_key_only = pose_group_gen.Velocity.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport(Velocity) failed\n", .{});
        std.process.exit(1);
    }

    const position_topic = dp.create_topic("Position", "Position", .{}, null, 0);
    if (position_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(Position) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: Position\n", .{});

    const velocity_topic = dp.create_topic("Velocity", "Velocity", .{}, null, 0);
    if (velocity_topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(Velocity) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: Velocity\n", .{});

    var pub_qos = DDS.PublisherQos{};
    pub_qos.presentation = .{ .access_scope = .GROUP_PRESENTATION_QOS, .coherent_access = true, .ordered_access = true };

    const publisher = dp.create_publisher(pub_qos, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const position_dw = publisher.create_datawriter(position_topic, dw_qos, null, 0);
    if (position_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(Position) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: Position\n", .{});

    const velocity_dw = publisher.create_datawriter(velocity_topic, dw_qos, null, 0);
    if (velocity_dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter(Velocity) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: Velocity\n", .{});

    var position_state = WriterSyncState{};
    var velocity_state = WriterSyncState{};
    setWriterListener(position_dw, &position_state) catch {
        std.debug.print("FAIL: set_listener_ex(Position) failed\n", .{});
        std.process.exit(1);
    };
    setWriterListener(velocity_dw, &velocity_state) catch {
        std.debug.print("FAIL: set_listener_ex(Velocity) failed\n", .{});
        std.process.exit(1);
    };

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!(position_state.reader_ready.load(.acquire) and velocity_state.reader_ready.load(.acquire))) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 10s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    const position_writer = pose_group_gen.PositionDataWriter.init(position_dw, alloc);
    const velocity_writer = pose_group_gen.VelocityDataWriter.init(velocity_dw, alloc);

    var group_id: i32 = 0;
    while (group_id < GROUP_COUNT) : (group_id += 1) {
        if (publisher.vtable.begin_coherent_changes(publisher.ptr) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: begin_coherent_changes() failed at group={d}\n", .{group_id});
            std.process.exit(1);
        }

        position_writer.write(.{
            .group_id = group_id,
            .x = @floatFromInt(group_id),
            .y = @as(f64, @floatFromInt(group_id)) * 2.0,
        }, 0) catch {
            std.debug.print("FAIL: Position write() failed at group={d}\n", .{group_id});
            std.process.exit(1);
        };

        // Deliberate gap -- see c/coherent-sets/src/publisher.c's matching comment.
        sleepNs(io, WRITE_GAP_NS);

        velocity_writer.write(.{
            .group_id = group_id,
            .vx = @as(f64, @floatFromInt(group_id)) * 0.5,
            .vy = @as(f64, @floatFromInt(group_id)) * 1.5,
        }, 0) catch {
            std.debug.print("FAIL: Velocity write() failed at group={d}\n", .{group_id});
            std.process.exit(1);
        };

        if (publisher.vtable.end_coherent_changes(publisher.ptr) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: end_coherent_changes() failed at group={d}\n", .{group_id});
            std.process.exit(1);
        }
        std.debug.print("Publisher: wrote group {d}\n", .{group_id});
    }

    std.debug.print("Publisher: done.\n", .{});

    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (!(position_state.ever_matched.load(.acquire) and position_state.matched_current_count.load(.acquire) == 0 and
        velocity_state.ever_matched.load(.acquire) and velocity_state.matched_current_count.load(.acquire) == 0))
    {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    if (publisher.delete_datawriter(position_dw) != DDS.RETCODE_OK or
        publisher.delete_datawriter(velocity_dw) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: delete_datawriter() did not return RETCODE_OK\n", .{});
        std.process.exit(1);
    }
}
