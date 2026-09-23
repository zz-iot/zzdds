// integration-tests/java/cft-reconfigure -- publisher. Direct Java port of
// c/cft-reconfigure/src/publisher.c -- see that file's header comment for
// the full scenario rationale and docs/design/integration-test-tier.md for
// the scenario spec.
//
// Required stdout markers: "Create topic:" x2, "Create writer for topic:",
// "Publisher: wrote phase1 seq=", "Publisher: received go-ahead signal.",
// "Publisher: wrote phase2 seq=", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int PHASE1_COUNT = 5;
    static final int PHASE2_COUNT = 5;
    // 40s, not the 20s every other match-wait in this tier uses -- see
    // c/cft-reconfigure/src/publisher.c's matching comment.
    static final int MATCH_TIMEOUT_MS = 40000;
    static final int GO_TIMEOUT_MS = 20000;
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

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (pub == null || sub == null) {
            System.err.println("FAIL: create_publisher()/create_subscriber() failed");
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
        System.out.println("Create writer for topic: CftEvent");
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

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReader goDr = sub.create_datareader(goTopic, drQos, null, 0);
        if (goDr == null) {
            System.err.println("FAIL: create_datareader(GoTopic) failed");
            System.exit(1);
        }

        CftEventDataWriter writer = new CftEventDataWriter(dw);
        CftEventDataReader goReader = new CftEventDataReader(goDr);

        // -- Wait for both of the subscriber's readers (witness + filtered)
        // to match before writing anything, so phase1 is guaranteed to
        // actually reach both. --
        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (state.matchedCurrentCount.get() < 2) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: fewer than 2 readers matched within " + (MATCH_TIMEOUT_MS / 1000) + "s (got " + state.matchedCurrentCount.get() + ")");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // -- Phase 1: written while the CFT's threshold excludes all of it. --
        for (int seq = 0; seq < PHASE1_COUNT; seq++) {
            Cft_event.CftEvent sample = new Cft_event.CftEvent();
            sample.set_seq(seq);
            if (writer.write(sample, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write(phase1) failed at seq=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote phase1 seq=" + seq);
            System.out.flush();
        }

        // -- Wait for the subscriber's go-ahead: it has confirmed phase1
        // was filtered out and reconfigured the CFT's parameters in
        // place. --
        boolean gotGo = false;
        deadline = System.currentTimeMillis() + GO_TIMEOUT_MS;
        while (!gotGo) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: go-ahead signal never arrived within " + (GO_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            CftEventDataReader.Sample sample = goReader.take();
            if (sample != null && sample.validData) {
                gotGo = true;
                break;
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Publisher: received go-ahead signal.");
        System.out.flush();

        // -- Phase 2: written after the reconfigure, on the same
        // DataWriter. --
        for (int seq = PHASE1_COUNT; seq < PHASE1_COUNT + PHASE2_COUNT; seq++) {
            Cft_event.CftEvent sample = new Cft_event.CftEvent();
            sample.set_seq(seq);
            if (writer.write(sample, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write(phase2) failed at seq=" + seq);
                System.exit(1);
            }
            System.out.println("Publisher: wrote phase2 seq=" + seq);
            System.out.flush();
        }

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
