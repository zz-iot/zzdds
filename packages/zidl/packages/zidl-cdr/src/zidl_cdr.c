/*
 * zidl-cdr — Standalone C99 CDR library implementation.
 *
 * Alignment rule (matches zidl-rt):
 *   CDR alignment is measured from the start of the CDR payload.
 *   ZidlCdrWriter.pos resets to 0 after zidl_cdr_write_encap(); subsequent
 *   primitives align relative to that reset point.
 *
 *   - XCDR1: natural alignment, capped at 8 bytes.
 *   - XCDR2: natural alignment, capped at 4 bytes.
 *
 * Writers default to little-endian.  The reader byte-swaps big-endian streams
 * on read.
 */

#include "zidl_cdr.h"

#include <stdlib.h>   /* malloc, realloc, free */
#include <string.h>   /* memcpy, strlen */

/* ── Internal helpers ────────────────────────────────────────────────────── */

/** Alignment cap: XCDR2 → min(size,4); XCDR1 and PL_CDR → min(size,8). */
static size_t align_cap(int xcdr_version, size_t wire_size) {
    size_t cap = (xcdr_version == ZIDL_XCDR2) ? 4u : 8u;
    return (wire_size < cap) ? wire_size : cap;
}

/* ── Writer ──────────────────────────────────────────────────────────────── */

static int writer_grow_default(ZidlCdrWriter *w, size_t needed) {
    size_t new_cap = (w->cap == 0) ? 64u : w->cap * 2u;
    while (new_cap < w->len + needed) new_cap *= 2u;
    uint8_t *p = (uint8_t *)realloc(w->buf, new_cap);
    if (!p) return ZIDL_CDR_OVERFLOW;
    w->buf = p;
    w->cap = new_cap;
    return ZIDL_CDR_OK;
}

int zidl_cdr_writer_init(ZidlCdrWriter *w, int xcdr_version) {
    w->buf          = NULL;
    w->cap          = 0;
    w->len          = 0;
    w->pos          = 0;
    w->xcdr_version = xcdr_version;
    w->byte_order   = ZIDL_CDR_LE;
    w->grow_fn      = writer_grow_default;
    return ZIDL_CDR_OK;
}

void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf, size_t cap, int xcdr_version) {
    w->buf          = buf;
    w->cap          = cap;
    w->len          = 0;
    w->pos          = 0;
    w->xcdr_version = xcdr_version;
    w->byte_order   = ZIDL_CDR_LE;
    w->grow_fn      = NULL;
}

void zidl_cdr_writer_deinit(ZidlCdrWriter *w) {
    if (w->grow_fn == writer_grow_default) {
        free(w->buf);
        w->buf = NULL;
        w->cap = 0;
        w->len = 0;
    }
}

void zidl_cdr_writer_set_byte_order(ZidlCdrWriter *w, int byte_order) {
    w->byte_order = byte_order;
}

static int writer_ensure(ZidlCdrWriter *w, size_t n) {
    if (w->len + n <= w->cap) return ZIDL_CDR_OK;
    if (!w->grow_fn) return ZIDL_CDR_OVERFLOW;
    return w->grow_fn(w, n);
}

static int writer_write_bytes(ZidlCdrWriter *w, const uint8_t *bytes, size_t n) {
    int rc = writer_ensure(w, n);
    if (rc) return rc;
    memcpy(w->buf + w->len, bytes, n);
    w->len += n;
    w->pos += n;
    return ZIDL_CDR_OK;
}

static void writer_store_u32_at(const ZidlCdrWriter *w, size_t offset, uint32_t v) {
    if (w->byte_order == ZIDL_CDR_BE) {
        w->buf[offset + 0] = (uint8_t)(v >> 24);
        w->buf[offset + 1] = (uint8_t)(v >> 16);
        w->buf[offset + 2] = (uint8_t)(v >> 8);
        w->buf[offset + 3] = (uint8_t)(v);
    } else {
        w->buf[offset + 0] = (uint8_t)(v);
        w->buf[offset + 1] = (uint8_t)(v >> 8);
        w->buf[offset + 2] = (uint8_t)(v >> 16);
        w->buf[offset + 3] = (uint8_t)(v >> 24);
    }
}

static int writer_pad(ZidlCdrWriter *w, size_t boundary) {
    size_t rem = w->pos % boundary;
    if (rem == 0) return ZIDL_CDR_OK;
    size_t pad = boundary - rem;
    /* Emit zero padding bytes. */
    static const uint8_t zeros[8] = {0,0,0,0,0,0,0,0};
    return writer_write_bytes(w, zeros, pad);
}

/* ── Encapsulation header ─────────────────────────────────────────────────── */

int zidl_cdr_write_encap(ZidlCdrWriter *w) {
    uint16_t id;
    if (w->xcdr_version == ZIDL_XCDR1) {
        id = (uint16_t)(w->byte_order == ZIDL_CDR_BE ? ZIDL_ENCAP_CDR1_BE : ZIDL_ENCAP_CDR1_LE);
    } else if (w->xcdr_version == ZIDL_PL_CDR) {
        id = (uint16_t)(w->byte_order == ZIDL_CDR_BE ? ZIDL_ENCAP_PL_CDR_BE : ZIDL_ENCAP_PL_CDR_LE);
    } else {
        id = (uint16_t)(w->byte_order == ZIDL_CDR_BE ? ZIDL_ENCAP_CDR2_BE : ZIDL_ENCAP_CDR2_LE);
    }
    uint8_t hdr[4] = {
        (uint8_t)(id >> 8),    /* high byte first (big-endian repr ID per RTPS spec) */
        (uint8_t)(id & 0xFFu),
        0x00u,                  /* options — unused */
        0x00u,
    };
    int rc = writer_ensure(w, 4);
    if (rc) return rc;
    memcpy(w->buf + w->len, hdr, 4);
    w->len += 4;
    /* Reset CDR payload position: alignment is measured from payload start. */
    w->pos = 0;
    return ZIDL_CDR_OK;
}

/* ── Primitive writes ─────────────────────────────────────────────────────── */

int zidl_cdr_write_u8(ZidlCdrWriter *w, uint8_t v) {
    return writer_write_bytes(w, &v, 1);
}
int zidl_cdr_write_i8(ZidlCdrWriter *w, int8_t v) {
    return zidl_cdr_write_u8(w, (uint8_t)v);
}
int zidl_cdr_write_bool(ZidlCdrWriter *w, bool v) {
    uint8_t b = v ? 1u : 0u;
    return writer_write_bytes(w, &b, 1);
}
int zidl_cdr_write_char(ZidlCdrWriter *w, char v) {
    return writer_write_bytes(w, (const uint8_t *)&v, 1);
}
int zidl_cdr_write_u16(ZidlCdrWriter *w, uint16_t v) {
    int rc = writer_pad(w, align_cap(w->xcdr_version, 2));
    if (rc) return rc;
    uint8_t b[2];
    if (w->byte_order == ZIDL_CDR_BE) {
        b[0] = (uint8_t)(v >> 8);
        b[1] = (uint8_t)(v & 0xFFu);
    } else {
        b[0] = (uint8_t)(v & 0xFFu);
        b[1] = (uint8_t)(v >> 8);
    }
    return writer_write_bytes(w, b, 2);
}
int zidl_cdr_write_i16(ZidlCdrWriter *w, int16_t v) {
    return zidl_cdr_write_u16(w, (uint16_t)v);
}
int zidl_cdr_write_u32(ZidlCdrWriter *w, uint32_t v) {
    int rc = writer_pad(w, align_cap(w->xcdr_version, 4));
    if (rc) return rc;
    uint8_t b[4];
    if (w->byte_order == ZIDL_CDR_BE) {
        b[0] = (uint8_t)(v >> 24);
        b[1] = (uint8_t)(v >> 16);
        b[2] = (uint8_t)(v >> 8);
        b[3] = (uint8_t)(v);
    } else {
        b[0] = (uint8_t)(v);
        b[1] = (uint8_t)(v >> 8);
        b[2] = (uint8_t)(v >> 16);
        b[3] = (uint8_t)(v >> 24);
    }
    return writer_write_bytes(w, b, 4);
}
int zidl_cdr_write_i32(ZidlCdrWriter *w, int32_t v) {
    return zidl_cdr_write_u32(w, (uint32_t)v);
}
int zidl_cdr_write_f32(ZidlCdrWriter *w, float v) {
    uint32_t bits;
    memcpy(&bits, &v, 4);
    return zidl_cdr_write_u32(w, bits);
}
int zidl_cdr_write_u64(ZidlCdrWriter *w, uint64_t v) {
    int rc = writer_pad(w, align_cap(w->xcdr_version, 8));
    if (rc) return rc;
    uint8_t b[8];
    if (w->byte_order == ZIDL_CDR_BE) {
        b[0] = (uint8_t)(v >> 56);
        b[1] = (uint8_t)(v >> 48);
        b[2] = (uint8_t)(v >> 40);
        b[3] = (uint8_t)(v >> 32);
        b[4] = (uint8_t)(v >> 24);
        b[5] = (uint8_t)(v >> 16);
        b[6] = (uint8_t)(v >> 8);
        b[7] = (uint8_t)(v);
    } else {
        b[0] = (uint8_t)(v);
        b[1] = (uint8_t)(v >> 8);
        b[2] = (uint8_t)(v >> 16);
        b[3] = (uint8_t)(v >> 24);
        b[4] = (uint8_t)(v >> 32);
        b[5] = (uint8_t)(v >> 40);
        b[6] = (uint8_t)(v >> 48);
        b[7] = (uint8_t)(v >> 56);
    }
    return writer_write_bytes(w, b, 8);
}
int zidl_cdr_write_i64(ZidlCdrWriter *w, int64_t v) {
    return zidl_cdr_write_u64(w, (uint64_t)v);
}
int zidl_cdr_write_f64(ZidlCdrWriter *w, double v) {
    uint64_t bits;
    memcpy(&bits, &v, 8);
    return zidl_cdr_write_u64(w, bits);
}

/* fixed<digits,scale> — packed BCD, alignment 1 */
int zidl_cdr_write_fixed(ZidlCdrWriter *w, uint8_t digits, uint8_t scale, double value) {
    uint8_t n = (uint8_t)((digits / 2u) + 1u); /* wire byte count */
    uint8_t n2 = (uint8_t)(2u * n);
    uint8_t pad = (uint8_t)(n2 - digits - 1u); /* 0 if digits odd, 1 if even */
    uint8_t dig[31] = {0};
    uint8_t nib[32] = {0};
    uint8_t buf[16];
    uint8_t i;

    int negative = (value < 0.0);
    double scale_factor = 1.0;
    for (i = 0; i < scale; i++) scale_factor *= 10.0;
    double abs_scaled = (negative ? -value : value) * scale_factor + 0.5;

    /* Max representable: 10^digits - 1 */
    double max_val = 1.0;
    for (i = 0; i < digits; i++) max_val *= 10.0;
    max_val -= 1.0;

    uint64_t int_val = (abs_scaled >= max_val + 1.0) ? (uint64_t)max_val : (uint64_t)abs_scaled;

    for (i = digits; i > 0; i--) {
        dig[i - 1] = (uint8_t)(int_val % 10u);
        int_val /= 10u;
    }

    for (i = 0; i < digits; i++) nib[pad + i] = dig[i];
    nib[n2 - 1] = negative ? 0xDu : 0xCu;

    for (i = 0; i < n; i++) buf[i] = (uint8_t)((nib[2*i] << 4) | nib[2*i + 1]);
    return writer_write_bytes(w, buf, n);
}

/* ── String / wstring writes ─────────────────────────────────────────────── */

int zidl_cdr_write_string(ZidlCdrWriter *w, const char *s, uint32_t len) {
    int rc = zidl_cdr_write_u32(w, len + 1u);
    if (rc) return rc;
    rc = writer_write_bytes(w, (const uint8_t *)s, len);
    if (rc) return rc;
    uint8_t nul = 0u;
    return writer_write_bytes(w, &nul, 1);
}

int zidl_cdr_write_wstring(ZidlCdrWriter *w, const uint16_t *s, uint32_t len) {
    int rc = zidl_cdr_write_u32(w, len + 1u);
    if (rc) return rc;
    for (uint32_t i = 0; i < len; i++) {
        rc = zidl_cdr_write_u16(w, s[i]);
        if (rc) return rc;
    }
    return zidl_cdr_write_u16(w, 0);
}

/* ── DHEADER ─────────────────────────────────────────────────────────────── */

int zidl_cdr_write_dheader(ZidlCdrWriter *w, uint32_t payload_size) {
    return zidl_cdr_write_u32(w, payload_size);
}

int zidl_cdr_reserve_dheader(ZidlCdrWriter *w, size_t *out_offset) {
    *out_offset = w->len;
    return zidl_cdr_write_u32(w, 0);
}

void zidl_cdr_patch_dheader(ZidlCdrWriter *w, size_t dheader_offset) {
    uint32_t payload = (uint32_t)(w->len - dheader_offset - 4u);
    writer_store_u32_at(w, dheader_offset, payload);
}

int zidl_cdr_reserve_dheader_maybe(ZidlCdrWriter *w, size_t *out_offset) {
    if (w->xcdr_version != ZIDL_XCDR2) {
        /* XCDR1 and PL_CDR do not use DHEADER */
        *out_offset = (size_t)-1; /* SIZE_MAX equivalent */
        return ZIDL_CDR_OK;
    }
    return zidl_cdr_reserve_dheader(w, out_offset);
}

void zidl_cdr_patch_dheader_maybe(ZidlCdrWriter *w, size_t dheader_offset) {
    if (dheader_offset == (size_t)-1) return;
    zidl_cdr_patch_dheader(w, dheader_offset);
}

/* ── Reader ──────────────────────────────────────────────────────────────── */

int zidl_cdr_reader_init(ZidlCdrReader *r, const uint8_t *data, size_t data_len) {
    if (data_len < 4) return ZIDL_CDR_INVALID;
    uint16_t id = (uint16_t)(((uint16_t)data[0] << 8) | (uint16_t)data[1]);
    r->is_pl_cdr = 0;
    switch (id) {
        case ZIDL_ENCAP_CDR1_LE:   r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR1; break;
        case ZIDL_ENCAP_CDR1_BE:   r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR1; break;
        case ZIDL_ENCAP_CDR2_LE:   r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR2; break;
        case ZIDL_ENCAP_CDR2_BE:   r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR2; break;
        case ZIDL_ENCAP_PL_CDR_LE: r->byte_order = ZIDL_CDR_LE; r->xcdr_version = ZIDL_XCDR1;
                                    r->is_pl_cdr = 1; break;
        case ZIDL_ENCAP_PL_CDR_BE: r->byte_order = ZIDL_CDR_BE; r->xcdr_version = ZIDL_XCDR1;
                                    r->is_pl_cdr = 1; break;
        default: return ZIDL_CDR_INVALID;
    }
    r->data     = data;
    r->data_len = data_len;
    r->pos      = 4; /* CDR payload starts after the 4-byte encap header */
    return ZIDL_CDR_OK;
}

static size_t reader_align_cap(int xcdr_version, size_t wire_size) {
    return align_cap(xcdr_version, wire_size);
}

static void reader_align_pos(ZidlCdrReader *r, size_t boundary) {
    /*
     * CDR alignment is measured from the start of the CDR payload, which
     * begins after the 4-byte encap header (r->pos == 4 at payload start).
     * So the effective payload offset is (r->pos - 4).
     */
    size_t cdr_pos = r->pos - 4u;
    size_t rem     = cdr_pos % boundary;
    if (rem != 0) r->pos += boundary - rem;
}

static int reader_read_slice(ZidlCdrReader *r, size_t n, const uint8_t **out) {
    if (r->pos + n > r->data_len) return ZIDL_CDR_TRUNCATED;
    *out     = r->data + r->pos;
    r->pos  += n;
    return ZIDL_CDR_OK;
}

static uint16_t maybe_swap16(const ZidlCdrReader *r, uint16_t raw) {
    if (r->byte_order == ZIDL_CDR_LE) return raw;
    return (uint16_t)((raw >> 8) | (raw << 8));
}
static uint32_t maybe_swap32(const ZidlCdrReader *r, uint32_t raw) {
    if (r->byte_order == ZIDL_CDR_LE) return raw;
    return ((raw & 0x000000FFu) << 24) |
           ((raw & 0x0000FF00u) <<  8) |
           ((raw & 0x00FF0000u) >>  8) |
           ((raw & 0xFF000000u) >> 24);
}
static uint64_t maybe_swap64(const ZidlCdrReader *r, uint64_t raw) {
    if (r->byte_order == ZIDL_CDR_LE) return raw;
    return ((raw & UINT64_C(0x00000000000000FF)) << 56) |
           ((raw & UINT64_C(0x000000000000FF00)) << 40) |
           ((raw & UINT64_C(0x0000000000FF0000)) << 24) |
           ((raw & UINT64_C(0x00000000FF000000)) <<  8) |
           ((raw & UINT64_C(0x000000FF00000000)) >>  8) |
           ((raw & UINT64_C(0x0000FF0000000000)) >> 24) |
           ((raw & UINT64_C(0x00FF000000000000)) >> 40) |
           ((raw & UINT64_C(0xFF00000000000000)) >> 56);
}

/* ── Primitive reads ─────────────────────────────────────────────────────── */

int zidl_cdr_read_u8(ZidlCdrReader *r, uint8_t *out) {
    const uint8_t *p;
    int rc = reader_read_slice(r, 1, &p);
    if (rc) return rc;
    *out = p[0];
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i8(ZidlCdrReader *r, int8_t *out) {
    uint8_t v;
    int rc = zidl_cdr_read_u8(r, &v);
    if (rc) return rc;
    *out = (int8_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_bool(ZidlCdrReader *r, bool *out) {
    uint8_t v;
    int rc = zidl_cdr_read_u8(r, &v);
    if (rc) return rc;
    if (v > 1u) return ZIDL_CDR_INVALID;
    *out = (v == 1u);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_char(ZidlCdrReader *r, char *out) {
    return zidl_cdr_read_u8(r, (uint8_t *)out);
}
int zidl_cdr_read_u16(ZidlCdrReader *r, uint16_t *out) {
    reader_align_pos(r, reader_align_cap(r->xcdr_version, 2));
    const uint8_t *p;
    int rc = reader_read_slice(r, 2, &p);
    if (rc) return rc;
    uint16_t raw = (uint16_t)p[0] | ((uint16_t)p[1] << 8);
    *out = maybe_swap16(r, raw);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i16(ZidlCdrReader *r, int16_t *out) {
    uint16_t v;
    int rc = zidl_cdr_read_u16(r, &v);
    if (rc) return rc;
    *out = (int16_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_u32(ZidlCdrReader *r, uint32_t *out) {
    reader_align_pos(r, reader_align_cap(r->xcdr_version, 4));
    const uint8_t *p;
    int rc = reader_read_slice(r, 4, &p);
    if (rc) return rc;
    uint32_t raw = (uint32_t)p[0]        |
                  ((uint32_t)p[1] << 8)  |
                  ((uint32_t)p[2] << 16) |
                  ((uint32_t)p[3] << 24);
    *out = maybe_swap32(r, raw);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i32(ZidlCdrReader *r, int32_t *out) {
    uint32_t v;
    int rc = zidl_cdr_read_u32(r, &v);
    if (rc) return rc;
    *out = (int32_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_f32(ZidlCdrReader *r, float *out) {
    uint32_t bits;
    int rc = zidl_cdr_read_u32(r, &bits);
    if (rc) return rc;
    memcpy(out, &bits, 4);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_u64(ZidlCdrReader *r, uint64_t *out) {
    reader_align_pos(r, reader_align_cap(r->xcdr_version, 8));
    const uint8_t *p;
    int rc = reader_read_slice(r, 8, &p);
    if (rc) return rc;
    uint64_t raw = (uint64_t)p[0]        |
                  ((uint64_t)p[1] << 8)  |
                  ((uint64_t)p[2] << 16) |
                  ((uint64_t)p[3] << 24) |
                  ((uint64_t)p[4] << 32) |
                  ((uint64_t)p[5] << 40) |
                  ((uint64_t)p[6] << 48) |
                  ((uint64_t)p[7] << 56);
    *out = maybe_swap64(r, raw);
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_i64(ZidlCdrReader *r, int64_t *out) {
    uint64_t v;
    int rc = zidl_cdr_read_u64(r, &v);
    if (rc) return rc;
    *out = (int64_t)v;
    return ZIDL_CDR_OK;
}
int zidl_cdr_read_f64(ZidlCdrReader *r, double *out) {
    uint64_t bits;
    int rc = zidl_cdr_read_u64(r, &bits);
    if (rc) return rc;
    memcpy(out, &bits, 8);
    return ZIDL_CDR_OK;
}

/* fixed<digits,scale> — packed BCD, alignment 1 */
int zidl_cdr_read_fixed(ZidlCdrReader *r, uint8_t digits, uint8_t scale, double *out) {
    uint8_t n = (uint8_t)((digits / 2u) + 1u);
    uint8_t n2 = (uint8_t)(2u * n);
    uint8_t pad = (uint8_t)(n2 - digits - 1u);
    const uint8_t *buf;
    uint8_t nib[32];
    uint8_t i;
    int rc;

    rc = reader_read_slice(r, n, &buf);
    if (rc) return rc;

    for (i = 0; i < n; i++) {
        nib[2*i]     = (buf[i] >> 4) & 0x0Fu;
        nib[2*i + 1] = buf[i] & 0x0Fu;
    }

    uint64_t int_val = 0;
    for (i = 0; i < digits; i++) {
        uint8_t d = nib[pad + i];
        if (d > 9u) return ZIDL_CDR_INVALID;
        int_val = int_val * 10u + d;
    }

    uint8_t sign_nib = nib[n2 - 1];
    int negative = (sign_nib == 0xDu || sign_nib == 0xBu);

    double scale_factor = 1.0;
    for (i = 0; i < scale; i++) scale_factor *= 10.0;

    *out = (double)int_val / scale_factor;
    if (negative) *out = -*out;
    return ZIDL_CDR_OK;
}

/* ── String / wstring reads ──────────────────────────────────────────────── */

int zidl_cdr_read_string_zerocopy(ZidlCdrReader *r, const char **out, uint32_t *out_len) {
    uint32_t len; /* byte count including NUL */
    int rc = zidl_cdr_read_u32(r, &len);
    if (rc) return rc;
    if (len == 0) return ZIDL_CDR_INVALID;
    const uint8_t *p;
    rc = reader_read_slice(r, len, &p);
    if (rc) return rc;
    *out     = (const char *)p;
    *out_len = len - 1u; /* exclude NUL */
    return ZIDL_CDR_OK;
}

int zidl_cdr_read_string(ZidlCdrReader *r, char **out) {
    const char *p;
    uint32_t    len;
    int rc = zidl_cdr_read_string_zerocopy(r, &p, &len);
    if (rc) return rc;
    char *buf = (char *)malloc(len + 1u);
    if (!buf) return ZIDL_CDR_OVERFLOW;
    memcpy(buf, p, len);
    buf[len] = '\0';
    *out = buf;
    return ZIDL_CDR_OK;
}

int zidl_cdr_read_wstring(ZidlCdrReader *r, uint16_t **out, uint32_t *out_len) {
    uint32_t len; /* wchar count including NUL wchar */
    int rc = zidl_cdr_read_u32(r, &len);
    if (rc) return rc;
    if (len == 0) return ZIDL_CDR_INVALID;
    uint32_t char_count = len - 1u;
    /* +1 for NUL wchar so caller can treat *out as a NUL-terminated uint16_t string. */
    uint16_t *buf = (uint16_t *)malloc((char_count + 1u) * sizeof(uint16_t));
    if (!buf) return ZIDL_CDR_OVERFLOW;
    for (uint32_t i = 0; i < char_count; i++) {
        rc = zidl_cdr_read_u16(r, &buf[i]);
        if (rc) { free(buf); return rc; }
    }
    uint16_t nul_wchar;
    rc = zidl_cdr_read_u16(r, &nul_wchar); /* discard NUL wchar */
    if (rc) { free(buf); return rc; }
    buf[char_count] = 0; /* NUL-terminate */
    *out     = buf;
    *out_len = char_count;
    return ZIDL_CDR_OK;
}

/* ── XCDR2 framing ───────────────────────────────────────────────────────── */

int zidl_cdr_read_dheader(ZidlCdrReader *r, uint32_t *out) {
    return zidl_cdr_read_u32(r, out);
}

int zidl_cdr_skip_dheader_if_xcdr2(ZidlCdrReader *r) {
    if (r->xcdr_version == ZIDL_XCDR2) {
        uint32_t dummy;
        return zidl_cdr_read_dheader(r, &dummy);
    }
    return ZIDL_CDR_OK;
}

int zidl_cdr_read_emheader(ZidlCdrReader *r, ZidlEmHeader *out) {
    uint32_t word;
    int rc = zidl_cdr_read_u32(r, &word);
    if (rc) return rc;
    out->must_understand = (word & 0x80000000u) != 0;
    out->lc       = (uint8_t)((word >> 28) & 0x7u);
    out->member_id = word & 0x0FFFFFFFu;
    switch (out->lc) {
        case 0: out->payload_bytes = 1u; break;
        case 1: out->payload_bytes = 2u; break;
        case 2: out->payload_bytes = 4u; break;
        case 3: out->payload_bytes = 8u; break;
        case 4: case 5: case 6: {
            uint32_t nextint;
            rc = zidl_cdr_read_u32(r, &nextint);
            if (rc) return rc;
            if      (out->lc == 4) out->payload_bytes = nextint;
            else if (out->lc == 5) out->payload_bytes = nextint * 4u;
            else                   out->payload_bytes = nextint * 8u;
            break;
        }
        default: return ZIDL_CDR_INVALID; /* LC=7 reserved */
    }
    return ZIDL_CDR_OK;
}

int zidl_cdr_write_emheader(ZidlCdrWriter *w, uint32_t member_id,
                             bool must_understand, uint8_t lc) {
    uint32_t mu  = must_understand ? 0x80000000u : 0u;
    uint32_t word = mu | ((uint32_t)(lc & 0x7u) << 28) | (member_id & 0x0FFFFFFFu);
    return zidl_cdr_write_u32(w, word);
}

int zidl_cdr_reserve_emheader(ZidlCdrWriter *w, uint32_t member_id,
                               bool must_understand, size_t *out_nextint_offset) {
    uint32_t mu  = must_understand ? 0x80000000u : 0u;
    /* LC=4: NEXTINT encodes payload byte count directly */
    uint32_t word = mu | (4u << 28) | (member_id & 0x0FFFFFFFu);
    int rc = zidl_cdr_write_u32(w, word);
    if (rc) return rc;
    *out_nextint_offset = w->len;
    return zidl_cdr_write_u32(w, 0); /* placeholder NEXTINT */
}

void zidl_cdr_patch_emheader(ZidlCdrWriter *w, size_t nextint_offset,
                              size_t payload_start) {
    uint32_t payload_bytes = (uint32_t)(w->len - payload_start);
    writer_store_u32_at(w, nextint_offset, payload_bytes);
}

int zidl_cdr_read_mutable_dheader(ZidlCdrReader *r, size_t *out_end_pos) {
    uint32_t size;
    int rc = zidl_cdr_read_dheader(r, &size);
    if (rc) return rc;
    *out_end_pos = r->pos + (size_t)size;
    return ZIDL_CDR_OK;
}

bool zidl_cdr_mutable_has_more(const ZidlCdrReader *r, size_t end_pos) {
    return r->pos < end_pos;
}

int zidl_cdr_skip_emheader_payload(ZidlCdrReader *r, const ZidlEmHeader *emh) {
    if (emh->lc < 4) {
        /* Align to the primitive size before skipping */
        size_t cap = align_cap(r->xcdr_version, emh->payload_bytes);
        reader_align_pos(r, cap);
    }
    return zidl_cdr_skip(r, emh->payload_bytes);
}

/* ── Utility ─────────────────────────────────────────────────────────────── */

size_t zidl_cdr_remaining(const ZidlCdrReader *r) {
    return (r->pos < r->data_len) ? (r->data_len - r->pos) : 0;
}

int zidl_cdr_skip(ZidlCdrReader *r, size_t n) {
    if (r->pos + n > r->data_len) return ZIDL_CDR_TRUNCATED;
    r->pos += n;
    return ZIDL_CDR_OK;
}

int zidl_cdr_seek_to(ZidlCdrReader *r, size_t abs_pos) {
    if (abs_pos > r->data_len) return ZIDL_CDR_TRUNCATED;
    r->pos = abs_pos;
    return ZIDL_CDR_OK;
}

/* ── MD5 / key hash ─────────────────────────────────────────────────────── */

typedef struct ZidlMd5Ctx {
    uint32_t h[4];
    uint64_t bit_len;
    uint8_t  block[64];
    size_t   block_len;
} ZidlMd5Ctx;

static uint32_t md5_rotl(uint32_t x, uint32_t c) {
    return (x << c) | (x >> (32u - c));
}

static uint32_t md5_load32_le(const uint8_t *p) {
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void md5_store32_le(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v;
    p[1] = (uint8_t)(v >> 8);
    p[2] = (uint8_t)(v >> 16);
    p[3] = (uint8_t)(v >> 24);
}

static void md5_transform(ZidlMd5Ctx *ctx, const uint8_t block[64]) {
    static const uint32_t s[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
    };
    static const uint32_t k[64] = {
        0xd76aa478u, 0xe8c7b756u, 0x242070dbu, 0xc1bdceeeu,
        0xf57c0fafu, 0x4787c62au, 0xa8304613u, 0xfd469501u,
        0x698098d8u, 0x8b44f7afu, 0xffff5bb1u, 0x895cd7beu,
        0x6b901122u, 0xfd987193u, 0xa679438eu, 0x49b40821u,
        0xf61e2562u, 0xc040b340u, 0x265e5a51u, 0xe9b6c7aau,
        0xd62f105du, 0x02441453u, 0xd8a1e681u, 0xe7d3fbc8u,
        0x21e1cde6u, 0xc33707d6u, 0xf4d50d87u, 0x455a14edu,
        0xa9e3e905u, 0xfcefa3f8u, 0x676f02d9u, 0x8d2a4c8au,
        0xfffa3942u, 0x8771f681u, 0x6d9d6122u, 0xfde5380cu,
        0xa4beea44u, 0x4bdecfa9u, 0xf6bb4b60u, 0xbebfbc70u,
        0x289b7ec6u, 0xeaa127fau, 0xd4ef3085u, 0x04881d05u,
        0xd9d4d039u, 0xe6db99e5u, 0x1fa27cf8u, 0xc4ac5665u,
        0xf4292244u, 0x432aff97u, 0xab9423a7u, 0xfc93a039u,
        0x655b59c3u, 0x8f0ccc92u, 0xffeff47du, 0x85845dd1u,
        0x6fa87e4fu, 0xfe2ce6e0u, 0xa3014314u, 0x4e0811a1u,
        0xf7537e82u, 0xbd3af235u, 0x2ad7d2bbu, 0xeb86d391u,
    };
    uint32_t m[16];
    for (int i = 0; i < 16; i++) m[i] = md5_load32_le(block + (size_t)i * 4u);

    uint32_t a = ctx->h[0];
    uint32_t b = ctx->h[1];
    uint32_t c = ctx->h[2];
    uint32_t d = ctx->h[3];

    for (uint32_t i = 0; i < 64u; i++) {
        uint32_t f, g;
        if (i < 16u) {
            f = (b & c) | ((~b) & d);
            g = i;
        } else if (i < 32u) {
            f = (d & b) | ((~d) & c);
            g = (5u * i + 1u) & 15u;
        } else if (i < 48u) {
            f = b ^ c ^ d;
            g = (3u * i + 5u) & 15u;
        } else {
            f = c ^ (b | (~d));
            g = (7u * i) & 15u;
        }
        uint32_t tmp = d;
        d = c;
        c = b;
        b = b + md5_rotl(a + f + k[i] + m[g], s[i]);
        a = tmp;
    }

    ctx->h[0] += a;
    ctx->h[1] += b;
    ctx->h[2] += c;
    ctx->h[3] += d;
}

static void md5_init(ZidlMd5Ctx *ctx) {
    ctx->h[0] = 0x67452301u;
    ctx->h[1] = 0xefcdab89u;
    ctx->h[2] = 0x98badcfeu;
    ctx->h[3] = 0x10325476u;
    ctx->bit_len = 0;
    ctx->block_len = 0;
}

static void md5_update(ZidlMd5Ctx *ctx, const uint8_t *data, size_t len) {
    ctx->bit_len += (uint64_t)len * 8u;
    while (len > 0) {
        size_t n = 64u - ctx->block_len;
        if (n > len) n = len;
        memcpy(ctx->block + ctx->block_len, data, n);
        ctx->block_len += n;
        data += n;
        len -= n;
        if (ctx->block_len == 64u) {
            md5_transform(ctx, ctx->block);
            ctx->block_len = 0;
        }
    }
}

static void md5_final(ZidlMd5Ctx *ctx, uint8_t out[16]) {
    uint64_t bit_len = ctx->bit_len;
    uint8_t one = 0x80u;
    uint8_t zero = 0u;
    md5_update(ctx, &one, 1);
    while (ctx->block_len != 56u) md5_update(ctx, &zero, 1);

    uint8_t len_bytes[8];
    for (int i = 0; i < 8; i++) len_bytes[i] = (uint8_t)(bit_len >> (8u * (uint32_t)i));
    md5_update(ctx, len_bytes, 8);

    for (int i = 0; i < 4; i++) md5_store32_le(out + (size_t)i * 4u, ctx->h[i]);
}

void zidl_md5(const uint8_t *data, size_t len, uint8_t out[16]) {
    ZidlMd5Ctx ctx;
    md5_init(&ctx);
    md5_update(&ctx, data, len);
    md5_final(&ctx, out);
}

void zidl_cdr_compute_key_hash(const uint8_t *serialized_key, size_t len, uint8_t out[16]) {
    if (len <= 16u) {
        memset(out, 0, 16u);
        if (len > 0) memcpy(out, serialized_key, len);
        return;
    }
    zidl_md5(serialized_key, len, out);
}

/* ── PL_CDR writer ───────────────────────────────────────────────────────── */

int zidl_cdr_pl_write_encap(ZidlCdrWriter *w) {
    static const uint8_t hdr[4] = { 0x00u, 0x03u, 0x00u, 0x00u };
    int rc = writer_ensure(w, 4);
    if (rc) return rc;
    memcpy(w->buf + w->len, hdr, 4);
    w->len += 4;
    w->pos  = 0;
    return ZIDL_CDR_OK;
}

int zidl_cdr_pl_reserve_param(ZidlCdrWriter *w, uint16_t pid,
                               ZidlPlParamHandle *out_handle) {
    /* Write pid as LE u16; we're always at a 4-byte boundary, so no padding needed */
    int rc = zidl_cdr_write_u16(w, pid);
    if (rc) return rc;
    out_handle->len_offset = w->len;
    rc = zidl_cdr_write_u16(w, 0u); /* placeholder length */
    if (rc) return rc;
    out_handle->buf_value_start = w->len;
    return ZIDL_CDR_OK;
}

int zidl_cdr_pl_patch_param(ZidlCdrWriter *w, ZidlPlParamHandle handle) {
    size_t raw_bytes = w->len - handle.buf_value_start;
    size_t rem       = raw_bytes % 4u;
    size_t pad       = (rem == 0u) ? 0u : (4u - rem);
    if (pad > 0u) {
        static const uint8_t zeros[4] = {0,0,0,0};
        int rc = writer_write_bytes(w, zeros, pad);
        if (rc) return rc;
    }
    uint16_t padded = (uint16_t)(raw_bytes + pad);
    w->buf[handle.len_offset]     = (uint8_t)(padded & 0xFFu);
    w->buf[handle.len_offset + 1] = (uint8_t)(padded >> 8);
    return ZIDL_CDR_OK;
}

int zidl_cdr_pl_write_sentinel(ZidlCdrWriter *w) {
    static const uint8_t sentinel[4] = { 0x01u, 0x00u, 0x00u, 0x00u };
    int rc = writer_ensure(w, 4);
    if (rc) return rc;
    memcpy(w->buf + w->len, sentinel, 4);
    w->len += 4;
    w->pos += 4;
    return ZIDL_CDR_OK;
}

/* ── PL_CDR reader ───────────────────────────────────────────────────────── */

int zidl_cdr_pl_read_param(ZidlCdrReader *r, ZidlPlParam *out) {
    uint16_t pid, len;
    int rc = zidl_cdr_read_u16(r, &pid);
    if (rc) return rc;
    rc = zidl_cdr_read_u16(r, &len);
    if (rc) return rc;
    out->pid      = pid;
    out->byte_len = len;
    /* end_pos = current pos + round_up_4(len) */
    size_t padded = ((size_t)len + 3u) & ~(size_t)3u;
    out->end_pos  = r->pos + padded;
    return ZIDL_CDR_OK;
}
