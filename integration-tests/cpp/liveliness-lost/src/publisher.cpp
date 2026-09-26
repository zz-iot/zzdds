/*
 * integration-tests/cpp/liveliness-lost -- publisher. Direct C++ port of
 * c/liveliness-lost/src/publisher.c -- see that file's header comment for
 * the full scenario rationale and docs/design/integration-test-tier.md for
 * the scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create writer for topic:"
 * x2, "Publisher: both readers matched.", "Publisher: write loop done.",
 * "Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as
 * expected.", "Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness
 * (total_count=N) despite continuous writing, as expected.", "Publisher:
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
constexpr int WRITE_PERIOD_MS = 500;
constexpr int WRITE_COUNT = 16; // 16 * 500ms = 8s, comfortably > 4 lease periods
// 40s, not the 20s every other match-wait in this tier uses -- see
// c/liveliness-lost/src/publisher.c's matching comment.
constexpr int MATCH_TIMEOUT_MS = 40000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct WriterState {
    std::atomic<int> matched_current_count{0};
    std::atomic<int> liveliness_lost_count{0};
};

class WriterListener : public ::DDS::DataWriterListenerBase {
public:
    explicit WriterListener(WriterState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
    }

    void on_liveliness_lost(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                             ::DDS::LivelinessLostStatus /*status*/) override {
        state_->liveliness_lost_count.fetch_add(1);
    }

private:
    WriterState *state_;
};

uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (std::strcmp(argv[i], "-d") == 0 || std::strcmp(argv[i], "--domain") == 0) {
            return static_cast<uint32_t>(std::strtoul(argv[i + 1], nullptr, 10));
        }
    }
    return 0;
}

std::shared_ptr<::DDS::DataWriter> create_writer(std::shared_ptr<::DDS::DomainParticipant> dp,
                                                   std::shared_ptr<::DDS::Publisher> pub,
                                                   const char *topic_name,
                                                   ::DDS::LivelinessQosPolicyKind kind,
                                                   std::shared_ptr<WriterListener> listener) {
    auto topic = dp->create_topic(topic_name, "LivelinessEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic(%s) failed\n", topic_name);
        return nullptr;
    }
    std::printf("Create topic: %s\n", topic_name);
    std::fflush(stdout);

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    dw_qos.liveliness.kind = kind;
    dw_qos.liveliness.lease_duration.sec = LEASE_DURATION_SEC;
    dw_qos.liveliness.lease_duration.nanosec = 0;

    // listener is owned by main()'s own scope, not this function's -- it
    // must outlive the writer, and create_datawriter() only takes a
    // shared_ptr parameter here, not shared ownership of it beyond the call.
    auto dw = pub->create_datawriter(topic, dw_qos, listener, DDS_PUBLICATION_MATCHED_STATUS | DDS_LIVELINESS_LOST_STATUS);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(%s) failed\n", topic_name);
        return nullptr;
    }
    std::printf("Create writer for topic: %s\n", topic_name);
    std::fflush(stdout);
    return dw;
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

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    WriterState auto_state, manual_state;
    // Held here, not inside create_writer(): create_datawriter() takes the
    // listener as a shared_ptr parameter but doesn't necessarily extend its
    // lifetime beyond the call, so it must be kept alive for as long as the
    // writer itself is (the whole rest of main()), not just the helper call.
    auto auto_listener = std::make_shared<WriterListener>(&auto_state);
    auto manual_listener = std::make_shared<WriterListener>(&manual_state);
    auto auto_dw = create_writer(dp, pub, "AutomaticLivelinessTopic", ::DDS::LivelinessQosPolicyKind::AUTOMATIC_LIVELINESS_QOS, auto_listener);
    if (!auto_dw) return 1;
    auto manual_dw = create_writer(dp, pub, "ManualByParticipantLivelinessTopic", ::DDS::LivelinessQosPolicyKind::MANUAL_BY_PARTICIPANT_LIVELINESS_QOS, manual_listener);
    if (!manual_dw) return 1;

    LivelinessEventDataWriter auto_writer(auto_dw->native_handle());
    LivelinessEventDataWriter manual_writer(manual_dw->native_handle());

    for (int waited_ms = 0; auto_state.matched_current_count.load() < 1 || manual_state.matched_current_count.load() < 1; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: readers never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Publisher: both readers matched.\n");
    std::fflush(stdout);

    // Deliberately never call assert_liveliness() anywhere in this loop --
    // that's the whole point (see this file's header comment).
    for (int i = 0; i < WRITE_COUNT; i++) {
        ::LivelinessEvent ev;
        ev.seq = i;
        if (auto_writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write(AUTOMATIC) failed at seq=%d\n", i);
            return 1;
        }
        if (manual_writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write(MANUAL_BY_PARTICIPANT) failed at seq=%d\n", i);
            return 1;
        }
        usleep(WRITE_PERIOD_MS * 1000);
    }
    std::printf("Publisher: write loop done.\n");
    std::fflush(stdout);

    ::DDS::LivelinessLostStatus auto_status, manual_status;
    if (auto_dw->get_liveliness_lost_status(auto_status) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: get_liveliness_lost_status(AUTOMATIC) failed\n");
        return 1;
    }
    if (manual_dw->get_liveliness_lost_status(manual_status) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: get_liveliness_lost_status(MANUAL_BY_PARTICIPANT) failed\n");
        return 1;
    }

    if (auto_state.liveliness_lost_count.load() != 0 || auto_status.total_count != 0) {
        std::fprintf(stderr, "FAIL: AUTOMATIC writer lost liveliness (listener_count=%d, status.total_count=%d), expected never\n",
                     auto_state.liveliness_lost_count.load(), auto_status.total_count);
        return 1;
    }
    std::printf("Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as expected.\n");
    std::fflush(stdout);

    if (manual_state.liveliness_lost_count.load() < 1 || manual_status.total_count < 1) {
        std::fprintf(stderr, "FAIL: MANUAL_BY_PARTICIPANT writer never lost liveliness (listener_count=%d, status.total_count=%d) despite never asserting it, expected >=1\n",
                     manual_state.liveliness_lost_count.load(), manual_status.total_count);
        return 1;
    }
    std::printf("Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness (total_count=%d) despite continuous writing, as expected.\n", manual_status.total_count);
    std::fflush(stdout);

    for (int waited_ms = 0; auto_state.matched_current_count.load() != 0 || manual_state.matched_current_count.load() != 0; waited_ms += POLL_PERIOD_MS) {
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
