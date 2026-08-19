// Java port of zig/shape's shape_main -- the OMG DDS-Interoperability
// "Shapes" demo app, talking to zzdds through its Java binding (JNI). CLI/
// behavior spec is dds-rtps's srcZig/shape_main.zig (see zig/shape); this now
// implements the full stretch-flag set from docs/design/shape-reference-app.md,
// matching zig/shape's and c/shape's/cpp/shape's semantics (deadline, lifespan,
// ownership strength, xcdr repr, partition, multi-instance/topic,
// additional-payload/size-modulo, content-filtering, presentation/coherent,
// take-read/read-only), including take_next_instance/take_n/read_n now that
// zidl's Java --generate-zzdds-wrappers backend generates them (it didn't
// used to -- see runSubscriber's read loop below for the same per-instance-
// drain/bulk-read semantics C/C++/Zig already had).
//
// One class, -P/-S selects publisher/subscriber mode, matching the other
// three ports and the dds-rtps interop harness convention of one binary
// (here: one `java ShapeMain ...` invocation) handed to both roles.

import io.zzdds.dcps.Dcps;
import io.zzdds.runtime.ZzddsRuntime;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.concurrent.atomic.AtomicBoolean;

public class ShapeMain {

    static final int MAX_TOPICS = 16;
    static final int MAX_SAMPLES_PER_READ = 256;

    // ── Options ─────────────────────────────────────────────────────────────

    static class Options {
        boolean publish = false;
        boolean subscribe = false;
        int domainId = 0;
        boolean bestEffort = false;
        boolean reliable = false;
        int historyDepth = -1; // -1 = use default KEEP_LAST 1
        long deadlineMs = 0; // 0 = infinite (no DEADLINE QoS)
        long lifespanMs = 0; // 0 = infinite
        int ownershipStrength = -1; // -1 = SHARED
        String topicName = "Square";
        String color = null;
        String partition = null;
        char durability = 'v'; // 'v', 'l', 't', 'p'
        int dataRepresentation = 1; // 1=XCDR1, 2=XCDR2
        boolean printWriterSamples = false;
        int shapesize = 20;
        long writePeriodMs = 33;
        long readPeriodMs = 100;
        long numIterations = -1; // -1 = infinite
        int numInstances = 1;
        int additionalPayload = 0;
        int sizeModulo = 0;
        String cftExpression = null;
        long timeFilterMs = 0;
        char finalInstanceState = 0; // 0, 'u', 'd'
        char accessScope = 'i'; // 'i', 't', 'g'
        boolean orderedAccess = false;
        boolean coherentAccess = false;
        int numTopics = 1;
        boolean takeRead = false;
        boolean readOnly = false;
        int coherentSampleCount = 0;
        int periodicAnnouncementMs = 0;
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

    static Dcps.DDS.PresentationQosPolicyAccessScopeKind accessScopeKind(char c) {
        switch (c) {
            case 't': return Dcps.DDS.PresentationQosPolicyAccessScopeKind.TOPIC_PRESENTATION_QOS;
            case 'g': return Dcps.DDS.PresentationQosPolicyAccessScopeKind.GROUP_PRESENTATION_QOS;
            default: return Dcps.DDS.PresentationQosPolicyAccessScopeKind.INSTANCE_PRESENTATION_QOS;
        }
    }

    // Matches the other three ports: explicitly offer/request a one-element
    // [XCDR_DATA_REPRESENTATION | XCDR2_DATA_REPRESENTATION] list rather than
    // leaving the field empty -- an empty sequence is DATAREPRESENTATION-
    // incompatible with that under zzdds's QoS matching (see c/shape's
    // README). -x selects XCDR1 (default) vs XCDR2 via this same mechanism.
    static void setRepresentation(Dcps.DDS.DataRepresentationQosPolicy repr, int dataRepresentation) {
        short id = (dataRepresentation == 2) ? Dcps.DDS.XCDR2_DATA_REPRESENTATION.value : Dcps.DDS.XCDR_DATA_REPRESENTATION.value;
        repr.set_value(Collections.singletonList(id));
    }

    // Matches zig/shape's buildWriterQos/buildReaderQos: sec/nanosec split
    // from a plain millisecond count.
    static Dcps.DDS.Duration_t durationFromMs(long ms) {
        return new Dcps.DDS.Duration_t((int) (ms / 1000), (int) ((ms % 1000) * 1_000_000));
    }

    static Dcps.DDS.DataWriterQos buildWriterQos(Dcps.DDS.Publisher pub, Options opts) {
        Dcps.DDS.DataWriterQos qos = new Dcps.DDS.DataWriterQos();
        if (pub.get_default_datawriter_qos(qos) != Dcps.DDS.RETCODE_OK.value) {
            throw new RuntimeException("get_default_datawriter_qos() failed");
        }
        qos.get_reliability().set_kind(reliabilityKind(opts));
        if (opts.historyDepth == 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        } else if (opts.historyDepth > 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
            qos.get_history().set_depth(opts.historyDepth);
        }
        if (opts.deadlineMs > 0) {
            qos.get_deadline().set_period(durationFromMs(opts.deadlineMs));
        }
        if (opts.lifespanMs > 0) {
            qos.get_lifespan().set_duration(durationFromMs(opts.lifespanMs));
        }
        if (opts.ownershipStrength >= 0) {
            qos.get_ownership().set_kind(Dcps.DDS.OwnershipQosPolicyKind.EXCLUSIVE_OWNERSHIP_QOS);
            qos.get_ownership_strength().set_value(opts.ownershipStrength);
        }
        qos.get_durability().set_kind(durabilityKind(opts.durability));
        setRepresentation(qos.get_data_representation(), opts.dataRepresentation);
        return qos;
    }

    static Dcps.DDS.DataReaderQos buildReaderQos(Dcps.DDS.Subscriber sub, Options opts) {
        Dcps.DDS.DataReaderQos qos = new Dcps.DDS.DataReaderQos();
        if (sub.get_default_datareader_qos(qos) != Dcps.DDS.RETCODE_OK.value) {
            throw new RuntimeException("get_default_datareader_qos() failed");
        }
        qos.get_reliability().set_kind(reliabilityKind(opts));
        if (opts.historyDepth == 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_ALL_HISTORY_QOS);
        } else if (opts.historyDepth > 0) {
            qos.get_history().set_kind(Dcps.DDS.HistoryQosPolicyKind.KEEP_LAST_HISTORY_QOS);
            qos.get_history().set_depth(opts.historyDepth);
        }
        if (opts.deadlineMs > 0) {
            qos.get_deadline().set_period(durationFromMs(opts.deadlineMs));
        }
        if (opts.ownershipStrength >= 0) {
            qos.get_ownership().set_kind(Dcps.DDS.OwnershipQosPolicyKind.EXCLUSIVE_OWNERSHIP_QOS);
        }
        if (opts.timeFilterMs > 0) {
            qos.get_time_based_filter().set_minimum_separation(durationFromMs(opts.timeFilterMs));
        }
        qos.get_durability().set_kind(durabilityKind(opts.durability));
        setRepresentation(qos.get_data_representation(), opts.dataRepresentation);
        return qos;
    }

    // ── Multi-topic helpers ──────────────────────────────────────────────────

    static class ExtraTopics {
        List<Dcps.DDS.Topic> topics = new ArrayList<>();
        List<String> names = new ArrayList<>();
    }

    static Dcps.DDS.Topic topicAt(Dcps.DDS.Topic base, ExtraTopics et, int i) {
        return (i == 0) ? base : et.topics.get(i - 1);
    }

    static String nameAt(String baseName, ExtraTopics et, int i) {
        return (i == 0) ? baseName : et.names.get(i - 1);
    }

    static ExtraTopics createExtraTopics(Dcps.DDS.DomainParticipant dp, Options opts) {
        ExtraTopics et = new ExtraTopics();
        for (int i = 1; i < opts.numTopics; i++) {
            String name = opts.topicName + i;
            System.out.println("Create topic: " + name);
            Dcps.DDS.Topic t = dp.create_topic(name, "ShapeType", null, null, 0);
            if (t == null) return null;
            et.names.add(name);
            et.topics.add(t);
        }
        return et;
    }

    // Returns color for instance index: inst=0 -> base, inst>0 -> "{base}{inst}".
    static String instanceColor(String base, int inst) {
        return (inst == 0) ? base : (base + inst);
    }

    // ── Publisher ───────────────────────────────────────────────────────────

    static int runPublisher(Dcps.DDS.DomainParticipant dp, Dcps.DDS.Topic baseTopic, Options opts) throws InterruptedException {
        String baseColor = (opts.color != null) ? opts.color : "BLUE";
        int n = opts.numTopics;

        ExtraTopics et = createExtraTopics(dp, opts);
        if (et == null) {
            System.err.println("FAIL: failed to create extra topics");
            return 1;
        }

        Dcps.DDS.PublisherQos pubQos = new Dcps.DDS.PublisherQos();
        pubQos.get_presentation().set_access_scope(accessScopeKind(opts.accessScope));
        pubQos.get_presentation().set_coherent_access(opts.coherentAccess);
        pubQos.get_presentation().set_ordered_access(opts.orderedAccess);
        if (opts.partition != null) pubQos.get_partition().set_name(Collections.singletonList(opts.partition));

        Dcps.DDS.Publisher pub = dp.create_publisher(pubQos, null, 0);
        if (pub == null) {
            System.err.println("FAIL: create_publisher returned null");
            return 1;
        }

        Dcps.DDS.DataWriterQos dwQos = buildWriterQos(pub, opts);
        int xcdrVersion = (opts.dataRepresentation == 2) ? ShapeTypeDataWriter.XCDR2 : ShapeTypeDataWriter.XCDR1;
        int dwMask = Dcps.DDS.OFFERED_INCOMPATIBLE_QOS_STATUS.value | Dcps.DDS.OFFERED_DEADLINE_MISSED_STATUS.value;

        List<String> topicNames = new ArrayList<>();
        List<Dcps.DDS.DataWriter> writers = new ArrayList<>();
        List<ShapeTypeDataWriter> typedWriters = new ArrayList<>();

        for (int i = 0; i < n; i++) {
            String tn = nameAt(opts.topicName, et, i);
            topicNames.add(tn);
            final String tnFinal = tn;
            Dcps.DDS.DataWriterListener listener = new Dcps.DDS.DataWriterListener() {
                public void on_offered_deadline_missed(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedDeadlineMissedStatus status) {
                    System.out.printf("on_offered_deadline_missed() topic: '%s'  type: 'ShapeType' : (total = %d, change = %d)%n",
                            tnFinal, status.get_total_count(), status.get_total_count_change());
                }
                public void on_liveliness_lost(Dcps.DDS.DataWriter w, Dcps.DDS.LivelinessLostStatus s) {}
                public void on_publication_matched(Dcps.DDS.DataWriter w, Dcps.DDS.PublicationMatchedStatus s) {}
                public void on_offered_incompatible_qos(Dcps.DDS.DataWriter w, Dcps.DDS.OfferedIncompatibleQosStatus status) {
                    System.out.printf("on_offered_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)%n",
                            tnFinal, status.get_last_policy_id(), policyName(status.get_last_policy_id()));
                }
            };
            Dcps.DDS.Topic t = topicAt(baseTopic, et, i);
            Dcps.DDS.DataWriter dw = pub.create_datawriter(t, dwQos, listener, dwMask);
            if (dw == null) {
                System.err.println("FAIL: create_datawriter returned null");
                return 1;
            }
            writers.add(dw);
            typedWriters.add(new ShapeTypeDataWriter(dw, xcdrVersion));
            System.out.println("Create writer for topic: " + tn + " color: " + baseColor);
        }

        Shape.ShapeType shape = new Shape.ShapeType();
        shape.set_color(baseColor);
        shape.set_shapesize(opts.shapesize == 0 ? 1 : opts.shapesize);
        if (opts.additionalPayload > 0) {
            List<Byte> buf = new ArrayList<>(Collections.nCopies(opts.additionalPayload, (byte) 0));
            buf.set(opts.additionalPayload - 1, (byte) 0xFF);
            shape.set_additional_payload_size(buf);
        }

        java.util.Random rand = new java.util.Random();

        long matchDeadline = System.nanoTime() + 10_000_000_000L;
        boolean printedMatched = false;

        // Coherent set gating: each outer write-loop iteration is one whole
        // coherent window. Default sc=1 when coherent_access is enabled
        // without an explicit count, so PID_COHERENT_SET is still emitted
        // for single-sample sets (required by Connext).
        int sc = (opts.coherentSampleCount > 0) ? opts.coherentSampleCount : 1;
        boolean useCoherentGating = opts.coherentAccess || opts.orderedAccess;

        long iteration = 0;
        while (!allDone.get()) {
            if (opts.numIterations >= 0 && iteration >= opts.numIterations) break;

            if (!printedMatched) {
                Dcps.DDS.PublicationMatchedStatus status = new Dcps.DDS.PublicationMatchedStatus();
                writers.get(0).get_publication_matched_status(status);
                if (status.get_current_count() > 0) {
                    System.out.printf("on_publication_matched() topic: '%s'  type: 'ShapeType' : matched readers %d (change = 1)%n",
                            topicNames.get(0), status.get_current_count());
                    printedMatched = true;
                } else if (System.nanoTime() > matchDeadline) {
                    return 0; // READER_NOT_MATCHED
                }
            }

            // For coherent publishers, hold off writing until a reader has
            // matched -- Connext's GROUP coherent subscriber requires the
            // group sequence to start from 1.
            if (useCoherentGating && !printedMatched) {
                Thread.sleep(opts.writePeriodMs);
                continue;
            }

            // DEADLINE QoS is enforced automatically by zzdds's own
            // background timer -- no manual elapsed-time tracking needed
            // here; on_offered_deadline_missed() fires on its own.

            if (useCoherentGating) {
                pub.begin_coherent_changes();
                for (int ti = 0; ti < n; ti++) {
                    for (int inst = 0; inst < opts.numInstances; inst++) {
                        shape.set_color(instanceColor(baseColor, inst));
                        for (int s = 0; s < sc; s++) {
                            shape.set_x(rand.nextInt(320));
                            shape.set_y(rand.nextInt(240));
                            int rc = typedWriters.get(ti).write(shape, 0L);
                            if (rc != Dcps.DDS.RETCODE_OK.value) {
                                System.err.println("FAIL: DataWriter.write rc=" + rc);
                                return 1;
                            }
                            if (opts.printWriterSamples) {
                                System.out.printf("%-10s %-10s %03d %03d [%d]%n",
                                        topicNames.get(ti), shape.get_color(), shape.get_x(), shape.get_y(), shape.get_shapesize());
                            }
                            if (opts.shapesize == 0) {
                                shape.set_shapesize(shape.get_shapesize() + 1);
                                if (opts.sizeModulo > 0 && shape.get_shapesize() > opts.sizeModulo) shape.set_shapesize(1);
                            }
                        }
                    }
                }
                pub.end_coherent_changes();
            } else {
                shape.set_x(rand.nextInt(320));
                shape.set_y(rand.nextInt(240));

                for (int ti = 0; ti < n; ti++) {
                    for (int inst = 0; inst < opts.numInstances; inst++) {
                        shape.set_color(instanceColor(baseColor, inst));
                        int rc = typedWriters.get(ti).write(shape, 0L);
                        if (rc != Dcps.DDS.RETCODE_OK.value) {
                            System.err.println("FAIL: DataWriter.write rc=" + rc);
                            return 1;
                        }
                        if (opts.printWriterSamples) {
                            System.out.printf("%-10s %-10s %03d %03d [%d]%n",
                                    topicNames.get(ti), shape.get_color(), shape.get_x(), shape.get_y(), shape.get_shapesize());
                        }
                    }
                }
                if (opts.shapesize == 0) {
                    shape.set_shapesize(shape.get_shapesize() + 1);
                    if (opts.sizeModulo > 0 && shape.get_shapesize() > opts.sizeModulo) shape.set_shapesize(1);
                }
            }

            iteration++;
            Thread.sleep(opts.writePeriodMs);
        }

        // Unregister/dispose all instances across all topics on finite run.
        if (opts.numIterations >= 0) {
            boolean doDispose = (opts.finalInstanceState == 'd');
            for (int ti = 0; ti < n; ti++) {
                for (int inst = 0; inst < opts.numInstances; inst++) {
                    Shape.ShapeType key = new Shape.ShapeType();
                    key.set_color(instanceColor(baseColor, inst));
                    int rc = doDispose ? typedWriters.get(ti).dispose(key, 0L) : typedWriters.get(ti).unregister(key, 0L);
                    if (rc != Dcps.DDS.RETCODE_OK.value) {
                        System.err.printf("FAIL: %s() failed: %d%n", doDispose ? "dispose" : "unregister_instance", rc);
                        return 1;
                    }
                }
            }
            Dcps.DDS.Duration_t ackTimeout = new Dcps.DDS.Duration_t(5, 0);
            for (Dcps.DDS.DataWriter dw : writers) {
                int ackRc = dw.wait_for_acknowledgments(ackTimeout);
                if (ackRc != Dcps.DDS.RETCODE_OK.value && ackRc != Dcps.DDS.RETCODE_TIMEOUT.value) {
                    System.err.printf("FAIL: wait_for_acknowledgments() failed: %d%n", ackRc);
                    return 1;
                }
            }
        }
        return 0;
    }

    // ── Subscriber ──────────────────────────────────────────────────────────

    static void printNotAlive(String topicName, String color, boolean disposed) {
        System.out.printf("%-10s %-10s %s%n", topicName, color,
                disposed ? "NOT_ALIVE_DISPOSED_INSTANCE_STATE" : "NOT_ALIVE_NO_WRITERS_INSTANCE_STATE");
    }

    static int runSubscriber(Dcps.DDS.DomainParticipant dp, Dcps.DDS.Topic baseTopic, Options opts) throws InterruptedException {
        int n = opts.numTopics;

        ExtraTopics et = createExtraTopics(dp, opts);
        if (et == null) {
            System.err.println("FAIL: failed to create extra topics");
            return 1;
        }

        // Content-filtered topic for topic[0] only (when --cft or -c COLOR is
        // specified) -- matches zig/shape's effective_cft_expr synthesis.
        // Filtering is automatic, at the reader layer (ShapeType.
        // getFieldFromCdr, resolved by ZzddsRuntime.registerTypeSupport) --
        // no app-side re-checking needed.
        String effectiveCftExpr = opts.cftExpression;
        if (effectiveCftExpr == null && opts.color != null) {
            effectiveCftExpr = "color = '" + opts.color + "'";
        }
        Dcps.DDS.ContentFilteredTopic cft = null;
        if (effectiveCftExpr != null) {
            cft = dp.create_contentfilteredtopic(opts.topicName + "_cft", baseTopic, effectiveCftExpr, Collections.emptyList());
            if (cft == null) {
                System.err.println("FAIL: create_contentfilteredtopic returned null");
                return 1;
            }
        }
        final Dcps.DDS.ContentFilteredTopic cftFinal = cft;

        Dcps.DDS.SubscriberQos subQos = new Dcps.DDS.SubscriberQos();
        subQos.get_presentation().set_access_scope(accessScopeKind(opts.accessScope));
        subQos.get_presentation().set_coherent_access(opts.coherentAccess);
        subQos.get_presentation().set_ordered_access(opts.orderedAccess);
        if (opts.partition != null) subQos.get_partition().set_name(Collections.singletonList(opts.partition));

        Dcps.DDS.Subscriber sub = dp.create_subscriber(subQos, null, 0);
        if (sub == null) {
            System.err.println("FAIL: create_subscriber returned null");
            return 1;
        }

        Dcps.DDS.DataReaderQos drQos = buildReaderQos(sub, opts);
        int drMask = Dcps.DDS.REQUESTED_INCOMPATIBLE_QOS_STATUS.value | Dcps.DDS.REQUESTED_DEADLINE_MISSED_STATUS.value;

        List<String> topicNames = new ArrayList<>();
        List<Dcps.DDS.DataReader> readers = new ArrayList<>();
        List<ShapeTypeDataReader> typedReaders = new ArrayList<>();

        for (int i = 0; i < n; i++) {
            String tn = nameAt(opts.topicName, et, i);
            topicNames.add(tn);
            final String tnFinal = tn;
            Dcps.DDS.DataReaderListener listener = new Dcps.DDS.DataReaderListener() {
                public void on_requested_deadline_missed(Dcps.DDS.DataReader r, Dcps.DDS.RequestedDeadlineMissedStatus status) {
                    System.out.printf("on_requested_deadline_missed() topic: '%s'  type: 'ShapeType' : (total = %d, change = %d)%n",
                            tnFinal, status.get_total_count(), status.get_total_count_change());
                }
                public void on_sample_rejected(Dcps.DDS.DataReader r, Dcps.DDS.SampleRejectedStatus s) {}
                public void on_liveliness_changed(Dcps.DDS.DataReader r, Dcps.DDS.LivelinessChangedStatus s) {}
                public void on_data_available(Dcps.DDS.DataReader r) {}
                public void on_subscription_matched(Dcps.DDS.DataReader r, Dcps.DDS.SubscriptionMatchedStatus s) {}
                public void on_sample_lost(Dcps.DDS.DataReader r, Dcps.DDS.SampleLostStatus s) {}
                public void on_requested_incompatible_qos(Dcps.DDS.DataReader r, Dcps.DDS.RequestedIncompatibleQosStatus status) {
                    System.out.printf("on_requested_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)%n",
                            tnFinal, status.get_last_policy_id(), policyName(status.get_last_policy_id()));
                }
            };

            Dcps.DDS.TopicDescription topicDesc = (i == 0 && cftFinal != null) ? cftFinal : dp.lookup_topicdescription(tn);
            if (topicDesc == null) {
                System.err.println("FAIL: lookup_topicdescription returned null for '" + tn + "'");
                return 1;
            }
            System.out.println("Create reader for topic: " + tn);
            Dcps.DDS.DataReader dr = sub.create_datareader(topicDesc, drQos, listener, drMask);
            if (dr == null) {
                System.err.println("FAIL: create_datareader returned null");
                return 1;
            }
            readers.add(dr);
            typedReaders.add(new ShapeTypeDataReader(dr));
        }

        // Maps instance_handle -> color for recovering key identity from
        // NOT_ALIVE samples that arrive without a serialized key payload.
        HashMap<Long, String> ihCache = new HashMap<>();

        boolean useAccess = opts.coherentAccess || opts.orderedAccess;

        long iteration = 0;
        while (!allDone.get()) {
            if (opts.numIterations >= 0 && iteration >= opts.numIterations) break;

            if (useAccess) {
                if (opts.coherentAccess) System.out.println("Reading coherent sets, iteration " + iteration);
                if (opts.orderedAccess) System.out.println("Reading with ordered access, iteration " + iteration);
                sub.begin_access();
            }

            for (int ti = 0; ti < n; ti++) {
                String tn = topicNames.get(ti);
                ShapeTypeDataReader reader = typedReaders.get(ti);

                if (opts.readOnly) {
                    // -R (non-destructive read): bulk-fetch every NOT_READ
                    // sample once per topic per outer iteration (flips them
                    // to READ so they won't re-match next time), then hand
                    // them out one at a time. --take-read still picks FIFO
                    // vs grouped-by-instance ordering via the sort below --
                    // matches c/shape's equivalent read_n loop exactly.
                    ShapeTypeDataReader.Sample[] samples = reader.read_n(
                            MAX_SAMPLES_PER_READ,
                            Dcps.DDS.NOT_READ_SAMPLE_STATE.value,
                            Dcps.DDS.ANY_VIEW_STATE.value,
                            Dcps.DDS.ANY_INSTANCE_STATE.value);
                    if (!opts.takeRead) {
                        Arrays.sort(samples, (a, b) -> Long.compare(a.instanceHandle, b.instanceHandle));
                    }
                    for (ShapeTypeDataReader.Sample sample : samples) {
                        processSample(sample, tn, ihCache);
                    }
                } else if (opts.takeRead) {
                    ShapeTypeDataReader.Sample sample;
                    while ((sample = reader.take()) != null) {
                        processSample(sample, tn, ihCache);
                    }
                } else {
                    // HANDLE_NIL every call (not the last-seen handle) drains
                    // each instance fully before moving to the next -- matches
                    // zig/shape's and c/shape's take_next_instance loop.
                    ShapeTypeDataReader.Sample sample;
                    while ((sample = reader.take_next_instance(0L)) != null) {
                        processSample(sample, tn, ihCache);
                    }
                }
            }

            if (useAccess) sub.end_access();

            // DEADLINE QoS is enforced automatically by zzdds's own
            // background timer -- no manual elapsed-time tracking needed
            // here; on_requested_deadline_missed() fires on its own.

            iteration++;
            Thread.sleep(opts.readPeriodMs);
        }

        if (cft != null) dp.delete_contentfilteredtopic(cft);
        return 0;
    }

    // Handles one taken/read sample: NOT_ALIVE printing, ih-cache update, and
    // the data print line. CFT filtering (when active) already happened at
    // the reader layer -- nothing to re-check here. Returns false if the
    // sample was NOT_ALIVE (caller doesn't need to act further either way).
    static boolean processSample(ShapeTypeDataReader.Sample sample, String topicName, HashMap<Long, String> ihCache) {
        if (!sample.validData) {
            String color = (sample.data.get_color() != null && !sample.data.get_color().isEmpty())
                    ? sample.data.get_color() : ihCache.getOrDefault(sample.instanceHandle, "");
            printNotAlive(topicName, color, false);
            return false;
        }

        // Content assertions: a key (color) must never change across samples
        // of the same instance handle, and the writer only ever emits x/y in
        // [0,320)/[0,240) with shapesize >= 1 -- hard-fail if either is
        // violated.
        String cachedColor = ihCache.get(sample.instanceHandle);
        if (cachedColor != null && !cachedColor.equals(sample.data.get_color())) {
            throw new RuntimeException("instance " + sample.instanceHandle + " color changed from '"
                    + cachedColor + "' to '" + sample.data.get_color() + "'");
        }
        if (sample.data.get_x() < 0 || sample.data.get_x() >= 320
                || sample.data.get_y() < 0 || sample.data.get_y() >= 240
                || sample.data.get_shapesize() < 1) {
            throw new RuntimeException("sample out of bounds: x=" + sample.data.get_x()
                    + " y=" + sample.data.get_y() + " shapesize=" + sample.data.get_shapesize());
        }
        ihCache.put(sample.instanceHandle, sample.data.get_color());

        List<Byte> extra = sample.data.get_additional_payload_size();
        if (extra != null && !extra.isEmpty()) {
            int lastByte = extra.get(extra.size() - 1) & 0xFF;
            System.out.printf("%-10s %-10s %03d %03d [%d] {%d}%n",
                    topicName, sample.data.get_color(), sample.data.get_x(), sample.data.get_y(), sample.data.get_shapesize(), lastByte);
        } else {
            System.out.printf("%-10s %-10s %03d %03d [%d]%n",
                    topicName, sample.data.get_color(), sample.data.get_x(), sample.data.get_y(), sample.data.get_shapesize());
        }
        return true;
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
                case "-R": opts.readOnly = true; break;
                case "-d":
                    if (++i >= args.length) return -1;
                    opts.domainId = Integer.parseInt(args[i]);
                    break;
                case "-k":
                    if (++i >= args.length) return -1;
                    opts.historyDepth = Integer.parseInt(args[i]);
                    break;
                case "-f":
                case "--deadline":
                    if (++i >= args.length) return -1;
                    opts.deadlineMs = Long.parseLong(args[i]);
                    break;
                case "-s":
                    if (++i >= args.length) return -1;
                    opts.ownershipStrength = Integer.parseInt(args[i]);
                    break;
                case "-t":
                    if (++i >= args.length) return -1;
                    opts.topicName = args[i];
                    break;
                case "-c":
                    if (++i >= args.length) return -1;
                    opts.color = args[i];
                    break;
                case "-p":
                    if (++i >= args.length) return -1;
                    opts.partition = args[i];
                    break;
                case "-D":
                    if (++i >= args.length) return -1;
                    opts.durability = args[i].isEmpty() ? 'v' : args[i].charAt(0);
                    break;
                case "-x":
                    if (++i >= args.length) return -1;
                    opts.dataRepresentation = Integer.parseInt(args[i]) == 2 ? 2 : 1;
                    break;
                case "-z":
                    if (++i >= args.length) return -1;
                    opts.shapesize = Integer.parseInt(args[i]);
                    break;
                case "-n":
                case "--num-instances":
                    if (++i >= args.length) return -1;
                    opts.numInstances = Integer.parseInt(args[i]);
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
                case "--additional-payload":
                case "--additional-payload-size":
                    if (++i >= args.length) return -1;
                    opts.additionalPayload = Integer.parseInt(args[i]);
                    break;
                case "--size-modulo":
                    if (++i >= args.length) return -1;
                    opts.sizeModulo = Integer.parseInt(args[i]);
                    break;
                case "--cft":
                    if (++i >= args.length) return -1;
                    opts.cftExpression = args[i];
                    break;
                case "--time-filter":
                    if (++i >= args.length) return -1;
                    opts.timeFilterMs = Long.parseLong(args[i]);
                    break;
                case "--lifespan":
                    if (++i >= args.length) return -1;
                    opts.lifespanMs = Long.parseLong(args[i]);
                    break;
                case "--final-instance-state":
                    if (++i >= args.length) return -1;
                    opts.finalInstanceState = args[i].isEmpty() ? 0 : args[i].charAt(0);
                    break;
                case "--access-scope":
                    if (++i >= args.length) return -1;
                    opts.accessScope = args[i].isEmpty() ? 'i' : args[i].charAt(0);
                    break;
                case "--ordered":
                    opts.orderedAccess = true;
                    break;
                case "--coherent":
                    opts.coherentAccess = true;
                    break;
                case "--num-topics":
                    if (++i >= args.length) return -1;
                    opts.numTopics = Integer.parseInt(args[i]);
                    break;
                case "--take-read":
                    opts.takeRead = true;
                    break;
                case "--coherent-sample-count":
                    if (++i >= args.length) return -1;
                    opts.coherentSampleCount = Integer.parseInt(args[i]);
                    break;
                case "--periodic-announcement":
                    if (++i >= args.length) return -1;
                    opts.periodicAnnouncementMs = Integer.parseInt(args[i]);
                    break;
                case "--config":
                    if (++i >= args.length) return -1;
                    opts.configPath = args[i];
                    break;
                case "--publisher-matches":
                case "--subscriber-matches":
                    // Consume argument value and ignore -- unimplemented
                    // options; no reference implementation elsewhere in this
                    // repo defines their semantics and no interop test
                    // exercises them.
                    if (++i >= args.length) return -1;
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
                        "  -f, --deadline <ms> Deadline period in milliseconds\n" +
                        "  --lifespan <ms>     Sample lifespan in milliseconds (writer only; 0 = infinite)\n" +
                        "  -s <strength>       Ownership strength (enables EXCLUSIVE ownership)\n" +
                        "  -x 1|2              Data representation: 1=XCDR1 (default), 2=XCDR2\n" +
                        "  -p <name>           Partition name\n" +
                        "\n" +
                        "Topic / data:\n" +
                        "  -t <name>           Topic name (default: Square)\n" +
                        "  -c <color>          Color / key value (default: BLUE)\n" +
                        "  -z <size>           Shape size; 0 = auto-increment each sample (default: 20)\n" +
                        "  -n <count>          Number of instances to publish (default: 1)\n" +
                        "  --num-topics <n>    Number of topics (Square, Square1, Square2, ...) (default: 1)\n" +
                        "  --additional-payload <bytes>  Extra zero bytes appended to each sample\n" +
                        "  --size-modulo <n>   Cycle shapesize 1..n when -z 0 is active\n" +
                        "  --cft <expr>        Content filter expression (subscriber only)\n" +
                        "\n" +
                        "Timing / iterations:\n" +
                        "  -i, --num-iterations <n>   Stop after n samples (-1 = infinite, default)\n" +
                        "  --write-period <ms>         Publish interval in ms (default: 33)\n" +
                        "  --read-period <ms>          Read poll interval in ms (default: 100)\n" +
                        "\n" +
                        "Presentation / coherent:\n" +
                        "  --access-scope i|t|g        Presentation access scope (default: i)\n" +
                        "  --ordered                    Enable ordered access\n" +
                        "  --coherent                   Enable coherent access\n" +
                        "  --coherent-sample-count <n>  Samples per coherent set (0 = no gating)\n" +
                        "  --take-read                  Same as default on this port (see README)\n" +
                        "  -R                           Non-destructive read() instead of take()\n" +
                        "\n" +
                        "Other:\n" +
                        "  -d <id>             Domain ID (default: 0)\n" +
                        "  -w                  Print each sample on the writer side\n" +
                        "  --periodic-announcement <ms>  SPDP participant re-announcement period\n" +
                        "                                (0 = use zzdds's own default)\n" +
                        "  --config <path>     Copy a zzdds.toml-style config file to ./zzdds.toml before\n" +
                        "                      creating the factory -- zzdds's own ambient lazy-resolve then\n" +
                        "                      picks it up automatically (see this port's README for why\n" +
                        "                      this is a copy rather than a direct call)\n" +
                        "  -h, --help          Show this help and exit\n" +
                        "\n"
                    );
                    System.exit(0);
                    break;
                default:
                    System.err.println("warning: unrecognised option: " + arg);
                    break;
            }
        }

        if (opts.publish && opts.color == null) opts.color = "BLUE";

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

        if (opts.numTopics < 1 || opts.numTopics > MAX_TOPICS) {
            System.err.println("--num-topics must be between 1 and " + MAX_TOPICS + " (got " + opts.numTopics + ")");
            System.exit(1);
        }

        if (opts.periodicAnnouncementMs > 0) {
            // Java has no setenv (process-wide env vars are immutable from
            // inside the JVM) -- zzdds reads
            // ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS once, at factory
            // creation, from *its own process's* environment, so this would
            // need to be set before the JVM starts (e.g. by run.sh), not here.
            System.err.println("warning: --periodic-announcement has no effect in this port " +
                    "(Java cannot set its own process environment after startup -- set " +
                    "ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS before launching the JVM instead)");
        }

        if (opts.configPath != null) {
            // MVP option from docs/design/shape-reference-app.md: no
            // zzdds_process_configure_from_file JNI wrapper exists yet (grepped
            // every `native` declaration in ZzddsRuntime.java -- confirmed
            // absent), so stage the chosen file as ./zzdds.toml before the
            // first factory is created in this process; zzdds's own ambient
            // lazy-resolve (config/process.zig's getForNewFactory) picks up a
            // file with exactly that name/location with zero explicit call.
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
