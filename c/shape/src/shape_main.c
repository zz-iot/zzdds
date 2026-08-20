/*
 * C port of zig/shape's shape_main -- the OMG DDS-Interoperability "Shapes"
 * demo app, talking to zzdds through its C ABI. CLI/behavior spec is
 * dds-rtps's srcZig/shape_main.zig (see zig/shape); this now implements the
 * full stretch-flag set from docs/design/shape-reference-app.md, matching
 * zig/shape's exact semantics (deadline, lifespan, ownership strength, xcdr
 * repr, partition, multi-instance/topic, additional-payload/size-modulo,
 * content-filtering, presentation/coherent, take-read/read-only). One
 * binary, -P/-S selects mode, matching the dds-rtps interop harness
 * convention of one binary path for both roles.
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
#include <inttypes.h>

#define MAX_TOPICS 16
#define MAX_SAMPLES_PER_READ 256
#define MAX_IH_CACHE 256

/* ── Options ─────────────────────────────────────────────────────────────── */

typedef struct {
    bool publish;
    bool subscribe;
    uint32_t domain_id;
    bool best_effort;
    bool reliable;
    int32_t history_depth; /* -1 = use default KEEP_LAST 1 */
    uint64_t deadline_ms;
    uint64_t lifespan_ms; /* 0 = infinite */
    int32_t ownership_strength; /* -1 = SHARED */
    const char *topic_name;
    const char *color;
    const char *partition;
    char durability; /* 'v', 'l', 't', 'p' */
    uint16_t data_representation; /* 1=XCDR1, 2=XCDR2 */
    bool print_writer_samples;
    int32_t shapesize;
    long write_period_ms;
    long read_period_ms;
    int64_t num_iterations; /* -1 = infinite */
    uint32_t num_instances;
    uint32_t additional_payload;
    int32_t size_modulo;
    const char *cft_expression;
    uint64_t time_filter_ms;
    char final_instance_state; /* 0, 'u', 'd' */
    char access_scope; /* 'i', 't', 'g' */
    bool ordered_access;
    bool coherent_access;
    uint32_t num_topics;
    bool take_read;
    bool read_only;
    uint32_t coherent_sample_count;
    uint32_t periodic_announcement_ms;
    const char *config_path;
    uint16_t datafrag_size;
} Options;

static Options default_options(void) {
    Options o;
    memset(&o, 0, sizeof(o));
    o.history_depth = -1;
    o.ownership_strength = -1;
    o.topic_name = "Square";
    o.color = NULL;
    o.durability = 'v';
    o.data_representation = 1;
    o.shapesize = 20;
    o.write_period_ms = 33;
    o.read_period_ms = 100;
    o.num_iterations = -1;
    o.num_instances = 1;
    o.num_topics = 1;
    o.access_scope = 'i';
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

static void on_offered_deadline_missed(
    DDS_DataWriter writer,
    const DDS_OfferedDeadlineMissedStatus *status,
    void *listener_data
) {
    (void)writer;
    const ListenerCtx *lc = (const ListenerCtx *)listener_data;
    printf("on_offered_deadline_missed() topic: '%s'  type: 'ShapeType' : (total = %d, change = %d)\n",
           lc->topic_name, (int)status->total_count, (int)status->total_count_change);
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

static void on_requested_deadline_missed(
    DDS_DataReader reader,
    const DDS_RequestedDeadlineMissedStatus *status,
    void *listener_data
) {
    (void)reader;
    const ListenerCtx *lc = (const ListenerCtx *)listener_data;
    printf("on_requested_deadline_missed() topic: '%s'  type: 'ShapeType' : (total = %d, change = %d)\n",
           lc->topic_name, (int)status->total_count, (int)status->total_count_change);
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
 * DataRepresentationId sequence rather than leaving it empty -- an empty
 * sequence here is DATAREPRESENTATION-incompatible with that against
 * zzdds's QoS matching (confirmed by cross-binding testing: before this was
 * added, every C<->Zig pair failed to match with on_offered/
 * on_requested_incompatible_qos() : 23 (DATAREPRESENTATION)). -x selects
 * XCDR1 (default) vs XCDR2 via this same mechanism. Static storage, so
 * _release must stay false -- nothing ever frees it; shared between the
 * writer/reader QoS builders since only one role is ever built per process. */
static DDS_DataRepresentationId_t g_repr_value = DDS_XCDR_DATA_REPRESENTATION;

static void set_representation(DDS_DataRepresentationQosPolicy *repr, uint16_t data_representation) {
    g_repr_value = (data_representation == 2) ? DDS_XCDR2_DATA_REPRESENTATION : DDS_XCDR_DATA_REPRESENTATION;
    repr->value._buffer = &g_repr_value;
    repr->value._length = 1;
    repr->value._maximum = 1;
    repr->value._release = false;
}

static void set_duration_from_ms(DDS_Duration_t *d, uint64_t ms) {
    d->sec = (int32_t)(ms / 1000);
    d->nanosec = (uint32_t)((ms % 1000) * 1000000ULL);
}

/* Partition name storage: DDS_StringSeq's _buffer is char** (C PSM layout).
 * Static, single-element, non-owning (_release=false) -- opts->partition
 * (argv, process-lifetime) outlives every QoS use of this. */
static const char *g_partition_cstr;

static void set_partition(DDS_PartitionQosPolicy *partition, const char *name) {
    if (!name) {
        memset(partition, 0, sizeof(*partition));
        return;
    }
    g_partition_cstr = name;
    partition->name._buffer = (char **)&g_partition_cstr;
    partition->name._length = 1;
    partition->name._maximum = 1;
    partition->name._release = false;
}

static DDS_PresentationQosPolicyAccessScopeKind access_scope_kind(char c) {
    switch (c) {
        case 't': return DDS_PresentationQosPolicyAccessScopeKind_TOPIC_PRESENTATION_QOS;
        case 'g': return DDS_PresentationQosPolicyAccessScopeKind_GROUP_PRESENTATION_QOS;
        default: return DDS_PresentationQosPolicyAccessScopeKind_INSTANCE_PRESENTATION_QOS;
    }
}

static int build_writer_qos(DDS_Publisher pub, DDS_DataWriterQos *qos, const Options *opts) {
    if (DDS_Publisher_get_default_datawriter_qos(pub, qos) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_default_datawriter_qos() failed\n");
        return -1;
    }
    qos->reliability.kind = reliability_kind(opts);
    if (opts->history_depth == 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    } else if (opts->history_depth > 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
        qos->history.depth = opts->history_depth;
    }
    qos->durability.kind = durability_kind(opts->durability);
    if (opts->deadline_ms > 0) set_duration_from_ms(&qos->deadline.period, opts->deadline_ms);
    if (opts->lifespan_ms > 0) set_duration_from_ms(&qos->lifespan.duration, opts->lifespan_ms);
    if (opts->ownership_strength >= 0) {
        qos->ownership.kind = DDS_OwnershipQosPolicyKind_EXCLUSIVE_OWNERSHIP_QOS;
        qos->ownership_strength.value = opts->ownership_strength;
    }
    set_representation(&qos->data_representation, opts->data_representation);
    return 0;
}

static int build_reader_qos(DDS_Subscriber sub, DDS_DataReaderQos *qos, const Options *opts) {
    if (DDS_Subscriber_get_default_datareader_qos(sub, qos) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_default_datareader_qos() failed\n");
        return -1;
    }
    qos->reliability.kind = reliability_kind(opts);
    if (opts->history_depth == 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    } else if (opts->history_depth > 0) {
        qos->history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
        qos->history.depth = opts->history_depth;
    }
    qos->durability.kind = durability_kind(opts->durability);
    if (opts->deadline_ms > 0) set_duration_from_ms(&qos->deadline.period, opts->deadline_ms);
    if (opts->ownership_strength >= 0) qos->ownership.kind = DDS_OwnershipQosPolicyKind_EXCLUSIVE_OWNERSHIP_QOS;
    if (opts->time_filter_ms > 0) set_duration_from_ms(&qos->time_based_filter.minimum_separation, opts->time_filter_ms);
    set_representation(&qos->data_representation, opts->data_representation);
    return 0;
}

/* ── Multi-topic helpers ───────────────────────────────────────────────────── */

/* Holds the extra topics (index 1..num_topics-1) created alongside the base
 * topic. The base topic (index 0) is owned by main() and its name is
 * opts->topic_name. Mirrors zig/shape's ExtraTopics. */
typedef struct {
    DDS_Topic topics[MAX_TOPICS];
    char *names[MAX_TOPICS];
    uint32_t count;
} ExtraTopics;

static void extra_topics_free(ExtraTopics *et) {
    for (uint32_t i = 0; i < et->count; i++) free(et->names[i]);
}

static DDS_Topic topic_at(const ExtraTopics *et, DDS_Topic base, uint32_t i) {
    return (i == 0) ? base : et->topics[i - 1];
}

static const char *name_at(const ExtraTopics *et, const char *base_name, uint32_t i) {
    return (i == 0) ? base_name : et->names[i - 1];
}

static int create_extra_topics(DDS_DomainParticipant dp, const Options *opts, ExtraTopics *et) {
    memset(et, 0, sizeof(*et));
    et->count = opts->num_topics - 1;
    for (uint32_t i = 0; i < et->count; i++) {
        char buf[160];
        snprintf(buf, sizeof(buf), "%s%u", opts->topic_name, i + 1);
        et->names[i] = strdup(buf);
        printf("Create topic: %s\n", et->names[i]);
        et->topics[i] = DDS_DomainParticipant_create_topic(dp, et->names[i], "ShapeType", NULL, NULL, 0);
        if (!et->topics[i]) {
            for (uint32_t j = 0; j <= i; j++) free(et->names[j]);
            et->count = 0;
            return -1;
        }
    }
    return 0;
}

/* Returns color for instance index: inst=0 -> base, inst>0 -> "{base}{inst}". */
static const char *instance_color(const char *base, uint32_t inst, char *buf, size_t buf_size) {
    if (inst == 0) return base;
    snprintf(buf, buf_size, "%s%u", base, inst);
    return buf;
}

/* ── Publisher ─────────────────────────────────────────────────────────────── */

static int run_publisher(DDS_DomainParticipant dp, DDS_Topic base_topic, const Options *opts) {
    const char *base_color = opts->color ? opts->color : "BLUE";
    uint32_t n = opts->num_topics;

    ExtraTopics et;
    if (create_extra_topics(dp, opts, &et) != 0) {
        fprintf(stderr, "FAIL: failed to create extra topics\n");
        return 1;
    }

    DDS_PublisherQos pub_qos;
    memset(&pub_qos, 0, sizeof(pub_qos));
    pub_qos.presentation.access_scope = access_scope_kind(opts->access_scope);
    pub_qos.presentation.coherent_access = opts->coherent_access;
    pub_qos.presentation.ordered_access = opts->ordered_access;
    set_partition(&pub_qos.partition, opts->partition);

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, &pub_qos, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher returned NULL\n");
        extra_topics_free(&et);
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    if (build_writer_qos(pub, &dw_qos, opts) != 0) {
        extra_topics_free(&et);
        return 1;
    }

    ListenerCtx lctxs[MAX_TOPICS];
    DDS_DataWriter dw_handles[MAX_TOPICS];
    ShapeTypeDataWriter typed_writers[MAX_TOPICS];
    DDS_StatusMask listener_mask = DDS_OFFERED_INCOMPATIBLE_QOS_STATUS | DDS_OFFERED_DEADLINE_MISSED_STATUS;

    for (uint32_t i = 0; i < n; i++) {
        const char *tn = name_at(&et, opts->topic_name, i);
        lctxs[i].topic_name = tn;
        DDS_DataWriterListener listener;
        memset(&listener, 0, sizeof(listener));
        listener.listener_data = &lctxs[i];
        listener.on_offered_incompatible_qos = on_offered_incompatible_qos;
        listener.on_offered_deadline_missed = on_offered_deadline_missed;

        DDS_Topic t = topic_at(&et, base_topic, i);
        dw_handles[i] = DDS_Publisher_create_datawriter(pub, t, &dw_qos, &listener, listener_mask);
        if (!dw_handles[i]) {
            fprintf(stderr, "FAIL: create_datawriter returned NULL\n");
            extra_topics_free(&et);
            return 1;
        }
        ShapeTypeDataWriter_init(&typed_writers[i], dw_handles[i], (opts->data_representation == 2) ? ZIDL_XCDR2 : ZIDL_XCDR1);
        printf("Create writer for topic: %s color: %s\n", tn, base_color);
    }

    ShapeType shape;
    memset(&shape, 0, sizeof(shape));
    strncpy(shape.color, base_color, sizeof(shape.color) - 1);
    shape.shapesize = (opts->shapesize == 0) ? 1 : opts->shapesize;

    if (opts->additional_payload > 0) {
        uint8_t *payload_buf = (uint8_t *)malloc(opts->additional_payload);
        memset(payload_buf, 0, opts->additional_payload - 1);
        payload_buf[opts->additional_payload - 1] = 255;
        shape.additional_payload_size._buffer = payload_buf;
        shape.additional_payload_size._length = opts->additional_payload;
        shape.additional_payload_size._maximum = opts->additional_payload;
        shape.additional_payload_size._release = true;
    }

    srand((unsigned)mono_ns());

    const int64_t match_deadline = mono_ns() + 10LL * 1000000000LL;
    bool printed_matched = false;

    /* Coherent set gating: each outer write-loop iteration is one whole
     * coherent window (begin_coherent_changes -> `sc` consecutive samples per
     * instance -> end_coherent_changes). Default sc=1 when coherent_access is
     * enabled without an explicit count, so PID_COHERENT_SET is still emitted
     * for single-sample sets (required by Connext). */
    uint32_t sc = (opts->coherent_sample_count > 0) ? opts->coherent_sample_count : 1;
    bool use_coherent_gating = opts->coherent_access || opts->ordered_access;

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts->num_iterations >= 0 && iteration >= opts->num_iterations) break;

        if (!printed_matched) {
            DDS_PublicationMatchedStatus status;
            memset(&status, 0, sizeof(status));
            DDS_DataWriter_get_publication_matched_status(dw_handles[0], &status);
            if (status.current_count > 0) {
                printf("on_publication_matched() topic: '%s'  type: 'ShapeType' : matched readers %d (change = 1)\n",
                       lctxs[0].topic_name, (int)status.current_count);
                printed_matched = true;
            } else if (mono_ns() > match_deadline) {
                if (opts->additional_payload > 0) free(shape.additional_payload_size._buffer);
                extra_topics_free(&et);
                return 0; /* READER_NOT_MATCHED */
            }
        }

        /* For coherent publishers, hold off writing until a reader has
         * matched -- Connext's GROUP coherent subscriber requires the group
         * sequence to start from 1; writing before match would advance the
         * GSN so the subscriber joins mid-stream and never receives a
         * complete set. */
        if (use_coherent_gating && !printed_matched) {
            usleep((useconds_t)(opts->write_period_ms * 1000));
            continue;
        }

        /* DEADLINE QoS is enforced automatically by zzdds's own background
         * timer (DomainParticipantImpl.checkTimers(), driven by a per-
         * participant thread) -- no manual elapsed-time tracking needed
         * here; on_offered_deadline_missed() fires on its own. */

        if (use_coherent_gating) {
            DDS_Publisher_begin_coherent_changes(pub);
            for (uint32_t ti = 0; ti < n; ti++) {
                for (uint32_t inst = 0; inst < opts->num_instances; inst++) {
                    char color_buf[160];
                    const char *inst_color = instance_color(base_color, inst, color_buf, sizeof(color_buf));
                    strncpy(shape.color, inst_color, sizeof(shape.color) - 1);
                    shape.color[sizeof(shape.color) - 1] = '\0';
                    for (uint32_t s = 0; s < sc; s++) {
                        shape.x = rand() % 320;
                        shape.y = rand() % 240;
                        int rc = ShapeTypeDataWriter_write(&typed_writers[ti], &shape, DDS_HANDLE_NIL);
                        if (rc != DDS_RETCODE_OK) {
                            fprintf(stderr, "FAIL: DataWriter_write (rc=%d)\n", rc);
                            if (opts->additional_payload > 0) free(shape.additional_payload_size._buffer);
                            extra_topics_free(&et);
                            return 1;
                        }
                        if (opts->print_writer_samples) {
                            printf("%-10s %-10s %03d %03d [%d]\n",
                                   lctxs[ti].topic_name, inst_color, (int)shape.x, (int)shape.y, (int)shape.shapesize);
                        }
                        if (opts->shapesize == 0) {
                            shape.shapesize++;
                            if (opts->size_modulo > 0 && shape.shapesize > opts->size_modulo) shape.shapesize = 1;
                        }
                    }
                }
            }
            DDS_Publisher_end_coherent_changes(pub);
        } else {
            shape.x = rand() % 320;
            shape.y = rand() % 240;

            for (uint32_t ti = 0; ti < n; ti++) {
                for (uint32_t inst = 0; inst < opts->num_instances; inst++) {
                    char color_buf[160];
                    const char *inst_color = instance_color(base_color, inst, color_buf, sizeof(color_buf));
                    strncpy(shape.color, inst_color, sizeof(shape.color) - 1);
                    shape.color[sizeof(shape.color) - 1] = '\0';
                    int rc = ShapeTypeDataWriter_write(&typed_writers[ti], &shape, DDS_HANDLE_NIL);
                    if (rc != DDS_RETCODE_OK) {
                        fprintf(stderr, "FAIL: DataWriter_write (rc=%d)\n", rc);
                        if (opts->additional_payload > 0) free(shape.additional_payload_size._buffer);
                        extra_topics_free(&et);
                        return 1;
                    }
                    if (opts->print_writer_samples) {
                        printf("%-10s %-10s %03d %03d [%d]\n",
                               lctxs[ti].topic_name, inst_color, (int)shape.x, (int)shape.y, (int)shape.shapesize);
                    }
                }
            }
            if (opts->shapesize == 0) {
                shape.shapesize++;
                if (opts->size_modulo > 0 && shape.shapesize > opts->size_modulo) shape.shapesize = 1;
            }
        }

        iteration++;
        usleep((useconds_t)(opts->write_period_ms * 1000));
    }

    /* Unregister/dispose all instances across all topics on finite run. */
    if (opts->num_iterations >= 0) {
        bool do_dispose = (opts->final_instance_state == 'd');
        for (uint32_t ti = 0; ti < n; ti++) {
            for (uint32_t inst = 0; inst < opts->num_instances; inst++) {
                char color_buf[160];
                const char *inst_color = instance_color(base_color, inst, color_buf, sizeof(color_buf));
                ShapeType key;
                memset(&key, 0, sizeof(key));
                strncpy(key.color, inst_color, sizeof(key.color) - 1);
                DDS_ReturnCode_t rc = do_dispose
                    ? ShapeTypeDataWriter_dispose(&typed_writers[ti], &key, DDS_HANDLE_NIL)
                    : ShapeTypeDataWriter_unregister(&typed_writers[ti], &key, DDS_HANDLE_NIL);
                if (rc != DDS_RETCODE_OK) {
                    fprintf(stderr, "FAIL: %s() failed: %d\n", do_dispose ? "dispose" : "unregister_instance", rc);
                    if (opts->additional_payload > 0) free(shape.additional_payload_size._buffer);
                    extra_topics_free(&et);
                    return 1;
                }
            }
        }
        /* Wait until all reliable readers have ACKed the NOT_ALIVE changes,
         * or up to 5 s, to avoid exiting before RELIABLE transport has
         * delivered the unregister/dispose changes to matched readers. */
        DDS_Duration_t ack_timeout = { .sec = 5, .nanosec = 0 };
        for (uint32_t ti = 0; ti < n; ti++) {
            DDS_ReturnCode_t ack_rc = DDS_DataWriter_wait_for_acknowledgments(dw_handles[ti], &ack_timeout);
            if (ack_rc != DDS_RETCODE_OK && ack_rc != DDS_RETCODE_TIMEOUT) {
                fprintf(stderr, "FAIL: wait_for_acknowledgments() failed: %d\n", ack_rc);
                if (opts->additional_payload > 0) free(shape.additional_payload_size._buffer);
                extra_topics_free(&et);
                return 1;
            }
        }
    }

    if (opts->additional_payload > 0) free(shape.additional_payload_size._buffer);
    extra_topics_free(&et);
    return 0;
}

/* ── Subscriber ────────────────────────────────────────────────────────────── */

/* Maps instance_handle -> color for recovering key identity from NOT_ALIVE
 * samples that arrive without a serialized key payload. Fixed-size linear
 * cache -- ample for a demo app's instance counts. */
typedef struct {
    DDS_InstanceHandle_t handle;
    char color[129];
    bool used;
} IhColorEntry;

static IhColorEntry g_ih_cache[MAX_IH_CACHE];

static void ih_cache_put(DDS_InstanceHandle_t handle, const char *color) {
    for (int i = 0; i < MAX_IH_CACHE; i++) {
        if (g_ih_cache[i].used && g_ih_cache[i].handle == handle) {
            strncpy(g_ih_cache[i].color, color, sizeof(g_ih_cache[i].color) - 1);
            return;
        }
    }
    for (int i = 0; i < MAX_IH_CACHE; i++) {
        if (!g_ih_cache[i].used) {
            g_ih_cache[i].used = true;
            g_ih_cache[i].handle = handle;
            strncpy(g_ih_cache[i].color, color, sizeof(g_ih_cache[i].color) - 1);
            return;
        }
    }
}

static const char *ih_cache_get(DDS_InstanceHandle_t handle) {
    for (int i = 0; i < MAX_IH_CACHE; i++) {
        if (g_ih_cache[i].used && g_ih_cache[i].handle == handle) return g_ih_cache[i].color;
    }
    return "";
}

static void print_not_alive(const char *topic_name, const char *color, uint32_t instance_state) {
    const char *state_str = (instance_state == DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE)
        ? "NOT_ALIVE_DISPOSED_INSTANCE_STATE"
        : "NOT_ALIVE_NO_WRITERS_INSTANCE_STATE";
    printf("%-10s %-10s %s\n", topic_name, color, state_str);
}

typedef struct {
    ShapeType v;
    zzdds_sample_info i;
} ShapeSample;

static int sample_cmp_by_handle(const void *a, const void *b) {
    const ShapeSample *sa = (const ShapeSample *)a;
    const ShapeSample *sb = (const ShapeSample *)b;
    if (sa->i.instance_handle < sb->i.instance_handle) return -1;
    if (sa->i.instance_handle > sb->i.instance_handle) return 1;
    return 0;
}

static int run_subscriber(DDS_DomainParticipant dp, DDS_Topic base_topic, const Options *opts) {
    uint32_t n = opts->num_topics;

    ExtraTopics et;
    if (create_extra_topics(dp, opts, &et) != 0) {
        fprintf(stderr, "FAIL: failed to create extra topics\n");
        return 1;
    }

    /* Content-filtered topic for topic[0] only (when --cft or -c COLOR is
     * specified) -- matches zig/shape's effective_cft_expr synthesis. */
    char synth_cft_buf[160];
    const char *effective_cft_expr = opts->cft_expression;
    if (!effective_cft_expr && opts->color) {
        snprintf(synth_cft_buf, sizeof(synth_cft_buf), "color = '%s'", opts->color);
        effective_cft_expr = synth_cft_buf;
    }

    DDS_ContentFilteredTopic cft = NULL;
    if (effective_cft_expr) {
        char cft_name[192];
        snprintf(cft_name, sizeof(cft_name), "%s_cft", opts->topic_name);
        cft = DDS_DomainParticipant_create_contentfilteredtopic(dp, cft_name, base_topic, effective_cft_expr, NULL);
        if (!cft) {
            fprintf(stderr, "FAIL: create_contentfilteredtopic returned NULL\n");
            extra_topics_free(&et);
            return 1;
        }
    }

    DDS_SubscriberQos sub_qos;
    memset(&sub_qos, 0, sizeof(sub_qos));
    sub_qos.presentation.access_scope = access_scope_kind(opts->access_scope);
    sub_qos.presentation.coherent_access = opts->coherent_access;
    sub_qos.presentation.ordered_access = opts->ordered_access;
    set_partition(&sub_qos.partition, opts->partition);

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, &sub_qos, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber returned NULL\n");
        extra_topics_free(&et);
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    if (build_reader_qos(sub, &dr_qos, opts) != 0) {
        extra_topics_free(&et);
        return 1;
    }

    ListenerCtx lctxs[MAX_TOPICS];
    DDS_DataReader dr_handles[MAX_TOPICS];
    ShapeTypeDataReader typed_readers[MAX_TOPICS];
    DDS_StatusMask listener_mask = DDS_REQUESTED_INCOMPATIBLE_QOS_STATUS | DDS_REQUESTED_DEADLINE_MISSED_STATUS;

    for (uint32_t i = 0; i < n; i++) {
        const char *tn = name_at(&et, opts->topic_name, i);
        lctxs[i].topic_name = tn;
        DDS_DataReaderListener listener;
        memset(&listener, 0, sizeof(listener));
        listener.listener_data = &lctxs[i];
        listener.on_requested_incompatible_qos = on_requested_incompatible_qos;
        listener.on_requested_deadline_missed = on_requested_deadline_missed;

        DDS_TopicDescription topic_desc = (i == 0 && cft)
            ? DDS_ContentFilteredTopic_as_DDS_TopicDescription(cft)
            : DDS_DomainParticipant_lookup_topicdescription(dp, tn);
        if (!topic_desc) {
            fprintf(stderr, "FAIL: lookup_topicdescription returned NULL for '%s'\n", tn);
            extra_topics_free(&et);
            return 1;
        }

        printf("Create reader for topic: %s\n", tn);
        dr_handles[i] = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, &listener, listener_mask);
        if (!dr_handles[i]) {
            fprintf(stderr, "FAIL: create_datareader returned NULL\n");
            extra_topics_free(&et);
            return 1;
        }
        ShapeTypeDataReader_init(&typed_readers[i], dr_handles[i]);
    }

    bool use_access = opts->coherent_access || opts->ordered_access;

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts->num_iterations >= 0 && iteration >= opts->num_iterations) break;

        if (use_access) {
            if (opts->coherent_access) printf("Reading coherent sets, iteration %" PRId64 "\n", iteration);
            if (opts->ordered_access) printf("Reading with ordered access, iteration %" PRId64 "\n", iteration);
            DDS_Subscriber_begin_access(sub);
        }

        for (uint32_t ti = 0; ti < n; ti++) {
            const char *tn = lctxs[ti].topic_name;

            if (opts->read_only) {
                /* -R (non-destructive read): bulk-fetch every NOT_READ sample
                 * once per topic per outer iteration (flips them to READ so
                 * they won't re-match), then hand them out one at a time.
                 * --take-read still picks FIFO vs grouped-by-instance
                 * ordering, applied here via the sort. */
                ShapeSample buf[MAX_SAMPLES_PER_READ];
                ShapeType values[MAX_SAMPLES_PER_READ];
                zzdds_sample_info infos[MAX_SAMPLES_PER_READ];
                memset(values, 0, sizeof(values));
                memset(infos, 0, sizeof(infos));
                int got = ShapeTypeDataReader_read_n(&typed_readers[ti], values, infos, MAX_SAMPLES_PER_READ,
                                                      DDS_NOT_READ_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
                if (got < 0) got = 0;
                for (int k = 0; k < got; k++) {
                    buf[k].v = values[k];
                    buf[k].i = infos[k];
                }
                if (!opts->take_read) {
                    qsort(buf, (size_t)got, sizeof(buf[0]), sample_cmp_by_handle);
                }

                for (int k = 0; k < got; k++) {
                    ShapeType *value = &buf[k].v;
                    zzdds_sample_info *info = &buf[k].i;

                    if (!info->valid_data ||
                        info->instance_state == DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE ||
                        info->instance_state == DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE)
                    {
                        const char *key_color = (value->color[0] != '\0') ? value->color : ih_cache_get(info->instance_handle);
                        print_not_alive(tn, key_color, info->instance_state);
                        ShapeType_free(value);
                        continue;
                    }

                    ih_cache_put(info->instance_handle, value->color);

                    uint32_t extra_len = value->additional_payload_size._length;
                    if (extra_len > 0 && value->additional_payload_size._buffer) {
                        uint8_t last_byte = value->additional_payload_size._buffer[extra_len - 1];
                        printf("%-10s %-10s %03d %03d [%d] {%d}\n",
                               tn, value->color, (int)value->x, (int)value->y, (int)value->shapesize, (int)last_byte);
                    } else {
                        printf("%-10s %-10s %03d %03d [%d]\n",
                               tn, value->color, (int)value->x, (int)value->y, (int)value->shapesize);
                    }
                    ShapeType_free(value);
                }
            } else {
                /* HANDLE_NIL every call (not the last-seen handle) drains
                 * each instance fully before moving to the next -- matches
                 * zig/shape's take_next_instance loop. --take-read uses
                 * FIFO take() delivery order instead. */
                for (;;) {
                    ShapeType value;
                    zzdds_sample_info info;
                    memset(&value, 0, sizeof(value));
                    memset(&info, 0, sizeof(info));
                    uint8_t cdr_buf[512];
                    size_t cdr_len = 0;

                    int rc = opts->take_read
                        ? ShapeTypeDataReader_take(&typed_readers[ti], &value, &info, cdr_buf, sizeof(cdr_buf), &cdr_len)
                        : ShapeTypeDataReader_take_next_instance(&typed_readers[ti], &value, &info, DDS_HANDLE_NIL, cdr_buf, sizeof(cdr_buf), &cdr_len);
                    if (rc != DDS_RETCODE_OK || !info.valid_data) {
                        if (rc == DDS_RETCODE_OK && !info.valid_data &&
                            (info.instance_state == DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE ||
                             info.instance_state == DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE))
                        {
                            const char *key_color = (value.color[0] != '\0') ? value.color : ih_cache_get(info.instance_handle);
                            print_not_alive(tn, key_color, info.instance_state);
                            ShapeType_free(&value);
                            continue;
                        }
                        ShapeType_free(&value);
                        break;
                    }

                    /* Content assertions: a key (color) must never change
                     * across samples of the same instance handle, and the
                     * writer only ever emits x/y in [0,320)/[0,240) with
                     * shapesize >= 1 -- hard-fail if either is violated. */
                    const char *cached_color = ih_cache_get(info.instance_handle);
                    if (cached_color[0] != '\0' && strcmp(cached_color, value.color) != 0) {
                        fprintf(stderr, "FAIL: instance %llu color changed from '%s' to '%s'\n",
                                (unsigned long long)info.instance_handle, cached_color, value.color);
                        ShapeType_free(&value);
                        extra_topics_free(&et);
                        return 1;
                    }
                    if (value.x < 0 || value.x >= 320 || value.y < 0 || value.y >= 240 || value.shapesize < 1) {
                        fprintf(stderr, "FAIL: sample out of bounds: x=%d y=%d shapesize=%d\n",
                                (int)value.x, (int)value.y, (int)value.shapesize);
                        ShapeType_free(&value);
                        extra_topics_free(&et);
                        return 1;
                    }
                    ih_cache_put(info.instance_handle, value.color);

                    uint32_t extra_len = value.additional_payload_size._length;
                    if (extra_len > 0 && value.additional_payload_size._buffer) {
                        uint8_t last_byte = value.additional_payload_size._buffer[extra_len - 1];
                        printf("%-10s %-10s %03d %03d [%d] {%d}\n",
                               tn, value.color, (int)value.x, (int)value.y, (int)value.shapesize, (int)last_byte);
                    } else {
                        printf("%-10s %-10s %03d %03d [%d]\n",
                               tn, value.color, (int)value.x, (int)value.y, (int)value.shapesize);
                    }
                    ShapeType_free(&value);
                }
            }
        }

        if (use_access) DDS_Subscriber_end_access(sub);

        /* DEADLINE QoS is enforced automatically by zzdds's own background
         * timer -- no manual elapsed-time tracking needed here;
         * on_requested_deadline_missed() fires on its own. */

        iteration++;
        usleep((useconds_t)(opts->read_period_ms * 1000));
    }

    if (cft) DDS_DomainParticipant_delete_contentfilteredtopic(dp, cft);
    extra_topics_free(&et);
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
        } else if (strcmp(arg, "-R") == 0) {
            opts->read_only = true;
        } else if (strcmp(arg, "-d") == 0) {
            if (++i >= argc) return -1;
            opts->domain_id = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "-k") == 0) {
            if (++i >= argc) return -1;
            opts->history_depth = (int32_t)strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "-f") == 0 || strcmp(arg, "--deadline") == 0) {
            if (++i >= argc) return -1;
            opts->deadline_ms = strtoull(argv[i], NULL, 10);
        } else if (strcmp(arg, "-s") == 0) {
            if (++i >= argc) return -1;
            opts->ownership_strength = (int32_t)strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "-t") == 0) {
            if (++i >= argc) return -1;
            opts->topic_name = argv[i];
        } else if (strcmp(arg, "-c") == 0) {
            if (++i >= argc) return -1;
            opts->color = argv[i];
        } else if (strcmp(arg, "-p") == 0) {
            if (++i >= argc) return -1;
            opts->partition = argv[i];
        } else if (strcmp(arg, "-D") == 0) {
            if (++i >= argc) return -1;
            opts->durability = argv[i][0] ? argv[i][0] : 'v';
        } else if (strcmp(arg, "-x") == 0) {
            if (++i >= argc) return -1;
            opts->data_representation = (uint16_t)strtoul(argv[i], NULL, 10);
            if (opts->data_representation != 2) opts->data_representation = 1;
        } else if (strcmp(arg, "-z") == 0) {
            if (++i >= argc) return -1;
            opts->shapesize = (int32_t)strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "-n") == 0 || strcmp(arg, "--num-instances") == 0) {
            if (++i >= argc) return -1;
            opts->num_instances = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "--write-period") == 0) {
            if (++i >= argc) return -1;
            opts->write_period_ms = strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "--read-period") == 0) {
            if (++i >= argc) return -1;
            opts->read_period_ms = strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "-i") == 0 || strcmp(arg, "--num-iterations") == 0) {
            if (++i >= argc) return -1;
            opts->num_iterations = strtoll(argv[i], NULL, 10);
        } else if (strcmp(arg, "--additional-payload") == 0 || strcmp(arg, "--additional-payload-size") == 0) {
            if (++i >= argc) return -1;
            opts->additional_payload = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "--size-modulo") == 0) {
            if (++i >= argc) return -1;
            opts->size_modulo = (int32_t)strtol(argv[i], NULL, 10);
        } else if (strcmp(arg, "--cft") == 0) {
            if (++i >= argc) return -1;
            opts->cft_expression = argv[i];
        } else if (strcmp(arg, "--time-filter") == 0) {
            if (++i >= argc) return -1;
            opts->time_filter_ms = strtoull(argv[i], NULL, 10);
        } else if (strcmp(arg, "--lifespan") == 0) {
            if (++i >= argc) return -1;
            opts->lifespan_ms = strtoull(argv[i], NULL, 10);
        } else if (strcmp(arg, "--final-instance-state") == 0) {
            if (++i >= argc) return -1;
            opts->final_instance_state = argv[i][0] ? argv[i][0] : 0;
        } else if (strcmp(arg, "--access-scope") == 0) {
            if (++i >= argc) return -1;
            opts->access_scope = argv[i][0] ? argv[i][0] : 'i';
        } else if (strcmp(arg, "--ordered") == 0) {
            opts->ordered_access = true;
        } else if (strcmp(arg, "--coherent") == 0) {
            opts->coherent_access = true;
        } else if (strcmp(arg, "--num-topics") == 0) {
            if (++i >= argc) return -1;
            opts->num_topics = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "--take-read") == 0) {
            opts->take_read = true;
        } else if (strcmp(arg, "--coherent-sample-count") == 0) {
            if (++i >= argc) return -1;
            opts->coherent_sample_count = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "--periodic-announcement") == 0) {
            if (++i >= argc) return -1;
            opts->periodic_announcement_ms = (uint32_t)strtoul(argv[i], NULL, 10);
        } else if (strcmp(arg, "--config") == 0) {
            if (++i >= argc) return -1;
            opts->config_path = argv[i];
        } else if (strcmp(arg, "-Z") == 0 || strcmp(arg, "--datafrag-size") == 0) {
            if (++i >= argc) return -1;
            char *endp = NULL;
            unsigned long v = strtoul(argv[i], &endp, 10);
            if (endp == argv[i] || v > 65535ul) {
                fprintf(stderr, "incorrect value for datafrag-size, must be a non-negative integer <= 65535\n");
                return -1;
            }
            opts->datafrag_size = (uint16_t)v;
        } else if (strcmp(arg, "--publisher-matches") == 0 || strcmp(arg, "--subscriber-matches") == 0) {
            /* Consume argument value and ignore -- unimplemented options; no
             * reference implementation elsewhere in this repo defines their
             * semantics and no interop test exercises them. */
            if (++i >= argc) return -1;
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
                "  -f, --deadline <ms> Deadline period in milliseconds\n"
                "  --lifespan <ms>     Sample lifespan in milliseconds (writer only; 0 = infinite)\n"
                "  -s <strength>       Ownership strength (enables EXCLUSIVE ownership)\n"
                "  -x 1|2              Data representation: 1=XCDR1 (default), 2=XCDR2\n"
                "  -p <name>           Partition name\n"
                "\n"
                "Topic / data:\n"
                "  -t <name>           Topic name (default: Square)\n"
                "  -c <color>          Color / key value (default: BLUE)\n"
                "  -z <size>           Shape size; 0 = auto-increment each sample (default: 20)\n"
                "  -n <count>          Number of instances to publish (default: 1)\n"
                "  --num-topics <n>    Number of topics (Square, Square1, Square2, ...) (default: 1)\n"
                "  --additional-payload <bytes>  Extra zero bytes appended to each sample\n"
                "  --size-modulo <n>   Cycle shapesize 1..n when -z 0 is active\n"
                "  --cft <expr>        Content filter expression (subscriber only)\n"
                "\n"
                "Timing / iterations:\n"
                "  -i, --num-iterations <n>   Stop after n samples (-1 = infinite, default)\n"
                "  --write-period <ms>         Publish interval in ms (default: 33)\n"
                "  --read-period <ms>          Read poll interval in ms (default: 100)\n"
                "\n"
                "Presentation / coherent:\n"
                "  --access-scope i|t|g        Presentation access scope (default: i)\n"
                "  --ordered                   Enable ordered access\n"
                "  --coherent                   Enable coherent access\n"
                "  --coherent-sample-count <n>  Samples per coherent set (0 = no gating)\n"
                "  --take-read                  Use take() instead of take_next_instance()\n"
                "  -R                           Use read() instead of take() (non-destructive)\n"
                "\n"
                "Other:\n"
                "  -d <id>             Domain ID (default: 0)\n"
                "  -w                  Print each sample on the writer side\n"
                "  --periodic-announcement <ms>  SPDP participant re-announcement period\n"
                "                                (0 = use zzdds's own default)\n"
                "  -Z, --datafrag-size <bytes>  DATA_FRAG fragment size in bytes, <= 65535\n"
                "                                (0 = use zzdds's own default)\n"
                "  --config <path>     Load a zzdds.toml-style config file as the process-wide\n"
                "                      default participant config before creating the factory\n"
                "                      (see zzdds-examples/config/ for example scenarios)\n"
                "  -h, --help          Show this help and exit\n"
                "\n"
            );
            exit(0);
        } else {
            fprintf(stderr, "warning: unrecognised option: %s\n", arg);
        }
    }

    if (opts->publish && !opts->color) opts->color = "BLUE";

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

    if (opts.num_topics < 1 || opts.num_topics > MAX_TOPICS) {
        fprintf(stderr, "--num-topics must be between 1 and %d (got %u)\n", MAX_TOPICS, opts.num_topics);
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

    DDS_DomainParticipant dp;
    if (opts.datafrag_size > 0 || opts.periodic_announcement_ms > 0) {
        /* Start from the factory's already-resolved default (reflecting
         * --config above, if any) rather than a bare zeroed struct, so this
         * composes correctly with --config instead of overwriting it --
         * same reasoning as zig/shape's createParticipant(). */
        zzdds_DomainParticipantConfig cfg;
        zzdds_DomainParticipantConfig_default(&cfg);
        if (zzdds_DomainParticipantFactory_get_default_participant_config(factory, &cfg) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: get_default_participant_config() failed\n");
            zzdds_destroy_factory(factory);
            return 1;
        }
        if (opts.datafrag_size > 0) cfg.rtps.fragment_size = opts.datafrag_size;
        if (opts.periodic_announcement_ms > 0) cfg.participant.announcement_period_ms = opts.periodic_announcement_ms;
        dp = zzdds_DomainParticipantFactory_create_participant_ex(factory, opts.domain_id, NULL, NULL, 0, &cfg);
        zzdds_DomainParticipantConfig_free(&cfg);
    } else {
        DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
        dp = DDS_DomainParticipantFactory_create_participant(dds_factory, opts.domain_id, NULL, NULL, 0);
    }
    if (!dp) {
        fprintf(stderr, "failed to create participant on domain %u\n", opts.domain_id);
        zzdds_destroy_factory(factory);
        return 1;
    }

    if (zzdds_register_type_support(dp, "ShapeType", ShapeType_compute_key_hash_from_cdr, ShapeType_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "registerTypeSupport() failed\n");
        zzdds_destroy_factory(factory);
        return 1;
    }

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
