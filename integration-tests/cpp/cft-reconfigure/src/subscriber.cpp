/*
 * integration-tests/cpp/cft-reconfigure -- subscriber (the entity under
 * test). Direct C++ port of c/cft-reconfigure/src/subscriber.c -- see that
 * file's header comment for the full scenario rationale and
 * docs/design/integration-test-tier.md for the scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create reader for topic:"
 * x2, "Create writer for topic:", "Subscriber: CFT introspection
 * (filter_expression/expression_parameters/related_topic) verified at
 * creation.", "Subscriber: ready.", "Subscriber: witnessed all 5 phase1
 * samples via unfiltered reader.", "Subscriber: filtered reader correctly
 * received zero phase1 samples (threshold=1000).", "Subscriber:
 * set_expression_parameters() reconfigured threshold to 3, read-back
 * verified.", "Subscriber: sent go-ahead signal.", "Subscriber: witnessed
 * all 10 total samples via unfiltered reader.", "Subscriber: filtered
 * reader received exactly the post-reconfigure samples {5..9}, confirming
 * live re-filtering without CFT recreation.", "Subscriber: done." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "cft_event.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int TOTAL_COUNT = 10;
constexpr int PHASE1_COUNT = 5;
constexpr int PHASE2_COUNT = 5;
// Must comfortably exceed publisher.cpp's own MATCH_TIMEOUT_MS -- see
// c/cft-reconfigure/src/subscriber.c's matching comment.
constexpr int WITNESS_TIMEOUT_MS = 45000;
constexpr int SETTLE_WINDOW_S = 3;
constexpr int FINAL_TIMEOUT_MS = 20000;
constexpr int POLL_PERIOD_MS = 20;

struct ReaderState {
    CftEventDataReader *reader = nullptr;
    std::atomic<bool> received[TOTAL_COUNT];
    std::atomic<int> count{0};

    ReaderState() {
        for (auto &v : received) v.store(false);
    }
};

class RecordingListener : public ::DDS::DataReaderListenerBase {
public:
    explicit RecordingListener(ReaderState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        for (;;) {
            CftEventDataReader::Sample sample{};
            uint8_t buf[256];
            size_t cdr_len = 0;
            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc == DDS_RETCODE_NO_DATA) break;
            if (rc != DDS_RETCODE_OK) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }
            if (!sample.info.valid_data) continue;
            int32_t seq = sample.value.seq;
            if (seq < 0 || seq >= TOTAL_COUNT) {
                std::fprintf(stderr, "FAIL: unexpected seq=%d\n", seq);
                std::exit(1);
            }
            if (!state_->received[seq].load()) {
                state_->received[seq].store(true);
                state_->count.fetch_add(1);
            }
        }
    }

private:
    ReaderState *state_;
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

    if (CftEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("CftEvent", "CftEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: CftEvent\n");
    std::fflush(stdout);

    auto go_topic = dp->create_topic("GoTopic", "CftEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!go_topic) {
        std::fprintf(stderr, "FAIL: create_topic(GoTopic) failed\n");
        return 1;
    }
    std::printf("Create topic: GoTopic\n");
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

    // -- Witness reader: plain, unfiltered, proves end-to-end wire delivery
    // independent of the filtered reader's own behavior. --
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto witness_dr = sub->create_datareader(ztopic->as_topic_description(), dr_qos, nullptr, 0);
    if (!witness_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(witness) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: CftEvent (witness)\n");
    std::fflush(stdout);

    // -- ContentFilteredTopic: initial threshold (1000) unreachable by
    // phase1's seq range (0..4), so every phase1 sample must be filtered
    // out. --
    auto cft = dp->create_contentfilteredtopic("CftEvent_Filtered", topic, "seq >= %0", ::DDS::StringSeq{"1000"});
    if (!cft) {
        std::fprintf(stderr, "FAIL: create_contentfilteredtopic() failed\n");
        return 1;
    }

    // -- CFT introspection, verified right at creation -- the exact surface
    // the API audit flags as "set once at creation, never read back". --
    auto filter_expr = cft->get_filter_expression();
    if (filter_expr != "seq >= %0") {
        std::fprintf(stderr, "FAIL: get_filter_expression() returned \"%s\", expected \"seq >= %%0\"\n", filter_expr.c_str());
        return 1;
    }
    ::DDS::StringSeq readback_params;
    if (cft->get_expression_parameters(readback_params) != ::DDS::RETCODE_OK || readback_params.size() != 1 || readback_params[0] != "1000") {
        std::fprintf(stderr, "FAIL: get_expression_parameters() at creation did not return [\"1000\"]\n");
        return 1;
    }
    auto related = cft->get_related_topic();
    if (!related || related->get_name() != "CftEvent") {
        std::fprintf(stderr, "FAIL: get_related_topic() did not return the CftEvent topic\n");
        return 1;
    }
    std::printf("Subscriber: CFT introspection (filter_expression/expression_parameters/related_topic) verified at creation.\n");
    std::fflush(stdout);

    auto cft_desc = std::static_pointer_cast<::DDS::TopicDescription>(cft);
    auto filtered_dr = sub->create_datareader(cft_desc, dr_qos, nullptr, 0);
    if (!filtered_dr) {
        std::fprintf(stderr, "FAIL: create_datareader(filtered) failed\n");
        return 1;
    }
    std::printf("Create reader for topic: CftEvent_Filtered\n");
    std::fflush(stdout);

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;
    auto go_dw = pub->create_datawriter(go_topic, dw_qos, nullptr, 0);
    if (!go_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter(GoTopic) failed\n");
        return 1;
    }
    std::printf("Create writer for topic: GoTopic\n");
    std::fflush(stdout);

    ReaderState witness_state, filtered_state;
    CftEventDataReader witness_reader(witness_dr->native_handle());
    CftEventDataReader filtered_reader(filtered_dr->native_handle());
    witness_state.reader = &witness_reader;
    filtered_state.reader = &filtered_reader;

    auto witness_listener = std::make_shared<RecordingListener>(&witness_state);
    auto filtered_listener = std::make_shared<RecordingListener>(&filtered_state);
    if (witness_dr->set_listener(witness_listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK ||
        filtered_dr->set_listener(filtered_listener, DDS_DATA_AVAILABLE_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    CftEventDataWriter go_writer(go_dw->native_handle());

    std::printf("Subscriber: ready.\n");
    std::fflush(stdout);

    // -- Phase 1: wait for the witness reader to see all 5, proving they
    // really were sent and really did arrive over the wire. --
    for (int waited_ms = 0; witness_state.count.load() < PHASE1_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= WITNESS_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: witness reader only saw %d/%d phase1 samples within %ds\n", witness_state.count.load(), PHASE1_COUNT, WITNESS_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Subscriber: witnessed all %d phase1 samples via unfiltered reader.\n", PHASE1_COUNT);
    std::fflush(stdout);

    // -- Settle window, then confirm the filtered reader received none of
    // phase1 (threshold=1000 excludes seq 0..4 entirely). --
    sleep(SETTLE_WINDOW_S);
    int filtered_after_phase1 = filtered_state.count.load();
    if (filtered_after_phase1 != 0) {
        std::fprintf(stderr, "FAIL: filtered reader received %d phase1 samples despite threshold=1000\n", filtered_after_phase1);
        return 1;
    }
    std::printf("Subscriber: filtered reader correctly received zero phase1 samples (threshold=1000).\n");
    std::fflush(stdout);

    // -- Reconfigure the live CFT in place -- no recreation of the CFT or
    // its DataReader. --
    if (cft->set_expression_parameters(::DDS::StringSeq{"3"}) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_expression_parameters() failed\n");
        return 1;
    }
    ::DDS::StringSeq readback2;
    if (cft->get_expression_parameters(readback2) != ::DDS::RETCODE_OK || readback2.size() != 1 || readback2[0] != "3") {
        std::fprintf(stderr, "FAIL: get_expression_parameters() after reconfigure did not return [\"3\"]\n");
        return 1;
    }
    std::printf("Subscriber: set_expression_parameters() reconfigured threshold to 3, read-back verified.\n");
    std::fflush(stdout);

    ::CftEvent go_ev;
    go_ev.seq = 0;
    if (go_writer.write(go_ev) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: write(GoTopic) failed\n");
        return 1;
    }
    std::printf("Subscriber: sent go-ahead signal.\n");
    std::fflush(stdout);

    // -- Phase 2: wait for the witness reader to see all 10 total. --
    for (int waited_ms = 0; witness_state.count.load() < TOTAL_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= FINAL_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: witness reader only saw %d/%d total samples within %ds\n", witness_state.count.load(), TOTAL_COUNT, FINAL_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    std::printf("Subscriber: witnessed all %d total samples via unfiltered reader.\n", TOTAL_COUNT);
    std::fflush(stdout);

    // -- The core assertion: the filtered reader must have received
    // *exactly* {5,6,7,8,9} -- phase2 correctly re-filtered against the new
    // threshold (proving live reconfiguration works), and phase1's seq=3
    // and seq=4 (both >= the *new* threshold of 3) never retroactively
    // appear (proving already-dropped samples are gone for good, not
    // replayed against the new parameter). --
    for (int seq = 0; seq < PHASE1_COUNT; seq++) {
        if (filtered_state.received[seq].load()) {
            std::fprintf(stderr, "FAIL: filtered reader retroactively received phase1 seq=%d after reconfigure\n", seq);
            return 1;
        }
    }
    for (int seq = PHASE1_COUNT; seq < TOTAL_COUNT; seq++) {
        if (!filtered_state.received[seq].load()) {
            std::fprintf(stderr, "FAIL: filtered reader never received phase2 seq=%d despite threshold=3\n", seq);
            return 1;
        }
    }
    if (filtered_state.count.load() != PHASE2_COUNT) {
        std::fprintf(stderr, "FAIL: filtered reader received %d samples total, expected exactly %d\n", filtered_state.count.load(), PHASE2_COUNT);
        return 1;
    }
    std::printf("Subscriber: filtered reader received exactly the post-reconfigure samples {5..9}, confirming live re-filtering without CFT recreation.\n");
    std::fflush(stdout);

    std::printf("Subscriber: done.\n");
    std::fflush(stdout);
    factory->delete_participant(dp);
    return 0;
}
