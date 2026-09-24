#include "static_pool_allocator.h"

#include <stddef.h>
#include <stdint.h>

#ifdef _WIN32
#include <windows.h>
typedef SRWLOCK portable_mutex_t;
#define PORTABLE_MUTEX_INITIALIZER SRWLOCK_INIT
static void portable_mutex_lock(portable_mutex_t *m) { AcquireSRWLockExclusive(m); }
static void portable_mutex_unlock(portable_mutex_t *m) { ReleaseSRWLockExclusive(m); }
#else
#include <pthread.h>
typedef pthread_mutex_t portable_mutex_t;
#define PORTABLE_MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER
static void portable_mutex_lock(portable_mutex_t *m) { pthread_mutex_lock(m); }
static void portable_mutex_unlock(portable_mutex_t *m) { pthread_mutex_unlock(m); }
#endif

#ifndef STATIC_POOL_BLOCK_SIZE
#define STATIC_POOL_BLOCK_SIZE 4096
#endif
#ifndef STATIC_POOL_BLOCK_COUNT
#define STATIC_POOL_BLOCK_COUNT 512
#endif
#define STATIC_POOL_ALIGN 16

typedef struct FreeNode {
    struct FreeNode *next;
} FreeNode;

static _Alignas(STATIC_POOL_ALIGN) unsigned char g_pool[STATIC_POOL_BLOCK_COUNT][STATIC_POOL_BLOCK_SIZE];
static FreeNode *g_free_list;
/* zzdds runs its own background threads (SPDP timer, UDP receive, per-reader
 * heartbeat, ...) that allocate/free concurrently with the calling thread --
 * this pool is genuinely shared across threads, not just nominally
 * thread-safe-by-convention like the process-wide C++ pmr allocators
 * elsewhere in this project (which document "configure once at startup,
 * never call concurrently" as their contract). A plain free-list without a
 * lock corrupts under concurrent alloc/free here in practice, not just in
 * theory -- confirmed by a real crash during initial testing. */
static portable_mutex_t g_pool_mutex = PORTABLE_MUTEX_INITIALIZER;

void static_pool_allocator_reset(void) {
    portable_mutex_lock(&g_pool_mutex);
    g_free_list = NULL;
    for (size_t i = 0; i < STATIC_POOL_BLOCK_COUNT; i++) {
        FreeNode *node = (FreeNode *)g_pool[i];
        node->next = g_free_list;
        g_free_list = node;
    }
    portable_mutex_unlock(&g_pool_mutex);
}

static void *pool_alloc(void *ctx, size_t len, size_t alignment) {
    (void)ctx;
    if (len > STATIC_POOL_BLOCK_SIZE || alignment > STATIC_POOL_ALIGN) return NULL;
    portable_mutex_lock(&g_pool_mutex);
    FreeNode *node = g_free_list;
    if (node) g_free_list = node->next;
    portable_mutex_unlock(&g_pool_mutex);
    return node; /* NULL if the pool was exhausted -- graceful failure, per contract */
}

static bool pool_resize(void *ctx, void *ptr, size_t old_len, size_t new_len, size_t alignment) {
    (void)ctx;
    (void)ptr;
    (void)old_len;
    (void)alignment;
    /* Every handed-out block is already STATIC_POOL_BLOCK_SIZE bytes
     * regardless of the originally requested len, so growing/shrinking
     * within that size is always an in-place no-op. */
    return new_len <= STATIC_POOL_BLOCK_SIZE;
}

static void pool_free(void *ctx, void *ptr, size_t len, size_t alignment) {
    (void)ctx;
    (void)len;
    (void)alignment;
    if (!ptr) return; /* required no-op per ZidlAllocator's contract */
    FreeNode *node = (FreeNode *)ptr;
    portable_mutex_lock(&g_pool_mutex);
    node->next = g_free_list;
    g_free_list = node;
    portable_mutex_unlock(&g_pool_mutex);
}

const ZidlAllocator static_pool_allocator = {
    .ctx = NULL,
    .alloc = pool_alloc,
    .resize = pool_resize,
    .free = pool_free,
};
