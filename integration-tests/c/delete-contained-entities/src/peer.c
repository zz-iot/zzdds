/*
 * integration-tests/c/delete-contained-entities -- peer.
 *
 * Simple counterpart to session.c: writes to SessionIn, reads from
 * SessionOut1/SessionOut2, exchanges a few samples, then waits for a clean
 * disconnect once the session tears itself down via
 * delete_contained_entities() -- matched-current-count must reach zero on
 * every entity matched with the session, without hanging or erroring. See
 * docs/design/integration-test-tier.md for the full scenario spec.
 *
 * Required stdout markers: "Create topic:" x3, "Create writer for topic:",
 * "Create reader for topic:" x2, "Peer: session disconnected cleanly."
 * Any failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "session_event.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SAMPLE_COUNT 5
#define RECEIVE_TARGET 2
#define READER_READY_TIMEOUT_MS 10000
#define RECEIVE_TIMEOUT_MS 20000
#define DISCONNECT_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_bool ever_matched;
    atomic_int matched_current_count;
    atomic_bool reader_ready;
} MatchState;

static void on_publication_matched_ex(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    MatchState *state = (MatchState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
    if (status->current_count > 0) atomic_store(&state->ever_matched, true);
}

static void on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void *listener_data) {
    (void)reader_handle;
    MatchState *state = (MatchState *)listener_data;
    if (is_ready) atomic_store(&state->reader_ready, true);
}

static void on_subscription_matched(DDS_DataReader reader, const DDS_SubscriptionMatchedStatus *status, void *listener_data) {
    (void)reader;
    MatchState *state = (MatchState *)listener_data;
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

static int set_writer_listener_ex(DDS_DataWriter dw, MatchState *state) {
    zzdds_DataWriter zdw = DDS_DataWriter_as_zzdds_DataWriter(dw);
    zzdds_DataWriterListenerEx listener_ex;
    memset(&listener_ex, 0, sizeof(listener_ex));
    listener_ex.listener_data = state;
    listener_ex.on_publication_matched = on_publication_matched_ex;
    listener_ex.on_reliable_reader_ready = on_reliable_reader_ready;
    return zzdds_DataWriter_set_listener_ex(zdw, &listener_ex, DDS_PUBLICATION_MATCHED_STATUS);
}

static int set_reader_listener(DDS_DataReader dr, MatchState *state) {
    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = state;
    listener.on_subscription_matched = on_subscription_matched;
    return DDS_DataReader_set_listener(dr, &listener, DDS_SUBSCRIPTION_MATCHED_STATUS);
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

    if (SessionEventTypeSupport_register(dp, "SessionEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register SessionEventTypeSupport failed\n");
        return 1;
    }

    DDS_Topic out1_topic = DDS_DomainParticipant_create_topic(dp, "SessionOut1", "SessionEvent", NULL, NULL, 0);
    if (!out1_topic) {
        fprintf(stderr, "FAIL: create_topic(SessionOut1) failed\n");
        return 1;
    }
    printf("Create topic: SessionOut1\n");

    DDS_Topic out2_topic = DDS_DomainParticipant_create_topic(dp, "SessionOut2", "SessionEvent", NULL, NULL, 0);
    if (!out2_topic) {
        fprintf(stderr, "FAIL: create_topic(SessionOut2) failed\n");
        return 1;
    }
    printf("Create topic: SessionOut2\n");

    DDS_Topic in_topic = DDS_DomainParticipant_create_topic(dp, "SessionIn", "SessionEvent", NULL, NULL, 0);
    if (!in_topic) {
        fprintf(stderr, "FAIL: create_topic(SessionIn) failed\n");
        return 1;
    }
    printf("Create topic: SessionIn\n");

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!pub || !sub) {
        fprintf(stderr, "FAIL: create_publisher/create_subscriber failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter in_dw = DDS_Publisher_create_datawriter(pub, in_topic, &dw_qos, NULL, 0);
    if (!in_dw) {
        fprintf(stderr, "FAIL: create_datawriter(SessionIn) failed\n");
        return 1;
    }
    printf("Create writer for topic: SessionIn\n");

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_TopicDescription out1_desc = zzdds_topic_as_description(out1_topic);
    DDS_DataReader out1_dr = DDS_Subscriber_create_datareader(sub, out1_desc, &dr_qos, NULL, 0);
    if (!out1_dr) {
        fprintf(stderr, "FAIL: create_datareader(SessionOut1) failed\n");
        return 1;
    }
    printf("Create reader for topic: SessionOut1\n");

    DDS_TopicDescription out2_desc = zzdds_topic_as_description(out2_topic);
    DDS_DataReader out2_dr = DDS_Subscriber_create_datareader(sub, out2_desc, &dr_qos, NULL, 0);
    if (!out2_dr) {
        fprintf(stderr, "FAIL: create_datareader(SessionOut2) failed\n");
        return 1;
    }
    printf("Create reader for topic: SessionOut2\n");

    MatchState writer_state, out1_state, out2_state;
    memset(&writer_state, 0, sizeof(writer_state));
    memset(&out1_state, 0, sizeof(out1_state));
    memset(&out2_state, 0, sizeof(out2_state));

    if (set_writer_listener_ex(in_dw, &writer_state) != DDS_RETCODE_OK ||
        set_reader_listener(out1_dr, &out1_state) != DDS_RETCODE_OK ||
        set_reader_listener(out2_dr, &out2_state) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    SessionEventDataWriter in_writer;
    SessionEventDataWriter_init(&in_writer, in_dw, ZIDL_XCDR1);
    SessionEventDataReader out1_reader, out2_reader;
    SessionEventDataReader_init(&out1_reader, out1_dr);
    SessionEventDataReader_init(&out2_reader, out2_dr);

    /* Gate on the session's reader actually being registered, not just
     * matched -- see session.c's matching comment for why. */
    for (int waited_ms = 0; !atomic_load(&writer_state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        SessionEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (SessionEventDataWriter_write(&in_writer, &ev, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    printf("Peer: wrote %d samples on SessionIn\n", SAMPLE_COUNT);

    /* Wait (poll -- no listener wiring needed here, just count receipts)
     * until both readers have seen at least RECEIVE_TARGET samples. */
    int received1 = 0, received2 = 0;
    SessionEvent values[SAMPLE_COUNT];
    DDS_SampleInfo infos[SAMPLE_COUNT];
    for (int waited_ms = 0; received1 < RECEIVE_TARGET || received2 < RECEIVE_TARGET; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: peer did not receive from session within %ds (out1=%d out2=%d)\n",
                    RECEIVE_TIMEOUT_MS / 1000, received1, received2);
            return 1;
        }
        int n1 = SessionEventDataReader_take_n(&out1_reader, values, infos, SAMPLE_COUNT,
                                                DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
        for (int i = 0; i < n1; i++) {
            if (infos[i].valid_data) received1++;
        }
        int n2 = SessionEventDataReader_take_n(&out2_reader, values, infos, SAMPLE_COUNT,
                                                DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
        for (int i = 0; i < n2; i++) {
            if (infos[i].valid_data) received2++;
        }
        if (received1 < RECEIVE_TARGET || received2 < RECEIVE_TARGET) usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Peer: received from session (out1=%d out2=%d).\n", received1, received2);

    /* Now wait for the session to tear itself down: matched-current-count
     * on every entity matched with it must drop to zero. */
    for (int waited_ms = 0;
         !(atomic_load(&writer_state.ever_matched) && atomic_load(&writer_state.matched_current_count) == 0 &&
           atomic_load(&out1_state.ever_matched) && atomic_load(&out1_state.matched_current_count) == 0 &&
           atomic_load(&out2_state.ever_matched) && atomic_load(&out2_state.matched_current_count) == 0);
         waited_ms += POLL_PERIOD_MS)
    {
        if (waited_ms >= DISCONNECT_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: peer never saw a clean disconnect within %ds\n", DISCONNECT_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    printf("Peer: session disconnected cleanly.\n");

    DDS_DomainParticipant_delete_contained_entities(dp);
    DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    zzdds_destroy_factory(factory);
    return 0;
}
