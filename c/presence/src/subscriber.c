/*
 * c/presence -- subscriber. Direct C port of zig/presence/subscriber.zig;
 * see docs/design/presence-reference-app.md at the repo root for the full
 * spec. Demonstrates DataReaderListener::on_liveliness_changed: observes
 * the writer's lease expiring (OFFLINE) and later recovering (ONLINE) after
 * an explicit assert_liveliness() call, and asserts the full cycle was seen
 * in order.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "ONLINE alive_count=", "OFFLINE alive_count=",
 * "Subscriber: observed full online -> offline -> online cycle." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "presence_sample.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CYCLE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

typedef enum { PHASE_WAITING_FIRST_ONLINE, PHASE_WAITING_OFFLINE, PHASE_WAITING_SECOND_ONLINE, PHASE_DONE } Phase;

typedef struct {
    PresenceBeaconDataReader *reader;
    /* Only ever touched from the listener's dispatch thread. */
    Phase phase;
    atomic_int step;
    atomic_bool cycle_complete;
} SubState;

static void on_liveliness_changed(DDS_DataReader the_reader, const DDS_LivelinessChangedStatus *status, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;
    bool online = status->alive_count > 0;
    if (online) {
        printf("ONLINE alive_count=%d not_alive_count=%d\n", status->alive_count, status->not_alive_count);
    } else {
        printf("OFFLINE alive_count=%d not_alive_count=%d\n", status->alive_count, status->not_alive_count);
    }

    switch (state->phase) {
    case PHASE_WAITING_FIRST_ONLINE:
        if (online) {
            state->phase = PHASE_WAITING_OFFLINE;
            atomic_store(&state->step, 1);
        }
        break;
    case PHASE_WAITING_OFFLINE:
        if (!online) {
            state->phase = PHASE_WAITING_SECOND_ONLINE;
            atomic_store(&state->step, 2);
        }
        break;
    case PHASE_WAITING_SECOND_ONLINE:
        if (online) {
            state->phase = PHASE_DONE;
            atomic_store(&state->step, 3);
            atomic_store(&state->cycle_complete, true);
        }
        break;
    case PHASE_DONE:
        break;
    }
}

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;

    for (;;) {
        PresenceBeacon value;
        zzdds_sample_info info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;

        int rc = PresenceBeaconDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }
        if (!info.valid_data) continue;

        printf("Subscriber: received sequence=%d\n", value.seq_num);
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

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
    dr_qos.history.depth = 1;
    dr_qos.liveliness.kind = DDS_LivelinessQosPolicyKind_MANUAL_BY_TOPIC_LIVELINESS_QOS;
    dr_qos.liveliness.lease_duration.sec = 2;
    dr_qos.liveliness.lease_duration.nanosec = 0;

    SubState state;
    state.reader = NULL;
    state.phase = PHASE_WAITING_FIRST_ONLINE;
    atomic_init(&state.step, 0);
    atomic_init(&state.cycle_complete, false);

    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_data_available = on_data_available;
    listener.on_liveliness_changed = on_liveliness_changed;

    /* Create with no listener attached yet: on_data_available/
     * on_liveliness_changed fire on a zzdds-internal dispatch thread as soon
     * as the reader matches, which can race state.reader's own
     * initialization below. Attach the listener only once state.reader is
     * set, via set_listener() below, closing the window entirely. */
    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: PresenceBeacon\n");

    PresenceBeaconDataReader reader;
    PresenceBeaconDataReader_init(&reader, dr);
    state.reader = &reader;

    if (DDS_DataReader_set_listener(dr, &listener, DDS_DATA_AVAILABLE_STATUS | DDS_LIVELINESS_CHANGED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    printf("Subscriber: waiting for online -> offline -> online cycle...\n");
    for (int waited_ms = 0; !atomic_load(&state.cycle_complete); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= CYCLE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: did not observe the full cycle within %ds (stuck at step=%d)\n",
                    CYCLE_TIMEOUT_MS / 1000, atomic_load(&state.step));
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    DDS_Subscriber_delete_datareader(sub, dr);

    printf("Subscriber: observed full online -> offline -> online cycle.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
