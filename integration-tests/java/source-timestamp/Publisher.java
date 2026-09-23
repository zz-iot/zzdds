// integration-tests/java/source-timestamp -- publisher. Direct Java port of
// c/source-timestamp/src/publisher.c -- see that file's header comment for
// the full scenario rationale and docs/design/integration-test-tier.md for
// the scenario spec.
//
// Required stdout markers: "Create topic:", "Create writer for topic:",
// "Publisher: wrote seq=... with explicit timestamp", "Publisher: disposed
// instance with explicit timestamp", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int SAMPLE_COUNT = 5;
    static final int WRITE_BASE_SEC = 1000000;
    static final int DISPOSE_SEC = 2000000;
    static final int DISPOSE_NSEC = 123456789;
    static final int MATCH_TIMEOUT_MS = 20000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static class PubState {
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);
    }

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

        if (TimestampEventTypeSupport.register(dp, "TimestampEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("TimestampEvent", "TimestampEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: TimestampEvent");
        System.out.flush();

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, null, 0);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: TimestampEvent");
        System.out.flush();

        PubState state = new PubState();
        Dcps.DDS.DataWriterListener listener = new Dcps.DDS.DataWriterListener() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
            }
        };
        if (dw.set_listener(listener, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener failed");
            System.exit(1);
        }

        TimestampEventDataWriter writer = new TimestampEventDataWriter(dw);

        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (state.matchedCurrentCount.get() < 1) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reader matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        Timestamp_event.TimestampEvent key = new Timestamp_event.TimestampEvent();
        key.set_id(0);
        key.set_seq(0);

        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Timestamp_event.TimestampEvent ev = new Timestamp_event.TimestampEvent();
            ev.set_id(0);
            ev.set_seq(seq);
            if (writer.write_w_timestamp(ev, 0L, WRITE_BASE_SEC + seq, 0) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write_w_timestamp() failed at seq=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote seq=" + seq + " with explicit timestamp sec=" + (WRITE_BASE_SEC + seq));
            System.out.flush();
        }

        if (writer.dispose_w_timestamp(key, 0L, DISPOSE_SEC, DISPOSE_NSEC) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: dispose_w_timestamp() failed");
            System.exit(1);
        }
        System.out.println("Publisher: disposed instance with explicit timestamp sec=" + DISPOSE_SEC + " nanosec=" + DISPOSE_NSEC);
        System.out.flush();

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (state.matchedCurrentCount.get() != 0) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Publisher: done.");
        System.out.flush();
        factory.delete_participant(dp);
    }
}
