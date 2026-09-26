/*
 * integration-tests/cpp/liveliness-lost -- subscriber. Direct C++ port of
 * c/liveliness-lost/src/subscriber.c -- see that file's header comment for
 * the full scenario rationale and docs/design/integration-test-tier.md for
 * the scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create reader for topic:"
 * x2, "Subscriber: both writers matched.", "Subscriber: AUTOMATIC reader
 * never observed NOT_ALIVE, as expected.", "Subscriber: MANUAL_BY_PARTICIPANT
 * reader observed NOT_ALIVE at least once, as expected.", "Subscriber:
 * done." Any failure path prints a line starting "FAIL:" and exits
 * nonzero.
 */
#include "liveliness_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int LEASE_DURATION_SEC = 2;
// Comfortably longer than the publisher's own ~8s write loop (16 writes *
// 500ms), so the observation window covers the whole thing.
constexpr int OBSERVE_WINDOW_S = 12;
// 40s, not the 20s every other match-wait in this tier uses -- see
// c/liveliness-lost/src/publisher.c's matching comment.
constexpr int MATCH_TIMEOUT_MS = 40000;
constexpr int POLL_PERIOD_MS = 20;

struct ReaderState {
    std::atomic<int> matched_current_count{0};
    std::atomic<int> alive_count{0};
    std::atomic<bool> ever_not_alive{false};
};

class ReaderListener : public ::DDS::DataReaderListenerBase {
public:
    explicit ReaderListener(ReaderState *state) : state_(state) {}

    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                                  ::DDS::SubscriptionMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
    }

    void on_liveliness_changed(std::shared_ptr<::DDS::DataReader> /*the_reader*/,
                                ::DDS::LivelinessChangedStatus status) override {
        state_->alive_count.store(status.alive_count);
        if (status.alive_count == 0) state_->ever_not_alive.store(true);
    }

private:
    ReaderState *state_;
};

uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) {
            return static_cast<uint32_t>(std::strtoul(argv[i + 1], nullptr, 10));
        }
    }
    return 0;
}

std::shared_ptr<::DDS::DataReader> create_reader(std::shared_ptr<::DDS::DomainParticipant> dp,
                                                   std::shared_ptr<::DDS::Subscriber> sub,
                                                   const char *topic_name,
                                                   ::DDS::LivelinessQosPolicyKind kind,
                                                   std::shared_ptr<ReaderListener> listener) {
    auto topic = dp->create_topic(topic_name, "LivelinessEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic(%s) failed\n", topic_name);
        return nullptr;
    }
    std::printf("Create topic: %s\n", topic_name);
    std::fflush(stdout);

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    dr_qos.liveliness.kind = kind;
    dr_qos.liveliness.lease_duration.sec = LEASE_DURATION_SEC;
    dr_qos.liveliness.lease_duration.nanosec = 0;

    // listener is owned by main()'s own scope, not this function's -- see
    // publisher.cpp's matching comment.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto dr = sub->create_datareader(ztopic->as_topic_description(), dr_qos, listener, DDS_SUBSCRIPTION_MATCHED_STATUS | DDS_LIVELINESS_CHANGED_STATUS);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader(%s) failed\n", topic_name);
        return nullptr;
    }
    std::printf("Create reader for topic: %s\n", topic_name);
    std::fflush(stdout);
    return dr;
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

    if (LivelinessEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    ReaderState auto_state, manual_state;
    auto auto_listener = std::make_shared<ReaderListener>(&auto_state);
    auto manual_listener = std::make_shared<ReaderListener>(&manual_state);
    auto auto_dr = create_reader(dp, sub, "AutomaticLivelinessTopic", ::DDS::LivelinessQosPolicyKind::AUTOMATIC_LIVELINESS_QOS, auto_listener);
    if (!auto_dr) return 1;
    auto manual_dr = create_reader(dp, sub, "ManualByParticipantLivelinessTopic", ::DDS::LivelinessQosPolicyKind::MANUAL_BY_PARTICIPANT_LIVELINESS_QOS, manual_listener);
    if (!manual_dr) return 1;

    for (int waited_ms = 0; auto_state.matched_current_count.load() < 1 || manual_state.matched_current_count.load() < 1; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: writers never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Subscriber: both writers matched.\n");
    std::fflush(stdout);

    sleep(OBSERVE_WINDOW_S);

    if (auto_state.ever_not_alive.load()) {
        std::fprintf(stderr, "FAIL: AUTOMATIC reader observed NOT_ALIVE (alive_count dropped to 0) at some point, expected never\n");
        return 1;
    }
    std::printf("Subscriber: AUTOMATIC reader never observed NOT_ALIVE, as expected.\n");
    std::fflush(stdout);

    if (!manual_state.ever_not_alive.load()) {
        std::fprintf(stderr, "FAIL: MANUAL_BY_PARTICIPANT reader never observed NOT_ALIVE despite the writer never asserting liveliness, expected at least once\n");
        return 1;
    }
    std::printf("Subscriber: MANUAL_BY_PARTICIPANT reader observed NOT_ALIVE at least once, as expected.\n");
    std::fflush(stdout);

    std::printf("Subscriber: done.\n");
    std::fflush(stdout);
    factory->delete_participant(dp);
    return 0;
}
