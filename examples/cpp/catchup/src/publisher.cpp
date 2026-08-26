/*
 * cpp/catchup -- publisher. Direct C++ port of zig/catchup/publisher.zig;
 * see docs/design/catchup-reference-app.md at the repo root for the full
 * spec. Writes a historical batch immediately, with no reader matched yet,
 * then -- once a reader does match -- writes a live batch. TRANSIENT_LOCAL
 * durability means zzdds's own writer-side cache (not this app) is what
 * makes the historical batch replayable to a late joiner.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: wrote historical seq_num=", "Publisher:
 * reader matched, writing live batch", "Publisher: wrote live seq_num=",
 * "Publisher: done." Any failure path prints a line starting "FAIL:" and
 * exits nonzero.
 */
#include "catchup_sample.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int HISTORICAL_COUNT = 10;
constexpr int LIVE_COUNT = 5;
constexpr int MATCH_TIMEOUT_MS = 15000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct PubState {
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
};

class PubListener : public ::DDS::DataWriterListenerBase {
public:
    explicit PubListener(PubState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
        std::printf("on_publication_matched() current_count=%d\n", status.current_count);
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

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.durability.kind = ::DDS::DurabilityQosPolicyKind::TRANSIENT_LOCAL_DURABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: HistoryEvent\n");

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    if (dw->set_listener(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    auto dw_handle = dw->native_handle();
    HistoryEventDataWriter writer(dw_handle);

    // -- Historical batch: written immediately, no reader matched yet. --
    int seq = 0;
    for (; seq < HISTORICAL_COUNT; seq++) {
        ::HistoryEvent sample;
        sample.seq_num = seq;
        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at seq_num=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote historical seq_num=%d\n", seq);
    }

    // -- Wait for the late-joining reader to match. --
    for (int waited_ms = 0; !state.ever_matched.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reader matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Publisher: reader matched, writing live batch\n");

    // -- Live batch. --
    for (; seq < HISTORICAL_COUNT + LIVE_COUNT; seq++) {
        ::HistoryEvent sample;
        sample.seq_num = seq;
        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at seq_num=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote live seq_num=%d\n", seq);
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
