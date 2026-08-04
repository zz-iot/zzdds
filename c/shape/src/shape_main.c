/*
 * C port of zig/shape's shape_main -- the OMG DDS-Interoperability "Shapes"
 * demo app, talking to zzdds through its C ABI. CLI/behavior spec is
 * dds-rtps's srcZig/shape_main.zig (see zig/shape); this implements the
 * "Must-have (v1)" flag subset from docs/design/shape-reference-app.md plus
 * --config -- not the stretch flags (deadline, lifespan, ownership
 * strength, xcdr repr, partition, multi-instance/topic,
 * additional-payload/size-modulo, content-filtering, presentation/coherent,
 * take-read/read-only). One binary, -P/-S selects mode, matching the
 * dds-rtps interop harness convention of one binary path for both roles.
 */
#include "shape.h"
#include "zzdds_c.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>

/* ── Options ─────────────────────────────────────────────────────────────── */

typedef struct {
    bool publish;
    bool subscribe;
    uint32_t domain_id;
    bool best_effort;
    bool reliable;
    int32_t history_depth; /* -1 = use default KEEP_LAST 1 */
    const char *topic_name;
    const char *color;
    char durability; /* 'v', 'l', 't', 'p' */
    bool print_writer_samples;
    int32_t shapesize;
    long write_period_ms;
    long read_period_ms;
    int64_t num_iterations; /* -1 = infinite */
    const char *config_path;
} Options;

static Options default_options(void) {
    Options o;
    memset(&o, 0, sizeof(o));
    o.history_depth = -1;
    o.topic_name = "Square";
    o.color = "BLUE";
    o.durability = 'v';
    o.shapesize = 20;
    o.write_period_ms = 33;
    o.read_period_ms = 100;
    o.num_iterations = -1;
    return o;
}

/* ── Policy name mapping (matches zig/shape's policyName()) ────────────────── */

static const char *policy_name(DDS_QosPolicyId_t id) {
    switch (id) {
        case DDS_DURABILITY_QOS_POLICY_ID: return "DURABILITY";
        case DDS_DEADLINE_QOS_POLICY_ID: return "DEADLINE";
        case DDS_LATENCYBUDGET_QOS_POLICY_ID: return "LATENCYBUDGET";
        case DDS_OWNERSHIP_QOS_POLICY_ID: return "OWNERSHIP";
        case DDS_LIVELINESS_QOS_POLICY_ID: return "LIVELINESS";
        case DDS_PARTITION_QOS_POLICY_ID: return "PARTITION";
        case DDS_RELIABILITY_QOS_POLICY_ID: return "RELIABILITY";
        case DDS_DESTINATIONORDER_QOS_POLICY_ID: return "DESTINATIONORDER";
        case DDS_DATAREPRESENTATION_QOS_POLICY_ID: return "DATAREPRESENTATION";
        default: return "UNKNOWN";
    }
}

/* ── Signal handling ───────────────────────────────────────────────────────── */

static volatile sig_atomic_t g_all_done = 0;

static void handle_sigint(int sig) {
    (void)sig;
    g_all_done = 1;
}

/* ── Time helpers ──────────────────────────────────────────────────────────── */

static int64_t mono_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (int64_t)ts.tv_sec * 1000000000LL + ts.tv_nsec;
}

/* ── Listener contexts ─────────────────────────────────────────────────────── */

typedef struct {
    const char *topic_name;
} ListenerCtx;

static void on_offered_incompatible_qos(
    DDS_DataWriter writer,
    const DDS_OfferedIncompatibleQosStatus *status,
    void *listener_data
) {
    (void)writer;
    const ListenerCtx *lc = (const ListenerCtx *)listener_data;
    printf("on_offered_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)\n",
           lc->topic_name, (int)status->last_policy_id, policy_name(status->last_policy_id));
}

static void on_requested_incompatible_qos(
    DDS_DataReader reader,
    const DDS_RequestedIncompatibleQosStatus *status,
    void *listener_data
) {
    (void)reader;
    const ListenerCtx *lc = (const ListenerCtx *)listener_data;
    printf("on_requested_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)\n",
           lc->topic_name, (int)status->last_policy_id, policy_name(status->last_policy_id));
}

/* ── QoS builders ──────────────────────────────────────────────────────────── */

/* -r forces RELIABLE even if -b was also passed; otherwise -b selects
 * BEST_EFFORT and everything else (including the no-flags case) is
 * RELIABLE -- matches zig/shape's buildWriterQos/buildReaderQos exactly. */
static DDS_ReliabilityQosPolicyKind reliability_kind(const Options *opts) {
    if (opts->best_effort && !opts->reliable) return DDS_ReliabilityQosPolicyKind_BEST_EFFORT_RELIABILITY_QOS;
    return DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
}

static DDS_DurabilityQosPolicyKind durability_kind(char d) {
    switch (d) {
        case 'l': return DDS_DurabilityQosPolicyKind_TRANSIENT_LOCAL_DURABILITY_QOS;
        case 't': return DDS_DurabilityQosPolicyKind_TRANSIENT_DURABILITY_QOS;
        case 'p': return DDS_DurabilityQosPolicyKind_PERSISTENT_DURABILITY_QOS;
        default: return DDS_DurabilityQosPolicyKind_VOLATILE_DURABILITY_QOS;
    }
}

/* zig/shape always explicitly offers/requests a one-element
 * DataRepresentationId sequence (XCDR1 by default) rather than leaving it
 * empty -- an empty sequence here is DATAREPRESENTATION-incompatible with
 * that against zzdds's QoS matching (confirmed by cross-binding testing:
 * before this was added, every C<->Zig pair failed to match with
 * on_offered/on_requested_incompatible_qos() : 23 (DATAREPRESENTATION)).
 * Static storage, so _release must stay false -- nothing ever frees it. */
static DDS_DataRepresentationId_t g_default_repr = DDS_XCDR_DATA_REPRESENTATION;

static void set_default_representation(DDS_DataRepresentationQosPolicy *repr) {
    repr->value._buffer = &g_default_repr;
    repr->value._length = 1;
    repr->value._maximum = 1;
    repr->value._release = false;
}

static void build_writer_qos(DDS_DataWriterQos *qos, const Options *opts) {
    /* Zero-init, not DDS_DataWriterQos_default() -- dcps.idl declares no
     * @default annotations at all, so IDL-default == zero-value for every
     * QoS policy field here; DDS_DataWriterQos_default is declared in
     * dcps.h but not actually exported by libzzdds.so (verified via
     * `nm -D libzzdds.so` -- a real zzdds C-ABI codegen gap, out of scope
     * for this examples-repo work). */
    memset(qos, 0, sizeof(*qos));
    qos->reliability.kind = reliability_kind(opts);
    if (opts->history_depth == 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    } else if (opts->history_depth > 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
        qos->history.depth = opts->history_depth;
    }
    qos->durability.kind = durability_kind(opts->durability);
    set_default_representation(&qos->data_representation);
}

static void build_reader_qos(DDS_DataReaderQos *qos, const Options *opts) {
    /* See build_writer_qos's comment: zero-init, not DDS_DataReaderQos_default(). */
    memset(qos, 0, sizeof(*qos));
    qos->reliability.kind = reliability_kind(opts);
    if (opts->history_depth == 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    } else if (opts->history_depth > 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
        qos->history.depth = opts->history_depth;
    }
    qos->durability.kind = durability_kind(opts->durability);
    set_default_representation(&qos->data_representation);
}

/* ── Publisher ─────────────────────────────────────────────────────────────── */

static int run_publisher(DDS_DomainParticipant dp, DDS_Topic topic, const Options *opts) {
    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher returned NULL\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    build_writer_qos(&dw_qos, opts);

    ListenerCtx lc = { .topic_name = opts->topic_name };
    DDS_DataWriterListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &lc;
    listener.on_offered_incompatible_qos = on_offered_incompatible_qos;

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(
        pub, topic, &dw_qos, &listener, DDS_OFFERED_INCOMPATIBLE_QOS_STATUS);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter returned NULL\n");
        return 1;
    }

    ShapeTypeDataWriter typed_writer;
    ShapeTypeDataWriter_init(&typed_writer, dw, ZIDL_XCDR1);

    printf("Create writer for topic: %s color: %s\n", opts->topic_name, opts->color);

    ShapeType shape;
    memset(&shape, 0, sizeof(shape));
    strncpy(shape.color, opts->color, sizeof(shape.color) - 1);
    shape.shapesize = (opts->shapesize == 0) ? 1 : opts->shapesize;

    srand((unsigned)mono_ns());

    const int64_t match_deadline = mono_ns() + 10LL * 1000000000LL;
    bool printed_matched = false;

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts->num_iterations >= 0 && iteration >= opts->num_iterations) break;

        if (!printed_matched) {
            DDS_PublicationMatchedStatus status;
            memset(&status, 0, sizeof(status));
            DDS_DataWriter_get_publication_matched_status(dw, &status);
            if (status.current_count > 0) {
                printf("on_publication_matched() topic: '%s'  type: 'ShapeType' : matched readers %d (change = 1)\n",
                       opts->topic_name, (int)status.current_count);
                printed_matched = true;
            } else if (mono_ns() > match_deadline) {
                return 0; /* READER_NOT_MATCHED */
            }
        }

        shape.x = rand() % 320;
        shape.y = rand() % 240;

        int rc = ShapeTypeDataWriter_write(&typed_writer, &shape, DDS_HANDLE_NIL);
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: DataWriter_write (rc=%d)\n", rc);
            return 1;
        }
        if (opts->print_writer_samples) {
            printf("%-10s %-10s %03d %03d [%d]\n",
                   opts->topic_name, shape.color, (int)shape.x, (int)shape.y, (int)shape.shapesize);
        }
        if (opts->shapesize == 0) {
            shape.shapesize++;
        }

        iteration++;
        usleep((useconds_t)(opts->write_period_ms * 1000));
    }

    if (opts->num_iterations >= 0) {
        DDS_Duration_t ack_timeout = { .sec = 5, .nanosec = 0 };
        DDS_Publisher_wait_for_acknowledgments(pub, &ack_timeout);
    }
    return 0;
}

/* ── Subscriber ────────────────────────────────────────────────────────────── */

static int run_subscriber(DDS_DomainParticipant dp, DDS_Topic topic, const Options *opts) {
    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber returned NULL\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    build_reader_qos(&dr_qos, opts);

    ListenerCtx lc = { .topic_name = opts->topic_name };
    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &lc;
    listener.on_requested_incompatible_qos = on_requested_incompatible_qos;

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(
        sub, topic_desc, &dr_qos, &listener, DDS_REQUESTED_INCOMPATIBLE_QOS_STATUS);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader returned NULL\n");
        return 1;
    }

    ShapeTypeDataReader typed_reader;
    ShapeTypeDataReader_init(&typed_reader, dr);

    printf("Create reader for topic: %s\n", opts->topic_name);

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts->num_iterations >= 0 && iteration >= opts->num_iterations) break;

        /* HANDLE_NIL every call (not the last-seen handle) drains each
         * instance fully before moving to the next -- matches
         * zig/shape's take_next_instance loop. */
        for (;;) {
            ShapeType value;
            zzdds_sample_info info;
            memset(&value, 0, sizeof(value));
            memset(&info, 0, sizeof(info));
            uint8_t buf[256];
            size_t cdr_len = 0;

            int rc = ShapeTypeDataReader_take_next_instance(
                &typed_reader, &value, &info, DDS_HANDLE_NIL, buf, sizeof(buf), &cdr_len);
            if (rc != DDS_RETCODE_OK || !info.valid_data) break;

            printf("%-10s %-10s %03d %03d [%d]\n",
                   opts->topic_name, value.color, (int)value.x, (int)value.y, (int)value.shapesize);
        }

        iteration++;
        usleep((useconds_t)(opts->read_period_ms * 1000));
    }
    return 0;
}

/* ── Argument parsing ──────────────────────────────────────────────────────── */

static int parse_args(int argc, char **argv, Options *opts) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "-P") == 0) {
            opts->publish = true;
        } else if (strcmp(arg, "-S") == 0) {
            opts->subscribe = true;
        } else if (strcmp(arg, "-b") == 0) {
            opts->best_effort = true;
        } else if (strcmp(arg, "-r") == 0) {
            opts->reliable = true;
        } else if (strcmp(arg, "-w") == 0) {
            opts->print_writer_samples = true;
        } else if (strcmp(arg, "-d") == 0) {
            if (++i >= argc) return -1;
            opts->domain_id = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "-k") == 0) {
            if (++i >= argc) return -1;
            opts->history_depth = (int32_t)strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "-t") == 0) {
            if (++i >= argc) return -1;
            opts->topic_name = argv[i];
        } else if (strcmp(arg, "-c") == 0) {
            if (++i >= argc) return -1;
            opts->color = argv[i];
        } else if (strcmp(arg, "-D") == 0) {
            if (++i >= argc) return -1;
            opts->durability = argv[i][0] ? argv[i][0] : 'v';
        } else if (strcmp(arg, "-z") == 0) {
            if (++i >= argc) return -1;
            opts->shapesize = (int32_t)strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "--write-period") == 0) {
            if (++i >= argc) return -1;
            opts->write_period_ms = strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "--read-period") == 0) {
            if (++i >= argc) return -1;
            opts->read_period_ms = strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "-i") == 0 || strcmp(arg, "--num-iterations") == 0) {
            if (++i >= argc) return -1;
            opts->num_iterations = strtoll(argv[i], NULL, 10);
        } else if (strcmp(arg, "--config") == 0) {
            if (++i >= argc) return -1;
            opts->config_path = argv[i];
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            printf(
                "Usage: shape_main -P|-S [options]\n"
                "\n"
                "Mode (required):\n"
                "  -P                  Publisher\n"
                "  -S                  Subscriber\n"
                "\n"
                "QoS:\n"
                "  -b                  BEST_EFFORT reliability (default: RELIABLE)\n"
                "  -r                  RELIABLE reliability (explicit)\n"
                "  -k <depth>          History depth; 0 = KEEP_ALL (default: KEEP_LAST 1)\n"
                "  -D v|l|t|p          Durability: volatile, transient-local, transient, persistent\n"
                "\n"
                "Topic / data:\n"
                "  -t <name>           Topic name (default: Square)\n"
                "  -c <color>          Color / key value (default: BLUE)\n"
                "  -z <size>           Shape size; 0 = auto-increment each sample (default: 20)\n"
                "\n"
                "Timing / iterations:\n"
                "  -i, --num-iterations <n>   Stop after n samples (-1 = infinite, default)\n"
                "  --write-period <ms>         Publish interval in ms (default: 33)\n"
                "  --read-period <ms>          Read poll interval in ms (default: 100)\n"
                "\n"
                "Other:\n"
                "  -d <id>             Domain ID (default: 0)\n"
                "  -w                  Print each sample on the writer side\n"
                "  --config <path>     Load a zzdds.toml-style config file as the process-wide\n"
                "                      default participant config before creating the factory\n"
                "                      (see zzdds-examples/config/ for example scenarios)\n"
                "  -h, --help          Show this help and exit\n"
                "\n"
                "This C port implements the \"Must-have (v1)\" flag subset only -- see\n"
                "zig/shape -h for the full CLI/behavior spec (stretch flags not yet ported).\n"
            );
            exit(0);
        } else {
            fprintf(stderr, "warning: unrecognised option: %s\n", arg);
        }
    }
    return 0;
}

/* ── main ──────────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    signal(SIGINT, handle_sigint);

    Options opts = default_options();
    if (parse_args(argc, argv, &opts) != 0) {
        fprintf(stderr, "argument error\n");
        return 1;
    }

    if (!opts.publish && !opts.subscribe) {
        fprintf(stderr, "specify -P (publish) or -S (subscribe)\n");
        return 1;
    }

    if (opts.config_path) {
        DDS_ReturnCode_t cfg_rc = zzdds_process_configure_from_file(opts.config_path, NULL);
        if (cfg_rc != DDS_RETCODE_OK) {
            fprintf(stderr, "failed to load config file '%s' (rc=%d)\n", opts.config_path, (int)cfg_rc);
            return 1;
        }
    }

    zzdds_DomainParticipantFactory factory = zzdds_create_factory();
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: zzdds_create_factory returned nil\n");
        return 1;
    }
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, opts.domain_id, NULL, NULL, 0);
    if (!dp) {
        fprintf(stderr, "failed to create participant on domain %u\n", opts.domain_id);
        zzdds_destroy_factory(factory);
        return 1;
    }

    zzdds_register_type_support_c(dp, "ShapeType", ShapeType_compute_key_hash_from_cdr);

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, opts.topic_name, "ShapeType", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "failed to create topic '%s'\n", opts.topic_name);
        zzdds_destroy_factory(factory);
        return 1;
    }
    printf("Create topic: %s\n", opts.topic_name);

    int rc = opts.publish ? run_publisher(dp, topic, &opts) : run_subscriber(dp, topic, &opts);

    zzdds_destroy_factory(factory);
    return rc;
}
