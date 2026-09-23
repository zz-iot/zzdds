/*
 * integration-tests/c/cft-reconfigure -- subscriber (the entity under
 * test). Exercises the ContentFilteredTopic introspection surface the API
 * audit flags as completely untested (get_filter_expression/
 * get_expression_parameters/set_expression_parameters/get_related_topic --
 * "CFT is set once at creation, never read back or changed") and, more
 * importantly, the *behavioral* question distinct from the stress `cft`
 * scenario's concurrency-safety coverage: does calling
 * set_expression_parameters() on an already-live CFT -- without ever
 * recreating the CFT or its DataReader -- actually re-filter *subsequent*
 * samples? See docs/design/integration-test-tier.md for the full scenario
 * spec.
 *
 * Two DataReaders on the same underlying "CftEvent" topic:
 * - a plain, unfiltered "witness" reader, used purely to independently
 *   confirm what the publisher actually sent end-to-end over the wire --
 *   without it, "the filtered reader received zero samples" would be
 *   ambiguous between "correctly filtered" and "never arrived at all" (not
 *   matched yet, lost, etc.).
 * - a ContentFilteredTopic reader, filter expression "seq >= %0", created
 *   with an unreachable initial parameter ("1000") so phase1 (seq 0..4) is
 *   filtered out entirely, then reconfigured mid-stream via
 *   set_expression_parameters(["3"]) once phase1 is confirmed witnessed and
 *   confirmed filtered.
 *
 * The two-phase design proves two things at once: (1) subsequent samples
 * (phase2, seq 5..9) really are re-filtered against the new parameter
 * without recreating anything; (2) already-evaluated-and-dropped samples
 * (phase1's seq=3, seq=4 -- both >= the *new* threshold of 3) are never
 * retroactively delivered -- CFT filtering is a one-time decision made at
 * receive time, not something replayed against a reader's own history.
 *
 * Required stdout markers: "Create topic:" x2, "Create reader for topic:"
 * x2, "Create writer for topic:", "Subscriber: CFT introspection
 * (filter_expression/expression_parameters/related_topic) verified at
 * creation.", "Subscriber: ready.", "Subscriber: witnessed all 5 phase1
 * samples via unfiltered reader.", "Subscriber: filtered reader correctly
 * received zero phase1 samples (threshold=1000).", "Subscriber:
 * set_expression_parameters() reconfigured threshold to 3, read-back
 * verified.", "Subscriber: sent go-ahead signal.", "Subscriber: witnessed
 * all 10 total samples via unfiltered reader.", "Subscriber: filtered
 * reader received exactly the post-reconfigure samples {5..9}, confirming
 * live re-filtering without CFT recreation.", "Subscriber: done." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "cft_event.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TOTAL_COUNT 10
#define PHASE1_COUNT 5
#define PHASE2_COUNT 5
/* Must comfortably exceed publisher.c's own MATCH_TIMEOUT_MS (40s, see its
 * matching comment): both sides start at the same time and race the same
 * environmental discovery delay, not a sequenced wait -- if this clock ran
 * out before publisher's own match-wait could ever succeed, this side would
 * time out first even though the publisher was still legitimately working. */
#define WITNESS_TIMEOUT_MS 45000
#define SETTLE_WINDOW_S 3
#define FINAL_TIMEOUT_MS 20000
#define POLL_PERIOD_MS 20

typedef struct {
    CftEventDataReader *reader;
    atomic_bool received[TOTAL_COUNT];
    atomic_int count;
} ReaderState;

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    ReaderState *state = (ReaderState *)listener_data;
    for (;;) {
        CftEvent value;
        DDS_SampleInfo info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[256];
        size_t cdr_len = 0;
        int rc = CftEventDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }
        if (!info.valid_data) continue;
        if (value.seq < 0 || value.seq >= TOTAL_COUNT) {
            fprintf(stderr, "FAIL: unexpected seq=%d\n", value.seq);
            exit(1);
        }
        if (!atomic_load(&state->received[value.seq])) {
            atomic_store(&state->received[value.seq], true);
            atomic_fetch_add(&state->count, 1);
        }
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

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!sub || !pub) {
        fprintf(stderr, "FAIL: create_subscriber()/create_publisher() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    /* -- Witness reader: plain, unfiltered, proves end-to-end wire
     * delivery independent of the filtered reader's own behavior. -- */
    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader witness_dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!witness_dr) {
        fprintf(stderr, "FAIL: create_datareader(witness) failed\n");
        return 1;
    }
    printf("Create reader for topic: CftEvent (witness)\n");
    fflush(stdout);

    /* -- ContentFilteredTopic: initial threshold (1000) unreachable by
     * phase1's seq range (0..4), so every phase1 sample must be filtered
     * out. -- */
    char *initial_param = "1000";
    DDS_StringSeq initial_params;
    memset(&initial_params, 0, sizeof(initial_params));
    initial_params._maximum = 1;
    initial_params._length = 1;
    initial_params._buffer = &initial_param;
    initial_params._release = false;

    DDS_ContentFilteredTopic cft = DDS_DomainParticipant_create_contentfilteredtopic(dp, "CftEvent_Filtered", topic, "seq >= %0", &initial_params);
    if (!cft) {
        fprintf(stderr, "FAIL: create_contentfilteredtopic() failed\n");
        return 1;
    }

    /* -- CFT introspection, verified right at creation -- the exact surface
     * the API audit flags as "set once at creation, never read back". -- */
    char *filter_expr = DDS_ContentFilteredTopic_get_filter_expression(cft);
    if (!filter_expr || strcmp(filter_expr, "seq >= %0") != 0) {
        fprintf(stderr, "FAIL: get_filter_expression() returned \"%s\", expected \"seq >= %%0\"\n", filter_expr ? filter_expr : "(null)");
        return 1;
    }
    DDS_StringSeq readback_params;
    memset(&readback_params, 0, sizeof(readback_params));
    if (DDS_ContentFilteredTopic_get_expression_parameters(cft, &readback_params) != DDS_RETCODE_OK || readback_params._length != 1 || strcmp(readback_params._buffer[0], "1000") != 0) {
        fprintf(stderr, "FAIL: get_expression_parameters() at creation did not return [\"1000\"]\n");
        return 1;
    }
    DDS_StringSeq_free(&readback_params);
    DDS_Topic related = DDS_ContentFilteredTopic_get_related_topic(cft);
    char *related_name = related ? DDS_Topic_get_name(related) : NULL;
    if (!related_name || strcmp(related_name, "CftEvent") != 0) {
        fprintf(stderr, "FAIL: get_related_topic() did not return the CftEvent topic\n");
        return 1;
    }
    printf("Subscriber: CFT introspection (filter_expression/expression_parameters/related_topic) verified at creation.\n");
    fflush(stdout);

    DDS_TopicDescription cft_desc = DDS_ContentFilteredTopic_as_DDS_TopicDescription(cft);
    DDS_DataReader filtered_dr = DDS_Subscriber_create_datareader(sub, cft_desc, &dr_qos, NULL, 0);
    if (!filtered_dr) {
        fprintf(stderr, "FAIL: create_datareader(filtered) failed\n");
        return 1;
    }
    printf("Create reader for topic: CftEvent_Filtered\n");
    fflush(stdout);

    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataWriter go_dw = DDS_Publisher_create_datawriter(pub, go_topic, &dw_qos, NULL, 0);
    if (!go_dw) {
        fprintf(stderr, "FAIL: create_datawriter(GoTopic) failed\n");
        return 1;
    }
    printf("Create writer for topic: GoTopic\n");
    fflush(stdout);

    ReaderState witness_state, filtered_state;
    memset(&witness_state, 0, sizeof(witness_state));
    memset(&filtered_state, 0, sizeof(filtered_state));
    for (int i = 0; i < TOTAL_COUNT; i++) {
        atomic_init(&witness_state.received[i], false);
        atomic_init(&filtered_state.received[i], false);
    }
    atomic_init(&witness_state.count, 0);
    atomic_init(&filtered_state.count, 0);

    CftEventDataReader witness_reader, filtered_reader;
    CftEventDataReader_init(&witness_reader, witness_dr);
    CftEventDataReader_init(&filtered_reader, filtered_dr);
    witness_state.reader = &witness_reader;
    filtered_state.reader = &filtered_reader;

    DDS_DataReaderListener witness_listener, filtered_listener;
    memset(&witness_listener, 0, sizeof(witness_listener));
    witness_listener.listener_data = &witness_state;
    witness_listener.on_data_available = on_data_available;
    memset(&filtered_listener, 0, sizeof(filtered_listener));
    filtered_listener.listener_data = &filtered_state;
    filtered_listener.on_data_available = on_data_available;
    if (DDS_DataReader_set_listener(witness_dr, &witness_listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK ||
        DDS_DataReader_set_listener(filtered_dr, &filtered_listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    CftEventDataWriter go_writer;
    CftEventDataWriter_init(&go_writer, go_dw, ZIDL_XCDR1);

    printf("Subscriber: ready.\n");
    fflush(stdout);

    /* -- Phase 1: wait for the witness reader to see all 5, proving they
     * really were sent and really did arrive over the wire. -- */
    for (int waited_ms = 0; atomic_load(&witness_state.count) < PHASE1_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= WITNESS_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: witness reader only saw %d/%d phase1 samples within %ds\n", atomic_load(&witness_state.count), PHASE1_COUNT, WITNESS_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Subscriber: witnessed all %d phase1 samples via unfiltered reader.\n", PHASE1_COUNT);
    fflush(stdout);

    /* -- Settle window, then confirm the filtered reader received none of
     * phase1 (threshold=1000 excludes seq 0..4 entirely). -- */
    sleep(SETTLE_WINDOW_S);
    int filtered_after_phase1 = atomic_load(&filtered_state.count);
    if (filtered_after_phase1 != 0) {
        fprintf(stderr, "FAIL: filtered reader received %d phase1 samples despite threshold=1000\n", filtered_after_phase1);
        return 1;
    }
    printf("Subscriber: filtered reader correctly received zero phase1 samples (threshold=1000).\n");
    fflush(stdout);

    /* -- Reconfigure the live CFT in place -- no recreation of the CFT or
     * its DataReader. -- */
    char *new_param = "3";
    DDS_StringSeq new_params;
    memset(&new_params, 0, sizeof(new_params));
    new_params._maximum = 1;
    new_params._length = 1;
    new_params._buffer = &new_param;
    new_params._release = false;
    if (DDS_ContentFilteredTopic_set_expression_parameters(cft, &new_params) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_expression_parameters() failed\n");
        return 1;
    }
    DDS_StringSeq readback2;
    memset(&readback2, 0, sizeof(readback2));
    if (DDS_ContentFilteredTopic_get_expression_parameters(cft, &readback2) != DDS_RETCODE_OK || readback2._length != 1 || strcmp(readback2._buffer[0], "3") != 0) {
        fprintf(stderr, "FAIL: get_expression_parameters() after reconfigure did not return [\"3\"]\n");
        return 1;
    }
    DDS_StringSeq_free(&readback2);
    printf("Subscriber: set_expression_parameters() reconfigured threshold to 3, read-back verified.\n");
    fflush(stdout);

    if (CftEventDataWriter_write(&go_writer, &(CftEvent){ .seq = 0 }, DDS_HANDLE_NIL) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: write(GoTopic) failed\n");
        return 1;
    }
    printf("Subscriber: sent go-ahead signal.\n");
    fflush(stdout);

    /* -- Phase 2: wait for the witness reader to see all 10 total. -- */
    for (int waited_ms = 0; atomic_load(&witness_state.count) < TOTAL_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= FINAL_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: witness reader only saw %d/%d total samples within %ds\n", atomic_load(&witness_state.count), TOTAL_COUNT, FINAL_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }
    printf("Subscriber: witnessed all %d total samples via unfiltered reader.\n", TOTAL_COUNT);
    fflush(stdout);

    /* -- The witness and filtered readers are separate DataReaders with
     * independent delivery/dispatch, so the witness reader reaching
     * TOTAL_COUNT does not guarantee the filtered reader's own listener has
     * finished processing its (fewer) samples yet. Wait for the filtered
     * reader's own count before asserting its exact contents below, or a
     * correct implementation can fail this nondeterministically (found via
     * Greptile review). -- */
    for (int waited_ms = 0; atomic_load(&filtered_state.count) < PHASE2_COUNT; waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= FINAL_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: filtered reader only saw %d/%d phase2 samples within %ds\n", atomic_load(&filtered_state.count), PHASE2_COUNT, FINAL_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    /* -- The core assertion: the filtered reader must have received
     * *exactly* {5,6,7,8,9} -- phase2 correctly re-filtered against the new
     * threshold (proving live reconfiguration works), and phase1's seq=3
     * and seq=4 (both >= the *new* threshold of 3) never retroactively
     * appear (proving already-dropped samples are gone for good, not
     * replayed against the new parameter). -- */
    for (int seq = 0; seq < PHASE1_COUNT; seq++) {
        if (atomic_load(&filtered_state.received[seq])) {
            fprintf(stderr, "FAIL: filtered reader retroactively received phase1 seq=%d after reconfigure\n", seq);
            return 1;
        }
    }
    for (int seq = PHASE1_COUNT; seq < TOTAL_COUNT; seq++) {
        if (!atomic_load(&filtered_state.received[seq])) {
            fprintf(stderr, "FAIL: filtered reader never received phase2 seq=%d despite threshold=3\n", seq);
            return 1;
        }
    }
    if (atomic_load(&filtered_state.count) != PHASE2_COUNT) {
        fprintf(stderr, "FAIL: filtered reader received %d samples total, expected exactly %d\n", atomic_load(&filtered_state.count), PHASE2_COUNT);
        return 1;
    }
    printf("Subscriber: filtered reader received exactly the post-reconfigure samples {5..9}, confirming live re-filtering without CFT recreation.\n");
    fflush(stdout);

    printf("Subscriber: done.\n");
    fflush(stdout);
    zzdds_destroy_factory(factory);
    return 0;
}
