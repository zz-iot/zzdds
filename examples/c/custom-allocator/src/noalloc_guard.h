/*
 * Interposed via LD_PRELOAD (not linked at build time -- see CMakeLists.txt):
 * once armed, malloc/calloc/realloc/free abort the process with a backtrace.
 * Arm this only after all one-time setup allocation is done (factory,
 * participant, topic, writer/reader creation) and before entering the
 * steady-state loop -- the showcase's claim is "zero heap allocation after
 * startup", not "zero from process start" (see allocator-strategy.md's
 * "Definition of zero malloc" section).
 *
 * The functions below resolve noalloc_guard_arm/_disarm via dlsym(RTLD_DEFAULT, ...)
 * so publisher/subscriber run fine even without LD_PRELOAD (arming becomes a
 * silent no-op) -- LD_PRELOAD is what turns this from "nothing happens" into
 * the actual falsifiable acceptance test.
 */
#ifndef NOALLOC_GUARD_CLIENT_H
#define NOALLOC_GUARD_CLIENT_H

#include <stdbool.h>

/* Returns true if the guard library was preloaded and is now armed. */
bool noalloc_guard_try_arm(void);

/* Returns true if the guard library was preloaded and is now disarmed. */
bool noalloc_guard_try_disarm(void);

#endif
