// java/catchup -- publisher. Direct Java port of
// zig/catchup/publisher.zig / c/catchup/src/publisher.c /
// cpp/catchup/src/publisher.cpp; see docs/design/catchup-reference-app.md
// at the repo root for the full spec. Writes a historical batch
// immediately, with no reader matched yet, then -- once a reader does
// match -- writes a live batch. TRANSIENT_LOCAL durability means zzdds's
// own writer-side cache (not this app) is what makes the historical batch
// replayable to a late joiner.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// writer for topic:", "Publisher: wrote historical seq_num=", "Publisher:
// reader matched, writing live batch", "Publisher: wrote live seq_num=",
// "Publisher: done." Any failure path prints a line starting "FAIL:" and
// exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int HISTORICAL_COUNT = 10;
    static final int LIVE_COUNT = 5;
    static final int MATCH_TIMEOUT_MS = 15000;
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

        if (HistoryEventTypeSupport.register(dp, "HistoryEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("HistoryEvent", "HistoryEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: HistoryEvent");

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_durability().set_kind(Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter rawWriter = pub.create_datawriter(topic, dwQos, null, 0);
        if (rawWriter == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: HistoryEvent");

        final AtomicBoolean everMatched = new AtomicBoolean(false);
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);

        Dcps.DDS.DataWriterListener writerListener = new Dcps.DDS.DataWriterListener() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) everMatched.set(true);
                System.out.println("on_publication_matched() current_count=" + s.get_current_count());
            }
        };
        if (rawWriter.set_listener(writerListener, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener failed");
            System.exit(1);
        }

        HistoryEventDataWriter writer = new HistoryEventDataWriter(rawWriter);

        // -- Historical batch: written immediately, no reader matched yet. --
        int seq = 0;
        for (; seq < HISTORICAL_COUNT; seq++) {
            Catchup_sample.HistoryEvent sample = new Catchup_sample.HistoryEvent();
            sample.set_seq_num(seq);
            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at seq_num=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote historical seq_num=" + seq);
        }

        // -- Wait for the late-joining reader to match. --
        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (!everMatched.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reader matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Publisher: reader matched, writing live batch");

        // -- Live batch. --
        for (; seq < HISTORICAL_COUNT + LIVE_COUNT; seq++) {
            Catchup_sample.HistoryEvent sample = new Catchup_sample.HistoryEvent();
            sample.set_seq_num(seq);
            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at seq_num=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote live seq_num=" + seq);
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
