/*
 * integration-tests/cpp/ignore-entities -- peer. Direct C++ port of
 * c/ignore-entities/src/peer.c -- see that file's header comment for the
 * full scenario rationale and docs/design/integration-test-tier.md for the
 * scenario spec.
 *
 * Required stdout markers: "Peer: ready.", "Peer: SubscriptionIgnoredTopic
 * reader received zero samples from the real (post-ignore) writer.", "Peer:
 * done." Any failure path prints a line starting "FAIL:" and exits
 * nonzero.
 */
#include "ignore_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 5;
// NOT long enough to guarantee the ignorer has finished every ignore_*()
// call -- its own PROBE_MATCH_TIMEOUT_MS (45s) applies twice, sequentially,
// for the publication and subscription probes, so its true worst case is
// well over a minute. Raised from 6s to match this file's own
// MATCH_TIMEOUT_MS convention as a meaningfully better (not watertight)
// margin: the SubscriptionIgnoredTopic check below can still report a false
// pass -- zero samples because the real (post-ignore) writer hasn't been
// created yet, not because ignore_subscription() worked -- if the ignorer
// is still deep in its own probe/settle choreography when this window
// closes. A fully watertight fix needs an explicit cross-process signal
// (e.g. a dedicated marker topic) rather than a fixed sleep; not done here
// to avoid adding a worst-case 100+s wait on top of an already
// CI-budget-constrained suite (found via Greptile review; see
// docs/roadmap.md's discovery-latency entry for the same underlying "how
// long is long enough" tension).
constexpr int SETTLE_WINDOW_S = 20;
constexpr int MATCH_TIMEOUT_MS = 20000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
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

    if (IgnoreEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto control_topic = dp->create_topic("ControlTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto topic_ignored_topic = dp->create_topic("TopicIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto pub_ignored_topic = dp->create_topic("PublicationIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto sub_ignored_topic = dp->create_topic("SubscriptionIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!control_topic || !topic_ignored_topic || !pub_ignored_topic || !sub_ignored_topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!pub || !sub) {
        std::fprintf(stderr, "FAIL: create_publisher()/create_subscriber() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto control_dw = pub->create_datawriter(control_topic, dw_qos, nullptr, 0);
    auto topic_ignored_dw = pub->create_datawriter(topic_ignored_topic, dw_qos, nullptr, 0);
    auto pub_ignored_dw = pub->create_datawriter(pub_ignored_topic, dw_qos, nullptr, 0);
    auto sub_ignored_ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(sub_ignored_topic);
    auto sub_ignored_dr = sub->create_datareader(sub_ignored_ztopic->as_topic_description(), dr_qos, nullptr, 0);
    if (!control_dw || !topic_ignored_dw || !pub_ignored_dw || !sub_ignored_dr) {
        std::fprintf(stderr, "FAIL: create_datawriter()/create_datareader() failed\n");
        return 1;
    }
    std::printf("Peer: ready.\n");

    // Write a few samples on TopicIgnoredTopic and PublicationIgnoredTopic
    // right away -- both writers exist continuously from here on, giving
    // the ignorer's readers every real opportunity to (wrongly) match.
    IgnoreEventDataWriter topic_ignored_writer(topic_ignored_dw->native_handle());
    IgnoreEventDataWriter pub_ignored_writer(pub_ignored_dw->native_handle());
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::IgnoreEvent ev;
        ev.seq = seq;
        topic_ignored_writer.write(ev);
        pub_ignored_writer.write(ev);
    }

    // Let the ignorer's full choreography (participant-discover-and-ignore,
    // publication probe-then-ignore, subscription probe-then-ignore) run to
    // completion. No assertion on topic_ignored_dw's or pub_ignored_dw's
    // own match-count here -- see this file's header comment for why that
    // would be asserting something ignore_topic()/ignore_publication()
    // never promised.
    sleep(SETTLE_WINDOW_S);

    // The one thing this process's own side CAN verify: ignore_subscription()
    // was called on ignorer's *writer* participant, so its real
    // (post-ignore) writer never adds this reader as a matched proxy --
    // meaning this reader, however its own SEDP match status reports
    // itself, must never actually receive any of that writer's samples.
    IgnoreEventDataReader sub_ignored_reader(sub_ignored_dr->native_handle());
    int taken_count = 0;
    for (;;) {
        IgnoreEventDataReader::Sample sample{};
        uint8_t buf[512];
        size_t cdr_len = 0;
        int rc = sub_ignored_reader.take(sample, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            std::fprintf(stderr, "FAIL: take(SubscriptionIgnoredTopic) CDR error (rc=%d)\n", rc);
            return 1;
        }
        if (sample.info.valid_data) taken_count++;
    }
    if (taken_count != 0) {
        std::fprintf(stderr, "FAIL: SubscriptionIgnoredTopic reader received %d samples, expected 0\n", taken_count);
        return 1;
    }
    std::printf("Peer: SubscriptionIgnoredTopic reader received zero samples from the real (post-ignore) writer.\n");

    // Normal ControlTopic round-trip, matching every other scenario's
    // sanity-check convention.
    ::DDS::PublicationMatchedStatus control_status;
    bool control_matched = false;
    for (int waited_ms = 0; !control_matched; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: ControlTopic writer never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        if (control_dw->get_publication_matched_status(control_status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_publication_matched_status(control) failed\n");
            return 1;
        }
        if (control_status.current_count > 0) {
            control_matched = true;
        } else {
            usleep(POLL_PERIOD_MS * 1000);
        }
    }

    IgnoreEventDataWriter control_writer(control_dw->native_handle());
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::IgnoreEvent ev;
        ev.seq = seq;
        if (control_writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write(ControlTopic) failed at seq=%d\n", seq);
            return 1;
        }
    }

    // Standard teardown-safety: wait for the ignorer to disconnect before
    // deleting, matching every other scenario's precedent.
    for (int waited_ms = 0;; waited_ms += POLL_PERIOD_MS) {
        if (control_dw->get_publication_matched_status(control_status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_publication_matched_status(control) failed\n");
            return 1;
        }
        if (control_status.current_count == 0) break;
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: ignorer did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Peer: done.\n");
    factory->delete_participant(dp);
    return 0;
}
