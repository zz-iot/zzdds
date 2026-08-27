// java/presence -- subscriber. Direct Java port of
// zig/presence/subscriber.zig / c/presence/src/subscriber.c /
// cpp/presence/src/subscriber.cpp; see docs/design/presence-reference-app.md
// at the repo root for the full spec. Demonstrates
// DataReaderListener.on_liveliness_changed: observes the writer's lease
// expiring (OFFLINE) and later recovering (ONLINE) after an explicit
// assert_liveliness() call, and asserts the full cycle was seen in order.
//
// Required stdout markers (see the spec doc): "Create topic:", "Create
// reader for topic:", "ONLINE alive_count=", "OFFLINE alive_count=",
// "Subscriber: observed full online -> offline -> online cycle." Any
// failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int CYCLE_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    enum Phase { WAITING_FIRST_ONLINE, WAITING_OFFLINE, WAITING_SECOND_ONLINE, DONE }

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

        if (PresenceBeaconTypeSupport.register(dp, "PresenceBeacon") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("PresenceBeacon", "PresenceBeacon", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: PresenceBeacon");

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
        drQos.get_history().set_depth(1);
        drQos.get_liveliness().set_kind(Dcps.DDS.LivelinessQosPolicyKind.MANUAL_BY_TOPIC_LIVELINESS_QOS);
        drQos.get_liveliness().get_lease_duration().set_sec(2);
        drQos.get_liveliness().get_lease_duration().set_nanosec(0);

        final Object[] readerBox = new Object[1]; // set right after create_datareader
        final Phase[] phase = { Phase.WAITING_FIRST_ONLINE };
        final AtomicInteger step = new AtomicInteger(0);
        final AtomicBoolean cycleComplete = new AtomicBoolean(false);

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {
                boolean online = s.get_alive_count() > 0;
                if (online) {
                    System.out.println("ONLINE alive_count=" + s.get_alive_count() + " not_alive_count=" + s.get_not_alive_count());
                } else {
                    System.out.println("OFFLINE alive_count=" + s.get_alive_count() + " not_alive_count=" + s.get_not_alive_count());
                }

                switch (phase[0]) {
                    case WAITING_FIRST_ONLINE:
                        if (online) {
                            phase[0] = Phase.WAITING_OFFLINE;
                            step.set(1);
                        }
                        break;
                    case WAITING_OFFLINE:
                        if (!online) {
                            phase[0] = Phase.WAITING_SECOND_ONLINE;
                            step.set(2);
                        }
                        break;
                    case WAITING_SECOND_ONLINE:
                        if (online) {
                            phase[0] = Phase.DONE;
                            step.set(3);
                            cycleComplete.set(true);
                        }
                        break;
                    case DONE:
                        break;
                }
            }

            public void on_data_available(Dcps.DDS.DataReader r) {
                PresenceBeaconDataReader reader = (PresenceBeaconDataReader) readerBox[0];
                PresenceBeaconDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    if (!sample.validData) continue;
                    System.out.println("Subscriber: received sequence=" + sample.data.get_seq_num());
                }
            }
        };

        // Create with no listener attached yet: on_data_available/
        // on_liveliness_changed fire on a zzdds-internal dispatch thread as
        // soon as the reader matches, which can race readerBox[0]'s own
        // assignment below. Attach the listener only once readerBox[0] is
        // set, via set_listener() below, closing the window entirely.
        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, null, 0);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: PresenceBeacon");

        readerBox[0] = new PresenceBeaconDataReader(rawReader);
        int listenerMask = Dcps.DDS.DATA_AVAILABLE_STATUS.value | Dcps.DDS.LIVELINESS_CHANGED_STATUS.value;
        if (rawReader.set_listener(listener, listenerMask) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        System.out.println("Subscriber: waiting for online -> offline -> online cycle...");
        long deadline = System.currentTimeMillis() + CYCLE_TIMEOUT_MS;
        while (!cycleComplete.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: did not observe the full cycle within " + (CYCLE_TIMEOUT_MS / 1000) + "s (stuck at step=" + step.get() + ")");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        sub.delete_datareader(rawReader);

        System.out.println("Subscriber: observed full online -> offline -> online cycle.");
    }
}
