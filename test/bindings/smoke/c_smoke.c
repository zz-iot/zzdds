#include "binding_smoke.h"
#include "zidl_cdr.h"

#include <assert.h>
#include <stdint.h>
#include <string.h>

static void check(int rc) {
    assert(rc == ZIDL_CDR_OK);
}

int main(void) {
    BindingSmokeStatus sample;
    memset(&sample, 0, sizeof(sample));
    sample.id = 7u;
    sample.count = 42u;
    strcpy(sample.label, "c-smoke");

    uint8_t buffer[256];
    ZidlCdrWriter writer;
    zidl_cdr_writer_init_fixed(&writer, buffer, sizeof(buffer), ZIDL_XCDR1);
    check(zidl_cdr_write_encap(&writer));
    check(BindingSmokeStatus_serialize(&writer, &sample));

    ZidlCdrReader reader;
    check(zidl_cdr_reader_init(&reader, buffer, writer.len));
    BindingSmokeStatus decoded;
    memset(&decoded, 0, sizeof(decoded));
    check(BindingSmokeStatus_deserialize(&reader, &decoded));
    assert(decoded.id == sample.id);
    assert(decoded.count == sample.count);
    assert(strcmp(decoded.label, sample.label) == 0);

    uint8_t from_struct[16];
    uint8_t from_cdr[16];
    check(BindingSmokeStatus_compute_key_hash(&sample, from_struct));
    check(BindingSmokeStatus_compute_key_hash_from_cdr(buffer, writer.len, from_cdr));
    assert(memcmp(from_struct, from_cdr, sizeof(from_struct)) == 0);

    DDS_DataWriter null_writer = NULL;
    BindingSmokeStatusDataWriter typed_writer;
    BindingSmokeStatusDataWriter_init(&typed_writer, null_writer, ZIDL_XCDR1);
    assert(typed_writer.xcdr_version == ZIDL_XCDR1);

    DDS_DataReader null_reader = NULL;
    BindingSmokeStatusDataReader typed_reader;
    BindingSmokeStatusDataReader_init(&typed_reader, null_reader);
    assert(typed_reader.reader == NULL);

    return 0;
}
