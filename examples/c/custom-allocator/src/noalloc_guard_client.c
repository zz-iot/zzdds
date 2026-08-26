#define _GNU_SOURCE
#include "noalloc_guard.h"

#include <dlfcn.h>
#include <stdio.h>

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
