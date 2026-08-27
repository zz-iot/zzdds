/*
 * c/registry -- publisher. Direct C port of zig/registry/publisher.zig; see
 * docs/design/registry-reference-app.md at the repo root for the full spec.
 * Walks three instances through three different explicit lifecycles:
 * register_instance() -> write() x2 -> dispose() (instance A),
 * register_instance() -> write_w_timestamp() -> unregister() (instance B),
 * register_instance() -> write() left alive (instance C) -- then confirms
 * get_key_value() rounds the handle it got for instance A back to the
 * right key.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: registered instance sensor_id=",
 * "Publisher: wrote sensor_id=", "Publisher: disposed sensor_id=",
 * "Publisher: unregistered sensor_id=", "Publisher: get_key_value
 * round-trip OK for sensor_id=", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "registry_sample.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

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
    printf("Create writer for topic: SensorReading\n");

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

    SensorReadingDataWriter writer;
    SensorReadingDataWriter_init(&writer, dw, ZIDL_XCDR1);

    for (int waited_ms = 0; !atomic_load(&state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    /* -- Instance A (sensor_id=1): register -> write x2 -> dispose -- */
    SensorReading key_a;
    memset(&key_a, 0, sizeof(key_a));
    key_a.sensor_id = 1;
    DDS_InstanceHandle_t handle_a = SensorReadingDataWriter_register_instance(&writer, &key_a);
    printf("Publisher: registered instance sensor_id=1\n");

    SensorReading sample_a1;
    memset(&sample_a1, 0, sizeof(sample_a1));
    sample_a1.sensor_id = 1;
    sample_a1.value = 100;
    if (SensorReadingDataWriter_write(&writer, &sample_a1, handle_a) != 0) {
        fprintf(stderr, "FAIL: write() failed for sensor_id=1\n");
        return 1;
    }
    printf("Publisher: wrote sensor_id=1 value=100\n");

    SensorReading sample_a2;
    memset(&sample_a2, 0, sizeof(sample_a2));
    sample_a2.sensor_id = 1;
    sample_a2.value = 101;
    if (SensorReadingDataWriter_write(&writer, &sample_a2, handle_a) != 0) {
        fprintf(stderr, "FAIL: write() failed for sensor_id=1\n");
        return 1;
    }
    printf("Publisher: wrote sensor_id=1 value=101\n");

    if (SensorReadingDataWriter_dispose(&writer, &key_a, handle_a) != 0) {
        fprintf(stderr, "FAIL: dispose() failed for sensor_id=1\n");
        return 1;
    }
    printf("Publisher: disposed sensor_id=1\n");

    /* -- Instance B (sensor_id=2): register -> write_w_timestamp -> unregister -- */
    SensorReading key_b;
    memset(&key_b, 0, sizeof(key_b));
    key_b.sensor_id = 2;
    DDS_InstanceHandle_t handle_b = SensorReadingDataWriter_register_instance(&writer, &key_b);
    printf("Publisher: registered instance sensor_id=2\n");

    struct timespec now;
    clock_gettime(CLOCK_REALTIME, &now);
    DDS_Time_t ts;
    ts.sec = (int32_t)now.tv_sec;
    ts.nanosec = (uint32_t)now.tv_nsec;

    SensorReading sample_b;
    memset(&sample_b, 0, sizeof(sample_b));
    sample_b.sensor_id = 2;
    sample_b.value = 200;
    if (SensorReadingDataWriter_write_w_timestamp(&writer, &sample_b, handle_b, ts) != 0) {
        fprintf(stderr, "FAIL: write_w_timestamp() failed for sensor_id=2\n");
        return 1;
    }
    printf("Publisher: wrote sensor_id=2 value=200\n");

    if (SensorReadingDataWriter_unregister(&writer, &key_b, handle_b) != 0) {
        fprintf(stderr, "FAIL: unregister() failed for sensor_id=2\n");
        return 1;
    }
    printf("Publisher: unregistered sensor_id=2\n");

    /* -- Instance C (sensor_id=3): register -> write, left alive -- */
    SensorReading key_c;
    memset(&key_c, 0, sizeof(key_c));
    key_c.sensor_id = 3;
    DDS_InstanceHandle_t handle_c = SensorReadingDataWriter_register_instance(&writer, &key_c);
    printf("Publisher: registered instance sensor_id=3\n");

    SensorReading sample_c;
    memset(&sample_c, 0, sizeof(sample_c));
    sample_c.sensor_id = 3;
    sample_c.value = 300;
    if (SensorReadingDataWriter_write(&writer, &sample_c, handle_c) != 0) {
        fprintf(stderr, "FAIL: write() failed for sensor_id=3\n");
        return 1;
    }
    printf("Publisher: wrote sensor_id=3 value=300\n");

    /* -- get_key_value() round-trip on instance A's handle -- */
    SensorReading key_holder;
    memset(&key_holder, 0, sizeof(key_holder));
    if (SensorReadingDataWriter_get_key_value(&writer, handle_a, &key_holder) != 0) {
        fprintf(stderr, "FAIL: get_key_value() failed for sensor_id=1\n");
        return 1;
    }
    if (key_holder.sensor_id != 1) {
        fprintf(stderr, "FAIL: get_key_value() round-trip mismatch: expected sensor_id=1, got sensor_id=%d\n", key_holder.sensor_id);
        return 1;
    }
    printf("Publisher: get_key_value round-trip OK for sensor_id=1\n");

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
