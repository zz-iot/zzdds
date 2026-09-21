/*
 * integration-tests/c/delete-contained-entities -- session.
 *
 * The entity under test. Builds a small tree (2 DataWriters, a plain
 * DataReader, a ContentFilteredTopic-backed DataReader, a ReadCondition
 * attached to a WaitSet) under one participant, exchanges a few samples
 * with the peer, then tears the whole tree down in one shot via
 * DomainParticipant_delete_contained_entities() instead of deleting each
 * child first -- the point of this scenario is exercising the cascade, not
 * manual teardown. See docs/design/integration-test-tier.md for the full
 * scenario spec.
 *
 * Core assertions: delete_contained_entities() returns RETCODE_OK, the
 * immediately-following delete_participant() ALSO returns RETCODE_OK (per
 * spec this only succeeds if the cascade genuinely left nothing dangling --
 * a real leaked child fails this with PRECONDITION_NOT_MET), and no
 * matched-status listener ever fires after the torn_down flag is set (a
 * callback firing after logical teardown began is a UAF-class bug this
 * project has hit before in teardown paths).
 *
 * Required stdout markers: "Create topic:" x3, "Create writer for topic:"
 * x2, "Create reader for topic:" x2, "Session: torn down via
 * delete_contained_entities." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
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
#define WAIT_STEP_SEC 1
#define POLL_PERIOD_MS 20

static atomic_bool torn_down = false;

typedef struct {
    atomic_bool reader_ready;
} WriterSyncState;

static void on_publication_matched_ex(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    (void)status;
    (void)listener_data;
    if (atomic_load(&torn_down)) {
        fprintf(stderr, "FAIL: listener fired after delete_contained_entities\n");
        exit(1);
    }
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

static void on_subscription_matched(DDS_DataReader reader, const DDS_SubscriptionMatchedStatus *status, void *listener_data) {
    (void)reader;
    (void)status;
    (void)listener_data;
    if (atomic_load(&torn_down)) {
        fprintf(stderr, "FAIL: listener fired after delete_contained_entities\n");
        exit(1);
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
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
        return 1;
    }

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_DataWriter out1_dw = DDS_Publisher_create_datawriter(pub, out1_topic, &dw_qos, NULL, 0);
    DDS_DataWriter out2_dw = DDS_Publisher_create_datawriter(pub, out2_topic, &dw_qos, NULL, 0);
    if (!out1_dw || !out2_dw) {
        fprintf(stderr, "FAIL: create_datawriter() failed\n");
        return 1;
    }
    printf("Create writer for topic: SessionOut1\n");
    printf("Create writer for topic: SessionOut2\n");

    WriterSyncState out1_state, out2_state;
    memset(&out1_state, 0, sizeof(out1_state));
    memset(&out2_state, 0, sizeof(out2_state));
    if (set_writer_listener_ex(out1_dw, &out1_state) != DDS_RETCODE_OK ||
        set_writer_listener_ex(out2_dw, &out2_state) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: set_listener_ex (writer) failed\n");
        return 1;
    }

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_TopicDescription in_desc = zzdds_topic_as_description(in_topic);
    DDS_DataReader in_dr = DDS_Subscriber_create_datareader(sub, in_desc, &dr_qos, NULL, 0);
    if (!in_dr) {
        fprintf(stderr, "FAIL: create_datareader(SessionIn) failed\n");
        return 1;
    }
    printf("Create reader for topic: SessionIn\n");

    /* Exercise CFT-collateral cleanup under the cascade -- this project has
     * a real CFT bug history (see docs/decisions.md). Trivial filter: just
     * needs to exist and be attached, not to actually narrow anything. */
    DDS_ContentFilteredTopic cft = DDS_DomainParticipant_create_contentfilteredtopic(dp, "SessionIn_cft", in_topic, "seq >= 0", NULL);
    if (!cft) {
        fprintf(stderr, "FAIL: create_contentfilteredtopic() failed\n");
        return 1;
    }
    DDS_TopicDescription cft_desc = DDS_ContentFilteredTopic_as_DDS_TopicDescription(cft);
    DDS_DataReader cft_dr = DDS_Subscriber_create_datareader(sub, cft_desc, &dr_qos, NULL, 0);
    if (!cft_dr) {
        fprintf(stderr, "FAIL: create_datareader(SessionIn_cft) failed\n");
        return 1;
    }
    printf("Create reader for topic: SessionIn_cft\n");

    DDS_DataReaderListener dr_listener;
    memset(&dr_listener, 0, sizeof(dr_listener));
    dr_listener.on_subscription_matched = on_subscription_matched;
    if (DDS_DataReader_set_listener(in_dr, &dr_listener, DDS_SUBSCRIPTION_MATCHED_STATUS) != DDS_RETCODE_OK ||
        DDS_DataReader_set_listener(cft_dr, &dr_listener, DDS_SUBSCRIPTION_MATCHED_STATUS) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: set_listener (reader) failed\n");
        return 1;
    }

    DDS_WaitSet ws = zzdds_create_waitset();
    if (zzdds_waitset_is_nil(ws)) {
        fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }
    DDS_ReadCondition in_rc = DDS_DataReader_create_readcondition(in_dr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
    if (!in_rc) {
        fprintf(stderr, "FAIL: create_readcondition() failed\n");
        return 1;
    }
    DDS_Condition in_cond = DDS_ReadCondition_as_DDS_Condition(in_rc);
    if (DDS_WaitSet_attach_condition(ws, in_cond) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: attach_condition() failed\n");
        return 1;
    }

    SessionEventDataWriter out1_writer, out2_writer;
    SessionEventDataWriter_init(&out1_writer, out1_dw, ZIDL_XCDR1);
    SessionEventDataWriter_init(&out2_writer, out2_dw, ZIDL_XCDR1);
    SessionEventDataReader in_reader;
    SessionEventDataReader_init(&in_reader, in_dr);

    /* Gate writes on the peer's reader actually being registered, not just
     * matched -- matched-count alone (SEDP discovery) does not imply the
     * remote RELIABLE reader proxy has registered this writer yet; writing
     * before that is a real race this project has hit before (see
     * DataReaderListenerEx.on_reliable_writer_ready / on_reliable_reader_ready
     * in docs/roadmap.md). Every other example in this repo gates on this
     * signal before its first write -- do the same here. */
    for (int waited_ms = 0; !(atomic_load(&out1_state.reader_ready) && atomic_load(&out2_state.reader_ready)); waited_ms += POLL_PERIOD_MS) {
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
        if (SessionEventDataWriter_write(&out1_writer, &ev, DDS_HANDLE_NIL) != 0 ||
            SessionEventDataWriter_write(&out2_writer, &ev, DDS_HANDLE_NIL) != 0)
        {
            fprintf(stderr, "FAIL: write() failed at seq=%d\n", seq);
            return 1;
        }
    }
    printf("Session: wrote %d samples on SessionOut1/SessionOut2\n", SAMPLE_COUNT);

    int received = 0;
    DDS_Duration_t wait_step = {WAIT_STEP_SEC, 0};
    int waited_ms = 0;
    SessionEvent values[SAMPLE_COUNT];
    DDS_SampleInfo infos[SAMPLE_COUNT];
    while (received < RECEIVE_TARGET) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: session did not receive from peer within %ds (got %d)\n", RECEIVE_TIMEOUT_MS / 1000, received);
            return 1;
        }
        DDS_ConditionSeq active;
        memset(&active, 0, sizeof(active));
        DDS_ReturnCode_t wr = DDS_WaitSet_wait(ws, &active, &wait_step);
        if (wr == DDS_RETCODE_TIMEOUT) {
            waited_ms += WAIT_STEP_SEC * 1000;
            continue;
        }
        if (wr != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", wr);
            return 1;
        }
        DDS_ConditionSeq_free(&active);

        int n = SessionEventDataReader_take_n(&in_reader, values, infos, SAMPLE_COUNT,
                                               DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
        for (int i = 0; i < n; i++) {
            if (infos[i].valid_data) received++;
        }
    }
    printf("Session: received %d samples from peer.\n", received);

    /* The core test: tear the whole tree down in one shot instead of
     * deleting out1_dw/out2_dw/in_dr/cft_dr/cft one at a time. */
    atomic_store(&torn_down, true);

    DDS_ReturnCode_t rc1 = DDS_DomainParticipant_delete_contained_entities(dp);
    if (rc1 != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: delete_contained_entities() returned %d, expected RETCODE_OK\n", rc1);
        return 1;
    }

    DDS_ReturnCode_t rc2 = DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    if (rc2 != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: delete_participant() returned %d after delete_contained_entities -- "
                        "cascade left something dangling\n", rc2);
        return 1;
    }

    zzdds_destroy_waitset(ws);
    printf("Session: torn down via delete_contained_entities.\n");

    zzdds_destroy_factory(factory);
    return 0;
}
