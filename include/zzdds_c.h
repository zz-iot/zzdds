#ifndef ZZDDS_C_H
#define ZZDDS_C_H

/*
 * Low-level support ABI used by zidl-generated zzdds topic wrappers.
 *
 * Prefer the generated DDS/zzdds language bindings for application code. This
 * header intentionally stays small and byte-oriented: it bridges generated CDR
 * TypeSupport/DataWriter/DataReader wrappers to the hand-written zzdds runtime.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include "dcps.h"
#include "zzdds.h"
#include "zidl_allocator.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*zzdds_compute_key_hash_fn)(const uint8_t *payload, size_t len, uint8_t hash_out[16]);

/* Discriminated field value used by get_field_from_cdr (below) and by
 * zzdds_cft_match_sample (see its own section further down): kind 0 = int
 * (i valid), 1 = float64 (f valid), 2 = string (s_ptr/s_len valid),
 * 3 = float32 (f valid). */
typedef struct zzdds_filter_value {
    int kind;
    int64_t i;
    double f;
    const uint8_t *s_ptr;
    size_t s_len;
} zzdds_filter_value;

/*
 * Resolve a named field (e.g. "color", "x") from a raw, not-yet-deserialized
 * CDR payload -- used to evaluate ContentFilteredTopic expressions
 * automatically, at delivery time, for a reader created against a CFT (see
 * zzdds_register_type_support(_ctx)'s get_field_fn parameter below). Return
 * false for an unknown/unsupported field.
 *
 * `scratch`/`scratch_len`: a returned string value's bytes MUST be copied
 * into `scratch` (`out->s_ptr = scratch`, `out->s_len <= scratch_len`)
 * rather than pointing into any locally-deserialized value -- the caller
 * only guarantees `scratch` (not any local you deserialize `payload` into)
 * valid beyond this one call. Return false if the matched string doesn't
 * fit in `scratch` (matches zzdds's own "an evaluation error passes the
 * sample through" semantics, safer than truncating and risking a wrong
 * comparison result).
 */
typedef bool (*zzdds_get_field_from_cdr_fn)(
    const uint8_t *payload, size_t payload_len,
    const char *field, size_t field_len,
    zzdds_filter_value *out,
    uint8_t *scratch, size_t scratch_len
);

/* ctx-carrying variant of zzdds_get_field_from_cdr_fn -- see
 * zzdds_compute_key_hash_ctx_fn's doc comment below for why this exists
 * (same reasoning, same callers). */
typedef bool (*zzdds_get_field_from_cdr_ctx_fn)(
    void *ctx,
    const uint8_t *payload, size_t payload_len,
    const char *field, size_t field_len,
    zzdds_filter_value *out,
    uint8_t *scratch, size_t scratch_len
);

zzdds_DomainParticipantFactory zzdds_create_factory(void);

/**
 * Same as zzdds_create_factory, but every allocation the factory and
 * everything it ever creates makes (participants, topics, writers, readers,
 * history cache entries, ...) is routed through `allocator` instead of the
 * default libc malloc/free. Pass NULL for the default (equivalent to
 * zzdds_create_factory()).
 *
 * `allocator` must outlive the returned factory and everything created
 * through it — zzdds never copies it. See ZidlAllocator's contract in
 * zidl_allocator.h.
 */
zzdds_DomainParticipantFactory zzdds_create_factory_with_allocator(const ZidlAllocator *allocator);

bool zzdds_factory_is_nil(zzdds_DomainParticipantFactory factory);
void zzdds_destroy_factory(zzdds_DomainParticipantFactory factory);

/**
 * WaitSet and GuardCondition are the only two condition-family types with no
 * factory operation in the DCPS IDL (per the OMG spec, both are
 * app-instantiated directly -- unlike StatusCondition/ReadCondition/
 * QueryCondition, which are obtained from an existing entity/reader and
 * already have a full C-ABI path via DDS_Entity_get_statuscondition() /
 * DDS_DataReader_create_readcondition()). These four functions are the
 * hand-written bootstrap for that gap, mirroring zzdds_create_factory()/
 * zzdds_create_factory_with_allocator() exactly.
 */
DDS_WaitSet zzdds_create_waitset(void);

/**
 * Same as zzdds_create_waitset, but every allocation the WaitSet itself
 * makes is routed through `allocator` instead of the default libc
 * malloc/free. Pass NULL for the default. `allocator` must outlive the
 * returned WaitSet -- see ZidlAllocator's contract in zidl_allocator.h.
 */
DDS_WaitSet zzdds_create_waitset_with_allocator(const ZidlAllocator *allocator);

DDS_GuardCondition zzdds_create_guardcondition(void);

/**
 * Same as zzdds_create_guardcondition, but the GuardCondition itself is
 * allocated through `allocator` instead of the default libc malloc/free.
 * Pass NULL for the default. `allocator` must outlive the returned
 * GuardCondition -- see ZidlAllocator's contract in zidl_allocator.h.
 */
DDS_GuardCondition zzdds_create_guardcondition_with_allocator(const ZidlAllocator *allocator);

/**
 * Mirrors zzdds_factory_is_nil — tells a real WaitSet/GuardCondition apart
 * from the boxed nil sentinel zzdds_create_waitset[_with_allocator] returns
 * on allocation failure.
 */
bool zzdds_waitset_is_nil(DDS_WaitSet waitset);
bool zzdds_guardcondition_is_nil(DDS_GuardCondition guardcondition);

/**
 * WaitSet/GuardCondition have no owning factory to delete them through (see
 * zzdds_create_waitset's doc comment above) — mirrors zzdds_destroy_factory.
 */
void zzdds_destroy_waitset(DDS_WaitSet waitset);
void zzdds_destroy_guardcondition(DDS_GuardCondition guardcondition);

/**
 * Function pointer type for zzdds_waitset_attach_condition_with_release's
 * release_fn parameter — same shape as a listener struct's
 * release_listener_data field.
 */
typedef void (*zzdds_condition_release_fn)(void *release_ctx);

/**
 * Same as DDS_WaitSet_attach_condition, except release_fn (if non-NULL)
 * fires exactly once when THIS attachment ends — however it ends: an
 * explicit DDS_WaitSet_detach_condition() call, waitset being destroyed
 * while condition is still attached, or condition being destroyed while
 * still attached to waitset. No DCPS operation exists for this (WaitSet
 * attachment is not ownership per the spec, so there is no lifecycle event
 * to hang a release on other than this).
 *
 * A binding that wraps an attached condition in something with its own
 * lifetime tracking (e.g. a reference-counted or GC-managed handle) can use
 * this to learn when it's safe to release its own keep-alive for that
 * condition, the same way a listener's release_listener_data lets it know
 * when a listener's context is no longer needed.
 *
 * release_ctx/release_fn are ignored (as if this were a plain
 * DDS_WaitSet_attach_condition() call) if condition is already attached to
 * waitset — a second registration is never silently swapped in for the
 * first.
 *
 * out_accepted, if non-NULL, is set to whether THIS call's own
 * release_ctx/release_fn was actually stored (true) or discarded because
 * condition was already attached (false) — checked and set atomically,
 * under the same internal lock as the dedup check itself. A caller with its
 * own side bookkeeping alongside release_ctx (a JNI global ref, a C++
 * shared_ptr keepalive, ...) needs this to decide, race-free, whether to
 * keep or immediately discard that bookkeeping: a separate, out-of-band
 * "is this already attached" cache of the caller's own can never stay
 * perfectly synchronized with this function's dedup check against a
 * concurrent attach/detach for the same condition.
 */
DDS_ReturnCode_t zzdds_waitset_attach_condition_with_release(
    DDS_WaitSet waitset,
    DDS_Condition condition,
    void *release_ctx,
    zzdds_condition_release_fn release_fn,
    bool *out_accepted);

/**
 * Resolve `path` as a zzdds TOML config file and install the result as the
 * process-wide configuration, in one step -- entirely through `allocator`
 * (NULL for the default, libc malloc/free). Must be called before any
 * factory has been created in this process.
 *
 * This is the actual, C/C++-usable way to avoid zzdds_create_factory_with_allocator's
 * ambient lazy-default path resolving through libc malloc regardless of the
 * allocator you give it: call this first, with the SAME allocator you'll
 * pass to zzdds_create_factory_with_allocator, and the process-wide config's
 * own persistent storage will live in that allocator for the rest of the
 * process's lifetime instead.
 *
 * Returns DDS_RETCODE_PRECONDITION_NOT_MET if a process-wide config is
 * already installed, DDS_RETCODE_ERROR if `path` doesn't exist or fails to
 * parse.
 */
DDS_ReturnCode_t zzdds_process_configure_from_file(
    const char *path,
    const ZidlAllocator *allocator
);
DDS_DomainParticipantFactory zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(zzdds_DomainParticipantFactory factory);
zzdds_DomainParticipantFactory DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(DDS_DomainParticipantFactory factory);
DDS_DomainParticipant zzdds_DomainParticipant_as_DDS_DomainParticipant(zzdds_DomainParticipant participant);
/** NOTE: only valid for handles created by a zzdds FactoryOwner (zzdds_create_factory).
 *  Passing a handle from any other DDS implementation causes memory corruption. */
zzdds_DomainParticipant DDS_DomainParticipant_as_zzdds_DomainParticipant(DDS_DomainParticipant participant);
/** NOTE: only valid for topics owned by a zzdds FactoryOwner participant. */
zzdds_Topic DDS_Topic_as_zzdds_Topic(DDS_Topic topic);
DDS_Topic zzdds_Topic_as_DDS_Topic(zzdds_Topic topic);
DDS_DataWriter zzdds_DataWriter_as_DDS_DataWriter(zzdds_DataWriter writer);
/** NOTE: only valid for writers owned by a zzdds FactoryOwner participant. */
zzdds_DataWriter DDS_DataWriter_as_zzdds_DataWriter(DDS_DataWriter writer);
DDS_DataReader zzdds_DataReader_as_DDS_DataReader(zzdds_DataReader reader);
/** NOTE: only valid for readers owned by a zzdds FactoryOwner participant. */
zzdds_DataReader DDS_DataReader_as_zzdds_DataReader(DDS_DataReader reader);
DDS_TopicDescription zzdds_topic_as_description(DDS_Topic topic);

/**
 * @param get_field_fn  Optional (NULL if the type has no fields a
 *                       ContentFilteredTopic expression could reference).
 *                       When set, a DataReader created against a CFT for
 *                       this type filters automatically, at the reader
 *                       layer -- the app never needs to re-check samples
 *                       itself (contrast with zzdds_cft_match_sample further
 *                       down, a lower-level tool for the case where that
 *                       isn't set, or for testing a sample outside the
 *                       context of a live DataReader).
 */
int zzdds_register_type_support(
    DDS_DomainParticipant participant,
    const char *type_name,
    zzdds_compute_key_hash_fn compute_key_hash_fn,
    zzdds_get_field_from_cdr_fn get_field_fn
);

/* ctx-carrying variant of zzdds_compute_key_hash_fn/zzdds_register_type_support
 * — for bindings that can't generate a fresh, uniquely-addressed native
 * function per registered type the way zidl -b c/-b cpp do (e.g. classic JNI:
 * a Java Class<?> has no native function pointer of its own, so one shared
 * trampoline needs ctx to know which class/method to dispatch to). C/C++/Zig
 * callers don't need this — use zzdds_register_type_support above. */
typedef int (*zzdds_compute_key_hash_ctx_fn)(void *ctx, const uint8_t *payload, size_t len, uint8_t hash_out[16]);

/**
 * Same as zzdds_register_type_support, but compute_key_hash_fn/get_field_fn
 * additionally receive ctx on every call (the SAME ctx for both -- one
 * shared per-registration context, not two). ctx_deinit (may be NULL) is
 * called exactly once when this registration is replaced (a later call for
 * the same type_name) or when participant is destroyed — same reclaim path
 * as the non-ctx variant's internal adapter, just exposed to the caller's
 * own ctx here. get_field_fn is optional (NULL if the type has no
 * filterable fields), same as zzdds_register_type_support's.
 */
int zzdds_register_type_support_ctx(
    DDS_DomainParticipant participant,
    const char *type_name,
    zzdds_compute_key_hash_ctx_fn compute_key_hash_fn,
    zzdds_get_field_from_cdr_ctx_fn get_field_fn,
    void *ctx,
    void (*ctx_deinit)(void *ctx)
);

DDS_InstanceHandle_t zzdds_register_instance_raw(DDS_DataWriter writer, const uint8_t key_hash[16]);

int zzdds_get_key_value_writer(
    DDS_DataWriter writer,
    DDS_InstanceHandle_t handle,
    uint8_t *buf,
    size_t buf_size,
    size_t *len_out
);

DDS_InstanceHandle_t zzdds_lookup_instance_writer(DDS_DataWriter writer, const uint8_t key_hash[16]);

int zzdds_get_key_value_reader(
    DDS_DataReader reader,
    DDS_InstanceHandle_t handle,
    uint8_t *buf,
    size_t buf_size,
    size_t *len_out
);

DDS_InstanceHandle_t zzdds_lookup_instance_reader(DDS_DataReader reader, const uint8_t key_hash[16]);

/*
 * ContentFilteredTopic matching for a sample you already have in hand.
 *
 * If get_field_fn was registered (see zzdds_register_type_support(_ctx)
 * above), a DataReader created against a CFT already filters automatically
 * -- you don't need this. Use zzdds_cft_match_sample when get_field_fn
 * wasn't set for a type, or to test an already-deserialized sample against
 * a filter outside the context of a live DataReader (e.g. tooling/tests).
 * Uses the SAME parser/evaluator zzdds uses internally (no need to
 * reimplement the filter grammar in application code).
 */

/* Resolve a named field (e.g. "color", "x") to a zzdds_filter_value, from an
 * already-deserialized sample (contrast with zzdds_get_field_from_cdr_fn
 * above, which parses raw CDR bytes). Return false for an unknown field. */
typedef bool (*zzdds_field_get_fn)(
    void *ctx,
    const char *field,
    size_t field_len,
    zzdds_filter_value *out
);

/* Returns true if the sample passes cft's filter expression (should be
 * delivered) -- also true for a NULL/nil cft or a non-CFT handle. */
bool zzdds_cft_match_sample(
    DDS_ContentFilteredTopic cft,
    void *ctx,
    zzdds_field_get_fn get
);

#ifdef __cplusplus
}
#endif

#endif
