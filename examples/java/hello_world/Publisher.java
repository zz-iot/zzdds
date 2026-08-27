// java/hello_world -- publisher. Direct Java port of
// zig/hello_world/publisher.zig / c/hello_world/src/publisher.c /
// cpp/hello_world/src/publisher.cpp; see
// docs/design/hello-world-reference-app.md at the repo root for the full
// spec. Demonstrates:
//
//   1. zzdds's DataWriterListenerEx::on_reliable_reader_ready extension --
//      write only once a matched RELIABLE reader has actually completed the
//      AckNack/Heartbeat handshake, not just SEDP discovery. Uses the same
//      ZzddsRuntime.asZzddsDataWriter narrowing zzdds's own
//      test/bindings/smoke/JavaSmoke.java uses -- unlike the C++ binding's
//      equivalent (a raw static_pointer_cast between unrelated sibling
//      classes, which is undefined behavior -- see cpp/hello_world's
//      README), Java's binding does this narrowing correctly via a real
//      runtime helper.
//   2. Clean shutdown gated on PublicationMatchedStatus.current_count
//      returning to zero -- waiting for the subscriber to tear its reader
//      down, not just for our own writes to finish.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// writer for topic:", "on_reliable_reader_ready", "Publisher: wrote
// count=", "on_publication_matched", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int SAMPLE_COUNT = 10;
    static final int READER_READY_TIMEOUT_MS = 10000;
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

        if (HelloWorldTypeSupport.register(dp, "HelloWorld") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("HelloWorld", "HelloWorld", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: HelloWorld");

        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher() failed");
            System.exit(1);
        }

        Dcps.DDS.DataWriterQos dwQos = new Dcps.DDS.DataWriterQos();
        pub.get_default_datawriter_qos(dwQos);
        dwQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        dwQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        Dcps.DDS.DataWriter rawWriter = pub.create_datawriter(topic, dwQos, null, 0);
        if (rawWriter == null) {
            System.err.println("FAIL: create_datawriter() failed");
            System.exit(1);
        }
        System.out.println("Create writer for topic: HelloWorld");

        final AtomicBoolean readerReady = new AtomicBoolean(false);
        final AtomicBoolean everMatched = new AtomicBoolean(false);
        final AtomicInteger matchedCurrentCount = new AtomicInteger(0);

        Zzdds.zzdds.DataWriter zdWriter =
            (Zzdds.zzdds.DataWriter) io.zzdds.runtime.ZzddsRuntime.asZzddsDataWriter(rawWriter);
        if (zdWriter == null) {
            System.err.println("FAIL: asZzddsDataWriter() failed");
            System.exit(1);
        }

        Zzdds.zzdds.DataWriterListenerEx writerListener = new Zzdds.zzdds.DataWriterListenerEx() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}

            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {
                matchedCurrentCount.set(s.get_current_count());
                if (s.get_current_count() > 0) everMatched.set(true);
                System.out.println("on_publication_matched() current_count=" + s.get_current_count());
            }

            public void on_reliable_reader_ready(int readerHandle, boolean isReady) {
                if (isReady) readerReady.set(true);
                System.out.println("on_reliable_reader_ready() is_ready=" + isReady);
            }
        };
        if (zdWriter.set_listener_ex(writerListener, Dcps.DDS.PUBLICATION_MATCHED_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener_ex failed");
            System.exit(1);
        }

        HelloWorldDataWriter writer = new HelloWorldDataWriter(rawWriter);

        // Wait for a reliable reader to complete the AckNack/Heartbeat
        // handshake before writing anything -- the whole point of the
        // extension.
        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        for (int i = 0; i < SAMPLE_COUNT; i++) {
            Hello_world.HelloWorld sample = new Hello_world.HelloWorld();
            sample.set_count(i);
            sample.set_message("Hello world!");

            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at count=" + i);
                System.exit(1);
            }
            System.out.println("Publisher: wrote count=" + i + " message=\"Hello world!\"");
        }

        // Wait for the subscriber to tear its reader down (current_count
        // back to zero) before exiting.
        deadline = System.currentTimeMillis() + DRAIN_TIMEOUT_MS;
        while (!(everMatched.get() && matchedCurrentCount.get() == 0)) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: subscriber did not disconnect within " + (DRAIN_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        System.out.println("Publisher: done.");
    }
}
