/*
 * Narrow, targeted regression check: arms the guard BEFORE doing anything at
 * all, then does exactly the bootstrap sequence a caller who wants zero libc
 * malloc/operator new from process start would use --
 * zzdds::process_configure_from_file() + zzdds::create_factory(allocator) --
 * and nothing else. publisher.cpp/subscriber.cpp's own guard only arms after
 * a lot of additional setup, so passing there doesn't specifically prove
 * THIS step is allocation-free; this program isolates it.
 */
#include "zzdds_cpp.hpp"
#include "static_pool_allocator.h"
#include "noalloc_guard.h"

#include <cstdio>

int main() {
    static_pool_allocator_reset();

    noalloc_guard_try_arm();

    if (zzdds::process_configure_from_file("zzdds.toml", &static_pool_allocator) != DDS_RETCODE_OK) {
        std::fprintf(stderr, "FAIL: process_configure_from_file\n");
        return 1;
    }

    auto factory = zzdds::create_factory(&static_pool_allocator);
    if (!factory) {
        std::fprintf(stderr, "FAIL: create_factory returned null\n");
        return 1;
    }

    noalloc_guard_try_disarm();
    std::printf("bootstrap_noalloc_check: OK -- config resolve + factory bootstrap made zero libc malloc/operator new calls\n");
    return 0;
}
