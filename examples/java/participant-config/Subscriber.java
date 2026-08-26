// java/participant-config -- subscriber. Direct Java port of
// zig/participant-config/subscriber.zig / c/participant-config/src/subscriber.c
// / cpp/participant-config/src/subscriber.cpp; see
// docs/design/participant-config-reference-app.md at the repo root for the
// full spec. Same two mutually exclusive modes as the publisher (see
// Publisher.java's doc comment).
//
// Required stdout markers: "Create topic:", "Create reader for topic:",
// "Subscriber: received count=", "Subscriber: received all 3 samples in
// order." Programmatic mode additionally prints "Config round-trip OK: ...".
// Any failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Subscriber {
    static final int EXPECTED_SAMPLES = 3;
    static final int RECEIVE_TIMEOUT_MS = 30000;
    static final int POLL_PERIOD_MS = 20;

    static final String CONFIG_PARTICIPANT_NAME = "participant-config-example";
    static final short CONFIG_FRAGMENT_SIZE = 9000;

    static class Options {
        int domainId = 0;
        String configPath = null;
    }

    static Options parseArgs(String[] args) {
        Options opts = new Options();
        for (int i = 0; i < args.length; i++) {
            if ((args[i].equals("-d") || args[i].equals("--domain")) && i + 1 < args.length) {
                opts.domainId = Integer.parseInt(args[++i]);
            } else if (args[i].equals("--config") && i + 1 < args.length) {
                opts.configPath = args[++i];
            }
        }
        return opts;
    }

    public static void main(String[] args) throws Exception {
        Options opts = parseArgs(args);

        if (opts.configPath != null) {
            int cfgRc = io.zzdds.runtime.ZzddsRuntime.configureFromFile(opts.configPath);
            if (cfgRc != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: failed to load config file '" + opts.configPath + "' (rc=" + cfgRc + ")");
                System.exit(1);
            }
        }

        Object baseFactory = io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (baseFactory == null) {
            System.err.println("FAIL: createFactory() failed");
            System.exit(1);
        }

        Dcps.DDS.DomainParticipant dp;
        if (opts.configPath == null) {
            Zzdds.zzdds.DomainParticipantFactory factory =
                (Zzdds.zzdds.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.asZzddsFactory(baseFactory);
            if (factory == null) {
                System.err.println("FAIL: asZzddsFactory() failed");
                System.exit(1);
            }

            Zzdds.zzdds.DomainParticipantConfig cfg = new Zzdds.zzdds.DomainParticipantConfig();
            cfg.get_participant().set_name(CONFIG_PARTICIPANT_NAME);
            cfg.get_rtps().set_fragment_size(CONFIG_FRAGMENT_SIZE);

            if (factory.set_default_participant_config(cfg) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: set_default_participant_config() failed");
                System.exit(1);
            }

            Zzdds.zzdds.DomainParticipantConfig readback = new Zzdds.zzdds.DomainParticipantConfig();
            if (factory.get_default_participant_config(readback) != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: get_default_participant_config() failed");
                System.exit(1);
            }

            if (!CONFIG_PARTICIPANT_NAME.equals(readback.get_participant().get_name())) {
                System.err.println("FAIL: participant.name round-trip mismatch: expected '" + CONFIG_PARTICIPANT_NAME
                        + "', got '" + readback.get_participant().get_name() + "'");
                System.exit(1);
            }
            if (readback.get_rtps().get_fragment_size() != CONFIG_FRAGMENT_SIZE) {
                System.err.println("FAIL: rtps.fragment_size round-trip mismatch: expected " + CONFIG_FRAGMENT_SIZE
                        + ", got " + readback.get_rtps().get_fragment_size());
                System.exit(1);
            }
            System.out.println("Config round-trip OK: participant.name='" + readback.get_participant().get_name()
                    + "' rtps.fragment_size=" + readback.get_rtps().get_fragment_size());

            dp = factory.create_participant_ex(opts.domainId, null, null, 0, cfg);
        } else {
            Dcps.DDS.DomainParticipantFactory factory = (Dcps.DDS.DomainParticipantFactory) baseFactory;
            dp = factory.create_participant(opts.domainId, null, null, 0);
        }
        if (dp == null) {
            System.err.println("FAIL: create_participant() failed on domain " + opts.domainId);
            System.exit(1);
        }

        if (ConfigPingTypeSupport.register(dp, "ConfigPing") != 0) {
            System.err.println("FAIL: register_type_support failed");
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic("ConfigPing", "ConfigPing", null, null, 0);
        if (topic == null) {
            System.err.println("FAIL: create_topic() failed");
            System.exit(1);
        }
        System.out.println("Create topic: ConfigPing");

        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber() failed");
            System.exit(1);
        }

        Dcps.DDS.DataReaderQos drQos = new Dcps.DDS.DataReaderQos();
        sub.get_default_datareader_qos(drQos);
        drQos.get_reliability().set_kind(Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS);
        drQos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);

        final AtomicInteger expectedNext = new AtomicInteger(0);
        final AtomicBoolean allReceived = new AtomicBoolean(false);
        final Object[] readerBox = new Object[1]; // set right after create_datareader

        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_data_available(Dcps.DDS.DataReader r) {
                ConfigPingDataReader reader = (ConfigPingDataReader) readerBox[0];
                ConfigPingDataReader.Sample sample;
                while ((sample = reader.take()) != null) {
                    if (!sample.validData) continue;

                    int count = sample.data.get_count();
                    int expected = expectedNext.get();
                    if (count != expected) {
                        System.err.println("FAIL: expected count=" + expected + " but got count=" + count);
                        System.exit(1);
                    }

                    System.out.println("Subscriber: received count=" + count);
                    int next = expectedNext.incrementAndGet();

                    if (next == EXPECTED_SAMPLES) {
                        allReceived.set(true);
                    }
                }
            }
        };

        // Create with no listener attached yet: on_data_available fires on
        // a zzdds-internal dispatch thread as soon as the reader matches,
        // which can race readerBox[0]'s own assignment below. Attach the
        // listener only once readerBox[0] is set, via set_listener() below,
        // closing the window entirely.
        Dcps.DDS.DataReader rawReader = sub.create_datareader(topic, drQos, null, 0);
        if (rawReader == null) {
            System.err.println("FAIL: create_datareader() failed");
            System.exit(1);
        }
        System.out.println("Create reader for topic: ConfigPing");

        readerBox[0] = new ConfigPingDataReader(rawReader);
        if (rawReader.set_listener(listener, Dcps.DDS.DATA_AVAILABLE_STATUS.value) != 0) {
            System.err.println("FAIL: set_listener() failed");
            System.exit(1);
        }

        System.out.println("Subscriber: waiting for " + EXPECTED_SAMPLES + " samples...");
        long deadline = System.currentTimeMillis() + RECEIVE_TIMEOUT_MS;
        while (!allReceived.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: only received " + expectedNext.get() + "/" + EXPECTED_SAMPLES + " samples within " + (RECEIVE_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        sub.delete_datareader(rawReader);

        System.out.println("Subscriber: received all " + EXPECTED_SAMPLES + " samples in order.");
    }
}
