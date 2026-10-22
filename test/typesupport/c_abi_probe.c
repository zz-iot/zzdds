/* Independent C consumer: descriptor layout and C callback calling convention. */
#include "zidl_typesupport.h"
#include <string.h>
int zidl_ts_c_probe(const ZidlTsLibrary *library) {
    if (!library || library->descriptor_size != sizeof(ZidlTsLibrary) ||
        library->abi_major != ZIDL_TS_ABI_MAJOR || !library->type_count) return 1;
    if (!library->object_count || !library->objects) return 7;
    for (uint64_t i = 0; i < library->object_count; ++i) {
        const ZidlTsObject *object = &library->objects[i];
        if (object->descriptor_size != sizeof(ZidlTsObject) || !object->cdr.data ||
            object->cdr.size < 4 || (object->dependency_count && !object->dependencies)) return 8;
    }
    for (uint64_t i = 0; i < library->type_count; ++i) {
        const ZidlTsType *type = &library->types[i];
        if (type->descriptor_size != sizeof(ZidlTsType)) return 2;
        if (type->name.size != strlen("LibraryTest::Reading") ||
            memcmp(type->name.data, "LibraryTest::Reading", type->name.size)) continue;
        const uint8_t sample[] = {0,1,0,0,0,0,128,63,42,0,0,0};
        const uint8_t key[] = {0,1,0,0,42,0,0,0};
        const uint8_t expected[16] = {0,0,0,42};
        uint8_t hash[16];
        if (type->keyed != 1 || type->validate(sample, sizeof sample) != ZIDL_TS_OK) return 3;
        if (type->key_hash(sample, sizeof sample, &hash) != ZIDL_TS_OK || memcmp(hash, expected, sizeof hash)) return 4;
        if (type->key_only_hash(key, sizeof key, &hash) != ZIDL_TS_OK || memcmp(hash, expected, sizeof hash)) return 5;
        return 0;
    }
    return 6;
}
