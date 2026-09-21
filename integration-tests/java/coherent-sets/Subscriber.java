// integration-tests/java/coherent-sets -- subscriber. Direct Java port of
// c/coherent-sets/src/subscriber.c -- see that file's header comment for
// the full atomicity-assertion rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:" x2, "Create reader for topic:"
// x2, "Subscriber: group N paired (position+velocity).", "Subscriber:
// received all 20 groups, atomic and ordered." Any failure path prints a
// line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.ArrayList;
import java.util.List;

public class Subscriber {
    static final int GROUP_COUNT = 20;
    static final int WAIT_STEP_SEC = 1;
    static final int OVERALL_DEADLINE_MS = 30000;

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

        Dcps.DDS.SubscriberQos subQos = new Dcps.DDS.SubscriberQos();
        subQos.get_presentation().set_access_scope(Dcps.DDS.PresentationQosPolicyAccessScopeKind.GROUP_PRESENTATION_QOS);
        subQos.get_presentation().set_coherent_access(true);
        subQos.get_presentation().set_ordered_access(true);

        Dcps.DDS.Subscriber sub = dp.create_subscriber(subQos, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReader positionDr = sub.create_datareader(positionTopic, drQos, null, 0);
        if (positionDr == null) {
            System.err.println("FAIL: create_datareader(Position) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: Position");

        Dcps.DDS.DataReader velocityDr = sub.create_datareader(velocityTopic, drQos, null, 0);
        if (velocityDr == null) {
            System.err.println("FAIL: create_datareader(Velocity) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: Velocity");

        PositionDataReader positionReader = new PositionDataReader(positionDr);
        VelocityDataReader velocityReader = new VelocityDataReader(velocityDr);

        Dcps.DDS.WaitSet ws = (Dcps.DDS.WaitSet) io.zzdds.runtime.ZzddsRuntime.createWaitSet();
        if (ws == null) {
            System.err.println("FAIL: createWaitSet() failed");
            System.exit(1);
        }

        Dcps.DDS.ReadCondition positionRc = positionDr.create_readcondition(
            Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        Dcps.DDS.ReadCondition velocityRc = velocityDr.create_readcondition(
            Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        if (positionRc == null || velocityRc == null) {
            System.err.println("FAIL: create_readcondition() failed");
            System.exit(1);
        }
        if (ws.attach_condition(positionRc) != 0 || ws.attach_condition(velocityRc) != 0) {
            System.err.println("FAIL: attach_condition() failed");
            System.exit(1);
        }

        List<Integer> positionOrder = new ArrayList<>();
        List<Integer> velocityOrder = new ArrayList<>();

        Dcps.DDS.Duration_t waitStep = new Dcps.DDS.Duration_t();
        waitStep.set_sec(WAIT_STEP_SEC);
        waitStep.set_nanosec(0);

        int overallWaitedMs = 0;
        while (positionOrder.size() < GROUP_COUNT || velocityOrder.size() < GROUP_COUNT) {
            if (overallWaitedMs >= OVERALL_DEADLINE_MS) {
                System.err.println("FAIL: only received position=" + positionOrder.size() + " velocity=" + velocityOrder.size()
                    + "/" + GROUP_COUNT + " within " + (OVERALL_DEADLINE_MS / 1000) + "s");
                System.exit(1);
            }

            ArrayList<Dcps.DDS.Condition> active = new ArrayList<>();
            int wr = ws.wait(active, waitStep);
            if (wr == Dcps.DDS.RETCODE_TIMEOUT.value) {
                overallWaitedMs += WAIT_STEP_SEC * 1000;
                continue;
            }
            if (wr != 0) {
                System.err.println("FAIL: WaitSet.wait() returned " + wr);
                System.exit(1);
            }

            if (sub.begin_access() != 0) {
                System.err.println("FAIL: begin_access() failed");
                System.exit(1);
            }

            PositionDataReader.Sample[] positionSamples = positionReader.take_n(
                GROUP_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (PositionDataReader.Sample s : positionSamples) {
                if (!s.validData) continue;
                positionOrder.add(s.data.get_group_id());
            }

            VelocityDataReader.Sample[] velocitySamples = velocityReader.take_n(
                GROUP_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (VelocityDataReader.Sample s : velocitySamples) {
                if (!s.validData) continue;
                velocityOrder.add(s.data.get_group_id());
            }

            if (sub.end_access() != 0) {
                System.err.println("FAIL: end_access() failed");
                System.exit(1);
            }

            // The core atomicity assertion -- see c/coherent-sets/src/subscriber.c's header comment.
            if (positionOrder.size() != velocityOrder.size()) {
                System.err.println("FAIL: atomicity violated -- position and velocity readers diverged after an access bracket "
                    + "(position count=" + positionOrder.size() + " velocity count=" + velocityOrder.size()
                    + ") -- a group became visible on one reader without its pair");
                System.exit(1);
            }
            for (int i = 0; i < positionOrder.size(); i++) {
                if (!positionOrder.get(i).equals(velocityOrder.get(i))) {
                    System.err.println("FAIL: atomicity violated at index " + i + " -- position group_id=" + positionOrder.get(i)
                        + " but velocity group_id=" + velocityOrder.get(i));
                    System.exit(1);
                }
            }
            if (!positionOrder.isEmpty()) {
                System.out.println("Subscriber: group " + positionOrder.get(positionOrder.size() - 1) + " paired (position+velocity).");
            }
        }

        for (int i = 0; i < GROUP_COUNT; i++) {
            if (positionOrder.get(i) != i || velocityOrder.get(i) != i) {
                System.err.println("FAIL: ordered_access violated at index " + i + " -- expected group_id=" + i
                    + ", got position=" + positionOrder.get(i) + " velocity=" + velocityOrder.get(i));
                System.exit(1);
            }
        }

        System.out.println("Subscriber: received all " + GROUP_COUNT + " groups, atomic and ordered.");

        ws.detach_condition(positionRc);
        ws.detach_condition(velocityRc);
        positionDr.delete_readcondition(positionRc);
        velocityDr.delete_readcondition(velocityRc);
        sub.delete_datareader(positionDr);
        sub.delete_datareader(velocityDr);
    }
}
