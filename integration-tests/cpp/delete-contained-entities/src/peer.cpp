/*
 * integration-tests/cpp/delete-contained-entities -- peer. Direct C++ port
 * of c/delete-contained-entities/src/peer.c -- see that file's header
 * comment for the full scenario rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create writer for topic:",
 * "Create reader for topic:" x2, "Peer: session disconnected cleanly."
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "session_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <vector>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 5;
constexpr int RECEIVE_TARGET = 2;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int RECEIVE_TIMEOUT_MS = 20000;
constexpr int DISCONNECT_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

struct MatchState {
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
    std::atomic<bool> reader_ready{false};
};

class WriterListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit WriterListener(MatchState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
    }

private:
    MatchState *state_;
};

class ReaderListener : public ::DDS::DataReaderListenerBase {
public:
    explicit ReaderListener(MatchState *state) : state_(state) {}

    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> /*reader*/,
                                  ::DDS::SubscriptionMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
    }

private:
    MatchState *state_;
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

    if (SessionEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register SessionEventTypeSupport failed\n");
        return 1;
    }

    auto out1_topic = dp->create_topic("SessionOut1", "SessionEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto out2_topic = dp->create_topic("SessionOut2", "SessionEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    auto in_topic = dp->create_topic("SessionIn", "SessionEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!out1_topic || !out2_topic || !in_topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: SessionOut1\n");
    std::printf("Create topic: SessionOut2\n");
    std::printf("Create topic: SessionIn\n");

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!pub || !sub) {
        std::fprintf(stderr, "FAIL: create_publisher/create_subscriber failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto in_dw = pub->create_datawriter(in_topic, dw_qos, nullptr, 0);
    if (!in_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(SessionIn) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: SessionIn\n");

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto zout1_topic = std::static_pointer_cast<::zzdds::TopicImpl>(out1_topic);
    auto out1_desc = zout1_topic->as_topic_description();
    auto out1_dr = sub->create_datareader(out1_desc, dr_qos, nullptr, 0);
    if (!out1_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(SessionOut1) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SessionOut1\n");

    auto zout2_topic = std::static_pointer_cast<::zzdds::TopicImpl>(out2_topic);
    auto out2_desc = zout2_topic->as_topic_description();
    auto out2_dr = sub->create_datareader(out2_desc, dr_qos, nullptr, 0);
    if (!out2_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(SessionOut2) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SessionOut2\n");

    MatchState writer_state, out1_state, out2_state;
    auto writer_listener = std::make_shared<WriterListener>(&writer_state);
    auto zin_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(in_dw);
    if (zin_dw->set_listener_ex(writer_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex (writer) failed\n");
        return 1;
    }
    auto out1_listener = std::make_shared<ReaderListener>(&out1_state);
    auto out2_listener = std::make_shared<ReaderListener>(&out2_state);
    if (out1_dr->set_listener(out1_listener, DDS_SUBSCRIPTION_MATCHED_STATUS) != ::DDS::RETCODE_OK ||
        out2_dr->set_listener(out2_listener, DDS_SUBSCRIPTION_MATCHED_STATUS) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: set_listener (reader) failed\n");
        return 1;
    }

    SessionEventDataWriter in_writer(in_dw->native_handle());
    SessionEventDataReader out1_reader(out1_dr->native_handle());
    SessionEventDataReader out2_reader(out2_dr->native_handle());

    // Gate on the session's reader actually being registered, not just
    // matched -- see session.cpp's matching comment for why.
    for (int waited_ms = 0; !writer_state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::SessionEvent ev;
        ev.seq = seq;
        if (in_writer.write(ev) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    std::printf("Peer: wrote %d samples on SessionIn\n", SAMPLE_COUNT);

    int received1 = 0, received2 = 0;
    for (int waited_ms = 0; received1 < RECEIVE_TARGET || received2 < RECEIVE_TARGET; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: peer did not receive from session within %ds (out1=%d out2=%d)\n",
                          RECEIVE_TIMEOUT_MS / 1000, received1, received2);
            return 1;
        }
        std::vector<::SessionEvent> values(SAMPLE_COUNT);
        std::vector<DDS_SampleInfo> infos(SAMPLE_COUNT);
        int n1 = out1_reader.take_n(values.data(), infos.data(), SAMPLE_COUNT,
                                     ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
        for (int i = 0; i < n1; i++) {
            if (infos[i].valid_data) received1++;
        }
        int n2 = out2_reader.take_n(values.data(), infos.data(), SAMPLE_COUNT,
                                     ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
        for (int i = 0; i < n2; i++) {
            if (infos[i].valid_data) received2++;
        }
        if (received1 < RECEIVE_TARGET || received2 < RECEIVE_TARGET) usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Peer: received from session (out1=%d out2=%d).\n", received1, received2);

    for (int waited_ms = 0;
         !(writer_state.ever_matched.load() && writer_state.matched_current_count.load() == 0 &&
           out1_state.ever_matched.load() && out1_state.matched_current_count.load() == 0 &&
           out2_state.ever_matched.load() && out2_state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= DISCONNECT_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: peer never saw a clean disconnect within %ds\n", DISCONNECT_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Peer: session disconnected cleanly.\n");

    dp->delete_contained_entities();
    factory->delete_participant(dp);
    return 0;
}
