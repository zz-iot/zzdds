// integration-tests/java/liveliness-lost -- subscriber. Direct Java port of
// c/liveliness-lost/src/subscriber.c -- see that file's header comment for
// the full scenario rationale and docs/design/integration-test-tier.md for
// the scenario spec.
//
// Required stdout markers: "Create topic:" x2, "Create reader for topic:"
// x2, "Subscriber: both writers matched.", "Subscriber: AUTOMATIC reader
// never observed NOT_ALIVE, as expected.", "Subscriber:
// MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as
// expected.", "Subscriber: done." Any failure path prints a line starting
// "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int LEASE_DURATION_SEC = 2;
    // Comfortably longer than the publisher's own ~8s write loop (16 writes
    // * 500ms), so the observation window covers the whole thing.
    static final int OBSERVE_WINDOW_MS = 12000;
    // 40s, not the 20s every other match-wait in this tier uses -- see
    // c/liveliness-lost/src/publisher.c's matching comment.
    static final int MATCH_TIMEOUT_MS = 40000;
    static final int POLL_PERIOD_MS = 20;

    static class ReaderState {
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);
        final AtomicInteger aliveCount = new AtomicInteger(0);
        final AtomicBoolean everNotAlive = new AtomicBoolean(false);
    }

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    static Dcps.DDS.DataReaderListener makeListener(ReaderState state) {
        return new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
            }

            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {
                state.aliveCount.set(s.get_alive_count());
                if (s.get_alive_count() == 0) state.everNotAlive.set(true);
            }
        };
    }

    static Dcps.DDS.DataReader createReader(Dcps.DDS.DomainParticipant dp, Dcps.DDS.Subscriber sub, String topicName,
                                             Dcps.DDS.LivelinessQosPolicyKind kind, ReaderState state) throws Exception {
        Dcps.DDS.Topic topic = dp.create_topic(topicName, "LivelinessEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic(" + topicName + ") failed");
            System.exit(1);
        }
        System.out.println("Create topic: " + topicName);
        System.out.flush();

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        drQos.get_liveliness().set_kind(kind);
        drQos.get_liveliness().get_lease_duration().set_sec(LEASE_DURATION_SEC);
        drQos.get_liveliness().get_lease_duration().set_nanosec(0);

        Dcps.DDS.DataReader dr = sub.create_datareader(topic, drQos, null, 0);
        if (dr == null) {
            System.err.println("FAIL: create_datareader(" + topicName + ") failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: " + topicName);
        System.out.flush();

        if (dr.set_listener(makeListener(state), Dcps.DDS.SUBSCRIPTION_MATCHED_STATUS.value | Dcps.DDS.LIVELINESS_CHANGED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener(" + topicName + ") failed");
            System.exit(1);
        }
        return dr;
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

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        ReaderState autoState = new ReaderState();
        ReaderState manualState = new ReaderState();
        createReader(dp, sub, "AutomaticLivelinessTopic", Dcps.DDS.LivelinessQosPolicyKind.AUTOMATIC_LIVELINESS_QOS, autoState);
        createReader(dp, sub, "ManualByParticipantLivelinessTopic", Dcps.DDS.LivelinessQosPolicyKind.MANUAL_BY_PARTICIPANT_LIVELINESS_QOS, manualState);

        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (autoState.matchedCurrentCount.get() < 1 || manualState.matchedCurrentCount.get() < 1) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: writers never matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Subscriber: both writers matched.");
        System.out.flush();

        Thread.sleep(OBSERVE_WINDOW_MS);

        if (autoState.everNotAlive.get()) {
            System.err.println("FAIL: AUTOMATIC reader observed NOT_ALIVE (alive_count dropped to 0) at some point, expected never");
            System.exit(1);
        }
        System.out.println("Subscriber: AUTOMATIC reader never observed NOT_ALIVE, as expected.");
        System.out.flush();

        if (!manualState.everNotAlive.get()) {
            System.err.println("FAIL: MANUAL_BY_PARTICIPANT reader never observed NOT_ALIVE despite the writer never asserting liveliness, expected at least once");
            System.exit(1);
        }
        System.out.println("Subscriber: MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as expected.");
        System.out.flush();

        System.out.println("Subscriber: done.");
        System.out.flush();
        factory.delete_participant(dp);
    }
}
