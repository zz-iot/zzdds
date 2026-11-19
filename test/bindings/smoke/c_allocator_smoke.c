/* Binding smoke test for zzdds_c.h's plain C-ABI allocator-injection
 * surface: zzdds_DomainParticipantFactory_create_with_allocator(const ZidlAllocator*).
 * Compiled and run by `zig build test-bindings -Dc-binding=true`.
 *
 * Proves the C-ABI allocator injection actually reaches every downstream
 * allocation (factory bootstrap, participant creation), not just that the
 * call compiles -- the plain-C counterpart to cpp_allocator_smoke.cpp's
 * happy-path test (no C++ wrapper/PMR layer exists at this level, so
 * cpp_allocator_smoke.cpp's PMR-exhaustion case has no C equivalent).
 * Hand-rolled tracking allocator, matching zzdds-examples' c/custom-allocator
 * example's style -- proving the plain vtable contract, not attribution
 * (that's what -Ddebug-allocator=true is for). */

#include "zzdds_c.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Atomic: on the shared runtime the factory's worker threads allocate and
// free through this allocator too.
static atomic_size_t g_alloc_calls = 0, g_free_calls = 0;

static void *track_alloc(void *ctx, size_t len, size_t alignment) {
    (void)ctx;
    (void)alignment;
    g_alloc_calls++;
    return malloc(len);
}

static bool track_resize(void *ctx, void *ptr, size_t old_len, size_t new_len, size_t alignment) {
    (void)ctx;
    (void)ptr;
    (void)old_len;
    (void)new_len;
    (void)alignment;
    return false;
}

static void track_free(void *ctx, void *ptr, size_t len, size_t alignment) {
    (void)ctx;
    (void)len;
    (void)alignment;
    g_free_calls++;
    free(ptr);
}

int main(void) {
    /* C ABI blocks made before any factory, from libc: under -Ddebug-allocator
     * the first default factory registers the DebugAllocator process-wide,
     * and these must still be freed and moved correctly after that. */
    void *early = zidl_cdr_alloc(32);
    char *early_str = zidl_cdr_strdup("early");
    void *early_moved = zidl_cdr_alloc(16);
    assert(early != NULL && early_str != NULL && early_moved != NULL);
    memset(early_moved, 0x5A, 16);

    ZidlAllocator tracking = {NULL, track_alloc, track_resize, track_free};

    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create_with_allocator(&tracking);
    assert(factory != NULL);
    /* Bootstrapping the factory itself (FactoryOwner) already allocates. */
    assert(g_alloc_calls > 0);
    size_t calls_after_bootstrap = g_alloc_calls;

    DDS_DomainParticipantFactory dds_factory = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(factory);

    /* Creating a participant spins up a real UdpTransport + SpdpSedpDiscovery
     * + DomainParticipantFactoryImpl/DomainParticipantImpl stack -- every one
     * of those allocates, and every one must inherit the injected allocator,
     * not silently fall back to the libc-backed default. */
    DDS_DomainParticipant dp = DDS_DomainParticipantFactory_create_participant(dds_factory, 0, NULL, NULL, 0);
    assert(dp != NULL);
    assert(g_alloc_calls > calls_after_bootstrap);

    /* NULL is every interface's nil: nothing found, or nothing made, is NULL;
     * NULL given as an object or argument is the nil, which refuses. */
    assert(DDS_DomainParticipant_lookup_topicdescription(dp, "NoSuchTopic") == NULL);
    assert(DDS_Topic_as_DDS_TopicDescription(NULL) == NULL);
    assert(DDS_Entity_enable(NULL) == DDS_RETCODE_ERROR);
    assert(DDS_Entity_get_instance_handle(NULL) == DDS_HANDLE_NIL);
    assert(DDS_DomainParticipant_delete_topic(dp, NULL) != DDS_RETCODE_OK);
    assert(DDS_DataWriter_as_zzdds_DataWriter(NULL) == NULL);
    zzdds_DomainParticipantFactory_release(NULL);

    DDS_ReturnCode_t rc = DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    assert(rc == DDS_RETCODE_OK);

    zzdds_DomainParticipantFactory_release(factory);

    /* Everything torn down, nothing leaked. */
    assert(g_alloc_calls == g_free_calls);

    /* The generated strict destroy refuses while a participant remains. */
    zzdds_DomainParticipantFactory own = zzdds_DomainParticipantFactory_create();
    assert(own != NULL);
    zidl_cdr_free(early, 32);
    zidl_cdr_free_str(early_str);
    unsigned char *moved = zidl_cdr_realloc(early_moved, 16, 4096);
    assert(moved != NULL && moved[0] == 0x5A && moved[15] == 0x5A);
    zidl_cdr_free(moved, 4096);
    DDS_DomainParticipantFactory own_dds = zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(own);
    DDS_DomainParticipant own_dp = DDS_DomainParticipantFactory_create_participant(own_dds, 0, NULL, NULL, 0);
    assert(own_dp != NULL);
    assert(zzdds_DomainParticipantFactory_destroy(own) == DDS_RETCODE_PRECONDITION_NOT_MET);
    /* delete_contained_entities empties it, so destroy then succeeds. */
    assert(DDS_DomainParticipantFactory_delete_contained_entities(own_dds) == DDS_RETCODE_OK);
    assert(zzdds_DomainParticipantFactory_destroy(own) == DDS_RETCODE_OK);

    /* The process-wide factory: the same one until delete_instance, which
     * refuses while it has participants. */
    assert(DDS_DomainParticipantFactory_delete_instance() == DDS_RETCODE_OK);
    DDS_DomainParticipantFactory inst = DDS_DomainParticipantFactory_get_instance();
    assert(inst != NULL);
    assert(DDS_DomainParticipantFactory_get_instance() == inst);
    DDS_DomainParticipant inst_dp = DDS_DomainParticipantFactory_create_participant(inst, 0, NULL, NULL, 0);
    assert(inst_dp != NULL);
    assert(DDS_DomainParticipantFactory_delete_instance() == DDS_RETCODE_PRECONDITION_NOT_MET);
    /* Nobody owns it: its zzdds view's destroy refuses. */
    assert(zzdds_DomainParticipantFactory_destroy(DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(inst)) == DDS_RETCODE_PRECONDITION_NOT_MET);
    assert(DDS_DomainParticipantFactory_delete_participant(inst, inst_dp) == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_instance() == DDS_RETCODE_OK);
    assert(DDS_DomainParticipantFactory_delete_instance() == DDS_RETCODE_OK);

    printf("c_allocator_smoke: OK\n");
    return 0;
}
