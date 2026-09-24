#define _GNU_SOURCE
#include "noalloc_guard.h"

#include <stdio.h>

/* LD_PRELOAD (and thus this whole guard mechanism -- see noalloc_guard.h)
 * has no Windows equivalent; the real interposer target (noalloc_guard,
 * built from noalloc_guard_preload.c) isn't even built there -- see
 * CMakeLists.txt. publisher/subscriber still link this file everywhere
 * (see the same file's noalloc_guard_client target) and already treat
 * "not preloaded" as a normal, silently-unguarded run, so on Windows this
 * just always takes that same path without touching dlfcn.h at all. */
#ifdef _WIN32

bool noalloc_guard_try_arm(void) {
    fprintf(stderr, "noalloc_guard: not supported on Windows (LD_PRELOAD has no equivalent here) "
                    "-- continuing unguarded\n");
    return false;
}

bool noalloc_guard_try_disarm(void) {
    return false;
}

#else
#include <dlfcn.h>

typedef void (*guard_fn)(void);

static guard_fn lookup(const char *name) {
    /* Cleared each call: dlerror() must be cleared before, checked after. */
    dlerror();
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (dlerror() != NULL) return NULL;
    return (guard_fn)sym;
}

bool noalloc_guard_try_arm(void) {
    guard_fn fn = lookup("noalloc_guard_arm");
    if (!fn) {
        fprintf(stderr, "noalloc_guard: not preloaded (run with LD_PRELOAD=.../libnoalloc_guard.so "
                        "to enable the zero-allocation acceptance check) -- continuing unguarded\n");
        return false;
    }
    fn();
    fprintf(stderr, "noalloc_guard: armed -- any malloc/calloc/realloc/free now aborts the process\n");
    return true;
}

bool noalloc_guard_try_disarm(void) {
    guard_fn fn = lookup("noalloc_guard_disarm");
    if (!fn) return false;
    fn();
    return true;
}

#endif
