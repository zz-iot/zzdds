//! Zenzen DDS interop publisher.
//!
//! Starts a DomainParticipant on domain 0, announces a RELIABLE DataWriter for
//! HelloWorldData::Msg on topic "HelloWorldTopic", writes one sample immediately,
//! then waits for delivery before exiting.
//!
//! Test scenario 1:  ./zzdds_interop_pub  &  ./cyclone_sub
//! Expected result:  cyclone_sub receives "Hello from Zenzen DDS" and exits 0.

const std = @import("std");
const zzdds = @import("zzdds");

const UdpTransport = zzdds.udp_transport.UdpTransport;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataWriterImpl = zzdds.dcps.DataWriterImpl;
const nil = zzdds.dcps;

const RtpsTimestamp = zzdds.util.time.RtpsTimestamp;
const history_mod = zzdds.rtps.history;

/// CDR_LE payload for HelloWorldData::Msg { userID = 1, message = "Hello from Zenzen DDS" }
const HELLO_PAYLOAD = blk: {
    const msg = "Hello from Zenzen DDS";
    const msg_len: u32 = msg.len + 1; // include NUL terminator
    var buf: [4 + 4 + 4 + msg_len]u8 = undefined;
    // Encapsulation header: CDR_LE
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
    buf[8] = @intCast(msg_len & 0xFF);
    buf[9] = @intCast((msg_len >> 8) & 0xFF);
    buf[10] = 0x00;
    buf[11] = 0x00;
    // message bytes
    var i: usize = 0;
    while (i < msg.len) : (i += 1) buf[12 + i] = msg[i];
    buf[12 + msg.len] = 0x00; // NUL
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
    // factory.deinit() calls participant.deinit() → discovery.stop() which joins
    // the recv thread; only then is it safe to free the SEDP StatefulReaders.
    defer disc_impl.deinit();
    const discovery = disc_impl.toDiscovery();

    // Security (noop)
    const security = zzdds.noop_security.noop_security_plugins;

    // Factory → Participant
    var factory = try DomainParticipantFactoryImpl.init(
        alloc,
        transport,
        discovery,
        security,
        .spec_random,
        .{},
    );
    defer factory.deinit();

    const dp_factory = factory.toDDSFactory();

    const DDS = @import("zzdds_generated").DDS;
    const dp = dp_factory.create_participant(0, .{}, nil.nil_dp_listener, 0);
    if (dp.ptr == nil.nil_dp_listener.ptr) {
        std.log.err("failed to create participant", .{});
        return error.ParticipantFailed;
    }

    // Publisher → Topic → DataWriter
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

    std.log.info("[MILESTONE] PARTICIPANT: started on domain 0", .{});

    // Wait up to 5 s for SPDP/SEDP discovery to match at least one reader.
    // Writing only after a reader is matched uses the direct send path rather
    // than the reliable replay path, which avoids a race where user DATA arrives
    // at the remote before its SEDP publication announcement is processed.
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
        &HELLO_PAYLOAD,
    );
    std.log.info("[MILESTONE] DATA: wrote sample (userID=1, message=\"Hello from Zenzen DDS\")", .{});

    // Keep alive briefly for reliable delivery (Heartbeat/AckNack exchange).
    zzdds.util.time.sleepNs(2 * std.time.ns_per_s);
    std.log.info("[PASS] zzdds_pub: complete", .{});

    // Cleanup: delete participant through the factory
    _ = dp_factory.delete_participant(dp);
}
