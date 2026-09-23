// integration-tests/java/ignore-entities -- bystander. Direct Java port of
// c/ignore-entities/src/bystander.c -- see that file's header comment for
// the full scenario rationale and docs/design/integration-test-tier.md for
// the scenario spec.
//
// Required stdout markers: "Bystander: ready.", "Bystander: created writer
// for ParticipantIgnoredTopic.", "Bystander: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

public class Bystander {
    static final int SAMPLE_COUNT = 5;
    static final int PRE_WRITER_DELAY_MS = 4000;
    static final int POST_WRITE_SETTLE_MS = 6000;

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
        System.out.println("Bystander: ready.");
        System.out.flush();

        // Deliberate wall-clock window -- not a race-avoidance hack. Gives
        // the ignorer a comfortable, unambiguous stretch of real time to
        // discover and ignore this participant before the writer below
        // ever announces.
        Thread.sleep(PRE_WRITER_DELAY_MS);

        if (IgnoreEventTypeSupport.register(dp, "IgnoreEvent") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("ParticipantIgnoredTopic", "IgnoreEvent", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, null, 0);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Bystander: created writer for ParticipantIgnoredTopic.");

        IgnoreEventDataWriter writer = new IgnoreEventDataWriter(dw);
        for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
            Ignore_event.IgnoreEvent ev = new Ignore_event.IgnoreEvent();
            ev.set_seq(seq);
            writer.write(ev, 0L);
        }

        // No match-count assertion here -- see this file's header comment
        // (and Ignorer.java's, for the full explanation). Just gives
        // Ignorer.java's own settle window (which this overlaps) a
        // comfortable stretch of real time before this process exits and
        // tears its participant down.
        Thread.sleep(POST_WRITE_SETTLE_MS);

        System.out.println("Bystander: done.");
        factory.delete_participant(dp);
    }
}
