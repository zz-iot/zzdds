/*
 * c/raw-loan -- subscriber. Direct C port of zig/raw-loan/subscriber.zig;
 * see docs/design/raw-loan-reference-app.md at the repo root for the full
 * spec. Bypasses TypeSupport marshaling entirely: every sample is read via
 * take_raw() in loan mode (cdr_payloads._maximum == 0 on entry -- the
 * returned bytes borrow directly from reader history, no copy) ->
 * deserialize straight out of the borrowed bytes -> return_loan_raw(),
 * instead of the generated typed DataReader_take() a normal example would
 * use. Strict ordering check doubles as the assertion that the publisher's
 * cancelled sample (see publisher.c) never arrives.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * reader for topic:", "Subscriber: received (loan) sequence=",
 * "Subscriber: received all N samples in order." Any failure path prints
 * a line starting "FAIL:" and exits nonzero.
 */
#include "loaned_ping.h"
#include "zzdds_c.h"
#include "zidl_cdr.h"

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

#define SAMPLE_COUNT 5
#define RECEIVE_TIMEOUT_MS 30000
#define POLL_PERIOD_MS 20

typedef struct {
    /* Only ever touched from the listener's dispatch thread. */
    int expected_next;
    portable_atomic_t all_received;
} SubState;

static void on_data_available(DDS_DataReader the_reader, void *listener_data) {
    SubState *state = (SubState *)listener_data;

    for (;;) {
        /* Zero-initialized cdr_payloads has _maximum == 0 -- the spec's own
         * inout-collection convention for "loan rather than copy" (see
         * dcps.idl's take_raw doc comment). key_hashes/sample_infos are
         * always plain copies regardless of mode. */
        DDS_OctetSeqSeq payloads;
        DDS_OctetSeq hashes;
        DDS_SampleInfoSeq infos;
        memset(&payloads, 0, sizeof(payloads));
        memset(&hashes, 0, sizeof(hashes));
        memset(&infos, 0, sizeof(infos));

        DDS_ReturnCode_t rc = DDS_DataReader_take_raw(
            the_reader, &payloads, &hashes, &infos,
            DDS_HANDLE_NIL, NULL,
            DDS_ANY_SAMPLE_STATE, DDS_ANY_VIEW_STATE, DDS_ANY_INSTANCE_STATE, 1);
        if (rc != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: take_raw() returned %d\n", rc);
            exit(1);
        }
        /* take_raw's own return code is RETCODE_OK even when nothing is
         * available -- check payloads._length for "did we actually get
         * one", not rc. */
        if (payloads._length == 0) break;

        DDS_OctetSeq desc = payloads._buffer[0];
        DDS_SampleInfo info = infos._buffer[0];
        if (info.valid_data) {
            LoanedPing value;
            memset(&value, 0, sizeof(value));
            ZidlCdrReader reader;
            if (zidl_cdr_reader_init(&reader, desc._buffer, desc._length) != 0) {
                fprintf(stderr, "FAIL: zidl_cdr_reader_init() on loaned payload failed\n");
                exit(1);
            }
            if (LoanedPing_deserialize(&reader, &value) != 0) {
                fprintf(stderr, "FAIL: LoanedPing_deserialize() on loaned payload failed\n");
                exit(1);
            }

            if (value.seq_num != state->expected_next) {
                fprintf(stderr, "FAIL: expected sequence=%d but got sequence=%d\n", state->expected_next, value.seq_num);
                exit(1);
            }
            printf("Subscriber: received (loan) sequence=%d\n", value.seq_num);
            state->expected_next++;
        }

        if (DDS_DataReader_return_loan_raw(the_reader, &payloads, &hashes, &infos) != DDS_RETCODE_OK) {
            fprintf(stderr, "FAIL: return_loan_raw() failed\n");
            exit(1);
        }

        /* Signal completion only after the loan is actually returned --
         * otherwise main() could race ahead and call delete_datareader()
         * while this loan is still outstanding, failing with
         * PRECONDITION_NOT_MET. */
        if (state->expected_next == SAMPLE_COUNT) {
            patomic_store(&state->all_received, true);
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

    if (LoanedPingTypeSupport_register(dp, "LoanedPing") != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: register_type_support failed\n");
        return 1;
    }

    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "LoanedPing", "LoanedPing", NULL, NULL, 0);
    if (!topic) {
        fprintf(stderr, "FAIL: create_topic() failed\n");
        return 1;
    }
    printf("Create topic: LoanedPing\n");

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    if (!sub) {
        fprintf(stderr, "FAIL: create_subscriber() failed\n");
        return 1;
    }

    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;

    SubState state;
    state.expected_next = 0;
    state.all_received = false;

    DDS_DataReaderListener listener;
    memset(&listener, 0, sizeof(listener));
    listener.listener_data = &state;
    listener.on_data_available = on_data_available;

    DDS_TopicDescription topic_desc = zzdds_topic_as_description(topic);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, topic_desc, &dr_qos, &listener, DDS_DATA_AVAILABLE_STATUS);
    if (!dr) {
        fprintf(stderr, "FAIL: create_datareader() failed\n");
        return 1;
    }
    printf("Create reader for topic: LoanedPing\n");

    printf("Subscriber: waiting for %d samples...\n", SAMPLE_COUNT);
    for (int waited_ms = 0; !patomic_load(&state.all_received); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= RECEIVE_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: only received %d/%d samples within %ds\n",
                    state.expected_next, SAMPLE_COUNT, RECEIVE_TIMEOUT_MS / 1000);
            return 1;
        }
        sleep_ms(POLL_PERIOD_MS);
    }

    /* Tear the reader down immediately -- the publisher is blocked waiting
     * for our matched-reader count to drop back to zero. */
    DDS_Subscriber_delete_datareader(sub, dr);

    printf("Subscriber: received all %d samples in order.\n", SAMPLE_COUNT);
    zzdds_destroy_factory(factory);
    return 0;
}
