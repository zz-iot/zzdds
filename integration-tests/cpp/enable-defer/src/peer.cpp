/*
 * integration-tests/cpp/enable-defer -- peer. Direct C++ port of
 * c/enable-defer/src/peer.c -- see that file's header comment for the full
 * scenario rationale and docs/design/integration-test-tier.md for the
 * scenario spec.
 *
 * Required stdout markers: "Create topic: ConfigTopic", "Create reader for
 * topic: ConfigTopic", "Peer: no premature match during Ns window.", "Peer:
 * no premature match; matched and received cleanly after enable()." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h>

namespace {

constexpr int SAMPLE_TARGET = 5;
constexpr int PREMATURE_CHECK_WINDOW_SEC = 3;
constexpr int MATCH_TIMEOUT_MS = 30000;
constexpr int RECEIVE_TIMEOUT_MS = 20000;
constexpr int POLL_PERIOD_MS = 20;

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

    if (ConfigEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register ConfigEventTypeSupport failed\n");
        return 1;
    }

    auto topic = dp->create_topic("ConfigTopic", "ConfigEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic(ConfigTopic) failed\n");
        return 1;
    }
    std::printf("Create topic: ConfigTopic\n");

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(desc, dr_qos, nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader(ConfigTopic) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: ConfigTopic\n");

    ConfigEventDataReader reader(dr->native_handle());

    // Core assertion: for a window comfortably inside the configurer's own
    // pre-enable delay, matched-current-count must stay exactly 0 -- direct
    // proof the deferred SEDP announcement genuinely never went out while
    // the configurer's writer was disabled.
    ::DDS::SubscriptionMatchedStatus status;
    for (int waited_ms = 0; waited_ms < PREMATURE_CHECK_WINDOW_SEC * 1000; waited_ms += POLL_PERIOD_MS) {
        if (dr->get_subscription_matched_status(status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_subscription_matched_status() failed\n");
            return 1;
        }
        if (status.current_count != 0) {
            std::fprintf(stderr, "FAIL: matched before enable() was called -- deferred SEDP announcement isn't working (current_count=%d)\n", status.current_count);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Peer: no premature match during %ds window.\n", PREMATURE_CHECK_WINDOW_SEC);

    // Now wait normally for the real match, once the configurer enables.
    bool matched = false;
    for (int waited_ms = 0; !matched; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: never matched within %ds of the premature-match window ending\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        if (dr->get_subscription_matched_status(status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_subscription_matched_status() failed\n");
            return 1;
        }
        if (status.current_count > 0) {
            matched = true;
        } else {
            usleep(POLL_PERIOD_MS * 1000);
        }
    }

    int received = 0;
    int32_t last_seq = -1;
    std::vector<::ConfigEvent> values(SAMPLE_TARGET);
    std::vector<DDS_SampleInfo> infos(SAMPLE_TARGET);
    for (int waited_ms = 0; received < SAMPLE_TARGET; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: did not receive all %d samples within %ds (got %d)\n", SAMPLE_TARGET, RECEIVE_TIMEOUT_MS / 1000, received);
            return 1;
        }
        int n = reader.take_n(values.data(), infos.data(), SAMPLE_TARGET,
                               ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
        for (int i = 0; i < n; i++) {
            if (!infos[i].valid_data) continue;
            if (values[i].seq != last_seq + 1) {
                std::fprintf(stderr, "FAIL: out-of-order sample, expected seq=%d got seq=%d\n", last_seq + 1, values[i].seq);
                return 1;
            }
            last_seq = values[i].seq;
            received++;
        }
        if (received < SAMPLE_TARGET) usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Peer: no premature match; matched and received cleanly after enable().\n");
    factory->delete_participant(dp);
    return 0;
}
