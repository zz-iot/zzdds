/*
 * C++ port of zig/shape's shape_main -- the OMG DDS-Interoperability "Shapes"
 * demo app, talking to zzdds through its native C++ API (dcps.hpp/dcps_impl.hpp,
 * the same shared_ptr-based entity model cpp/custom-allocator uses). CLI/
 * behavior spec is dds-rtps's srcZig/shape_main.zig (see zig/shape); this now
 * implements the full stretch-flag set from docs/design/shape-reference-app.md,
 * matching zig/shape's and c/shape's exact semantics (deadline, lifespan,
 * ownership strength, xcdr repr, partition, multi-instance/topic,
 * additional-payload/size-modulo, content-filtering, presentation/coherent,
 * take-read/read-only).
 */
#include "shape.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <ctime>
#include <cinttypes>
#include <memory>
#include <string>
#include <vector>
#include <optional>
#include <algorithm>
#include <unordered_map>
#include <unistd.h>

namespace {

constexpr uint32_t MAX_TOPICS = 16;
constexpr int MAX_SAMPLES_PER_READ = 256;

/* ── Options ─────────────────────────────────────────────────────────────── */

struct Options {
    bool publish = false;
    bool subscribe = false;
    uint32_t domain_id = 0;
    bool best_effort = false;
    bool reliable = false;
    int32_t history_depth = -1; /* -1 = use default KEEP_LAST 1 */
    uint64_t deadline_ms = 0;
    uint64_t lifespan_ms = 0; /* 0 = infinite */
    int32_t ownership_strength = -1; /* -1 = SHARED */
    const char *topic_name = "Square";
    std::optional<std::string> color;
    std::optional<std::string> partition;
    char durability = 'v'; /* 'v', 'l', 't', 'p' */
    uint16_t data_representation = 1; /* 1=XCDR1, 2=XCDR2 */
    bool print_writer_samples = false;
    int32_t shapesize = 20;
    long write_period_ms = 33;
    long read_period_ms = 100;
    int64_t num_iterations = -1; /* -1 = infinite */
    uint32_t num_instances = 1;
    uint32_t additional_payload = 0;
    int32_t size_modulo = 0;
    std::optional<std::string> cft_expression;
    uint64_t time_filter_ms = 0;
    char final_instance_state = 0; /* 0, 'u', 'd' */
    char access_scope = 'i'; /* 'i', 't', 'g' */
    bool ordered_access = false;
    bool coherent_access = false;
    uint32_t num_topics = 1;
    bool take_read = false;
    bool read_only = false;
    uint32_t coherent_sample_count = 0;
    uint32_t periodic_announcement_ms = 0;
    const char *config_path = nullptr;
};

/* ── Policy name mapping (matches zig/shape's policyName()) ────────────────── */

const char *policy_name(::DDS::QosPolicyId_t id) {
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

/* ── Signal handling ───────────────────────────────────────────────────────── */

volatile sig_atomic_t g_all_done = 0;

void handle_sigint(int) { g_all_done = 1; }

/* ── Time helpers ──────────────────────────────────────────────────────────── */

int64_t mono_ns() {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<int64_t>(ts.tv_sec) * 1000000000LL + ts.tv_nsec;
}

/* ── Listeners ─────────────────────────────────────────────────────────────── */

class ShapeDataWriterListener : public ::DDS::DataWriterListenerBase {
public:
    explicit ShapeDataWriterListener(std::string topic_name) : topic_name_(std::move(topic_name)) {}

    void on_offered_incompatible_qos(
        std::shared_ptr<::DDS::DataWriter> /*writer*/,
        ::DDS::OfferedIncompatibleQosStatus status
    ) override {
        std::printf("on_offered_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)\n",
                     topic_name_.c_str(), static_cast<int>(status.last_policy_id),
                     policy_name(status.last_policy_id));
    }

    void on_offered_deadline_missed(
        std::shared_ptr<::DDS::DataWriter> /*writer*/,
        ::DDS::OfferedDeadlineMissedStatus status
    ) override {
        std::printf("on_offered_deadline_missed() topic: '%s'  type: 'ShapeType' : (total = %d, change = %d)\n",
                     topic_name_.c_str(), static_cast<int>(status.total_count),
                     static_cast<int>(status.total_count_change));
    }

private:
    std::string topic_name_;
};

class ShapeDataReaderListener : public ::DDS::DataReaderListenerBase {
public:
    explicit ShapeDataReaderListener(std::string topic_name) : topic_name_(std::move(topic_name)) {}

    void on_requested_incompatible_qos(
        std::shared_ptr<::DDS::DataReader> /*reader*/,
        ::DDS::RequestedIncompatibleQosStatus status
    ) override {
        std::printf("on_requested_incompatible_qos() topic: '%s'  type: 'ShapeType' : %d (%s)\n",
                     topic_name_.c_str(), static_cast<int>(status.last_policy_id),
                     policy_name(status.last_policy_id));
    }

    void on_requested_deadline_missed(
        std::shared_ptr<::DDS::DataReader> /*reader*/,
        ::DDS::RequestedDeadlineMissedStatus status
    ) override {
        std::printf("on_requested_deadline_missed() topic: '%s'  type: 'ShapeType' : (total = %d, change = %d)\n",
                     topic_name_.c_str(), static_cast<int>(status.total_count),
                     static_cast<int>(status.total_count_change));
    }

private:
    std::string topic_name_;
};

/* ── QoS builders ──────────────────────────────────────────────────────────── */

/* -r forces RELIABLE even if -b was also passed; otherwise -b selects
 * BEST_EFFORT and everything else (including the no-flags case) is
 * RELIABLE -- matches zig/shape's buildWriterQos/buildReaderQos exactly. */
::DDS::ReliabilityQosPolicyKind reliability_kind(const Options &opts) {
    if (opts.best_effort && !opts.reliable) return ::DDS::ReliabilityQosPolicyKind::BEST_EFFORT_RELIABILITY_QOS;
    return ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
}

::DDS::DurabilityQosPolicyKind durability_kind(char d) {
    switch (d) {
        case 'l': return ::DDS::DurabilityQosPolicyKind::TRANSIENT_LOCAL_DURABILITY_QOS;
        case 't': return ::DDS::DurabilityQosPolicyKind::TRANSIENT_DURABILITY_QOS;
        case 'p': return ::DDS::DurabilityQosPolicyKind::PERSISTENT_DURABILITY_QOS;
        default: return ::DDS::DurabilityQosPolicyKind::VOLATILE_DURABILITY_QOS;
    }
}

::DDS::PresentationQosPolicyAccessScopeKind access_scope_kind(char c) {
    switch (c) {
        case 't': return ::DDS::PresentationQosPolicyAccessScopeKind::TOPIC_PRESENTATION_QOS;
        case 'g': return ::DDS::PresentationQosPolicyAccessScopeKind::GROUP_PRESENTATION_QOS;
        default: return ::DDS::PresentationQosPolicyAccessScopeKind::INSTANCE_PRESENTATION_QOS;
    }
}

/* zig/shape always explicitly offers/requests a one-element
 * DataRepresentationId sequence rather than leaving it empty -- an empty
 * sequence is DATAREPRESENTATION-incompatible with that under zzdds's QoS
 * matching (see c/shape's README: found and fixed there via cross-binding
 * testing first). -x selects XCDR1 (default) vs XCDR2 via this same
 * mechanism. */
void set_representation(::DDS::DataRepresentationQosPolicy &repr, uint16_t data_representation) {
    repr.value = { (data_representation == 2) ? ::DDS::XCDR2_DATA_REPRESENTATION : ::DDS::XCDR_DATA_REPRESENTATION };
}

::DDS::Duration_t duration_from_ms(uint64_t ms) {
    return ::DDS::Duration_t{ static_cast<int32_t>(ms / 1000), static_cast<uint32_t>((ms % 1000) * 1000000ULL) };
}

::DDS::DataWriterQos build_writer_qos(const Options &opts) {
    auto qos = ::DDS::DataWriterQos::default_value();
    qos.reliability.kind = reliability_kind(opts);
    if (opts.history_depth == 0) {
        qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    } else if (opts.history_depth > 0) {
        qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_LAST_HISTORY_QOS;
        qos.history.depth = opts.history_depth;
    }
    qos.durability.kind = durability_kind(opts.durability);
    if (opts.deadline_ms > 0) qos.deadline.period = duration_from_ms(opts.deadline_ms);
    if (opts.lifespan_ms > 0) qos.lifespan.duration = duration_from_ms(opts.lifespan_ms);
    if (opts.ownership_strength >= 0) {
        qos.ownership.kind = ::DDS::OwnershipQosPolicyKind::EXCLUSIVE_OWNERSHIP_QOS;
        qos.ownership_strength.value = opts.ownership_strength;
    }
    set_representation(qos.data_representation, opts.data_representation);
    return qos;
}

::DDS::DataReaderQos build_reader_qos(const Options &opts) {
    auto qos = ::DDS::DataReaderQos::default_value();
    qos.reliability.kind = reliability_kind(opts);
    if (opts.history_depth == 0) {
        qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    } else if (opts.history_depth > 0) {
        qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_LAST_HISTORY_QOS;
        qos.history.depth = opts.history_depth;
    }
    qos.durability.kind = durability_kind(opts.durability);
    if (opts.deadline_ms > 0) qos.deadline.period = duration_from_ms(opts.deadline_ms);
    if (opts.ownership_strength >= 0) qos.ownership.kind = ::DDS::OwnershipQosPolicyKind::EXCLUSIVE_OWNERSHIP_QOS;
    if (opts.time_filter_ms > 0) qos.time_based_filter.minimum_separation = duration_from_ms(opts.time_filter_ms);
    set_representation(qos.data_representation, opts.data_representation);
    return qos;
}

/* ── Multi-topic helpers ───────────────────────────────────────────────────── */

/* Holds the extra topics (index 1..num_topics-1) created alongside the base
 * topic. The base topic (index 0) is owned by main() and its name is
 * opts.topic_name. Mirrors zig/shape's ExtraTopics. */
struct ExtraTopics {
    std::vector<std::shared_ptr<::DDS::Topic>> topics;
    std::vector<std::string> names;
};

std::shared_ptr<::DDS::Topic> topic_at(const std::shared_ptr<::DDS::Topic> &base, const ExtraTopics &et, uint32_t i) {
    return (i == 0) ? base : et.topics[i - 1];
}

std::string name_at(const std::string &base_name, const ExtraTopics &et, uint32_t i) {
    return (i == 0) ? base_name : et.names[i - 1];
}

std::optional<ExtraTopics> create_extra_topics(std::shared_ptr<::DDS::DomainParticipant> dp, const Options &opts) {
    ExtraTopics et;
    for (uint32_t i = 1; i < opts.num_topics; i++) {
        std::string name = std::string(opts.topic_name) + std::to_string(i);
        std::printf("Create topic: %s\n", name.c_str());
        auto t = dp->create_topic(name, "ShapeType", ::DDS::TopicQos::default_value(), nullptr, 0);
        if (!t) return std::nullopt;
        et.names.push_back(name);
        et.topics.push_back(t);
    }
    return et;
}

/* Returns color for instance index: inst=0 -> base, inst>0 -> "{base}{inst}". */
std::string instance_color(const std::string &base, uint32_t inst) {
    if (inst == 0) return base;
    return base + std::to_string(inst);
}

/* ── Publisher ─────────────────────────────────────────────────────────────── */

int run_publisher(std::shared_ptr<::DDS::DomainParticipant> dp, std::shared_ptr<::DDS::Topic> base_topic, const Options &opts) {
    const std::string base_color = opts.color.value_or("BLUE");
    const uint32_t n = opts.num_topics;

    auto et_opt = create_extra_topics(dp, opts);
    if (!et_opt) {
        std::fprintf(stderr, "FAIL: failed to create extra topics\n");
        return 1;
    }
    ExtraTopics et = std::move(*et_opt);

    auto pub_qos = ::DDS::PublisherQos::default_value();
    pub_qos.presentation.access_scope = access_scope_kind(opts.access_scope);
    pub_qos.presentation.coherent_access = opts.coherent_access;
    pub_qos.presentation.ordered_access = opts.ordered_access;
    if (opts.partition) pub_qos.partition.name = { *opts.partition };

    auto pub = dp->create_publisher(pub_qos, nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher returned null\n");
        return 1;
    }

    auto dw_qos = build_writer_qos(opts);
    int xcdr_version = (opts.data_representation == 2) ? ZIDL_XCDR2 : ZIDL_XCDR1;

    std::vector<std::shared_ptr<::DDS::DataWriter>> dw_handles(n);
    std::vector<std::unique_ptr<ShapeTypeDataWriter>> typed_writers(n);
    std::vector<std::string> topic_names(n);
    // Must outlive the loop -- create_datawriter only extracts the raw
    // DDS_DataWriterListener C struct (capturing `this` as its void* context)
    // at call time; it never retains the shared_ptr itself. A loop-local
    // listener here would be destroyed at the end of each iteration, leaving
    // the reader's registered listener context dangling -- a real,
    // reproduced-via-crash bug (SIGSEGV in checkTimers' background timer
    // thread once a status callback actually fired, e.g. -f/--deadline)
    // rather than a hypothetical one.
    std::vector<std::shared_ptr<ShapeDataWriterListener>> listeners(n);
    ::DDS::StatusMask listener_mask = ::DDS::OFFERED_INCOMPATIBLE_QOS_STATUS | ::DDS::OFFERED_DEADLINE_MISSED_STATUS;

    for (uint32_t i = 0; i < n; i++) {
        std::string tn = name_at(opts.topic_name, et, i);
        topic_names[i] = tn;
        listeners[i] = std::make_shared<ShapeDataWriterListener>(tn);
        auto &listener = listeners[i];
        auto t = topic_at(base_topic, et, i);
        dw_handles[i] = pub->create_datawriter(t, dw_qos, listener, listener_mask);
        if (!dw_handles[i]) {
            std::fprintf(stderr, "FAIL: create_datawriter returned null\n");
            return 1;
        }
        auto dw_handle = dw_handles[i]->native_handle();
        typed_writers[i] = std::make_unique<ShapeTypeDataWriter>(dw_handle, xcdr_version);
        std::printf("Create writer for topic: %s color: %s\n", tn.c_str(), base_color.c_str());
    }

    ShapeType shape;
    shape.color = base_color;
    shape.shapesize = (opts.shapesize == 0) ? 1 : opts.shapesize;

    if (opts.additional_payload > 0) {
        shape.additional_payload_size.assign(opts.additional_payload, 0);
        shape.additional_payload_size.back() = 255;
    }

    std::srand(static_cast<unsigned>(mono_ns()));

    const int64_t match_deadline = mono_ns() + 10LL * 1000000000LL;
    bool printed_matched = false;

    /* Coherent set gating: each outer write-loop iteration is one whole
     * coherent window (begin_coherent_changes -> `sc` consecutive samples per
     * instance -> end_coherent_changes). Default sc=1 when coherent_access is
     * enabled without an explicit count, so PID_COHERENT_SET is still emitted
     * for single-sample sets (required by Connext). */
    const uint32_t sc = (opts.coherent_sample_count > 0) ? opts.coherent_sample_count : 1;
    const bool use_coherent_gating = opts.coherent_access || opts.ordered_access;

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts.num_iterations >= 0 && iteration >= opts.num_iterations) break;

        if (!printed_matched) {
            ::DDS::PublicationMatchedStatus status;
            dw_handles[0]->get_publication_matched_status(status);
            if (status.current_count > 0) {
                std::printf("on_publication_matched() topic: '%s'  type: 'ShapeType' : matched readers %d (change = 1)\n",
                            topic_names[0].c_str(), static_cast<int>(status.current_count));
                printed_matched = true;
            } else if (mono_ns() > match_deadline) {
                return 0; /* READER_NOT_MATCHED */
            }
        }

        /* For coherent publishers, hold off writing until a reader has
         * matched -- Connext's GROUP coherent subscriber requires the group
         * sequence to start from 1; writing before match would advance the
         * GSN so the subscriber joins mid-stream and never receives a
         * complete set. */
        if (use_coherent_gating && !printed_matched) {
            usleep(static_cast<useconds_t>(opts.write_period_ms * 1000));
            continue;
        }

        /* DEADLINE QoS is enforced automatically by zzdds's own background
         * timer -- no manual elapsed-time tracking needed here;
         * on_offered_deadline_missed() fires on its own. */

        if (use_coherent_gating) {
            pub->begin_coherent_changes();
            for (uint32_t ti = 0; ti < n; ti++) {
                for (uint32_t inst = 0; inst < opts.num_instances; inst++) {
                    shape.color = instance_color(base_color, inst);
                    for (uint32_t s = 0; s < sc; s++) {
                        shape.x = std::rand() % 320;
                        shape.y = std::rand() % 240;
                        int rc = typed_writers[ti]->write(shape);
                        if (rc != DDS_RETCODE_OK) {
                            std::fprintf(stderr, "FAIL: DataWriter::write (rc=%d)\n", rc);
                            return 1;
                        }
                        if (opts.print_writer_samples) {
                            std::printf("%-10s %-10s %03d %03d [%d]\n",
                                        topic_names[ti].c_str(), shape.color.c_str(),
                                        static_cast<int>(shape.x), static_cast<int>(shape.y),
                                        static_cast<int>(shape.shapesize));
                        }
                        if (opts.shapesize == 0) {
                            shape.shapesize++;
                            if (opts.size_modulo > 0 && shape.shapesize > opts.size_modulo) shape.shapesize = 1;
                        }
                    }
                }
            }
            pub->end_coherent_changes();
        } else {
            shape.x = std::rand() % 320;
            shape.y = std::rand() % 240;

            for (uint32_t ti = 0; ti < n; ti++) {
                for (uint32_t inst = 0; inst < opts.num_instances; inst++) {
                    shape.color = instance_color(base_color, inst);
                    int rc = typed_writers[ti]->write(shape);
                    if (rc != DDS_RETCODE_OK) {
                        std::fprintf(stderr, "FAIL: DataWriter::write (rc=%d)\n", rc);
                        return 1;
                    }
                    if (opts.print_writer_samples) {
                        std::printf("%-10s %-10s %03d %03d [%d]\n",
                                    topic_names[ti].c_str(), shape.color.c_str(),
                                    static_cast<int>(shape.x), static_cast<int>(shape.y),
                                    static_cast<int>(shape.shapesize));
                    }
                }
            }
            if (opts.shapesize == 0) {
                shape.shapesize++;
                if (opts.size_modulo > 0 && shape.shapesize > opts.size_modulo) shape.shapesize = 1;
            }
        }

        iteration++;
        usleep(static_cast<useconds_t>(opts.write_period_ms * 1000));
    }

    /* Unregister/dispose all instances across all topics on finite run. */
    if (opts.num_iterations >= 0) {
        const bool do_dispose = (opts.final_instance_state == 'd');
        for (uint32_t ti = 0; ti < n; ti++) {
            for (uint32_t inst = 0; inst < opts.num_instances; inst++) {
                ShapeType key;
                key.color = instance_color(base_color, inst);
                if (do_dispose) {
                    typed_writers[ti]->dispose(key);
                } else {
                    typed_writers[ti]->unregister_instance(key);
                }
            }
        }
        /* Wait until all reliable readers have ACKed the NOT_ALIVE changes,
         * or up to 5 s, to avoid exiting before RELIABLE transport has
         * delivered the unregister/dispose changes to matched readers. */
        for (uint32_t ti = 0; ti < n; ti++) {
            dw_handles[ti]->wait_for_acknowledgments(::DDS::Duration_t{5, 0});
        }
    }

    return 0;
}

/* ── Subscriber ────────────────────────────────────────────────────────────── */

void print_not_alive(const std::string &topic_name, const std::string &color, ::DDS::InstanceStateKind instance_state) {
    const char *state_str = (instance_state == ::DDS::NOT_ALIVE_DISPOSED_INSTANCE_STATE)
        ? "NOT_ALIVE_DISPOSED_INSTANCE_STATE"
        : "NOT_ALIVE_NO_WRITERS_INSTANCE_STATE";
    std::printf("%-10s %-10s %s\n", topic_name.c_str(), color.c_str(), state_str);
}

int run_subscriber(std::shared_ptr<::DDS::DomainParticipant> dp, std::shared_ptr<::DDS::Topic> base_topic, const Options &opts) {
    const uint32_t n = opts.num_topics;

    auto et_opt = create_extra_topics(dp, opts);
    if (!et_opt) {
        std::fprintf(stderr, "FAIL: failed to create extra topics\n");
        return 1;
    }
    ExtraTopics et = std::move(*et_opt);

    /* Content-filtered topic for topic[0] only (when --cft or -c COLOR is
     * specified) -- matches zig/shape's effective_cft_expr synthesis. */
    std::optional<std::string> effective_cft_expr = opts.cft_expression;
    if (!effective_cft_expr && opts.color) {
        effective_cft_expr = "color = '" + *opts.color + "'";
    }

    std::shared_ptr<::DDS::ContentFilteredTopic> cft;
    if (effective_cft_expr) {
        std::string cft_name = std::string(opts.topic_name) + "_cft";
        cft = dp->create_contentfilteredtopic(cft_name, base_topic, *effective_cft_expr, {});
    }

    auto sub_qos = ::DDS::SubscriberQos::default_value();
    sub_qos.presentation.access_scope = access_scope_kind(opts.access_scope);
    sub_qos.presentation.coherent_access = opts.coherent_access;
    sub_qos.presentation.ordered_access = opts.ordered_access;
    if (opts.partition) sub_qos.partition.name = { *opts.partition };

    auto sub = dp->create_subscriber(sub_qos, nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber returned null\n");
        return 1;
    }

    auto dr_qos = build_reader_qos(opts);
    std::vector<std::shared_ptr<::DDS::DataReader>> dr_handles(n);
    std::vector<std::unique_ptr<ShapeTypeDataReader>> typed_readers(n);
    std::vector<std::string> topic_names(n);
    // Must outlive the loop -- see run_publisher's matching listeners vector
    // for why (real, reproduced UAF, not a hypothetical one).
    std::vector<std::shared_ptr<ShapeDataReaderListener>> listeners(n);
    ::DDS::StatusMask listener_mask = ::DDS::REQUESTED_INCOMPATIBLE_QOS_STATUS | ::DDS::REQUESTED_DEADLINE_MISSED_STATUS;

    for (uint32_t i = 0; i < n; i++) {
        std::string tn = name_at(opts.topic_name, et, i);
        topic_names[i] = tn;
        listeners[i] = std::make_shared<ShapeDataReaderListener>(tn);
        auto &listener = listeners[i];

        std::shared_ptr<::DDS::TopicDescription> topic_desc = (i == 0 && cft)
            ? std::static_pointer_cast<::DDS::TopicDescription>(cft)
            : dp->lookup_topicdescription(tn);
        if (!topic_desc) {
            std::fprintf(stderr, "FAIL: lookup_topicdescription returned null for '%s'\n", tn.c_str());
            return 1;
        }

        std::printf("Create reader for topic: %s\n", tn.c_str());
        dr_handles[i] = sub->create_datareader(topic_desc, dr_qos, listener, listener_mask);
        if (!dr_handles[i]) {
            std::fprintf(stderr, "FAIL: create_datareader returned null\n");
            return 1;
        }
        auto dr_handle = dr_handles[i]->native_handle();
        typed_readers[i] = std::make_unique<ShapeTypeDataReader>(dr_handle);
    }

    /* Maps instance_handle -> color for recovering key identity from
     * NOT_ALIVE samples that arrive without a serialized key payload. */
    std::unordered_map<DDS_InstanceHandle_t, std::string> ih_cache;

    const bool use_access = opts.coherent_access || opts.ordered_access;

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts.num_iterations >= 0 && iteration >= opts.num_iterations) break;

        if (use_access) {
            if (opts.coherent_access) std::printf("Reading coherent sets, iteration %" PRId64 "\n", iteration);
            if (opts.ordered_access) std::printf("Reading with ordered access, iteration %" PRId64 "\n", iteration);
            sub->begin_access();
        }

        for (uint32_t ti = 0; ti < n; ti++) {
            const std::string &tn = topic_names[ti];

            if (opts.read_only) {
                /* -R (non-destructive read): bulk-fetch every NOT_READ sample
                 * once per topic per outer iteration (flips them to READ so
                 * they won't re-match), then hand them out one at a time.
                 * --take-read still picks FIFO vs grouped-by-instance
                 * ordering, applied here via the sort. */
                std::vector<::ShapeType> values(MAX_SAMPLES_PER_READ);
                std::vector<zzdds_sample_info> infos(MAX_SAMPLES_PER_READ);
                int got = typed_readers[ti]->read_n(values.data(), infos.data(), MAX_SAMPLES_PER_READ,
                                                     ::DDS::NOT_READ_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
                if (got < 0) got = 0;

                std::vector<int> order(static_cast<size_t>(got));
                for (int k = 0; k < got; k++) order[static_cast<size_t>(k)] = k;
                if (!opts.take_read) {
                    std::sort(order.begin(), order.end(), [&](int a, int b) {
                        return infos[static_cast<size_t>(a)].instance_handle < infos[static_cast<size_t>(b)].instance_handle;
                    });
                }

                for (int idx : order) {
                    ::ShapeType &value = values[static_cast<size_t>(idx)];
                    zzdds_sample_info &info = infos[static_cast<size_t>(idx)];

                    if (!info.valid_data ||
                        info.instance_state == ::DDS::NOT_ALIVE_NO_WRITERS_INSTANCE_STATE ||
                        info.instance_state == ::DDS::NOT_ALIVE_DISPOSED_INSTANCE_STATE)
                    {
                        std::string key_color = !value.color.empty() ? std::string(value.color) : ih_cache[info.instance_handle];
                        print_not_alive(tn, key_color, static_cast<::DDS::InstanceStateKind>(info.instance_state));
                        continue;
                    }

                    ih_cache[info.instance_handle] = value.color;

                    if (!value.additional_payload_size.empty()) {
                        uint8_t last_byte = value.additional_payload_size.back();
                        std::printf("%-10s %-10s %03d %03d [%d] {%d}\n",
                                    tn.c_str(), value.color.c_str(), static_cast<int>(value.x),
                                    static_cast<int>(value.y), static_cast<int>(value.shapesize), static_cast<int>(last_byte));
                    } else {
                        std::printf("%-10s %-10s %03d %03d [%d]\n",
                                    tn.c_str(), value.color.c_str(), static_cast<int>(value.x),
                                    static_cast<int>(value.y), static_cast<int>(value.shapesize));
                    }
                }
            } else {
                /* HANDLE_NIL every call (not the last-seen handle) drains
                 * each instance fully before moving to the next -- matches
                 * zig/shape's take_next_instance loop. --take-read uses
                 * FIFO take() delivery order instead. */
                for (;;) {
                    ShapeTypeDataReader::Sample sample;
                    sample.info = zzdds_sample_info{};
                    uint8_t buf[512];
                    size_t cdr_len = 0;

                    int rc = opts.take_read
                        ? typed_readers[ti]->take(sample, buf, sizeof(buf), &cdr_len)
                        : typed_readers[ti]->take_next_instance(sample, DDS_HANDLE_NIL, buf, sizeof(buf), &cdr_len);

                    if (rc != DDS_RETCODE_OK || !sample.info.valid_data) {
                        if (rc == DDS_RETCODE_OK && !sample.info.valid_data &&
                            (sample.info.instance_state == ::DDS::NOT_ALIVE_NO_WRITERS_INSTANCE_STATE ||
                             sample.info.instance_state == ::DDS::NOT_ALIVE_DISPOSED_INSTANCE_STATE))
                        {
                            std::string key_color = !sample.value.color.empty() ? std::string(sample.value.color) : ih_cache[sample.info.instance_handle];
                            print_not_alive(tn, key_color, static_cast<::DDS::InstanceStateKind>(sample.info.instance_state));
                            continue;
                        }
                        break;
                    }

                    ih_cache[sample.info.instance_handle] = sample.value.color;

                    if (!sample.value.additional_payload_size.empty()) {
                        uint8_t last_byte = sample.value.additional_payload_size.back();
                        std::printf("%-10s %-10s %03d %03d [%d] {%d}\n",
                                    tn.c_str(), sample.value.color.c_str(), static_cast<int>(sample.value.x),
                                    static_cast<int>(sample.value.y), static_cast<int>(sample.value.shapesize), static_cast<int>(last_byte));
                    } else {
                        std::printf("%-10s %-10s %03d %03d [%d]\n",
                                    tn.c_str(), sample.value.color.c_str(), static_cast<int>(sample.value.x),
                                    static_cast<int>(sample.value.y), static_cast<int>(sample.value.shapesize));
                    }
                }
            }
        }

        if (use_access) sub->end_access();

        /* DEADLINE QoS is enforced automatically by zzdds's own background
         * timer -- no manual elapsed-time tracking needed here;
         * on_requested_deadline_missed() fires on its own. */

        iteration++;
        usleep(static_cast<useconds_t>(opts.read_period_ms * 1000));
    }

    if (cft) dp->delete_contentfilteredtopic(cft);
    return 0;
}

/* ── Argument parsing ──────────────────────────────────────────────────────── */

int parse_args(int argc, char **argv, Options &opts) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (std::strcmp(arg, "-P") == 0) {
            opts.publish = true;
        } else if (std::strcmp(arg, "-S") == 0) {
            opts.subscribe = true;
        } else if (std::strcmp(arg, "-b") == 0) {
            opts.best_effort = true;
        } else if (std::strcmp(arg, "-r") == 0) {
            opts.reliable = true;
        } else if (std::strcmp(arg, "-w") == 0) {
            opts.print_writer_samples = true;
        } else if (std::strcmp(arg, "-R") == 0) {
            opts.read_only = true;
        } else if (std::strcmp(arg, "-d") == 0) {
            if (++i >= argc) return -1;
            opts.domain_id = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "-k") == 0) {
            if (++i >= argc) return -1;
            opts.history_depth = static_cast<int32_t>(std::strtol(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "-f") == 0 || std::strcmp(arg, "--deadline") == 0) {
            if (++i >= argc) return -1;
            opts.deadline_ms = std::strtoull(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "-s") == 0) {
            if (++i >= argc) return -1;
            opts.ownership_strength = static_cast<int32_t>(std::strtol(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "-t") == 0) {
            if (++i >= argc) return -1;
            opts.topic_name = argv[i];
        } else if (std::strcmp(arg, "-c") == 0) {
            if (++i >= argc) return -1;
            opts.color = argv[i];
        } else if (std::strcmp(arg, "-p") == 0) {
            if (++i >= argc) return -1;
            opts.partition = argv[i];
        } else if (std::strcmp(arg, "-D") == 0) {
            if (++i >= argc) return -1;
            opts.durability = argv[i][0] ? argv[i][0] : 'v';
        } else if (std::strcmp(arg, "-x") == 0) {
            if (++i >= argc) return -1;
            opts.data_representation = static_cast<uint16_t>(std::strtoul(argv[i], nullptr, 10));
            if (opts.data_representation != 2) opts.data_representation = 1;
        } else if (std::strcmp(arg, "-z") == 0) {
            if (++i >= argc) return -1;
            opts.shapesize = static_cast<int32_t>(std::strtol(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "-n") == 0 || std::strcmp(arg, "--num-instances") == 0) {
            if (++i >= argc) return -1;
            opts.num_instances = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--write-period") == 0) {
            if (++i >= argc) return -1;
            opts.write_period_ms = std::strtol(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "--read-period") == 0) {
            if (++i >= argc) return -1;
            opts.read_period_ms = std::strtol(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "-i") == 0 || std::strcmp(arg, "--num-iterations") == 0) {
            if (++i >= argc) return -1;
            opts.num_iterations = std::strtoll(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "--additional-payload") == 0 || std::strcmp(arg, "--additional-payload-size") == 0) {
            if (++i >= argc) return -1;
            opts.additional_payload = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--size-modulo") == 0) {
            if (++i >= argc) return -1;
            opts.size_modulo = static_cast<int32_t>(std::strtol(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--cft") == 0) {
            if (++i >= argc) return -1;
            opts.cft_expression = argv[i];
        } else if (std::strcmp(arg, "--time-filter") == 0) {
            if (++i >= argc) return -1;
            opts.time_filter_ms = std::strtoull(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "--lifespan") == 0) {
            if (++i >= argc) return -1;
            opts.lifespan_ms = std::strtoull(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "--final-instance-state") == 0) {
            if (++i >= argc) return -1;
            opts.final_instance_state = argv[i][0] ? argv[i][0] : 0;
        } else if (std::strcmp(arg, "--access-scope") == 0) {
            if (++i >= argc) return -1;
            opts.access_scope = argv[i][0] ? argv[i][0] : 'i';
        } else if (std::strcmp(arg, "--ordered") == 0) {
            opts.ordered_access = true;
        } else if (std::strcmp(arg, "--coherent") == 0) {
            opts.coherent_access = true;
        } else if (std::strcmp(arg, "--num-topics") == 0) {
            if (++i >= argc) return -1;
            opts.num_topics = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--take-read") == 0) {
            opts.take_read = true;
        } else if (std::strcmp(arg, "--coherent-sample-count") == 0) {
            if (++i >= argc) return -1;
            opts.coherent_sample_count = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--periodic-announcement") == 0) {
            if (++i >= argc) return -1;
            opts.periodic_announcement_ms = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--config") == 0) {
            if (++i >= argc) return -1;
            opts.config_path = argv[i];
        } else if (std::strcmp(arg, "--publisher-matches") == 0 || std::strcmp(arg, "--subscriber-matches") == 0) {
            /* Consume argument value and ignore -- unimplemented options; no
             * reference implementation elsewhere in this repo defines their
             * semantics and no interop test exercises them. */
            if (++i >= argc) return -1;
        } else if (std::strcmp(arg, "-h") == 0 || std::strcmp(arg, "--help") == 0) {
            std::printf(
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
                "  --config <path>     Load a zzdds.toml-style config file as the process-wide\n"
                "                      default participant config before creating the factory\n"
                "                      (see zzdds-examples/config/ for example scenarios)\n"
                "  -h, --help          Show this help and exit\n"
                "\n"
            );
            std::exit(0);
        } else {
            std::fprintf(stderr, "warning: unrecognised option: %s\n", arg);
        }
    }
    return 0;
}

} // namespace

/* ── main ──────────────────────────────────────────────────────────────────── */

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    Options opts;
    if (parse_args(argc, argv, opts) != 0) {
        std::fprintf(stderr, "argument error\n");
        return 1;
    }

    if (!opts.publish && !opts.subscribe) {
        std::fprintf(stderr, "specify -P (publish) or -S (subscribe)\n");
        return 1;
    }

    if (opts.num_topics < 1 || opts.num_topics > MAX_TOPICS) {
        std::fprintf(stderr, "--num-topics must be between 1 and %u (got %u)\n", MAX_TOPICS, opts.num_topics);
        return 1;
    }

    if (opts.periodic_announcement_ms > 0) {
        setenv("ZZDDS_PARTICIPANT_ANNOUNCEMENT_PERIOD_MS", std::to_string(opts.periodic_announcement_ms).c_str(), 1);
    }

    if (opts.config_path) {
        auto cfg_rc = zzdds::process_configure_from_file(opts.config_path, nullptr);
        if (cfg_rc != DDS_RETCODE_OK) {
            std::fprintf(stderr, "failed to load config file '%s' (rc=%d)\n", opts.config_path, static_cast<int>(cfg_rc));
            return 1;
        }
    }

    auto factory = zzdds::create_factory();
    if (!factory) {
        std::fprintf(stderr, "FAIL: create_factory returned null\n");
        return 1;
    }

    auto dp = factory->create_participant(opts.domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "failed to create participant on domain %u\n", opts.domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    ShapeTypeTypeSupport::register_type(dp_handle);

    auto topic = dp->create_topic(opts.topic_name, "ShapeType", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "failed to create topic '%s'\n", opts.topic_name);
        return 1;
    }
    std::printf("Create topic: %s\n", opts.topic_name);

    int rc = opts.publish ? run_publisher(dp, topic, opts) : run_subscriber(dp, topic, opts);
    return rc;
}
