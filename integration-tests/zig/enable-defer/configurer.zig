//! zig/enable-defer -- configurer. The entity under test: builds a Publisher
//! and DataWriter tree with ENTITY_FACTORY QoS (`autoenable_created_entities
//! = false`) set on the participant and on the Publisher, so both the
//! Publisher and its DataWriter come in disabled -- a "configuration phase"
//! where the app finishes wiring QoS/listeners before going live, and a
//! half-configured entity is never visible to peers in the meantime. See
//! docs/design/integration-test-tier.md for the full scenario spec.
//!
//! Core assertions: a write() on the still-disabled writer returns an error
//! (NOT_ENABLED at the C-ABI/vtable layer; the native-Zig path was found
//! during this scenario's own construction to bypass that guard entirely --
//! see src/dcps/writer.zig's writeRaw fix); enabling the writer before its
//! own Publisher returns PRECONDITION_NOT_MET; enabling the Publisher then
//! the writer succeeds and triggers the previously-deferred SEDP
//! announcement, after which normal matching and data exchange proceed.
//!
//! Required stdout markers: "Create topic: ConfigTopic", "Create writer for
//! topic: ConfigTopic", "Configurer: write on disabled writer correctly
//! returned an error.", "Configurer: enabling writer before publisher
//! correctly returned PRECONDITION_NOT_MET.", "Configurer: done." Any
//! failure path prints a line starting "FAIL:" and exits nonzero.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const ZZDDS = @import("zzdds_ext_generated").zzdds;
const config_event_gen = @import("config_event_gen");

const SAMPLE_COUNT: i32 = 5;
const PRE_ENABLE_DELAY_NS: u64 = 4 * std.time.ns_per_s;
const READER_READY_TIMEOUT_NS: i64 = 20 * std.time.ns_per_s;
const DRAIN_TIMEOUT_NS: i64 = 15 * std.time.ns_per_s;
const POLL_PERIOD_NS: u64 = 20 * std.time.ns_per_ms;

const WriterSyncState = struct {
    reader_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    matched_current_count: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    ever_matched: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn monoNs(io: std.Io) i64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn sleepNs(io: std.Io, ns: u64) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = @intCast(ns) }, .clock = .awake }).sleep(io) catch {};
}

fn onPublicationMatchedEx(state: *WriterSyncState, dw: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
    _ = dw;
    state.matched_current_count.store(status.current_count, .release);
    if (status.current_count > 0) state.ever_matched.store(true, .release);
}

fn onReliableReaderReady(state: *WriterSyncState, reader_handle: DDS.InstanceHandle_t, is_ready: bool) void {
    _ = reader_handle;
    if (is_ready) state.reader_ready.store(true, .release);
}

fn setWriterListenerEx(dw: DDS.DataWriter, state: *WriterSyncState) !void {
    const zdw = zzdds.asZzddsDataWriter(dw) orelse return error.AsZzddsDataWriterFailed;
    if (zdw.set_listener_ex(ZZDDS.dataWriterListenerEx(state, .{
        .on_publication_matched = onPublicationMatchedEx,
        .on_reliable_reader_ready = onReliableReaderReady,
    }), DDS.PUBLICATION_MATCHED_STATUS) != DDS.RETCODE_OK) return error.SetListenerExFailed;
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

    // Participant created normally (enabled) -- only ITS CHILDREN start
    // disabled, per ENTITY_FACTORY QoS semantics.
    const dp = dpf.create_participant(domain_id, .{}, null, 0);
    if (dp.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_participant() failed on domain {d}\n", .{domain_id});
        std.process.exit(1);
    }
    defer _ = dpf.delete_participant(dp);

    // Get-mutate-set, not a from-scratch QoS literal -- avoids clobbering any
    // other participant QoS field (see examples/c/shape's shape_main.c fix
    // in Phase A's history for why a zeroed/from-scratch QoS struct is risky
    // now that entity_factory genuinely defaults true).
    var dp_qos: DDS.DomainParticipantQos = undefined;
    if (dp.vtable.get_qos(dp.ptr, &dp_qos) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: get_qos(participant) failed\n", .{});
        std.process.exit(1);
    }
    dp_qos.entity_factory.autoenable_created_entities = false;
    if (dp.vtable.set_qos(dp.ptr, &dp_qos) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_qos(participant, autoenable=false) failed\n", .{});
        std.process.exit(1);
    }

    var ts_alloc = alloc;
    if (!zzdds.registerTypeSupport(dp, "ConfigEvent", .{
        .ctx = @ptrCast(&ts_alloc),
        .compute_key_hash = config_event_gen.ConfigEvent.computeKeyHashFromCdr,
        .compute_key_hash_key_only = config_event_gen.ConfigEvent.computeKeyHashFromCdrKeyOnly,
    })) {
        std.debug.print("FAIL: registerTypeSupport(ConfigEvent) failed\n", .{});
        std.process.exit(1);
    }

    // Topics have no wire footprint of their own (confirmed against Phase
    // A's topic.zig changes) -- creating one here is unaffected either way.
    const topic = dp.create_topic("ConfigTopic", "ConfigEvent", .{}, null, 0);
    if (topic.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_topic(ConfigTopic) failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create topic: ConfigTopic\n", .{});

    // Publisher comes in disabled (participant's entity_factory QoS above).
    const publisher = dp.create_publisher(.{}, null, 0);
    if (publisher.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_publisher() failed\n", .{});
        std.process.exit(1);
    }

    var pub_qos: DDS.PublisherQos = undefined;
    if (publisher.vtable.get_qos(publisher.ptr, &pub_qos) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: get_qos(publisher) failed\n", .{});
        std.process.exit(1);
    }
    pub_qos.entity_factory.autoenable_created_entities = false;
    if (publisher.vtable.set_qos(publisher.ptr, &pub_qos) != DDS.RETCODE_OK) {
        std.debug.print("FAIL: set_qos(publisher, autoenable=false) failed\n", .{});
        std.process.exit(1);
    }

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = .KEEP_ALL_HISTORY_QOS;

    // DataWriter comes in disabled (publisher's entity_factory QoS above).
    const dw = publisher.create_datawriter(topic, dw_qos, null, 0);
    if (dw.ptr == zzdds.dcps.NIL_PTR) {
        std.debug.print("FAIL: create_datawriter() failed\n", .{});
        std.process.exit(1);
    }
    std.debug.print("Create writer for topic: ConfigTopic\n", .{});

    var writer_state = WriterSyncState{};
    setWriterListenerEx(dw, &writer_state) catch {
        std.debug.print("FAIL: set_listener_ex(ConfigTopic writer) failed\n", .{});
        std.process.exit(1);
    };

    const writer = config_event_gen.ConfigEventDataWriter.init(dw, alloc);

    // Core assertion #1: write() on a still-disabled writer must fail, not
    // silently succeed. (This is the native-Zig path -- see writer.zig's
    // writeRaw fix in this same change; before it, this call would have
    // wrongly succeeded even though `dw` is disabled.)
    if (writer.write(.{ .seq = -1 }, 0)) |_| {
        std.debug.print("FAIL: write() on disabled writer succeeded, expected an error\n", .{});
        std.process.exit(1);
    } else |_| {}
    std.debug.print("Configurer: write on disabled writer correctly returned an error.\n", .{});

    // Deliberate wall-clock window -- not a race-avoidance hack. This just
    // gives the peer process a comfortable, unambiguous stretch of real time
    // to independently confirm zero premature matching before anything here
    // is enabled; the peer controls its own assertion window on its own
    // clock, this delay only makes sure there's real room for it.
    sleepNs(io, PRE_ENABLE_DELAY_NS);

    // Core assertion #2: enabling the writer before its own Publisher must
    // fail with PRECONDITION_NOT_MET (spec: can't enable a child before its
    // factory entity).
    {
        const rc = dw.vtable.enable(dw.ptr);
        if (rc != DDS.RETCODE_PRECONDITION_NOT_MET) {
            std.debug.print("FAIL: writer.enable() before publisher.enable() returned {d}, expected RETCODE_PRECONDITION_NOT_MET ({d})\n", .{ rc, DDS.RETCODE_PRECONDITION_NOT_MET });
            std.process.exit(1);
        }
    }
    std.debug.print("Configurer: enabling writer before publisher correctly returned PRECONDITION_NOT_MET.\n", .{});

    {
        const rc = publisher.vtable.enable(publisher.ptr);
        if (rc != DDS.RETCODE_OK) {
            std.debug.print("FAIL: publisher.enable() returned {d}, expected RETCODE_OK\n", .{rc});
            std.process.exit(1);
        }
    }
    {
        const rc = dw.vtable.enable(dw.ptr);
        if (rc != DDS.RETCODE_OK) {
            std.debug.print("FAIL: writer.enable() returned {d} after publisher.enable(), expected RETCODE_OK\n", .{rc});
            std.process.exit(1);
        }
    }
    std.debug.print("Configurer: enabled publisher then writer.\n", .{});

    const ready_deadline = monoNs(io) + READER_READY_TIMEOUT_NS;
    while (!writer_state.reader_ready.load(.acquire)) {
        if (monoNs(io) > ready_deadline) {
            std.debug.print("FAIL: no reliable reader became ready within 20s of enabling\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    var seq: i32 = 0;
    while (seq < SAMPLE_COUNT) : (seq += 1) {
        writer.write(.{ .seq = seq }, 0) catch {
            std.debug.print("FAIL: write() failed at seq={d} after enabling\n", .{seq});
            std.process.exit(1);
        };
    }
    std.debug.print("Configurer: wrote {d} samples after enabling.\n", .{SAMPLE_COUNT});

    // Standard teardown-safety: wait for the peer to unmatch/drain before
    // deleting, matching raw-loan's precedent.
    const drain_deadline = monoNs(io) + DRAIN_TIMEOUT_NS;
    while (writer_state.matched_current_count.load(.acquire) != 0 or !writer_state.ever_matched.load(.acquire)) {
        if (monoNs(io) > drain_deadline) {
            std.debug.print("FAIL: subscriber did not disconnect within 15s\n", .{});
            std.process.exit(1);
        }
        sleepNs(io, POLL_PERIOD_NS);
    }

    std.debug.print("Configurer: done.\n", .{});
}
