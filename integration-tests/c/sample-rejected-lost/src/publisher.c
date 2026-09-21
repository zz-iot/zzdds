/*
 * integration-tests/c/sample-rejected-lost -- publisher.
 *
 * Three DataWriters under one Publisher, written in this specific order:
 * LostTopic (RELIABLE, KEEP_LAST depth=1, TRANSIENT_LOCAL) gets 5
 * back-to-back writes FIRST, before any reader can possibly be matched to
 * it -- the subscriber deliberately defers creating that reader until
 * after the Sync signal below, so these writes are written and evicted
 * with zero chance of ever being acked (a genuinely, deterministically
 * un-recoverable loss for SNs 1-4, not a race against real-time ack
 * latency -- an earlier version of this scenario tried racing fast writes
 * against an already-matched reader and nothing was ever lost, because
 * localhost round-trips are fast enough that each sample got acked before
 * the next write evicted it). Then RejectedTopic (RELIABLE, KEEP_ALL, no
 * resource limits of its own -- the *reader's* tight resource_limits is
 * what causes rejection) gets 5 back-to-back writes against an
 * already-matched reader. SyncTopic gets one write *after* everything
 * above is done, purely so the subscriber knows it's safe to create the
 * LostTopic reader and check final status without racing the publisher's
 * own writes. See docs/design/integration-test-tier.md for the full
 * scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create writer for topic:"
 * x3, "Publisher: wrote 5 samples on LostTopic...", "Publisher: wrote 5
 * samples on RejectedTopic...", "Publisher: sync sent.", "Publisher: done."
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "status_event.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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

    if (StatusEventTypeSupport_register(dp, "StatusEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register StatusEventTypeSupport failed\n");
        return 1;
    }

    DDS_Topic rejected_topic = DDS_DomainParticipant_create_topic(dp, "RejectedTopic", "StatusEvent", NULL, NULL, 0);
    if (!rejected_topic) {
        fprintf(stderr, "FAIL: create_topic(RejectedTopic) failed\n");
        return 1;
    }
    printf("Create topic: RejectedTopic\n");

    DDS_Topic lost_topic = DDS_DomainParticipant_create_topic(dp, "LostTopic", "StatusEvent", NULL, NULL, 0);
    if (!lost_topic) {
        fprintf(stderr, "FAIL: create_topic(LostTopic) failed\n");
        return 1;
    }
    printf("Create topic: LostTopic\n");

    DDS_Topic sync_topic = DDS_DomainParticipant_create_topic(dp, "SyncTopic", "StatusEvent", NULL, NULL, 0);
    if (!sync_topic) {
        fprintf(stderr, "FAIL: create_topic(SyncTopic) failed\n");
        return 1;
    }
    printf("Create topic: SyncTopic\n");

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    /* LostTopic FIRST, deliberately before any reader can possibly be
     * matched -- see the file header comment. */
    DDS_DataWriterQos lost_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &lost_qos);
    lost_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    lost_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_LAST_HISTORY_QOS;
    lost_qos.history.depth = 1;
    /* TRANSIENT_LOCAL so the late-joining reader can still receive whatever
     * remains in the writer's cache (the seq=4 sample) -- VOLATILE (the
     * default) would make it miss ALL 5 samples, not just the 4 evicted
     * ones. Eviction (and therefore loss of seq 0-3) still happens
     * regardless of durability. */
    lost_qos.durability.kind = DDS_DurabilityQosPolicyKind_TRANSIENT_LOCAL_DURABILITY_QOS;

    DDS_DataWriter lost_dw = DDS_Publisher_create_datawriter(pub, lost_topic, &lost_qos, NULL, 0);
    if (!lost_dw) {
        fprintf(stderr, "FAIL: create_datawriter(LostTopic) failed\n");
        return 1;
    }
    printf("Create writer for topic: LostTopic\n");

    StatusEventDataWriter lost_writer;
    StatusEventDataWriter_init(&lost_writer, lost_dw, ZIDL_XCDR1);
    for (int seq = 0; seq < 5; seq++) {
        StatusEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (StatusEventDataWriter_write(&lost_writer, &ev, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: LostTopic write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    printf("Publisher: wrote 5 samples on LostTopic (KEEP_LAST depth=1, no reader matched yet).\n");

    DDS_DataWriterQos rejected_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &rejected_qos);
    rejected_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    rejected_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataWriter rejected_dw = DDS_Publisher_create_datawriter(pub, rejected_topic, &rejected_qos, NULL, 0);
    if (!rejected_dw) {
        fprintf(stderr, "FAIL: create_datawriter(RejectedTopic) failed\n");
        return 1;
    }
    printf("Create writer for topic: RejectedTopic\n");

    DDS_DataWriterQos sync_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &sync_qos);
    sync_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    DDS_DataWriter sync_dw = DDS_Publisher_create_datawriter(pub, sync_topic, &sync_qos, NULL, 0);
    if (!sync_dw) {
        fprintf(stderr, "FAIL: create_datawriter(SyncTopic) failed\n");
        return 1;
    }
    printf("Create writer for topic: SyncTopic\n");

    WriterSyncState rejected_state, sync_state, lost_state;
    memset(&rejected_state, 0, sizeof(rejected_state));
    memset(&sync_state, 0, sizeof(sync_state));
    memset(&lost_state, 0, sizeof(lost_state));

    if (set_writer_listener(rejected_dw, &rejected_state) != DDS_RETCODE_OK ||
        set_writer_listener(sync_dw, &sync_state) != DDS_RETCODE_OK ||
        set_writer_listener(lost_dw, &lost_state) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    /* Only Rejected/Sync need to wait for their reader -- the subscriber
     * creates those two immediately at startup. LostTopic's reader isn't
     * created until the subscriber gets the Sync sample, by design. */
    for (int waited_ms = 0;
         !(atomic_load(&rejected_state.reader_ready) && atomic_load(&sync_state.reader_ready));
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    StatusEventDataWriter rejected_writer;
    StatusEventDataWriter_init(&rejected_writer, rejected_dw, ZIDL_XCDR1);
    /* The subscriber deliberately does not drain RejectedTopic until it has
     * confirmed rejection happened, so no reader-side consumption race is
     * possible here regardless of exact write timing. */
    for (int seq = 0; seq < 5; seq++) {
        StatusEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (StatusEventDataWriter_write(&rejected_writer, &ev, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: RejectedTopic write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    printf("Publisher: wrote 5 samples on RejectedTopic (up to 2 expected rejected).\n");

    StatusEventDataWriter sync_writer;
    StatusEventDataWriter_init(&sync_writer, sync_dw, ZIDL_XCDR1);
    StatusEvent sync_ev;
    memset(&sync_ev, 0, sizeof(sync_ev));
    if (StatusEventDataWriter_write(&sync_writer, &sync_ev, DDS_HANDLE_NIL) != 0) {
        fprintf(stderr, "FAIL: SyncTopic write() failed\n");
        return 1;
    }
    printf("Publisher: sync sent.\n");
    printf("Publisher: done.\n");

    for (int waited_ms = 0;
         !(atomic_load(&rejected_state.ever_matched) && atomic_load(&rejected_state.matched_current_count) == 0 &&
           atomic_load(&sync_state.ever_matched) && atomic_load(&sync_state.matched_current_count) == 0 &&
           atomic_load(&lost_state.ever_matched) && atomic_load(&lost_state.matched_current_count) == 0);
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    if (DDS_Publisher_delete_datawriter(pub, rejected_dw) != DDS_RETCODE_OK ||
        DDS_Publisher_delete_datawriter(pub, lost_dw) != DDS_RETCODE_OK ||
        DDS_Publisher_delete_datawriter(pub, sync_dw) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: delete_datawriter() did not return RETCODE_OK\n");
        return 1;
    }

    zzdds_destroy_factory(factory);
    return 0;
}
