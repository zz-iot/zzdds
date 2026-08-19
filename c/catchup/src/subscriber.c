/*
 * c/catchup -- subscriber (the late joiner). Direct C port of
 * zig/catchup/subscriber.zig; see docs/design/catchup-reference-app.md at
 * the repo root for the full spec. Starts after the publisher has already
 * written its full historical batch (enforced by the harness, not this
 * app). Immediately after creating the reader, calls
 * wait_for_historical_data() -- the API this whole example exists to
 * exercise -- before taking anything, then confirms the full historical
 * batch was in fact replayed by the time that call returns, then continues
 * taking live samples as they arrive.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: wait_for_historical_data() returned",
 * "HISTORICAL BATCH COMPLETE (10 samples)", "LIVE SAMPLE seq_num=",
 * "Subscriber: observed historical batch then live batch correctly." Any
 * failure path prints a line starting "FAIL:" and exits nonzero.
 */
#include "catchup_sample.h"
#include "zzdds_c.h"

#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define HISTORICAL_COUNT 10
#define LIVE_COUNT 5
#define HISTORICAL_WAIT_TIMEOUT_S 10
#define RECEIVE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

typedef struct {
    HistoryEventDataReader *reader;
    atomic_bool historical_received[10];
    atomic_bool live_received[5];
    atomic_bool historical_confirmed;
    atomic_bool all_done;
} SubState;

/* Pure readiness check -- does NOT store all_done itself. Callers decide
 * when it's safe to actually commit the flag (see on_data_available's
 * deferred-store comment: main() deletes the reader as soon as it observes
 * all_done, so storing it while still inside a take loop would let
 * delete_datareader() race that same invocation's next take() call). */
static bool ready_to_finish(SubState *state) {
    if (!atomic_load(&state->historical_confirmed)) return false;
    for (int i = 0; i < LIVE_COUNT; i++) {
        if (!atomic_load(&state->live_received[i])) return false;
    }
    return true;
}

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    (void)the_reader;
    SubState *state = (SubState *)listener_data;
    /* main() can also independently decide it's done (see the
     * ready_to_finish() call right after wait_for_historical_data()
     * returns below) and call delete_datareader() while this invocation is
     * still draining. That's still fine: zzdds's core EntityQuiesce
     * mechanism (not anything in this file) guarantees a delete_datareader()
     * racing an in-flight take() call is memory-safe -- the racing take()
     * either completes normally (started before teardown) or cleanly sees
     * "no data" (started after), never a crash or use-after-free. */
    bool became_done = false;

    for (;;) {
        HistoryEvent value;
        zzdds_sample_info info;
        memset(&value, 0, sizeof(value));
        memset(&info, 0, sizeof(info));
        uint8_t buf[512];
        size_t cdr_len = 0;

        int rc = HistoryEventDataReader_take(state->reader, &value, &info, buf, sizeof(buf), &cdr_len);
        if (rc == DDS_RETCODE_NO_DATA) break;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take() CDR error (rc=%d)\n", rc);
            exit(1);
        }
        if (!info.valid_data) continue;

        int32_t seq_num = value.seq_num;
        if (seq_num >= 0 && seq_num < HISTORICAL_COUNT) {
            atomic_store(&state->historical_received[seq_num], true);
        } else if (seq_num >= HISTORICAL_COUNT && seq_num < HISTORICAL_COUNT + LIVE_COUNT) {
            printf("LIVE SAMPLE seq_num=%d\n", seq_num);
            atomic_store(&state->live_received[seq_num - HISTORICAL_COUNT], true);
            if (!atomic_load(&state->all_done) && !became_done && ready_to_finish(state)) {
                became_done = true;
            }
        } else {
            fprintf(stderr, "FAIL: unexpected seq_num=%d\n", seq_num);
            exit(1);
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

    if (zzdds_register_type_support(dp, "HistoryEvent", HistoryEvent_compute_key_hash_from_cdr, HistoryEvent_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "HistoryEvent", "HistoryEvent", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: HistoryEvent\n");

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.durability.kind = DDS_DurabilityQosPolicyKind_TRANSIENT_LOCAL_DURABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    SubState state;
    memset(&state, 0, sizeof(state));
    for (int i = 0; i < HISTORICAL_COUNT; i++) atomic_init(&state.historical_received[i], false);
    for (int i = 0; i < LIVE_COUNT; i++) atomic_init(&state.live_received[i], false);
    atomic_init(&state.historical_confirmed, false);
    atomic_init(&state.all_done, false);

    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_data_available = on_data_available;

    /* Create with no listener attached yet: on_data_available fires on a
     * zzdds-internal dispatch thread as soon as the reader matches the
     * publisher's already-written historical batch, which can race
     * state.reader's own initialization below (a real, not hypothetical,
     * race given this example's whole point is data being ready before the
     * reader even exists). Attach the listener only once state.reader is
     * set, via set_listener() below, closing the window entirely. */
    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: HistoryEvent\n");

    HistoryEventDataReader reader;
    HistoryEventDataReader_init(&reader, dr);
    state.reader = &reader;

    if (DDS_DataReader_set_listener(dr, &listener, DDS_DATA_AVAILABLE_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener() failed\n");
        return 1;
    }

    /* The API this whole example exists to exercise: block until the
     * TRANSIENT_LOCAL historical replay has actually landed, before
     * taking anything. */
    DDS_Duration_t max_wait;
    max_wait.sec = HISTORICAL_WAIT_TIMEOUT_S;
    max_wait.nanosec = 0;
    DDS_ReturnCode_t rc = DDS_DataReader_wait_for_historical_data(dr, &max_wait);
    if (rc != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: wait_for_historical_data() returned %d\n", rc);
        return 1;
    }
    printf("Subscriber: wait_for_historical_data() returned\n");

    /* Confirm the real guarantee, not just the return code: every
     * historical sample must already have been delivered by now. */
    int historical_count = 0;
    for (int i = 0; i < HISTORICAL_COUNT; i++) {
        if (atomic_load(&state.historical_received[i])) historical_count++;
    }
    if (historical_count != HISTORICAL_COUNT) {
        fprintf(stderr, "FAIL: wait_for_historical_data() returned OK but only %d/%d historical samples were actually received\n", historical_count, HISTORICAL_COUNT);
        return 1;
    }
    printf("HISTORICAL BATCH COMPLETE (%d samples)\n", HISTORICAL_COUNT);
    atomic_store(&state.historical_confirmed, true);
    if (ready_to_finish(&state)) {
        atomic_store(&state.all_done, true);
    }

    for (int waited_ms = 0; !atomic_load(&state.all_done); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: did not observe the full live batch within %ds\n", RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        usleep(POLL_PERIOD_MS * 1000);
    }

    DDS_Subscriber_delete_datareader(sub, dr);

    printf("Subscriber: observed historical batch then live batch correctly.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
