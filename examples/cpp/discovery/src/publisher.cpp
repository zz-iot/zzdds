/*
 * cpp/discovery -- publisher. Direct C++ port of
 * zig/discovery/publisher.zig / c/discovery/src/publisher.c; see
 * docs/design/discovery-reference-app.md at the repo root for the full
 * spec.
 *
 * After creating its topic, calls DomainParticipant::get_discovered_topics/
 * _topic_data -- these succeed immediately, even before any remote peer
 * appears (a participant registers its own locally-created topics right
 * away). Once a reliable reader is ready (proving cross-process match
 * happened), calls DataWriter::get_matched_subscriptions/_subscription_data
 * to look up the matched subscriber's own topic/type name. Then runs the
 * same minimal reliable write loop (3 samples) as hello_world/
 * participant-config.
 *
 * Unlike zig/discovery, this crosses the C ABI under the hood -- but the
 * idiomatic C++ wrapper types (::DDS::TopicBuiltinTopicData's std::string
 * fields, ::DDS::InstanceHandleSeq as std::vector) are fully RAII, so
 * nothing here needs manual freeing (compare to c/discovery, which calls
 * the C-ABI struct's own _free() directly).
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Discovery OK (participant):", "on_reliable_reader_ready", "Discovery OK
 * (writer):", "Publisher: wrote count=", "Publisher: done." Any failure
 * path prints a line starting "FAIL:" and exits nonzero.
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

constexpr int SAMPLE_COUNT = 3;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

const char *TOPIC_NAME = "DiscoveryPing";
const char *TYPE_NAME = "DiscoveryPing";

struct PubState {
    std::atomic<bool> reader_ready{false};
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
};

class PubListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit PubListener(PubState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
        std::printf("on_publication_matched() current_count=%d\n", status.current_count);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
        std::printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
    }

private:
    PubState *state_;
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

    // Participant-level discovery: a freshly-created local topic is
    // immediately visible, no cross-process wait needed.
    {
        ::DDS::InstanceHandleSeq handles;
        if (dp->get_discovered_topics(handles) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_discovered_topics() failed\n");
            return 1;
        }
        bool found = false;
        ::DDS::TopicBuiltinTopicData topic_data;
        for (auto h : handles) {
            if (dp->get_discovered_topic_data(topic_data, h) != ::DDS::RETCODE_OK) continue;
            if (topic_data.name == TOPIC_NAME) {
                found = true;
                break;
            }
        }
        if (!found) {
            std::fprintf(stderr, "FAIL: get_discovered_topic_data() never returned '%s'\n", TOPIC_NAME);
            return 1;
        }
        if (topic_data.type_name != TYPE_NAME) {
            std::fprintf(stderr, "FAIL: discovered topic type_name mismatch: expected '%s', got '%s'\n",
                         TYPE_NAME, topic_data.type_name.c_str());
            return 1;
        }
        std::printf("Discovery OK (participant): topic.name='%s' topic.type_name='%s'\n",
                    topic_data.name.c_str(), topic_data.type_name.c_str());
    }

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: %s\n", TOPIC_NAME);

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    auto dw_handle = dw->native_handle();
    DiscoveryPingDataWriter writer(dw_handle);

    for (int waited_ms = 0; !state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    // Writer-level discovery: the remote subscriber has definitely matched
    // by now (on_reliable_reader_ready only fires once it has).
    {
        ::DDS::InstanceHandleSeq handles;
        if (dw->get_matched_subscriptions(handles) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_matched_subscriptions() failed\n");
            return 1;
        }
        if (handles.empty()) {
            std::fprintf(stderr, "FAIL: get_matched_subscriptions() returned no matches\n");
            return 1;
        }
        ::DDS::SubscriptionBuiltinTopicData sub_data;
        if (dw->get_matched_subscription_data(sub_data, handles[0]) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_matched_subscription_data() failed\n");
            return 1;
        }
        if (sub_data.topic_name != TOPIC_NAME || sub_data.type_name != TYPE_NAME) {
            std::fprintf(stderr, "FAIL: matched subscription topic_name/type_name mismatch: got '%s'/'%s'\n",
                         sub_data.topic_name.c_str(), sub_data.type_name.c_str());
            return 1;
        }
        std::printf("Discovery OK (writer): matched_subscription.topic_name='%s' type_name='%s'\n",
                    sub_data.topic_name.c_str(), sub_data.type_name.c_str());
    }

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        ::DiscoveryPing sample;
        sample.count = i;

        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at count=%d\n", i);
            return 1;
        }
        std::printf("Publisher: wrote count=%d\n", i);
    }

    for (int waited_ms = 0;
         !(state.ever_matched.load() && state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Publisher: done.\n");
    return 0;
}
