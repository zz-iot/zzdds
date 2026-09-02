/*
 * Minimal downstream consumer of a relocated zzdds C/C++ library bundle.
 *
 * Driven by scripts/verify_release_bundle.py through both supported
 * consumption paths (pkg-config and CMake find_package(ZZDDS)). Deliberately
 * tiny: it only has to force a real link against the bundled libzzdds +
 * libzidl_cdr and execute one runtime call, proving the symbols resolve and
 * the shared library actually loads from a prefix that was renamed and moved
 * after the build. Functional DDS coverage is examples/{c,cpp}/hello_world
 * (built by the same script against the same bundle) plus the test-bindings
 * and examples CI jobs.
 */
#include "zzdds_c.h"

#include <stdio.h>

int main(void) {
    zzdds_DomainParticipantFactory factory = zzdds_create_factory();
    if (zzdds_factory_is_nil(factory)) {
        fprintf(stderr, "FAIL: zzdds_create_factory() returned the nil sentinel\n");
        return 1;
    }
    zzdds_destroy_factory(factory);
    printf("ok: zzdds bundle consumer linked against libzzdds and ran\n");
    return 0;
}
