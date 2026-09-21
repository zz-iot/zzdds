//! zig/coherent-sets -- subscriber.
//!
//! One Subscriber (PRESENTATION access_scope=GROUP, coherent_access=true,
//! ordered_access=true), two DataReaders (Position, Velocity), one WaitSet
//! with a ReadCondition per reader. `on_data_on_readers` is NOT used here --
//! it has zero firing sites in zzdds today (see docs/roadmap.md) -- a
//! WaitSet is the proven, already-implemented mechanism (see the `waitset`
//! example).
//!
//! The core assertion: after every begin_access()/end_access() bracket, the
//! two parallel arrays of group_ids taken so far (`position_order`,
//! `velocity_order`) must be exactly the same length and pairwise equal --
//! see c/coherent-sets/src/subscriber.c's header comment for the full
//! rationale and docs/design/integration-test-tier.md for the scenario
//! spec.
//!
//! Required stdout markers: "Create topic:" x2, "Create reader for topic:"
//! x2, "Subscriber: group N paired (position+velocity).", "Subscriber:
//! received all 20 groups, atomic and ordered." Any failure path prints a
//! line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const pose_group_gen = @import("pose_group_gen");

const GROUP_COUNT: i32 = 20;
const WAIT_STEP: DDS.Duration_t = .{ .sec = 1, .nanosec = 0 };
const OVERALL_DEADLINE_NS: i64 = 30 * std.time.ns_per_s;

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn readAsCondition(rc: DDS.ReadCondition) DDS.Condition {
    return rc.vtable.as_Condition(rc.ptr);
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

    var sub_qos = DDS.SubscriberQos{};
    sub_qos.presentation = .{ .access_scope = .GROUP_PRESENTATION_QOS, .coherent_access = true, .ordered_access = true };

    const subscriber = dp.create_subscriber(sub_qos, null, 0);
    if (subscriber.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_subscriber() failed\n", .{});
        std.process.exit(1);
    }

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    const position_topic_desc = dp.lookup_topicdescription("Position");
    const position_dr = subscriber.create_datareader(position_topic_desc, dr_qos, null, 0);
    if (position_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(Position) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: Position\n", .{});

    const velocity_topic_desc = dp.lookup_topicdescription("Velocity");
    const velocity_dr = subscriber.create_datareader(velocity_topic_desc, dr_qos, null, 0);
    if (velocity_dr.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datareader(Velocity) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create reader for topic: Velocity\n", .{});

    var position_typed_dr = pose_group_gen.PositionDataReader.init(position_dr, alloc);
    var velocity_typed_dr = pose_group_gen.VelocityDataReader.init(velocity_dr, alloc);

    const ws = zzdds.createWaitSet(alloc) catch {
        std.debug.print("FAIL: createWaitSet() failed\n", .{});
        std.process.exit(1);
    };
    defer ws.deinit();

    const position_rc = position_dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    const velocity_rc = velocity_dr.create_readcondition(DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
    if (position_rc.ptr == zzdds.dcps.NIL_PTR or velocity_rc.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_readcondition() failed\n", .{});
        std.process.exit(1);
    }
    if (ws.attach_condition(readAsCondition(position_rc)) != DDS.RETCODE_OK or
        ws.attach_condition(readAsCondition(velocity_rc)) != DDS.RETCODE_OK)
    {
        std.debug.print("FAIL: attach_condition() failed\n", .{});
        std.process.exit(1);
    }

    var position_order: std.ArrayListUnmanaged(i32) = .empty;
    defer position_order.deinit(alloc);
    var velocity_order: std.ArrayListUnmanaged(i32) = .empty;
    defer velocity_order.deinit(alloc);

    const deadline = monoNs(io) + OVERALL_DEADLINE_NS;
    while (position_order.items.len < GROUP_COUNT or velocity_order.items.len < GROUP_COUNT) {
        if (monoNs(io) > deadline) {
            std.debug.print("FAIL: only received position={d} velocity={d}/{d} within 30s\n", .{ position_order.items.len, velocity_order.items.len, GROUP_COUNT });
            std.process.exit(1);
        }

        var active = DDS.ConditionSeq{};
        const wr = ws.wait(&active, WAIT_STEP);
        defer if (active._release) {
            if (active._buffer) |b| alloc.free(b[0..active._maximum]);
        };
        if (wr == DDS.RETCODE_TIMEOUT) continue;
        if (wr != DDS.RETCODE_OK) {
            std.debug.print("FAIL: WaitSet.wait() returned {d}\n", .{wr});
            std.process.exit(1);
        }

        if (subscriber.vtable.begin_access(subscriber.ptr) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: begin_access() failed\n", .{});
            std.process.exit(1);
        }

        var position_taken: std.ArrayListUnmanaged(pose_group_gen.PositionDataReader.SampledValue) = .empty;
        defer position_taken.deinit(alloc);
        _ = try position_typed_dr.take(&position_taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        for (position_taken.items) |sv| {
            try position_order.append(alloc, sv.value.group_id);
        }

        var velocity_taken: std.ArrayListUnmanaged(pose_group_gen.VelocityDataReader.SampledValue) = .empty;
        defer velocity_taken.deinit(alloc);
        _ = try velocity_typed_dr.take(&velocity_taken, -1, DDS.ANY_SAMPLE_STATE, DDS.ANY_VIEW_STATE, DDS.ANY_INSTANCE_STATE);
        for (velocity_taken.items) |sv| {
            try velocity_order.append(alloc, sv.value.group_id);
        }

        if (subscriber.vtable.end_access(subscriber.ptr) != DDS.RETCODE_OK) {
            std.debug.print("FAIL: end_access() failed\n", .{});
            std.process.exit(1);
        }

        // The core atomicity assertion -- see c/coherent-sets/src/subscriber.c's header comment.
        if (position_order.items.len != velocity_order.items.len) {
            std.debug.print(
                "FAIL: atomicity violated -- position and velocity readers diverged after an access bracket (position count={d} velocity count={d}) -- a group became visible on one reader without its pair\n",
                .{ position_order.items.len, velocity_order.items.len },
            );
            std.process.exit(1);
        }
        for (position_order.items, 0..) |g, i| {
            if (g != velocity_order.items[i]) {
                std.debug.print("FAIL: atomicity violated at index {d} -- position group_id={d} but velocity group_id={d}\n", .{ i, g, velocity_order.items[i] });
                std.process.exit(1);
            }
        }
        if (position_order.items.len > 0) {
            std.debug.print("Subscriber: group {d} paired (position+velocity).\n", .{position_order.items[position_order.items.len - 1]});
        }
    }

    var i: usize = 0;
    while (i < GROUP_COUNT) : (i += 1) {
        if (position_order.items[i] != i or velocity_order.items[i] != i) {
            std.debug.print("FAIL: ordered_access violated at index {d} -- expected group_id={d}, got position={d} velocity={d}\n", .{ i, i, position_order.items[i], velocity_order.items[i] });
            std.process.exit(1);
        }
    }

    std.debug.print("Subscriber: received all {d} groups, atomic and ordered.\n", .{GROUP_COUNT});

    _ = ws.detach_condition(readAsCondition(position_rc));
    _ = ws.detach_condition(readAsCondition(velocity_rc));
    _ = position_dr.delete_readcondition(position_rc);
    _ = velocity_dr.delete_readcondition(velocity_rc);
    _ = subscriber.delete_datareader(position_dr);
    _ = subscriber.delete_datareader(velocity_dr);
}
