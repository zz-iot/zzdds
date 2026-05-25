//! Zenzen DDS interop publisher — DATA_FRAG path.
//!
//! Same as zzdds_pub but uses fragment_size=512 and a ~2 KB payload so the
//! writer must split the sample into four DATA_FRAG submessages.  Verifies
//! that a Cyclone DDS reader can reassemble Zenzen DDS DATA_FRAG frames.
//!
//! Test scenario 3:  ./zzdds_interop_pub_frag  &  ./cyclone_sub
//! Expected result:  cyclone_sub receives the sample and exits 0.

const std = @import("std");
const zzdds = @import("zzdds");

const UdpTransport = zzdds.udp_transport.UdpTransport;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const nil = zzdds.dcps;

const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

/// Fragment size used by this publisher.  Must be smaller than MSG_LEN so the
/// writer produces at least two DATA_FRAG submessages.
const FRAG_SIZE: u16 = 512;

/// Length of the message string (excluding NUL).  Must be > FRAG_SIZE.
const MSG_LEN: usize = 2000;

/// CDR_LE payload for HelloWorldData::Msg { userID=1, message="Hello from Zenzen DDS (frag test) <pad…>" }.
/// Total size ≈ 2013 bytes → FRAG_SIZE=512 → 4 DATA_FRAG submessages.
const FRAG_PAYLOAD: [4 + 4 + 4 + MSG_LEN + 1]u8 = blk: {
    @setEvalBranchQuota(10_000);
    const prefix = "Hello from Zenzen DDS (frag test) ";
    const msg_len_u32: u32 = MSG_LEN + 1; // include NUL
    var buf: [4 + 4 + 4 + MSG_LEN + 1]u8 = undefined;
    // CDR_LE encapsulation header
    buf[0] = 0x00;
    buf[1] = 0x01;
    buf[2] = 0x00;
    buf[3] = 0x00;
    // userID = 1 (int32 LE)
    buf[4] = 0x01;
    buf[5] = 0x00;
    buf[6] = 0x00;
    buf[7] = 0x00;
    // message length (u32 LE)
    buf[8] = @intCast(msg_len_u32 & 0xFF);
    buf[9] = @intCast((msg_len_u32 >> 8) & 0xFF);
    buf[10] = 0x00;
    buf[11] = 0x00;
    // message: prefix then '.' padding
    var i: usize = 0;
    while (i < prefix.len) : (i += 1) buf[12 + i] = prefix[i];
    while (i < MSG_LEN) : (i += 1) buf[12 + i] = '.';
    buf[12 + MSG_LEN] = 0x00; // NUL terminator
    break :blk buf;
};

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Transport
    const udp = try UdpTransport.init(alloc, .{}, 0, null);
    defer udp.deinit();
    const transport = udp.transport();

    // Discovery
    const disc_impl = try SpdpSedpDiscovery.init(alloc, transport, 0, 3_000);
    // disc_impl deferred first so it runs AFTER factory.deinit() (LIFO order).
    defer disc_impl.deinit();
    const discovery = disc_impl.toDiscovery();

    // Security (noop)
    const security = zzdds.noop_security.noop_security_plugins;

    // Factory with low fragment_size so the writer uses DATA_FRAG.
    var factory = try DomainParticipantFactoryImpl.init(
        alloc,
        transport,
        discovery,
        security,
        .spec_random,
        .{ .rtps = .{ .fragment_size = FRAG_SIZE } },
    );
    defer factory.deinit();

    const dp_factory = factory.toDDSFactory();

    const DDS = @import("zzdds_generated").DDS;
    const dp = dp_factory.create_participant(0, .{}, nil.nil_dp_listener, 0);
    if (dp.ptr == nil.nil_dp_listener.ptr) {
        std.log.err("failed to create participant", .{});
        return error.ParticipantFailed;
    }

    const pub_ = dp.vtable.create_publisher(dp.ptr, .{}, nil.nil_pub_listener, 0);
    const topic = dp.vtable.create_topic(
        dp.ptr,
        "HelloWorldTopic",
        "HelloWorldData::Msg",
        .{},
        nil.nil_topic_listener,
        0,
    );

    var dw_qos = DDS.DataWriterQos{};
    dw_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dw = pub_.vtable.create_datawriter(pub_.ptr, topic, dw_qos, nil.nil_dw_listener, 0);
    if (dw.ptr == nil.nil_dw_listener.ptr) {
        std.log.err("failed to create data writer", .{});
        return error.WriterFailed;
    }

    std.log.info("[MILESTONE] PARTICIPANT: started on domain 0 (frag_size={})", .{FRAG_SIZE});

    // Wait up to 5 s for a matched reader.
    const dw_impl: *DataWriterImpl = @ptrCast(@alignCast(dw.ptr));
    var waited_ns: u64 = 0;
    while (waited_ns < 5 * std.time.ns_per_s) {
        if (dw_impl.matchedReaderCount() > 0) break;
        zzdds.util.time.sleepNs(50 * std.time.ns_per_ms);
        waited_ns += 50 * std.time.ns_per_ms;
    }
    if (dw_impl.matchedReaderCount() == 0) {
        std.log.err("[FAIL] SEDP: no matched reader found within 5 s", .{});
        return error.NoMatchedReader;
    }
    std.log.info("[MILESTONE] SEDP: matched {d} reader(s)", .{dw_impl.matchedReaderCount()});

    _ = try dw_impl.writeRaw(
        .alive,
        RtpsTimestamp.now(),
        history_mod.INSTANCE_HANDLE_NIL,
        std.mem.zeroes([16]u8),
        &FRAG_PAYLOAD,
    );
    std.log.info("[MILESTONE] DATA_FRAG: wrote {d}-byte sample in fragments of {d} bytes", .{ FRAG_PAYLOAD.len, FRAG_SIZE });

    // Keep alive for reliable delivery (Heartbeat_FRAG / AckNack_FRAG exchange).
    zzdds.util.time.sleepNs(3 * std.time.ns_per_s);
    std.log.info("[PASS] zzdds_pub_frag: complete", .{});

    _ = dp_factory.delete_participant(dp);
}
