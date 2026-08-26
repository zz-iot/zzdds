/*
 * LD_PRELOAD-only shim: interposes malloc/calloc/realloc/free AND global
 * operator new/operator delete process-wide (including calls made from
 * inside libzzdds.so and the generated C++ DCPS impl, via normal ELF
 * global-scope symbol interposition for the C functions, and the C++
 * standard's replaceable-global-operator mechanism for new/delete -- this is
 * why LD_PRELOAD is used here instead of just linking this file into the
 * executable). Exports noalloc_guard_arm()/_disarm(), which
 * src/noalloc_guard_client.c resolves via dlsym(RTLD_DEFAULT, ...) from the
 * app.
 *
 * Not linked into publisher/subscriber at build time -- built as its own
 * shared library and loaded only via LD_PRELOAD, so the app runs fine
 * (unguarded) without it too. See CMakeLists.txt.
 *
 * Overriding operator new/delete directly (rather than relying solely on the
 * malloc/free interposition below, which libstdc++'s *default* operator
 * new/delete happen to call internally) is what the design doc's acceptance
 * test explicitly calls for -- and it's the only way to reliably catch a
 * custom allocator or STL implementation that doesn't route through libc
 * malloc/free at all.
 */
#include <dlfcn.h>
#include <execinfo.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>

static std::atomic<int> g_armed{0};

/* trip()'s own diagnostics (fprintf's lazy stdio-buffer malloc,
 * backtrace_symbols_fd's internal allocation) must not re-enter the guard --
 * that would recurse into trip() again before the first abort() lands,
 * blowing the stack (observed as a segfault instead of a clean SIGABRT).
 * Thread-local: multiple background threads (UDP recv, SPDP timer,
 * heartbeat) can independently trip concurrently, and each must be allowed
 * to run its own diagnostics without tripping over another thread's. */
static thread_local int t_in_trip = 0;

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
    total = (total + 15u) & ~(size_t)15u;
    if (total == 0 || g_bootstrap_used + total > BOOTSTRAP_POOL_SIZE) return nullptr;
    void *p = &g_bootstrap_pool[g_bootstrap_used];
    g_bootstrap_used += total;
    memset(p, 0, total);
    return p;
}

static int from_bootstrap_pool(void *ptr) {
    return ptr >= (void *)g_bootstrap_pool && ptr < (void *)(g_bootstrap_pool + BOOTSTRAP_POOL_SIZE);
}

static void ensure_real_fns() {
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
    fprintf(stderr, "noalloc_guard: FAIL -- %s called while armed (unexpected heap "
                    "allocation after startup)\n", what);
    void *bt[32];
    int n = backtrace(bt, 32);
    backtrace_symbols_fd(bt, n, 2);
    fflush(stderr);
    abort();
}

extern "C" void noalloc_guard_arm() {
    ensure_real_fns();
    g_armed.store(1);
}

extern "C" void noalloc_guard_disarm() {
    g_armed.store(0);
}

extern "C" void *malloc(size_t size) {
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("malloc()");
    return real_malloc(size);
}

extern "C" void *calloc(size_t nmemb, size_t size) {
    if (!real_calloc) {
        if (g_resolving) return bootstrap_calloc(nmemb, size);
        ensure_real_fns();
        if (!real_calloc) return bootstrap_calloc(nmemb, size);
    }
    if (!t_in_trip && g_armed.load()) trip("calloc()");
    return real_calloc(nmemb, size);
}

extern "C" void *realloc(void *ptr, size_t size) {
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("realloc()");
    return real_realloc(ptr, size);
}

extern "C" void free(void *ptr) {
    if (ptr == nullptr || from_bootstrap_pool(ptr)) return;
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("free()");
    real_free(ptr);
}

// ── Global operator new/delete replacement ──────────────────────────────────
// Delegates straight to real_malloc/real_free (not the possibly-intercepted
// malloc/free symbols above) to avoid a redundant re-check/recursion path.

static void *guarded_new(size_t size) {
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("operator new()");
    void *p = real_malloc(size == 0 ? 1 : size);
    if (!p) throw std::bad_alloc();
    return p;
}

void *operator new(size_t size) { return guarded_new(size); }
void *operator new[](size_t size) { return guarded_new(size); }
void *operator new(size_t size, const std::nothrow_t &) noexcept {
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("operator new(nothrow)");
    return real_malloc(size == 0 ? 1 : size);
}
void *operator new[](size_t size, const std::nothrow_t &) noexcept {
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("operator new[](nothrow)");
    return real_malloc(size == 0 ? 1 : size);
}

static void guarded_delete(void *ptr) {
    if (ptr == nullptr || from_bootstrap_pool(ptr)) return;
    ensure_real_fns();
    if (!t_in_trip && g_armed.load()) trip("operator delete()");
    real_free(ptr);
}

void operator delete(void *ptr) noexcept { guarded_delete(ptr); }
void operator delete[](void *ptr) noexcept { guarded_delete(ptr); }
void operator delete(void *ptr, size_t) noexcept { guarded_delete(ptr); }
void operator delete[](void *ptr, size_t) noexcept { guarded_delete(ptr); }
