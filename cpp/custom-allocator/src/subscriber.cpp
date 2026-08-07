/*
 * Milestone 1 custom-allocator C++ showcase: subscribes to SensorSample values over
 * real UDP DDS discovery, using a fixed-size static-pool allocator for every
 * allocation the factory and everything it creates makes, AND every C++
 * wrapper object (via zidl::setCppAllocator) -- no libc malloc/free/operator
 * new anywhere in this process's steady-state receive loop.
 */
#include "sensor.hpp"
#include "zzdds_cpp.hpp"
#include "dcps_impl.hpp"
#include "static_pool_allocator.h"
#include "noalloc_guard.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {

constexpr int DOMAIN_ID = 7;
constexpr int EXPECTED_SAMPLES = 10;
constexpr int EXPECTED_LOGS = 5;
constexpr int MAX_WAIT_SECONDS = 20;

void check(int rc, const char *what) {
    if (rc != 0) {
        std::fprintf(stderr, "FAIL: %s (rc=%d)\n", what, rc);
        std::exit(1);
    }
}

char g_stdout_buf[8192];

} // namespace

int main() {
    std::setvbuf(stdout, g_stdout_buf, _IOFBF, sizeof(g_stdout_buf));
    static_pool_allocator_reset();
    zidl_cdr_set_allocator(&static_pool_allocator);
    zidl::setCppAllocator(&static_pool_allocator);

    // Resolve+install zzdds.toml as the process-wide config BEFORE creating
    // any factory, through the same static-pool allocator everything else in
    // this process uses -- see publisher.cpp / this README's config-file
    // section.
    if (zzdds::process_configure_from_file("zzdds.toml", &static_pool_allocator) != DDS_RETCODE_OK) {
        std::fprintf(stderr, "FAIL: process_configure_from_file\n");
        return 1;
    }

    auto factory = zzdds::create_factory(&static_pool_allocator);
    if (!factory) {
        std::fprintf(stderr, "FAIL: create_factory returned null\n");
        return 1;
    }

    auto dp = factory->create_participant(
        DOMAIN_ID, ::DDS::DomainParticipantQos::default_value(), nullptr, 0);
    if (!dp) {
        std::fprintf(stderr, "FAIL: create_participant returned null\n");
        return 1;
    }
    auto dp_handle = dp->native_handle();

    check(SensorSampleTypeSupport::register_type(dp_handle), "register_type");

    auto topic = dp->create_topic(
        "SensorTopic", "SensorSample", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!topic) {
        std::fprintf(stderr, "FAIL: create_topic returned null\n");
        return 1;
    }

    auto sub = dp->create_subscriber(::DDS::SubscriberQos::default_value(), nullptr, 0);
    if (!sub) {
        std::fprintf(stderr, "FAIL: create_subscriber returned null\n");
        return 1;
    }

    auto dr = sub->create_datareader(topic, ::DDS::DataReaderQos::default_value(), nullptr, 0);
    if (!dr) {
        std::fprintf(stderr, "FAIL: create_datareader returned null\n");
        return 1;
    }
    auto dr_handle = dr->native_handle();

    SensorSampleDataReader typed_reader(dr_handle);

    check(SensorLogTypeSupport::register_type(dp_handle), "register_type (SensorLog)");

    auto log_topic = dp->create_topic(
        "SensorLogTopic", "SensorLog", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!log_topic) {
        std::fprintf(stderr, "FAIL: create_topic (SensorLog) returned null\n");
        return 1;
    }

    auto log_dr = sub->create_datareader(log_topic, ::DDS::DataReaderQos::default_value(), nullptr, 0);
    if (!log_dr) {
        std::fprintf(stderr, "FAIL: create_datareader (SensorLog) returned null\n");
        return 1;
    }
    auto log_dr_handle = log_dr->native_handle();

    SensorLogDataReader log_reader(log_dr_handle);

    // Give discovery/matching a moment to settle before arming the guard:
    // SPDP/SEDP built-in discovery endpoints spawn a heartbeat thread per
    // newly matched remote participant (via std.Thread.spawn), and Zig's own
    // stdlib hardcodes std.heap.c_allocator for that spawn's bookkeeping on
    // the libc/pthread backend -- SpawnConfig.allocator is silently ignored
    // there, so this allocation isn't something zzdds can route through the
    // injected allocator. It's a one-time, bounded, per-newly-matched-peer
    // cost though, not a per-sample hot-path one, so it belongs before
    // arming, same as factory/entity bootstrap.
    sleep(2);

    noalloc_guard_try_arm();

    std::printf("subscriber: waiting for up to %d samples on domain %d (timeout %ds)...\n",
                EXPECTED_SAMPLES, DOMAIN_ID, MAX_WAIT_SECONDS);

    int received = 0;
    for (int elapsed_ms = 0; elapsed_ms < MAX_WAIT_SECONDS * 1000 && received < EXPECTED_SAMPLES;
         elapsed_ms += 50) {
        // take()'s return value is ambiguous: it's 0 both when the queue was
        // empty (untouched out/info) AND when a sample was successfully
        // taken and deserialized -- the only reliable signal is
        // info.valid_data, which is why info must be zeroed first: an empty
        // queue never touches it, so a stale (non-zeroed) valid_data from a
        // previous iteration could otherwise be misread as a real sample.
        SensorSampleDataReader::Sample sample;
        sample.info = zzdds_sample_info{};
        uint8_t buf[256];
        size_t cdr_len = 0;
        int rc = typed_reader.take(sample, buf, sizeof(buf), &cdr_len);
        if (rc == 0 && sample.info.valid_data) {
            std::printf("  received sample: id=%u temp=%.1fC label=%s\n",
                        sample.value.sensor_id, sample.value.temperature_c,
                        sample.value.label.c_str());
            received++;
            continue; // check for more immediately, no sleep
        }
        usleep(50 * 1000);
    }

    int received_logs = 0;
    for (int elapsed_ms = 0; elapsed_ms < MAX_WAIT_SECONDS * 1000 && received_logs < EXPECTED_LOGS;
         elapsed_ms += 50) {
        SensorLogDataReader::Sample sample;
        sample.info = zzdds_sample_info{};
        uint8_t buf[512];
        size_t cdr_len = 0;
        int rc = log_reader.take(sample, buf, sizeof(buf), &cdr_len);
        if (rc == 0 && sample.info.valid_data) {
            std::printf("  received log: id=%u message=\"%s\" readings=[",
                        sample.value.sensor_id, sample.value.log_message.c_str());
            for (size_t i = 0; i < sample.value.readings.size(); i++) {
                std::printf("%s%.1f", i == 0 ? "" : ", ", sample.value.readings[i]);
            }
            std::printf("]\n");
            // Unlike C's SensorLog_free(&out): std::pmr::string/vector's
            // destructors release back to the pool automatically when
            // `sample` goes out of scope at the end of this iteration -- no
            // explicit free call, by construction of RAII plus the pmr
            // allocator binding zidl::setCppAllocator set up before this
            // Sample was default-constructed.
            received_logs++;
            continue;
        }
        usleep(50 * 1000);
    }

    noalloc_guard_try_disarm();

    if (received == 0) {
        std::fprintf(stderr, "FAIL: received 0 samples (expected %d) -- discovery or transport problem\n",
                      EXPECTED_SAMPLES);
        return 1;
    }
    if (received_logs == 0) {
        std::fprintf(stderr, "FAIL: received 0 log samples (expected %d)\n", EXPECTED_LOGS);
        return 1;
    }
    std::printf("subscriber: done, received %d/%d samples, %d/%d logs\n",
                received, EXPECTED_SAMPLES, received_logs, EXPECTED_LOGS);
    return 0;
}
