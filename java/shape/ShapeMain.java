// Java port of zig/shape's shape_main -- the OMG DDS-Interoperability
// "Shapes" demo app, talking to zzdds through its Java binding (JNI). CLI/
// behavior spec is dds-rtps's srcZig/shape_main.zig (see zig/shape); this
// implements the "Must-have (v1)" flag subset from
// docs/design/shape-reference-app.md plus --config -- same scope as
// c/shape and cpp/shape, see their READMEs for exactly what's not
// implemented (stretch flags).
//
// Fresh implementation -- no existing zzdds Java shape port anywhere to
// adapt. One class, -P/-S selects publisher/subscriber mode, matching the
// other three ports and the dds-rtps interop harness convention of one
// binary (here: one `java ShapeMain ...` invocation) handed to both roles.

import io.zzdds.dcps.Dcps;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.concurrent.atomic.AtomicBoolean;

public class ShapeMain {

    // ── Options ─────────────────────────────────────────────────────────────

    static class Options {
        boolean publish = false;
        boolean subscribe = false;
        int domainId = 0;
        boolean bestEffort = false;
        boolean reliable = false;
        int historyDepth = -1; // -1 = use default KEEP_LAST 1
        String topicName = "Square";
        String color = "BLUE";
        char durability = 'v'; // 'v', 'l', 't', 'p'
        boolean printWriterSamples = false;
        int shapesize = 20;
        long writePeriodMs = 33;
        long readPeriodMs = 100;
        long numIterations = -1; // -1 = infinite
        String configPath = null;
    }

    // ── Policy name mapping (matches zig/shape's policyName()) ────────────────

    static String policyName(int id) {
        switch (id) {
            case 2: return "DURABILITY";
            case 4: return "DEADLINE";
            case 5: return "LATENCYBUDGET";
            case 6: return "OWNERSHIP";
            case 8: return "LIVELINESS";
            case 10: return "PARTITION";
            case 11: return "RELIABILITY";
            case 12: return "DESTINATIONORDER";
            case 23: return "DATAREPRESENTATION";
            default: return "UNKNOWN";
        }
    }

    static final AtomicBoolean allDone = new AtomicBoolean(false);

    // ── QoS builders ────────────────────────────────────────────────────────

    // -r forces RELIABLE even if -b was also passed; otherwise -b selects
    // BEST_EFFORT and everything else (including the no-flags case) is
    // RELIABLE -- matches zig/shape's buildWriterQos/buildReaderQos exactly.
    static Dcps.DDS.ReliabilityQosPolicyKind reliabilityKind(Options opts) {
        if (opts.bestEffort && !opts.reliable) return Dcps.DDS.ReliabilityQosPolicyKind.BEST_EFFORT_RELIABILITY_QOS;
        return Dcps.DDS.ReliabilityQosPolicyKind.RELIABLE_RELIABILITY_QOS;
    }

    static Dcps.DDS.DurabilityQosPolicyKind durabilityKind(char d) {
        switch (d) {
            case 'l': return Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_LOCAL_DURABILITY_QOS;
            case 't': return Dcps.DDS.DurabilityQosPolicyKind.TRANSIENT_DURABILITY_QOS;
            case 'p': return Dcps.DDS.DurabilityQosPolicyKind.PERSISTENT_DURABILITY_QOS;
            default: return Dcps.DDS.DurabilityQosPolicyKind.VOLATILE_DURABILITY_QOS;
        }
    }

    // Now matches the other three ports: explicitly offer/request a
    // one-element [XCDR_DATA_REPRESENTATION] (XCDR1) list, instead of
    // leaving the field empty. This used to be unsafe -- zidl's Java
    // backend always emitted/expected a DHEADER for @appendable types like
    // ShapeType regardless of any declared representation, so declaring
    // XCDR1 here made the QoS lie about the actual wire bytes (see the fix:
    // zidl's Java backend now threads a real xcdr_version through its
    // generated CDR code, mirroring C/C++/Zig's conditional
    // zidl_cdr_reserve_dheader_maybe/skip_dheader_if_xcdr2 -- ShapeTypeDataWriter
    // now takes a real xcdrVersion, defaulting to XCDR1). See this port's
    // README ("Cross-binding interop") for the full story, including the
    // separate dcps_jni.c data_representation marshalling bug this also
    // exposed and fixed.
    static void setDefaultRepresentation(Dcps.DDS.DataRepresentationQosPolicy repr) {
        repr.set_value(java.util.Collections.singletonList(Dcps.DDS.XCDR_DATA_REPRESENTATION.value));
    }

    static Dcps.DDS.DataWriterQos buildWriterQos(Options opts) {
        Dcps.DDS.DataWriterQos qos = new Dcps.DDS.DataWriterQos();
        qos.get_reliability().set_kind(reliabilityKind(opts));
        if (opts.historyDepth == 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        } else if (opts.historyDepth > 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
            qos.get_history().set_depth(opts.historyDepth);
        }
        qos.get_durability().set_kind(durabilityKind(opts.durability));
        setDefaultRepresentation(qos.get_data_representation());
        return qos;
    }

    static Dcps.DDS.DataReaderQos buildReaderQos(Options opts) {
        Dcps.DDS.DataReaderQos qos = new Dcps.DDS.DataReaderQos();
        qos.get_reliability().set_kind(reliabilityKind(opts));
        if (opts.historyDepth == 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        } else if (opts.historyDepth > 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
            qos.get_history().set_depth(opts.historyDepth);
        }
        qos.get_durability().set_kind(durabilityKind(opts.durability));
        setDefaultRepresentation(qos.get_data_representation());
        return qos;
    }

    // ── Publisher ───────────────────────────────────────────────────────────

    static int runPublisher(Dcps.DDS.DomainParticipant dp, Dcps.DDS.Topic topic, Options opts) throws InterruptedException {
        Dcps.DDS.Publisher pub = dp.create_publisher(null, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher returned null");
            return 1;
        }

        Dcps.DDS.DataWriterQos dwQos = buildWriterQos(opts);
        Dcps.DDS.DataWriterListener listener = new Dcps.DDS.DataWriterListener() {
            public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus s) {}
            public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}
            public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {}

            public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus status) {
                System.out.printf("on_offered_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)%n",
                        opts.topicName, status.get_last_policy_id(), policyName(status.get_last_policy_id()));
            }
        };

        Dcps.DDS.DataWriter dw = pub.create_datawriter(topic, dwQos, listener, Dcps.DDS.OFFERED_INCOMPATIBLE_QOS_STATUS.value);
        if (dw == null) {
            System.err.println("FAIL: create_datawriter returned null");
            return 1;
        }
        ShapeTypeDataWriter typedWriter = new ShapeTypeDataWriter(dw, ShapeTypeDataWriter.XCDR1);

        System.out.println("Create writer for topic: " + opts.topicName + " color: " + opts.color);

        Shape.ShapeType shape = new Shape.ShapeType();
        shape.set_color(opts.color);
        shape.set_shapesize(opts.shapesize == 0 ? 1 : opts.shapesize);

        java.util.Random rand = new java.util.Random();

        long matchDeadline = System.nanoTime() + 10_000_000_000L;
        boolean printedMatched = false;

        long iteration = 0;
        while (!allDone.get()) {
            if (opts.numIterations >= 0 && iteration >= opts.numIterations) break;

            if (!printedMatched) {
                Dcps.DDS.PublicationMatchedStatus status = new Dcps.DDS.PublicationMatchedStatus();
                dw.get_publication_matched_status(status);
                if (status.get_current_count() > 0) {
                    System.out.printf("on_publication_matched() topic: '%s'  type: 'ShapeType' : matched readers %d (change = 1)%n",
                            opts.topicName, status.get_current_count());
                    printedMatched = true;
                } else if (System.nanoTime() > matchDeadline) {
                    return 0; // READER_NOT_MATCHED
                }
            }

            shape.set_x(rand.nextInt(320));
            shape.set_y(rand.nextInt(240));

            int rc = typedWriter.write(shape, 0L);
            if (rc != Dcps.DDS.RETCODE_OK.value) {
                System.err.println("FAIL: DataWriter.write rc=" + rc);
                return 1;
            }
            if (opts.printWriterSamples) {
                System.out.printf("%-10s %-10s %03d %03d [%d]%n",
                        opts.topicName, shape.get_color(), shape.get_x(), shape.get_y(), shape.get_shapesize());
            }
            if (opts.shapesize == 0) {
                shape.set_shapesize(shape.get_shapesize() + 1);
            }

            iteration++;
            Thread.sleep(opts.writePeriodMs);
        }

        if (opts.numIterations >= 0) {
            Dcps.DDS.Duration_t ackTimeout = new Dcps.DDS.Duration_t(5, 0);
            pub.wait_for_acknowledgments(ackTimeout);
        }
        return 0;
    }

    // ── Subscriber ──────────────────────────────────────────────────────────

    static int runSubscriber(Dcps.DDS.DomainParticipant dp, Dcps.DDS.Topic topic, Options opts) throws InterruptedException {
        Dcps.DDS.Subscriber sub = dp.create_subscriber(null, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber returned null");
            return 1;
        }

        Dcps.DDS.DataReaderQos drQos = buildReaderQos(opts);
        Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
            public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus s) {}
            public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
            public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
            public void on_data_available(Dcps.DDS.DataReader r) {}
            public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
            public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}

            public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus status) {
                System.out.printf("on_requested_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)%n",
                        opts.topicName, status.get_last_policy_id(), policyName(status.get_last_policy_id()));
            }
        };

        Dcps.DDS.DataReader dr = sub.create_datareader(topic, drQos, listener, Dcps.DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS.value);
        if (dr == null) {
            System.err.println("FAIL: create_datareader returned null");
            return 1;
        }
        ShapeTypeDataReader typedReader = new ShapeTypeDataReader(dr);

        System.out.println("Create reader for topic: " + opts.topicName);

        long iteration = 0;
        while (!allDone.get()) {
            if (opts.numIterations >= 0 && iteration >= opts.numIterations) break;

            // Plain take() (FIFO, not grouped-by-instance like the other three
            // ports' take_next_instance loop) -- zidl's Java --generate-zzdds-wrappers
            // doesn't emit a take_next_instance wrapper. Doesn't affect this
            // example's output (order among received samples isn't checked).
            ShapeTypeDataReader.Sample sample;
            while ((sample = typedReader.take()) != null) {
                if (!sample.validData) continue;
                System.out.printf("%-10s %-10s %03d %03d [%d]%n",
                        opts.topicName, sample.data.get_color(), sample.data.get_x(),
                        sample.data.get_y(), sample.data.get_shapesize());
            }

            iteration++;
            Thread.sleep(opts.readPeriodMs);
        }
        return 0;
    }

    // ── Argument parsing ────────────────────────────────────────────────────

    static int parseArgs(String[] args, Options opts) {
        for (int i = 0; i < args.length; i++) {
            String arg = args[i];
            switch (arg) {
                case "-P": opts.publish = true; break;
                case "-S": opts.subscribe = true; break;
                case "-b": opts.bestEffort = true; break;
                case "-r": opts.reliable = true; break;
                case "-w": opts.printWriterSamples = true; break;
                case "-d":
                    if (++i >= args.length) return -1;
                    opts.domainId = Integer.parseInt(args[i]);
                    break;
                case "-k":
                    if (++i >= args.length) return -1;
                    opts.historyDepth = Integer.parseInt(args[i]);
                    break;
                case "-t":
                    if (++i >= args.length) return -1;
                    opts.topicName = args[i];
                    break;
                case "-c":
                    if (++i >= args.length) return -1;
                    opts.color = args[i];
                    break;
                case "-D":
                    if (++i >= args.length) return -1;
                    opts.durability = args[i].isEmpty() ? 'v' : args[i].charAt(0);
                    break;
                case "-z":
                    if (++i >= args.length) return -1;
                    opts.shapesize = Integer.parseInt(args[i]);
                    break;
                case "--write-period":
                    if (++i >= args.length) return -1;
                    opts.writePeriodMs = Long.parseLong(args[i]);
                    break;
                case "--read-period":
                    if (++i >= args.length) return -1;
                    opts.readPeriodMs = Long.parseLong(args[i]);
                    break;
                case "-i":
                case "--num-iterations":
                    if (++i >= args.length) return -1;
                    opts.numIterations = Long.parseLong(args[i]);
                    break;
                case "--config":
                    if (++i >= args.length) return -1;
                    opts.configPath = args[i];
                    break;
                case "-h":
                case "--help":
                    System.out.print(
                        "Usage: java ShapeMain -P|-S [options]\n" +
                        "\n" +
                        "Mode (required):\n" +
                        "  -P                  Publisher\n" +
                        "  -S                  Subscriber\n" +
                        "\n" +
                        "QoS:\n" +
                        "  -b                  BEST_EFFORT reliability (default: RELIABLE)\n" +
                        "  -r                  RELIABLE reliability (explicit)\n" +
                        "  -k <depth>          History depth; 0 = KEEP_ALL (default: KEEP_LAST 1)\n" +
                        "  -D v|l|t|p          Durability: volatile, transient-local, transient, persistent\n" +
                        "\n" +
                        "Topic / data:\n" +
                        "  -t <name>           Topic name (default: Square)\n" +
                        "  -c <color>          Color / key value (default: BLUE)\n" +
                        "  -z <size>           Shape size; 0 = auto-increment each sample (default: 20)\n" +
                        "\n" +
                        "Timing / iterations:\n" +
                        "  -i, --num-iterations <n>   Stop after n samples (-1 = infinite, default)\n" +
                        "  --write-period <ms>         Publish interval in ms (default: 33)\n" +
                        "  --read-period <ms>          Read poll interval in ms (default: 100)\n" +
                        "\n" +
                        "Other:\n" +
                        "  -d <id>             Domain ID (default: 0)\n" +
                        "  -w                  Print each sample on the writer side\n" +
                        "  --config <path>     Copy a zzdds.toml-style config file to ./zzdds.toml before\n" +
                        "                      creating the factory -- zzdds's own ambient lazy-resolve then\n" +
                        "                      picks it up automatically (see zzdds-examples/config/ for\n" +
                        "                      example scenarios; see this port's README for why this is a\n" +
                        "                      copy rather than a direct call, unlike the other three ports)\n" +
                        "  -h, --help          Show this help and exit\n" +
                        "\n" +
                        "This Java port implements the \"Must-have (v1)\" flag subset only -- see\n" +
                        "zig/shape -h for the full CLI/behavior spec (stretch flags not yet ported).\n"
                    );
                    System.exit(0);
                    break;
                default:
                    System.err.println("warning: unrecognised option: " + arg);
                    break;
            }
        }
        return 0;
    }

    // ── main ────────────────────────────────────────────────────────────────

    public static void main(String[] args) throws Exception {
        Runtime.getRuntime().addShutdownHook(new Thread(() -> allDone.set(true)));

        Options opts = new Options();
        if (parseArgs(args, opts) != 0) {
            System.err.println("argument error");
            System.exit(1);
        }

        if (!opts.publish && !opts.subscribe) {
            System.err.println("specify -P (publish) or -S (subscribe)");
            System.exit(1);
        }

        if (opts.configPath != null) {
            // MVP option from docs/design/shape-reference-app.md: no
            // zzdds_process_configure_from_file JNI wrapper exists yet (grepped
            // every `native` declaration in ZzddsRuntime.java -- confirmed
            // absent), so stage the chosen file as ./zzdds.toml before the
            // first factory is created in this process; zzdds's own ambient
            // lazy-resolve (config/process.zig's getForNewFactory) picks up a
            // file with exactly that name/location with zero explicit call --
            // the same mechanism this example's own zzdds.toml (if any) would
            // rely on, just staged at run time instead of build time.
            //
            // A real, pre-existing ./zzdds.toml in this cwd must not be
            // permanently destroyed by staging ours over it -- back it up and
            // restore it on exit via the same shutdown-hook mechanism as
            // allDone above, so it survives Ctrl-C/SIGTERM as well as a
            // normal run, not just System.exit(1) below on a copy failure.
            java.nio.file.Path target = Paths.get("zzdds.toml");
            java.nio.file.Path backup = Paths.get("zzdds.toml.orig." + ProcessHandle.current().pid());
            try {
                if (Files.exists(target)) {
                    Files.move(target, backup, StandardCopyOption.REPLACE_EXISTING);
                    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                        try {
                            Files.move(backup, target, StandardCopyOption.REPLACE_EXISTING);
                        } catch (java.io.IOException ignored) {
                        }
                    }));
                } else {
                    Runtime.getRuntime().addShutdownHook(new Thread(() -> {
                        try {
                            Files.deleteIfExists(target);
                        } catch (java.io.IOException ignored) {
                        }
                    }));
                }
                Files.copy(Paths.get(opts.configPath), target, StandardCopyOption.REPLACE_EXISTING);
            } catch (java.io.IOException e) {
                System.err.println("failed to load config file '" + opts.configPath + "': " + e.getMessage());
                System.exit(1);
            }
        }

        Dcps.DDS.DomainParticipantFactory factory =
            (Dcps.DDS.DomainParticipantFactory) io.zzdds.runtime.ZzddsRuntime.createFactory();
        if (factory == null) {
            System.err.println("FAIL: createFactory() returned null");
            System.exit(1);
        }

        Dcps.DDS.DomainParticipant dp = factory.create_participant(opts.domainId, null, null, 0);
        if (dp == null) {
            System.err.println("failed to create participant on domain " + opts.domainId);
            System.exit(1);
        }

        int rc = ShapeTypeTypeSupport.register(dp, null);
        if (rc != Dcps.DDS.RETCODE_OK.value) {
            System.err.println("FAIL: TypeSupport.register rc=" + rc);
            System.exit(1);
        }

        Dcps.DDS.Topic topic = dp.create_topic(opts.topicName, "ShapeType", null, null, 0);
        if (topic == null) {
            System.err.println("failed to create topic '" + opts.topicName + "'");
            System.exit(1);
        }
        System.out.println("Create topic: " + opts.topicName);

        int exitCode = opts.publish ? runPublisher(dp, topic, opts) : runSubscriber(dp, topic, opts);
        System.exit(exitCode);
    }
}
