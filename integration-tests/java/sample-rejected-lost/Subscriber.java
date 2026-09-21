// integration-tests/java/sample-rejected-lost -- subscriber. Direct Java
// port of c/sample-rejected-lost/src/subscriber.c -- see that file's header
// comment for the full scenario rationale and
// docs/design/integration-test-tier.md for the scenario spec.
//
// Required stdout markers: "Create topic:" x3, "Create reader for topic:"
// x3, "Subscriber: sample_rejected confirmed (count=N, buffered=M).",
// "Subscriber: sample_lost confirmed (count=N, last seq=N).", "Subscriber:
// SAMPLE_REJECTED/SAMPLE_LOST both verified." Any failure path prints a
// line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

public class Subscriber {
    static final int SYNC_TIMEOUT_MS = 20000;
    static final int STATUS_TIMEOUT_MS = 20000;
    static final int POLL_PERIOD_MS = 20;
    static final int MAX_SAMPLES = 8;

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

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos rejectedQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(rejectedQos);
        rejectedQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        rejectedQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        rejectedQos.get_resource_limits().set_max_samples(3);
        rejectedQos.get_resource_limits().set_max_instances(1);
        rejectedQos.get_resource_limits().set_max_samples_per_instance(3);
        Dcps.DDS.DataReader rejectedDr = sub.create_datareader(rejectedTopic, rejectedQos, null, 0);
        if (rejectedDr == null) {
            System.err.println("FAIL: create_datareader(RejectedTopic) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: RejectedTopic");

        Dcps.DDS.DataReaderQos syncQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(syncQos);
        syncQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        Dcps.DDS.DataReader syncDr = sub.create_datareader(syncTopic, syncQos, null, 0);
        if (syncDr == null) {
            System.err.println("FAIL: create_datareader(SyncTopic) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: SyncTopic");

        StatusEventDataReader rejectedReader = new StatusEventDataReader(rejectedDr);
        StatusEventDataReader syncReader = new StatusEventDataReader(syncDr);

        // Gate: don't create the LostTopic reader, or check RejectedTopic's
        // final status, until the publisher has genuinely finished writing
        // everything (it writes Sync last).
        {
            boolean gotSync = false;
            long deadline = System.currentTimeMillis() + SYNC_TIMEOUT_MS;
            while (!gotSync) {
                if (System.currentTimeMillis() > deadline) {
                    System.err.println("FAIL: sync sample never arrived within " + (SYNC_TIMEOUT_MS / 1000) + "s");
                    System.exit(1);
                }
                StatusEventDataReader.Sample[] s = syncReader.take_n(
                    MAX_SAMPLES, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
                if (s.length > 0) gotSync = true;
                else Thread.sleep(POLL_PERIOD_MS);
            }
        }

        Dcps.DDS.DataReaderQos lostQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(lostQos);
        lostQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        lostQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
        lostQos.get_history().set_depth(1);
        lostQos.get_durability().set_kind(Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS);
        Dcps.DDS.DataReader lostDr = sub.create_datareader(lostTopic, lostQos, null, 0);
        if (lostDr == null) {
            System.err.println("FAIL: create_datareader(LostTopic) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: LostTopic");
        StatusEventDataReader lostReader = new StatusEventDataReader(lostDr);

        // RejectedTopic: deliberately never drained until now. Confirm
        // rejection happened, then take whatever made it through.
        Dcps.DDS.SampleRejectedStatus rejectedStatus = new Dcps.DDS.SampleRejectedStatus();
        {
            long deadline = System.currentTimeMillis() + STATUS_TIMEOUT_MS;
            while (true) {
                if (rejectedDr.get_sample_rejected_status(rejectedStatus) != Dcps.DDS.RETCODE_OK.value) {
                    System.err.println("FAIL: get_sample_rejected_status() failed");
                    System.exit(1);
                }
                if (rejectedStatus.get_total_count() > 0) break;
                if (System.currentTimeMillis() > deadline) {
                    System.err.println("FAIL: no sample ever rejected on RejectedTopic within " + (STATUS_TIMEOUT_MS / 1000) + "s");
                    System.exit(1);
                }
                Thread.sleep(POLL_PERIOD_MS);
            }
        }
        StatusEventDataReader.Sample[] rejectedTaken = rejectedReader.take_n(
            MAX_SAMPLES, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        // Count-conservation invariant, not a hardcoded exact split -- see
        // docs/decisions.md's dds-rtps CoherentSets flake history for why
        // this project avoids asserting exact counts where a property
        // suffices.
        int rejectedTotal = rejectedStatus.get_total_count() + rejectedTaken.length;
        if (rejectedTotal != 5) {
            System.err.println("FAIL: RejectedTopic count mismatch -- rejected=" + rejectedStatus.get_total_count()
                + " buffered=" + rejectedTaken.length + " total=" + rejectedTotal + ", expected 5");
            System.exit(1);
        }
        if (rejectedTaken.length == 0) {
            System.err.println("FAIL: RejectedTopic: nothing was ever successfully buffered (rejected everything)");
            System.exit(1);
        }
        System.out.println("Subscriber: sample_rejected confirmed (count=" + rejectedStatus.get_total_count()
            + ", buffered=" + rejectedTaken.length + ").");

        // LostTopic: confirm loss happened, then take whatever remains and
        // confirm the writer's LAST value survived.
        Dcps.DDS.SampleLostStatus lostStatus = new Dcps.DDS.SampleLostStatus();
        {
            long deadline = System.currentTimeMillis() + STATUS_TIMEOUT_MS;
            while (true) {
                if (lostDr.get_sample_lost_status(lostStatus) != Dcps.DDS.RETCODE_OK.value) {
                    System.err.println("FAIL: get_sample_lost_status() failed");
                    System.exit(1);
                }
                if (lostStatus.get_total_count() > 0) break;
                if (System.currentTimeMillis() > deadline) {
                    System.err.println("FAIL: no sample ever lost on LostTopic within " + (STATUS_TIMEOUT_MS / 1000) + "s");
                    System.exit(1);
                }
                Thread.sleep(POLL_PERIOD_MS);
            }
        }
        StatusEventDataReader.Sample[] lostTaken = lostReader.take_n(
            MAX_SAMPLES, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        int maxSeq = -1;
        for (StatusEventDataReader.Sample s : lostTaken) {
            if (s.validData && s.data.get_seq() > maxSeq) maxSeq = s.data.get_seq();
        }
        if (maxSeq != 4) {
            System.err.println("FAIL: LostTopic did not deliver the writer's last sample (seq=4) -- last seen=" + maxSeq);
            System.exit(1);
        }
        System.out.println("Subscriber: sample_lost confirmed (count=" + lostStatus.get_total_count() + ", last seq=" + maxSeq + ").");

        System.out.println("Subscriber: SAMPLE_REJECTED/SAMPLE_LOST both verified.");
    }
}
