/*
 * integration-tests/cpp/ignore-entities -- ignorer. Direct C++ port of
 * c/ignore-entities/src/ignorer.c -- see that file's header comment for
 * the full scenario rationale (why every assertion here lives on this side
 * of the wire) and docs/design/integration-test-tier.md for the scenario
 * spec.
 *
 * Required stdout markers: "Ignorer: ready for bystander.", "Ignorer:
 * ignore_participant() applied to bystander.", "Ignorer:
 * ignore_publication() applied via probe.", "Ignorer: ignore_subscription()
 * applied via probe.", "Ignorer: all ignore checks passed.", "Ignorer:
 * done." Any failure path prints a line starting "FAIL:" and exits
 * nonzero.
 */
#include "ignore_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 5;
constexpr int DISCOVER_BYSTANDER_TIMEOUT_MS = 15000;
// 45s, not the 20s every other match-wait in this tier uses -- this
// scenario's probe-match steps showed intermittent delays under this
// suite's own CI/dev sandbox load that 20s didn't reliably clear; see
// docs/roadmap.md.
constexpr int PROBE_MATCH_TIMEOUT_MS = 45000;
constexpr int SETTLE_WINDOW_S = 3;
constexpr int MATCH_TIMEOUT_MS = 20000;
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

    if (IgnoreEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto control_topic = dp->create_topic("ControlTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto topic_ignored_topic = dp->create_topic("TopicIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto pub_ignored_topic = dp->create_topic("PublicationIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto sub_ignored_topic = dp->create_topic("SubscriptionIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto participant_ignored_topic = dp->create_topic("ParticipantIgnoredTopic", "IgnoreEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!control_topic || !topic_ignored_topic || !pub_ignored_topic || !sub_ignored_topic || !participant_ignored_topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }

    // -- ignore_topic(): local knowledge only, no peer needed yet. --
    auto topic_ignored_handle = topic_ignored_topic->get_instance_handle();
    if (dp->ignore_topic(topic_ignored_handle) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: ignore_topic() failed\n");
        return 1;
    }
    std::printf("Ignorer: ignore_topic() applied to TopicIgnoredTopic.\n");
    std::fflush(stdout);

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!sub || !pub) {
        std::fprintf(stderr, "FAIL: create_subscriber()/create_publisher() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto topic_ignored_ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic_ignored_topic);
    auto participant_ignored_ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(participant_ignored_topic);
    auto control_ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(control_topic);
    auto pub_ignored_ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(pub_ignored_topic);

    // Reader created immediately after ignoring -- the writer it must never
    // match (peer's) doesn't exist yet at this point.
    auto topic_ignored_dr = sub->create_datareader(topic_ignored_ztopic->as_topic_description(), dr_qos, nullptr, 0);
    // Harmless to create now, before ignore_participant() below -- the
    // participant-level guard blocks at first discovery regardless of when
    // this reader was created (see this file's header comment).
    auto participant_ignored_dr = sub->create_datareader(participant_ignored_ztopic->as_topic_description(), dr_qos, nullptr, 0);
    auto control_dr = sub->create_datareader(control_ztopic->as_topic_description(), dr_qos, nullptr, 0);
    if (!topic_ignored_dr || !participant_ignored_dr || !control_dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }

    std::printf("Ignorer: ready for bystander.\n");
    std::fflush(stdout);

    // -- ignore_participant(): discover bystander's participant, ignore it
    // well within its own deliberate pre-writer delay. --
    bool found_bystander = false;
    for (int waited_ms = 0; !found_bystander; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DISCOVER_BYSTANDER_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: bystander's participant never appeared within %ds\n", DISCOVER_BYSTANDER_TIMEOUT_MS / 1000);
            return 1;
        }
        ::DDS::InstanceHandleSeq handles;
        dp->get_discovered_participants(handles);
        if (!handles.empty()) {
            auto rc = dp->ignore_participant(handles[0]);
            if (rc != ::DDS::RETCODE_OK) {
                std::fprintf(stderr, "FAIL: ignore_participant() returned %d\n", static_cast<int>(rc));
                return 1;
            }
            found_bystander = true;
        } else {
            usleep(POLL_PERIOD_MS * 1000);
        }
    }
    std::printf("Ignorer: ignore_participant() applied to bystander.\n");
    std::fflush(stdout);

    // -- ignore_publication(): probe, learn peer's writer handle, ignore,
    // then prove a freshly-created reader never matches it. --
    {
        auto probe_dr = sub->create_datareader(pub_ignored_ztopic->as_topic_description(), dr_qos, nullptr, 0);
        if (!probe_dr) {
            std::fprintf(stderr, "FAIL: create_datareader(probe, PublicationIgnoredTopic) failed\n");
            return 1;
        }
        ::DDS::SubscriptionMatchedStatus status;
        bool matched = false;
        for (int waited_ms = 0; !matched; waited_ms += POLL_PERIOD_MS) {
            if (waited_ms >= PROBE_MATCH_TIMEOUT_MS) {
                std::fprintf(stderr, "FAIL: probe reader never matched peer's PublicationIgnoredTopic writer within %ds\n", PROBE_MATCH_TIMEOUT_MS / 1000);
                return 1;
            }
            if (probe_dr->get_subscription_matched_status(status) != ::DDS::RETCODE_OK) {
                std::fprintf(stderr, "FAIL: get_subscription_matched_status(probe) failed\n");
                return 1;
            }
            if (status.current_count > 0) matched = true; else usleep(POLL_PERIOD_MS * 1000);
        }

        ::DDS::InstanceHandleSeq pub_handles;
        if (probe_dr->get_matched_publications(pub_handles) != ::DDS::RETCODE_OK || pub_handles.empty()) {
            std::fprintf(stderr, "FAIL: get_matched_publications(probe) returned no handles\n");
            return 1;
        }
        auto writer_handle = pub_handles[0];
        if (dp->ignore_publication(writer_handle) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: ignore_publication() failed\n");
            return 1;
        }
        sub->delete_datareader(probe_dr);
        std::printf("Ignorer: ignore_publication() applied via probe.\n");
        std::fflush(stdout);
    }
    auto pub_ignored_dr = sub->create_datareader(pub_ignored_ztopic->as_topic_description(), dr_qos, nullptr, 0);
    if (!pub_ignored_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(real, PublicationIgnoredTopic) failed\n");
        return 1;
    }

    // -- ignore_subscription(): probe, learn peer's reader handle, ignore,
    // then prove a freshly-created writer never matches it. --
    {
        auto probe_dw = pub->create_datawriter(sub_ignored_topic, dw_qos, nullptr, 0);
        if (!probe_dw) {
            std::fprintf(stderr, "FAIL: create_datawriter(probe, SubscriptionIgnoredTopic) failed\n");
            return 1;
        }
        ::DDS::PublicationMatchedStatus status;
        bool matched = false;
        for (int waited_ms = 0; !matched; waited_ms += POLL_PERIOD_MS) {
            if (waited_ms >= PROBE_MATCH_TIMEOUT_MS) {
                std::fprintf(stderr, "FAIL: probe writer never matched peer's SubscriptionIgnoredTopic reader within %ds\n", PROBE_MATCH_TIMEOUT_MS / 1000);
                return 1;
            }
            if (probe_dw->get_publication_matched_status(status) != ::DDS::RETCODE_OK) {
                std::fprintf(stderr, "FAIL: get_publication_matched_status(probe) failed\n");
                return 1;
            }
            if (status.current_count > 0) matched = true; else usleep(POLL_PERIOD_MS * 1000);
        }

        ::DDS::InstanceHandleSeq sub_handles;
        if (probe_dw->get_matched_subscriptions(sub_handles) != ::DDS::RETCODE_OK || sub_handles.empty()) {
            std::fprintf(stderr, "FAIL: get_matched_subscriptions(probe) returned no handles\n");
            return 1;
        }
        auto reader_handle = sub_handles[0];
        if (dp->ignore_subscription(reader_handle) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: ignore_subscription() failed\n");
            return 1;
        }
        pub->delete_datawriter(probe_dw);
        std::printf("Ignorer: ignore_subscription() applied via probe.\n");
        std::fflush(stdout);
    }
    auto sub_ignored_dw = pub->create_datawriter(sub_ignored_topic, dw_qos, nullptr, 0);
    if (!sub_ignored_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(real, SubscriptionIgnoredTopic) failed\n");
        return 1;
    }
    IgnoreEventDataWriter sub_ignored_writer(sub_ignored_dw->native_handle());
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::IgnoreEvent ev;
        ev.seq = seq;
        if (sub_ignored_writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write(SubscriptionIgnoredTopic) failed at seq=%d\n", seq);
            return 1;
        }
    }

    // Let everything settle: bystander's writer (created after its own
    // delay) gets a real chance to try (and fail) to announce; the
    // already-existing TopicIgnoredTopic writer gets a real chance to try
    // (and fail) to match the reader created above.
    sleep(SETTLE_WINDOW_S);

    ::DDS::SubscriptionMatchedStatus topic_status;
    if (topic_ignored_dr->get_subscription_matched_status(topic_status) != ::DDS::RETCODE_OK || topic_status.current_count != 0) {
        std::fprintf(stderr, "FAIL: TopicIgnoredTopic reader matched despite ignore_topic() (current_count=%d)\n", topic_status.current_count);
        return 1;
    }
    ::DDS::SubscriptionMatchedStatus participant_status;
    if (participant_ignored_dr->get_subscription_matched_status(participant_status) != ::DDS::RETCODE_OK || participant_status.current_count != 0) {
        std::fprintf(stderr, "FAIL: ParticipantIgnoredTopic reader matched despite ignore_participant() (current_count=%d)\n", participant_status.current_count);
        return 1;
    }
    ::DDS::SubscriptionMatchedStatus pub_status;
    if (pub_ignored_dr->get_subscription_matched_status(pub_status) != ::DDS::RETCODE_OK || pub_status.current_count != 0) {
        std::fprintf(stderr, "FAIL: PublicationIgnoredTopic reader matched despite ignore_publication() (current_count=%d)\n", pub_status.current_count);
        return 1;
    }

    // Confirm the real guarantee, not just the match-count field: peer's
    // writers for TopicIgnoredTopic and PublicationIgnoredTopic have been
    // writing continuously this whole time (see peer.cpp) and -- since
    // ignore_topic()/ignore_publication() are a strictly one-sided, local
    // filter (see this file's header comment) -- legitimately still
    // consider *themselves* matched from their own side. What must never
    // happen is this reader's own take() ever surfacing one of their
    // samples.
    IgnoreEventDataReader topic_ignored_reader(topic_ignored_dr->native_handle());
    IgnoreEventDataReader pub_ignored_reader(pub_ignored_dr->native_handle());
    for (int which = 0; which < 2; which++) {
        IgnoreEventDataReader &reader = which == 0 ? topic_ignored_reader : pub_ignored_reader;
        const char *label = which == 0 ? "TopicIgnoredTopic" : "PublicationIgnoredTopic";
        int taken_count = 0;
        for (;;) {
            IgnoreEventDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;
            int rc = reader.take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take(%s) CDR error (rc=%d)\n", label, rc);
                return 1;
            }
            if (sample.info.valid_data) taken_count++;
        }
        if (taken_count != 0) {
            std::fprintf(stderr, "FAIL: %s reader received %d samples, expected 0\n", label, taken_count);
            return 1;
        }
    }
    std::printf("Ignorer: all ignore checks passed.\n");
    std::fflush(stdout);

    // -- Control: prove the apparatus itself works -- an unignored reader
    // must match and receive normally. --
    ::DDS::SubscriptionMatchedStatus control_status;
    bool control_matched = false;
    for (int waited_ms = 0; !control_matched; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: ControlTopic reader never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        if (control_dr->get_subscription_matched_status(control_status) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: get_subscription_matched_status(control) failed\n");
            return 1;
        }
        if (control_status.current_count > 0) control_matched = true; else usleep(POLL_PERIOD_MS * 1000);
    }

    IgnoreEventDataReader control_reader(control_dr->native_handle());
    int received = 0;
    int32_t last_seq = -1;
    for (int waited_ms = 0; received < SAMPLE_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: ControlTopic did not receive all %d samples within %ds (got %d)\n", SAMPLE_COUNT, RECEIVE_TIMEOUT_MS / 1000, received);
            return 1;
        }
        IgnoreEventDataReader::Sample sample{};
        uint8_t buf[512];
        size_t cdr_len = 0;
        int rc = control_reader.take(sample, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_OK && sample.info.valid_data) {
            if (sample.value.seq != last_seq + 1) {
                std::fprintf(stderr, "FAIL: ControlTopic out-of-order sample, expected seq=%d got seq=%d\n", last_seq + 1, sample.value.seq);
                return 1;
            }
            last_seq = sample.value.seq;
            received++;
            continue;
        }
        if (rc != DDS_RETCODE_OK && rc != DDS_RETCODE_NO_DATA) {
            std::fprintf(stderr, "FAIL: take(ControlTopic) CDR error (rc=%d)\n", rc);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Ignorer: ControlTopic received all %d samples.\n", SAMPLE_COUNT);
    std::fflush(stdout);

    // Standard teardown-safety: waiting for peer's ControlTopic writer to
    // observe us disconnect isn't this side's job -- peer waits on its own
    // matched-count-to-zero after we delete_participant() (see peer.cpp).
    std::printf("Ignorer: done.\n");
    std::fflush(stdout);
    factory->delete_participant(dp);
    return 0;
}
