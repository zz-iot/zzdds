/*
 * Milestone 1 custom-allocator showcase: publishes SensorSample values over real UDP
 * DDS discovery, using a fixed-size static-pool allocator for every
 * allocation the factory and everything it creates makes (participant,
 * topic, publisher, writer, history cache) -- no libc malloc/free anywhere
 * in this process's steady-state publishing loop.
 */
#include "sensor.h"
#include "zzdds_c.h"
#include "static_pool_allocator.h"
#include "noalloc_guard.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define DOMAIN_ID 7
#define SAMPLE_COUNT 10
#define LOG_COUNT 5

static void check(DDS_ReturnCode_t rc, const char *what) {
    if (rc != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: %s (rc=%d)\n", what, (int)rc);
        exit(1);
    }
}

/* Statically buffered (not malloc'd) so stdio's own lazy buffer setup can
 * never trip the noalloc guard once armed below. */
static char g_stdout_buf[8192];

int main(void) {
    setvbuf(stdout, g_stdout_buf, _IOFBF, sizeof(g_stdout_buf));
    static_pool_allocator_reset();
    /* Routes zidl-cdr's own internal buffer growth (the CDR writer's
     * malloc/realloc-backed default) through the same static-pool allocator
     * used for entity bootstrap -- without this, the writer would still grow
     * its scratch buffer via libc realloc regardless of the factory
     * allocator. It's this application's responsibility to size the pool for
     * whatever it serializes. */
    zidl_cdr_set_allocator(&static_pool_allocator);

    /* Resolve+install zzdds.toml as the process-wide config BEFORE creating
     * any factory, through the same static-pool allocator everything else in
     * this process uses. Without this, zzdds_create_factory_with_allocator's
     * own ambient lazy-default resolution (config/process.zig's
     * getForNewFactory) would still route this one-time bootstrap step
     * through libc malloc regardless of the allocator passed to it -- see
     * this README's config-file section. */
    DDS_ReturnCode_t cfg_rc = zzdds_process_configure_from_file("zzdds.toml", &static_pool_allocator);
    if (cfg_rc != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: zzdds_process_configure_from_file (rc=%d)\n", (int)cfg_rc);
        return 1;
    }

    zzdds_DomainParticipantFactory factory = zzdds_create_factory_with_allocator(&static_pool_allocator);
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: zzdds_create_factory_with_allocator returned nil\n");
        return 1;
    }
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, DOMAIN_ID, NULL, NULL, 0);
    if (!dp) {
        fprintf(stderr, "FAIL: create_participant returned NULL\n");
        return 1;
    }

    check(zzdds_register_type_support(dp, "SensorSample", SensorSample_compute_key_hash_from_cdr, SensorSample_get_field_from_cdr),
          "register_type_support");

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "SensorTopic", "SensorSample", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic returned NULL\n");
        return 1;
    }

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher returned NULL\n");
        return 1;
    }

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, NULL, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter returned NULL\n");
        return 1;
    }

    SensorSampleDataWriter typed_writer;
    SensorSampleDataWriter_init(&typed_writer, dw, ZIDL_XCDR1);

    /* Milestone 2: SensorLog has an unbounded string and sequence -- writing
     * it needs no heap at all (the fields just point at this process's own
     * stack data), but it exercises the writer's CDR encoding of unbounded
     * fields on the wire, which the subscriber's decode side (Phase 2's
     * zidl_cdr allocator injection) then has to handle. */
    check(zzdds_register_type_support(dp, "SensorLog", SensorLog_compute_key_hash_from_cdr, SensorLog_get_field_from_cdr),
          "register_type_support (SensorLog)");

    DDS_Topic log_topic = DDS_DomainParticipant_create_topic(dp, "SensorLogTopic", "SensorLog", NULL, NULL, 0);
    if (!log_topic) {
        fprintf(stderr, "FAIL: create_topic (SensorLog) returned NULL\n");
        return 1;
    }

    DDS_DataWriter log_dw = DDS_Publisher_create_datawriter(pub, log_topic, NULL, NULL, 0);
    if (!log_dw) {
        fprintf(stderr, "FAIL: create_datawriter (SensorLog) returned NULL\n");
        return 1;
    }

    SensorLogDataWriter log_writer;
    SensorLogDataWriter_init(&log_writer, log_dw, ZIDL_XCDR1);

    printf("publisher: writing %d samples on domain %d...\n", SAMPLE_COUNT, DOMAIN_ID);

    /* Give discovery a moment to find a matched reader before writing --
     * best-effort QoS (the default) drops samples with no matched reader
     * yet, so a brief wait makes the demo reliably show real delivery. This
     * also lets SPDP/SEDP matching settle: matching a newly discovered
     * remote participant spawns a heartbeat thread via std.Thread.spawn,
     * whose bookkeeping allocation Zig's own stdlib hardcodes to
     * std.heap.c_allocator on the libc/pthread backend (SpawnConfig.allocator
     * is silently ignored there) -- a one-time, bounded, per-newly-matched-peer
     * cost, not a per-sample hot-path one, so it belongs before arming. */
    sleep(2);

    /* All one-time/discovery-adjacent allocation is done -- arm the guard so
     * any further malloc/calloc/realloc/free aborts the process. */
    noalloc_guard_try_arm();

    for (int i = 0; i < SAMPLE_COUNT; i++) {
        SensorSample sample;
        memset(&sample, 0, sizeof(sample));
        sample.sensor_id = 42;
        sample.timestamp_ms = (unsigned long long)i * 1000ULL;
        sample.temperature_c = 20.0 + (double)i * 0.5;
        snprintf(sample.label, sizeof(sample.label), "sensor-%d", i);

        check(SensorSampleDataWriter_write(&typed_writer, &sample, DDS_HANDLE_NIL), "DataWriter_write");
        printf("  wrote sample %d: temp=%.1fC label=%s\n", i, sample.temperature_c, sample.label);
        usleep(200 * 1000);
    }

    printf("publisher: writing %d log samples...\n", LOG_COUNT);
    for (int i = 0; i < LOG_COUNT; i++) {
        char message[64];
        snprintf(message, sizeof(message), "sensor 42 reading batch #%d", i);

        double readings_buf[3] = { 20.0 + i, 21.0 + i, 22.0 + i };

        SensorLog log_sample;
        log_sample.sensor_id = 42;
        log_sample.log_message = message;
        log_sample.readings._buffer = readings_buf;
        log_sample.readings._length = 3;
        log_sample.readings._maximum = 3;
        log_sample.readings._release = false;

        check(SensorLogDataWriter_write(&log_writer, &log_sample, DDS_HANDLE_NIL), "SensorLogDataWriter_write");
        printf("  wrote log %d: %s\n", i, message);
        usleep(200 * 1000);
    }

    /* Give the last samples time to actually go out over the wire before
     * tearing everything down. */
    sleep(1);

    noalloc_guard_try_disarm();
    zzdds_destroy_factory(factory);
    printf("publisher: done\n");
    return 0;
}
