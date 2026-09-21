/*
 * integration-tests/cpp/delete-contained-entities -- session. Direct C++
 * port of c/delete-contained-entities/src/session.c -- see that file's
 * header comment for the full scenario rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create writer for topic:"
 * x2, "Create reader for topic:" x2, "Session: torn down via
 * delete_contained_entities." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
 */
#include "session_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 5;
constexpr int RECEIVE_TARGET = 2;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int RECEIVE_TIMEOUT_MS = 20000;
constexpr ::DDS::Duration_t WAIT_STEP{1, 0};
constexpr int POLL_PERIOD_MS = 20;

std::atomic<bool> torn_down{false};

struct WriterSyncState {
    std::atomic<bool> reader_ready{false};
};

class WriterListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit WriterListener(WriterSyncState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus /*status*/) override {
        if (torn_down.load()) {
            std::fprintf(stderr, "FAIL: listener fired after delete_contained_entities\n");
            std::exit(1);
        }
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
    }

private:
    WriterSyncState *state_;
};

class ReaderListener : public ::DDS::DataReaderListenerBase {
public:
    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> /*reader*/,
                                  ::DDS::SubscriptionMatchedStatus /*status*/) override {
        if (torn_down.load()) {
            std::fprintf(stderr, "FAIL: listener fired after delete_contained_entities\n");
            std::exit(1);
        }
    }
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
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto out1_dw = pub->create_datawriter(out1_topic, dw_qos, nullptr, 0);
    auto out2_dw = pub->create_datawriter(out2_topic, dw_qos, nullptr, 0);
    if (!out1_dw || !out2_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: SessionOut1\n");
    std::printf("Create writer for topic: SessionOut2\n");

    WriterSyncState out1_state, out2_state;
    auto out1_listener = std::make_shared<WriterListener>(&out1_state);
    auto out2_listener = std::make_shared<WriterListener>(&out2_state);
    auto zout1_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(out1_dw);
    auto zout2_dw = std::static_pointer_cast<::zzdds::DataWriterImpl>(out2_dw);
    if (zout1_dw->set_listener_ex(out1_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK ||
        zout2_dw->set_listener_ex(out2_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: set_listener_ex (writer) failed\n");
        return 1;
    }

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto zin_topic = std::static_pointer_cast<::zzdds::TopicImpl>(in_topic);
    auto in_desc = zin_topic->as_topic_description();
    auto in_dr = sub->create_datareader(in_desc, dr_qos, nullptr, 0);
    if (!in_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(SessionIn) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SessionIn\n");

    // Exercise CFT-collateral cleanup under the cascade -- this project has
    // a real CFT bug history (see docs/decisions.md). Trivial filter: just
    // needs to exist and be attached, not to actually narrow anything.
    auto cft = dp->create_contentfilteredtopic("SessionIn_cft", in_topic, "seq >= 0", {});
    if (!cft) {
        std::fprintf(stderr, "FAIL: create_contentfilteredtopic() failed\n");
        return 1;
    }
    auto cft_dr = sub->create_datareader(cft, dr_qos, nullptr, 0);
    if (!cft_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(SessionIn_cft) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SessionIn_cft\n");

    auto reader_listener = std::make_shared<ReaderListener>();
    if (in_dr->set_listener(reader_listener, DDS_SUBSCRIPTION_MATCHED_STATUS) != ::DDS::RETCODE_OK ||
        cft_dr->set_listener(reader_listener, DDS_SUBSCRIPTION_MATCHED_STATUS) != ::DDS::RETCODE_OK)
    {
        std::fprintf(stderr, "FAIL: set_listener (reader) failed\n");
        return 1;
    }

    auto ws = zzdds::create_waitset();
    if (!ws) {
        std::fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }
    auto in_rc = in_dr->create_readcondition(::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
    if (!in_rc) {
        std::fprintf(stderr, "FAIL: create_readcondition() failed\n");
        return 1;
    }
    if (ws->attach_condition(in_rc) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: attach_condition() failed\n");
        return 1;
    }

    SessionEventDataWriter out1_writer(out1_dw->native_handle());
    SessionEventDataWriter out2_writer(out2_dw->native_handle());
    SessionEventDataReader in_reader(in_dr->native_handle());

    // Gate writes on the peer's reader actually being registered, not just
    // matched -- see docs/design/integration-test-tier.md's raw-loan/
    // coherent-sets precedent and this project's on_reliable_reader_ready
    // work: matched-count alone (SEDP discovery) does not imply the remote
    // RELIABLE reader proxy has registered this writer yet.
    for (int waited_ms = 0; !(out1_state.reader_ready.load() && out2_state.reader_ready.load()); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::SessionEvent ev;
        ev.seq = seq;
        if (out1_writer.write(ev) != 0 || out2_writer.write(ev) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    std::printf("Session: wrote %d samples on SessionOut1/SessionOut2\n", SAMPLE_COUNT);

    int received = 0;
    int waited_ms = 0;
    while (received < RECEIVE_TARGET) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: session did not receive from peer within %ds (got %d)\n", RECEIVE_TIMEOUT_MS / 1000, received);
            return 1;
        }
        ::DDS::ConditionSeq active;
        auto wr = ws->wait(active, WAIT_STEP);
        if (wr == ::DDS::RETCODE_TIMEOUT) {
            waited_ms += 1000;
            continue;
        }
        if (wr != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", static_cast<int>(wr));
            return 1;
        }
        std::vector<::SessionEvent> values(SAMPLE_COUNT);
        std::vector<DDS_SampleInfo> infos(SAMPLE_COUNT);
        int n = in_reader.take_n(values.data(), infos.data(), SAMPLE_COUNT,
                                  ::DDS::ANY_SAMPLE_STATE, ::DDS::ANY_VIEW_STATE, ::DDS::ANY_INSTANCE_STATE);
        for (int i = 0; i < n; i++) {
            if (infos[i].valid_data) received++;
        }
    }
    std::printf("Session: received %d samples from peer.\n", received);

    // The core test: tear the whole tree down in one shot instead of
    // deleting out1_dw/out2_dw/in_dr/cft_dr/cft one at a time.
    torn_down.store(true);

    auto rc1 = dp->delete_contained_entities();
    if (rc1 != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: delete_contained_entities() returned %d, expected RETCODE_OK\n", static_cast<int>(rc1));
        return 1;
    }

    auto rc2 = factory->delete_participant(dp);
    if (rc2 != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: delete_participant() returned %d after delete_contained_entities -- "
                              "cascade left something dangling\n", static_cast<int>(rc2));
        return 1;
    }

    std::printf("Session: torn down via delete_contained_entities.\n");
    return 0;
}
