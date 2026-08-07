/*
 * cpp/hello_world -- subscriber. Direct C++ port of
 * zig/hello_world/subscriber.zig / c/hello_world/src/subscriber.c; see
 * docs/design/hello-world-reference-app.md at the repo root for the full
 * spec. Demonstrates DataReaderListener::on_data_available: every sample
 * is checked against the next expected `count` (fail fast -- any gap or
 * reorder is a hard error), and once all 10 arrive in order this process
 * tears its reader down immediately, which is what lets the publisher's
 * matched reader count drop back to zero and exit.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: received count=", "Subscriber: received
 * all 10 samples in order." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
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

constexpr int EXPECTED_SAMPLES = 10;
constexpr int RECEIVE_TIMEOUT_MS = 30000;
constexpr int POLL_PERIOD_MS = 20;

struct SubState {
    HelloWorldDataReader *reader = nullptr;
    // Only ever touched from the listener's dispatch thread -- see
    // SubListener::on_data_available.
    int32_t expected_next = 0;
    std::atomic<bool> all_received{false};
};

class SubListener : public ::DDS::DataReaderListenerBase {
public:
    explicit SubListener(SubState *state) : state_(state) {}

    void on_data_available(std::shared_ptr<::DDS::DataReader> /*the_reader*/) override {
        for (;;) {
            HelloWorldDataReader::Sample sample{};
            uint8_t buf[512];
            size_t cdr_len = 0;

            int rc = state_->reader->take(sample, buf, sizeof(buf), &cdr_len);
            if (rc != 0) {
                std::fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
                std::exit(1);
            }
            // sample is value-initialized above, so an untouched
            // valid_data==false here means the queue is now empty -- same
            // ambiguity c/hello_world/src/subscriber.c documents, resolved
            // the same way.
            if (!sample.info.valid_data) break;

            if (sample.value.count != state_->expected_next) {
                std::fprintf(stderr, "FAIL: expected count=%d but got count=%d\n",
                              state_->expected_next, sample.value.count);
                std::exit(1);
            }

            std::printf("Subscriber: received count=%d message=\"%s\"\n",
                         sample.value.count, sample.value.message.c_str());
            state_->expected_next++;

            if (state_->expected_next == EXPECTED_SAMPLES) {
                state_->all_received.store(true);
            }
        }
    }

private:
    SubState *state_;
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

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    auto dr_qos = ::DDS::DataReaderQos::default_value();
    dr_qos.reliability.kind = ::DDS::ReliabilityQosPolicyKind::RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = ::DDS::HistoryQosPolicyKind::KEEP_ALL_HISTORY_QOS;

    SubState state;
    auto listener = std::make_shared<SubListener>(&state);

    // create_topic now actually constructs zzdds::detail::TopicSupport under
    // the hood (see zzdds's build.zig --cpp-impl-override), which publicly
    // derives from zzdds::TopicImpl -- so this upcast is real and valid, and
    // as_topic_description() is already implemented there. No raw C ABI
    // needed for this anymore.
    auto ztopic = std::static_pointer_cast<::zzdds::TopicImpl>(topic);
    auto topic_desc = ztopic->as_topic_description();
    auto dr = sub->create_datareader(topic_desc, dr_qos, listener, DDS_DATA_AVAILABLE_STATUS);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    std::printf("Create reader for topic: HelloWorld\n");

    auto dr_handle = dr->native_handle();
    HelloWorldDataReader reader(dr_handle);
    state.reader = &reader;

    std::printf("Subscriber: waiting for %d samples...\n", EXPECTED_SAMPLES);
    for (int waited_ms = 0; !state.all_received.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                          state.expected_next, EXPECTED_SAMPLES, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    // Tear the reader down immediately -- the publisher is blocked waiting
    // for our matched-reader count to drop back to zero.
    sub->delete_datareader(dr);

    std::printf("Subscriber: received all %d samples in order.\n", EXPECTED_SAMPLES);
    return 0;
}
