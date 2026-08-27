// zzdds Java pub/sub showcase — subscriber process. See Publisher.java.
//
// Registers a real DataReaderListener (on_data_available) — the native JNI
// upcall path — instead of polling, to demonstrate that side of the binding
// too. Prints every sample it receives and exits 0 once it has seen at
// least EXPECTED_SAMPLES, or exits 1 on timeout.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int DOMAIN_ID = 0;
    static final int EXPECTED_SAMPLES = 10;

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
        Dcps.DDS.Subscriber subscriber = participant.create_subscriber(null, null, 0);
        if (topic == null || subscriber == null) {
            System.err.println("FAIL: entity creation returned null");
            System.exit(1);
        }

        final AtomicInteger received = new AtomicInteger(0);
        final Object lock = new Object();

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                // Fired on zzdds's own network thread (see ZzddsRuntime's
                // javadoc) — take() calls back into JNI from here, which is
                // fine, but keep callback bodies short and avoid blocking.
                SensorSampleDataReader reader = new SensorSampleDataReader(r);
                SensorSampleDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    if (!sample.validData) continue;
                    System.out.println("Subscriber: received sensor_id=" + sample.data.get_sensor_id()
                        + " temperature_c=" + sample.data.get_temperature_c()
                        + " label=" + sample.data.get_label());
                    synchronized (lock) {
                        received.incrementAndGet();
                        lock.notifyAll();
                    }
                }
            }
        };

        Dcps.DDS.DataReader rawReader = subscriber.create_datareader(topic, null, listener, 0xFFFFFFFF);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() returned null");
            System.exit(1);
        }

        System.out.println("Subscriber: waiting for " + EXPECTED_SAMPLES + " samples...");
        long deadline = System.currentTimeMillis() + 30_000;
        synchronized (lock) {
            while (received.get() < EXPECTED_SAMPLES && System.currentTimeMillis() < deadline) {
                lock.wait(1000);
            }
        }

        if (received.get() < EXPECTED_SAMPLES) {
            System.err.println("FAIL: only received " + received.get() + "/" + EXPECTED_SAMPLES + " samples within 30s");
            System.exit(1);
        }
        System.out.println("Subscriber: done, received " + received.get() + " samples.");
    }
}
