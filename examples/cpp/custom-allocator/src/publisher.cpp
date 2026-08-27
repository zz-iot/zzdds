/*
 * Milestone 1 custom-allocator C++ showcase: publishes SensorSample values over real
 * UDP DDS discovery, using a fixed-size static-pool allocator for every
 * allocation the factory and everything it creates makes (participant,
 * topic, publisher, writer, history cache -- via
 * zzdds_create_factory_with_allocator) AND every C++ wrapper object
 * (DomainParticipant/Topic/DataWriter impl objects, via
 * zidl::setCppAllocator's std::pmr routing) -- no libc malloc/free/operator
 * new anywhere in this process's steady-state publishing loop.
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
constexpr int SAMPLE_COUNT = 10;
constexpr int LOG_COUNT = 5;

void check(int rc, const char *what) {
    if (rc != 0) {
        std::fprintf(stderr, "FAIL: %s (rc=%d)\n", what, rc);
        std::exit(1);
    }
}

// Statically buffered (not malloc'd) so stdio's own lazy buffer setup can
// never trip the noalloc guard once armed below.
char g_stdout_buf[8192];

} // namespace

int main() {
    std::setvbuf(stdout, g_stdout_buf, _IOFBF, sizeof(g_stdout_buf));
    static_pool_allocator_reset();
    // Two separate, independent allocator registrations (see
    // allocator-strategy.md): zidl_cdr_set_allocator routes the CDR writer's
    // own scratch-buffer growth; zidl::setCppAllocator routes every C++
    // wrapper object (DomainParticipantImpl, TopicImpl, DataWriterImpl, ...,
    // via std::pmr) -- both must point at the same pool for a genuinely
    // zero-libc-malloc process.
    zidl_cdr_set_allocator(&static_pool_allocator);
    zidl::setCppAllocator(&static_pool_allocator);

    // Resolve+install zzdds.toml as the process-wide config BEFORE creating
    // any factory, through the same static-pool allocator everything else in
    // this process uses. Without this, create_factory's own ambient
    // lazy-default resolution would still route this one-time bootstrap step
    // through libc malloc regardless of the allocator passed to it -- see
    // this README's config-file section.
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

    auto pub = dp->create_publisher(::DDS::PublisherQos::default_value(), nullptr, 0);
    if (!pub) {
        std::fprintf(stderr, "FAIL: create_publisher returned null\n");
        return 1;
    }

    auto dw = pub->create_datawriter(topic, ::DDS::DataWriterQos::default_value(), nullptr, 0);
    if (!dw) {
        std::fprintf(stderr, "FAIL: create_datawriter returned null\n");
        return 1;
    }
    auto dw_handle = dw->native_handle();

    SensorSampleDataWriter typed_writer(dw_handle);

    // Milestone 2: SensorLog has an unbounded string and sequence -- writing
    // it needs no heap at all (the fields just get assigned from this
    // process's own stack data), but it exercises the writer's CDR encoding
    // of unbounded fields on the wire, which the subscriber's decode side
    // then has to handle.
    check(SensorLogTypeSupport::register_type(dp_handle), "register_type (SensorLog)");

    auto log_topic = dp->create_topic(
        "SensorLogTopic", "SensorLog", ::DDS::TopicQos::default_value(), nullptr, 0);
    if (!log_topic) {
        std::fprintf(stderr, "FAIL: create_topic (SensorLog) returned null\n");
        return 1;
    }

    auto log_dw = pub->create_datawriter(log_topic, ::DDS::DataWriterQos::default_value(), nullptr, 0);
    if (!log_dw) {
        std::fprintf(stderr, "FAIL: create_datawriter (SensorLog) returned null\n");
        return 1;
    }
    auto log_dw_handle = log_dw->native_handle();

    SensorLogDataWriter log_writer(log_dw_handle);

    std::printf("publisher: writing %d samples on domain %d...\n", SAMPLE_COUNT, DOMAIN_ID);

    // Give discovery a moment to find a matched reader before writing --
    // best-effort QoS (the default) drops samples with no matched reader
    // yet, so a brief wait makes the demo reliably show real delivery. This
    // also lets SPDP/SEDP matching settle: matching a newly discovered
    // remote participant spawns a heartbeat thread via std.Thread.spawn,
    // whose bookkeeping allocation Zig's own stdlib hardcodes to
    // std.heap.c_allocator on the libc/pthread backend (SpawnConfig.allocator
    // is silently ignored there) -- a one-time, bounded, per-newly-matched-peer
    // cost, not a per-sample hot-path one, so it belongs before arming.
    sleep(2);

    // All one-time/discovery-adjacent allocation is done -- arm the guard so
    // any further malloc/calloc/realloc/free/operator new aborts the process.
    noalloc_guard_try_arm();

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        SensorSample sample;
        sample.sensor_id = 42;
        sample.timestamp_ms = static_cast<uint64_t>(i) * 1000ULL;
        sample.temperature_c = 20.0 + static_cast<double>(i) * 0.5;
        char label_buf[32];
        std::snprintf(label_buf, sizeof(label_buf), "sensor-%d", i);
        sample.label = label_buf;

        check(typed_writer.write(sample), "DataWriter::write");
        std::printf("  wrote sample %d: temp=%.1fC label=%s\n", i, sample.temperature_c, sample.label.c_str());
        usleep(200 * 1000);
    }

    std::printf("publisher: writing %d log samples...\n", LOG_COUNT);
    for (int i = 0; i < LOG_COUNT; i++) {
        SensorLog log_sample;
        log_sample.sensor_id = 42;
        char message_buf[64];
        std::snprintf(message_buf, sizeof(message_buf), "sensor 42 reading batch #%d", i);
        log_sample.log_message = message_buf;
        log_sample.readings = { 20.0 + static_cast<double>(i), 21.0 + static_cast<double>(i), 22.0 + static_cast<double>(i) };

        check(log_writer.write(log_sample), "SensorLogDataWriter::write");
        std::printf("  wrote log %d: %s\n", i, log_sample.log_message.c_str());
        usleep(200 * 1000);
    }

    // Give the last samples time to actually go out over the wire before
    // tearing everything down.
    sleep(1);

    noalloc_guard_try_disarm();
    std::printf("publisher: done\n");
    return 0;
}
