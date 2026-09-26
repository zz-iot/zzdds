// integration-tests/java/liveliness-lost -- publisher. Direct Java port of
// c/liveliness-lost/src/publisher.c -- see that file's header comment for
// the full scenario rationale and docs/design/integration-test-tier.md for
// the scenario spec.
//
// Required stdout markers: "Create topic:" x2, "Create writer for topic:"
// x2, "Publisher: both readers matched.", "Publisher: write loop done.",
// "Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as
// expected.", "Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness
// (total_count=N) despite continuous writing, as expected.", "Publisher:
// done." Any failure path prints a line starting "FAIL:" and exits
// nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int LEASE_DURATION_SEC = 2;
    static final int WRITE_PERIOD_MS = 500;
    static final int WRITE_COUNT = 16; // 16 * 500ms = 8s, comfortably > 4 lease periods
    // 40s, not the 20s every other match-wait in this tier uses -- see
    // c/liveliness-lost/src/publisher.c's matching comment.
    static final int MATCH_TIMEOUT_MS = 40000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static class WriterState {
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);
        final AtomicInteger livelinessLostCount = new AtomicInteger(0);
    }

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    static Dcps.DDS.DataWriterListener makeListener(WriterState state) {
        return new Dcps.DDS.DataWriterListener() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}

            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {
                state.livelinessLostCount.incrementAndGet();
            }

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
            }
        };
    }

    static Dcps.DDS.DataWriter createWriter(Dcps.DDS.DomainParticipant dp, Dcps.DDS.Publisher pub, String topicName,
                                             Dcps.DDS.LivelinessQosPolicyKind kind, WriterState state) throws Exception {
        Dcps.DDS.Topic topic = dp.create_topic(topicName, "LivelinessEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic(" + topicName + ") failed");
            System.exit(1);
        }
        System.out.println("Create topic: " + topicName);
        System.out.flush();

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        dwQos.get_liveliness().set_kind(kind);
        dwQos.get_liveliness().get_lease_duration().set_sec(LEASE_DURATION_SEC);
        dwQos.get_liveliness().get_lease_duration().set_nanosec(0);

        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, null, 0);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter(" + topicName + ") failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: " + topicName);
        System.out.flush();

        if (dw.set_listener(makeListener(state), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value | Dcps.DDS.LIVELINESS_LOST_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener(" + topicName + ") failed");
            System.exit(1);
        }
        return dw;
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

        if (LivelinessEventTypeSupport.register(dp, "LivelinessEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        WriterState autoState = new WriterState();
        WriterState manualState = new WriterState();
        Dcps.DDS.DataWriter autoDw = createWriter(dp, pub, "AutomaticLivelinessTopic", Dcps.DDS.LivelinessQosPolicyKind.AUTOMATIC_LIVELINESS_QOS, autoState);
        Dcps.DDS.DataWriter manualDw = createWriter(dp, pub, "ManualByParticipantLivelinessTopic", Dcps.DDS.LivelinessQosPolicyKind.MANUAL_BY_PARTICIPANT_LIVELINESS_QOS, manualState);

        LivelinessEventDataWriter autoWriter = new LivelinessEventDataWriter(autoDw);
        LivelinessEventDataWriter manualWriter = new LivelinessEventDataWriter(manualDw);

        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (autoState.matchedCurrentCount.get() < 1 || manualState.matchedCurrentCount.get() < 1) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: readers never matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Publisher: both readers matched.");
        System.out.flush();

        // Deliberately never call assert_liveliness() anywhere in this loop
        // -- that's the whole point (see c/liveliness-lost/src/publisher.c's
        // header comment).
        for (int i = 0; i < WRITE_COUNT; i++) {
            Liveliness_event.LivelinessEvent ev = new Liveliness_event.LivelinessEvent();
            ev.set_seq(i);
            if (autoWriter.write(ev, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write(AUTOMATIC) failed at seq=" + i);
                System.exit(1);
            }
            if (manualWriter.write(ev, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write(MANUAL_BY_PARTICIPANT) failed at seq=" + i);
                System.exit(1);
            }
            Thread.sleep(WRITE_PERIOD_MS);
        }
        System.out.println("Publisher: write loop done.");
        System.out.flush();

        Dcps.DDS.LivelinessLostStatus autoStatus = new Dcps.DDS.LivelinessLostStatus();
        if (autoDw.get_liveliness_lost_status(autoStatus) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: get_liveliness_lost_status(AUTOMATIC) failed");
            System.exit(1);
        }
        Dcps.DDS.LivelinessLostStatus manualStatus = new Dcps.DDS.LivelinessLostStatus();
        if (manualDw.get_liveliness_lost_status(manualStatus) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: get_liveliness_lost_status(MANUAL_BY_PARTICIPANT) failed");
            System.exit(1);
        }

        if (autoState.livelinessLostCount.get() != 0 || autoStatus.get_total_count() != 0) {
            System.err.println("FAIL: AUTOMATIC writer lost liveliness (listener_count=" + autoState.livelinessLostCount.get() + ", status.total_count=" + autoStatus.get_total_count() + "), expected never");
            System.exit(1);
        }
        System.out.println("Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as expected.");
        System.out.flush();

        if (manualState.livelinessLostCount.get() < 1 || manualStatus.get_total_count() < 1) {
            System.err.println("FAIL: MANUAL_BY_PARTICIPANT writer never lost liveliness (listener_count=" + manualState.livelinessLostCount.get() + ", status.total_count=" + manualStatus.get_total_count() + ") despite never asserting it, expected >=1");
            System.exit(1);
        }
        System.out.println("Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness (total_count=" + manualStatus.get_total_count() + ") despite continuous writing, as expected.");
        System.out.flush();

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (autoState.matchedCurrentCount.get() != 0 || manualState.matchedCurrentCount.get() != 0) {
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
