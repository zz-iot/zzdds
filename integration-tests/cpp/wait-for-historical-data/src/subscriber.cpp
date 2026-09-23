/*
 * integration-tests/cpp/wait-for-historical-data -- subscriber (the late
 * joiner). Direct C++ port of c/wait-for-historical-data/src/subscriber.c --
 * see that file's header comment for the full scenario rationale
 * (negative-then-positive wait_for_historical_data() bar) and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: negative check (no writer yet) correctly returned TIMEOUT.",
 * "Subscriber: ready for publisher.", "Subscriber: wait_for_historical_data()
 * returned", "HISTORICAL BATCH COMPLETE (8 samples)", "LIVE SAMPLE seq_num=",
 * "Subscriber: observed historical batch then live batch correctly." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "history_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int HISTORICAL_COUNT = 8;
constexpr int LIVE_COUNT = 4;
constexpr int NEGATIVE_WAIT_NSEC = 300 * 1000 * 1000;
constexpr int HISTORICAL_WAIT_TIMEOUT_S = 15;
constexpr int RECEIVE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

struct SubState {
    HistoryEventDataReader *reader = nullptr;
    std::atomic<bool> historical_received[8];
    std::atomic<bool> live_received[4];
    std::atomic<bool> historical_confirmed{false};
    std::atomic<bool> all_done{false};

    SubState() {
        for (auto &v : historical_received) v.store(false);
        for (auto &v : live_received) v.store(false);
    }

    bool ready_to_finish() {
        if (!historical_confirmed.load()) return false;
        for (auto &v : live_received) {
            if (!v.load()) return false;
        }
        return true;
    }
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        bool became_done = false;

        for (;;) {
            HistoryEventDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;

            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }
            if (!sample.info.valid_data) continue;

            int32_t seq_num = sample.value.seq_num;
            if (seq_num >= 0 && seq_num < HISTORICAL_COUNT) {
                state_->historical_received[seq_num].store(true);
            } else if (seq_num >= HISTORICAL_COUNT && seq_num < HISTORICAL_COUNT + LIVE_COUNT) {
                std::printf("LIVE SAMPLE seq_num=%d\n", seq_num);
                state_->live_received[seq_num - HISTORICAL_COUNT].store(true);
                if (!state_->all_done.load() && !became_done && state_->ready_to_finish()) {
                    became_done = true;
                }
            } else {
                std::fprintf(stderr, "FAIL: unexpected seq_num=%d\n", seq_num);
                std::exit(1);
            }
        }

        if (became_done) {
            state_->all_done.store(true);
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

    if (HistoryEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("HistoryEvent", "HistoryEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: HistoryEvent\n");

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = ::DDS::DurabilityQosPolicyKind::TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    SubState state;
    auto listener = std::make_shared<SubListener>(&state);

    // Create with no listener attached yet -- see this file's header
    // comment and c/wait-for-historical-data/src/subscriber.c's matching
    // comment for why.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: HistoryEvent\n");

    auto dr_handle = dr->native_handle();
    HistoryEventDataReader reader(dr_handle);
    state.reader = &reader;

    if (dr->set_listener(listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    // Negative case -- see this file's header comment. No writer exists
    // anywhere on this domain yet (the harness enforces that), so a short,
    // non-zero max_wait here is guaranteed to time out.
    ::DDS::Duration_t negative_wait;
    negative_wait.sec = 0;
    negative_wait.nanosec = NEGATIVE_WAIT_NSEC;
    ::DDS::ReturnCode_t neg_rc = dr->wait_for_historical_data(negative_wait);
    if (neg_rc != ::DDS::RETCODE_TIMEOUT) {
        std::fprintf(stderr, "FAIL: wait_for_historical_data() with no writer matched returned %d, expected RETCODE_TIMEOUT (%d)\n",
                      static_cast<int>(neg_rc), static_cast<int>(::DDS::RETCODE_TIMEOUT));
        return 1;
    }
    std::printf("Subscriber: negative check (no writer yet) correctly returned TIMEOUT.\n");

    // Tells the harness it's now safe to start the publisher -- see this
    // file's header comment and the interop test's wait_for_marker().
    std::printf("Subscriber: ready for publisher.\n");
    std::fflush(stdout);

    // The positive case: block until the TRANSIENT_LOCAL historical replay
    // has actually landed, before taking anything.
    ::DDS::Duration_t max_wait;
    max_wait.sec = HISTORICAL_WAIT_TIMEOUT_S;
    max_wait.nanosec = 0;
    ::DDS::ReturnCode_t rc = dr->wait_for_historical_data(max_wait);
    if (rc != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: wait_for_historical_data() returned %d\n", static_cast<int>(rc));
        return 1;
    }
    std::printf("Subscriber: wait_for_historical_data() returned\n");

    // Confirm the real guarantee, not just the return code: every
    // historical sample must already have been delivered by now.
    int historical_count = 0;
    for (auto &v : state.historical_received) {
        if (v.load()) historical_count++;
    }
    if (historical_count != HISTORICAL_COUNT) {
        std::fprintf(stderr, "FAIL: wait_for_historical_data() returned OK but only %d/%d historical samples were actually received\n", historical_count, HISTORICAL_COUNT);
        return 1;
    }
    std::printf("HISTORICAL BATCH COMPLETE (%d samples)\n", HISTORICAL_COUNT);
    state.historical_confirmed.store(true);
    if (state.ready_to_finish()) {
        state.all_done.store(true);
    }

    for (int waited_ms = 0; !state.all_done.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: did not observe the full live batch within %ds\n", RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    sub->delete_datareader(dr);

    std::printf("Subscriber: observed historical batch then live batch correctly.\n");
    factory->delete_participant(dp);
    return 0;
}
