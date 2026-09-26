/*
 * integration-tests/c/cft-reconfigure -- publisher. Writes CftEvent samples
 * in two batches (phase1: seq 0..4, phase2: seq 5..9) on the same
 * long-lived DataWriter, pausing between batches until the subscriber
 * signals (via GoTopic, reusing CftEvent's own type -- same minimalism
 * convention sample-rejected-lost's SyncTopic follows) that it has already
 * confirmed phase1 was correctly filtered out and has called
 * set_expression_parameters() to reconfigure its ContentFilteredTopic --
 * without ever recreating it -- before phase2 exists. See
 * docs/design/integration-test-tier.md for the full scenario spec and
 * subscriber.c for the assertions themselves; this side just drives the two
 * batches on a fixed schedule the subscriber controls.
 *
 * Required stdout markers: "Create topic:" x2, "Create writer for topic:",
 * "Publisher: wrote phase1 seq=", "Publisher: received go-ahead signal.",
 * "Publisher: wrote phase2 seq=", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "cft_event.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PHASE1_COUNT 5
#define PHASE2_COUNT 5
/* 40s, not the 20s every other match-wait in this tier uses -- this
 * scenario waits for *two* readers to match (witness + filtered), twice the
 * SEDP discovery work of a typical 1-reader scenario, and it showed
 * intermittent timeouts specifically as the first Java pair run right after
 * a from-scratch 4-binding rebuild (JVM cold-start contending with residual
 * build-tail CPU/IO load) under this suite's own CI/dev sandbox. */
#define MATCH_TIMEOUT_MS 40000
#define GO_TIMEOUT_MS 20000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    atomic_int matched_current_count;
} PubState;

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    PubState *state = (PubState *)listener_data;
    atomic_store(&state->matched_current_count, status->current_count);
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

    if (CftEventTypeSupport_register(dp, "CftEvent") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "CftEvent", "CftEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: CftEvent\n");
    fflush(stdout);

    DDS_Topic go_topic = DDS_DomainParticipant_create_topic(dp, "GoTopic", "CftEvent", NULL, NULL, 0);
    if (!go_topic) {
        fprintf(stderr, "FAIL: create_topic(GoTopic) failed\n");
        return 1;
    }
    printf("Create topic: GoTopic\n");
    fflush(stdout);

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!pub || !sub) {
        fprintf(stderr, "FAIL: create_publisher()/create_subscriber() failed\n");
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
    printf("Create writer for topic: CftEvent\n");
    fflush(stdout);

    PubState state;
    atomic_init(&state.matched_current_count, 0);
    DDS_DataWriterListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_publication_matched = on_publication_matched;
    if (DDS_DataWriter_set_listener(dw, &listener, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_TopicDescription go_desc = zzdds_topic_as_description(go_topic);
    DDS_DataReader go_dr = DDS_Subscriber_create_datareader(sub, go_desc, &dr_qos, NULL, 0);
    if (!go_dr) {
        fprintf(stderr, "FAIL: create_datareader(GoTopic) failed\n");
        return 1;
    }

    CftEventDataWriter writer;
    CftEventDataWriter_init(&writer, dw, ZIDL_XCDR1);
    CftEventDataReader go_reader;
    CftEventDataReader_init(&go_reader, go_dr);

    /* -- Wait for both of the subscriber's readers (witness + filtered) to
     * match before writing anything, so phase1 is guaranteed to actually
     * reach both. -- */
    for (int waited_ms = 0; atomic_load(&state.matched_current_count) < 2; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= MATCH_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: fewer than 2 readers matched within %ds (got %d)\n", MATCH_TIMEOUT_MS / 1000, atomic_load(&state.matched_current_count));
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    /* -- Phase 1: written while the CFT's threshold excludes all of it. -- */
    for (int seq = 0; seq < PHASE1_COUNT; seq++) {
        CftEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (CftEventDataWriter_write(&writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write(phase1) failed at seq=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote phase1 seq=%d\n", seq);
        fflush(stdout);
    }

    /* -- Wait for the subscriber's go-ahead: it has confirmed phase1 was
     * filtered out and reconfigured the CFT's parameters in place. -- */
    bool got_go = false;
    for (int waited_ms = 0; !got_go; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= GO_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: go-ahead signal never arrived within %ds\n", GO_TIMEOUT_MS / 1000);
            return 1;
        }
        CftEvent value;
        DDS_SampleInfo info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[256];
        size_t cdr_len = 0;
        int rc = CftEventDataReader_take(&go_reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_OK && info.valid_data) {
            got_go = true;
            break;
        }
        if (rc != DDS_RETCODE_OK && rc != DDS_RETCODE_NO_DATA) {
            fprintf(stderr, "FAIL: take(GoTopic) CDR error (rc=%d)\n", rc);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Publisher: received go-ahead signal.\n");
    fflush(stdout);

    /* -- Phase 2: written after the reconfigure, on the same DataWriter. -- */
    for (int seq = PHASE1_COUNT; seq < PHASE1_COUNT + PHASE2_COUNT; seq++) {
        CftEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.seq = seq;
        if (CftEventDataWriter_write(&writer, &ev, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: write(phase2) failed at seq=%d\n", seq);
            return 1;
        }
        printf("Publisher: wrote phase2 seq=%d\n", seq);
        fflush(stdout);
    }

    for (int waited_ms = 0; atomic_load(&state.matched_current_count) != 0; waited_ms += POLL_PERIOD_MS) {
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
