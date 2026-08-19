// java/registry -- publisher. Direct Java port of
// zig/registry/publisher.zig / c/registry/src/publisher.c /
// cpp/registry/src/publisher.cpp; see docs/design/registry-reference-app.md
// at the repo root for the full spec. Walks three instances through three
// different explicit lifecycles: register_instance() -> write() x2 ->
// dispose() (instance A), register_instance() -> write_w_timestamp() ->
// unregister() (instance B), register_instance() -> write() left alive
// (instance C) -- then confirms get_key_value() rounds the handle it got
// for instance A back to the right key.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// writer for topic:", "Publisher: registered instance sensor_id=",
// "Publisher: wrote sensor_id=", "Publisher: disposed sensor_id=",
// "Publisher: unregistered sensor_id=", "Publisher: get_key_value
// round-trip OK for sensor_id=", "Publisher: done." Any failure path
// prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
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

        if (SensorReadingTypeSupport.register(dp, "SensorReading") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("SensorReading", "SensorReading", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: SensorReading");

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
        System.out.println("Create writer for topic: SensorReading");

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

        SensorReadingDataWriter writer = new SensorReadingDataWriter(rawWriter);

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        // -- Instance A (sensor_id=1): register -> write x2 -> dispose --
        Registry_sample.SensorReading keyA = new Registry_sample.SensorReading();
        keyA.set_sensor_id(1);
        long handleA = writer.register_instance(keyA);
        System.out.println("Publisher: registered instance sensor_id=1");

        Registry_sample.SensorReading sampleA1 = new Registry_sample.SensorReading();
        sampleA1.set_sensor_id(1);
        sampleA1.set_value(100);
        if (writer.write(sampleA1, handleA) != 0) {
            System.err.println("FAIL: write() failed for sensor_id=1");
            System.exit(1);
        }
        System.out.println("Publisher: wrote sensor_id=1 value=100");

        Registry_sample.SensorReading sampleA2 = new Registry_sample.SensorReading();
        sampleA2.set_sensor_id(1);
        sampleA2.set_value(101);
        if (writer.write(sampleA2, handleA) != 0) {
            System.err.println("FAIL: write() failed for sensor_id=1");
            System.exit(1);
        }
        System.out.println("Publisher: wrote sensor_id=1 value=101");

        if (writer.dispose(keyA, handleA) != 0) {
            System.err.println("FAIL: dispose() failed for sensor_id=1");
            System.exit(1);
        }
        System.out.println("Publisher: disposed sensor_id=1");

        // -- Instance B (sensor_id=2): register -> write_w_timestamp -> unregister --
        Registry_sample.SensorReading keyB = new Registry_sample.SensorReading();
        keyB.set_sensor_id(2);
        long handleB = writer.register_instance(keyB);
        System.out.println("Publisher: registered instance sensor_id=2");

        long nowMillis = System.currentTimeMillis();
        int tsSec = (int) (nowMillis / 1000);
        int tsNanosec = (int) ((nowMillis % 1000) * 1_000_000);

        Registry_sample.SensorReading sampleB = new Registry_sample.SensorReading();
        sampleB.set_sensor_id(2);
        sampleB.set_value(200);
        if (writer.write_w_timestamp(sampleB, handleB, tsSec, tsNanosec) != 0) {
            System.err.println("FAIL: write_w_timestamp() failed for sensor_id=2");
            System.exit(1);
        }
        System.out.println("Publisher: wrote sensor_id=2 value=200");

        if (writer.unregister(keyB, handleB) != 0) {
            System.err.println("FAIL: unregister() failed for sensor_id=2");
            System.exit(1);
        }
        System.out.println("Publisher: unregistered sensor_id=2");

        // -- Instance C (sensor_id=3): register -> write, left alive --
        Registry_sample.SensorReading keyC = new Registry_sample.SensorReading();
        keyC.set_sensor_id(3);
        long handleC = writer.register_instance(keyC);
        System.out.println("Publisher: registered instance sensor_id=3");

        Registry_sample.SensorReading sampleC = new Registry_sample.SensorReading();
        sampleC.set_sensor_id(3);
        sampleC.set_value(300);
        if (writer.write(sampleC, handleC) != 0) {
            System.err.println("FAIL: write() failed for sensor_id=3");
            System.exit(1);
        }
        System.out.println("Publisher: wrote sensor_id=3 value=300");

        // -- get_key_value() round-trip on instance A's handle --
        Registry_sample.SensorReading keyHolder = writer.get_key_value(handleA);
        if (keyHolder == null) {
            System.err.println("FAIL: get_key_value() failed for sensor_id=1");
            System.exit(1);
        }
        if (keyHolder.get_sensor_id() != 1) {
            System.err.println("FAIL: get_key_value() round-trip mismatch: expected sensor_id=1, got sensor_id=" + keyHolder.get_sensor_id());
            System.exit(1);
        }
        System.out.println("Publisher: get_key_value round-trip OK for sensor_id=1");

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
