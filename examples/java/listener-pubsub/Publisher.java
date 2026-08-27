// zzdds Java pub/sub showcase — publisher process.
//
// Creates a real DomainParticipant, registers SensorSample's TypeSupport,
// creates a topic/publisher/datawriter, and writes a handful of samples a
// second apart over real UDP DDS discovery. Run alongside Subscriber.java
// (see run.sh) — they're two separate JVM processes, matching how
// zzdds-embedded-c-example's publisher/subscriber binaries work.

import io.zzdds.dcps.Dcps;

public class Publisher {
    static final int DOMAIN_ID = 0;
    static final int SAMPLE_COUNT = 10;

    public static void main(String[] args) throws Exception {
        Dcps.DDS.DomainParticipantFactory factory =
            (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (factory == null) {
            System.err.println("FAIL: createFactory() returned null");
            System.exit(1);
        }

        Dcps.DDS.DomainParticipant participant = factory.create_participant(DOMAIN_ID, null, null, 0);
        if (participant == null) {
            System.err.println("FAIL: create_participant() returned null");
            System.exit(1);
        }

        int rc = SensorSampleTypeSupport.register(participant, null);
        if (rc != 0) {
            System.err.println("FAIL: TypeSupport.register rc=" + rc);
            System.exit(1);
        }

        Dcps.DDS.Topic topic = participant.create_topic("SensorTopic", "SensorSample", null, null, 0);
        Dcps.DDS.Publisher publisher = participant.create_publisher(null, null, 0);
        Dcps.DDS.DataWriter rawWriter = publisher.create_datawriter(topic, null, null, 0);
        if (topic == null || publisher == null || rawWriter == null) {
            System.err.println("FAIL: entity creation returned null");
            System.exit(1);
        }

        SensorSampleDataWriter writer = new SensorSampleDataWriter(rawWriter);

        System.out.println("Publisher: waiting for a subscriber to match...");
        // No listener here — just poll get_publication_matched_status() so
        // this stays a minimal, single-threaded example.
        Dcps.DDS.PublicationMatchedStatus status = new Dcps.DDS.PublicationMatchedStatus();
        for (int i = 0; i < 100 && status.get_current_count() == 0; i++) {
            rawWriter.get_publication_matched_status(status);
            if (status.get_current_count() == 0) Thread.sleep(100);
        }
        if (status.get_current_count() == 0) {
            System.err.println("FAIL: no subscriber matched within 10s");
            System.exit(1);
        }
        System.out.println("Publisher: matched a subscriber, writing " + SAMPLE_COUNT + " samples.");

        for (int i = 0; i < SAMPLE_COUNT; i++) {
            Sensor.SensorSample sample = new Sensor.SensorSample();
            sample.set_sensor_id(1);
            sample.set_timestamp_ms(System.currentTimeMillis());
            sample.set_temperature_c(20.0 + i * 0.5);
            sample.set_label("sensor-1");

            int wrc = writer.write(sample, 0L);
            if (wrc != 0) {
                System.err.println("FAIL: write() rc=" + wrc + " at sample " + i);
                System.exit(1);
            }
            System.out.println("Publisher: wrote sample " + i + " temperature_c=" + sample.get_temperature_c());
            Thread.sleep(1000);
        }

        System.out.println("Publisher: done.");
    }
}
