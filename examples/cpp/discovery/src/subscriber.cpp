/*
 * cpp/discovery -- subscriber. Direct C++ port of
 * zig/discovery/subscriber.zig / c/discovery/src/subscriber.c; see
 * docs/design/discovery-reference-app.md at the repo root for the full
 * spec.
 *
 * Waits for a matched publication (polling DataReader::get_matched_
 * publications, bounded by a timeout), then calls DataReader::get_matched_
 * publication_data to look up the matched writer's own topic/type name.
 * Then runs the same minimal reliable read loop (3 samples) as
 * hello_world/participant-config.
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Discovery OK (reader):", "Subscriber: received count=", "Subscriber:
 * received all 3 samples in order." Any failure path prints a line
 * starting "FAIL:" and exits nonzero.
 */
#include "discovery_ping.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int EXPECTED_SAMPLES = 3;
constexpr int MATCH_TIMEOUT_MS = 10000;
constexpr int RECEIVE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

const char *TOPIC_NAME = "DiscoveryPing";
const char *TYPE_NAME = "DiscoveryPing";

struct SubState {
    DiscoveryPingDataReader *reader = nullptr;
    int32_t expected_next = 0;
    std::atomic<bool> all_received{false};
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        for (;;) {
            DiscoveryPingDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;

            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }
            if (!sample.info.valid_data) break;

            if (sample.value.count != state_->expected_next) {
                std::fprintf(stderr, "FAIL: expected count=%d but got count=%d\n",
                              state_->expected_next, sample.value.count);
                std::exit(1);
            }

            std::printf("Subscriber: received count=%d\n", sample.value.count);
            state_->expected_next++;

            if (state_->expected_next == EXPECTED_SAMPLES) {
                state_->all_received.store(true);
            }
        }
    }

private:
    SubState *state_;
};

struct Options {
    uint32_t domain_id = 0;
};

Options parse_args(int argc, char **argv) {
    Options opts;
    for (int i = 1; i < argc; i++) {
        if ((std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) && i + 1 < argc) {
            opts.domain_id = static_cast<uint32_t>(std::strtoul(argv[++i], nullptr, 10));
        }
    }
    return opts;
}

} // namespace

int main(int argc, char **argv) {
    Options opts = parse_args(argc, argv);

    auto factory = zzdds::create_factory();
    if (!factory) {
        std::fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    auto dp = factory->create_participant(opts.domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", opts.domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    if (DiscoveryPingTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic(TOPIC_NAME, TYPE_NAME, ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: %s\n", TOPIC_NAME);

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    SubState state;
    auto listener = std::make_shared<SubListener>(&state);

    // Create with no listener attached yet: on_data_available fires on a
    // zzdds-internal dispatch thread as soon as the reader matches, which
    // can race state.reader's own initialization below. Attach the
    // listener only once state.reader is set, via set_listener() below,
    // closing the window entirely.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: %s\n", TOPIC_NAME);

    auto dr_handle = dr->native_handle();
    DiscoveryPingDataReader reader(dr_handle);
    state.reader = &reader;

    if (dr->set_listener(listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    // Reader-level discovery: wait for the remote publisher to match.
    ::DDS::InstanceHandleSeq pub_handles;
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (dr->get_matched_publications(pub_handles) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_matched_publications() failed\n");
            return 1;
        }
        if (!pub_handles.empty()) break;
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no matched publication within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    ::DDS::PublicationBuiltinTopicData pub_data;
    if (dr->get_matched_publication_data(pub_data, pub_handles[0]) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: get_matched_publication_data() failed\n");
        return 1;
    }
    if (pub_data.topic_name != TOPIC_NAME || pub_data.type_name != TYPE_NAME) {
        std::fprintf(stderr, "FAIL: matched publication topic_name/type_name mismatch: got '%s'/'%s'\n",
                     pub_data.topic_name.c_str(), pub_data.type_name.c_str());
        return 1;
    }
    std::printf("Discovery OK (reader): matched_publication.topic_name='%s' type_name='%s'\n",
                pub_data.topic_name.c_str(), pub_data.type_name.c_str());

    std::printf("Subscriber: waiting for %d samples...\n", EXPECTED_SAMPLES);
    for (int waited_ms = 0; !state.all_received.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                          state.expected_next, EXPECTED_SAMPLES, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    sub->delete_datareader(dr);

    std::printf("Subscriber: received all %d samples in order.\n", EXPECTED_SAMPLES);
    return 0;
}
