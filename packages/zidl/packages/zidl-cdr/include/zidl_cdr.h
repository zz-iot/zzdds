/**
 * zidl-cdr — Standalone C99 CDR library.
 *
 * Implements OMG XCDR1 and XCDR2 (little-endian output) for DDS CDR
 * serialization.  No dependencies; compiles with any hosted or freestanding
 * C99 toolchain (GCC, Clang, MSVC, IAR, arm-none-eabi-gcc).
 *
 * Key properties (matching zidl-rt semantics):
 *   - CDR alignment is from the start of the CDR payload (after the 4-byte
 *     encapsulation header).  ZidlCdrWriter.pos resets to 0 after
 *     zidl_cdr_write_encap().
 *   - XCDR1: natural alignment up to 8 bytes (IDL §9.3.1).
 *   - XCDR2: natural alignment capped at 4 bytes (XTypes §7.4.1).
 *   - Always emits little-endian output.  Reader handles both byte orders.
 *   - Cross-validated byte-for-byte against zidl-rt.
 *
 * ## Error codes
 *   ZIDL_CDR_OK          ( 0) — success
 *   ZIDL_CDR_OVERFLOW   (-1) — buffer full (fixed mode) or malloc failed
 *   ZIDL_CDR_TRUNCATED  (-2) — reader hit end of data before read completed
 *   ZIDL_CDR_INVALID    (-3) — bad encap ID, invalid bool byte, etc.
 */
#ifndef ZIDL_CDR_H
#define ZIDL_CDR_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Error codes ─────────────────────────────────────────────────────────── */

#define ZIDL_CDR_OK          0
#define ZIDL_CDR_OVERFLOW  (-1)
#define ZIDL_CDR_TRUNCATED (-2)
#define ZIDL_CDR_INVALID   (-3)

/* ── XCDR version ────────────────────────────────────────────────────────── */

#define ZIDL_XCDR1   1
#define ZIDL_XCDR2   2
#define ZIDL_PL_CDR  3  /**< XCDR1 ParameterList (PL_CDR) framing */

/* ── Byte order ──────────────────────────────────────────────────────────── */

#define ZIDL_CDR_LE 0
#define ZIDL_CDR_BE 1

/* ── Encapsulation identifiers (written big-endian in bytes [0..1]) ──────── */

/** CDR1 LE → header 0x00 0x01 0x00 0x00 */
#define ZIDL_ENCAP_CDR1_LE    0x0001u
/** CDR1 BE → header 0x00 0x00 0x00 0x00 */
#define ZIDL_ENCAP_CDR1_BE    0x0000u
/** CDR2 LE → header 0x00 0x07 0x00 0x00 (confirmed Cyclone DDS 11.0.1) */
#define ZIDL_ENCAP_CDR2_LE    0x0007u
/** CDR2 BE → header 0x00 0x06 0x00 0x00 */
#define ZIDL_ENCAP_CDR2_BE    0x0006u
/** PL_CDR LE → header 0x00 0x03 0x00 0x00 (RTPS §10.2) */
#define ZIDL_ENCAP_PL_CDR_LE  0x0003u
/** PL_CDR BE → header 0x00 0x02 0x00 0x00 */
#define ZIDL_ENCAP_PL_CDR_BE  0x0002u

/** PID_SENTINEL — terminates a PL_CDR ParameterList */
#define ZIDL_CDR_PID_SENTINEL 0x0001u
/** PID_PAD — ignored padding parameter */
#define ZIDL_CDR_PID_PAD      0x0000u

/* ── CDR Writer ──────────────────────────────────────────────────────────── */

/**
 * CDR writer state.
 *
 * Two modes:
 *   - Dynamic (malloc-backed): init with zidl_cdr_writer_init().  Buffer
 *     grows automatically.  Must call zidl_cdr_writer_deinit() when done.
 *   - Fixed: init with zidl_cdr_writer_init_fixed().  Writes into caller-
 *     supplied buf[0..cap]; returns ZIDL_CDR_OVERFLOW if full.  No deinit.
 *
 * Fields (treat as opaque; access only via API functions):
 *   buf  — write buffer
 *   cap  — total buffer capacity in bytes
 *   len  — bytes written (includes the 4-byte encap header)
 *   pos  — CDR payload byte count used for alignment; resets to 0 after
 *           zidl_cdr_write_encap() so alignment is from the start of the
 *           CDR payload (not the start of the buffer)
 */
typedef struct ZidlCdrWriter {
    uint8_t *buf;
    size_t   cap;
    size_t   len;
    size_t   pos;
    int      xcdr_version;
    int      byte_order;
    /** Non-NULL → dynamic mode: called to grow buf.  NULL → fixed mode. */
    int    (*grow_fn)(struct ZidlCdrWriter *w, size_t needed);
} ZidlCdrWriter;

/** Init a malloc-backed writer.  Pair with zidl_cdr_writer_deinit(). */
int  zidl_cdr_writer_init      (ZidlCdrWriter *w, int xcdr_version);
/** Init a fixed-buffer writer.  No deinit required. */
void zidl_cdr_writer_init_fixed(ZidlCdrWriter *w, uint8_t *buf, size_t cap, int xcdr_version);
/** Free a malloc-backed writer's buffer.  No-op for fixed-buffer writers. */
void zidl_cdr_writer_deinit    (ZidlCdrWriter *w);
/** Set writer byte order. Defaults to ZIDL_CDR_LE. */
void zidl_cdr_writer_set_byte_order(ZidlCdrWriter *w, int byte_order);

/* Encapsulation header ── must be the first call after init */
int zidl_cdr_write_encap(ZidlCdrWriter *w);

/* Primitives */
int zidl_cdr_write_u8  (ZidlCdrWriter *w, uint8_t   v);
int zidl_cdr_write_i8  (ZidlCdrWriter *w, int8_t    v);
int zidl_cdr_write_bool(ZidlCdrWriter *w, bool      v);
int zidl_cdr_write_char(ZidlCdrWriter *w, char      v);
int zidl_cdr_write_u16 (ZidlCdrWriter *w, uint16_t  v);
int zidl_cdr_write_i16 (ZidlCdrWriter *w, int16_t   v);
int zidl_cdr_write_u32 (ZidlCdrWriter *w, uint32_t  v);
int zidl_cdr_write_i32 (ZidlCdrWriter *w, int32_t   v);
int zidl_cdr_write_f32 (ZidlCdrWriter *w, float     v);
int zidl_cdr_write_u64 (ZidlCdrWriter *w, uint64_t  v);
int zidl_cdr_write_i64 (ZidlCdrWriter *w, int64_t   v);
int zidl_cdr_write_f64 (ZidlCdrWriter *w, double    v);

/**
 * Write a fixed<digits,scale> value as packed BCD (alignment 1).
 * N = (digits/2)+1 bytes; sign nibble 0xC positive/zero, 0xD negative.
 * digits must be 1..31; scale must be <= digits.
 */
int zidl_cdr_write_fixed(ZidlCdrWriter *w, uint8_t digits, uint8_t scale, double value);

/**
 * CDR string: writes u32 length (byte count + 1 for NUL), then bytes, NUL.
 * len = strlen(s); does not count the NUL terminator.
 */
int zidl_cdr_write_string (ZidlCdrWriter *w, const char     *s, uint32_t len);
/**
 * CDR wstring: writes u32 count (wchar count + 1 for NUL wchar), wchars, NUL wchar.
 * len = wchar count; does not count the NUL wchar.
 */
int zidl_cdr_write_wstring(ZidlCdrWriter *w, const uint16_t *s, uint32_t len);

/* XCDR2 DHEADER framing */

/** Write a DHEADER with an already-known payload_size. */
int  zidl_cdr_write_dheader       (ZidlCdrWriter *w, uint32_t payload_size);
/** Reserve a DHEADER slot (writes placeholder 0); returns offset. */
int  zidl_cdr_reserve_dheader     (ZidlCdrWriter *w, size_t *out_offset);
/** Patch a DHEADER reserved with zidl_cdr_reserve_dheader(). */
void zidl_cdr_patch_dheader       (ZidlCdrWriter *w, size_t dheader_offset);

/**
 * On XCDR2: reserves a DHEADER and stores offset in *out_offset.
 * On XCDR1: no-op; stores SIZE_MAX in *out_offset.
 */
int  zidl_cdr_reserve_dheader_maybe(ZidlCdrWriter *w, size_t *out_offset);
/** Patch DHEADER at dheader_offset; no-op if dheader_offset == SIZE_MAX. */
void zidl_cdr_patch_dheader_maybe  (ZidlCdrWriter *w, size_t dheader_offset);

/* ── CDR Reader ──────────────────────────────────────────────────────────── */

/**
 * CDR reader state.  Constructed by parsing the 4-byte encapsulation header.
 * Subsequent reads apply alignment padding and byte-swap for big-endian streams.
 */
typedef struct ZidlCdrReader {
    const uint8_t *data;
    size_t         data_len;
    /** Current read position; starts at 4 (past the encap header). */
    size_t         pos;
    int            byte_order;   /**< ZIDL_CDR_LE or ZIDL_CDR_BE */
    int            xcdr_version; /**< ZIDL_XCDR1, ZIDL_XCDR2, or ZIDL_PL_CDR */
    /** Non-zero when stream uses PL_CDR ParameterList framing. */
    int            is_pl_cdr;
} ZidlCdrReader;

/**
 * Parse the 4-byte CDR encapsulation header and initialize the reader.
 * Returns ZIDL_CDR_INVALID for unknown encapsulation IDs or data shorter
 * than 4 bytes.
 */
int zidl_cdr_reader_init(ZidlCdrReader *r, const uint8_t *data, size_t data_len);

/* Primitives */
int zidl_cdr_read_u8  (ZidlCdrReader *r, uint8_t   *out);
int zidl_cdr_read_i8  (ZidlCdrReader *r, int8_t    *out);
int zidl_cdr_read_bool(ZidlCdrReader *r, bool      *out);
int zidl_cdr_read_char(ZidlCdrReader *r, char      *out);
int zidl_cdr_read_u16 (ZidlCdrReader *r, uint16_t  *out);
int zidl_cdr_read_i16 (ZidlCdrReader *r, int16_t   *out);
int zidl_cdr_read_u32 (ZidlCdrReader *r, uint32_t  *out);
int zidl_cdr_read_i32 (ZidlCdrReader *r, int32_t   *out);
int zidl_cdr_read_f32 (ZidlCdrReader *r, float     *out);
int zidl_cdr_read_u64 (ZidlCdrReader *r, uint64_t  *out);
int zidl_cdr_read_i64 (ZidlCdrReader *r, int64_t   *out);
int zidl_cdr_read_f64 (ZidlCdrReader *r, double    *out);

/**
 * Read a fixed<digits,scale> value from packed BCD (alignment 1).
 * Returns ZIDL_CDR_INVALID if a digit nibble > 9 is encountered.
 */
int zidl_cdr_read_fixed(ZidlCdrReader *r, uint8_t digits, uint8_t scale, double *out);

/**
 * Zero-copy string read: *out points into the CDR data buffer (no malloc).
 * *out_len = byte count excluding the trailing NUL.
 * Valid as long as the buffer passed to zidl_cdr_reader_init stays alive.
 */
int zidl_cdr_read_string_zerocopy(ZidlCdrReader *r, const char **out, uint32_t *out_len);

/**
 * Allocating string read.  Caller must free(*out) with free().
 */
int zidl_cdr_read_string (ZidlCdrReader *r, char     **out);

/**
 * Allocating wstring read.  Caller must free(*out) with free().
 * *out is NUL-terminated (a trailing uint16_t 0 is appended after the chars).
 * *out_len = wchar count excluding the trailing NUL wchar.
 */
int zidl_cdr_read_wstring(ZidlCdrReader *r, uint16_t **out, uint32_t *out_len);

/* XCDR2 framing */
int zidl_cdr_read_dheader         (ZidlCdrReader *r, uint32_t *out);
/** On XCDR2: reads and discards the DHEADER.  On XCDR1: no-op. */
int zidl_cdr_skip_dheader_if_xcdr2(ZidlCdrReader *r);

/** Decoded EMHEADER for one @mutable type member. */
typedef struct ZidlEmHeader {
    uint32_t member_id;
    bool     must_understand;
    /** Raw length code (0–6): 0→1B, 1→2B, 2→4B, 3→8B, 4–6→NEXTINT-encoded. */
    uint8_t  lc;
    /**
     * Byte count of this member's payload.  Always set:
     *   LC=0→1, LC=1→2, LC=2→4, LC=3→8, LC=4→NEXTINT, LC=5→NEXTINT×4, LC=6→NEXTINT×8.
     */
    uint32_t payload_bytes;
} ZidlEmHeader;

int zidl_cdr_read_emheader(ZidlCdrReader *r, ZidlEmHeader *out);

/* XCDR2 EMHEADER write support (for @mutable types) */

/**
 * Write a fixed-size EMHEADER for a member with payload 1, 2, 4, or 8 bytes
 * (LC 0–3).  No NEXTINT is written.  lc must be 0, 1, 2, or 3.
 */
int zidl_cdr_write_emheader(ZidlCdrWriter *w, uint32_t member_id,
                             bool must_understand, uint8_t lc);

/**
 * Reserve an EMHEADER + NEXTINT placeholder (LC=4) for a variable-length member.
 * Stores the offset of the NEXTINT word in *out_nextint_offset.
 * After writing the member payload, call zidl_cdr_patch_emheader().
 */
int zidl_cdr_reserve_emheader(ZidlCdrWriter *w, uint32_t member_id,
                               bool must_understand, size_t *out_nextint_offset);

/**
 * Patch the NEXTINT written by zidl_cdr_reserve_emheader() with the actual
 * payload byte count.  payload_start is w->len immediately after the NEXTINT
 * was written (i.e. the offset of the first payload byte in the buffer).
 */
void zidl_cdr_patch_emheader(ZidlCdrWriter *w, size_t nextint_offset,
                              size_t payload_start);

/* XCDR2 @mutable reader helpers */

/**
 * Read the DHEADER for a @mutable type and store the absolute end position
 * of the mutable payload in *out_end_pos.  Generated deserializers loop
 * while (zidl_cdr_mutable_has_more(r, end_pos)).
 */
int  zidl_cdr_read_mutable_dheader(ZidlCdrReader *r, size_t *out_end_pos);

/** True while there are more EMHEADER-framed members to consume. */
bool zidl_cdr_mutable_has_more(const ZidlCdrReader *r, size_t end_pos);

/**
 * Skip the payload of an unknown EMHEADER member.
 * For LC < 4: aligns to the primitive size then skips payload_bytes bytes.
 * For LC >= 4: skips payload_bytes bytes directly.
 */
int  zidl_cdr_skip_emheader_payload(ZidlCdrReader *r, const ZidlEmHeader *emh);

/* Utility */
size_t zidl_cdr_remaining(const ZidlCdrReader *r);
int    zidl_cdr_skip      (ZidlCdrReader *r, size_t n);

/**
 * Seek to an absolute position in the reader buffer.
 * Used by generated PL_CDR deserializers to advance to PlParam.end_pos
 * after processing (or skipping) a parameter value.
 * Returns ZIDL_CDR_TRUNCATED if abs_pos > data_len.
 */
int zidl_cdr_seek_to(ZidlCdrReader *r, size_t abs_pos);

/* ── Key hash helpers ───────────────────────────────────────────────────── */

/** MD5 digest helper used for RTPS key hashes. */
void zidl_md5(const uint8_t *data, size_t len, uint8_t out[16]);

/**
 * RTPS key hash rule: serialized key <= 16 bytes is zero-padded, otherwise
 * MD5(serialized key) is returned.
 */
void zidl_cdr_compute_key_hash(const uint8_t *serialized_key, size_t len, uint8_t out[16]);

/* ── PL_CDR (ParameterList CDR) writer ──────────────────────────────────── */

/**
 * Handle returned by zidl_cdr_pl_reserve_param().
 * Pass to zidl_cdr_pl_patch_param() after writing the member value.
 */
typedef struct ZidlPlParamHandle {
    size_t len_offset;       /**< Byte offset of the u16 length field in buf */
    size_t buf_value_start;  /**< Byte offset of the first value byte in buf */
} ZidlPlParamHandle;

/**
 * Write PL_CDR_LE encapsulation header [0x00 0x03 0x00 0x00].
 * Must be called first; resets w->pos to 0.
 * xcdr_version must be ZIDL_PL_CDR (set by zidl_cdr_writer_init).
 */
int zidl_cdr_pl_write_encap(ZidlCdrWriter *w);

/**
 * Write (pid, 0) placeholder header and return a handle.
 * Write the member value after this call, then call zidl_cdr_pl_patch_param().
 */
int zidl_cdr_pl_reserve_param(ZidlCdrWriter *w, uint16_t pid,
                               ZidlPlParamHandle *out_handle);

/**
 * Pad the current value to a 4-byte boundary and patch the length field.
 */
int zidl_cdr_pl_patch_param(ZidlCdrWriter *w, ZidlPlParamHandle handle);

/**
 * Write PID_SENTINEL (0x0001, 0x0000) to terminate the parameter list.
 */
int zidl_cdr_pl_write_sentinel(ZidlCdrWriter *w);

/* ── PL_CDR reader ───────────────────────────────────────────────────────── */

/**
 * Decoded PL_CDR parameter header.
 */
typedef struct ZidlPlParam {
    uint16_t pid;        /**< Parameter ID (full 16-bit value; mask 0x3FFF for member ID) */
    uint16_t byte_len;   /**< Raw value byte count from the length field */
    size_t   end_pos;    /**< Absolute reader pos after value + padding (seekTo target) */
} ZidlPlParam;

/**
 * Read one PL_CDR parameter header.
 *
 * Returns ZIDL_CDR_OK and sets *out on success.
 * Sets out->pid = ZIDL_CDR_PID_SENTINEL (0x0001) when the sentinel is reached.
 * The caller should stop the loop when out->pid == ZIDL_CDR_PID_SENTINEL.
 * Returns ZIDL_CDR_TRUNCATED if the buffer is exhausted before the sentinel.
 */
int zidl_cdr_pl_read_param(ZidlCdrReader *r, ZidlPlParam *out);

#ifdef __cplusplus
}
#endif
#endif /* ZIDL_CDR_H */
