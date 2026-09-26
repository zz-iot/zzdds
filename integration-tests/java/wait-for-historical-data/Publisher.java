// integration-tests/java/wait-for-historical-data -- publisher. Direct Java
// port of c/wait-for-historical-data/src/publisher.c -- see that file's
// header comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:", "Create writer for topic:",
// "Publisher: wrote historical seq_num=", "Publisher: reader matched,
// writing live batch", "Publisher: wrote live seq_num=", "Publisher: done."
// Any failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int HISTORICAL_COUNT = 8;
    static final int LIVE_COUNT = 4;
    static final int MATCH_TIMEOUT_MS = 20000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static class PubState {
        final AtomicBoolean everMatched = new AtomicBoolean(false);
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

        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, null, 0);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: HistoryEvent");

        PubState state = new PubState();
        Dcps.DDS.DataWriterListener listener = new Dcps.DDS.DataWriterListener() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) state.everMatched.set(true);
                System.out.println("on_publication_matched() current_count=" + s.get_current_count());
            }
        };
        if (dw.set_listener(listener, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener failed");
            System.exit(1);
        }

        HistoryEventDataWriter writer = new HistoryEventDataWriter(dw);

        // -- Historical batch: written immediately, no reader matched yet. --
        int seq = 0;
        for (; seq < HISTORICAL_COUNT; seq++) {
            History_event.HistoryEvent sample = new History_event.HistoryEvent();
            sample.set_seq_num(seq);
            if (writer.write(sample, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write() failed at seq_num=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote historical seq_num=" + seq);
        }

        // Verify the batch above was genuinely historical: the subscriber and its
        // reader already exist by the time this process starts (see the harness),
        // so nothing here actually stops discovery from completing fast enough to
        // match before this fast, unthrottled write loop finishes -- which would
        // silently turn some or all of it into ordinary live delivery instead of
        // exercising TRANSIENT_LOCAL replay, without the subscriber's
        // sequence-number-only check ever noticing (found via Greptile review).
        // Assert unmatched here instead of just assuming it, so a race like that
        // fails loudly instead of silently validating nothing.
        if (state.matchedCurrentCount.get() != 0) {
            System.err.println("FAIL: reader matched before the historical batch finished writing -- not exercising late-join replay");
            System.exit(1);
        }

        // -- Wait for the late-joining reader to match. --
        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (!state.everMatched.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reader matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Publisher: reader matched, writing live batch");

        // -- Live batch. --
        for (; seq < HISTORICAL_COUNT + LIVE_COUNT; seq++) {
            History_event.HistoryEvent sample = new History_event.HistoryEvent();
            sample.set_seq_num(seq);
            if (writer.write(sample, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write() failed at seq_num=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote live seq_num=" + seq);
        }

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (!(state.everMatched.get() && state.matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Publisher: done.");
        factory.delete_participant(dp);
    }
}
