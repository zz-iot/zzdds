/*
 * cpp/presence -- publisher. Direct C++ port of zig/presence/publisher.zig;
 * see docs/design/presence-reference-app.md at the repo root for the full
 * spec. Demonstrates MANUAL_BY_TOPIC_LIVELINESS_QOS: writes for a while,
 * deliberately goes quiet (no writes, no asserts) for longer than its own
 * lease_duration, then calls DataWriter::assert_liveliness() explicitly
 * before resuming.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: wrote sequence=", "Publisher: going
 * offline", "Publisher: asserting liveliness and resuming", "Publisher:
 * done." Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "presence_sample.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int ONLINE_BEACON_COUNT = 8;
constexpr int BEACON_PERIOD_MS = 500;
constexpr int LEASE_DURATION_S = 2;
constexpr int OFFLINE_DURATION_MS = 5000; // > LEASE_DURATION_S
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

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

    if (PresenceBeaconTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("PresenceBeacon", "PresenceBeacon", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: PresenceBeacon\n");

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_LAST_HISTORY_QOS;
    dw_qos.history.depth = 1;
    dw_qos.liveliness.kind = ::DDS::LivelinessQosPolicyKind::MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration.sec = LEASE_DURATION_S;
    dw_qos.liveliness.lease_duration.nanosec = 0;

    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: PresenceBeacon\n");

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    auto dw_handle = dw->native_handle();
    PresenceBeaconDataWriter writer(dw_handle);

    for (int waited_ms = 0; !state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    // -- Online phase --
    int seq = 0;
    for (; seq < ONLINE_BEACON_COUNT; seq++) {
        ::PresenceBeacon sample;
        sample.seq_num = seq;
        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at sequence=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote sequence=%d\n", seq);
        usleep(BEACON_PERIOD_MS * 1000);
    }

    // -- Offline phase: no writes, no asserts, longer than the lease --
    std::printf("Publisher: going offline (no writes/asserts for %ds, lease is %ds)\n",
                OFFLINE_DURATION_MS / 1000, LEASE_DURATION_S);
    usleep(OFFLINE_DURATION_MS * 1000);

    // -- Recovery --
    std::printf("Publisher: asserting liveliness and resuming\n");
    if (dw->assert_liveliness() != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: assert_liveliness() failed\n");
        return 1;
    }

    for (; seq < ONLINE_BEACON_COUNT * 2; seq++) {
        ::PresenceBeacon sample;
        sample.seq_num = seq;
        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at sequence=%d\n", seq);
            return 1;
        }
        std::printf("Publisher: wrote sequence=%d\n", seq);
        usleep(BEACON_PERIOD_MS * 1000);
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
