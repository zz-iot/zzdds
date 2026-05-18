/* Integration test for generated C types + CDR serialization.
   Compiled and run by `zig build integration-test`. */

#include "types.h"
#include "zidl_cdr.h"
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── helper ──────────────────────────────────────────────────────────────── */

static void check(int rc, const char *msg) {
    if (rc != ZIDL_CDR_OK) {
        fprintf(stderr, "FAIL: %s (rc=%d)\n", msg, rc);
        exit(1);
    }
}

/* ── roundtrip: Sample (@final) ─────────────────────────────────────────── */

static void test_sample_roundtrip(void) {
    uint8_t buf[1024];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, buf, sizeof(buf), ZIDL_XCDR2);
    check(zidl_cdr_write_encap(&w), "write_encap");

    Sample s;
    memset(&s, 0, sizeof(s));
    s.id        = 42;
    s.b         = true;
    s.u8_val    = 0xFF;
    s.s16_val   = -1000;
    s.u16_val   = 65000;
    s.s32_val   = -2000000;
    s.u32_val   = 4000000;
    s.s64_val   = -9000000000LL;
    s.u64_val   = 18000000000ULL;
    s.f32_val   = 3.14f;
    s.f64_val   = 2.718281828;
    s.str       = "hello world";
    strncpy(s.bstr, "bounded", sizeof(s.bstr) - 1);
    s.arr[0]    = 10; s.arr[1] = 20; s.arr[2] = 30;
    s.clr       = Color_GREEN;
    s.nested.x  = 7; s.nested.y = -3;

    check(Sample_serialize(&w, &s), "Sample_serialize");

    ZidlCdrReader r;
    check(zidl_cdr_reader_init(&r, buf, w.pos + 4), "reader_init");

    Sample s2;
    memset(&s2, 0, sizeof(s2));
    check(Sample_deserialize(&r, &s2), "Sample_deserialize");

    assert(s2.id       == 42);
    assert(s2.b        == true);
    assert(s2.u8_val   == 0xFF);
    assert(s2.s16_val  == -1000);
    assert(s2.u16_val  == 65000);
    assert(s2.s32_val  == -2000000);
    assert(s2.u32_val  == 4000000);
    assert(s2.s64_val  == -9000000000LL);
    assert(s2.u64_val  == 18000000000ULL);
    assert(fabsf(s2.f32_val - 3.14f) < 1e-5f);
    assert(fabs(s2.f64_val - 2.718281828) < 1e-12);
    assert(s2.str != NULL && strcmp(s2.str, "hello world") == 0);
    assert(strcmp(s2.bstr, "bounded") == 0);
    assert(s2.arr[0] == 10 && s2.arr[1] == 20 && s2.arr[2] == 30);
    assert(s2.clr == Color_GREEN);
    assert(s2.nested.x == 7 && s2.nested.y == -3);

    free(s2.str);
    printf("  test_sample_roundtrip: OK\n");
}

/* ── roundtrip: Frame (@appendable, DHEADER) ─────────────────────────────── */

static void test_frame_roundtrip(void) {
    uint8_t buf[256];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, buf, sizeof(buf), ZIDL_XCDR2);
    check(zidl_cdr_write_encap(&w), "write_encap");

    Frame f;
    memset(&f, 0, sizeof(f));
    f.seq_num = 7;
    f.topic   = "/sensors/imu";

    check(Frame_serialize(&w, &f), "Frame_serialize");

    ZidlCdrReader r;
    check(zidl_cdr_reader_init(&r, buf, w.pos + 4), "reader_init");

    Frame f2;
    memset(&f2, 0, sizeof(f2));
    check(Frame_deserialize(&r, &f2), "Frame_deserialize");

    assert(f2.seq_num == 7);
    assert(f2.topic != NULL && strcmp(f2.topic, "/sensors/imu") == 0);

    free(f2.topic);
    printf("  test_frame_roundtrip: OK\n");
}

/* ── key serialization ───────────────────────────────────────────────────── */

static void test_sample_key(void) {
    uint8_t buf[64];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, buf, sizeof(buf), ZIDL_XCDR2);
    check(zidl_cdr_write_encap(&w), "write_encap");

    Sample s;
    memset(&s, 0, sizeof(s));
    s.id = 99;

    check(Sample_serialize_key(&w, &s), "Sample_serialize_key");

    /* Key payload is just one u32 = 4 bytes (+ 4 encap = 8 total) */
    assert(w.pos == 4); /* pos tracks payload bytes after encap */

    assert(Sample_has_key == 1);
    assert(Frame_has_key  == 0);

    printf("  test_sample_key: OK\n");
}

static void test_sample_deserialize_key(void) {
    uint8_t buf[1024];
    ZidlCdrWriter w;
    zidl_cdr_writer_init_fixed(&w, buf, sizeof(buf), ZIDL_XCDR2);
    check(zidl_cdr_write_encap(&w), "write_encap");

    Sample s;
    memset(&s, 0, sizeof(s));
    s.id = 0x01020304u;
    s.b = true;
    s.str = "non-key payload";
    s.arr[0] = 1; s.arr[1] = 2; s.arr[2] = 3;
    s.nested.x = 10; s.nested.y = 20;
    check(Sample_serialize(&w, &s), "Sample_serialize");

    ZidlCdrReader r;
    check(zidl_cdr_reader_init(&r, buf, w.pos + 4), "reader_init");

    Sample key;
    memset(&key, 0, sizeof(key));
    check(Sample_deserialize_key(&r, &key), "Sample_deserialize_key");
    assert(key.id == s.id);
    assert(key.b == false);
    assert(key.str == NULL);
    assert(key.nested.x == 0);
    assert(zidl_cdr_remaining(&r) == 0);

    printf("  test_sample_deserialize_key: OK\n");
}

static void test_sample_compute_key_hash(void) {
    Sample s;
    memset(&s, 0, sizeof(s));
    s.id = 0x01020304u;

    uint8_t hash[16];
    check(Sample_compute_key_hash(&s, hash), "Sample_compute_key_hash");
    const uint8_t expected[16] = {
        0x01, 0x02, 0x03, 0x04,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    assert(memcmp(hash, expected, sizeof(expected)) == 0);

    printf("  test_sample_compute_key_hash: OK\n");
}

int main(void) {
    printf("C integration tests:\n");
    test_sample_roundtrip();
    test_frame_roundtrip();
    test_sample_key();
    test_sample_deserialize_key();
    test_sample_compute_key_hash();
    printf("All C integration tests passed.\n");
    return 0;
}
