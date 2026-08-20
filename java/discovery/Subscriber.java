// java/discovery -- subscriber. Direct Java port of
// zig/discovery/subscriber.zig / c/discovery/src/subscriber.c /
// cpp/discovery/src/subscriber.cpp; see
// docs/design/discovery-reference-app.md at the repo root for the full
// spec.
//
// Waits for a matched publication (polling DataReader.get_matched_
// publications, bounded by a timeout), then calls DataReader.get_matched_
// publication_data to look up the matched writer's own topic/type name.
// Then runs the same minimal reliable read loop (3 samples) as
// hello_world/participant-config.
//
// Required stdout markers: "Create topic:", "Create reader for topic:",
// "Discovery OK (reader):", "Subscriber: received count=", "Subscriber:
// received all 3 samples in order." Any failure path prints a line
// starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int EXPECTED_SAMPLES = 3;
    static final int MATCH_TIMEOUT_MS = 10000;
    static final int RECEIVE_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    static final String TOPIC_NAME = "DiscoveryPing";
    static final String TYPE_NAME = "DiscoveryPing";

    static class Options {
        int domainId = 0;
    }

    static Options parseArgs(String[] args) {
        Options opts = new Options();
        for (int i = 0; i < args.length; i++) {
            if ((args[i].equals("-d") || args[i].equals("--domain")) && i + 1 < args.length) {
                opts.domainId = Integer.parseInt(args[++i]);
            }
        }
        return opts;
    }

    public static void main(String[] args) throws Exception {
        Options opts = parseArgs(args);

        Object baseFactory = io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (baseFactory == null) {
            System.err.println("FAIL: createFactory() failed");
            System.exit(1);
        }

        Dcps.DDS.DomainParticipantFactory factory = (Dcps.DDS.DomainParticipantFactory) baseFactory;
        Dcps.DDS.DomainParticipant dp = factory.create_participant(opts.domainId, null, null, 0);
        if (dp == null) {
            System.err.println("FAIL: create_participant() failed on domain " + opts.domainId);
            System.exit(1);
        }

        if (DiscoveryPingTypeSupport.register(dp, TOPIC_NAME) != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic(TOPIC_NAME, TYPE_NAME, null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: " + TOPIC_NAME);

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
                DiscoveryPingDataReader reader = (DiscoveryPingDataReader) readerBox[0];
                DiscoveryPingDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    if (!sample.validData) continue;

                    int count = sample.data.get_count();
                    int expected = expectedNext.get();
                    if (count != expected) {
                        System.err.println("FAIL: expected count=" + expected + " but got count=" + count);
                        System.exit(1);
                    }

                    System.out.println("Subscriber: received count=" + count);
                    int next = expectedNext.incrementAndGet();

                    if (next == EXPECTED_SAMPLES) {
                        allReceived.set(true);
                    }
                }
            }
        };

        // Create with no listener attached yet: on_data_available fires on
        // a zzdds-internal dispatch thread as soon as the reader matches,
        // which can race readerBox[0]'s own assignment below. Attach the
        // listener only once readerBox[0] is set, via set_listener() below,
        // closing the window entirely.
        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, null, 0);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: " + TOPIC_NAME);

        readerBox[0] = new DiscoveryPingDataReader(rawReader);
        if (rawReader.set_listener(listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        // Reader-level discovery: wait for the remote publisher to match.
        java.util.ArrayList<Integer> pubHandles = new java.util.ArrayList<>();
        long matchDeadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (true) {
            if (rawReader.get_matched_publications(pubHandles) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_matched_publications() failed");
                System.exit(1);
            }
            if (!pubHandles.isEmpty()) break;
            if (System.currentTimeMillis() > matchDeadline) {
                System.err.println("FAIL: no matched publication within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        Dcps.DDS.PublicationBuiltinTopicData pubData = new Dcps.DDS.PublicationBuiltinTopicData();
        if (rawReader.get_matched_publication_data(pubData, pubHandles.get(0)) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: get_matched_publication_data() failed");
            System.exit(1);
        }
        if (!TOPIC_NAME.equals(pubData.get_topic_name()) || !TYPE_NAME.equals(pubData.get_type_name())) {
            System.err.println("FAIL: matched publication topic_name/type_name mismatch: got '"
                    + pubData.get_topic_name() + "'/'" + pubData.get_type_name() + "'");
            System.exit(1);
        }
        System.out.println("Discovery OK (reader): matched_publication.topic_name='" + pubData.get_topic_name()
                + "' type_name='" + pubData.get_type_name() + "'");

        System.out.println("Subscriber: waiting for " + EXPECTED_SAMPLES + " samples...");
        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (!allReceived.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: only received " + expectedNext.get() + "/" + EXPECTED_SAMPLES + " samples within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        sub.delete_datareader(rawReader);

        System.out.println("Subscriber: received all " + EXPECTED_SAMPLES + " samples in order.");
    }
}
