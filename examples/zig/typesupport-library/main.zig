//! The host imports no application-generated modules. Descriptors and checked
//! wire operations come from the command-line libraries; sample production and
//! interpretation remain application code (fixed XCDR1 vectors in this demo).
const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;
const Ext = @import("zzdds_ext_generated").zzdds;
const ts = zzdds.typesupport;
const names = [_][:0]const u8{ "LoadedDemo::Reading", "LoadedDemo::Pulse" };
const topics = [_][:0]const u8{ "LoadedReadings", "LoadedPulses" };
// Match the demo vectors explicitly in both endpoint QoS and discovery.
var xcdr1 = [_]i16{0};
const representation = DDS.DataRepresentationQosPolicy{ .value = .{ ._maximum = 1, ._length = 1, ._buffer = &xcdr1, ._release = false } };
const samples = [_][]const u8{
    &.{ 0, 1, 0, 0, 1, 0, 0, 0, 101, 0, 0, 0 },
    &.{ 0, 1, 0, 0, 2, 0, 0, 0, 202, 0, 0, 0 },
    &.{ 0, 1, 0, 0, 7, 0, 0, 0 },
};
const Ready = struct {
    value: std.atomic.Value(bool) = .init(false),
    fn matched(_: *@This(), _: DDS.DataWriter, status: DDS.PublicationMatchedStatus) void {
        std.debug.print("Matched readers: {d}\n", .{status.current_count});
    }
    fn incompatible(_: *@This(), _: DDS.DataWriter, status: DDS.OfferedIncompatibleQosStatus) void {
        std.debug.print("Incompatible reader QoS policy: {d}\n", .{status.last_policy_id});
    }
    fn changed(self: *@This(), _: DDS.InstanceHandle_t, ready: bool) void {
        self.value.store(ready, .release);
    }
};
fn pause(io: std.Io) void {
    (std.Io.Clock.Duration{ .raw = .{ .nanoseconds = 20 * std.time.ns_per_ms }, .clock = .awake }).sleep(io) catch {};
}
fn now(io: std.Io) i128 {
    return std.Io.Clock.awake.now(io).nanoseconds;
}
fn require(entity: anytype) !@TypeOf(entity) {
    if (entity.ptr == zzdds.dcps.NIL_PTR) return error.EntityCreationFailed;
    return entity;
}
fn register(participant: DDS.DomainParticipant, libraries: *ts.Manager, provider: []const u8, name: []const u8) !ts.Registration {
    const selection = try libraries.select(provider, name);
    defer selection.deinit();
    return ts.register(participant, selection);
}
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.arena.allocator());
    defer args.deinit();
    _ = args.skip();
    const mode = args.next() orelse return error.ExpectedInspectPubOrSub;
    if (!std.mem.eql(u8, mode, "inspect") and !std.mem.eql(u8, mode, "pub") and !std.mem.eql(u8, mode, "sub")) return error.ExpectedInspectPubOrSub;
    const sensors = args.next() orelse return error.ExpectedSensorsLibraryPath;
    const control = args.next() orelse return error.ExpectedControlLibraryPath;
    const domain = if (args.next()) |s| try std.fmt.parseInt(u32, s, 10) else 187;
    if (domain > 232) return error.ExpectedUdpDomainZeroThrough232;
    if (args.next() != null) return error.UnexpectedArgument;
    var libraries = try ts.Manager.init(init.gpa, 4);
    defer libraries.deinit();
    try libraries.load("sensors", sensors);
    try libraries.load("control", control);
    for ([_][]const u8{ "sensors", "control" }) |provider| {
        const view = try libraries.acquire(provider);
        defer view.deinit();
        for (view.types()) |t| std.debug.print("export {s}: {s} keyed={}\n", .{ provider, t.name.data[0..@intCast(t.name.size)], t.keyed != 0 });
    }
    if (std.mem.eql(u8, mode, "inspect")) return;
    {
        const pulse_a = try libraries.select("sensors", names[1]);
        defer pulse_a.deinit();
        const pulse_b = try libraries.select("control", names[1]);
        defer pulse_b.deinit();
        if (!pulse_a.equivalent(pulse_b)) return error.ExpectedEquivalentExports;
        std.debug.print("Equivalent Pulse exports; explicitly selecting control\n", .{});
    }

    var owner = try zzdds.createFactory();
    defer owner.deinit();
    const factory = owner.toDDSFactory();
    const participant = try require(factory.create_participant(domain, .{}, null, 0));
    defer _ = factory.delete_participant(participant);
    const reading_registration = try register(participant, &libraries, "sensors", names[0]);
    defer reading_registration.deinit();
    const pulse_registration = try register(participant, &libraries, "control", names[1]);
    defer pulse_registration.deinit();
    const registrations = [_]ts.Registration{ reading_registration, pulse_registration };
    // Removing catalog mappings does not invalidate the installed providers.
    try libraries.remove("sensors");
    try libraries.remove("control");
    const publishing = std.mem.eql(u8, mode, "pub");
    var ready = [_]Ready{ .{}, .{} };
    var writers: [2]DDS.DataWriter = undefined;
    var readers: [2]DDS.DataReader = undefined;
    for (names, 0..) |name, i| {
        const topic = try require(participant.create_topic(topics[i], name, .{}, null, 0));
        if (publishing) {
            const publisher = try require(participant.create_publisher(.{}, null, 0));
            const extended = zzdds.asZzddsPublisher(publisher) orelse return error.MissingExtension;
            writers[i] = try require(extended.create_datawriter_ex(topic, .{
                .data_representation = representation,
                .reliability = .{ .kind = .RELIABLE_RELIABILITY_QOS },
                .history = .{ .kind = .KEEP_ALL_HISTORY_QOS },
            }, Ext.dataWriterListenerEx(&ready[i], .{ .on_reliable_reader_ready = Ready.changed, .on_publication_matched = Ready.matched, .on_offered_incompatible_qos = Ready.incompatible }), DDS.PUBLICATION_MATCHED_STATUS | DDS.OFFERED_INCOMPATIBLE_QOS_STATUS));
        } else {
            const subscriber = try require(participant.create_subscriber(.{}, null, 0));
            readers[i] = try require(subscriber.create_datareader(topic.as_TopicDescription(), .{
                .data_representation = representation,
                .reliability = .{ .kind = .RELIABLE_RELIABILITY_QOS },
                .history = .{ .kind = .KEEP_ALL_HISTORY_QOS },
            }, null, 0));
        }
    }
    const deadline = now(init.io) + 20 * std.time.ns_per_s;
    if (publishing) {
        while (!ready[0].value.load(.acquire) or !ready[1].value.load(.acquire)) {
            if (now(init.io) > deadline) return error.ReaderReadyTimeout;
            pause(init.io);
        }
        try registrations[0].write(writers[0], .alive, samples[0]);
        try registrations[0].write(writers[0], .alive, samples[1]);
        try registrations[1].write(writers[1], .alive, samples[2]);
        for (writers) |writer| {
            if (writer.wait_for_acknowledgments(.{ .sec = 10, .nanosec = 0 }) != DDS.RETCODE_OK) return error.AcknowledgmentTimeout;
        }
        std.debug.print("PASS published two keyed readings and one keyless pulse\n", .{});
    } else {
        var seen = [_]bool{ false, false, false };
        var handles: [2]DDS.InstanceHandle_t = undefined;
        while (!seen[0] or !seen[1] or !seen[2]) {
            for (readers, 0..) |reader, i| {
                while (zzdds.takeRaw(reader)) |sample| {
                    defer sample.deinit();
                    if (!sample.info.valid_data) continue;
                    const first: usize = if (i == 0) 0 else 2;
                    const end: usize = if (i == 0) 2 else 3;
                    var matched = false;
                    for (first..end) |index| {
                        if (std.mem.eql(u8, sample.data, samples[index])) {
                            seen[index] = true;
                            if (index < 2) handles[index] = sample.info.instance_handle;
                            matched = true;
                        }
                    }
                    if (!matched) return error.UnexpectedSample;
                }
            }
            if (now(init.io) > deadline) return error.ReceptionTimeout;
            pause(init.io);
        }
        if (handles[0] == handles[1]) return error.KeyedInstancesCollapsed;
        std.debug.print("PASS received two distinct keyed instances and one keyless pulse\n", .{});
    }
}
