// integration-tests/java/cft-reconfigure -- subscriber (the entity under
// test). Direct Java port of c/cft-reconfigure/src/subscriber.c -- see that
// file's header comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:" x2, "Create reader for topic:"
// x2, "Create writer for topic:", "Subscriber: CFT introspection
// (filter_expression/expression_parameters/related_topic) verified at
// creation.", "Subscriber: ready.", "Subscriber: witnessed all 5 phase1
// samples via unfiltered reader.", "Subscriber: filtered reader correctly
// received zero phase1 samples (threshold=1000).", "Subscriber:
// set_expression_parameters() reconfigured threshold to 3, read-back
// verified.", "Subscriber: sent go-ahead signal.", "Subscriber: witnessed
// all 10 total samples via unfiltered reader.", "Subscriber: filtered
// reader received exactly the post-reconfigure samples {5..9}, confirming
// live re-filtering without CFT recreation.", "Subscriber: done." Any
// failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int TOTAL_COUNT = 10;
    static final int PHASE1_COUNT = 5;
    static final int PHASE2_COUNT = 5;
    // Must comfortably exceed Publisher.java's own MATCH_TIMEOUT_MS -- see
    // c/cft-reconfigure/src/subscriber.c's matching comment.
    static final int WITNESS_TIMEOUT_MS = 45000;
    static final int SETTLE_WINDOW_MS = 3000;
    static final int FINAL_TIMEOUT_MS = 20000;
    static final int POLL_PERIOD_MS = 20;

    static class ReaderState {
        CftEventDataReader reader;
        final AtomicBoolean[] received = new AtomicBoolean[TOTAL_COUNT];
        final AtomicInteger count = new AtomicInteger(0);

        ReaderState() {
            for (int i = 0; i < TOTAL_COUNT; i++) received[i] = new AtomicBoolean(false);
        }
    }

    static Dcps.DDS.DataReaderListener makeListener(ReaderState state) {
        return new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                CftEventDataReader.Sample sample;
                while ((sample = state.reader.take()) != null) {
                    if (!sample.validData) continue;
                    int seq = sample.data.get_seq();
                    if (seq < 0 || seq >= TOTAL_COUNT) {
                        System.err.println("FAIL: unexpected seq=" + seq);
                        System.exit(1);
                    }
                    if (!state.received[seq].get()) {
                        state.received[seq].set(true);
                        state.count.incrementAndGet();
                    }
                }
            }
        };
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

        if (CftEventTypeSupport.register(dp, "CftEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("CftEvent", "CftEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: CftEvent");
        System.out.flush();

        Dcps.DDS.Topic goTopic = dp.create_topic("GoTopic", "CftEvent", null, null, 0);
        if (goTopic == null) {
            System.err.println("FAIL: create_topic(GoTopic) failed");
            System.exit(1);
        }
        System.out.println("Create topic: GoTopic");
        System.out.flush();

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (sub == null || pub == null) {
            System.err.println("FAIL: create_subscriber()/create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        // -- Witness reader: plain, unfiltered, proves end-to-end wire
        // delivery independent of the filtered reader's own behavior. --
        Dcps.DDS.DataReader witnessDr = sub.create_datareader(topic, drQos, null, 0);
        if (witnessDr == null) {
            System.err.println("FAIL: create_datareader(witness) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: CftEvent (witness)");
        System.out.flush();

        // -- ContentFilteredTopic: initial threshold (1000) unreachable by
        // phase1's seq range (0..4), so every phase1 sample must be
        // filtered out. --
        Dcps.DDS.ContentFilteredTopic cft = dp.create_contentfilteredtopic(
            "CftEvent_Filtered", topic, "seq >= %0", Arrays.asList("1000"));
        if (cft == null) {
            System.err.println("FAIL: create_contentfilteredtopic() failed");
            System.exit(1);
        }

        // -- CFT introspection, verified right at creation -- the exact
        // surface the API audit flags as "set once at creation, never read
        // back". --
        String filterExpr = cft.get_filter_expression();
        if (filterExpr == null || !filterExpr.equals("seq >= %0")) {
            System.err.println("FAIL: get_filter_expression() returned \"" + filterExpr + "\", expected \"seq >= %0\"");
            System.exit(1);
        }
        List<String> readbackParams = new ArrayList<>();
        if (cft.get_expression_parameters(readbackParams) != Dcps.DDS.RETCODE_OK.value || readbackParams.size() != 1 || !readbackParams.get(0).equals("1000")) {
            System.err.println("FAIL: get_expression_parameters() at creation did not return [\"1000\"]");
            System.exit(1);
        }
        Dcps.DDS.Topic related = cft.get_related_topic();
        if (related == null || !related.get_name().equals("CftEvent")) {
            System.err.println("FAIL: get_related_topic() did not return the CftEvent topic");
            System.exit(1);
        }
        System.out.println("Subscriber: CFT introspection (filter_expression/expression_parameters/related_topic) verified at creation.");
        System.out.flush();

        Dcps.DDS.DataReader filteredDr = sub.create_datareader(cft, drQos, null, 0);
        if (filteredDr == null) {
            System.err.println("FAIL: create_datareader(filtered) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: CftEvent_Filtered");
        System.out.flush();

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        Dcps.DDS.DataWriter goDw = pub.create_datawriter(goTopic, dwQos, null, 0);
        if (goDw == null) {
            System.err.println("FAIL: create_datawriter(GoTopic) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: GoTopic");
        System.out.flush();

        ReaderState witnessState = new ReaderState();
        ReaderState filteredState = new ReaderState();
        witnessState.reader = new CftEventDataReader(witnessDr);
        filteredState.reader = new CftEventDataReader(filteredDr);

        if (witnessDr.set_listener(makeListener(witnessState), Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0 ||
            filteredDr.set_listener(makeListener(filteredState), Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        CftEventDataWriter goWriter = new CftEventDataWriter(goDw);

        System.out.println("Subscriber: ready.");
        System.out.flush();

        // -- Phase 1: wait for the witness reader to see all 5, proving
        // they really were sent and really did arrive over the wire. --
        long deadline = System.currentTimeMillis() + WITNESS_TIMEOUT_MS;
        while (witnessState.count.get() < PHASE1_COUNT) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: witness reader only saw " + witnessState.count.get() + "/" + PHASE1_COUNT + " phase1 samples within " + (WITNESS_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Subscriber: witnessed all " + PHASE1_COUNT + " phase1 samples via unfiltered reader.");
        System.out.flush();

        // -- Settle window, then confirm the filtered reader received none
        // of phase1 (threshold=1000 excludes seq 0..4 entirely). --
        Thread.sleep(SETTLE_WINDOW_MS);
        int filteredAfterPhase1 = filteredState.count.get();
        if (filteredAfterPhase1 != 0) {
            System.err.println("FAIL: filtered reader received " + filteredAfterPhase1 + " phase1 samples despite threshold=1000");
            System.exit(1);
        }
        System.out.println("Subscriber: filtered reader correctly received zero phase1 samples (threshold=1000).");
        System.out.flush();

        // -- Reconfigure the live CFT in place -- no recreation of the CFT
        // or its DataReader. --
        if (cft.set_expression_parameters(Arrays.asList("3")) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: set_expression_parameters() failed");
            System.exit(1);
        }
        List<String> readback2 = new ArrayList<>();
        if (cft.get_expression_parameters(readback2) != Dcps.DDS.RETCODE_OK.value || readback2.size() != 1 || !readback2.get(0).equals("3")) {
            System.err.println("FAIL: get_expression_parameters() after reconfigure did not return [\"3\"]");
            System.exit(1);
        }
        System.out.println("Subscriber: set_expression_parameters() reconfigured threshold to 3, read-back verified.");
        System.out.flush();

        Cft_event.CftEvent goEv = new Cft_event.CftEvent();
        goEv.set_seq(0);
        if (goWriter.write(goEv, 0L) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: write(GoTopic) failed");
            System.exit(1);
        }
        System.out.println("Subscriber: sent go-ahead signal.");
        System.out.flush();

        // -- Phase 2: wait for the witness reader to see all 10 total. --
        deadline = System.currentTimeMillis() + FINAL_TIMEOUT_MS;
        while (witnessState.count.get() < TOTAL_COUNT) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: witness reader only saw " + witnessState.count.get() + "/" + TOTAL_COUNT + " total samples within " + (FINAL_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Subscriber: witnessed all " + TOTAL_COUNT + " total samples via unfiltered reader.");
        System.out.flush();

        // The witness and filtered readers are separate DataReaders with independent
        // delivery/dispatch, so the witness reader reaching TOTAL_COUNT does not
        // guarantee the filtered reader's own listener has finished processing its
        // (fewer) samples yet. Wait for the filtered reader's own count before
        // asserting its exact contents below, or a correct implementation can fail
        // this nondeterministically (found via Greptile review).
        deadline = System.currentTimeMillis() + FINAL_TIMEOUT_MS;
        while (filteredState.count.get() < PHASE2_COUNT) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: filtered reader only saw " + filteredState.count.get() + "/" + PHASE2_COUNT + " phase2 samples within " + (FINAL_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // -- The core assertion: the filtered reader must have received
        // *exactly* {5,6,7,8,9} -- phase2 correctly re-filtered against the
        // new threshold (proving live reconfiguration works), and phase1's
        // seq=3 and seq=4 (both >= the *new* threshold of 3) never
        // retroactively appear (proving already-dropped samples are gone
        // for good, not replayed against the new parameter). --
        for (int seq = 0; seq < PHASE1_COUNT; seq++) {
            if (filteredState.received[seq].get()) {
                System.err.println("FAIL: filtered reader retroactively received phase1 seq=" + seq + " after reconfigure");
                System.exit(1);
            }
        }
        for (int seq = PHASE1_COUNT; seq < TOTAL_COUNT; seq++) {
            if (!filteredState.received[seq].get()) {
                System.err.println("FAIL: filtered reader never received phase2 seq=" + seq + " despite threshold=3");
                System.exit(1);
            }
        }
        if (filteredState.count.get() != PHASE2_COUNT) {
            System.err.println("FAIL: filtered reader received " + filteredState.count.get() + " samples total, expected exactly " + PHASE2_COUNT);
            System.exit(1);
        }
        System.out.println("Subscriber: filtered reader received exactly the post-reconfigure samples {5..9}, confirming live re-filtering without CFT recreation.");
        System.out.flush();

        System.out.println("Subscriber: done.");
        System.out.flush();
        factory.delete_participant(dp);
    }
}
