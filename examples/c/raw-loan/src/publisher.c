/*
 * c/raw-loan -- publisher. Direct C port of zig/raw-loan/publisher.zig; see
 * docs/design/raw-loan-reference-app.md at the repo root for the full spec.
 * Bypasses TypeSupport marshaling entirely: every published sample goes
 * through loan_raw() (borrow a buffer sized for the real CDR payload) ->
 * serialize directly into it (zidl_cdr's counting-mode pass sizes it, then
 * a fixed-mode pass writes straight into the loaned buffer -- a true
 * zero-copy write, unlike zig/raw-loan's memcpy workaround; see the spec
 * doc's "Zig-specific gap" section) -> publish_loan_raw(), instead of the
 * generated typed DataWriter_write() a normal example would use. Also
 * demonstrates the cancel path -- loan_raw() then return_loan_raw()
 * without ever publishing -- once, so the subscriber has a genuine
 * negative to assert against.
 *
 * Required stdout markers (see the spec doc): "Create topic:", "Create
 * writer for topic:", "Publisher: published (loan) sequence=", "Publisher:
 * cancelling loan for sequence=", "Publisher: done." Any failure path
 * prints a line starting "FAIL:" and exits nonzero.
 */
#include "loaned_ping.h"
#include "zzdds_c.h"
#include "zzdds.h"
#include "zidl_cdr.h"

#include <signal.h> /* sig_atomic_t */
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
#define CANCELLED_SEQ_NUM (-1)
#define READER_READY_TIMEOUT_MS 10000
#define DRAIN_TIMEOUT_MS 15000
#define POLL_PERIOD_MS 20

typedef struct {
    volatile sig_atomic_t reader_ready;
    volatile sig_atomic_t ever_matched;
    volatile sig_atomic_t matched_current_count;
} PubState;

static void on_reliable_reader_ready(DDS_InstanceHandle_t reader_handle, bool is_ready, void *listener_data) {
    (void)reader_handle;
    PubState *state = (PubState *)listener_data;
    if (is_ready) state->reader_ready = true;
    printf("on_reliable_reader_ready() is_ready=%s\n", is_ready ? "true" : "false");
}

static void on_publication_matched(DDS_DataWriter writer, const DDS_PublicationMatchedStatus *status, void *listener_data) {
    (void)writer;
    PubState *state = (PubState *)listener_data;
    state->matched_current_count = status->current_count;
    if (status->current_count > 0) state->ever_matched = true;
    printf("on_publication_matched() current_count=%d\n", status->current_count);
}

/* Loan a buffer sized for `value`, serialize directly into it via a
 * counting pass (to learn the size) then a fixed-mode pass (to write into
 * the real loaned buffer) -- true zero-copy, no intermediate malloc'd
 * buffer. Returns 0 and leaves the loan outstanding in *cdr_payload on
 * success, or -1 with no outstanding loan on any failure. */
static int loan_and_serialize(DDS_DataWriter dw, const LoanedPing *value, DDS_OctetSeq *cdr_payload) {
    ZidlCdrWriter counting;
    zidl_cdr_writer_init_counting(&counting, ZIDL_XCDR1);
    if (zidl_cdr_write_encap(&counting) != 0) return -1;
    if (LoanedPing_serialize(&counting, value) != 0) return -1;

    memset(cdr_payload, 0, sizeof(*cdr_payload));
    if (DDS_DataWriter_loan_raw(dw, (uint32_t)counting.len, cdr_payload) != DDS_RETCODE_OK) return -1;

    ZidlCdrWriter fixed;
    zidl_cdr_writer_init_fixed(&fixed, cdr_payload->_buffer, cdr_payload->_maximum, ZIDL_XCDR1);
    if (zidl_cdr_write_encap(&fixed) != 0) {
        DDS_DataWriter_return_loan_raw(dw, cdr_payload);
        return -1;
    }
    if (LoanedPing_serialize(&fixed, value) != 0) {
        DDS_DataWriter_return_loan_raw(dw, cdr_payload);
        return -1;
    }
    return 0;
}

static int publish_loaned(DDS_DataWriter dw, const LoanedPing *value) {
    DDS_OctetSeq cdr_payload;
    if (loan_and_serialize(dw, value, &cdr_payload) != 0) return -1;

    uint8_t hash_bytes[16];
    LoanedPing_compute_key_hash(value, hash_bytes);
    DDS_OctetSeq key_hash;
    key_hash._buffer = hash_bytes;
    key_hash._length = 16;
    key_hash._maximum = 16;
    key_hash._release = false;

    if (DDS_DataWriter_publish_loan_raw(dw, &cdr_payload, &key_hash, DDS_HANDLE_NIL, DDS_WriteKind_ALIVE_WRITE_KIND) != DDS_RETCODE_OK) return -1;
    return 0;
}

static int loan_and_cancel(DDS_DataWriter dw, const LoanedPing *value) {
    DDS_OctetSeq cdr_payload;
    if (loan_and_serialize(dw, value, &cdr_payload) != 0) return -1;
    if (DDS_DataWriter_return_loan_raw(dw, &cdr_payload) != DDS_RETCODE_OK) return -1;
    return 0;
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
    printf("Create writer for topic: LoanedPing\n");

    PubState state;
    state.reader_ready = false;
    state.ever_matched = false;
    state.matched_current_count = 0;

    zzdds_DataWriter zdw = DDS_DataWriter_as_zzdds_DataWriter(dw);
    zzdds_DataWriterListenerEx listener_ex;
    memset(&listener_ex, 0, sizeof(listener_ex));
    listener_ex.listener_data = &state;
    listener_ex.on_publication_matched = on_publication_matched;
    listener_ex.on_reliable_reader_ready = on_reliable_reader_ready;
    if (zzdds_DataWriter_set_listener_ex(zdw, &listener_ex, DDS_PUBLICATION_MATCHED_STATUS) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: set_listener_ex failed\n");
        return 1;
    }

    for (int waited_ms = 0; !(state.reader_ready); waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= READER_READY_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: no reliable reader became ready within %ds\n", READER_READY_TIMEOUT_MS / 1000);
            return 1;
        }
        sleep_ms(POLL_PERIOD_MS);
    }

    /* -- Write-loan phase: publish SAMPLE_COUNT pings via loan_raw/publish_loan_raw -- */
    for (int seq = 0; seq < SAMPLE_COUNT; seq++) {
        LoanedPing sample;
        memset(&sample, 0, sizeof(sample));
        sample.seq_num = seq;
        if (publish_loaned(dw, &sample) != 0) {
            fprintf(stderr, "FAIL: publish_loaned() failed at sequence=%d\n", seq);
            return 1;
        }
        printf("Publisher: published (loan) sequence=%d\n", seq);
    }

    /* -- Cancel phase: loan a buffer, then return it unpublished -- */
    {
        LoanedPing cancelled;
        memset(&cancelled, 0, sizeof(cancelled));
        cancelled.seq_num = CANCELLED_SEQ_NUM;
        if (loan_and_cancel(dw, &cancelled) != 0) {
            fprintf(stderr, "FAIL: loan_and_cancel() failed\n");
            return 1;
        }
        printf("Publisher: cancelling loan for sequence=%d (never published)\n", CANCELLED_SEQ_NUM);
    }

    for (int waited_ms = 0;
         !((state.ever_matched) && (state.matched_current_count) == 0);
         waited_ms += POLL_PERIOD_MS) {
        if (waited_ms >= DRAIN_TIMEOUT_MS) {
            fprintf(stderr, "FAIL: subscriber did not disconnect within %ds\n", DRAIN_TIMEOUT_MS / 1000);
            return 1;
        }
        sleep_ms(POLL_PERIOD_MS);
    }

    /* Every loan above was either published or explicitly cancelled -- an
     * outstanding loan would make delete_datawriter fail with
     * PRECONDITION_NOT_MET (see docs/design/raw-loan-api.md). */
    if (DDS_Publisher_delete_datawriter(pub, dw) != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: delete_datawriter() did not return RETCODE_OK -- an outstanding loan leaked\n");
        return 1;
    }

    printf("Publisher: done.\n");
    zzdds_destroy_factory(factory);
    return 0;
}
