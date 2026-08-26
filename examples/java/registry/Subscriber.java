// java/registry -- subscriber. Direct Java port of
// zig/registry/subscriber.zig / c/registry/src/subscriber.c /
// cpp/registry/src/subscriber.cpp; see docs/design/registry-reference-app.md
// at the repo root for the full spec. Tracks each of the publisher's three
// instances' observed Sample.instanceState sequence (fail fast on an
// unexpected transition), and once all three have reached their expected
// outcome, calls lookup_instance() to confirm the key-to-handle direction
// matches what the publisher's own samples for that instance carried.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// reader for topic:", "Subscriber: sensor_id=... instance_state=...",
// "Subscriber: lookup_instance round-trip OK for sensor_id=",
// "Subscriber: all three instance lifecycles observed correctly." Any
// failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;

public class Subscriber {
    static final int RECEIVE_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    static class InstanceTrack {
        final int sensorId;
        boolean seenAlive = false;
        boolean reachedTerminal = false;
        long handle = 0;
        InstanceTrack(int sensorId) { this.sensorId = sensorId; }
    }

    static String stateName(int s) {
        if (s == Dcps.DDS.ALIVE_INSTANCE_STATE.value) return "ALIVE";
        if (s == Dcps.DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE.value) return "NOT_ALIVE_DISPOSED";
        if (s == Dcps.DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE.value) return "NOT_ALIVE_NO_WRITERS";
        return "UNKNOWN";
    }

    static InstanceTrack trackFor(InstanceTrack[] tracks, int sensorId) {
        for (InstanceTrack t : tracks) {
            if (t.sensorId == sensorId) return t;
        }
        System.err.println("FAIL: unexpected sensor_id=" + sensorId);
        System.exit(1);
        return null; // unreachable
    }

    static boolean allInstancesDone(InstanceTrack[] tracks) {
        for (InstanceTrack t : tracks) {
            if (!t.reachedTerminal) return false;
        }
        return true;
    }

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

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        final InstanceTrack[] tracks = { new InstanceTrack(1), new InstanceTrack(2), new InstanceTrack(3) };
        final Object[] readerBox = new Object[1]; // set right after create_datareader
        final AtomicBoolean allDone = new AtomicBoolean(false);

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                SensorReadingDataReader reader = (SensorReadingDataReader) readerBox[0];
                // Deferred, not set directly inside the loop below: main()
                // deletes the reader as soon as it observes allDone, so
                // setting it mid-loop would let main()'s
                // delete_datareader() race this same invocation's next
                // take() call. Only commit the flag once this invocation's
                // take loop has fully drained and won't touch the reader
                // again.
                boolean becameDone = false;
                SensorReadingDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    int sensorId = sample.data.get_sensor_id();
                    InstanceTrack track = trackFor(tracks, sensorId);
                    System.out.println("Subscriber: sensor_id=" + sensorId + " instance_state=" + stateName(sample.instanceState));
                    track.handle = sample.instanceHandle;

                    if (sample.instanceState == Dcps.DDS.ALIVE_INSTANCE_STATE.value) {
                        track.seenAlive = true;
                        if (track.sensorId == 3) track.reachedTerminal = true;
                    } else if (sample.instanceState == Dcps.DDS.NOT_ALIVE_DISPOSED_INSTANCE_STATE.value) {
                        if (track.sensorId != 1) {
                            System.err.println("FAIL: unexpected NOT_ALIVE_DISPOSED for sensor_id=" + track.sensorId);
                            System.exit(1);
                        }
                        if (!track.seenAlive) {
                            System.err.println("FAIL: sensor_id=1 reached NOT_ALIVE_DISPOSED without ever being ALIVE");
                            System.exit(1);
                        }
                        track.reachedTerminal = true;
                    } else if (sample.instanceState == Dcps.DDS.NOT_ALIVE_NO_WRITERS_INSTANCE_STATE.value) {
                        if (track.sensorId != 2) {
                            System.err.println("FAIL: unexpected NOT_ALIVE_NO_WRITERS for sensor_id=" + track.sensorId);
                            System.exit(1);
                        }
                        if (!track.seenAlive) {
                            System.err.println("FAIL: sensor_id=2 reached NOT_ALIVE_NO_WRITERS without ever being ALIVE");
                            System.exit(1);
                        }
                        track.reachedTerminal = true;
                    } else {
                        System.err.println("FAIL: unknown instance_state=" + sample.instanceState + " for sensor_id=" + track.sensorId);
                        System.exit(1);
                    }

                    if (allInstancesDone(tracks) && !allDone.get() && !becameDone) {
                        InstanceTrack cTrack = trackFor(tracks, 3);
                        Registry_sample.SensorReading query = new Registry_sample.SensorReading();
                        query.set_sensor_id(3);
                        long lookedUp = reader.lookup_instance(query);
                        if (lookedUp == 0 || lookedUp != cTrack.handle) {
                            System.err.println("FAIL: lookup_instance() round-trip mismatch for sensor_id=3");
                            System.exit(1);
                        }
                        System.out.println("Subscriber: lookup_instance round-trip OK for sensor_id=3");
                        becameDone = true;
                    }
                }
                if (becameDone) {
                    allDone.set(true);
                }
            }
        };

        // Create with no listener attached yet: on_data_available fires on
        // a zzdds-internal dispatch thread as soon as the reader matches,
        // which can race readerBox[0]'s own assignment below. Attach the
        // listener only once readerBox[0] is set, via set_listener()
        // below, closing the window entirely.
        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, null, 0);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: SensorReading");

        readerBox[0] = new SensorReadingDataReader(rawReader);
        if (rawReader.set_listener(listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        System.out.println("Subscriber: waiting for all three instance lifecycles...");
        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (!allDone.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: did not observe all three instance lifecycles within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        sub.delete_datareader(rawReader);

        System.out.println("Subscriber: all three instance lifecycles observed correctly.");
    }
}
