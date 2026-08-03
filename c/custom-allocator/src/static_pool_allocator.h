#ifndef STATIC_POOL_ALLOCATOR_H
#define STATIC_POOL_ALLOCATOR_H

#include "zidl_allocator.h"

/*
 * A fixed-size, fixed-block free-list allocator: no malloc/free anywhere,
 * ever. All storage lives in a single static array sized at compile time.
 *
 * Deliberately simple for a first embedded example: every allocation request
 * up to STATIC_POOL_BLOCK_SIZE bytes is rounded up to one block; anything
 * larger fails (returns NULL, per ZidlAllocator's graceful-failure contract —
 * callers already handle alloc failure without this allocator needing to do
 * anything special). Freed blocks return to a singly-linked free list for
 * reuse, so the pool supports the create/destroy/re-create churn of a long-
 * running pub/sub loop (history-cache entries in particular), not just a
 * one-shot bump allocation.
 */

/* Reset the pool to fully free. Call once, before any zzdds/zidl allocation
 * happens (i.e. before zzdds_create_factory_with_allocator). Not
 * thread-safe -- matches ZidlAllocator's own "configure once at startup"
 * contract used throughout zzdds/zidl. */
void static_pool_allocator_reset(void);

/* The ZidlAllocator vtable instance backed by this pool. */
extern const ZidlAllocator static_pool_allocator;

#endif
