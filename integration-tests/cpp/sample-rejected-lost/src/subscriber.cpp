/*
 * integration-tests/cpp/sample-rejected-lost -- subscriber. Direct C++ port
 * of c/sample-rejected-lost/src/subscriber.c -- see that file's header
 * comment for the full scenario rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create reader for topic:"
 * x3, "Subscriber: sample_rejected confirmed (count=N, buffered=M).",
 * "Subscriber: sample_lost confirmed (count=N, last seq=N).", "Subscriber:
 * SAMPLE_REJECTED/SAMPLE_LOST both verified." Any failure path prints a
 * line starting "FAIL:" and exits nonzero.
 */
#include "status_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h>

namespace {

constexpr int SYNC_TIMEOUT_MS = 20000;
constexpr int STATUS_TIMEOUT_MS = 20000;
constexpr int POLL_PERIOD_MS = 20;
constexpr int MAX_SAMPLES = 8;

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

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto rejected_qos = ::DDS::DataReaderQos::default_value();
    rejected_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    rejected_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    rejected_qos.resource_limits.max_samples = 3;
    rejected_qos.resource_limits.max_instances = 1;
    rejected_qos.resource_limits.max_samples_per_instance = 3;
    auto zrejected_topic = std::static_pointer_cast<::zzdds::TopicImpl>(rejected_topic);
    auto rejected_dr = sub->create_datareader(zrejected_topic->as_topic_description(), rejected_qos, nullptr, 0);
    if (!rejected_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(RejectedTopic) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: RejectedTopic\n");

    auto sync_qos = ::DDS::DataReaderQos::default_value();
    sync_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    auto zsync_topic = std::static_pointer_cast<::zzdds::TopicImpl>(sync_topic);
    auto sync_dr = sub->create_datareader(zsync_topic->as_topic_description(), sync_qos, nullptr, 0);
    if (!sync_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(SyncTopic) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SyncTopic\n");

    ::StatusEventDataReader rejected_reader(rejected_dr->native_handle());
    ::StatusEventDataReader sync_reader(sync_dr->native_handle());

    std::vector<::StatusEvent> values(MAX_SAMPLES);
    std::vector<DDS_SampleInfo> infos(MAX_SAMPLES);

    // Gate: don't create the LostTopic reader, or check RejectedTopic's
    // final status, until the publisher has genuinely finished writing
    // everything (it writes Sync last).
    {
        bool got_sync = false;
        for (int waited_ms = 0; !got_sync; waited_ms += POLL_PERIOD_MS) {
            if (waited_ms >= SYNC_TIMEOUT_MS) {
                std::fprintf(stderr, "FAIL: sync sample never arrived within %ds\n", SYNC_TIMEOUT_MS / 1000);
                return 1;
            }
            int n = sync_reader.take_n(values.data(), infos.data(), MAX_SAMPLES,
                                        ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
            if (n > 0) got_sync = true;
            else usleep(POLL_PERIOD_MS * 1000);
        }
    }

    auto lost_qos = ::DDS::DataReaderQos::default_value();
    lost_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    lost_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_LAST_HISTORY_QOS;
    lost_qos.history.depth = 1;
    lost_qos.durability.kind = ::DDS::DurabilityQosPolicyKind::TRANSIENT_LOCAL_DURABILITY_QOS;
    auto zlost_topic = std::static_pointer_cast<::zzdds::TopicImpl>(lost_topic);
    auto lost_dr = sub->create_datareader(zlost_topic->as_topic_description(), lost_qos, nullptr, 0);
    if (!lost_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(LostTopic) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: LostTopic\n");
    ::StatusEventDataReader lost_reader(lost_dr->native_handle());

    // RejectedTopic: deliberately never drained until now. Confirm
    // rejection happened, then take whatever made it through.
    ::DDS::SampleRejectedStatus rejected_status;
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (rejected_dr->get_sample_rejected_status(rejected_status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_sample_rejected_status() failed\n");
            return 1;
        }
        if (rejected_status.total_count > 0) break;
        if (waited_ms >= STATUS_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no sample ever rejected on RejectedTopic within %ds\n", STATUS_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    int rejected_buffered = rejected_reader.take_n(values.data(), infos.data(), MAX_SAMPLES,
                                                    ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
    // Count-conservation invariant, not a hardcoded exact split -- see
    // docs/decisions.md's dds-rtps CoherentSets flake history for why this
    // project avoids asserting exact counts where a property suffices.
    int rejected_total = rejected_status.total_count + rejected_buffered;
    if (rejected_total != 5) {
        std::fprintf(stderr, "FAIL: RejectedTopic count mismatch -- rejected=%d buffered=%d total=%d, expected 5\n",
                      rejected_status.total_count, rejected_buffered, rejected_total);
        return 1;
    }
    if (rejected_buffered == 0) {
        std::fprintf(stderr, "FAIL: RejectedTopic: nothing was ever successfully buffered (rejected everything)\n");
        return 1;
    }
    std::printf("Subscriber: sample_rejected confirmed (count=%d, buffered=%d).\n", rejected_status.total_count, rejected_buffered);

    // LostTopic: confirm loss happened, then take whatever remains and
    // confirm the writer's LAST value survived.
    ::DDS::SampleLostStatus lost_status;
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (lost_dr->get_sample_lost_status(lost_status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_sample_lost_status() failed\n");
            return 1;
        }
        if (lost_status.total_count > 0) break;
        if (waited_ms >= STATUS_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no sample ever lost on LostTopic within %ds\n", STATUS_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    int lost_n = lost_reader.take_n(values.data(), infos.data(), MAX_SAMPLES,
                                     ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
    int max_seq = -1;
    for (int i = 0; i < lost_n; i++) {
        if (infos[i].valid_data && values[i].seq > max_seq) max_seq = values[i].seq;
    }
    if (max_seq != 4) {
        std::fprintf(stderr, "FAIL: LostTopic did not deliver the writer's last sample (seq=4) -- last seen=%d\n", max_seq);
        return 1;
    }
    std::printf("Subscriber: sample_lost confirmed (count=%d, last seq=%d).\n", lost_status.total_count, max_seq);

    std::printf("Subscriber: SAMPLE_REJECTED/SAMPLE_LOST both verified.\n");

    return 0;
}
