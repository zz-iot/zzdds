//! Regression for the UAF found by stress-tests/zig/lifecycle_churn
//! (--scenario entities): a DataWriter torn down concurrently with a
//! discovery-driven on_publication_matched dispatch.
//!
//! `onReaderDiscovered` (participant.zig) releases `participant.mu` before
//! firing each matched writer's `matched_notify`. It holds the *proto*'s
//! quiesce across that window, but `matched_notify.ctx` is the
//! DataWriterImpl, whose lifetime nothing pins there. A concurrent
//! `delete_datawriter` frees the DataWriterImpl in the gap, and
//! `notifyPublicationMatched`'s first line -- `self.quiesce.acquire()` --
//! then reads freed memory (entity_quiesce.zig's own doc: it "can't
//! protect a `ctx` pointer that was already dangling before `acquire()`").
//!
//! Setup: a real UDP-loopback participant pair, one stable reader, and a
//! writer participant whose DataWriter is created/deleted in a tight loop
//! on a worker thread. Every `create_datawriter` prompts the reader's
//! already-announced SEDP data to be (re)matched against the new writer --
//! `onReaderDiscovered` fires on the writer participant's own receive
//! thread, racing the worker's `delete_datawriter`. Pre-fix this GPFs /
//! trips DebugAllocator within a few hundred iterations and is a genuine
//! data race under test-tsan.

const std = @import("std");
const zzdds = @import("zzdds");
const DDS = @import("zzdds_generated").DDS;

const UdpTransport = zzdds.udp_transport.UdpTransport;
const SpdpSedpDiscovery = zzdds.combined_discovery.SpdpSedpDiscovery;
const DomainParticipantFactoryImpl = zzdds.dcps.DomainParticipantFactoryImpl;
const TopicImpl = zzdds.dcps.TopicImpl;
const time_mod = zzdds.util.time;
const noop_security = zzdds.noop_security.noop_security_plugins;

const testing = std.testing;

fn topicDesc(t: DDS.Topic) DDS.TopicDescription {
    return (@as(*TopicImpl, @ptrCast(@alignCast(t.ptr)))).toTopicDescription();
}

const DOMAIN: u32 = 88;
const ITERS: u32 = 60;

const Churn = struct {
    pub_: DDS.Publisher,
    topic: DDS.Topic,

    fn run(self: Churn) void {
        var qos = DDS.DataWriterQos{};
        qos.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        var i: u32 = 0;
        while (i < ITERS) : (i += 1) {
            const dw = self.pub_.create_datawriter(self.topic, qos, null, 0);
            if (dw.ptr != zzdds.dcps.NIL_PTR) _ = self.pub_.delete_datawriter(dw);
        }
    }
};

test "lifecycle churn: delete_datawriter concurrent with discovery-driven on_publication_matched" {
    const alloc = testing.allocator;

    // stable reader participant
    const udp_r = try UdpTransport.init(alloc, .{ .participant_id = 40 }, DOMAIN, null);
    defer udp_r.deinit();
    const disc_r = try SpdpSedpDiscovery.init(alloc, udp_r.transport(), DOMAIN, 200);
    var factory_r = try DomainParticipantFactoryImpl.init(alloc, udp_r.transport(), disc_r.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_r.deinit();
        disc_r.deinit();
    }
    const dpf_r = factory_r.toDDSFactory();
    const dp_r = dpf_r.create_participant(DOMAIN, .{}, null, 0);
    defer _ = dpf_r.delete_participant(dp_r);
    const sub_r = dp_r.create_subscriber(.{}, null, 0);
    const topic_r = dp_r.create_topic("ChurnTopic", "ChurnType", .{}, null, 0);
    var rq = DDS.DataReaderQos{};
    rq.reliability.kind = .RELIABLE_RELIABILITY_QOS;
    _ = sub_r.create_datareader(topicDesc(topic_r), rq, null, 0);

    // writer participant
    const udp_w = try UdpTransport.init(alloc, .{ .participant_id = 41 }, DOMAIN, null);
    defer udp_w.deinit();
    const disc_w = try SpdpSedpDiscovery.init(alloc, udp_w.transport(), DOMAIN, 200);
    var factory_w = try DomainParticipantFactoryImpl.init(alloc, udp_w.transport(), disc_w.toDiscovery(), noop_security, .spec_random, .{});
    defer {
        factory_w.deinit();
        disc_w.deinit();
    }
    const dpf_w = factory_w.toDDSFactory();
    const dp_w = dpf_w.create_participant(DOMAIN, .{}, null, 0);
    defer _ = dpf_w.delete_participant(dp_w);
    const pub_w = dp_w.create_publisher(.{}, null, 0);
    const topic_w = dp_w.create_topic("ChurnTopic", "ChurnType", .{}, null, 0);

    // Best-effort: wait (bounded) for a first match so the churn loop runs
    // against live discovery, not a cold start. Not an assertion.
    {
        var wq = DDS.DataWriterQos{};
        wq.reliability.kind = .RELIABLE_RELIABILITY_QOS;
        const warm = pub_w.create_datawriter(topic_w, wq, null, 0);
        const deadline = time_mod.nanoTimestamp() + 5 * std.time.ns_per_s;
        var st: DDS.PublicationMatchedStatus = undefined;
        while (time_mod.nanoTimestamp() < deadline) {
            _ = warm.vtable.get_publication_matched_status(warm.ptr, &st);
            if (st.current_count >= 1) break;
            time_mod.sleepNs(10 * std.time.ns_per_ms);
        }
        _ = pub_w.delete_datawriter(warm);
    }

    const worker = try std.Thread.spawn(.{}, Churn.run, .{Churn{ .pub_ = pub_w, .topic = topic_w }});
    worker.join();
}
