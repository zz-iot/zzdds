/*
 * integration-tests/cpp/source-timestamp -- publisher. Direct C++ port of
 * c/source-timestamp/src/publisher.c -- see that file's header comment for
 * the full scenario rationale and docs/design/integration-test-tier.md for
 * the scenario spec.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Publisher: wrote seq=... with explicit timestamp", "Publisher: disposed
 * instance with explicit timestamp", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "timestamp_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 5;
constexpr int32_t WRITE_BASE_SEC = 1000000;
constexpr int32_t DISPOSE_SEC = 2000000;
constexpr uint32_t DISPOSE_NSEC = 123456789u;
constexpr int MATCH_TIMEOUT_MS = 20000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct PubState {
    std::atomic<int> matched_current_count{0};
};

class PubListener : public ::DDS::DataWriterListenerBase {
public:
    explicit PubListener(PubState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
    }

private:
    PubState *state_;
};

uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) {
            return static_cast<uint32_t>(std::strtoul(argv[i + 1], nullptr, 10));
        }
    }
    return 0;
}

} // namespace

int main(int argc, char **argv) {
    uint32_t domain_id = parse_domain(argc, argv);

    auto factory = zzdds::create_factory();
    if (!factory) {
        std::fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }

    auto dp = factory->create_participant(domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    if (TimestampEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("TimestampEvent", "TimestampEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: TimestampEvent\n");
    std::fflush(stdout);

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
    std::printf("Create writer for topic: TimestampEvent\n");
    std::fflush(stdout);

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    if (dw->set_listener(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    TimestampEventDataWriter writer(dw->native_handle());

    for (int waited_ms = 0; state.matched_current_count.load() < 1; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reader matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    ::TimestampEvent key;
    key.id = 0;
    key.seq = 0;

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::TimestampEvent ev;
        ev.id = 0;
        ev.seq = seq;
        ::DDS_Time_t ts;
        ts.sec = WRITE_BASE_SEC + seq;
        ts.nanosec = 0;
        if (writer.write_w_timestamp(ev, ts) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write_w_timestamp() failed at seq=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote seq=%d with explicit timestamp sec=%d\n", seq, ts.sec);
        std::fflush(stdout);
    }

    ::DDS_Time_t dispose_ts;
    dispose_ts.sec = DISPOSE_SEC;
    dispose_ts.nanosec = DISPOSE_NSEC;
    if (writer.dispose_w_timestamp(key, dispose_ts) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: dispose_w_timestamp() failed\n");
        return 1;
    }
    std::printf("Publisher: disposed instance with explicit timestamp sec=%d nanosec=%u\n", dispose_ts.sec, dispose_ts.nanosec);
    std::fflush(stdout);

    for (int waited_ms = 0; state.matched_current_count.load() != 0; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Publisher: done.\n");
    std::fflush(stdout);
    factory->delete_participant(dp);
    return 0;
}
