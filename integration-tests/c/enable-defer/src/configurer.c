/*
 * integration-tests/c/enable-defer -- configurer.
 *
 * The entity under test: builds a Publisher and DataWriter tree with
 * ENTITY_FACTORY QoS (autoenable_created_entities = false) set on the
 * participant and on the Publisher, so both the Publisher and its DataWriter
 * come in disabled -- a "configuration phase" where the app finishes wiring
 * QoS/listeners before going live, and a half-configured entity is never
 * visible to peers in the meantime. See docs/design/integration-test-tier.md
 * for the full scenario spec.
 *
 * Core assertions: a write() on the still-disabled writer returns
 * RETCODE_NOT_ENABLED; enabling the writer before its own Publisher returns
 * RETCODE_PRECONDITION_NOT_MET; enabling the Publisher then the writer
 * succeeds and triggers the previously-deferred SEDP announcement, after
 * which normal matching and data exchange proceed.
 *
 * Required stdout markers: "Create topic: ConfigTopic", "Create writer for
 * topic: ConfigTopic", "Configurer: write on disabled writer correctly
 * returned NOT_ENABLED.", "Configurer: enabling writer before publisher
 * correctly returned PRECONDITION_NOT_MET.", "Configurer: done." Any failure
 * path prints a line starting "FAIL:" and exits nonzero.
 */
#include "config_event.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_COUNT 5
#define PRE_ENABLE_DELAY_SEC 4
#define READER_READY_TIMEOUT_MS 20000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_bool reader_ready;
    atomic_int matched_current_count;
    atomic_bool ever_matched;
} WriterSyncState;

static void on_publication_matched_ex(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    WriterSyncState *state = (WriterSyncState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
    if (status->current_count > 0) atomic_store(&state->ever_matched, true);
}

static void on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void *listener_data) {
    (void)reader_handle;
    WriterSyncState *state = (WriterSyncState *)listener_data;
    if (is_ready) atomic_store(&state->reader_ready, true);
}

static int set_writer_listener_ex(DDS_DataWriter dw, WriterSyncState *state) {
    zzdds_DataWriter zdw = DDS_DataWriter_as_zzdds_DataWriter(dw);
    zzdds_DataWriterListenerEx listener_ex;
    memset(&listener_ex, 0, sizeof(listener_ex));
    listener_ex.listener_data = state;
    listener_ex.on_publication_matched = on_publication_matched_ex;
    listener_ex.on_reliable_reader_ready = on_reliable_reader_ready;
    return zzdds_DataWriter_set_listener_ex(zdw, &listener_ex, DDS_PUBLICATION_MATCHED_STATUS);
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

    /* Participant created normally (enabled) -- only ITS CHILDREN start
     * disabled, per ENTITY_FACTORY QoS semantics. */
    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, domain_id, NULL, NULL, 0);
    if (!dp) {
        fprintf(stderr, "FAIL: create_participant() failed on domain %u\n", domain_id);
        return 1;
    }

    /* Get-mutate-set, not a from-scratch QoS literal -- avoids clobbering any
     * other participant QoS field (see examples/c/shape's shape_main.c fix
     * in Phase A's history for why a zeroed/from-scratch QoS struct is risky
     * now that entity_factory genuinely defaults true). */
    DDS_DomainParticipantQos dp_qos;
    if (DDS_DomainParticipant_get_qos(dp, &dp_qos) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_qos(participant) failed\n");
        return 1;
    }
    dp_qos.entity_factory.autoenable_created_entities = false;
    if (DDS_DomainParticipant_set_qos(dp, &dp_qos) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_qos(participant, autoenable=false) failed\n");
        return 1;
    }

    if (ConfigEventTypeSupport_register(dp, "ConfigEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register ConfigEventTypeSupport failed\n");
        return 1;
    }

    /* Topics have no wire footprint of their own -- creating one here is
     * unaffected either way. */
    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "ConfigTopic", "ConfigEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic(ConfigTopic) failed\n");
        return 1;
    }
    printf("Create topic: ConfigTopic\n");

    /* Publisher comes in disabled (participant's entity_factory QoS above). */
    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_PublisherQos pub_qos;
    if (DDS_Publisher_get_qos(pub, &pub_qos) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_qos(publisher) failed\n");
        return 1;
    }
    pub_qos.entity_factory.autoenable_created_entities = false;
    if (DDS_Publisher_set_qos(pub, &pub_qos) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_qos(publisher, autoenable=false) failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    /* DataWriter comes in disabled (publisher's entity_factory QoS above). */
    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Create writer for topic: ConfigTopic\n");

    WriterSyncState writer_state;
    memset(&writer_state, 0, sizeof(writer_state));
    if (set_writer_listener_ex(dw, &writer_state) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener_ex(ConfigTopic writer) failed\n");
        return 1;
    }

    ConfigEventDataWriter writer;
    ConfigEventDataWriter_init(&writer, dw, ZIDL_XCDR1);

    /* Core assertion #1: write() on a still-disabled writer must fail with
     * NOT_ENABLED, not silently succeed. */
    ConfigEvent probe_ev;
    memset(&probe_ev, 0, sizeof(probe_ev));
    probe_ev.seq = -1;
    DDS_ReturnCode_t probe_rc = ConfigEventDataWriter_write(&writer, &probe_ev, DDS_HANDLE_NIL);
    if (probe_rc != DDS_RETCODE_NOT_ENABLED) {
        fprintf(stderr, "FAIL: write() on disabled writer returned %d, expected RETCODE_NOT_ENABLED (%d)\n", probe_rc, DDS_RETCODE_NOT_ENABLED);
        return 1;
    }
    printf("Configurer: write on disabled writer correctly returned NOT_ENABLED.\n");

    /* Deliberate wall-clock window -- not a race-avoidance hack. This just
     * gives the peer process a comfortable, unambiguous stretch of real time
     * to independently confirm zero premature matching before anything here
     * is enabled; the peer controls its own assertion window on its own
     * clock, this delay only makes sure there's real room for it. */
    sleep(PRE_ENABLE_DELAY_SEC);

    /* Core assertion #2: enabling the writer before its own Publisher must
     * fail with PRECONDITION_NOT_MET (spec: can't enable a child before its
     * factory entity). */
    DDS_ReturnCode_t rc = DDS_DataWriter_enable(dw);
    if (rc != DDS_RETCODE_PRECONDITION_NOT_MET) {
        fprintf(stderr, "FAIL: writer.enable() before publisher.enable() returned %d, expected RETCODE_PRECONDITION_NOT_MET (%d)\n", rc, DDS_RETCODE_PRECONDITION_NOT_MET);
        return 1;
    }
    printf("Configurer: enabling writer before publisher correctly returned PRECONDITION_NOT_MET.\n");

    rc = DDS_Publisher_enable(pub);
    if (rc != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: publisher.enable() returned %d, expected RETCODE_OK\n", rc);
        return 1;
    }
    rc = DDS_DataWriter_enable(dw);
    if (rc != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: writer.enable() returned %d after publisher.enable(), expected RETCODE_OK\n", rc);
        return 1;
    }
    printf("Configurer: enabled publisher then writer.\n");

    for (int waited_ms = 0; !atomic_load(&writer_state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds of enabling\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        ConfigEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (ConfigEventDataWriter_write(&writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write() failed at seq=%d after enabling\n", seq);
            return 1;
        }
    }
    printf("Configurer: wrote %d samples after enabling.\n", SAMPLE_COUNT);

    /* Standard teardown-safety: wait for the peer to unmatch/drain before
     * deleting, matching raw-loan's precedent. */
    for (int waited_ms = 0; atomic_load(&writer_state.matched_current_count) != 0 || !atomic_load(&writer_state.ever_matched); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Configurer: done.\n");

    DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    zzdds_destroy_factory(factory);
    return 0;
}
