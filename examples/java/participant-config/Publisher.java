// java/participant-config -- publisher. Direct Java port of
// zig/participant-config/publisher.zig / c/participant-config/src/publisher.c
// / cpp/participant-config/src/publisher.cpp; see
// docs/design/participant-config-reference-app.md at the repo root for the
// full spec.
//
// Two mutually exclusive modes (see c/participant-config's publisher.c for
// the full description): programmatic (default) round-trips a
// Zzdds.zzdds.DomainParticipantConfig value through
// set_default_participant_config/get_default_participant_config before
// creating the participant via create_participant_ex; file mode
// (--config <path>) loads a zzdds.toml-style file instead. Both then run
// the same minimal reliable write loop (3 samples) as hello_world.
//
// Required stdout markers: "Create topic:", "Create writer for topic:",
// "on_reliable_reader_ready", "Publisher: wrote count=", "Publisher: done."
// Programmatic mode additionally prints "Config round-trip OK: ...". Any
// failure path prints a line starting "FAIL:" and exits nonzero.

import io.zzdds.dcps.Dcps;
import io.zzdds.ext.Zzdds;

import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class Publisher {
    static final int SAMPLE_COUNT = 3;
    static final int READER_READY_TIMEOUT_MS = 10000;
    static final int DRAIN_TIMEOUT_MS = 15000;
    static final int POLL_PERIOD_MS = 20;

    // Distinctive values for the programmatic round-trip check -- one plain
    // string field, one scalar field in an all-primitive nested struct, so a
    // mismatch in either is unambiguous about which kind of field broke.
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
            // Programmatic mode: createFactory() always boxes into the base
            // DDS view -- narrow to zzdds's own extension view to reach
            // create_participant_ex/set_default_participant_config/
            // get_default_participant_config below.
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
        System.out.println("Create writer for topic: ConfigPing");

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

        ConfigPingDataWriter writer = new ConfigPingDataWriter(rawWriter);

        long deadline = System.currentTimeMillis() + READER_READY_TIMEOUT_MS;
        while (!readerReady.get()) {
            if (System.currentTimeMillis() > deadline) {
                System.err.println("FAIL: no reliable reader became ready within " + (READER_READY_TIMEOUT_MS / 1000) + "s");
                System.exit(1);
            }
            Thread.sleep(POLL_PERIOD_MS);
        }

        for (int i = 0; i < SAMPLE_COUNT; i++) {
            Config_ping.ConfigPing sample = new Config_ping.ConfigPing();
            sample.set_count(i);

            if (writer.write(sample, 0L) != 0) {
                System.err.println("FAIL: write() failed at count=" + i);
                System.exit(1);
            }
            System.out.println("Publisher: wrote count=" + i);
        }

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
