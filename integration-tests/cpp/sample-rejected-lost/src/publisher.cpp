/*
 * integration-tests/cpp/sample-rejected-lost -- publisher. Direct C++ port
 * of c/sample-rejected-lost/src/publisher.c -- see that file's header
 * comment for the full scenario rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create writer for topic:"
 * x3, "Publisher: wrote 5 samples on LostTopic...", "Publisher: wrote 5
 * samples on RejectedTopic...", "Publisher: sync sent.", "Publisher: done."
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "status_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct WriterSyncState {
    std::atomic<bool> reader_ready{false};
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
};

class WriterListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit WriterListener(WriterSyncState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
    }

private:
    WriterSyncState *state_;
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

    if (StatusEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register StatusEventTypeSupport failed\n");
        return 1;
    }

    auto rejected_topic = dp->create_topic("RejectedTopic", "StatusEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto lost_topic = dp->create_topic("LostTopic", "StatusEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto sync_topic = dp->create_topic("SyncTopic", "StatusEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!rejected_topic || !lost_topic || !sync_topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: RejectedTopic\n");
    std::printf("Create topic: LostTopic\n");
    std::printf("Create topic: SyncTopic\n");

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    // LostTopic FIRST, deliberately before any reader can possibly be
    // matched -- see the file header comment.
    auto lost_qos = ::DDS::DataWriterQos::default_value();
    lost_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    lost_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_LAST_HISTORY_QOS;
    lost_qos.history.depth = 1;
    // TRANSIENT_LOCAL so the late-joining reader can still receive whatever
    // remains in the writer's cache (the seq=4 sample) -- VOLATILE (the
    // default) would make it miss ALL 5 samples, not just the 4 evicted
    // ones. Eviction (and therefore loss of seq 0-3) still happens
    // regardless of durability.
    lost_qos.durability.kind = ::DDS::DurabilityQosPolicyKind::TRANSIENT_LOCAL_DURABILITY_QOS;

    auto lost_dw = pub->create_datawriter(lost_topic, lost_qos, nullptr, 0);
    if (!lost_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(LostTopic) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: LostTopic\n");

    {
        ::StatusEventDataWriter lost_writer(lost_dw->native_handle());
        for (int seq = 0; seq < 5; seq++) {
            ::StatusEvent ev;
            ev.seq = seq;
            if (lost_writer.write(ev) != 0) {
                std::fprintf(stderr, "FAIL: LostTopic write() failed at seq=%d\n", seq);
                return 1;
            }
        }
    }
    std::printf("Publisher: wrote 5 samples on LostTopic (KEEP_LAST depth=1, no reader matched yet).\n");

    auto rejected_qos = ::DDS::DataWriterQos::default_value();
    rejected_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    rejected_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    auto rejected_dw = pub->create_datawriter(rejected_topic, rejected_qos, nullptr, 0);
    if (!rejected_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(RejectedTopic) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: RejectedTopic\n");

    auto sync_qos = ::DDS::DataWriterQos::default_value();
    sync_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    auto sync_dw = pub->create_datawriter(sync_topic, sync_qos, nullptr, 0);
    if (!sync_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(SyncTopic) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: SyncTopic\n");

    WriterSyncState rejected_state, sync_state, lost_state;
    auto rejected_listener = std::make_shared<WriterListener>(&rejected_state);
    auto sync_listener = std::make_shared<WriterListener>(&sync_state);
    auto lost_listener = std::make_shared<WriterListener>(&lost_state);
    auto zrejected_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(rejected_dw);
    auto zsync_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(sync_dw);
    auto zlost_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(lost_dw);
    if (zrejected_dw->set_listener_ex(rejected_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK ||
        zsync_dw->set_listener_ex(sync_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK ||
        zlost_dw->set_listener_ex(lost_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    // Only Rejected/Sync need to wait for their reader -- the subscriber
    // creates those two immediately at startup. LostTopic's reader isn't
    // created until the subscriber gets the Sync sample, by design.
    for (int waited_ms = 0;
         !(rejected_state.reader_ready.load() && sync_state.reader_ready.load());
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    ::StatusEventDataWriter rejected_writer(rejected_dw->native_handle());
    // The subscriber deliberately does not drain RejectedTopic until it has
    // confirmed rejection happened, so no reader-side consumption race is
    // possible here regardless of exact write timing.
    for (int seq = 0; seq < 5; seq++) {
        ::StatusEvent ev;
        ev.seq = seq;
        if (rejected_writer.write(ev) != 0) {
            std::fprintf(stderr, "FAIL: RejectedTopic write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    std::printf("Publisher: wrote 5 samples on RejectedTopic (up to 2 expected rejected).\n");

    ::StatusEventDataWriter sync_writer(sync_dw->native_handle());
    ::StatusEvent sync_ev;
    sync_ev.seq = 0;
    if (sync_writer.write(sync_ev) != 0) {
        std::fprintf(stderr, "FAIL: SyncTopic write() failed\n");
        return 1;
    }
    std::printf("Publisher: sync sent.\n");
    std::printf("Publisher: done.\n");

    for (int waited_ms = 0;
         !(rejected_state.ever_matched.load() && rejected_state.matched_current_count.load() == 0 &&
           sync_state.ever_matched.load() && sync_state.matched_current_count.load() == 0 &&
           lost_state.ever_matched.load() && lost_state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    if (pub->delete_datawriter(rejected_dw) != ::DDS::RETCODE_OK ||
        pub->delete_datawriter(lost_dw) != ::DDS::RETCODE_OK ||
        pub->delete_datawriter(sync_dw) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: delete_datawriter() did not return RETCODE_OK\n");
        return 1;
    }

    return 0;
}
