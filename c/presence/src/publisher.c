/*
 * c/presence -- publisher. Direct C port of zig/presence/publisher.zig; see
 * docs/design/presence-reference-app.md at the repo root for the full spec.
 * Demonstrates MANUAL_BY_TOPIC_LIVELINESS_QOS: writes for a while,
 * deliberately goes quiet (no writes, no asserts) for longer than its own
 * lease_duration, then calls DDS_DataWriter_assert_liveliness() explicitly
 * before resuming.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: wrote sequence=", "Publisher: going
 * offline", "Publisher: asserting liveliness and resuming", "Publisher:
 * done." Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "presence_sample.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ONLINE_BEACON_COUNT 8
#define BEACON_PERIOD_MS 500
#define LEASE_DURATION_S 2
#define OFFLINE_DURATION_MS 5000 /* > LEASE_DURATION_S */
#define READER_READY_TIMEOUT_MS 10000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_bool reader_ready;
    atomic_bool ever_matched;
    atomic_int matched_current_count;
} PubState;

static void on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void *listener_data) {
    (void)reader_handle;
    PubState *state = (PubState *)listener_data;
    if (is_ready) atomic_store(&state->reader_ready, true);
    printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
}

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    PubState *state = (PubState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
    if (status->current_count > 0) atomic_store(&state->ever_matched, true);
    printf("on_publication_matched() current_count=%d\n", status->current_count);
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

    if (zzdds_register_type_support(dp, "PresenceBeacon", PresenceBeacon_compute_key_hash_from_cdr, PresenceBeacon_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "PresenceBeacon", "PresenceBeacon", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: PresenceBeacon\n");

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
    dw_qos.history.depth = 1;
    dw_qos.liveliness.kind = DDS_LivelinessQosPolicyKind_MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dw_qos.liveliness.lease_duration.sec = LEASE_DURATION_S;
    dw_qos.liveliness.lease_duration.nanosec = 0;

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Create writer for topic: PresenceBeacon\n");

    PubState state;
    atomic_init(&state.reader_ready, false);
    atomic_init(&state.ever_matched, false);
    atomic_init(&state.matched_current_count, 0);

    zzdds_DataWriter zdw = DDS_DataWriter_as_zzdds_DataWriter(dw);
    zzdds_DataWriterListenerEx listener_ex;
    memset(&listener_ex, 0, sizeof(listener_ex));
    listener_ex.listener_data = &state;
    listener_ex.on_publication_matched = on_publication_matched;
    listener_ex.on_reliable_reader_ready = on_reliable_reader_ready;
    if (zzdds_DataWriter_set_listener_ex(zdw, &listener_ex, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    PresenceBeaconDataWriter writer;
    PresenceBeaconDataWriter_init(&writer, dw, ZIDL_XCDR1);

    for (int waited_ms = 0; !atomic_load(&state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    /* -- Online phase -- */
    int seq = 0;
    for (; seq < ONLINE_BEACON_COUNT; seq++) {
        PresenceBeacon sample;
        memset(&sample, 0, sizeof(sample));
        sample.seq_num = seq;
        if (PresenceBeaconDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at sequence=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote sequence=%d\n", seq);
        usleep(BEACON_PERIOD_MS * 1000);
    }

    /* -- Offline phase: no writes, no asserts, longer than the lease -- */
    printf("Publisher: going offline (no writes/asserts for %ds, lease is %ds)\n",
           OFFLINE_DURATION_MS / 1000, LEASE_DURATION_S);
    usleep(OFFLINE_DURATION_MS * 1000);

    /* -- Recovery -- */
    printf("Publisher: asserting liveliness and resuming\n");
    if (DDS_DataWriter_assert_liveliness(dw) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: assert_liveliness() failed\n");
        return 1;
    }

    for (; seq < ONLINE_BEACON_COUNT * 2; seq++) {
        PresenceBeacon sample;
        memset(&sample, 0, sizeof(sample));
        sample.seq_num = seq;
        if (PresenceBeaconDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at sequence=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote sequence=%d\n", seq);
        usleep(BEACON_PERIOD_MS * 1000);
    }

    for (int waited_ms = 0;
         !(atomic_load(&state.ever_matched) && atomic_load(&state.matched_current_count) == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Publisher: done.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
