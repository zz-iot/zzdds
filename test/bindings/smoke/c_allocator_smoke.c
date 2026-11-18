/* Binding smoke test for zzdds_c.h's plain C-ABI allocator-injection
 * surface: zzdds_create_factory_with_allocator(const ZidlAllocator*).
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
    ZidlAllocator tracking = {NULL, track_alloc, track_resize, track_free};

    zzdds_DomainParticipantFactory factory = zzdds_create_factory_with_allocator(&tracking);
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
    zzdds_destroy_factory(NULL);

    DDS_ReturnCode_t rc = DDS_DomainParticipantFactory_delete_participant(dds_factory, dp);
    assert(rc == DDS_RETCODE_OK);

    zzdds_destroy_factory(factory);

    /* Everything torn down, nothing leaked. */
    assert(g_alloc_calls == g_free_calls);

    printf("c_allocator_smoke: OK\n");
    return 0;
}
