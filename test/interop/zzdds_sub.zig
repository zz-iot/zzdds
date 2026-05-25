//! Zenzen DDS interop subscriber.
//!
//! Starts a DomainParticipant on domain 0, announces a DataReader for
//! HelloWorldData::Msg on "HelloWorldTopic", polls for up to 10 s for a
//! sample, then prints it and exits 0 (or exits 1 on timeout).
//!
//! Test scenario 2:  ./cyclone_pub  &  ./zzdds_interop_sub
//! Expected result:  zzdds_interop_sub receives the sample and exits 0.

const std = @import("std");
const zzdds = @import("zzdds");

const UdpTransport = zzdds.udp_transport.UdpTransport;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const DataReaderImpl = zzdds.dcps.DataReaderImpl;
const nil = zzdds.dcps;

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

    // Subscriber → Topic → DataReader
    const sub = dp.vtable.create_subscriber(dp.ptr, .{}, nil.nil_sub_listener, 0);
    const topic = dp.vtable.create_topic(
        dp.ptr,
        "HelloWorldTopic",
        "HelloWorldData::Msg",
        .{},
        nil.nil_topic_listener,
        0,
    );
    const TopicImpl = zzdds.dcps.TopicImpl;
    const topic_desc = @as(*TopicImpl, @ptrCast(@alignCast(topic.ptr))).toTopicDescription();

    var dr_qos = DDS.DataReaderQos{};
    dr_qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    const dr = sub.vtable.create_datareader(sub.ptr, topic_desc, dr_qos, nil.nil_dr_listener, 0);
    if (dr.ptr == nil.nil_dr_listener.ptr) {
        std.log.err("failed to create data reader", .{});
        return error.ReaderFailed;
    }

    std.log.info("[MILESTONE] PARTICIPANT: started on domain 0", .{});
    std.log.info("[MILESTONE] DR: waiting for sample (up to 10 s)...", .{});

    const dr_impl: *DataReaderImpl = @ptrCast(@alignCast(dr.ptr));
    var last_matched: usize = 0;
    const deadline_ns = zzdds.util.time.nanoTimestamp() + 10 * std.time.ns_per_s;

    while (zzdds.util.time.nanoTimestamp() < deadline_ns) {
        // Log the first time a writer is matched (SEDP milestone).
        const now_matched = dr_impl.matchedWriterCount();
        if (now_matched > last_matched) {
            std.log.info("[MILESTONE] SEDP: matched {d} writer(s)", .{now_matched});
            last_matched = now_matched;
        }

        if (dr_impl.takeRaw()) |sample| {
            defer alloc.free(sample.data);
            if (parsePrint(sample.data)) {
                std.log.info("[PASS] zzdds_sub: complete", .{});
                _ = dp_factory.delete_participant(dp);
                std.process.exit(0);
            }
            // Key-only or malformed sample — keep waiting for the actual data.
            continue;
        }
        zzdds.util.time.sleepNs(50 * std.time.ns_per_ms);
    }

    std.log.err("[FAIL] zzdds_sub: timeout — no sample received in 10 s", .{});
    _ = dp_factory.delete_participant(dp);
    std.process.exit(1);
}

/// Decode and print a CDR_LE HelloWorldData::Msg payload.
/// Handles both XCDR1 (encap byte[1]=0x01) and XCDR2 APPENDABLE (byte[1]=0x09),
/// which adds a 4-byte DHEADER before the struct body.
/// Returns true if a complete sample was decoded and printed; false for key-only
/// or malformed payloads (caller should keep waiting).
fn parsePrint(payload: []const u8) bool {
    if (payload.len < 4) {
        std.log.warn("payload too short ({} bytes)", .{payload.len});
        return false;
    }
    // Encap byte[1]: 0x01=CDR_LE(XCDR1), 0x07=PLAIN_CDR2_LE(XCDR2 FINAL),
    //                0x09=DELIMITED_CDR2_LE(XCDR2 APPENDABLE, has 4-byte DHEADER)
    var offset: usize = 4;
    const encap_id = payload[1];
    if (encap_id == 0x08 or encap_id == 0x09) {
        // XCDR2 APPENDABLE: skip the 4-byte struct DHEADER.
        if (payload.len < offset + 4) {
            std.log.warn("payload too short for DHEADER ({} bytes)", .{payload.len});
            return false;
        }
        offset += 4;
    }
    if (payload.len < offset + 8) {
        // Key-only payload (e.g. OpenDDS instance registration) — not a full sample.
        return false;
    }
    const userID = std.mem.readInt(i32, payload[offset..][0..4], .little);
    const msg_len = std.mem.readInt(u32, payload[offset + 4 ..][0..4], .little);
    offset += 8;
    if (payload.len < offset + msg_len) {
        std.log.warn("payload truncated (have {} need {})", .{ payload.len, offset + msg_len });
        return false;
    }
    const msg_end = if (msg_len > 0) offset + msg_len - 1 else offset;
    const msg = payload[offset..msg_end];
    std.log.info("zzdds_sub: received userID={d} message=\"{s}\"", .{ userID, msg });
    return true;
}
