/*
 * c/waitset -- subscriber. Direct C port of zig/waitset/subscriber.zig; see
 * docs/design/waitset-reference-app.md at the repo root for the full spec.
 *
 * One WaitSet, four conditions attached simultaneously:
 *
 *   - StatusCondition (SUBSCRIPTION_MATCHED_STATUS) -- logs the match.
 *   - QueryCondition ("priority > %0", param "4") -- real attach/trigger/
 *     query-expression/parameters exercise. Like cpp/waitset (see its
 *     subscriber.cpp comment), no binding's C ABI exposes a
 *     take_w_condition-equivalent operation yet, so QueryCondition's
 *     trigger fires the same as ReadCondition's, and the actual high/low
 *     split below is a plain field check in application code after
 *     draining -- an honest, currently-available demonstration, not a
 *     workaround for a bug.
 *   - ReadCondition (any sample/view/instance state) -- same trigger
 *     condition as QueryCondition above.
 *   - GuardCondition -- same watchdog-thread pattern as the publisher.
 *
 * Like publisher.c, branches on each held condition's own
 * get_trigger_value() directly rather than membership in wait()'s returned
 * DDS_ConditionSeq.
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

    if (DDS_WaitSet_attach_condition(ws, DDS_StatusCondition_as_DDS_Condition(sc)) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, DDS_ReadCondition_as_DDS_Condition(rc_cond)) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, DDS_ReadCondition_as_DDS_Condition(DDS_QueryCondition_as_DDS_ReadCondition(qc_cond))) != DDS_RETCODE_OK ||
        DDS_WaitSet_attach_condition(ws, DDS_GuardCondition_as_DDS_Condition(gc)) != DDS_RETCODE_OK)
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
        DDS_ConditionSeq_free(&active);

        if (DDS_GuardCondition_get_trigger_value(gc)) {
            fprintf(stderr, "FAIL: watchdog fired -- only received %d/%d samples\n", received, EXPECTED_SAMPLES);
            return 1;
        }
        if (!matched_logged && DDS_StatusCondition_get_trigger_value(sc)) {
            DDS_SubscriptionMatchedStatus status;
            DDS_DataReader_get_subscription_matched_status(dr, &status);
            if (status.current_count > 0) {
                printf("Subscriber: writer matched\n");
                matched_logged = true;
            }
        }

        bool query_triggered = DDS_QueryCondition_get_trigger_value(qc_cond);
        bool read_triggered = DDS_ReadCondition_get_trigger_value(rc_cond);
        if (!query_triggered && !read_triggered) continue;

        WaitsetSample values[EXPECTED_SAMPLES];
        zzdds_sample_info infos[EXPECTED_SAMPLES];
        memset(values, 0, sizeof(values));
        memset(infos, 0, sizeof(infos));
        int n = WaitsetSampleDataReader_take_n(&reader, values, infos, EXPECTED_SAMPLES,
                                                DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE);
        for (int i = 0; i < n; i++) {
            if (!infos[i].valid_data) continue;
            if (values[i].priority > 4) {
                printf("Subscriber: high-priority count=%d priority=%d\n", values[i].count, values[i].priority);
            } else {
                printf("Subscriber: low-priority count=%d priority=%d\n", values[i].count, values[i].priority);
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
