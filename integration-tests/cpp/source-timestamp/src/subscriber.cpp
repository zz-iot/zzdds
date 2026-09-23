/*
 * integration-tests/cpp/source-timestamp -- subscriber (the entity under
 * test). Direct C++ port of c/source-timestamp/src/subscriber.c -- see that
 * file's header comment for the full scenario rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: ready.", "Subscriber: received seq=... with source_timestamp
 * sec=... matching the explicit write timestamp.", "Subscriber: received
 * disposed instance with source_timestamp matching the explicit dispose
 * timestamp.", "Subscriber: done." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
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
constexpr int RECEIVE_TIMEOUT_MS = 20000;
constexpr int POLL_PERIOD_MS = 20;

struct SubState {
    TimestampEventDataReader *reader = nullptr;
    std::atomic<bool> alive_received[SAMPLE_COUNT];
    std::atomic<int> alive_count{0};
    std::atomic<bool> dispose_received{false};
    std::atomic<bool> dispose_timestamp_ok{false};

    SubState() {
        for (auto &v : alive_received) v.store(false);
    }
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        for (;;) {
            TimestampEventDataReader::Sample sample{};
            uint8_t buf[256];
            size_t cdr_len = 0;
            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }

            if (sample.info.valid_data) {
                int32_t seq = sample.value.seq;
                if (seq < 0 || seq >= SAMPLE_COUNT) {
                    std::fprintf(stderr, "FAIL: unexpected seq=%d\n", seq);
                    std::exit(1);
                }
                if (sample.info.source_timestamp.sec != WRITE_BASE_SEC + seq || sample.info.source_timestamp.nanosec != 0) {
                    std::fprintf(stderr, "FAIL: seq=%d source_timestamp sec=%d nanosec=%u does not match expected sec=%d nanosec=0\n",
                                 seq, sample.info.source_timestamp.sec, sample.info.source_timestamp.nanosec, WRITE_BASE_SEC + seq);
                    std::exit(1);
                }
                std::printf("Subscriber: received seq=%d with source_timestamp sec=%d matching the explicit write timestamp.\n", seq, sample.info.source_timestamp.sec);
                std::fflush(stdout);
                if (!state_->alive_received[seq].load()) {
                    state_->alive_received[seq].store(true);
                    state_->alive_count.fetch_add(1);
                }
            } else if (sample.info.instance_state == DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE) {
                state_->dispose_received.store(true);
                if (sample.info.source_timestamp.sec == DISPOSE_SEC && sample.info.source_timestamp.nanosec == DISPOSE_NSEC) {
                    state_->dispose_timestamp_ok.store(true);
                } else {
                    std::fprintf(stderr, "FAIL: disposed-instance source_timestamp sec=%d nanosec=%u does not match expected sec=%d nanosec=%u\n",
                                 sample.info.source_timestamp.sec, sample.info.source_timestamp.nanosec, DISPOSE_SEC, DISPOSE_NSEC);
                    std::exit(1);
                }
            }
        }
    }

private:
    SubState *state_;
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

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto dr = sub->create_datareader(ztopic->as_topic_description(), dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: TimestampEvent\n");
    std::fflush(stdout);

    SubState state;
    TimestampEventDataReader reader(dr->native_handle());
    state.reader = &reader;

    auto listener = std::make_shared<SubListener>(&state);
    if (dr->set_listener(listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    std::printf("Subscriber: ready.\n");
    std::fflush(stdout);

    for (int waited_ms = 0; state.alive_count.load() < SAMPLE_COUNT || !state.dispose_received.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: only received %d/%d alive samples and dispose_received=%d within %ds\n",
                         state.alive_count.load(), SAMPLE_COUNT, state.dispose_received.load(), RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    if (!state.dispose_timestamp_ok.load()) {
        std::fprintf(stderr, "FAIL: dispose sample was received but its timestamp never matched (should have exited already)\n");
        return 1;
    }
    std::printf("Subscriber: received disposed instance with source_timestamp matching the explicit dispose timestamp.\n");
    std::fflush(stdout);

    std::printf("Subscriber: done.\n");
    std::fflush(stdout);
    factory->delete_participant(dp);
    return 0;
}
