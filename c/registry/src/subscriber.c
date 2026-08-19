/*
 * c/registry -- subscriber. Direct C port of zig/registry/subscriber.zig;
 * see docs/design/registry-reference-app.md at the repo root for the full
 * spec. Tracks each of the publisher's three instances' observed
 * SampleInfo.instance_state sequence (fail fast on an unexpected
 * transition), and once all three have reached their expected outcome,
 * calls lookup_instance() to confirm the key-to-handle direction matches
 * what the publisher's own samples for that instance carried.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: sensor_id=... instance_state=...",
 * "Subscriber: lookup_instance round-trip OK for sensor_id=",
 * "Subscriber: all three instance lifecycles observed correctly." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "registry_sample.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RECEIVE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

static const char *state_name(DDS_InstanceStateKind s) {
    switch (s) {
        case DDS_ALIVE_INSTANCE_STATE: return "ALIVE";
        case DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE: return "NOT_ALIVE_DISPOSED";
        case DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE: return "NOT_ALIVE_NO_WRITERS";
        default: return "UNKNOWN";
    }
}

typedef struct {
    int32_t sensor_id;
    bool seen_alive;
    bool reached_terminal;
    DDS_InstanceHandle_t handle;
} InstanceTrack;

typedef struct {
    SensorReadingDataReader *reader;
    /* Only ever touched from the listener's dispatch thread. */
    InstanceTrack tracks[3];
    atomic_bool all_done;
} SubState;

static InstanceTrack *track_for(SubState *state, int32_t sensor_id) {
    for (int i = 0; i < 3; i++) {
        if (state->tracks[i].sensor_id == sensor_id) return &state->tracks[i];
    }
    fprintf(stderr, "FAIL: unexpected sensor_id=%d\n", sensor_id);
    exit(1);
}

static bool all_instances_done(SubState *state) {
    for (int i = 0; i < 3; i++) {
        if (!state->tracks[i].reached_terminal) return false;
    }
    return true;
}

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;
    /* Deferred, not stored directly inside the loop below: main() deletes
     * the reader as soon as it observes state->all_done, so storing it
     * mid-loop would let main()'s delete_datareader() race this same
     * invocation's next take() call. Only commit the flag once this
     * invocation's take loop has fully drained and won't touch the reader
     * again. */
    bool became_done = false;

    for (;;) {
        SensorReading value;
        zzdds_sample_info info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;

        int rc = SensorReadingDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }

        InstanceTrack *track = track_for(state, value.sensor_id);
        printf("Subscriber: sensor_id=%d instance_state=%s\n", value.sensor_id, state_name(info.instance_state));
        track->handle = info.instance_handle;

        switch (info.instance_state) {
            case DDS_ALIVE_INSTANCE_STATE:
                track->seen_alive = true;
                if (track->sensor_id == 3) track->reached_terminal = true;
                break;
            case DDS_NOT_ALIVE_DISPOSED_INSTANCE_STATE:
                if (track->sensor_id != 1) {
                    fprintf(stderr, "FAIL: unexpected NOT_ALIVE_DISPOSED for sensor_id=%d\n", track->sensor_id);
                    exit(1);
                }
                if (!track->seen_alive) {
                    fprintf(stderr, "FAIL: sensor_id=1 reached NOT_ALIVE_DISPOSED without ever being ALIVE\n");
                    exit(1);
                }
                track->reached_terminal = true;
                break;
            case DDS_NOT_ALIVE_NO_WRITERS_INSTANCE_STATE:
                if (track->sensor_id != 2) {
                    fprintf(stderr, "FAIL: unexpected NOT_ALIVE_NO_WRITERS for sensor_id=%d\n", track->sensor_id);
                    exit(1);
                }
                if (!track->seen_alive) {
                    fprintf(stderr, "FAIL: sensor_id=2 reached NOT_ALIVE_NO_WRITERS without ever being ALIVE\n");
                    exit(1);
                }
                track->reached_terminal = true;
                break;
            default:
                fprintf(stderr, "FAIL: unknown instance_state=%u for sensor_id=%d\n", info.instance_state, track->sensor_id);
                exit(1);
        }

        if (all_instances_done(state) && !atomic_load(&state->all_done) && !became_done) {
            InstanceTrack *c_track = track_for(state, 3);
            SensorReading query;
            memset(&query, 0, sizeof(query));
            query.sensor_id = 3;
            DDS_InstanceHandle_t looked_up = SensorReadingDataReader_lookup_instance(state->reader, &query);
            if (looked_up == 0 || looked_up != c_track->handle) {
                fprintf(stderr, "FAIL: lookup_instance() round-trip mismatch for sensor_id=3\n");
                exit(1);
            }
            printf("Subscriber: lookup_instance round-trip OK for sensor_id=3\n");
            became_done = true;
        }
    }

    if (became_done) {
        atomic_store(&state->all_done, true);
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

    if (zzdds_register_type_support(dp, "SensorReading", SensorReading_compute_key_hash_from_cdr, SensorReading_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "SensorReading", "SensorReading", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: SensorReading\n");

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
    state.tracks[0].sensor_id = 1;
    state.tracks[1].sensor_id = 2;
    state.tracks[2].sensor_id = 3;
    atomic_init(&state.all_done, false);

    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_data_available = on_data_available;

    /* Create with no listener attached yet: on_data_available fires on a
     * zzdds-internal dispatch thread as soon as the reader matches, which
     * can race state.reader's own initialization below. Attach the listener
     * only once state.reader is set, via set_listener() below, closing the
     * window entirely. */
    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: SensorReading\n");

    SensorReadingDataReader reader;
    SensorReadingDataReader_init(&reader, dr);
    state.reader = &reader;

    if (DDS_DataReader_set_listener(dr, &listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    printf("Subscriber: waiting for all three instance lifecycles...\n");
    for (int waited_ms = 0; !atomic_load(&state.all_done); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: did not observe all three instance lifecycles within %ds\n", RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    DDS_Subscriber_delete_datareader(sub, dr);

    printf("Subscriber: all three instance lifecycles observed correctly.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
