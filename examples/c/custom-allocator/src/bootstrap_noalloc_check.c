/*
 * Narrow, targeted regression check: arms the guard BEFORE doing anything at
 * all, then does exactly the bootstrap sequence a caller who wants zero libc
 * malloc from process start would use --
 * zzdds_process_configure_from_file() + zzdds_DomainParticipantFactory_create_with_allocator()
 * -- and nothing else. publisher.c/subscriber.c's own guard only arms after
 * a lot of additional setup (participant/topic/writer/reader creation,
 * discovery settling), so passing there doesn't specifically prove THIS
 * step is malloc-free; this program isolates it.
 */
#include "zzdds_c.h"
#include "static_pool_allocator.h"
#include "noalloc_guard.h"

#include <stdio.h>

int main(void) {
    static_pool_allocator_reset();

    noalloc_guard_try_arm();

    DDS_ReturnCode_t cfg_rc = zzdds_process_configure_from_file("zzdds.toml", &static_pool_allocator);
    if (cfg_rc != DDS_RETCODE_OK) {
        fprintf(stderr, "FAIL: zzdds_process_configure_from_file (rc=%d)\n", (int)cfg_rc);
        return 1;
    }

    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create_with_allocator(&static_pool_allocator);
    if (factory == NULL) {
        fprintf(stderr, "FAIL: zzdds_DomainParticipantFactory_create_with_allocator returned NULL\n");
        return 1;
    }

    noalloc_guard_try_disarm();
    zzdds_DomainParticipantFactory_release(factory);
    printf("bootstrap_noalloc_check: OK -- config resolve + factory bootstrap made zero libc malloc calls\n");
    return 0;
}
