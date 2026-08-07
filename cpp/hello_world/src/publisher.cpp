/*
 * cpp/hello_world -- publisher. Direct C++ port of
 * zig/hello_world/publisher.zig / c/hello_world/src/publisher.c; see
 * docs/design/hello-world-reference-app.md at the repo root for the full
 * spec. Demonstrates:
 *
 *   1. zzdds's DataWriterListenerEx::on_reliable_reader_ready extension --
 *      write only once a matched RELIABLE reader has actually completed the
 *      AckNack/Heartbeat handshake, not just SEDP discovery.
 *   2. Clean shutdown gated on PublicationMatchedStatus.current_count
 *      returning to zero -- waiting for the subscriber to tear its reader
 *      down, not just for our own writes to finish.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "on_reliable_reader_ready", "Publisher: wrote
 * count=", "on_publication_matched", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "hello_world.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int SAMPLE_COUNT = 10;
constexpr int READER_READY_TIMEOUT_MS = 10000;
constexpr int DRAIN_TIMEOUT_MS = 15000;
constexpr int POLL_PERIOD_MS = 20;

struct PubState {
    std::atomic<bool> reader_ready{false};
    std::atomic<bool> ever_matched{false};
    std::atomic<int> matched_current_count{0};
};

class PubListener : public ::zzdds::DataWriterListenerExBase {
public:
    explicit PubListener(PubState *state) : state_(state) {}

    void on_publication_matched(std::shared_ptr<::DDS::DataWriter> /*writer*/,
                                 ::DDS::PublicationMatchedStatus status) override {
        state_->matched_current_count.store(status.current_count);
        if (status.current_count > 0) state_->ever_matched.store(true);
        std::printf("on_publication_matched() current_count=%d\n", status.current_count);
    }

    void on_reliable_reader_ready(::DDS::InstanceHandle_t /*reader_handle*/, bool is_ready) override {
        if (is_ready) state_->reader_ready.store(true);
        std::printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
    }

private:
    PubState *state_;
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

    if (HelloWorldTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("HelloWorld", "HelloWorld", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: HelloWorld\n");

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    auto dw_qos = ::DDS::DataWriterQos::default_value();
    dw_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    auto dw = pub->create_datawriter(topic, dw_qos, nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    std::printf("Create writer for topic: HelloWorld\n");

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    // create_datawriter now actually constructs zzdds::detail::DataWriterSupport
    // under the hood (see zzdds's build.zig --cpp-impl-override), which
    // publicly derives from zzdds::DataWriterImpl -- so this upcast is a
    // real, valid one along an actual inheritance chain, not the undefined
    // behavior it used to be (a cast between unrelated sibling classes).
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    auto dw_handle = dw->native_handle();
    HelloWorldDataWriter writer(dw_handle);

    // Wait for a reliable reader to complete the AckNack/Heartbeat handshake
    // before writing anything -- the whole point of the extension.
    for (int waited_ms = 0; !state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        ::HelloWorld sample;
        sample.count = i;
        sample.message = "Hello world!";

        if (writer.write(sample) != 0) {
            std::fprintf(stderr, "FAIL: write() failed at count=%d\n", i);
            return 1;
        }
        std::printf("Publisher: wrote count=%d message=\"Hello world!\"\n", i);
    }

    // Wait for the subscriber to tear its reader down (current_count back
    // to zero) before exiting.
    for (int waited_ms = 0;
         !(state.ever_matched.load() && state.matched_current_count.load() == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    std::printf("Publisher: done.\n");
    return 0;
}
