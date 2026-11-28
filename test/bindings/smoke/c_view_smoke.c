/* Read view types over a live reader (zidl --generate-views): a writer and a
 * reader in one participant, a sample written and taken with take_view. The
 * view's string and primitive sequences point into the loaned payload until
 * return_view, which ends the loan. Then the write twin, a builder: filled in
 * place in a write loan and published, or cancelled. Compiled and run by
 * `zig build test-bindings -Dc-binding=true`. */

/* nanosleep is POSIX, which strict C99 hides without this. */
#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#endif

#include "view_smoke.h"
#include "zzdds_c.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
static void sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <time.h>
static void sleep_ms(int ms) {
    struct timespec ts = { ms / 1000, (long)(ms % 1000) * 1000000L };
    nanosleep(&ts, NULL);
}
#endif

/* The domain build.zig gives this binary (ZZDDS_TEST_DOMAIN_BASE, as
 * test/support/domain.zig reads it), or 99 run directly. */
static uint32_t test_domain(void) {
    const char *base = getenv("ZZDDS_TEST_DOMAIN_BASE");
    return base != NULL ? (uint32_t)strtoul(base, NULL, 10) : 99u;
}

#define TIMEOUT_MS 10000
#define POLL_MS 10

static int within(const DDS_OctetSeq *payload, const void *p) {
    const uint8_t *b = (const uint8_t *)p;
    return b >= payload->_buffer && b < payload->_buffer + payload->_length;
}

/* take_view, waiting up to TIMEOUT_MS for a sample. */
static DDS_ReturnCode_t take_view_within(ViewSmokeFrameDataReader *reader, ViewSmokeFrameView *view, DDS_SampleInfo *info, DDS_OctetSeqSeq *loan_payloads, DDS_SampleInfoSeq *loan_infos) {
    for (int waited = 0;; waited += POLL_MS) {
        DDS_ReturnCode_t rc = ViewSmokeFrameDataReader_take_view(reader, view, info, loan_payloads, loan_infos);
        if (rc != DDS_RETCODE_NO_DATA || waited >= TIMEOUT_MS) return rc;
        sleep_ms(POLL_MS);
    }
}

int main(void) {
    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create();
    assert(factory != NULL);
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);
    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, test_domain(), NULL, NULL, 0);
    assert(dp != NULL);
    assert(ViewSmokeFrameTypeSupport_register(dp, "ViewSmokeFrame") == DDS_RETCODE_OK);
    DDS_Topic topic = DDS_DomainParticipant_create_topic(dp, "ViewSmokeC", "ViewSmokeFrame", NULL, NULL, 0);
    assert(topic != NULL);

    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp, NULL, NULL, 0);
    DDS_DataReaderQos dr_qos;
    DDS_Subscriber_get_default_datareader_qos(sub, &dr_qos);
    dr_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dr_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, DDS_Topic_as_DDS_TopicDescription(topic), &dr_qos, NULL, 0);
    assert(dr != NULL);

    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp, NULL, NULL, 0);
    DDS_DataWriterQos dw_qos;
    DDS_Publisher_get_default_datawriter_qos(pub, &dw_qos);
    dw_qos.reliability.kind = DDS_ReliabilityQosPolicyKind_RELIABLE_RELIABILITY_QOS;
    dw_qos.history.kind = DDS_HistoryQosPolicyKind_KEEP_ALL_HISTORY_QOS;
    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic, &dw_qos, NULL, 0);
    assert(dw != NULL);

    /* The reader matches before anything is written. */
    for (int waited = 0;; waited += POLL_MS) {
        DDS_PublicationMatchedStatus status;
        assert(DDS_DataWriter_get_publication_matched_status(dw, &status) == DDS_RETCODE_OK);
        if (status.current_count >= 1) break;
        assert(waited < TIMEOUT_MS);
        sleep_ms(POLL_MS);
    }

    uint8_t payload[64];
    for (int i = 0; i < 64; ++i) payload[i] = (uint8_t)(i * 3);
    double samples[3] = { 1.5, -2.25, 1e300 };
    char label[] = "view smoke";
    ViewSmokeFrame sample;
    memset(&sample, 0, sizeof sample);
    sample.id = 3u;
    sample.label = label;
    sample.payload = (uint8_t_seq){ 64, 64, payload, false };
    sample.samples = (double_seq){ 3, 3, samples, false };
    ViewSmokeFrameDataWriter writer;
    ViewSmokeFrameDataWriter_init(&writer, dw, ZIDL_XCDR2);
    assert(ViewSmokeFrameDataWriter_write(&writer, &sample, DDS_HANDLE_NIL) == DDS_RETCODE_OK);

    ViewSmokeFrameDataReader reader;
    ViewSmokeFrameDataReader_init(&reader, dr);
    ViewSmokeFrameView view;
    DDS_SampleInfo info;
    DDS_OctetSeqSeq loan_payloads = { 0, 0, NULL, false };
    DDS_SampleInfoSeq loan_infos = { 0, 0, NULL, false };
    DDS_ReturnCode_t rc = take_view_within(&reader, &view, &info, &loan_payloads, &loan_infos);
    assert(rc == DDS_RETCODE_OK && info.valid_data);

    /* Decoded in place: the string and sequences point into the loan. */
    const DDS_OctetSeq *loaned = &loan_payloads._buffer[0];
    assert(view.id == 3u);
    assert(strcmp(view.label, "view smoke") == 0 && within(loaned, view.label));
    assert(view.payload.count == 64 && within(loaned, view.payload.data));
    const uint8_t *bytes = ZIDL_CDR_VIEW_AS(&view.payload, uint8_t);
    assert(bytes != NULL && memcmp(bytes, payload, sizeof payload) == 0);
    double samples_out[3];
    assert(view.samples.count == 3 && within(loaned, view.samples.data));
    assert(zidl_cdr_view_copy(&view.samples, samples_out) == 0);
    assert(memcmp(samples_out, samples, sizeof samples) == 0);
    ViewSmokeFrameDataReader_return_view(&reader, &view, &loan_payloads, &loan_infos);

    /* Taken, so nothing is left. */
    assert(ViewSmokeFrameDataReader_take_view(&reader, &view, &info, &loan_payloads, &loan_infos) == DDS_RETCODE_NO_DATA);

    /* A builder's loan cancelled publishes nothing. */
    ViewSmokeFrameBuilder builder;
    memset(&builder, 0, sizeof builder);
    builder.id = 5u;
    builder.label = "cancelled";
    builder.payload.count = 8;
    ViewSmokeFrameWriteLoan wloan;
    assert(ViewSmokeFrameDataWriter_loan_builder(&writer, &builder, &wloan) == DDS_RETCODE_OK);
    assert(ViewSmokeFrameDataWriter_cancel_builder(&writer, &wloan) == DDS_RETCODE_OK);

    /* One filled in place and published reads back as if written. */
    memset(&builder, 0, sizeof builder);
    builder.id = 4u;
    builder.label = "builder smoke";
    builder.payload.count = 32;
    builder.samples.count = 2;
    assert(ViewSmokeFrameDataWriter_loan_builder(&writer, &builder, &wloan) == DDS_RETCODE_OK);
    uint8_t *octets = ViewSmokeFrameWriteLoan_data(&wloan, &builder.payload);
    assert(octets != NULL);
    for (int i = 0; i < 32; ++i) octets[i] = (uint8_t)(255 - i);
    double built[2] = { 3.0, -0.5 };
    void *doubles = ViewSmokeFrameWriteLoan_data(&wloan, &builder.samples);
    assert(doubles != NULL);
    memcpy(doubles, built, sizeof built); /* 8-byte elements may be unaligned */
    assert(ViewSmokeFrameDataWriter_publish_builder(&writer, &builder, &wloan) == DDS_RETCODE_OK);

    rc = take_view_within(&reader, &view, &info, &loan_payloads, &loan_infos);
    assert(rc == DDS_RETCODE_OK && info.valid_data);
    assert(view.id == 4u && strcmp(view.label, "builder smoke") == 0);
    bytes = ZIDL_CDR_VIEW_AS(&view.payload, uint8_t);
    assert(view.payload.count == 32 && bytes != NULL);
    for (int i = 0; i < 32; ++i) assert(bytes[i] == (uint8_t)(255 - i));
    assert(view.samples.count == 2 && zidl_cdr_view_copy(&view.samples, samples_out) == 0);
    assert(memcmp(samples_out, built, sizeof built) == 0);
    ViewSmokeFrameDataReader_return_view(&reader, &view, &loan_payloads, &loan_infos);
    assert(ViewSmokeFrameDataReader_take_view(&reader, &view, &info, &loan_payloads, &loan_infos) == DDS_RETCODE_NO_DATA);

    assert(DDS_DomainParticipant_delete_contained_entities(dp) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_participant(dds_factory, dp) == DDS_RETCODE_OK);
    assert(zzdds_DomainParticipantFactory_destroy(factory) == DDS_RETCODE_OK);
    printf("c_view_smoke: OK\n");
    return 0;
}
