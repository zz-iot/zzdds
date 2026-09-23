// integration-tests/java/ignore-entities -- peer. Direct Java port of
// c/ignore-entities/src/peer.c -- see that file's header comment for the
// full scenario rationale and docs/design/integration-test-tier.md for the
// scenario spec.
//
// Required stdout markers: "Peer: ready.", "Peer: SubscriptionIgnoredTopic
// reader received zero samples from the real (post-ignore) writer.", "Peer:
// done." Any failure path prints a line starting "FAIL:" and exits
// nonzero.

import io.zzdds.dcps.Dcps;

public class Peer {
    static final int SAMPLE_COUNT = 5;
    static final int SETTLE_WINDOW_MS = 6000;
    static final int MATCH_TIMEOUT_MS = 20000;
    static final int DRAIN_TIMEOUT_MS = 15000;
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

        if (IgnoreEventTypeSupport.register(dp, "IgnoreEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic controlTopic = dp.create_topic("ControlTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic topicIgnoredTopic = dp.create_topic("TopicIgnoredTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic pubIgnoredTopic = dp.create_topic("PublicationIgnoredTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic subIgnoredTopic = dp.create_topic("SubscriptionIgnoredTopic", "IgnoreEvent", null, null, 0);
        if (controlTopic == null || topicIgnoredTopic == null || pubIgnoredTopic == null || subIgnoredTopic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }

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

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter controlDw = pub.create_datawriter(controlTopic, dwQos, null, 0);
        Dcps.DDS.DataWriter topicIgnoredDw = pub.create_datawriter(topicIgnoredTopic, dwQos, null, 0);
        Dcps.DDS.DataWriter pubIgnoredDw = pub.create_datawriter(pubIgnoredTopic, dwQos, null, 0);
        Dcps.DDS.DataReader subIgnoredDr = sub.create_datareader(subIgnoredTopic, drQos, null, 0);
        if (controlDw == null || topicIgnoredDw == null || pubIgnoredDw == null || subIgnoredDr == null) {
            System.err.println("FAIL: create_datawriter()/create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Peer: ready.");

        // Write a few samples on TopicIgnoredTopic and PublicationIgnoredTopic
        // right away -- both writers exist continuously from here on, giving
        // the ignorer's readers every real opportunity to (wrongly) match.
        IgnoreEventDataWriter topicIgnoredWriter = new IgnoreEventDataWriter(topicIgnoredDw);
        IgnoreEventDataWriter pubIgnoredWriter = new IgnoreEventDataWriter(pubIgnoredDw);
        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Ignore_event.IgnoreEvent ev = new Ignore_event.IgnoreEvent();
            ev.set_seq(seq);
            topicIgnoredWriter.write(ev, 0L);
            pubIgnoredWriter.write(ev, 0L);
        }

        // Let the ignorer's full choreography (participant-discover-and-ignore,
        // publication probe-then-ignore, subscription probe-then-ignore) run
        // to completion. No assertion on topicIgnoredDw's or pubIgnoredDw's
        // own match-count here -- see this file's header comment for why
        // that would be asserting something ignore_topic()/ignore_publication()
        // never promised.
        Thread.sleep(SETTLE_WINDOW_MS);

        // The one thing this process's own side CAN verify: ignore_subscription()
        // was called on ignorer's *writer* participant, so its real
        // (post-ignore) writer never adds this reader as a matched proxy --
        // meaning this reader, however its own SEDP match status reports
        // itself, must never actually receive any of that writer's samples.
        IgnoreEventDataReader subIgnoredReader = new IgnoreEventDataReader(subIgnoredDr);
        IgnoreEventDataReader.Sample[] samples = subIgnoredReader.take_n(
            SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        int takenCount = 0;
        for (IgnoreEventDataReader.Sample s : samples) {
            if (s.validData) takenCount++;
        }
        if (takenCount != 0) {
            System.err.println("FAIL: SubscriptionIgnoredTopic reader received " + takenCount + " samples, expected 0");
            System.exit(1);
        }
        System.out.println("Peer: SubscriptionIgnoredTopic reader received zero samples from the real (post-ignore) writer.");

        // Normal ControlTopic round-trip, matching every other scenario's
        // sanity-check convention.
        Dcps.DDS.PublicationMatchedStatus controlStatus = new Dcps.DDS.PublicationMatchedStatus();
        boolean controlMatched = false;
        long deadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (!controlMatched) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: ControlTopic writer never matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            if (controlDw.get_publication_matched_status(controlStatus) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_publication_matched_status(control) failed");
                System.exit(1);
            }
            if (controlStatus.get_current_count() > 0) {
                controlMatched = true;
            } else {
                Thread.sleep(POLL_PERIOD_MS);
            }
        }

        IgnoreEventDataWriter controlWriter = new IgnoreEventDataWriter(controlDw);
        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Ignore_event.IgnoreEvent ev = new Ignore_event.IgnoreEvent();
            ev.set_seq(seq);
            if (controlWriter.write(ev, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write(ControlTopic) failed at seq=" + seq);
                System.exit(1);
            }
        }

        // Standard teardown-safety: wait for the ignorer to disconnect
        // before deleting, matching every other scenario's precedent.
        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (true) {
            if (controlDw.get_publication_matched_status(controlStatus) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_publication_matched_status(control) failed");
                System.exit(1);
            }
            if (controlStatus.get_current_count() == 0) break;
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: ignorer did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Peer: done.");
        factory.delete_participant(dp);
    }
}
