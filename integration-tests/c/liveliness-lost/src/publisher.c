/*
 * integration-tests/c/liveliness-lost -- publisher (the entity under
 * test). Exercises on_liveliness_lost()/get_liveliness_lost_status() --
 * "zero coverage anywhere" per the API audit -- for the two LIVELINESS
 * kinds `presence` (examples/{c,cpp,java,zig}/presence) deliberately left out to keep
 * itself a single-scenario example: AUTOMATIC and MANUAL_BY_PARTICIPANT.
 * `presence` already covers MANUAL_BY_TOPIC, `assert_liveliness()`, and
 * `on_liveliness_changed`'s full ONLINE->OFFLINE->ONLINE recovery cycle;
 * this scenario does not repeat that -- it's a one-way lapse, no recovery,
 * and it targets a sharper, more spec-precise question than "did a writer
 * go silent": *what counts* as a liveliness assertion differs by kind, and
 * it's easy to get backwards.
 *
 * Two DataWriters, same write cadence (every 0.5s), same 2s lease_duration,
 * for the whole ~8s test -- deliberately never calling
 * DomainParticipant_assert_liveliness() or DataWriter_assert_liveliness()
 * at all:
 * - AUTOMATIC: per the DDS spec (and zzdds's own writer.zig comment,
 *   "AUTOMATIC: any write() counts as a liveliness assertion"), each
 *   write() itself refreshes liveliness. Expected: on_liveliness_lost NEVER
 *   fires, despite the same 2s lease as the other writer.
 * - MANUAL_BY_PARTICIPANT: per spec, only an explicit assert_liveliness()
 *   call counts -- write() does not. Expected: on_liveliness_lost DOES
 *   fire at least once, *despite* writing continuously the entire time.
 *   This is the surprising, easy-to-get-backwards case an implementation
 *   bug could plausibly invert (e.g. if write() were mistakenly treated as
 *   sufficient for every kind).
 *
 * Required stdout markers: "Create topic:" x2, "Create writer for topic:"
 * x2, "Publisher: both readers matched.", "Publisher: write loop done.",
 * "Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as
 * expected.", "Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness
 * (total_count=N) despite continuous writing, as expected.", "Publisher:
 * done." Any failure path prints a line starting "FAIL:" and exits
 * nonzero.
 */
#include "liveliness_event.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define LEASE_DURATION_SEC 2
#define WRITE_PERIOD_MS 500
#define WRITE_COUNT 16 /* 16 * 500ms = 8s, comfortably > 4 lease periods */
/* 40s, not the 20s every other match-wait in this tier uses -- this
 * scenario creates *two* writers per process (AUTOMATIC + MANUAL_BY_PARTICIPANT),
 * twice the SEDP discovery work of a typical 1-writer scenario -- see
 * integration-tests/cft-reconfigure's identical precedent/reasoning. */
#define MATCH_TIMEOUT_MS 40000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_int matched_current_count;
    atomic_int liveliness_lost_count;
} WriterState;

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    WriterState *state = (WriterState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
}

static void on_liveliness_lost(DDS_DataWriter writer, const DDS_LivelinessLostStatus *status, void *listener_data) {
    (void)writer;
    (void)status;
    WriterState *state = (WriterState *)listener_data;
    atomic_fetch_add(&state->liveliness_lost_count, 1);
}

static uint32_t parse_domain(int argc, char **argv) {
    for (int i = 1; i < argc - 1; i++) {
        if (strcmp(argv[i], "-d") == 0 || strcmp(argv[i], "--domain") == 0) {
            return (uint32_t)strtoul(argv[i + 1], NULL, 10);
        }
    }
    return 0;
}

static DDS_DataWriter create_writer(DDS_DomainParticipant dp, DDS_Publisher pub, const char *topic_name,
                                     DDS_LivelinessQosPolicyKind kind, WriterState *state) {
    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, topic_name, "LivelinessEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic(%s) failed\n", topic_name);
        return NULL;
    }
    printf("Create topic: %s\n", topic_name);
    fflush(stdout);

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    dw_qos.liveliness.kind = kind;
    dw_qos.liveliness.lease_duration.sec = LEASE_DURATION_SEC;
    dw_qos.liveliness.lease_duration.nanosec = 0;

    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    if (!dw) {
        fprintf(stderr, "FAIL: create_datawriter(%s) failed\n", topic_name);
        return NULL;
    }
    printf("Create writer for topic: %s\n", topic_name);
    fflush(stdout);

    atomic_init(&state->matched_current_count, 0);
    atomic_init(&state->liveliness_lost_count, 0);
    DDS_DataWriterListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = state;
    listener.on_publication_matched = on_publication_matched;
    listener.on_liveliness_lost = on_liveliness_lost;
    if (DDS_DataWriter_set_listener(dw, &listener, DDS_PUBLICATION_MATCHED_STATUS | DDS_LIVELINESS_LOST_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener(%s) failed\n", topic_name);
        return NULL;
    }
    return dw;
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

    if (LivelinessEventTypeSupport_register(dp, "LivelinessEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    WriterState auto_state, manual_state;
    DDS_DataWriter auto_dw = create_writer(dp, pub, "AutomaticLivelinessTopic", DDS_LivelinessQosPolicyKind_AUTOMATIC_LIVELINESS_QOS, &auto_state);
    if (!auto_dw) return 1;
    DDS_DataWriter manual_dw = create_writer(dp, pub, "ManualByParticipantLivelinessTopic", DDS_LivelinessQosPolicyKind_MANUAL_BY_PARTICIPANT_LIVELINESS_QOS, &manual_state);
    if (!manual_dw) return 1;

    LivelinessEventDataWriter auto_writer, manual_writer;
    LivelinessEventDataWriter_init(&auto_writer, auto_dw, ZIDL_XCDR1);
    LivelinessEventDataWriter_init(&manual_writer, manual_dw, ZIDL_XCDR1);

    for (int waited_ms = 0; atomic_load(&auto_state.matched_current_count) < 1 || atomic_load(&manual_state.matched_current_count) < 1; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: readers never matched within %ds\n", MATCH_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Publisher: both readers matched.\n");
    fflush(stdout);

    /* Deliberately never call assert_liveliness() anywhere in this loop --
     * that's the whole point (see this file's header comment). */
    for (int i = 0; i < WRITE_COUNT; i++) {
        LivelinessEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = i;
        if (LivelinessEventDataWriter_write(&auto_writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write(AUTOMATIC) failed at seq=%d\n", i);
            return 1;
        }
        if (LivelinessEventDataWriter_write(&manual_writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write(MANUAL_BY_PARTICIPANT) failed at seq=%d\n", i);
            return 1;
        }
        usleep(WRITE_PERIOD_MS * 1000);
    }
    printf("Publisher: write loop done.\n");
    fflush(stdout);

    DDS_LivelinessLostStatus auto_status, manual_status;
    if (DDS_DataWriter_get_liveliness_lost_status(auto_dw, &auto_status) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_liveliness_lost_status(AUTOMATIC) failed\n");
        return 1;
    }
    if (DDS_DataWriter_get_liveliness_lost_status(manual_dw, &manual_status) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: get_liveliness_lost_status(MANUAL_BY_PARTICIPANT) failed\n");
        return 1;
    }

    if (atomic_load(&auto_state.liveliness_lost_count) != 0 || auto_status.total_count != 0) {
        fprintf(stderr, "FAIL: AUTOMATIC writer lost liveliness (listener_count=%d, status.total_count=%d), expected never\n",
                atomic_load(&auto_state.liveliness_lost_count), auto_status.total_count);
        return 1;
    }
    printf("Publisher: AUTOMATIC writer never lost liveliness (total_count=0), as expected.\n");
    fflush(stdout);

    if (atomic_load(&manual_state.liveliness_lost_count) < 1 || manual_status.total_count < 1) {
        fprintf(stderr, "FAIL: MANUAL_BY_PARTICIPANT writer never lost liveliness (listener_count=%d, status.total_count=%d) despite never asserting it, expected >=1\n",
                atomic_load(&manual_state.liveliness_lost_count), manual_status.total_count);
        return 1;
    }
    printf("Publisher: MANUAL_BY_PARTICIPANT writer lost liveliness (total_count=%d) despite continuous writing, as expected.\n", manual_status.total_count);
    fflush(stdout);

    for (int waited_ms = 0; atomic_load(&auto_state.matched_current_count) != 0 || atomic_load(&manual_state.matched_current_count) != 0; waited_ms += POLL_PERIOD_MS) {
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
