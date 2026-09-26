// integration-tests/java/ignore-entities -- ignorer. Direct Java port of
// c/ignore-entities/src/ignorer.c -- see that file's header comment for
// the full scenario rationale (why every assertion here lives on this side
// of the wire) and docs/design/integration-test-tier.md for the scenario
// spec.
//
// Required stdout markers: "Ignorer: ready for bystander.", "Ignorer:
// ignore_participant() applied to bystander.", "Ignorer:
// ignore_publication() applied via probe.", "Ignorer: ignore_subscription()
// applied via probe.", "Ignorer: all ignore checks passed.", "Ignorer:
// done." Any failure path prints a line starting "FAIL:" and exits
// nonzero.

import io.zzdds.dcps.Dcps;

import java.util.ArrayList;
import java.util.List;

public class Ignorer {
    static final int SAMPLE_COUNT = 5;
    static final int DISCOVER_BYSTANDER_TIMEOUT_MS = 15000;
    // 45s, not the 20s every other match-wait in this tier uses -- this
    // scenario's probe-match steps showed intermittent delays under this
    // suite's own CI/dev sandbox load that 20s didn't reliably clear; see
    // docs/roadmap.md.
    static final int PROBE_MATCH_TIMEOUT_MS = 45000;
    static final int SETTLE_WINDOW_MS = 3000;
    static final int MATCH_TIMEOUT_MS = 20000;
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

        if (IgnoreEventTypeSupport.register(dp, "IgnoreEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic controlTopic = dp.create_topic("ControlTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic topicIgnoredTopic = dp.create_topic("TopicIgnoredTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic pubIgnoredTopic = dp.create_topic("PublicationIgnoredTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic subIgnoredTopic = dp.create_topic("SubscriptionIgnoredTopic", "IgnoreEvent", null, null, 0);
        Dcps.DDS.Topic participantIgnoredTopic = dp.create_topic("ParticipantIgnoredTopic", "IgnoreEvent", null, null, 0);
        if (controlTopic == null || topicIgnoredTopic == null || pubIgnoredTopic == null
                || subIgnoredTopic == null || participantIgnoredTopic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }

        // -- ignore_topic(): local knowledge only, no peer needed yet. --
        int topicIgnoredHandle = topicIgnoredTopic.get_instance_handle();
        if (dp.ignore_topic(topicIgnoredHandle) != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: ignore_topic() failed");
            System.exit(1);
        }
        System.out.println("Ignorer: ignore_topic() applied to TopicIgnoredTopic.");

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
        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        // Reader created immediately after ignoring -- the writer it must
        // never match (peer's) doesn't exist yet at this point.
        Dcps.DDS.DataReader topicIgnoredDr = sub.create_datareader(topicIgnoredTopic, drQos, null, 0);
        // Harmless to create now, before ignore_participant() below -- the
        // participant-level guard blocks at first discovery regardless of
        // when this reader was created (see this file's header comment).
        Dcps.DDS.DataReader participantIgnoredDr = sub.create_datareader(participantIgnoredTopic, drQos, null, 0);
        Dcps.DDS.DataReader controlDr = sub.create_datareader(controlTopic, drQos, null, 0);
        if (topicIgnoredDr == null || participantIgnoredDr == null || controlDr == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }

        System.out.println("Ignorer: ready for bystander.");
        System.out.flush();

        // -- ignore_participant(): discover bystander's participant,
        // ignore it well within its own deliberate pre-writer delay. --
        boolean foundBystander = false;
        long deadline = System.currentTimeMillis() + DISCOVER_BYSTANDER_TIMEOUT_MS;
        while (!foundBystander) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: bystander's participant never appeared within " + (DISCOVER_BYSTANDER_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            List<Integer> handles = new ArrayList<>();
            dp.get_discovered_participants(handles);
            if (!handles.isEmpty()) {
                int rc = dp.ignore_participant(handles.get(0));
                if (rc != Dcps.DDS.RETCODE_OK.value) {
                    System.err.println("FAIL: ignore_participant() returned " + rc);
                    System.exit(1);
                }
                foundBystander = true;
            } else {
                Thread.sleep(POLL_PERIOD_MS);
            }
        }
        System.out.println("Ignorer: ignore_participant() applied to bystander.");

        // -- ignore_publication(): probe, learn peer's writer handle,
        // ignore, then prove a freshly-created reader never matches it. --
        {
            Dcps.DDS.DataReader probeDr = sub.create_datareader(pubIgnoredTopic, drQos, null, 0);
            if (probeDr == null) {
                System.err.println("FAIL: create_datareader(probe, PublicationIgnoredTopic) failed");
                System.exit(1);
            }
            Dcps.DDS.SubscriptionMatchedStatus status = new Dcps.DDS.SubscriptionMatchedStatus();
            boolean matched = false;
            long probeDeadline = System.currentTimeMillis() + PROBE_MATCH_TIMEOUT_MS;
            while (!matched) {
                if (System.currentTimeMillis() > probeDeadline) {
                    System.err.println("FAIL: probe reader never matched peer's PublicationIgnoredTopic writer within " + (PROBE_MATCH_TIMEOUT_MS / 1000) + "s");
                    System.exit(1);
                }
                if (probeDr.get_subscription_matched_status(status) != Dcps.DDS.RETCODE_OK.value) {
                    System.err.println("FAIL: get_subscription_matched_status(probe) failed");
                    System.exit(1);
                }
                if (status.get_current_count() > 0) matched = true; else Thread.sleep(POLL_PERIOD_MS);
            }

            List<Integer> pubHandles = new ArrayList<>();
            if (probeDr.get_matched_publications(pubHandles) != Dcps.DDS.RETCODE_OK.value || pubHandles.isEmpty()) {
                System.err.println("FAIL: get_matched_publications(probe) returned no handles");
                System.exit(1);
            }
            int writerHandle = pubHandles.get(0);
            if (dp.ignore_publication(writerHandle) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: ignore_publication() failed");
                System.exit(1);
            }
            sub.delete_datareader(probeDr);
            System.out.println("Ignorer: ignore_publication() applied via probe.");
        }
        Dcps.DDS.DataReader pubIgnoredDr = sub.create_datareader(pubIgnoredTopic, drQos, null, 0);
        if (pubIgnoredDr == null) {
            System.err.println("FAIL: create_datareader(real, PublicationIgnoredTopic) failed");
            System.exit(1);
        }

        // -- ignore_subscription(): probe, learn peer's reader handle,
        // ignore, then prove a freshly-created writer never matches it. --
        {
            Dcps.DDS.DataWriter probeDw = pub.create_datawriter(subIgnoredTopic, dwQos, null, 0);
            if (probeDw == null) {
                System.err.println("FAIL: create_datawriter(probe, SubscriptionIgnoredTopic) failed");
                System.exit(1);
            }
            Dcps.DDS.PublicationMatchedStatus status = new Dcps.DDS.PublicationMatchedStatus();
            boolean matched = false;
            long probeDeadline = System.currentTimeMillis() + PROBE_MATCH_TIMEOUT_MS;
            while (!matched) {
                if (System.currentTimeMillis() > probeDeadline) {
                    System.err.println("FAIL: probe writer never matched peer's SubscriptionIgnoredTopic reader within " + (PROBE_MATCH_TIMEOUT_MS / 1000) + "s");
                    System.exit(1);
                }
                if (probeDw.get_publication_matched_status(status) != Dcps.DDS.RETCODE_OK.value) {
                    System.err.println("FAIL: get_publication_matched_status(probe) failed");
                    System.exit(1);
                }
                if (status.get_current_count() > 0) matched = true; else Thread.sleep(POLL_PERIOD_MS);
            }

            List<Integer> subHandles = new ArrayList<>();
            if (probeDw.get_matched_subscriptions(subHandles) != Dcps.DDS.RETCODE_OK.value || subHandles.isEmpty()) {
                System.err.println("FAIL: get_matched_subscriptions(probe) returned no handles");
                System.exit(1);
            }
            int readerHandle = subHandles.get(0);
            if (dp.ignore_subscription(readerHandle) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: ignore_subscription() failed");
                System.exit(1);
            }
            pub.delete_datawriter(probeDw);
            System.out.println("Ignorer: ignore_subscription() applied via probe.");
        }
        Dcps.DDS.DataWriter subIgnoredDw = pub.create_datawriter(subIgnoredTopic, dwQos, null, 0);
        if (subIgnoredDw == null) {
            System.err.println("FAIL: create_datawriter(real, SubscriptionIgnoredTopic) failed");
            System.exit(1);
        }
        IgnoreEventDataWriter subIgnoredWriter = new IgnoreEventDataWriter(subIgnoredDw);
        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Ignore_event.IgnoreEvent ev = new Ignore_event.IgnoreEvent();
            ev.set_seq(seq);
            if (subIgnoredWriter.write(ev, 0L) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: write(SubscriptionIgnoredTopic) failed at seq=" + seq);
                System.exit(1);
            }
        }

        // Let everything settle: bystander's writer (created after its own
        // delay) gets a real chance to try (and fail) to announce; the
        // already-existing TopicIgnoredTopic writer gets a real chance to
        // try (and fail) to match the reader created above.
        Thread.sleep(SETTLE_WINDOW_MS);

        Dcps.DDS.SubscriptionMatchedStatus topicStatus = new Dcps.DDS.SubscriptionMatchedStatus();
        if (topicIgnoredDr.get_subscription_matched_status(topicStatus) != Dcps.DDS.RETCODE_OK.value || topicStatus.get_current_count() != 0) {
            System.err.println("FAIL: TopicIgnoredTopic reader matched despite ignore_topic() (current_count=" + topicStatus.get_current_count() + ")");
            System.exit(1);
        }
        Dcps.DDS.SubscriptionMatchedStatus participantStatus = new Dcps.DDS.SubscriptionMatchedStatus();
        if (participantIgnoredDr.get_subscription_matched_status(participantStatus) != Dcps.DDS.RETCODE_OK.value || participantStatus.get_current_count() != 0) {
            System.err.println("FAIL: ParticipantIgnoredTopic reader matched despite ignore_participant() (current_count=" + participantStatus.get_current_count() + ")");
            System.exit(1);
        }
        Dcps.DDS.SubscriptionMatchedStatus pubStatus = new Dcps.DDS.SubscriptionMatchedStatus();
        if (pubIgnoredDr.get_subscription_matched_status(pubStatus) != Dcps.DDS.RETCODE_OK.value || pubStatus.get_current_count() != 0) {
            System.err.println("FAIL: PublicationIgnoredTopic reader matched despite ignore_publication() (current_count=" + pubStatus.get_current_count() + ")");
            System.exit(1);
        }

        // Confirm the real guarantee, not just the match-count field:
        // peer's writers for TopicIgnoredTopic and PublicationIgnoredTopic
        // have been writing continuously this whole time (see Peer.java)
        // and -- since ignore_topic()/ignore_publication() are a strictly
        // one-sided, local filter (see this file's header comment) --
        // legitimately still consider *themselves* matched from their own
        // side. What must never happen is this reader's own take() ever
        // surfacing one of their samples.
        IgnoreEventDataReader topicIgnoredReader = new IgnoreEventDataReader(topicIgnoredDr);
        IgnoreEventDataReader.Sample[] topicSamples = topicIgnoredReader.take_n(
            SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        int topicTaken = 0;
        for (IgnoreEventDataReader.Sample s : topicSamples) if (s.validData) topicTaken++;
        if (topicTaken != 0) {
            System.err.println("FAIL: TopicIgnoredTopic reader received " + topicTaken + " samples, expected 0");
            System.exit(1);
        }
        IgnoreEventDataReader pubIgnoredReader = new IgnoreEventDataReader(pubIgnoredDr);
        IgnoreEventDataReader.Sample[] pubSamples = pubIgnoredReader.take_n(
            SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
        int pubTaken = 0;
        for (IgnoreEventDataReader.Sample s : pubSamples) if (s.validData) pubTaken++;
        if (pubTaken != 0) {
            System.err.println("FAIL: PublicationIgnoredTopic reader received " + pubTaken + " samples, expected 0");
            System.exit(1);
        }
        System.out.println("Ignorer: all ignore checks passed.");

        // -- Control: prove the apparatus itself works -- an unignored
        // reader must match and receive normally. --
        Dcps.DDS.SubscriptionMatchedStatus controlStatus = new Dcps.DDS.SubscriptionMatchedStatus();
        boolean controlMatched = false;
        long matchDeadline = System.currentTimeMillis() + MATCH_TIMEOUT_MS;
        while (!controlMatched) {
            if (System.currentTimeMillis() > matchDeadline) {
                System.err.println("FAIL: ControlTopic reader never matched within " + (MATCH_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            if (controlDr.get_subscription_matched_status(controlStatus) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_subscription_matched_status(control) failed");
                System.exit(1);
            }
            if (controlStatus.get_current_count() > 0) controlMatched = true; else Thread.sleep(POLL_PERIOD_MS);
        }

        IgnoreEventDataReader controlReader = new IgnoreEventDataReader(controlDr);
        int received = 0;
        int lastSeq = -1;
        long receiveDeadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (received < SAMPLE_COUNT) {
            if (System.currentTimeMillis() > receiveDeadline) {
                System.err.println("FAIL: ControlTopic did not receive all " + SAMPLE_COUNT + " samples within " + (RECEIVE_TIMEOUT_MS / 1000) + "s (got " + received + ")");
                System.exit(1);
            }
            IgnoreEventDataReader.Sample[] samples = controlReader.take_n(
                SAMPLE_COUNT, Dcps.DDS.ANY_SAMPLE_STATE.value, Dcps.DDS.ANY_VIEW_STATE.value, Dcps.DDS.ANY_INSTANCE_STATE.value);
            for (IgnoreEventDataReader.Sample s : samples) {
                if (!s.validData) continue;
                if (s.data.get_seq() != lastSeq + 1) {
                    System.err.println("FAIL: ControlTopic out-of-order sample, expected seq=" + (lastSeq + 1) + " got seq=" + s.data.get_seq());
                    System.exit(1);
                }
                lastSeq = s.data.get_seq();
                received++;
            }
            if (received < SAMPLE_COUNT) Thread.sleep(POLL_PERIOD_MS);
        }
        System.out.println("Ignorer: ControlTopic received all " + SAMPLE_COUNT + " samples.");

        // Standard teardown-safety: waiting for peer's ControlTopic writer
        // to observe us disconnect isn't this side's job -- peer waits on
        // its own matched-count-to-zero after we delete_participant() (see
        // Peer.java).
        System.out.println("Ignorer: done.");
        factory.delete_participant(dp);
    }
}
