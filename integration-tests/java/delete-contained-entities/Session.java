// integration-tests/java/delete-contained-entities -- session. Direct Java
// port of c/delete-contained-entities/src/session.c -- see that file's
// header comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:" x3, "Create writer for topic:"
// x2, "Create reader for topic:" x2, "Session: torn down via
// delete_contained_entities." Any failure path prints a line starting
// "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.Collections;
import java.util.concurrent.atomic.AtomicBoolean;

public class Session {
    static final int SAMPLE_COUNT = 5;
    static final int RECEIVE_TARGET = 2;
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int RECEIVE_TIMEOUT_MS = 20000;
    static final int WAIT_STEP_SEC = 1;
    static final int POLL_PERIOD_MS = 20;

    static final AtomicBoolean tornDown = new AtomicBoolean(false);

    static class WriterSyncState {
        final AtomicBoolean readerReady = new AtomicBoolean(false);
    }

    static int parseDomain(String[] args) {
        for (int i = 0; i < args.length - 1; i++) {
            if (args[i].equals("-d") || args[i].equals("--domain")) {
                return Integer.parseInt(args[i + 1]);
            }
        }
        return 0;
    }

    static Zzdds.zzdds.DataWriterListenerEx makeWriterListener(WriterSyncState state) {
        return new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                if (tornDown.get()) {
                    System.err.println("FAIL: listener fired after delete_contained_entities");
                    System.exit(1);
                }
            }

            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) state.readerReady.set(true);
            }
        };
    }

    static Dcps.DDS.DataReaderListener makeReaderListener() {
        return new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {
                if (tornDown.get()) {
                    System.err.println("FAIL: listener fired after delete_contained_entities");
                    System.exit(1);
                }
            }
        };
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

        if (SessionEventTypeSupport.register(dp, "SessionEvent") != 0) {
            System.err.println("FAIL: register SessionEventTypeSupport failed");
            System.exit(1);
        }

        Dcps.DDS.Topic out1Topic = dp.create_topic("SessionOut1", "SessionEvent", null, null, 0);
        Dcps.DDS.Topic out2Topic = dp.create_topic("SessionOut2", "SessionEvent", null, null, 0);
        Dcps.DDS.Topic inTopic = dp.create_topic("SessionIn", "SessionEvent", null, null, 0);
        if (out1Topic == null || out2Topic == null || inTopic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: SessionOut1");
        System.out.println("Create topic: SessionOut2");
        System.out.println("Create topic: SessionIn");

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter out1Dw = pub.create_datawriter(out1Topic, dwQos, null, 0);
        Dcps.DDS.DataWriter out2Dw = pub.create_datawriter(out2Topic, dwQos, null, 0);
        if (out1Dw == null || out2Dw == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: SessionOut1");
        System.out.println("Create writer for topic: SessionOut2");

        WriterSyncState out1State = new WriterSyncState();
        WriterSyncState out2State = new WriterSyncState();
        Zzdds.zzdds.DataWriter zOut1Dw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(out1Dw);
        Zzdds.zzdds.DataWriter zOut2Dw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(out2Dw);
        if (zOut1Dw == null || zOut2Dw == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }
        if (zOut1Dw.set_listener_ex(makeWriterListener(out1State), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0 ||
            zOut2Dw.set_listener_ex(makeWriterListener(out2State), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0)
        {
            System.err.println("FAIL: set_listener_ex (writer) failed");
            System.exit(1);
        }

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReader inDr = sub.create_datareader(inTopic, drQos, null, 0);
        if (inDr == null) {
            System.err.println("FAIL: create_datareader(SessionIn) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: SessionIn");

        // Exercise CFT-collateral cleanup under the cascade -- this project
        // has a real CFT bug history (see docs/decisions.md). Trivial
        // filter: just needs to exist and be attached, not to actually
        // narrow anything.
        Dcps.DDS.ContentFilteredTopic cft = dp.create_contentfilteredtopic("SessionIn_cft", inTopic, "seq >= 0", Collections.emptyList());
        if (cft == null) {
            System.err.println("FAIL: create_contentfilteredtopic() failed");
            System.exit(1);
        }
        Dcps.DDS.DataReader cftDr = sub.create_datareader(cft, drQos, null, 0);
        if (cftDr == null) {
            System.err.println("FAIL: create_datareader(SessionIn_cft) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: SessionIn_cft");

        Dcps.DDS.DataReaderListener readerListener = makeReaderListener();
        if (inDr.set_listener(readerListener, Dcps.DDS.SUBSCRIPTION_MATCHED_STATUS.value) != 0 ||
            cftDr.set_listener(readerListener, Dcps.DDS.SUBSCRIPTION_MATCHED_STATUS.value) != 0)
        {
            System.err.println("FAIL: set_listener (reader) failed");
            System.exit(1);
        }

        Dcps.DDS.WaitSet ws = (Dcps.DDS.WaitSet) io.zzdds.runtime.ZzddsRuntime.createWaitSet();
        if (ws == null) {
            System.err.println("FAIL: createWaitSet() failed");
            System.exit(1);
        }
        Dcps.DDS.ReadCondition inRc = inDr.create_readcondition(
            Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        if (inRc == null) {
            System.err.println("FAIL: create_readcondition() failed");
            System.exit(1);
        }
        if (ws.attach_condition(inRc) != 0) {
            System.err.println("FAIL: attach_condition() failed");
            System.exit(1);
        }

        SessionEventDataWriter out1Writer = new SessionEventDataWriter(out1Dw);
        SessionEventDataWriter out2Writer = new SessionEventDataWriter(out2Dw);
        SessionEventDataReader inReader = new SessionEventDataReader(inDr);

        // Gate writes on the peer's reader actually being registered, not
        // just matched -- see docs/design/integration-test-tier.md's
        // raw-loan/coherent-sets precedent and this project's
        // on_reliable_reader_ready work: matched-count alone (SEDP
        // discovery) does not imply the remote RELIABLE reader proxy has
        // registered this writer yet.
        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!(out1State.readerReady.get() && out2State.readerReady.get())) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Session_event.SessionEvent ev = new Session_event.SessionEvent();
            ev.set_seq(seq);
            if (out1Writer.write(ev, 0L) != 0 || out2Writer.write(ev, 0L) != 0) {
                System.err.println("FAIL: write() failed at seq=" + seq);
                System.exit(1);
            }
        }
        System.out.println("Session: wrote " + SAMPLE_COUNT + " samples on SessionOut1/SessionOut2");

        int received = 0;
        Dcps.DDS.Duration_t waitStep = new Dcps.DDS.Duration_t();
        waitStep.set_sec(WAIT_STEP_SEC);
        waitStep.set_nanosec(0);
        int waitedMs = 0;
        while (received < RECEIVE_TARGET) {
            if (waitedMs >= RECEIVE_TIMEOUT_MS) {
                System.err.println("FAIL: session did not receive from peer within " + (RECEIVE_TIMEOUT_MS / 1000) + "s (got " + received + ")");
                System.exit(1);
            }
            java.util.ArrayList<Dcps.DDS.Condition> active = new java.util.ArrayList<>();
            int wr = ws.wait(active, waitStep);
            if (wr == Dcps.DDS.RETCODE_TIMEOUT.value) {
                waitedMs += WAIT_STEP_SEC * 1000;
                continue;
            }
            if (wr != 0) {
                System.err.println("FAIL: WaitSet.wait() returned " + wr);
                System.exit(1);
            }
            SessionEventDataReader.Sample[] samples = inReader.take_n(
                SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (SessionEventDataReader.Sample s : samples) {
                if (s.validData) received++;
            }
        }
        System.out.println("Session: received " + received + " samples from peer.");

        // The core test: tear the whole tree down in one shot instead of
        // deleting out1Dw/out2Dw/inDr/cftDr/cft one at a time.
        tornDown.set(true);

        int rc1 = dp.delete_contained_entities();
        if (rc1 != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: delete_contained_entities() returned " + rc1 + ", expected RETCODE_OK");
            System.exit(1);
        }

        int rc2 = factory.delete_participant(dp);
        if (rc2 != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: delete_participant() returned " + rc2 + " after delete_contained_entities -- cascade left something dangling");
            System.exit(1);
        }

        System.out.println("Session: torn down via delete_contained_entities.");
    }
}
