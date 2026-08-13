/*
 * c/waitset -- subscriber. Direct C port of zig/waitset/subscriber.zig; see
 * docs/design/waitset-reference-app.md at the repo root for the full spec.
 *
 * One WaitSet, four conditions attached simultaneously:
 *
 *   - StatusCondition (SUBSCRIPTION_MATCHED_STATUS) -- logs the match.
 *   - QueryCondition ("priority > %0", param "4") -- real attach/trigger/
 *     query-expression/parameters exercise. Drained via the generated
 *     WaitsetSampleDataReader_take_w_condition (what the OMG spec calls
 *     take_w_condition, and part of the typed DataReader's implicit IDL on
 *     every binding -- see zidl's roadmap for the fuller writeup on closing
 *     this gap).
 *   - ReadCondition (any sample/view/instance state) -- same trigger
 *     condition as QueryCondition above.
 *   - GuardCondition -- same watchdog-thread pattern as the publisher.
 *
 * Like publisher.c, branches on membership in wait()'s returned
 * DDS_ConditionSeq -- see that file's comment for the full reasoning.
 *
 * Required stdout markers: "Create topic:", "Create reader for topic:",
 * "Subscriber: writer matched", "Subscriber: high-priority count=",
 * "Subscriber: low-priority count=", "Subscriber: received all 10
 * samples.", "Subscriber: done." Any failure path prints a line starting
 * "FAIL:" and exits nonzero.
 */
#include "waitset_sample.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define EXPECTED_SAMPLES 10
#define HIGH_PRIORITY_THRESHOLD "4" /* priority > 4 => count 5..9 */
#define WAIT_STEP_SEC 1
#define OVERALL_DEADLINE_MS 30000
#define WATCHDOG_POLL_MS 50

typedef struct {
    DDS_GuardCondition gc;
    atomic_bool stop;
} Watchdog;

static void *watchdog_run(void *arg) {
    Watchdog *w = (Watchdog *)arg;
    int elapsed_ms = 0;
    while (!atomic_load(&w->stop)) {
        if (elapsed_ms >= OVERALL_DEADLINE_MS) {
            printf("Watchdog: overall deadline exceeded, triggering GuardCondition\n");
            DDS_GuardCondition_set_trigger_value(w->gc, true);
            return NULL;
        }
        usleep(WATCHDOG_POLL_MS * 1000);
        elapsed_ms += WATCHDOG_POLL_MS;
    }
    return NULL;
}

static bool condition_active(const DDS_ConditionSeq *active, DDS_Condition c) {
    for (uint32_t i = 0; i < active->_length; i++) {
        if (active->_buffer[i] == c) return true;
    }
    return false;
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

    /* Unlike hello_world, this registration's get_field callback actually
     * matters here -- the QueryCondition's "priority > %0" expression needs
     * field-level access to evaluate. */
    if (zzdds_register_type_support(dp, "WaitsetSample", WaitsetSample_compute_key_hash_from_cdr, WaitsetSample_get_field_from_cdr) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "WaitsetSample", "WaitsetSample", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: WaitsetSample\n");

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, NULL, 0);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: WaitsetSample\n");

    /* ── WaitSet setup: all four condition types on one WaitSet ── */

    DDS_WaitSet ws = zzdds_create_waitset();
    if (zzdds_waitset_is_nil(ws)) {
        fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }

    DDS_Entity dr_entity = DDS_DataReader_as_DDS_Entity(dr);
    DDS_StatusCondition sc = DDS_Entity_get_statuscondition(dr_entity);
    if (DDS_StatusCondition_set_enabled_statuses(sc, DDS_SUBSCRIPTION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_enabled_statuses() failed\n");
        return 1;
    }

    DDS_ReadCondition rc_cond = DDS_DataReader_create_readcondition(dr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
    if (!rc_cond) {
        fprintf(stderr, "FAIL: create_readcondition() failed\n");
        return 1;
    }

    char *param_bufs[1] = {HIGH_PRIORITY_THRESHOLD};
    DDS_StringSeq params;
    params._maximum = 1;
    params._length = 1;
    params._buffer = param_bufs;
    params._release = false;
    DDS_QueryCondition qc_cond = DDS_DataReader_create_querycondition(
        dr, DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE,
        "priority > %0", &params);
    if (!qc_cond) {
        fprintf(stderr, "FAIL: create_querycondition() failed\n");
        return 1;
    }

    DDS_GuardCondition gc = zzdds_create_guardcondition();
    if (zzdds_guardcondition_is_nil(gc)) {
        fprintf(stderr, "FAIL: create_guardcondition() failed\n");
        return 1;
    }

    /* Computed once and reused for both attach and the wait loop's
     * membership checks below -- each is `==`-comparable against whatever
     * wait() later returns for the same underlying condition, including
     * qc_cond's two-level QueryCondition -> ReadCondition -> Condition
     * upcast. */
    DDS_Condition sc_cond = DDS_StatusCondition_as_DDS_Condition(sc);
    DDS_Condition rc_as_cond = DDS_ReadCondition_as_DDS_Condition(rc_cond);
    DDS_Condition qc_as_cond = DDS_ReadCondition_as_DDS_Condition(DDS_QueryCondition_as_DDS_ReadCondition(qc_cond));
    DDS_Condition gc_cond = DDS_GuardCondition_as_DDS_Condition(gc);

    if (DDS_WaitSet_attach_condition(ws, sc_cond) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, rc_as_cond) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, qc_as_cond) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, gc_cond) != DDS_RETCODE_OK)
    {
        fprintf(stderr, "FAIL: attach_condition() failed\n");
        return 1;
    }

    Watchdog watchdog;
    watchdog.gc = gc;
    atomic_init(&watchdog.stop, false);
    pthread_t watchdog_thread;
    pthread_create(&watchdog_thread, NULL, watchdog_run, &watchdog);

    /* ── Main loop: wait, branch on which conditions triggered ── */

    WaitsetSampleDataReader reader;
    WaitsetSampleDataReader_init(&reader, dr);
    DDS_Duration_t wait_step = {WAIT_STEP_SEC, 0};
    int received = 0;
    bool matched_logged = false;
    while (received < EXPECTED_SAMPLES) {
        DDS_ConditionSeq active;
        memset(&active, 0, sizeof(active));
        DDS_ReturnCode_t wr = DDS_WaitSet_wait(ws, &active, &wait_step);
        if (wr == DDS_RETCODE_TIMEOUT) continue;
        if (wr != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", wr);
            return 1;
        }

        bool gc_triggered = condition_active(&active, gc_cond);
        bool sc_triggered = condition_active(&active, sc_cond);
        bool query_triggered = condition_active(&active, qc_as_cond);
        bool read_triggered = condition_active(&active, rc_as_cond);
        DDS_ConditionSeq_free(&active);

        if (gc_triggered) {
            fprintf(stderr, "FAIL: watchdog fired -- only received %d/%d samples\n", received, EXPECTED_SAMPLES);
            return 1;
        }
        if (!matched_logged && sc_triggered) {
            DDS_SubscriptionMatchedStatus status;
            DDS_DataReader_get_subscription_matched_status(dr, &status);
            if (status.current_count > 0) {
                printf("Subscriber: writer matched\n");
                matched_logged = true;
            }
        }

        if (!query_triggered && !read_triggered) continue;

        /* Drain the high-priority subset first via take_w_condition, then
         * whatever's left via a plain take_n. These are two separate calls,
         * each independently locking/unlocking the reader -- a sample can
         * arrive (from the RTPS receive thread) in the gap between them,
         * missing the first (query) take and getting swept up by the
         * second (unfiltered) one. Confirmed as a real, reproducible race
         * in zig/waitset and cpp/waitset (not just in theory): a
         * high-priority sample occasionally printed as "low-priority"
         * (still correctly *received*, just mislabeled) despite
         * take_w_condition's own filtering being correct at the instant it
         * ran. So: still call both -- take_w_condition is still genuinely
         * exercised, and still does the real draining -- but decide the
         * *label* from each sample's own already-deserialized `priority`
         * field rather than trusting which call it came from. */
        WaitsetSample high_values[EXPECTED_SAMPLES];
        zzdds_sample_info high_infos[EXPECTED_SAMPLES];
        memset(high_values, 0, sizeof(high_values));
        memset(high_infos, 0, sizeof(high_infos));
        int n_high = WaitsetSampleDataReader_take_w_condition(
            &reader, DDS_QueryCondition_as_DDS_ReadCondition(qc_cond), high_values, high_infos, EXPECTED_SAMPLES);

        WaitsetSample low_values[EXPECTED_SAMPLES];
        zzdds_sample_info low_infos[EXPECTED_SAMPLES];
        memset(low_values, 0, sizeof(low_values));
        memset(low_infos, 0, sizeof(low_infos));
        int n_low = WaitsetSampleDataReader_take_n(&reader, low_values, low_infos, EXPECTED_SAMPLES,
                                                     DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);

        for (int i = 0; i < n_high; i++) {
            if (!high_infos[i].valid_data) continue;
            if (high_values[i].priority > 4) {
                printf("Subscriber: high-priority count=%d priority=%d\n", high_values[i].count, high_values[i].priority);
            } else {
                printf("Subscriber: low-priority count=%d priority=%d\n", high_values[i].count, high_values[i].priority);
            }
            received++;
        }
        for (int i = 0; i < n_low; i++) {
            if (!low_infos[i].valid_data) continue;
            if (low_values[i].priority > 4) {
                printf("Subscriber: high-priority count=%d priority=%d\n", low_values[i].count, low_values[i].priority);
            } else {
                printf("Subscriber: low-priority count=%d priority=%d\n", low_values[i].count, low_values[i].priority);
            }
            received++;
        }
    }

    printf("Subscriber: received all %d samples.\n", EXPECTED_SAMPLES);

    atomic_store(&watchdog.stop, true);
    pthread_join(watchdog_thread, NULL);

    /* Well-behaved cleanup: detach and delete every condition explicitly
     * before tearing the reader down (contrast with publisher.c, which
     * deliberately does *not* do this for its StatusCondition). */
    DDS_WaitSet_detach_condition(ws, DDS_StatusCondition_as_DDS_Condition(sc));
    DDS_WaitSet_detach_condition(ws, DDS_ReadCondition_as_DDS_Condition(rc_cond));
    DDS_WaitSet_detach_condition(ws, DDS_ReadCondition_as_DDS_Condition(DDS_QueryCondition_as_DDS_ReadCondition(qc_cond)));
    DDS_WaitSet_detach_condition(ws, DDS_GuardCondition_as_DDS_Condition(gc));
    DDS_DataReader_delete_readcondition(dr, rc_cond);
    DDS_DataReader_delete_readcondition(dr, DDS_QueryCondition_as_DDS_ReadCondition(qc_cond));
    DDS_Subscriber_delete_datareader(sub, dr);

    zzdds_destroy_guardcondition(gc);
    zzdds_destroy_waitset(ws);

    printf("Subscriber: done.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
