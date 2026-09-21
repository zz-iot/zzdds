// integration-tests/java/enable-defer -- peer. Direct Java port of
// c/enable-defer/src/peer.c -- see that file's header comment for the full
// scenario rationale and docs/design/integration-test-tier.md for the
// scenario spec.
//
// Required stdout markers: "Create topic: ConfigTopic", "Create reader for
// topic: ConfigTopic", "Peer: no premature match during Ns window.", "Peer:
// no premature match; matched and received cleanly after enable()." Any
// failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

public class Peer {
    static final int SAMPLE_TARGET = 5;
    static final int PREMATURE_CHECK_WINDOW_MS = 3000;
    static final int MATCH_TIMEOUT_MS = 30000;
    static final int RECEIVE_TIMEOUT_MS = 20000;
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

        if (ConfigEventTypeSupport.register(dp, "ConfigEvent") != 0) {
            System.err.println("FAIL: register ConfigEventTypeSupport failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("ConfigTopic", "ConfigEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic(ConfigTopic) failed");
            System.exit(1);
        }
        System.out.println("Create topic: ConfigTopic");

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataReader dr = sub.create_datareader(topic, drQos, null, 0);
        if (dr == null) {
            System.err.println("FAIL: create_datareader(ConfigTopic) failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: ConfigTopic");

        ConfigEventDataReader reader = new ConfigEventDataReader(dr);

        // Core assertion: for a window comfortably inside the configurer's
        // own pre-enable delay, matched-current-count must stay exactly 0 --
        // direct proof the deferred SEDP announcement genuinely never went
        // out while the configurer's writer was disabled.
        Dcps.DDS.SubscriptionMatchedStatus status = new Dcps.DDS.SubscriptionMatchedStatus();
        long deadline = System.currentTimeMillis() + PREMATURE_CHECK_WINDOW_MS;
        while (System.currentTimeMillis() < deadline) {
            if (dr.get_subscription_matched_status(status) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_subscription_matched_status() failed");
                System.exit(1);
            }
            if (status.get_current_count() != 0) {
                System.err.println("FAIL: matched before enable() was called -- deferred SEDP announcement isn't working (current_count=" + status.get_current_count() + ")");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Peer: no premature match during " + (PREMATURE_CHECK_WINDOW_MS / 1000) + "s window.");

        // Now wait normally for the real match, once the configurer enables.
        boolean matched = false;
        deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (!matched) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: never matched within " + (MATCH_TIMEOUT_MS / 1000) + "s of the premature-match window ending");
                System.exit(1);
            }
            if (dr.get_subscription_matched_status(status) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_subscription_matched_status() failed");
                System.exit(1);
            }
            if (status.get_current_count() > 0) {
                matched = true;
            } else {
                Thread.sleep(POLL_PERIOD_MS);
            }
        }

        int received = 0;
        int lastSeq = -1;
        deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (received < SAMPLE_TARGET) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: did not receive all " + SAMPLE_TARGET + " samples within " + (RECEIVE_TIMEOUT_MS / 1000) + "s (got " + received + ")");
                System.exit(1);
            }
            ConfigEventDataReader.Sample[] samples = reader.take_n(
                SAMPLE_TARGET, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (ConfigEventDataReader.Sample s : samples) {
                if (!s.validData) continue;
                if (s.data.get_seq() != lastSeq + 1) {
                    System.err.println("FAIL: out-of-order sample, expected seq=" + (lastSeq + 1) + " got seq=" + s.data.get_seq());
                    System.exit(1);
                }
                lastSeq = s.data.get_seq();
                received++;
            }
            if (received < SAMPLE_TARGET) Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Peer: no premature match; matched and received cleanly after enable().");
        factory.delete_participant(dp);
    }
}
