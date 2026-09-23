// integration-tests/java/source-timestamp -- subscriber (the entity under
// test). Direct Java port of c/source-timestamp/src/subscriber.c -- see
// that file's header comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:", "Create reader for topic:",
// "Subscriber: ready.", "Subscriber: received seq=... with source_timestamp
// sec=... matching the explicit write timestamp.", "Subscriber: received
// disposed instance with source_timestamp matching the explicit dispose
// timestamp.", "Subscriber: done." Any failure path prints a line starting
// "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int SAMPLE_COUNT = 5;
    static final int WRITE_BASE_SEC = 1000000;
    static final int DISPOSE_SEC = 2000000;
    static final int DISPOSE_NSEC = 123456789;
    static final int RECEIVE_TIMEOUT_MS = 20000;
    static final int POLL_PERIOD_MS = 20;

    static class SubState {
        TimestampEventDataReader reader;
        final AtomicBoolean[] aliveReceived = new AtomicBoolean[SAMPLE_COUNT];
        final AtomicInteger aliveCount = new AtomicInteger(0);
        final AtomicBoolean disposeReceived = new AtomicBoolean(false);
        final AtomicBoolean disposeTimestampOk = new AtomicBoolean(false);

        SubState() {
            for (int i = 0; i < SAMPLE_COUNT; i++) aliveReceived[i] = new AtomicBoolean(false);
        }
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

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, null, 0);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: TimestampEvent");
        System.out.flush();

        SubState state = new SubState();
        state.reader = new TimestampEventDataReader(rawReader);

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                TimestampEventDataReader.Sample sample;
                while ((sample = state.reader.take()) != null) {
                    Dcps.DDS.Time_t ts = sample.info.get_source_timestamp();
                    if (sample.validData) {
                        int seq = sample.data.get_seq();
                        if (seq < 0 || seq >= SAMPLE_COUNT) {
                            System.err.println("FAIL: unexpected seq=" + seq);
                            System.exit(1);
                        }
                        if (ts.get_sec() != WRITE_BASE_SEC + seq || ts.get_nanosec() != 0) {
                            System.err.println("FAIL: seq=" + seq + " source_timestamp sec=" + ts.get_sec() + " nanosec=" + ts.get_nanosec() + " does not match expected sec=" + (WRITE_BASE_SEC + seq) + " nanosec=0");
                            System.exit(1);
                        }
                        System.out.println("Subscriber: received seq=" + seq + " with source_timestamp sec=" + ts.get_sec() + " matching the explicit write timestamp.");
                        System.out.flush();
                        if (!state.aliveReceived[seq].get()) {
                            state.aliveReceived[seq].set(true);
                            state.aliveCount.incrementAndGet();
                        }
                    } else if (sample.instanceState == Dcps.DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE.value) {
                        state.disposeReceived.set(true);
                        if (ts.get_sec() == DISPOSE_SEC && ts.get_nanosec() == DISPOSE_NSEC) {
                            state.disposeTimestampOk.set(true);
                        } else {
                            System.err.println("FAIL: disposed-instance source_timestamp sec=" + ts.get_sec() + " nanosec=" + ts.get_nanosec() + " does not match expected sec=" + DISPOSE_SEC + " nanosec=" + DISPOSE_NSEC);
                            System.exit(1);
                        }
                    }
                }
            }
        };
        if (rawReader.set_listener(listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        System.out.println("Subscriber: ready.");
        System.out.flush();

        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (state.aliveCount.get() < SAMPLE_COUNT || !state.disposeReceived.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: only received " + state.aliveCount.get() + "/" + SAMPLE_COUNT + " alive samples and disposeReceived=" + state.disposeReceived.get() + " within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        if (!state.disposeTimestampOk.get()) {
            System.err.println("FAIL: dispose sample was received but its timestamp never matched (should have exited already)");
            System.exit(1);
        }
        System.out.println("Subscriber: received disposed instance with source_timestamp matching the explicit dispose timestamp.");
        System.out.flush();

        System.out.println("Subscriber: done.");
        System.out.flush();
        factory.delete_participant(dp);
    }
}
