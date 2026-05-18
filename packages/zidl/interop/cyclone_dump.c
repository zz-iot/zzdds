/*
 * cyclone_dump.c — Serialize interop test types using Cyclone DDS CDR and
 * write the resulting byte streams to binary files in expected/.
 *
 * The files include the 4-byte CDR encapsulation header followed by the
 * CDR-encoded payload, matching exactly what zidl-rt's CdrWriter produces.
 *
 * Build: see Makefile.
 * Usage: ./cyclone_dump [output_dir]   (default: expected/)
 *
 * Cyclone's dds_stream_write_sampleLE writes CDR payload only (no encap
 * header).  We prepend the 4-byte header manually before writing to disk.
 *
 * XCDR2 LE encap header: [0x00, 0x07, 0x00, 0x00]   (CDR2_LE = 0x0007 BE)
 * XCDR1 LE encap header: [0x00, 0x01, 0x00, 0x00]   (CDR_LE  = 0x0001 BE)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>

#include "dds/dds.h"
#include "dds/cdr/dds_cdrstream.h"
#include "gen/types.h"

/* ── allocator passed to Cyclone stream APIs ─────────────────────────────── */
static const dds_cdrstream_allocator_t std_alloc = {
    .malloc  = malloc,
    .realloc = realloc,
    .free    = free,
};

/* ── encapsulation headers ────────────────────────────────────────────────── */
static const unsigned char ENCAP_XCDR2_LE[4] = { 0x00, 0x07, 0x00, 0x00 };
static const unsigned char ENCAP_XCDR1_LE[4] = { 0x00, 0x01, 0x00, 0x00 };

/* ── helpers ──────────────────────────────────────────────────────────────── */

static void dump_hex(const char *label,
                     const unsigned char *hdr, uint32_t hdr_len,
                     const unsigned char *payload, uint32_t pay_len)
{
    printf("=== %s (%u bytes) ===\n", label, hdr_len + pay_len);
    uint32_t total = hdr_len + pay_len;
    for (uint32_t i = 0; i < total; i++) {
        unsigned char b = (i < hdr_len) ? hdr[i] : payload[i - hdr_len];
        printf("%02x", b);
        if ((i + 1) % 16 == 0 || i + 1 == total) printf("\n");
        else printf(" ");
    }
}

static int write_file(const char *path,
                      const unsigned char *hdr,  uint32_t hdr_len,
                      const unsigned char *data, uint32_t data_len)
{
    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "Cannot open %s: %s\n", path, strerror(errno)); return -1; }
    fwrite(hdr,  1, hdr_len,  f);
    fwrite(data, 1, data_len, f);
    fclose(f);
    printf("Wrote %u bytes to %s\n", hdr_len + data_len, path);
    return 0;
}

/*
 * Serialize one sample (XCDR2 LE) and write to <outdir>/<name>.bin.
 * Also prints hex for visual verification.
 */
static int serialize_xcdr2(const char *outdir, const char *name,
                            const void *sample,
                            const dds_topic_descriptor_t *topic_desc)
{
    struct dds_cdrstream_desc cdesc;
    dds_cdrstream_desc_from_topic_desc(&cdesc, topic_desc);

    dds_ostreamLE_t os;
    dds_ostreamLE_init(&os, &std_alloc, 0, DDSI_RTPS_CDR_ENC_VERSION_2);

    bool ok = dds_stream_write_sampleLE(&os, &std_alloc, sample, &cdesc);
    if (!ok) { fprintf(stderr, "serialize_xcdr2 failed for %s\n", name); return -1; }

    dump_hex(name, ENCAP_XCDR2_LE, 4, os.x.m_buffer, os.x.m_index);

    char path[512];
    snprintf(path, sizeof(path), "%s/%s_xcdr2.bin", outdir, name);
    int rc = write_file(path, ENCAP_XCDR2_LE, 4, os.x.m_buffer, os.x.m_index);

    dds_ostreamLE_fini(&os, &std_alloc);
    dds_cdrstream_desc_fini(&cdesc, &std_alloc);
    return rc;
}

static int serialize_xcdr1(const char *outdir, const char *name,
                            const void *sample,
                            const dds_topic_descriptor_t *topic_desc)
{
    struct dds_cdrstream_desc cdesc;
    dds_cdrstream_desc_from_topic_desc(&cdesc, topic_desc);

    dds_ostreamLE_t os;
    dds_ostreamLE_init(&os, &std_alloc, 0, DDSI_RTPS_CDR_ENC_VERSION_1);

    bool ok = dds_stream_write_sampleLE(&os, &std_alloc, sample, &cdesc);
    if (!ok) { fprintf(stderr, "serialize_xcdr1 failed for %s\n", name); return -1; }

    dump_hex(name, ENCAP_XCDR1_LE, 4, os.x.m_buffer, os.x.m_index);

    char path[512];
    snprintf(path, sizeof(path), "%s/%s_xcdr1.bin", outdir, name);
    int rc = write_file(path, ENCAP_XCDR1_LE, 4, os.x.m_buffer, os.x.m_index);

    dds_ostreamLE_fini(&os, &std_alloc);
    dds_cdrstream_desc_fini(&cdesc, &std_alloc);
    return rc;
}

/* ── test fixtures ────────────────────────────────────────────────────────── */

static int test_primitives(const char *outdir)
{
    Interop_Primitives s = {
        .x    = 42,
        .y    = 1.5f,
        .flag = true,
        .b    = 0xAB,
        .d    = 3.14,
        .s    = -7,
        .ll   = 9000000000LL,
    };
    int rc = 0;
    rc |= serialize_xcdr2(outdir, "primitives", &s, &Interop_Primitives_desc);
    rc |= serialize_xcdr1(outdir, "primitives", &s, &Interop_Primitives_desc);
    return rc;
}

static int test_message(const char *outdir)
{
    static int32_t vals[3] = { 10, 20, 30 };
    Interop_Message s = {
        .sensor_id = 7,
        .label     = (char *)"hello",
        .values    = { ._maximum = 3, ._length = 3, ._buffer = vals, ._release = false },
    };
    int rc = 0;
    rc |= serialize_xcdr2(outdir, "message", &s, &Interop_Message_desc);
    rc |= serialize_xcdr1(outdir, "message", &s, &Interop_Message_desc);
    return rc;
}

static int test_point(const char *outdir)
{
    Interop_Point s = { .x = 100, .y = -200 };
    /* @appendable: only makes sense in XCDR2 (DHEADER required) */
    return serialize_xcdr2(outdir, "point", &s, &Interop_Point_desc);
}

static int test_outer(const char *outdir)
{
    Interop_Outer s = {
        .inner = {
            .x    = -1,
            .y    = 0.0f,
            .flag = false,
            .b    = 0,
            .d    = 0.0,
            .s    = 0,
            .ll   = 0LL,
        },
        .tag = 99,
    };
    int rc = 0;
    rc |= serialize_xcdr2(outdir, "outer", &s, &Interop_Outer_desc);
    rc |= serialize_xcdr1(outdir, "outer", &s, &Interop_Outer_desc);
    return rc;
}

/* ── main ─────────────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    const char *outdir = (argc > 1) ? argv[1] : "expected";

    int rc = 0;
    rc |= test_primitives(outdir);
    rc |= test_message(outdir);
    rc |= test_point(outdir);
    rc |= test_outer(outdir);

    return rc ? 1 : 0;
}
