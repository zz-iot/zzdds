// integration-tests/java/sample-rejected-lost -- publisher. Direct Java
// port of c/sample-rejected-lost/src/publisher.c -- see that file's header
// comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:" x3, "Create writer for topic:"
// x3, "Publisher: wrote 5 samples on LostTopic...", "Publisher: wrote 5
// samples on RejectedTopic...", "Publisher: sync sent.", "Publisher: done."
// Any failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    static class WriterSyncState {
        final AtomicBoolean readerReady = new AtomicBoolean(false);
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

    static Zzdds.zzdds.DataWriterListenerEx makeListener(WriterSyncState state) {
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

        if (StatusEventTypeSupport.register(dp, "StatusEvent") != 0) {
            System.err.println("FAIL: register StatusEventTypeSupport failed");
            System.exit(1);
        }

        Dcps.DDS.Topic rejectedTopic = dp.create_topic("RejectedTopic", "StatusEvent", null, null, 0);
        Dcps.DDS.Topic lostTopic = dp.create_topic("LostTopic", "StatusEvent", null, null, 0);
        Dcps.DDS.Topic syncTopic = dp.create_topic("SyncTopic", "StatusEvent", null, null, 0);
        if (rejectedTopic == null || lostTopic == null || syncTopic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: RejectedTopic");
        System.out.println("Create topic: LostTopic");
        System.out.println("Create topic: SyncTopic");

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        // LostTopic FIRST, deliberately before any reader can possibly be
        // matched -- see the file header comment.
        Dcps.DDS.DataWriterQos lostQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(lostQos);
        lostQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        lostQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
        lostQos.get_history().set_depth(1);
        // TRANSIENT_LOCAL so the late-joining reader can still receive
        // whatever remains in the writer's cache (the seq=4 sample) --
        // VOLATILE (the default) would make it miss ALL 5 samples, not just
        // the 4 evicted ones. Eviction (and therefore loss of seq 0-3)
        // still happens regardless of durability.
        lostQos.get_durability().set_kind(Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS);

        Dcps.DDS.DataWriter lostDw = pub.create_datawriter(lostTopic, lostQos, null, 0);
        if (lostDw == null) {
            System.err.println("FAIL: create_datawriter(LostTopic) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: LostTopic");

        StatusEventDataWriter lostWriter = new StatusEventDataWriter(lostDw);
        for (int seq = 0; seq < 5; seq++) {
            Status_event.StatusEvent ev = new Status_event.StatusEvent();
            ev.set_seq(seq);
            if (lostWriter.write(ev, 0L) != 0) {
                System.err.println("FAIL: LostTopic write() failed at seq=" + seq);
                System.exit(1);
            }
        }
        System.out.println("Publisher: wrote 5 samples on LostTopic (KEEP_LAST depth=1, no reader matched yet).");

        Dcps.DDS.DataWriterQos rejectedQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(rejectedQos);
        rejectedQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        rejectedQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        Dcps.DDS.DataWriter rejectedDw = pub.create_datawriter(rejectedTopic, rejectedQos, null, 0);
        if (rejectedDw == null) {
            System.err.println("FAIL: create_datawriter(RejectedTopic) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: RejectedTopic");

        Dcps.DDS.DataWriterQos syncQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(syncQos);
        syncQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        Dcps.DDS.DataWriter syncDw = pub.create_datawriter(syncTopic, syncQos, null, 0);
        if (syncDw == null) {
            System.err.println("FAIL: create_datawriter(SyncTopic) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: SyncTopic");

        WriterSyncState rejectedState = new WriterSyncState();
        WriterSyncState syncState = new WriterSyncState();
        WriterSyncState lostState = new WriterSyncState();

        Zzdds.zzdds.DataWriter zRejectedDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(rejectedDw);
        Zzdds.zzdds.DataWriter zSyncDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(syncDw);
        Zzdds.zzdds.DataWriter zLostDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(lostDw);
        if (zRejectedDw == null || zSyncDw == null || zLostDw == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }
        if (zRejectedDw.set_listener_ex(makeListener(rejectedState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0 ||
            zSyncDw.set_listener_ex(makeListener(syncState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0 ||
            zLostDw.set_listener_ex(makeListener(lostState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0)
        {
            System.err.println("FAIL: set_listener_ex failed");
            System.exit(1);
        }

        // Only Rejected/Sync need to wait for their reader -- the
        // subscriber creates those two immediately at startup. LostTopic's
        // reader isn't created until the subscriber gets the Sync sample,
        // by design.
        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!(rejectedState.readerReady.get() && syncState.readerReady.get())) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        StatusEventDataWriter rejectedWriter = new StatusEventDataWriter(rejectedDw);
        // The subscriber deliberately does not drain RejectedTopic until it
        // has confirmed rejection happened, so no reader-side consumption
        // race is possible here regardless of exact write timing.
        for (int seq = 0; seq < 5; seq++) {
            Status_event.StatusEvent ev = new Status_event.StatusEvent();
            ev.set_seq(seq);
            if (rejectedWriter.write(ev, 0L) != 0) {
                System.err.println("FAIL: RejectedTopic write() failed at seq=" + seq);
                System.exit(1);
            }
        }
        System.out.println("Publisher: wrote 5 samples on RejectedTopic (up to 2 expected rejected).");

        StatusEventDataWriter syncWriter = new StatusEventDataWriter(syncDw);
        Status_event.StatusEvent syncEv = new Status_event.StatusEvent();
        syncEv.set_seq(0);
        if (syncWriter.write(syncEv, 0L) != 0) {
            System.err.println("FAIL: SyncTopic write() failed");
            System.exit(1);
        }
        System.out.println("Publisher: sync sent.");
        System.out.println("Publisher: done.");

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (!(rejectedState.everMatched.get() && rejectedState.matchedCurrentCount.get() == 0 &&
                 syncState.everMatched.get() && syncState.matchedCurrentCount.get() == 0 &&
                 lostState.everMatched.get() && lostState.matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        if (pub.delete_datawriter(rejectedDw) != Dcps.DDS.RETCODE_OK.value ||
            pub.delete_datawriter(lostDw) != Dcps.DDS.RETCODE_OK.value ||
            pub.delete_datawriter(syncDw) != Dcps.DDS.RETCODE_OK.value)
        {
            System.err.println("FAIL: delete_datawriter() did not return RETCODE_OK");
            System.exit(1);
        }
    }
}
