/*
 * integration-tests/cpp/cft-reconfigure -- publisher. Direct C++ port of
 * c/cft-reconfigure/src/publisher.c -- see that file's header comment for
 * the full scenario rationale and docs/design/integration-test-tier.md for
 * the scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create writer for topic:",
 * "Publisher: wrote phase1 seq=", "Publisher: received go-ahead signal.",
 * "Publisher: wrote phase2 seq=", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "cft_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int PHASE1_COUNT = 5;
constexpr int PHASE2_COUNT = 5;
// 40s, not the 20s every other match-wait in this tier uses -- see
// c/cft-reconfigure/src/publisher.c's matching comment.
constexpr int MATCH_TIMEOUT_MS = 40000;
constexpr int GO_TIMEOUT_MS = 20000;
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

    if (CftEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("CftEvent", "CftEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: CftEvent\n");
    std::fflush(stdout);

    auto go_topic = dp->create_topic("GoTopic", "CftEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!go_topic) {
        std::fprintf(stderr, "FAIL: create_topic(GoTopic) failed\n");
        return 1;
    }
    std::printf("Create topic: GoTopic\n");
    std::fflush(stdout);

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!pub || !sub) {
        std::fprintf(stderr, "FAIL: create_publisher()/create_subscriber() failed\n");
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
    std::printf("Create writer for topic: CftEvent\n");
    std::fflush(stdout);

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    if (dw->set_listener(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto go_ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(go_topic);
    auto go_dr = sub->create_datareader(go_ztopic->as_topic_description(), dr_qos, nullptr, 0);
    if (!go_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(GoTopic) failed\n");
        return 1;
    }

    CftEventDataWriter writer(dw->native_handle());
    CftEventDataReader go_reader(go_dr->native_handle());

    // -- Wait for both of the subscriber's readers (witness + filtered) to
    // match before writing anything, so phase1 is guaranteed to actually
    // reach both. --
    for (int waited_ms = 0; state.matched_current_count.load() < 2; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: fewer than 2 readers matched within %ds (got %d)\n", MATCH_TIMEOUT_MS / 1000, state.matched_current_count.load());
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    // -- Phase 1: written while the CFT's threshold excludes all of it. --
    for (int seq = 0; seq < PHASE1_COUNT; seq++) {
        ::CftEvent ev;
        ev.seq = seq;
        if (writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write(phase1) failed at seq=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote phase1 seq=%d\n", seq);
        std::fflush(stdout);
    }

    // -- Wait for the subscriber's go-ahead: it has confirmed phase1 was
    // filtered out and reconfigured the CFT's parameters in place. --
    bool got_go = false;
    for (int waited_ms = 0; !got_go; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= GO_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: go-ahead signal never arrived within %ds\n", GO_TIMEOUT_MS / 1000);
            return 1;
        }
        CftEventDataReader::Sample sample{};
        uint8_t buf[256];
        size_t cdr_len = 0;
        int rc = go_reader.take(sample, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_OK && sample.info.valid_data) {
            got_go = true;
            break;
        }
        if (rc != DDS_RETCODE_OK && rc != DDS_RETCODE_NO_DATA) {
            std::fprintf(stderr, "FAIL: take(GoTopic) CDR error (rc=%d)\n", rc);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Publisher: received go-ahead signal.\n");
    std::fflush(stdout);

    // -- Phase 2: written after the reconfigure, on the same DataWriter. --
    for (int seq = PHASE1_COUNT; seq < PHASE1_COUNT + PHASE2_COUNT; seq++) {
        ::CftEvent ev;
        ev.seq = seq;
        if (writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write(phase2) failed at seq=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote phase2 seq=%d\n", seq);
        std::fflush(stdout);
    }

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
