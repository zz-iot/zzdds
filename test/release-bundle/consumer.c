/*
 * Minimal downstream consumer of a relocated zzdds C/C++ library bundle.
 *
 * Driven by scripts/verify_release_bundle.py through both supported
 * consumption paths (pkg-config and CMake find_package(ZZDDS)). Deliberately
 * tiny: it only has to force a real link against the bundled libzzdds and
 * execute a few runtime calls, proving the symbols resolve and the shared
 * library actually loads from a prefix that was renamed and moved after the
 * build. The zidl-cdr calls cover both halves of its C API (zidl_cdr.c and
 * the Zig wire functions), which libzzdds must export: the bundle ships no
 * other copy. Functional DDS coverage is examples/{c,cpp}/hello_world
 * (built by the same script against the same bundle) plus the test-bindings
 * and examples CI jobs.
 */
#include "zzdds_c.h"
#include "zidl_cdr.h"

#include <stdio.h>

int main(void) {
    uint8_t storage[8];
    ZidlCdrWriter writer;
    zidl_cdr_writer_init_fixed(&writer, storage, sizeof storage, ZIDL_XCDR1);
    if (zidl_cdr_write_u32(&writer, 42u) != ZIDL_CDR_OK || writer.len != 4) {
        fprintf(stderr, "FAIL: zidl-cdr writer through libzzdds\n");
        return 1;
    }

    zzdds_DomainParticipantFactory factory = zzdds_DomainParticipantFactory_create();
    if (factory == NULL) {
        fprintf(stderr, "FAIL: zzdds_DomainParticipantFactory_create() returned the nil sentinel\n");
        return 1;
    }
    zzdds_DomainParticipantFactory_release(factory);
    printf("ok: zzdds bundle consumer linked against libzzdds and ran\n");
    return 0;
}
