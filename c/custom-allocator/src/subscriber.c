/*
 * Milestone 1 custom-allocator showcase: subscribes to SensorSample values over real
 * UDP DDS discovery, using a fixed-size static-pool allocator for every
 * allocation the factory and everything it creates makes -- no libc
 * malloc/free anywhere in this process's steady-state receive loop.
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
#define EXPECTED_SAMPLES 10
#define EXPECTED_LOGS 5
#define MAX_WAIT_SECONDS 20

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
    /* Needed for SensorLog: decoding its unbounded string/sequence fields
     * allocates via zidl_cdr_alloc, which routes through this registered
     * allocator instead of libc malloc (Phase 2's read-side CDR allocator
     * injection). SensorSample never needs this -- it has no unbounded
     * fields to decode. */
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

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber returned NULL\n");
        return 1;
    }

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, NULL, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader returned NULL\n");
        return 1;
    }

    SensorSampleDataReader typed_reader;
    SensorSampleDataReader_init(&typed_reader, dr);

    check(zzdds_register_type_support(dp, "SensorLog", SensorLog_compute_key_hash_from_cdr, SensorLog_get_field_from_cdr),
          "register_type_support (SensorLog)");

    DDS_Topic log_topic = DDS_DomainParticipant_create_topic(dp, "SensorLogTopic", "SensorLog", NULL, NULL, 0);
    if (!log_topic) {
        fprintf(stderr, "FAIL: create_topic (SensorLog) returned NULL\n");
        return 1;
    }

    DDS_TopicDescription log_topic_desc = zzdds_topic_as_description(log_topic);
    DDS_DataReader log_dr = DDS_Subscriber_create_datareader(sub, log_topic_desc, NULL, NULL, 0);
    if (!log_dr) {
        fprintf(stderr, "FAIL: create_datareader (SensorLog) returned NULL\n");
        return 1;
    }

    SensorLogDataReader log_reader;
    SensorLogDataReader_init(&log_reader, log_dr);

    /* Give discovery/matching a moment to settle before arming the guard:
     * SPDP/SEDP built-in discovery endpoints spawn a heartbeat thread per
     * newly matched remote participant (via std.Thread.spawn), and Zig's
     * own stdlib hardcodes std.heap.c_allocator for that spawn's bookkeeping
     * on the libc/pthread backend -- SpawnConfig.allocator is silently
     * ignored there, so this allocation isn't something zzdds can route
     * through the injected allocator. It's a one-time, bounded,
     * per-newly-discovered-peer cost though, not a per-sample hot-path one,
     * so it belongs before arming, same as factory/entity bootstrap. */
    sleep(2);

    noalloc_guard_try_arm();

    printf("subscriber: waiting for up to %d samples on domain %d (timeout %ds)...\n",
           EXPECTED_SAMPLES, DOMAIN_ID, MAX_WAIT_SECONDS);

    int received = 0;
    for (int elapsed_ms = 0; elapsed_ms < MAX_WAIT_SECONDS * 1000 && received < EXPECTED_SAMPLES; elapsed_ms += 50) {
        /* SensorSampleDataReader_take returns DDS_RETCODE_OK (0) for a real
         * sample and DDS_RETCODE_NO_DATA when the queue is empty -- no
         * longer ambiguous (used to collide: both empty-queue and a
         * successfully-deserialized sample returned 0, before
         * zzdds_take_one_raw's own retcode convention was normalized -- see
         * zidl's docs/roadmap.md "Binding design review: decision"). Still
         * checking info.valid_data too, defensively: it's zeroed first so a
         * dispose/unregister-only sample (key data, no real payload) is
         * never misread as one with real data. */
        SensorSample out;
        zzdds_sample_info info;
        memset(&out, 0, sizeof(out));
        memset(&info, 0, sizeof(info));
        uint8_t buf[256];
        size_t cdr_len = 0;
        int rc = SensorSampleDataReader_take(&typed_reader, &out, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_OK && info.valid_data) {
            printf("  received sample: id=%u temp=%.1fC label=%s\n",
                   out.sensor_id, out.temperature_c, out.label);
            received++;
            continue; /* check for more immediately, no sleep */
        }
        usleep(50 * 1000);
    }

    int received_logs = 0;
    for (int elapsed_ms = 0; elapsed_ms < MAX_WAIT_SECONDS * 1000 && received_logs < EXPECTED_LOGS; elapsed_ms += 50) {
        SensorLog out;
        zzdds_sample_info info;
        memset(&out, 0, sizeof(out));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;
        int rc = SensorLogDataReader_take(&log_reader, &out, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_OK && info.valid_data) {
            printf("  received log: id=%u message=\"%s\" readings=[", out.sensor_id, out.log_message);
            for (uint32_t i = 0; i < out.readings._length; i++) {
                printf("%s%.1f", i == 0 ? "" : ", ", out.readings._buffer[i]);
            }
            printf("]\n");
            /* out.log_message and out.readings._buffer were heap-allocated
             * during decode (via the registered allocator) -- must be freed
             * here, or every received sample leaks. */
            SensorLog_free(&out);
            received_logs++;
            continue;
        }
        usleep(50 * 1000);
    }

    noalloc_guard_try_disarm();
    zzdds_destroy_factory(factory);

    if (received == 0) {
        fprintf(stderr, "FAIL: received 0 samples (expected %d) -- discovery or transport problem\n",
                EXPECTED_SAMPLES);
        return 1;
    }
    if (received_logs == 0) {
        fprintf(stderr, "FAIL: received 0 log samples (expected %d)\n", EXPECTED_LOGS);
        return 1;
    }
    printf("subscriber: done, received %d/%d samples, %d/%d logs\n",
           received, EXPECTED_SAMPLES, received_logs, EXPECTED_LOGS);
    return 0;
}
