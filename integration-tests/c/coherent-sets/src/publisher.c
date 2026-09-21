/*
 * integration-tests/c/coherent-sets -- publisher.
 *
 * Publishes GROUP_COUNT ticks. Each tick is one coherent set spanning two
 * DataWriters under one Publisher (PRESENTATION access_scope=GROUP,
 * coherent_access=true, ordered_access=true): write Position, sleep
 * WRITE_GAP_MS, write Velocity, end the coherent set. The gap matters --
 * see subscriber.c's comment on why. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * Required stdout markers: "Create topic:" x2, "Create writer for topic:"
 * x2, "Publisher: wrote group N", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "pose_group.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define GROUP_COUNT 20
#define WRITE_GAP_US (8 * 1000)
#define READER_READY_TIMEOUT_MS 10000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_bool reader_ready;
    atomic_bool ever_matched;
    atomic_int matched_current_count;
} WriterSyncState;

static void on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void *listener_data) {
    (void)reader_handle;
    WriterSyncState *state = (WriterSyncState *)listener_data;
    if (is_ready) atomic_store(&state->reader_ready, true);
}

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    WriterSyncState *state = (WriterSyncState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
    if (status->current_count > 0) atomic_store(&state->ever_matched, true);
}

static uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) {
            return (uint32_t)strtoul(argv[i + 1], NULL, 10);
        }
    }
    return 0;
}

static int set_writer_listener(DDS_DataWriter dw, WriterSyncState *state) {
    zzdds_DataWriter zdw = DDS_DataWriter_as_zzdds_DataWriter(dw);
    zzdds_DataWriterListenerEx listener_ex;
    memset(&listener_ex, 0, sizeof(listener_ex));
    listener_ex.listener_data = state;
    listener_ex.on_publication_matched = on_publication_matched;
    listener_ex.on_reliable_reader_ready = on_reliable_reader_ready;
    return zzdds_DataWriter_set_listener_ex(zdw, &listener_ex, DDS_PUBLICATION_MATCHED_STATUS);
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

    if (PositionTypeSupport_register(dp, "Position") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register PositionTypeSupport failed\n");
        return 1;
    }
    if (VelocityTypeSupport_register(dp, "Velocity") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register VelocityTypeSupport failed\n");
        return 1;
    }

    DDS_Topic position_topic = DDS_DomainParticipant_create_topic(dp, "Position", "Position", NULL, NULL, 0);
    if (!position_topic) {
        fprintf(stderr, "FAIL: create_topic(Position) failed\n");
        return 1;
    }
    printf("Create topic: Position\n");

    DDS_Topic velocity_topic = DDS_DomainParticipant_create_topic(dp, "Velocity", "Velocity", NULL, NULL, 0);
    if (!velocity_topic) {
        fprintf(stderr, "FAIL: create_topic(Velocity) failed\n");
        return 1;
    }
    printf("Create topic: Velocity\n");

    DDS_PublisherQos pub_qos;
    DDS_DomainParticipant_get_default_publisher_qos(dp, &pub_qos);
    pub_qos.presentation.access_scope = DDS_PresentationQosPolicyAccessScopeKind_GROUP_PRESENTATION_QOS;
    pub_qos.presentation.coherent_access = true;
    pub_qos.presentation.ordered_access = true;

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, &pub_qos, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter position_dw = DDS_Publisher_create_datawriter(pub, position_topic, &dw_qos, NULL, 0);
    if (!position_dw) {
        fprintf(stderr, "FAIL: create_datawriter(Position) failed\n");
        return 1;
    }
    printf("Create writer for topic: Position\n");

    DDS_DataWriter velocity_dw = DDS_Publisher_create_datawriter(pub, velocity_topic, &dw_qos, NULL, 0);
    if (!velocity_dw) {
        fprintf(stderr, "FAIL: create_datawriter(Velocity) failed\n");
        return 1;
    }
    printf("Create writer for topic: Velocity\n");

    WriterSyncState position_state, velocity_state;
    memset(&position_state, 0, sizeof(position_state));
    memset(&velocity_state, 0, sizeof(velocity_state));

    if (set_writer_listener(position_dw, &position_state) != DDS_RETCODE_OK ||
        set_writer_listener(velocity_dw, &velocity_state) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    for (int waited_ms = 0;
         !(atomic_load(&position_state.reader_ready) && atomic_load(&velocity_state.reader_ready));
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    PositionDataWriter position_writer;
    PositionDataWriter_init(&position_writer, position_dw, ZIDL_XCDR1);
    VelocityDataWriter velocity_writer;
    VelocityDataWriter_init(&velocity_writer, velocity_dw, ZIDL_XCDR1);

    for (int group_id = 0; group_id < GROUP_COUNT; group_id++) {
        if (DDS_Publisher_begin_coherent_changes(pub) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: begin_coherent_changes() failed at group=%d\n", group_id);
            return 1;
        }

        Position pos;
        memset(&pos, 0, sizeof(pos));
        pos.group_id = group_id;
        pos.x = (double)group_id;
        pos.y = (double)group_id * 2.0;
        if (PositionDataWriter_write(&position_writer, &pos, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: Position write() failed at group=%d\n", group_id);
            return 1;
        }

        /* Deliberate gap: back-to-back writes on loopback UDP often arrive
         * in the same receive burst regardless of whether reader-side
         * coherent-set gating works at all -- this gap is what makes the
         * test capable of catching a broken gate, not just a fast one. */
        usleep(WRITE_GAP_US);

        Velocity vel;
        memset(&vel, 0, sizeof(vel));
        vel.group_id = group_id;
        vel.vx = (double)group_id * 0.5;
        vel.vy = (double)group_id * 1.5;
        if (VelocityDataWriter_write(&velocity_writer, &vel, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: Velocity write() failed at group=%d\n", group_id);
            return 1;
        }

        if (DDS_Publisher_end_coherent_changes(pub) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: end_coherent_changes() failed at group=%d\n", group_id);
            return 1;
        }
        printf("Publisher: wrote group %d\n", group_id);
    }

    printf("Publisher: done.\n");

    for (int waited_ms = 0;
         !(atomic_load(&position_state.ever_matched) && atomic_load(&position_state.matched_current_count) == 0 &&
           atomic_load(&velocity_state.ever_matched) && atomic_load(&velocity_state.matched_current_count) == 0);
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    if (DDS_Publisher_delete_datawriter(pub, position_dw) != DDS_RETCODE_OK ||
        DDS_Publisher_delete_datawriter(pub, velocity_dw) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: delete_datawriter() did not return RETCODE_OK\n");
        return 1;
    }

    zzdds_destroy_factory(factory);
    return 0;
}
