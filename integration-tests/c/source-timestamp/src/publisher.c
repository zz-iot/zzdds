/*
 * integration-tests/c/source-timestamp -- publisher. Writes 5 samples via
 * write_w_timestamp() with deliberately fabricated, deterministic explicit
 * timestamps (seconds since epoch ~11.5 days in, nowhere near "now" in any
 * plausible real run -- seq 0..4 map to WRITE_BASE_SEC+seq exactly), then
 * disposes the instance via dispose_w_timestamp() with its own distinct
 * explicit timestamp (a different base, plus a nonzero nanosecond
 * component, to prove nanosecond-granularity propagation too). See
 * docs/design/integration-test-tier.md for the full scenario spec and
 * subscriber.c for the assertions themselves -- this side just drives the
 * writes on a fixed schedule.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Publisher: wrote seq=... with explicit timestamp", "Publisher: disposed
 * instance with explicit timestamp", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "timestamp_event.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_COUNT 5
#define WRITE_BASE_SEC 1000000
#define DISPOSE_SEC 2000000
#define DISPOSE_NSEC 123456789u
#define MATCH_TIMEOUT_MS 20000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_int matched_current_count;
} PubState;

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    PubState *state = (PubState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
}

static uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) {
            return (uint32_t)strtoul(argv[i + 1], NULL, 10);
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    uint32_t domain_id = parse_domain(argc, argv);

    zzdds_DomainParticipantFactory factory = zzdds_create_factory();
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: createFactory() failed\n");
        return 1;
    }
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, domain_id, NULL, NULL, 0);
    if (!dp) {
        fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }

    if (TimestampEventTypeSupport_register(dp, "TimestampEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "TimestampEvent", "TimestampEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: TimestampEvent\n");
    fflush(stdout);

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Create writer for topic: TimestampEvent\n");
    fflush(stdout);

    PubState state;
    atomic_init(&state.matched_current_count, 0);
    DDS_DataWriterListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_publication_matched = on_publication_matched;
    if (DDS_DataWriter_set_listener(dw, &listener, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    TimestampEventDataWriter writer;
    TimestampEventDataWriter_init(&writer, dw, ZIDL_XCDR1);

    for (int waited_ms = 0; atomic_load(&state.matched_current_count) < 1; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reader matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    TimestampEvent key;
    memset(&key, 0, sizeof(key));
    key.id = 0;
    DDS_InstanceHandle_t handle = TimestampEventDataWriter_register_instance(&writer, &key);

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        TimestampEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.id = 0;
        ev.seq = seq;
        DDS_Time_t ts;
        ts.sec = WRITE_BASE_SEC + seq;
        ts.nanosec = 0;
        if (TimestampEventDataWriter_write_w_timestamp(&writer, &ev, handle, ts) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write_w_timestamp() failed at seq=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote seq=%d with explicit timestamp sec=%d\n", seq, ts.sec);
        fflush(stdout);
    }

    DDS_Time_t dispose_ts;
    dispose_ts.sec = DISPOSE_SEC;
    dispose_ts.nanosec = DISPOSE_NSEC;
    if (TimestampEventDataWriter_dispose_w_timestamp(&writer, &key, handle, dispose_ts) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: dispose_w_timestamp() failed\n");
        return 1;
    }
    printf("Publisher: disposed instance with explicit timestamp sec=%d nanosec=%u\n", dispose_ts.sec, dispose_ts.nanosec);
    fflush(stdout);

    for (int waited_ms = 0; atomic_load(&state.matched_current_count) != 0; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Publisher: done.\n");
    fflush(stdout);
    zzdds_destroy_factory(factory);
    return 0;
}
