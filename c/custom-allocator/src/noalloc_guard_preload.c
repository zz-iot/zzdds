/*
 * LD_PRELOAD-only shim: interposes malloc/calloc/realloc/free process-wide
 * (including calls made from inside libzzdds.so itself, via normal ELF
 * global-scope symbol interposition -- this is why LD_PRELOAD is used here
 * instead of just linking this file into the executable). Exports
 * noalloc_guard_arm()/_disarm(), which src/noalloc_guard_client.c resolves
 * via dlsym(RTLD_DEFAULT, ...) from the app.
 *
 * Not linked into publisher/subscriber at build time -- built as its own
 * shared library and loaded only via LD_PRELOAD, so the app runs fine
 * (unguarded) without it too. See CMakeLists.txt.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static atomic_int g_armed = 0;

/* trip()'s own diagnostics (fprintf's lazy stdio-buffer malloc,
 * backtrace_symbols_fd's internal allocation) must not re-enter the guard --
 * that would recurse into trip() again before the first abort() lands,
 * blowing the stack (observed as a segfault instead of a clean SIGABRT).
 * Thread-local: multiple background threads (UDP recv, SPDP timer,
 * heartbeat) can independently trip concurrently, and each must be allowed
 * to run its own diagnostics without tripping over another thread's. */
static __thread int t_in_trip = 0;

typedef void *(*malloc_fn)(size_t);
typedef void *(*calloc_fn)(size_t, size_t);
typedef void *(*realloc_fn)(void *, size_t);
typedef void (*free_fn)(void *);

static malloc_fn real_malloc;
static calloc_fn real_calloc;
static realloc_fn real_realloc;
static free_fn real_free;

/* dlsym() itself can call calloc() internally (to allocate bookkeeping for
 * the very first dlopen/dlsym lookup) before we've resolved real_calloc --
 * a well-known LD_PRELOAD chicken-and-egg problem. This static bootstrap
 * pool satisfies exactly those reentrant calls; it's never freed (freeing a
 * bootstrap-pool pointer is treated as a no-op below), tiny, and one-time. */
#define BOOTSTRAP_POOL_SIZE 4096
static unsigned char g_bootstrap_pool[BOOTSTRAP_POOL_SIZE];
static size_t g_bootstrap_used = 0;
static int g_resolving = 0;

static void *bootstrap_calloc(size_t nmemb, size_t size) {
    size_t total = nmemb * size;
    total = (total + 15u) & ~((size_t)15u);
    if (total == 0 || g_bootstrap_used + total > BOOTSTRAP_POOL_SIZE) return NULL;
    void *p = &g_bootstrap_pool[g_bootstrap_used];
    g_bootstrap_used += total;
    memset(p, 0, total);
    return p;
}

static int from_bootstrap_pool(void *ptr) {
    return ptr >= (void *)g_bootstrap_pool && ptr < (void *)(g_bootstrap_pool + BOOTSTRAP_POOL_SIZE);
}

static void ensure_real_fns(void) {
    if (real_malloc && real_calloc && real_realloc && real_free) return;
    if (g_resolving) return; /* reentered from within dlsym() itself */
    g_resolving = 1;
    if (!real_malloc) real_malloc = (malloc_fn)dlsym(RTLD_NEXT, "malloc");
    if (!real_realloc) real_realloc = (realloc_fn)dlsym(RTLD_NEXT, "realloc");
    if (!real_free) real_free = (free_fn)dlsym(RTLD_NEXT, "free");
    if (!real_calloc) real_calloc = (calloc_fn)dlsym(RTLD_NEXT, "calloc");
    g_resolving = 0;
}

static void trip(const char *what) {
    t_in_trip = 1;
    fprintf(stderr, "noalloc_guard: FAIL -- %s() called while armed (unexpected heap "
                    "allocation after startup)\n", what);
    void *bt[32];
    int n = backtrace(bt, 32);
    backtrace_symbols_fd(bt, n, 2);
    fflush(stderr);
    abort();
}

void noalloc_guard_arm(void) {
    ensure_real_fns();
    atomic_store(&g_armed, 1);
}

void noalloc_guard_disarm(void) {
    atomic_store(&g_armed, 0);
}

void *malloc(size_t size) {
    ensure_real_fns();
    if (!t_in_trip && atomic_load(&g_armed)) trip("malloc");
    return real_malloc(size);
}

void *calloc(size_t nmemb, size_t size) {
    if (!real_calloc) {
        if (g_resolving) return bootstrap_calloc(nmemb, size);
        ensure_real_fns();
        if (!real_calloc) return bootstrap_calloc(nmemb, size);
    }
    if (!t_in_trip && atomic_load(&g_armed)) trip("calloc");
    return real_calloc(nmemb, size);
}

void *realloc(void *ptr, size_t size) {
    ensure_real_fns();
    if (!t_in_trip && atomic_load(&g_armed)) trip("realloc");
    return real_realloc(ptr, size);
}

void free(void *ptr) {
    if (ptr == NULL || from_bootstrap_pool(ptr)) return;
    ensure_real_fns();
    if (!t_in_trip && atomic_load(&g_armed)) trip("free");
    real_free(ptr);
}
