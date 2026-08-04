/*
 * C++ port of zig/shape's shape_main -- the OMG DDS-Interoperability "Shapes"
 * demo app, talking to zzdds through its native C++ API (dcps.hpp/dcps_impl.hpp,
 * the same shared_ptr-based entity model cpp/custom-allocator uses). CLI/
 * behavior spec is dds-rtps's srcZig/shape_main.zig (see zig/shape); this
 * implements the "Must-have (v1)" flag subset from
 * docs/design/shape-reference-app.md plus --config -- same scope as c/shape,
 * see its README for exactly what's not implemented (stretch flags).
 */
#include "shape.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <ctime>
#include <memory>
#include <unistd.h>

namespace {

/* ── Options ─────────────────────────────────────────────────────────────── */

struct Options {
    bool publish = false;
    bool subscribe = false;
    uint32_t domain_id = 0;
    bool best_effort = false;
    bool reliable = false;
    int32_t history_depth = -1; /* -1 = use default KEEP_LAST 1 */
    const char *topic_name = "Square";
    const char *color = "BLUE";
    char durability = 'v'; /* 'v', 'l', 't', 'p' */
    bool print_writer_samples = false;
    int32_t shapesize = 20;
    long write_period_ms = 33;
    long read_period_ms = 100;
    int64_t num_iterations = -1; /* -1 = infinite */
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

/* zig/shape always explicitly offers/requests a one-element
 * DataRepresentationId sequence (XCDR1 by default) rather than leaving it
 * empty -- an empty sequence is DATAREPRESENTATION-incompatible with that
 * under zzdds's QoS matching (see c/shape's README: this was found and
 * fixed there via cross-binding testing first). */
void set_default_representation(::DDS::DataRepresentationQosPolicy &repr) {
    repr.value = { ::DDS::XCDR_DATA_REPRESENTATION };
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
    set_default_representation(qos.data_representation);
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
    set_default_representation(qos.data_representation);
    return qos;
}

/* ── Publisher ─────────────────────────────────────────────────────────────── */

int run_publisher(std::shared_ptr<::DDS::DomainParticipant> dp, std::shared_ptr<::DDS::Topic> topic, const Options &opts) {
    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher returned null\n");
        return 1;
    }

    auto dw_qos = build_writer_qos(opts);
    auto listener = std::make_shared<ShapeDataWriterListener>(opts.topic_name);
    auto dw = pub->create_datawriter(topic, dw_qos, listener, ::DDS::OFFERED_INCOMPATIBLE_QOS_STATUS);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter returned null\n");
        return 1;
    }
    auto dw_handle = std::static_pointer_cast<::DDS::DataWriterImpl>(dw)->native_handle();
    ShapeTypeDataWriter typed_writer(dw_handle);

    std::printf("Create writer for topic: %s color: %s\n", opts.topic_name, opts.color);

    ShapeType shape;
    shape.color = opts.color;
    shape.shapesize = (opts.shapesize == 0) ? 1 : opts.shapesize;

    std::srand(static_cast<unsigned>(mono_ns()));

    const int64_t match_deadline = mono_ns() + 10LL * 1000000000LL;
    bool printed_matched = false;

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts.num_iterations >= 0 && iteration >= opts.num_iterations) break;

        if (!printed_matched) {
            ::DDS::PublicationMatchedStatus status;
            dw->get_publication_matched_status(status);
            if (status.current_count > 0) {
                std::printf("on_publication_matched() topic: '%s'  type: 'ShapeType' : matched readers %d (change = 1)\n",
                            opts.topic_name, static_cast<int>(status.current_count));
                printed_matched = true;
            } else if (mono_ns() > match_deadline) {
                return 0; /* READER_NOT_MATCHED */
            }
        }

        shape.x = std::rand() % 320;
        shape.y = std::rand() % 240;

        int rc = typed_writer.write(shape);
        if (rc != DDS_RETCODE_OK) {
            std::fprintf(stderr, "FAIL: DataWriter::write (rc=%d)\n", rc);
            return 1;
        }
        if (opts.print_writer_samples) {
            std::printf("%-10s %-10s %03d %03d [%d]\n",
                        opts.topic_name, shape.color.c_str(), static_cast<int>(shape.x),
                        static_cast<int>(shape.y), static_cast<int>(shape.shapesize));
        }
        if (opts.shapesize == 0) {
            shape.shapesize++;
        }

        iteration++;
        usleep(static_cast<useconds_t>(opts.write_period_ms * 1000));
    }

    if (opts.num_iterations >= 0) {
        pub->wait_for_acknowledgments(::DDS::Duration_t{5, 0});
    }
    return 0;
}

/* ── Subscriber ────────────────────────────────────────────────────────────── */

int run_subscriber(std::shared_ptr<::DDS::DomainParticipant> dp, const Options &opts) {
    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber returned null\n");
        return 1;
    }

    /* Same lookup_topicdescription workaround cpp/custom-allocator uses:
     * create_datareader wants a genuine TopicDescriptionImpl-backed object,
     * not the TopicImpl shared_ptr create_topic returned. */
    auto topic_desc = dp->lookup_topicdescription(opts.topic_name);
    if (!topic_desc) {
        std::fprintf(stderr, "FAIL: lookup_topicdescription returned null\n");
        return 1;
    }

    auto dr_qos = build_reader_qos(opts);
    auto listener = std::make_shared<ShapeDataReaderListener>(opts.topic_name);
    auto dr = sub->create_datareader(topic_desc, dr_qos, listener, ::DDS::REQUESTED_INCOMPATIBLE_QOS_STATUS);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader returned null\n");
        return 1;
    }
    auto dr_handle = std::static_pointer_cast<::DDS::DataReaderImpl>(dr)->native_handle();
    ShapeTypeDataReader typed_reader(dr_handle);

    std::printf("Create reader for topic: %s\n", opts.topic_name);

    int64_t iteration = 0;
    while (!g_all_done) {
        if (opts.num_iterations >= 0 && iteration >= opts.num_iterations) break;

        /* HANDLE_NIL every call (not the last-seen handle) drains each
         * instance fully before moving to the next -- matches
         * zig/shape's take_next_instance loop. */
        for (;;) {
            ShapeTypeDataReader::Sample sample;
            sample.info = zzdds_sample_info{};
            uint8_t buf[256];
            size_t cdr_len = 0;

            int rc = typed_reader.take_next_instance(sample, DDS_HANDLE_NIL, buf, sizeof(buf), &cdr_len);
            if (rc != DDS_RETCODE_OK || !sample.info.valid_data) break;

            std::printf("%-10s %-10s %03d %03d [%d]\n",
                        opts.topic_name, sample.value.color.c_str(), static_cast<int>(sample.value.x),
                        static_cast<int>(sample.value.y), static_cast<int>(sample.value.shapesize));
        }

        iteration++;
        usleep(static_cast<useconds_t>(opts.read_period_ms * 1000));
    }
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
        } else if (std::strcmp(arg, "-d") == 0) {
            if (++i >= argc) return -1;
            opts.domain_id = static_cast<uint32_t>(std::strtoul(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "-k") == 0) {
            if (++i >= argc) return -1;
            opts.history_depth = static_cast<int32_t>(std::strtol(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "-t") == 0) {
            if (++i >= argc) return -1;
            opts.topic_name = argv[i];
        } else if (std::strcmp(arg, "-c") == 0) {
            if (++i >= argc) return -1;
            opts.color = argv[i];
        } else if (std::strcmp(arg, "-D") == 0) {
            if (++i >= argc) return -1;
            opts.durability = argv[i][0] ? argv[i][0] : 'v';
        } else if (std::strcmp(arg, "-z") == 0) {
            if (++i >= argc) return -1;
            opts.shapesize = static_cast<int32_t>(std::strtol(argv[i], nullptr, 10));
        } else if (std::strcmp(arg, "--write-period") == 0) {
            if (++i >= argc) return -1;
            opts.write_period_ms = std::strtol(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "--read-period") == 0) {
            if (++i >= argc) return -1;
            opts.read_period_ms = std::strtol(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "-i") == 0 || std::strcmp(arg, "--num-iterations") == 0) {
            if (++i >= argc) return -1;
            opts.num_iterations = std::strtoll(argv[i], nullptr, 10);
        } else if (std::strcmp(arg, "--config") == 0) {
            if (++i >= argc) return -1;
            opts.config_path = argv[i];
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
                "This C++ port implements the \"Must-have (v1)\" flag subset only -- see\n"
                "zig/shape -h for the full CLI/behavior spec (stretch flags not yet ported).\n"
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
    auto dp_handle = std::static_pointer_cast<::DDS::DomainParticipantImpl>(dp)->native_handle();

    ShapeTypeTypeSupport::register_type(dp_handle);

    auto topic = dp->create_topic(opts.topic_name, "ShapeType", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "failed to create topic '%s'\n", opts.topic_name);
        return 1;
    }
    std::printf("Create topic: %s\n", opts.topic_name);

    int rc = opts.publish ? run_publisher(dp, topic, opts) : run_subscriber(dp, opts);
    return rc;
}
