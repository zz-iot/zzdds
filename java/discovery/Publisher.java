// java/discovery -- publisher. Direct Java port of
// zig/discovery/publisher.zig / c/discovery/src/publisher.c /
// cpp/discovery/src/publisher.cpp; see
// docs/design/discovery-reference-app.md at the repo root for the full
// spec.
//
// After creating its topic, calls DomainParticipant.get_discovered_topics/
// _topic_data -- these succeed immediately, even before any remote peer
// appears (a participant registers its own locally-created topics right
// away). Once a reliable reader is ready (proving cross-process match
// happened), calls DataWriter.get_matched_subscriptions/_subscription_data
// to look up the matched subscriber's own topic/type name. Then runs the
// same minimal reliable write loop (3 samples) as hello_world/
// participant-config.
//
// InstanceHandleSeq maps to java.util.List<Integer> and TopicBuiltinTopicData/
// SubscriptionBuiltinTopicData/PublicationBuiltinTopicData are plain,
// GC-managed Java classes -- fully idiomatic, nothing to free manually
// (compare to c/discovery, which calls the C-ABI struct's own _free()
// directly).
//
// Required stdout markers: "Create topic:", "Create writer for topic:",
// "Discovery OK (participant):", "on_reliable_reader_ready", "Discovery OK
// (writer):", "Publisher: wrote count=", "Publisher: done." Any failure
// path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int SAMPLE_COUNT = 3;
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int DRAIN_TIMEOUT_MS = 15000;
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

        // Participant-level discovery: a freshly-created local topic is
        // immediately visible, no cross-process wait needed.
        {
            java.util.ArrayList<Integer> handles = new java.util.ArrayList<>();
            if (dp.get_discovered_topics(handles) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_discovered_topics() failed");
                System.exit(1);
            }
            boolean found = false;
            Dcps.DDS.TopicBuiltinTopicData topicData = new Dcps.DDS.TopicBuiltinTopicData();
            for (int h : handles) {
                if (dp.get_discovered_topic_data(topicData, h) != Dcps.DDS.RETCODE_OK.value) continue;
                if (TOPIC_NAME.equals(topicData.get_name())) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                System.err.println("FAIL: get_discovered_topic_data() never returned '" + TOPIC_NAME + "'");
                System.exit(1);
            }
            if (!TYPE_NAME.equals(topicData.get_type_name())) {
                System.err.println("FAIL: discovered topic type_name mismatch: expected '" + TYPE_NAME
                        + "', got '" + topicData.get_type_name() + "'");
                System.exit(1);
            }
            System.out.println("Discovery OK (participant): topic.name='" + topicData.get_name()
                    + "' topic.type_name='" + topicData.get_type_name() + "'");
        }

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter rawWriter = pub.create_datawriter(topic, dwQos, null, 0);
        if (rawWriter == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: " + TOPIC_NAME);

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

        DiscoveryPingDataWriter writer = new DiscoveryPingDataWriter(rawWriter);

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // Writer-level discovery: the remote subscriber has definitely
        // matched by now (on_reliable_reader_ready only fires once it has).
        {
            java.util.ArrayList<Integer> handles = new java.util.ArrayList<>();
            if (rawWriter.get_matched_subscriptions(handles) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_matched_subscriptions() failed");
                System.exit(1);
            }
            if (handles.isEmpty()) {
                System.err.println("FAIL: get_matched_subscriptions() returned no matches");
                System.exit(1);
            }
            Dcps.DDS.SubscriptionBuiltinTopicData subData = new Dcps.DDS.SubscriptionBuiltinTopicData();
            if (rawWriter.get_matched_subscription_data(subData, handles.get(0)) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_matched_subscription_data() failed");
                System.exit(1);
            }
            if (!TOPIC_NAME.equals(subData.get_topic_name()) || !TYPE_NAME.equals(subData.get_type_name())) {
                System.err.println("FAIL: matched subscription topic_name/type_name mismatch: got '"
                        + subData.get_topic_name() + "'/'" + subData.get_type_name() + "'");
                System.exit(1);
            }
            System.out.println("Discovery OK (writer): matched_subscription.topic_name='" + subData.get_topic_name()
                    + "' type_name='" + subData.get_type_name() + "'");
        }

        for (int i = 0; i < SAMPLE_COUNT; i++) {
            Discovery_ping.DiscoveryPing sample = new Discovery_ping.DiscoveryPing();
            sample.set_count(i);

            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at count=" + i);
                System.exit(1);
            }
            System.out.println("Publisher: wrote count=" + i);
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
