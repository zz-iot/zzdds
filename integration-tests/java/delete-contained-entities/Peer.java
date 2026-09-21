// integration-tests/java/delete-contained-entities -- peer. Direct Java
// port of c/delete-contained-entities/src/peer.c -- see that file's header
// comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:" x3, "Create writer for topic:",
// "Create reader for topic:" x2, "Peer: session disconnected cleanly."
// Any failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Peer {
    static final int SAMPLE_COUNT = 5;
    static final int RECEIVE_TARGET = 2;
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int RECEIVE_TIMEOUT_MS = 20000;
    static final int DISCONNECT_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    static class MatchState {
        final AtomicBoolean everMatched = new AtomicBoolean(false);
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);
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

    static Zzdds.zzdds.DataWriterListenerEx makeWriterListener(MatchState state) {
        return new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) state.everMatched.set(true);
            }

            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) state.readerReady.set(true);
            }
        };
    }

    static Dcps.DDS.DataReaderListener makeReaderListener(MatchState state) {
        return new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {
                state.matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) state.everMatched.set(true);
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
        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (pub == null || sub == null) {
            System.err.println("FAIL: create_publisher/create_subscriber failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter inDw = pub.create_datawriter(inTopic, dwQos, null, 0);
        if (inDw == null) {
            System.err.println("FAIL: create_datawriter(SessionIn) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: SessionIn");

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReader out1Dr = sub.create_datareader(out1Topic, drQos, null, 0);
        Dcps.DDS.DataReader out2Dr = sub.create_datareader(out2Topic, drQos, null, 0);
        if (out1Dr == null || out2Dr == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: SessionOut1");
        System.out.println("Create reader for topic: SessionOut2");

        MatchState writerState = new MatchState();
        MatchState out1State = new MatchState();
        MatchState out2State = new MatchState();

        Zzdds.zzdds.DataWriter zInDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(inDw);
        if (zInDw == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }
        if (zInDw.set_listener_ex(makeWriterListener(writerState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener_ex (writer) failed");
            System.exit(1);
        }
        if (out1Dr.set_listener(makeReaderListener(out1State), Dcps.DDS.SUBSCRIPTION_MATCHED_STATUS.value) != 0 ||
            out2Dr.set_listener(makeReaderListener(out2State), Dcps.DDS.SUBSCRIPTION_MATCHED_STATUS.value) != 0)
        {
            System.err.println("FAIL: set_listener (reader) failed");
            System.exit(1);
        }

        SessionEventDataWriter inWriter = new SessionEventDataWriter(inDw);
        SessionEventDataReader out1Reader = new SessionEventDataReader(out1Dr);
        SessionEventDataReader out2Reader = new SessionEventDataReader(out2Dr);

        // Gate on the session's reader actually being registered, not just
        // matched -- see Session.java's matching comment for why.
        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!writerState.readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Session_event.SessionEvent ev = new Session_event.SessionEvent();
            ev.set_seq(seq);
            if (inWriter.write(ev, 0L) != 0) {
                System.err.println("FAIL: write() failed at seq=" + seq);
                System.exit(1);
            }
        }
        System.out.println("Peer: wrote " + SAMPLE_COUNT + " samples on SessionIn");

        int received1 = 0, received2 = 0;
        long waitDeadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (received1 < RECEIVE_TARGET || received2 < RECEIVE_TARGET) {
            if (System.currentTimeMillis() > waitDeadline) {
                System.err.println("FAIL: peer did not receive from session within " + (RECEIVE_TIMEOUT_MS / 1000)
                    + "s (out1=" + received1 + " out2=" + received2 + ")");
                System.exit(1);
            }
            SessionEventDataReader.Sample[] s1 = out1Reader.take_n(
                SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (SessionEventDataReader.Sample s : s1) if (s.validData) received1++;
            SessionEventDataReader.Sample[] s2 = out2Reader.take_n(
                SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (SessionEventDataReader.Sample s : s2) if (s.validData) received2++;
            if (received1 < RECEIVE_TARGET || received2 < RECEIVE_TARGET) Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Peer: received from session (out1=" + received1 + " out2=" + received2 + ").");

        deadline = System.currentTimeMillis() + DISCONNECT_TIMEOUT_MS;
        while (!(writerState.everMatched.get() && writerState.matchedCurrentCount.get() == 0 &&
                 out1State.everMatched.get() && out1State.matchedCurrentCount.get() == 0 &&
                 out2State.everMatched.get() && out2State.matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: peer never saw a clean disconnect within " + (DISCONNECT_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Peer: session disconnected cleanly.");

        dp.delete_contained_entities();
        factory.delete_participant(dp);
    }
}
