/* An application's own runtime from C (zzdds.idl's ExecutionRuntime): a
 * manual runtime selected by a factory runs two participants' discovery only
 * inside zzdds_ExecutionRuntime_drive, on this thread. The runtime refuses
 * destroy while it is in use, and goes once the factory lets go of it.
 * Compiled and run by `zig build test-bindings -Dc-binding=true`. */

#include "zzdds_c.h"

#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

/* The domain build.zig gives this binary (ZZDDS_TEST_DOMAIN_BASE, as
 * test/support/domain.zig reads it), or 99 run directly. */
static uint32_t test_domain(void) {
    const char *base = getenv("ZZDDS_TEST_DOMAIN_BASE");
    return base != NULL ? (uint32_t)strtoul(base, NULL, 10) : 99u;
}

static int matched(DDS_DataWriter dw) {
    DDS_PublicationMatchedStatus status;
    if (DDS_DataWriter_get_publication_matched_status(dw, &status) != DDS_RETCODE_OK) return 0;
    return status.current_count == 1;
}

int main(void) {
    zzdds_RuntimeConfig bad = { zzdds_RuntimeMode_RUNTIME_MODE_HOSTED, 0, 8 };
    assert(zzdds_ExecutionRuntime_create(&bad) == NULL);

    zzdds_RuntimeConfig config = { zzdds_RuntimeMode_RUNTIME_MODE_MANUAL, 0, 8 };
    zzdds_ExecutionRuntime rt = zzdds_ExecutionRuntime_create(&config);
    assert(rt != NULL);
    assert(zzdds_ExecutionRuntime_get_mode(rt) == zzdds_RuntimeMode_RUNTIME_MODE_MANUAL);
    assert(zzdds_ExecutionRuntime_get_state(rt) == zzdds_RuntimeState_RUNTIME_STATE_RUNNING);

    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create();
    assert(factory != NULL);
    assert(zzdds_DomainParticipantFactory_set_default_runtime(factory, rt) == DDS_RETCODE_OK);
    assert(zzdds_DomainParticipantFactory_get_default_runtime(factory) == rt);
    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

    DDS_DomainParticipant dp_w = DDS_DomainParticipantFactory_create_participant(dds_factory, test_domain(), NULL, NULL, 0);
    DDS_DomainParticipant dp_r = DDS_DomainParticipantFactory_create_participant(dds_factory, test_domain(), NULL, NULL, 0);
    assert(dp_w != NULL && dp_r != NULL);
    DDS_Topic topic_w = DDS_DomainParticipant_create_topic(dp_w, "CRuntimeSmoke", "CRuntimeSmokeType", NULL, NULL, 0);
    DDS_Topic topic_r = DDS_DomainParticipant_create_topic(dp_r, "CRuntimeSmoke", "CRuntimeSmokeType", NULL, NULL, 0);
    assert(topic_w != NULL && topic_r != NULL);
    DDS_Publisher pub = DDS_DomainParticipant_create_publisher(dp_w, NULL, NULL, 0);
    DDS_Subscriber sub = DDS_DomainParticipant_create_subscriber(dp_r, NULL, NULL, 0);
    DDS_DataWriter dw = DDS_Publisher_create_datawriter(pub, topic_w, NULL, NULL, 0);
    DDS_DataReader dr = DDS_Subscriber_create_datareader(sub, zzdds_Topic_as_topic_description(DDS_Topic_as_zzdds_Topic(topic_r)), NULL, NULL, 0);
    assert(dw != NULL && dr != NULL);

    /* Discovery runs only when driven. */
    DDS_Duration_t wait = { 0, 20000000u };
    zzdds_DriveResult result;
    int rounds = 0;
    while (!matched(dw)) {
        assert(zzdds_ExecutionRuntime_drive(rt, 64, &wait, &result) == DDS_RETCODE_OK);
        assert(++rounds < 1000); /* 20 s */
    }
    assert(result.state == zzdds_RuntimeState_RUNTIME_STATE_RUNNING);
    assert(zzdds_ExecutionRuntime_drive(rt, 0, &wait, &result) == DDS_RETCODE_BAD_PARAMETER);

    /* Strict: the participants and the factory still use it. */
    assert(zzdds_ExecutionRuntime_destroy(rt) == DDS_RETCODE_PRECONDITION_NOT_MET);
    assert(DDS_DomainParticipant_delete_contained_entities(dp_w) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipant_delete_contained_entities(dp_r) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_participant(dds_factory, dp_w) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_participant(dds_factory, dp_r) == DDS_RETCODE_OK);
    assert(zzdds_ExecutionRuntime_destroy(rt) == DDS_RETCODE_PRECONDITION_NOT_MET);
    assert(zzdds_DomainParticipantFactory_set_default_runtime(factory, NULL) == DDS_RETCODE_OK);
    assert(zzdds_DomainParticipantFactory_get_default_runtime(factory) == NULL);
    assert(zzdds_ExecutionRuntime_destroy(rt) == DDS_RETCODE_OK);
    zzdds_DomainParticipantFactory_release(factory);
    printf("c_runtime_smoke: OK\n");
    return 0;
}
