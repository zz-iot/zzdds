// java/hello_world -- subscriber. Direct Java port of
// zig/hello_world/subscriber.zig / c/hello_world/src/subscriber.c /
// cpp/hello_world/src/subscriber.cpp; see
// docs/design/hello-world-reference-app.md at the repo root for the full
// spec. Demonstrates DataReaderListener::on_data_available: every sample
// is checked against the next expected `count` (fail fast -- any gap or
// reorder is a hard error), and once all 10 arrive in order this process
// tears its reader down immediately, which is what lets the publisher's
// matched reader count drop back to zero and exit.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// reader for topic:", "Subscriber: received count=", "Subscriber: received
// all 10 samples in order." Any failure path prints a line starting
// "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int EXPECTED_SAMPLES = 10;
    static final int RECEIVE_TIMEOUT_MS = 30000;
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

        if (HelloWorldTypeSupport.register(dp, "HelloWorld") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("HelloWorld", "HelloWorld", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: HelloWorld");

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        final AtomicInteger expectedNext = new AtomicInteger(0);
        final AtomicBoolean allReceived = new AtomicBoolean(false);
        final Object[] readerBox = new Object[1]; // set right after create_datareader

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                // Fired on zzdds's own network thread (see ZzddsRuntime's
                // javadoc) -- take() calls back into JNI from here, which is
                // fine, but keep callback bodies short and avoid blocking.
                HelloWorldDataReader reader = (HelloWorldDataReader) readerBox[0];
                HelloWorldDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    if (!sample.validData) continue;

                    int count = sample.data.get_count();
                    int expected = expectedNext.get();
                    if (count != expected) {
                        System.err.println("FAIL: expected count=" + expected + " but got count=" + count);
                        System.exit(1);
                    }

                    System.out.println("Subscriber: received count=" + count + " message=\"" + sample.data.get_message() + "\"");
                    int next = expectedNext.incrementAndGet();

                    if (next == EXPECTED_SAMPLES) {
                        allReceived.set(true);
                    }
                }
            }
        };

        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: HelloWorld");

        readerBox[0] = new HelloWorldDataReader(rawReader);

        System.out.println("Subscriber: waiting for " + EXPECTED_SAMPLES + " samples...");
        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (!allReceived.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: only received " + expectedNext.get() + "/" + EXPECTED_SAMPLES + " samples within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // Tear the reader down immediately -- the publisher is blocked
        // waiting for our matched-reader count to drop back to zero.
        sub.delete_datareader(rawReader);

        System.out.println("Subscriber: received all " + EXPECTED_SAMPLES + " samples in order.");
    }
}
