/*
 * integration-tests/cpp/coherent-sets -- publisher. Direct C++ port of
 * c/coherent-sets/src/publisher.c; see
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create writer for topic:"
 * x2, "Publisher: wrote group N", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "pose_group.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int GROUP_COUNT = 20;
constexpr int WRITE_GAP_US = 8 * 1000;
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

    if (PositionTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register PositionTypeSupport failed\n");
        return 1;
    }
    if (VelocityTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register VelocityTypeSupport failed\n");
        return 1;
    }

    auto position_topic = dp->create_topic("Position", "Position", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!position_topic) {
        std::fprintf(stderr, "FAIL: create_topic(Position) failed\n");
        return 1;
    }
    std::printf("Create topic: Position\n");

    auto velocity_topic = dp->create_topic("Velocity", "Velocity", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!velocity_topic) {
        std::fprintf(stderr, "FAIL: create_topic(Velocity) failed\n");
        return 1;
    }
    std::printf("Create topic: Velocity\n");

    auto pub_qos = ::DDS::PublisherQos::default_value();
    pub_qos.presentation.access_scope = ::DDS::PresentationQosPolicyAccessScopeKind::GROUP_PRESENTATION_QOS;
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.ordered_access = true;

    auto pub = dp->create_publisher(pub_qos, nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto position_dw = pub->create_datawriter(position_topic, dw_qos, nullptr, 0);
    if (!position_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(Position) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: Position\n");

    auto velocity_dw = pub->create_datawriter(velocity_topic, dw_qos, nullptr, 0);
    if (!velocity_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(Velocity) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: Velocity\n");

    WriterSyncState position_state, velocity_state;
    auto position_listener = std::make_shared<WriterListener>(&position_state);
    auto velocity_listener = std::make_shared<WriterListener>(&velocity_state);
    auto zposition_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(position_dw);
    auto zvelocity_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(velocity_dw);
    if (zposition_dw->set_listener_ex(position_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK ||
        zvelocity_dw->set_listener_ex(velocity_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    for (int waited_ms = 0;
         !(position_state.reader_ready.load() && velocity_state.reader_ready.load());
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    PositionDataWriter position_writer(position_dw->native_handle());
    VelocityDataWriter velocity_writer(velocity_dw->native_handle());

    for (int group_id = 0; group_id < GROUP_COUNT; group_id++) {
        if (pub->begin_coherent_changes() != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: begin_coherent_changes() failed at group=%d\n", group_id);
            return 1;
        }

        ::Position pos;
        pos.group_id = group_id;
        pos.x = static_cast<double>(group_id);
        pos.y = static_cast<double>(group_id) * 2.0;
        if (position_writer.write(pos) != 0) {
            std::fprintf(stderr, "FAIL: Position write() failed at group=%d\n", group_id);
            return 1;
        }

        // Deliberate gap -- see publisher.c's matching comment.
        usleep(WRITE_GAP_US);

        ::Velocity vel;
        vel.group_id = group_id;
        vel.vx = static_cast<double>(group_id) * 0.5;
        vel.vy = static_cast<double>(group_id) * 1.5;
        if (velocity_writer.write(vel) != 0) {
            std::fprintf(stderr, "FAIL: Velocity write() failed at group=%d\n", group_id);
            return 1;
        }

        if (pub->end_coherent_changes() != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: end_coherent_changes() failed at group=%d\n", group_id);
            return 1;
        }
        std::printf("Publisher: wrote group %d\n", group_id);
    }

    std::printf("Publisher: done.\n");

    for (int waited_ms = 0;
         !(position_state.ever_matched.load() && position_state.matched_current_count.load() == 0 &&
           velocity_state.ever_matched.load() && velocity_state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    if (pub->delete_datawriter(position_dw) != ::DDS::RETCODE_OK ||
        pub->delete_datawriter(velocity_dw) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: delete_datawriter() did not return RETCODE_OK\n");
        return 1;
    }

    return 0;
}
