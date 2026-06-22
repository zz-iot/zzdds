#include "binding_smoke.hpp"
#include "zidl_cdr.h"

#include <cassert>
#include <cstdint>
#include <cstring>
#include <string>

static void check(int rc) {
    assert(rc == ZIDL_CDR_OK);
}

int main() {
    BindingSmokeStatus sample{};
    sample.id = 7u;
    sample.count = 42u;
    sample.label = "cpp-smoke";

    uint8_t buffer[256];
    ZidlCdrWriter writer;
    zidl_cdr_writer_init_fixed(&writer, buffer, sizeof(buffer), ZIDL_XCDR1);
    check(zidl_cdr_write_encap(&writer));
    check(BindingSmokeStatus_serialize(&writer, &sample));

    ZidlCdrReader reader;
    check(zidl_cdr_reader_init(&reader, buffer, writer.len));
    BindingSmokeStatus decoded{};
    check(BindingSmokeStatus_deserialize(&reader, &decoded));
    assert(decoded.id == sample.id);
    assert(decoded.count == sample.count);
    assert(decoded.label == sample.label);

    uint8_t from_struct[16];
    uint8_t from_cdr[16];
    check(BindingSmokeStatus_compute_key_hash(&sample, from_struct));
    check(BindingSmokeStatus_compute_key_hash_from_cdr(buffer, writer.len, from_cdr));
    assert(std::memcmp(from_struct, from_cdr, sizeof(from_struct)) == 0);

    DDS_DataWriter null_writer{};
    BindingSmokeStatusDataWriter typed_writer(null_writer, ZIDL_XCDR1);
    (void)typed_writer;

    DDS_DataReader null_reader{};
    BindingSmokeStatusDataReader typed_reader(null_reader);
    (void)typed_reader;

    return 0;
}
