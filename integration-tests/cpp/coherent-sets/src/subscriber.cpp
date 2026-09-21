/*
 * integration-tests/cpp/coherent-sets -- subscriber. Direct C++ port of
 * c/coherent-sets/src/subscriber.c -- see that file's header comment for
 * the full atomicity-assertion rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create reader for topic:"
 * x2, "Subscriber: group N paired (position+velocity).", "Subscriber:
 * received all 20 groups, atomic and ordered." Any failure path prints a
 * line starting "FAIL:" and exits nonzero.
 */
#include "pose_group.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>

namespace {

constexpr int GROUP_COUNT = 20;
constexpr ::DDS::Duration_t WAIT_STEP{1, 0};
constexpr int OVERALL_DEADLINE_MS = 30000;

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

    auto sub_qos = ::DDS::SubscriberQos::default_value();
    sub_qos.presentation.access_scope = ::DDS::PresentationQosPolicyAccessScopeKind::GROUP_PRESENTATION_QOS;
    sub_qos.presentation.coherent_access = true;
    sub_qos.presentation.ordered_access = true;

    auto sub = dp->create_subscriber(sub_qos, nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    // See cpp/waitset/src/subscriber.cpp's matching comment: create_topic()
    // constructs zzdds::detail::TopicSupport under the hood, so this upcast
    // is real.
    auto zposition_topic = std::static_pointer_cast<::zzdds::TopicImpl>(position_topic);
    auto position_desc = zposition_topic->as_topic_description();
    auto position_dr = sub->create_datareader(position_desc, dr_qos, nullptr, 0);
    if (!position_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(Position) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: Position\n");

    auto zvelocity_topic = std::static_pointer_cast<::zzdds::TopicImpl>(velocity_topic);
    auto velocity_desc = zvelocity_topic->as_topic_description();
    auto velocity_dr = sub->create_datareader(velocity_desc, dr_qos, nullptr, 0);
    if (!velocity_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(Velocity) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: Velocity\n");

    PositionDataReader position_reader(position_dr->native_handle());
    VelocityDataReader velocity_reader(velocity_dr->native_handle());

    auto ws = zzdds::create_waitset();
    if (!ws) {
        std::fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }

    auto position_rc = position_dr->create_readcondition(::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
    auto velocity_rc = velocity_dr->create_readcondition(::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
    if (!position_rc || !velocity_rc) {
        std::fprintf(stderr, "FAIL: create_readcondition() failed\n");
        return 1;
    }
    if (ws->attach_condition(position_rc) != ::DDS::RETCODE_OK ||
        ws->attach_condition(velocity_rc) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: attach_condition() failed\n");
        return 1;
    }

    std::vector<int> position_order, velocity_order;
    position_order.reserve(GROUP_COUNT);
    velocity_order.reserve(GROUP_COUNT);

    int overall_waited_ms = 0;
    while (static_cast<int>(position_order.size()) < GROUP_COUNT || static_cast<int>(velocity_order.size()) < GROUP_COUNT) {
        if (overall_waited_ms >= OVERALL_DEADLINE_MS) {
            std::fprintf(stderr, "FAIL: only received position=%zu velocity=%zu/%d within %ds\n",
                          position_order.size(), velocity_order.size(), GROUP_COUNT, OVERALL_DEADLINE_MS / 1000);
            return 1;
        }

        ::DDS::ConditionSeq active;
        auto wr = ws->wait(active, WAIT_STEP);
        if (wr == ::DDS::RETCODE_TIMEOUT) {
            overall_waited_ms += 1000;
            continue;
        }
        if (wr != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", static_cast<int>(wr));
            return 1;
        }

        if (sub->begin_access() != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: begin_access() failed\n");
            return 1;
        }

        std::vector<::Position> position_values(GROUP_COUNT);
        std::vector<DDS_SampleInfo> position_infos(GROUP_COUNT);
        int n_pos_taken = position_reader.take_n(position_values.data(), position_infos.data(), GROUP_COUNT,
                                                  ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
        for (int i = 0; i < n_pos_taken; i++) {
            if (!position_infos[i].valid_data) continue;
            position_order.push_back(position_values[i].group_id);
        }

        std::vector<::Velocity> velocity_values(GROUP_COUNT);
        std::vector<DDS_SampleInfo> velocity_infos(GROUP_COUNT);
        int n_vel_taken = velocity_reader.take_n(velocity_values.data(), velocity_infos.data(), GROUP_COUNT,
                                                  ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
        for (int i = 0; i < n_vel_taken; i++) {
            if (!velocity_infos[i].valid_data) continue;
            velocity_order.push_back(velocity_values[i].group_id);
        }

        if (sub->end_access() != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: end_access() failed\n");
            return 1;
        }

        // The core atomicity assertion -- see c/coherent-sets/src/subscriber.c's header comment.
        if (position_order.size() != velocity_order.size()) {
            std::fprintf(stderr,
                          "FAIL: atomicity violated -- position and velocity readers diverged after an access bracket "
                          "(position count=%zu velocity count=%zu) -- a group became visible on one reader without its pair\n",
                          position_order.size(), velocity_order.size());
            return 1;
        }
        for (size_t i = 0; i < position_order.size(); i++) {
            if (position_order[i] != velocity_order[i]) {
                std::fprintf(stderr, "FAIL: atomicity violated at index %zu -- position group_id=%d but velocity group_id=%d\n",
                              i, position_order[i], velocity_order[i]);
                return 1;
            }
        }
        if (!position_order.empty()) {
            std::printf("Subscriber: group %d paired (position+velocity).\n", position_order.back());
        }
    }

    for (int i = 0; i < GROUP_COUNT; i++) {
        if (position_order[i] != i || velocity_order[i] != i) {
            std::fprintf(stderr, "FAIL: ordered_access violated at index %d -- expected group_id=%d, got position=%d velocity=%d\n",
                          i, i, position_order[i], velocity_order[i]);
            return 1;
        }
    }

    std::printf("Subscriber: received all %d groups, atomic and ordered.\n", GROUP_COUNT);

    ws->detach_condition(position_rc);
    ws->detach_condition(velocity_rc);
    position_dr->delete_readcondition(position_rc);
    velocity_dr->delete_readcondition(velocity_rc);
    sub->delete_datareader(position_dr);
    sub->delete_datareader(velocity_dr);

    return 0;
}
