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
#ifdef _WIN32
/* No <unistd.h> on Windows: the usleep()/sleep() this file uses, on Sleep(). */
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
static inline void usleep(unsigned long us) { Sleep((DWORD)(us / 1000)); }
static inline void sleep(unsigned s) { Sleep((DWORD)s * 1000); }
#else
#include <unistd.h>
#endif

namespace {

constexpr int SAMPLE_COUNT = 5;
constexpr int RECEIVE_TARGET = 2;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int RECEIVE_TIMEOUT_MS = 20000;
constexpr ::DDS::Duration_t WAIT_STEP{1, 0};
constexpr int POLL_PERIOD_MS = 20;

enum Phase : int { PHASE_RUNNING, PHASE_DELETING, PHASE_DELETED };
std::atomic<int> phase{PHASE_RUNNING};

void fail_if_torn_down(const char *callback, const char *topic, int32_t total_count, int32_t total_count_change,
                       int32_t current_count, int32_t current_count_change) {
    int p = phase.load();
    if (p == PHASE_RUNNING) return;
    std::fprintf(stderr,
                 "FAIL: listener fired %s delete_contained_entities: %s on %s "
                 "(total_count=%d total_count_change=%d current_count=%d current_count_change=%d)\n",
                 p == PHASE_DELETING ? "during" : "after", callback, topic, total_count, total_count_change,
                 current_count, current_count_change);
    std::exit(1);
}

struct WriterSyncState {
    std::atomic<bool> reader_ready{false};
};

class WriterListener : public ::zzdds::DataWriterListenerExBase {
public:
    WriterListener(WriterSyncState *state, const char *topic) : state_(state), topic_(topic) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        fail_if_torn_down("on_publication_matched", topic_, status.total_count, status.total_count_change,
                          status.current_count, status.current_count_change);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
    }

private:
    WriterSyncState *state_;
    const char *topic_;
};

class ReaderListener : public ::DDS::DataReaderListenerBase {
public:
    explicit ReaderListener(const char *topic) : topic_(topic) {}

    void on_subscription_matched(std::shared_ptr<::DDS::DataReader> /*reader*/,
                                  ::DDS::SubscriptionMatchedStatus status) override {
        fail_if_torn_down("on_subscription_matched", topic_, status.total_count, status.total_count_change,
                          status.current_count, status.current_count_change);
        if (status.current_count > 0) matched_.store(true);
    }

    bool matched() const { return matched_.load(); }

private:
    const char *topic_;
    std::atomic<bool> matched_{false};
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

    // Writers get their extended listeners at creation, through zzdds's
    // Publisher extension class: a reader discovered earlier matches inside
    // creation, so a listener attached afterwards could miss
    // on_publication_matched and on_reliable_reader_ready.
    auto zpub = std::dynamic_pointer_cast<::zzdds::PublisherImpl>(pub);
    if (!zpub) {
        std::fprintf(stderr, "FAIL: publisher is not a zzdds::PublisherImpl\n");
        return 1;
    }
    WriterSyncState out1_state, out2_state;
    auto out1_listener = std::make_shared<WriterListener>(&out1_state, "SessionOut1");
    auto out2_listener = std::make_shared<WriterListener>(&out2_state, "SessionOut2");
    auto out1_dw = zpub->create_datawriter_ex(out1_topic, dw_qos, out1_listener, DDS_PUBLICATION_MATCHED_STATUS);
    auto out2_dw = zpub->create_datawriter_ex(out2_topic, dw_qos, out2_listener, DDS_PUBLICATION_MATCHED_STATUS);
    if (!out1_dw || !out2_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: SessionOut1\n");
    std::printf("Create writer for topic: SessionOut2\n");

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    // Reader listeners are attached at creation, so their "never after
    // teardown" check covers the readers' whole lifetime.
    auto reader_listener = std::make_shared<ReaderListener>("SessionIn");
    auto cft_reader_listener = std::make_shared<ReaderListener>("SessionIn_cft");
    auto zin_topic = std::static_pointer_cast<::zzdds::TopicImpl>(in_topic);
    auto in_desc = zin_topic->as_topic_description();
    auto in_dr = sub->create_datareader(in_desc, dr_qos, reader_listener, DDS_SUBSCRIPTION_MATCHED_STATUS);
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
    auto cft_dr = sub->create_datareader(cft, dr_qos, cft_reader_listener, DDS_SUBSCRIPTION_MATCHED_STATUS);
    if (!cft_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(SessionIn_cft) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: SessionIn_cft\n");

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

    // Both readers must match the peer's writer before teardown too: samples
    // on the plain reader do not mean the CFT reader has matched, and a first
    // match arriving late would fire its listener during the teardown.
    for (int waited_ms = 0; !(reader_listener->matched() && cft_reader_listener->matched()); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: readers not matched with the peer's writer within %ds (SessionIn=%s SessionIn_cft=%s)\n",
                         READER_READY_TIMEOUT_MS / 1000, reader_listener->matched() ? "true" : "false",
                         cft_reader_listener->matched() ? "true" : "false");
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
    phase.store(PHASE_DELETING);

    auto rc1 = dp->delete_contained_entities();
    if (rc1 != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: delete_contained_entities() returned %d, expected RETCODE_OK\n", static_cast<int>(rc1));
        return 1;
    }
    phase.store(PHASE_DELETED);

    auto rc2 = factory->delete_participant(dp);
    if (rc2 != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: delete_participant() returned %d after delete_contained_entities -- "
                              "cascade left something dangling\n", static_cast<int>(rc2));
        return 1;
    }

    std::printf("Session: torn down via delete_contained_entities.\n");
    return 0;
}
