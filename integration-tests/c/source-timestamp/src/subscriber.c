/*
 * integration-tests/c/source-timestamp -- subscriber (the entity under
 * test). Verifies that write_w_timestamp()/dispose_w_timestamp()'s
 * explicit, caller-supplied timestamps genuinely propagate end-to-end to
 * SampleInfo.source_timestamp on the receiving side -- not silently
 * replaced with "now" at send or receive time. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * The assertion is deliberately an *exact* match, not "close to now" or
 * "monotonically increasing": the publisher's explicit timestamps
 * (WRITE_BASE_SEC+seq, ~11.5 days since the epoch) are nowhere near
 * whatever the actual wall-clock time is during a real test run (some
 * multi-billion-second value in 2026), so any bug that silently substitutes
 * a real clock reading instead of honoring the caller's explicit value
 * shows up immediately and unambiguously as a wildly wrong assertion
 * failure, not a flaky near-miss.
 *
 * register_instance_w_timestamp()'s timestamp is a documented, deliberate
 * no-op in zidl (delegates straight to plain register_instance() --
 * covered by zidl's own backend unit tests), so this scenario doesn't
 * duplicate that coverage; write_w_timestamp() and dispose_w_timestamp()
 * share the identical wire-timestamp plumbing in zzdds core
 * (writer.zig's vtWriteRaw/rtpsTimestampFromRaw, keyed only by WriteKind),
 * so exercising both is a real, non-redundant check on that shared path,
 * not two independent implementations that happened to both need testing.
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: ready.", "Subscriber: received seq=... with source_timestamp
 * sec=... matching the explicit write timestamp.", "Subscriber: received
 * disposed instance with source_timestamp matching the explicit dispose
 * timestamp.", "Subscriber: done." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
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
#define RECEIVE_TIMEOUT_MS 20000
#define POLL_PERIOD_MS 20

typedef struct {
    TimestampEventDataReader *reader;
    atomic_bool alive_received[SAMPLE_COUNT];
    atomic_int alive_count;
    atomic_bool dispose_received;
    atomic_bool dispose_timestamp_ok;
} SubState;

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;
    for (;;) {
        TimestampEvent value;
        DDS_SampleInfo info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[256];
        size_t cdr_len = 0;
        int rc = TimestampEventDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }

        if (info.valid_data) {
            if (value.seq < 0 || value.seq >= SAMPLE_COUNT) {
                fprintf(stderr, "FAIL: unexpected seq=%d\n", value.seq);
                exit(1);
            }
            if (info.source_timestamp.sec != WRITE_BASE_SEC + value.seq || info.source_timestamp.nanosec != 0) {
                fprintf(stderr, "FAIL: seq=%d source_timestamp sec=%d nanosec=%u does not match expected sec=%d nanosec=0\n",
                        value.seq, info.source_timestamp.sec, info.source_timestamp.nanosec, WRITE_BASE_SEC + value.seq);
                exit(1);
            }
            printf("Subscriber: received seq=%d with source_timestamp sec=%d matching the explicit write timestamp.\n", value.seq, info.source_timestamp.sec);
            fflush(stdout);
            if (!atomic_load(&state->alive_received[value.seq])) {
                atomic_store(&state->alive_received[value.seq], true);
                atomic_fetch_add(&state->alive_count, 1);
            }
        } else if (info.instance_state == DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE) {
            atomic_store(&state->dispose_received, true);
            if (info.source_timestamp.sec == DISPOSE_SEC && info.source_timestamp.nanosec == DISPOSE_NSEC) {
                atomic_store(&state->dispose_timestamp_ok, true);
            } else {
                fprintf(stderr, "FAIL: disposed-instance source_timestamp sec=%d nanosec=%u does not match expected sec=%d nanosec=%u\n",
                        info.source_timestamp.sec, info.source_timestamp.nanosec, DISPOSE_SEC, DISPOSE_NSEC);
                exit(1);
            }
        }
        /* Other invalid-data kinds (e.g. NOT_ALIVE_NO_WRITERS) are outside this scenario's scope; ignored. */
    }
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

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    SubState state;
    memset(&state, 0, sizeof(state));
    for (int i = 0; i < SAMPLE_COUNT; i++) atomic_init(&state.alive_received[i], false);
    atomic_init(&state.alive_count, 0);
    atomic_init(&state.dispose_received, false);
    atomic_init(&state.dispose_timestamp_ok, false);

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: TimestampEvent\n");
    fflush(stdout);

    TimestampEventDataReader reader;
    TimestampEventDataReader_init(&reader, dr);
    state.reader = &reader;

    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_data_available = on_data_available;
    if (DDS_DataReader_set_listener(dr, &listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    printf("Subscriber: ready.\n");
    fflush(stdout);

    for (int waited_ms = 0; atomic_load(&state.alive_count) < SAMPLE_COUNT || !atomic_load(&state.dispose_received); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: only received %d/%d alive samples and dispose_received=%d within %ds\n",
                    atomic_load(&state.alive_count), SAMPLE_COUNT, atomic_load(&state.dispose_received), RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    if (!atomic_load(&state.dispose_timestamp_ok)) {
        fprintf(stderr, "FAIL: dispose sample was received but its timestamp never matched (should have exited already)\n");
        return 1;
    }
    printf("Subscriber: received disposed instance with source_timestamp matching the explicit dispose timestamp.\n");
    fflush(stdout);

    printf("Subscriber: done.\n");
    fflush(stdout);
    zzdds_destroy_factory(factory);
    return 0;
}
