// java/presence -- publisher. Direct Java port of zig/presence/publisher.zig
// / c/presence/src/publisher.c / cpp/presence/src/publisher.cpp; see
// docs/design/presence-reference-app.md at the repo root for the full spec.
// Demonstrates MANUAL_BY_TOPIC_LIVELINESS_QOS: writes for a while,
// deliberately goes quiet (no writes, no asserts) for longer than its own
// lease_duration, then calls DataWriter.assert_liveliness() explicitly
// before resuming.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// writer for topic:", "Publisher: wrote sequence=", "Publisher: going
// offline", "Publisher: asserting liveliness and resuming", "Publisher:
// done." Any failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int ONLINE_BEACON_COUNT = 8;
    static final int BEACON_PERIOD_MS = 500;
    static final int LEASE_DURATION_S = 2;
    static final int OFFLINE_DURATION_MS = 5000; // > LEASE_DURATION_S
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    public static void main(String[] args) throws Exception {
        int domainId = parseDomain(args);

        Dcps.DDS.DomainParticipantFactory factory =
            (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (factory == null) {
            System.err.println("FAIL: createFactory() failed");
            System.exit(1);
        }

        Dcps.DDS.DomainParticipant dp = factory.create_participant(domainId, null, null, 0);
        if (dp == null) {
            System.err.println("FAIL: create_participant() failed on domain " + domainId);
            System.exit(1);
        }

        if (PresenceBeaconTypeSupport.register(dp, "PresenceBeacon") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("PresenceBeacon", "PresenceBeacon", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: PresenceBeacon");

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
        dwQos.get_history().set_depth(1);
        dwQos.get_liveliness().set_kind(Dcps.DDS.LivelinessQosPolicyKind.MANUAL_BY_TOPIC_LIVELINESS_QOS);
        dwQos.get_liveliness().get_lease_duration().set_sec(LEASE_DURATION_S);
        dwQos.get_liveliness().get_lease_duration().set_nanosec(0);

        Dcps.DDS.DataWriter rawWriter = pub.create_datawriter(topic, dwQos, null, 0);
        if (rawWriter == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: PresenceBeacon");

        final AtomicBoolean readerReady = new AtomicBoolean(false);
        final AtomicBoolean everMatched = new AtomicBoolean(false);
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);

        Zzdds.zzdds.DataWriter zdWriter =
            (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(rawWriter);
        if (zdWriter == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }

        Zzdds.zzdds.DataWriterListenerEx writerListener = new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) everMatched.set(true);
                System.out.println("on_publication_matched() current_count=" + s.get_current_count());
            }

            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) readerReady.set(true);
                System.out.println("on_reliable_reader_ready() is_ready=" + isReady);
            }
        };
        if (zdWriter.set_listener_ex(writerListener, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener_ex failed");
            System.exit(1);
        }

        PresenceBeaconDataWriter writer = new PresenceBeaconDataWriter(rawWriter);

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // -- Online phase --
        int seq = 0;
        for (; seq < ONLINE_BEACON_COUNT; seq++) {
            Presence_sample.PresenceBeacon sample = new Presence_sample.PresenceBeacon();
            sample.set_seq_num(seq);
            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at sequence=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote sequence=" + seq);
            Thread.sleep(BEACON_PERIOD_MS);
        }

        // -- Offline phase: no writes, no asserts, longer than the lease --
        System.out.println("Publisher: going offline (no writes/asserts for " + (OFFLINE_DURATION_MS / 1000) + "s, lease is " + LEASE_DURATION_S + "s)");
        Thread.sleep(OFFLINE_DURATION_MS);

        // -- Recovery --
        System.out.println("Publisher: asserting liveliness and resuming");
        if (rawWriter.assert_liveliness() != 0) {
            System.err.println("FAIL: assert_liveliness() failed");
            System.exit(1);
        }

        for (; seq < ONLINE_BEACON_COUNT * 2; seq++) {
            Presence_sample.PresenceBeacon sample = new Presence_sample.PresenceBeacon();
            sample.set_seq_num(seq);
            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at sequence=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote sequence=" + seq);
            Thread.sleep(BEACON_PERIOD_MS);
        }

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (!(everMatched.get() && matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Publisher: done.");
    }
}
