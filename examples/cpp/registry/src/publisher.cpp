/*
 * cpp/registry -- publisher. Direct C++ port of zig/registry/publisher.zig;
 * see docs/design/registry-reference-app.md at the repo root for the full
 * spec. Walks three instances through three different explicit lifecycles:
 * register_instance() -> write() x2 -> dispose() (instance A),
 * register_instance() -> write_w_timestamp() -> unregister_instance()
 * (instance B), register_instance() -> write() left alive (instance C) --
 * then confirms get_key_value() rounds the handle it got for instance A
 * back to the right key.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: registered instance sensor_id=",
 * "Publisher: wrote sensor_id=", "Publisher: disposed sensor_id=",
 * "Publisher: unregistered sensor_id=", "Publisher: get_key_value
 * round-trip OK for sensor_id=", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "registry_sample.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"

#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

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

    if (SensorReadingTypeSupport::register_type(dp_handle) != 0) {
        std::fprintf(stderr, "FAIL: register_type failed\n");
        return 1;
    }

    auto topic = dp->create_topic("SensorReading", "SensorReading", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    std::printf("Create topic: SensorReading\n");

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
    std::printf("Create writer for topic: SensorReading\n");

    PubState state;
    auto listener = std::make_shared<PubListener>(&state);
    auto zdw = std::static_pointer_cast<::zzdds::DataWriterImpl>(dw);
    if (zdw->set_listener_ex(listener, DDS_PUBLICATION_MATCHED_STATUS) != ::DDS::RETCODE_OK) {
        std::fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    auto dw_handle = dw->native_handle();
    SensorReadingDataWriter writer(dw_handle);

    for (int waited_ms = 0; !state.reader_ready.load(); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            std::fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    // -- Instance A (sensor_id=1): register -> write x2 -> dispose --
    ::SensorReading key_a;
    key_a.sensor_id = 1;
    key_a.value = 0;
    DDS_InstanceHandle_t handle_a = writer.register_instance(key_a);
    std::printf("Publisher: registered instance sensor_id=1\n");

    ::SensorReading sample_a1;
    sample_a1.sensor_id = 1;
    sample_a1.value = 100;
    if (writer.write(sample_a1) != 0) {
        std::fprintf(stderr, "FAIL: write() failed for sensor_id=1\n");
        return 1;
    }
    std::printf("Publisher: wrote sensor_id=1 value=100\n");

    ::SensorReading sample_a2;
    sample_a2.sensor_id = 1;
    sample_a2.value = 101;
    if (writer.write(sample_a2) != 0) {
        std::fprintf(stderr, "FAIL: write() failed for sensor_id=1\n");
        return 1;
    }
    std::printf("Publisher: wrote sensor_id=1 value=101\n");

    if (writer.dispose(key_a) != 0) {
        std::fprintf(stderr, "FAIL: dispose() failed for sensor_id=1\n");
        return 1;
    }
    std::printf("Publisher: disposed sensor_id=1\n");

    // -- Instance B (sensor_id=2): register -> write_w_timestamp -> unregister --
    ::SensorReading key_b;
    key_b.sensor_id = 2;
    key_b.value = 0;
    writer.register_instance(key_b);
    std::printf("Publisher: registered instance sensor_id=2\n");

    auto now = std::chrono::system_clock::now().time_since_epoch();
    auto now_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();
    DDS_Time_t ts;
    ts.sec = static_cast<int32_t>(now_ns / 1000000000LL);
    ts.nanosec = static_cast<uint32_t>(now_ns % 1000000000LL);

    ::SensorReading sample_b;
    sample_b.sensor_id = 2;
    sample_b.value = 200;
    if (writer.write_w_timestamp(sample_b, ts) != 0) {
        std::fprintf(stderr, "FAIL: write_w_timestamp() failed for sensor_id=2\n");
        return 1;
    }
    std::printf("Publisher: wrote sensor_id=2 value=200\n");

    if (writer.unregister_instance(key_b) != 0) {
        std::fprintf(stderr, "FAIL: unregister_instance() failed for sensor_id=2\n");
        return 1;
    }
    std::printf("Publisher: unregistered sensor_id=2\n");

    // -- Instance C (sensor_id=3): register -> write, left alive --
    ::SensorReading key_c;
    key_c.sensor_id = 3;
    key_c.value = 0;
    writer.register_instance(key_c);
    std::printf("Publisher: registered instance sensor_id=3\n");

    ::SensorReading sample_c;
    sample_c.sensor_id = 3;
    sample_c.value = 300;
    if (writer.write(sample_c) != 0) {
        std::fprintf(stderr, "FAIL: write() failed for sensor_id=3\n");
        return 1;
    }
    std::printf("Publisher: wrote sensor_id=3 value=300\n");

    // -- get_key_value() round-trip on instance A's handle --
    ::SensorReading key_holder;
    if (writer.get_key_value(handle_a, key_holder) != 0) {
        std::fprintf(stderr, "FAIL: get_key_value() failed for sensor_id=1\n");
        return 1;
    }
    if (key_holder.sensor_id != 1) {
        std::fprintf(stderr, "FAIL: get_key_value() round-trip mismatch: expected sensor_id=1, got sensor_id=%d\n", key_holder.sensor_id);
        return 1;
    }
    std::printf("Publisher: get_key_value round-trip OK for sensor_id=1\n");

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
