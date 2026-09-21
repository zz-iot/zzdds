// integration-tests/java/coherent-sets -- publisher. Direct Java port of
// c/coherent-sets/src/publisher.c; see
// docs/design/integration-test-tier.md for the full scenario spec.
//
// Required stdout markers: "Create topic:" x2, "Create writer for topic:"
// x2, "Publisher: wrote group N", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int GROUP_COUNT = 20;
    static final int WRITE_GAP_MS = 8;
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

        if (PositionTypeSupport.register(dp, "Position") != 0) {
            System.err.println("FAIL: register PositionTypeSupport failed");
            System.exit(1);
        }
        if (VelocityTypeSupport.register(dp, "Velocity") != 0) {
            System.err.println("FAIL: register VelocityTypeSupport failed");
            System.exit(1);
        }

        Dcps.DDS.Topic positionTopic = dp.create_topic("Position", "Position", null, null, 0);
        if (positionTopic == null) {
            System.err.println("FAIL: create_topic(Position) failed");
            System.exit(1);
        }
        System.out.println("Create topic: Position");

        Dcps.DDS.Topic velocityTopic = dp.create_topic("Velocity", "Velocity", null, null, 0);
        if (velocityTopic == null) {
            System.err.println("FAIL: create_topic(Velocity) failed");
            System.exit(1);
        }
        System.out.println("Create topic: Velocity");

        Dcps.DDS.PublisherQos pubQos = new Dcps.DDS.PublisherQos();
        pubQos.get_presentation().set_access_scope(Dcps.DDS.PresentationQosPolicyAccessScopeKind.GROUP_PRESENTATION_QOS);
        pubQos.get_presentation().set_coherent_access(true);
        pubQos.get_presentation().set_ordered_access(true);

        Dcps.DDS.Publisher pub = dp.create_publisher(pubQos, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter positionDw = pub.create_datawriter(positionTopic, dwQos, null, 0);
        if (positionDw == null) {
            System.err.println("FAIL: create_datawriter(Position) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: Position");

        Dcps.DDS.DataWriter velocityDw = pub.create_datawriter(velocityTopic, dwQos, null, 0);
        if (velocityDw == null) {
            System.err.println("FAIL: create_datawriter(Velocity) failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: Velocity");

        WriterSyncState positionState = new WriterSyncState();
        WriterSyncState velocityState = new WriterSyncState();

        Zzdds.zzdds.DataWriter zPositionDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(positionDw);
        Zzdds.zzdds.DataWriter zVelocityDw = (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(velocityDw);
        if (zPositionDw == null || zVelocityDw == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }
        if (zPositionDw.set_listener_ex(makeListener(positionState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0 ||
            zVelocityDw.set_listener_ex(makeListener(velocityState), Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0)
        {
            System.err.println("FAIL: set_listener_ex failed");
            System.exit(1);
        }

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!(positionState.readerReady.get() && velocityState.readerReady.get())) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        PositionDataWriter positionWriter = new PositionDataWriter(positionDw);
        VelocityDataWriter velocityWriter = new VelocityDataWriter(velocityDw);

        for (int groupId = 0; groupId < GROUP_COUNT; groupId++) {
            if (pub.begin_coherent_changes() != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: begin_coherent_changes() failed at group=" + groupId);
                System.exit(1);
            }

            Pose_group.Position pos = new Pose_group.Position();
            pos.set_group_id(groupId);
            pos.set_x((double) groupId);
            pos.set_y((double) groupId * 2.0);
            if (positionWriter.write(pos, 0L) != 0) {
                System.err.println("FAIL: Position write() failed at group=" + groupId);
                System.exit(1);
            }

            // Deliberate gap -- see c/coherent-sets/src/publisher.c's matching comment.
            Thread.sleep(WRITE_GAP_MS);

            Pose_group.Velocity vel = new Pose_group.Velocity();
            vel.set_group_id(groupId);
            vel.set_vx((double) groupId * 0.5);
            vel.set_vy((double) groupId * 1.5);
            if (velocityWriter.write(vel, 0L) != 0) {
                System.err.println("FAIL: Velocity write() failed at group=" + groupId);
                System.exit(1);
            }

            if (pub.end_coherent_changes() != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: end_coherent_changes() failed at group=" + groupId);
                System.exit(1);
            }
            System.out.println("Publisher: wrote group " + groupId);
        }

        System.out.println("Publisher: done.");

        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (!(positionState.everMatched.get() && positionState.matchedCurrentCount.get() == 0 &&
                 velocityState.everMatched.get() && velocityState.matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        if (pub.delete_datawriter(positionDw) != Dcps.DDS.RETCODE_OK.value ||
            pub.delete_datawriter(velocityDw) != Dcps.DDS.RETCODE_OK.value)
        {
            System.err.println("FAIL: delete_datawriter() did not return RETCODE_OK");
            System.exit(1);
        }
    }
}
