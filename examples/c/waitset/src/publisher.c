/*
 * c/waitset -- publisher. Direct C port of zig/waitset/publisher.zig; see
 * docs/design/waitset-reference-app.md at the repo root for the full spec.
 *
 * Drives its whole lifecycle through a single WaitSet with two conditions
 * attached at once, instead of a listener:
 *
 *   - StatusCondition (PUBLICATION_MATCHED_STATUS) -- reused across two
 *     separate wait phases: first waiting for a reader to match, later
 *     waiting for it to disconnect again.
 *   - GuardCondition -- a background "watchdog" thread sets this if the
 *     whole run exceeds its overall deadline. Real cross-thread concurrency
 *     on the same WaitSet/GuardCondition -- the same exercise zig/waitset's
 *     own watchdog demonstrates.
 *
 * Branches on membership in wait()'s returned DDS_ConditionSeq, the
 * spec-idiomatic pattern (DDS v1.4 Annex, "iterate active_conditions") --
 * a handle this program already holds (e.g. DDS_GuardCondition_as_DDS_Condition(gc))
 * is `==`-comparable against what wait() returns for the same underlying
 * condition. Previously worked around here by calling each condition's own
 * get_trigger_value() directly instead, because that identity didn't hold
 * at the C-ABI level -- see zidl/docs/design/binding-c-abi-identity.md for
 * the bug and its fix.
 *
 * After the run completes, delete_datawriter() is called WITHOUT first
 * detaching the writer's StatusCondition from the WaitSet -- deliberately,
 * to demonstrate that this is safe.
 *
 * Required stdout markers: "Create topic:", "Create writer for topic:",
 * "Publisher: reader matched", "Publisher: wrote count=", "Publisher:
 * reader disconnected", "Publisher: StatusCondition remained attached
 * through delete_datawriter (safe).", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "waitset_sample.h"
#include "zzdds_c.h"
#include "zzdds.h"

#include <stdlib.h> /* malloc/free, used below before this file's own <stdlib.h> include */
#ifdef _WIN32
#include <windows.h>
typedef HANDLE portable_thread_t;
typedef struct { void *(*fn)(void *); void *arg; } portable_thread_start_t;
static DWORD WINAPI portable_thread_trampoline(LPVOID p) {
    portable_thread_start_t *s = (portable_thread_start_t *)p;
    void *(*fn)(void *) = s->fn;
    void *arg = s->arg;
    free(s);
    fn(arg);
    return 0;
}
static int portable_thread_create(portable_thread_t *t, void *(*fn)(void *), void *arg) {
    portable_thread_start_t *s = (portable_thread_start_t *)malloc(sizeof(*s));
    if (!s) return -1;
    s->fn = fn;
    s->arg = arg;
    *t = CreateThread(NULL, 0, portable_thread_trampoline, s, 0, NULL);
    if (!*t) { free(s); return -1; }
    return 0;
}
static void portable_thread_join(portable_thread_t t) { WaitForSingleObject(t, INFINITE); CloseHandle(t); }
#else
#include <pthread.h>
typedef pthread_t portable_thread_t;
static int portable_thread_create(portable_thread_t *t, void *(*fn)(void *), void *arg) { return pthread_create(t, NULL, fn, arg); }
static void portable_thread_join(portable_thread_t t) { pthread_join(t, NULL); }
#endif
/* atomic_bool/atomic_int's inter-thread guarantees matter here: these
 * fields are written from a DDS listener callback (a different thread)
 * than main()'s polling loop. <stdatomic.h> needs a compiler flag on
 * MSVC this repo's example CMakeLists don't set (error C1189: "C atomic
 * support is not enabled") -- rather than chase that flag, or weaken this
 * to a plain volatile flag (drops the actual cross-thread memory-ordering
 * guarantee, not just the type -- flagged in PR review, see git history),
 * use Win32's Interlocked* intrinsics directly on Windows, real C11
 * atomics elsewhere. atomic_init() sites stay plain assignments on both
 * platforms -- they run before the listener thread exists, and the C
 * standard's own atomic_init() is itself non-atomic, meant exactly for
 * that pre-concurrency case. */
#ifdef _WIN32
#include <windows.h>
typedef volatile LONG portable_atomic_t;
static void patomic_store(portable_atomic_t *a, int v) { InterlockedExchange(a, v); }
static int patomic_load(portable_atomic_t *a) { return InterlockedExchangeAdd(a, 0); }
#else
#include <stdatomic.h>
typedef atomic_int portable_atomic_t;
static void patomic_store(portable_atomic_t *a, int v) { atomic_store(a, v); }
static int patomic_load(portable_atomic_t *a) { return atomic_load(a); }
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <unistd.h>
static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }
#endif

#define SAMPLE_COUNT 10
#define WAIT_STEP_SEC 1
#define OVERALL_DEADLINE_MS 25000
#define WATCHDOG_POLL_MS 50

typedef struct {
    DDS_GuardCondition gc;
    portable_atomic_t stop;
} Watchdog;

static void *watchdog_run(void *arg) {
    Watchdog *w = (Watchdog *)arg;
    int elapsed_ms = 0;
    while (!patomic_load(&w->stop)) {
        if (elapsed_ms >= OVERALL_DEADLINE_MS) {
            printf("Watchdog: overall deadline exceeded, triggering GuardCondition\n");
            DDS_GuardCondition_set_trigger_value(w->gc, true);
            return NULL;
        }
        sleep_ms(WATCHDOG_POLL_MS);
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

    if (WaitsetSampleTypeSupport_register(dp, "WaitsetSample") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "WaitsetSample", "WaitsetSample", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: WaitsetSample\n");

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    if (!pub) {
        fprintf(stderr, "FAIL: create_publisher() failed\n");
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
    printf("Create writer for topic: WaitsetSample\n");

    /* ── WaitSet setup: StatusCondition + GuardCondition together ── */

    DDS_WaitSet ws = zzdds_create_waitset();
    if (zzdds_waitset_is_nil(ws)) {
        fprintf(stderr, "FAIL: create_waitset() failed\n");
        return 1;
    }

    DDS_Entity dw_entity = DDS_DataWriter_as_DDS_Entity(dw);
    DDS_StatusCondition sc = DDS_Entity_get_statuscondition(dw_entity);
    if (DDS_StatusCondition_set_enabled_statuses(sc, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_enabled_statuses() failed\n");
        return 1;
    }
    if (DDS_WaitSet_attach_condition(ws, DDS_StatusCondition_as_DDS_Condition(sc)) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: attach_condition(StatusCondition) failed\n");
        return 1;
    }

    DDS_GuardCondition gc = zzdds_create_guardcondition();
    if (zzdds_guardcondition_is_nil(gc)) {
        fprintf(stderr, "FAIL: create_guardcondition() failed\n");
        return 1;
    }
    if (DDS_WaitSet_attach_condition(ws, DDS_GuardCondition_as_DDS_Condition(gc)) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: attach_condition(GuardCondition) failed\n");
        return 1;
    }

    Watchdog watchdog;
    watchdog.gc = gc;
    watchdog.stop = false;
    portable_thread_t watchdog_thread;
    if (portable_thread_create(&watchdog_thread, watchdog_run, &watchdog) != 0) {
        fprintf(stderr, "FAIL: watchdog thread creation failed\n");
        return 1;
    }

    DDS_Condition gc_cond = DDS_GuardCondition_as_DDS_Condition(gc);
    DDS_Condition sc_cond = DDS_StatusCondition_as_DDS_Condition(sc);

    /* ── Wait for a reader to match ── */

    DDS_Duration_t wait_step = {WAIT_STEP_SEC, 0};
    bool matched = false;
    while (!matched) {
        DDS_ConditionSeq active;
        memset(&active, 0, sizeof(active));
        DDS_ReturnCode_t rc = DDS_WaitSet_wait(ws, &active, &wait_step);
        if (rc == DDS_RETCODE_TIMEOUT) continue;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", rc);
            return 1;
        }

        bool gc_triggered = condition_active(&active, gc_cond);
        bool sc_triggered = condition_active(&active, sc_cond);
        DDS_ConditionSeq_free(&active);

        if (gc_triggered) {
            fprintf(stderr, "FAIL: watchdog fired before any reader matched\n");
            return 1;
        }
        if (sc_triggered) {
            DDS_PublicationMatchedStatus status;
            DDS_DataWriter_get_publication_matched_status(dw, &status);
            if (status.current_count > 0) {
                printf("Publisher: reader matched\n");
                matched = true;
            }
        }
    }

    /* ── Write samples: priority = count ── */

    WaitsetSampleDataWriter writer;
    WaitsetSampleDataWriter_init(&writer, dw, ZIDL_XCDR1);
    for (int i = 0; i < SAMPLE_COUNT; i++) {
        WaitsetSample sample;
        memset(&sample, 0, sizeof(sample));
        sample.count = i;
        sample.priority = i;
        strncpy(sample.message, "Hello waitset!", sizeof(sample.message) - 1);

        if (WaitsetSampleDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) != 0) {
            fprintf(stderr, "FAIL: write() failed at count=%d\n", i);
            return 1;
        }
        printf("Publisher: wrote count=%d priority=%d\n", i, i);
    }

    /* ── Wait for the reader to disconnect again ── */

    bool disconnected = false;
    while (!disconnected) {
        DDS_ConditionSeq active;
        memset(&active, 0, sizeof(active));
        DDS_ReturnCode_t rc = DDS_WaitSet_wait(ws, &active, &wait_step);
        if (rc == DDS_RETCODE_TIMEOUT) continue;
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: WaitSet.wait() returned %d\n", rc);
            return 1;
        }

        bool gc_triggered = condition_active(&active, gc_cond);
        bool sc_triggered = condition_active(&active, sc_cond);
        DDS_ConditionSeq_free(&active);

        if (gc_triggered) {
            fprintf(stderr, "FAIL: watchdog fired before the reader disconnected\n");
            return 1;
        }
        if (sc_triggered) {
            DDS_PublicationMatchedStatus status;
            DDS_DataWriter_get_publication_matched_status(dw, &status);
            if (status.current_count == 0) {
                printf("Publisher: reader disconnected\n");
                disconnected = true;
            }
        }
    }

    patomic_store(&watchdog.stop, true);
    portable_thread_join(watchdog_thread);

    /* Well-behaved cleanup for the GuardCondition... */
    DDS_WaitSet_detach_condition(ws, DDS_GuardCondition_as_DDS_Condition(gc));
    /* ...but the StatusCondition is deliberately left attached through
     * delete_datawriter() below, to demonstrate that this is safe. */
    printf("Publisher: StatusCondition remained attached through delete_datawriter (safe).\n");
    DDS_Publisher_delete_datawriter(pub, dw);

    zzdds_destroy_guardcondition(gc);
    zzdds_destroy_waitset(ws);

    printf("Publisher: done.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
