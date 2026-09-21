/*
 * integration-tests/cpp/enable-defer -- configurer. Direct C++ port of
 * c/enable-defer/src/configurer.c -- see that file's header comment for the
 * full scenario rationale and docs/design/integration-test-tier.md for the
 * scenario spec.
 *
 * Required stdout markers: "Create topic: ConfigTopic", "Create writer for
 * topic: ConfigTopic", "Configurer: write on disabled writer correctly
 * returned NOT_ENABLED.", "Configurer: enabling writer before publisher
 * correctly returned PRECONDITION_NOT_MET.", "Configurer: done." Any failure
 * path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_event.hpp"
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
constexpr int PRE_ENABLE_DELAY_SEC = 4;
constexpr int READER_READY_TIMEOUT_MS = 20000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct WriterSyncState {
    std::atomic<bool> reader_ready{false};
    std::atomic<int> matched_current_count{0};
    std::atomic<bool> ever_matched{false};
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

    // Participant created normally (enabled) -- only ITS CHILDREN start
    // disabled, per ENTITY_FACTORY QoS semantics.
    auto dp = factory->create_participant(domain_id, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }
    auto dp_handle = dp->native_handle();

    // Get-mutate-set, not a from-scratch QoS literal -- avoids clobbering any
    // other participant QoS field (see examples/c/shape's shape_main.c fix
    // in Phase A's history for why a zeroed/from-scratch QoS struct is risky
    // now that entity_factory genuinely defaults true).
    ::DDS::DomainParticipantQos dp_qos;
    if (dp->get_qos(dp_qos) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: get_qos(participant) failed\n");
        return 1;
    }
    dp_qos.entity_factory.autoenable_created_entities = false;
    if (dp->set_qos(dp_qos) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_qos(participant, autoenable=false) failed\n");
        return 1;
    }

    if (ConfigEventTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register ConfigEventTypeSupport failed\n");
        return 1;
    }

    // Topics have no wire footprint of their own -- creating one here is
    // unaffected either way.
    auto topic = dp->create_topic("ConfigTopic", "ConfigEvent", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic(ConfigTopic) failed\n");
        return 1;
    }
    std::printf("Create topic: ConfigTopic\n");

    // Publisher comes in disabled (participant's entity_factory QoS above).
    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    ::DDS::PublisherQos pub_qos;
    if (pub->get_qos(pub_qos) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: get_qos(publisher) failed\n");
        return 1;
    }
    pub_qos.entity_factory.autoenable_created_entities = false;
    if (pub->set_qos(pub_qos) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_qos(publisher, autoenable=false) failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    // DataWriter comes in disabled (publisher's entity_factory QoS above).
    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: ConfigTopic\n");

    WriterSyncState writer_state;
    auto writer_listener = std::make_shared<WriterListener>(&writer_state);
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(writer_listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex(ConfigTopic writer) failed\n");
        return 1;
    }

    ConfigEventDataWriter writer(dw->native_handle());

    // Core assertion #1: write() on a still-disabled writer must fail with
    // NOT_ENABLED, not silently succeed.
    ::ConfigEvent probe_ev;
    probe_ev.seq = -1;
    auto probe_rc = writer.write(probe_ev);
    if (probe_rc != ::DDS::RETCODE_NOT_ENABLED) {
        std::fprintf(stderr, "FAIL: write() on disabled writer returned %d, expected RETCODE_NOT_ENABLED (%d)\n",
                      static_cast<int>(probe_rc), static_cast<int>(::DDS::RETCODE_NOT_ENABLED));
        return 1;
    }
    std::printf("Configurer: write on disabled writer correctly returned NOT_ENABLED.\n");

    // Deliberate wall-clock window -- not a race-avoidance hack. This just
    // gives the peer process a comfortable, unambiguous stretch of real time
    // to independently confirm zero premature matching before anything here
    // is enabled; the peer controls its own assertion window on its own
    // clock, this delay only makes sure there's real room for it.
    sleep(PRE_ENABLE_DELAY_SEC);

    // Core assertion #2: enabling the writer before its own Publisher must
    // fail with PRECONDITION_NOT_MET (spec: can't enable a child before its
    // factory entity).
    auto rc = dw->enable();
    if (rc != ::DDS::RETCODE_PRECONDITION_NOT_MET) {
        std::fprintf(stderr, "FAIL: writer.enable() before publisher.enable() returned %d, expected RETCODE_PRECONDITION_NOT_MET (%d)\n",
                      static_cast<int>(rc), static_cast<int>(::DDS::RETCODE_PRECONDITION_NOT_MET));
        return 1;
    }
    std::printf("Configurer: enabling writer before publisher correctly returned PRECONDITION_NOT_MET.\n");

    rc = pub->enable();
    if (rc != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: publisher.enable() returned %d, expected RETCODE_OK\n", static_cast<int>(rc));
        return 1;
    }
    rc = dw->enable();
    if (rc != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: writer.enable() returned %d after publisher.enable(), expected RETCODE_OK\n", static_cast<int>(rc));
        return 1;
    }
    std::printf("Configurer: enabled publisher then writer.\n");

    for (int waited_ms = 0; !writer_state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds of enabling\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ::ConfigEvent ev;
        ev.seq = seq;
        if (writer.write(ev) != ::DDS::RETCODE_OK) {
            std::fprintf(stderr, "FAIL: write() failed at seq=%d after enabling\n", seq);
            return 1;
        }
    }
    std::printf("Configurer: wrote %d samples after enabling.\n", SAMPLE_COUNT);

    // Standard teardown-safety: wait for the peer to unmatch/drain before
    // deleting, matching raw-loan's precedent.
    for (int waited_ms = 0; writer_state.matched_current_count.load() != 0 || !writer_state.ever_matched.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Configurer: done.\n");
    factory->delete_participant(dp);
    return 0;
}
