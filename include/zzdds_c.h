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

/** zzdds_listener_invocation_failed's reasons. */
#define ZZDDS_LISTENER_FAILED_EXCEPTION 1 /* the listener threw */
#define ZZDDS_LISTENER_FAILED_ARGUMENTS 2 /* its arguments could not be built, so it was not called */

/**
 * For a binding's generated listener bridge, called on the callback's own
 * thread before it returns: the listener call running there failed, for
 * `reason` (ZZDDS_LISTENER_FAILED_*). The bridge still returns normally;
 * no exception crosses into zzdds. When the call ends, zzdds logs the
 * failure, at most once per interval process-wide with a count of the rest,
 * and an explicit DDS_Subscriber_notify_datareaders whose child failed stops
 * its batch there and returns DDS_RETCODE_ERROR. The failed call is not
 * retried and the listener stays installed. Returns false, doing nothing,
 * outside a listener call or for an unknown reason.
 */
bool zzdds_listener_invocation_failed(int reason);

/**
 * A WaitSet's result for a binding (zzdds_waitset_wait_leased,
 * zzdds_waitset_get_conditions_leased): for each condition, the release_ctx
 * its attachment was made with, held, so that the binding can build its own
 * result from it even if the condition is detached or deleted meanwhile.
 * An attachment's release_fn runs once the attachment has ended and every
 * result holding it has been freed, on the thread that drops the last one.
 */
typedef struct zzdds_waitset_result zzdds_waitset_result;

/**
 * DDS_WaitSet_wait, returning a result to free with zzdds_waitset_result_free.
 * *out is NULL on any code but DDS_RETCODE_OK.
 */
DDS_ReturnCode_t zzdds_waitset_wait_leased(
    DDS_WaitSet waitset,
    const DDS_Duration_t *timeout,
    zzdds_waitset_result **out);

/** DDS_WaitSet_get_conditions, returning a result as zzdds_waitset_wait_leased does. */
DDS_ReturnCode_t zzdds_waitset_get_conditions_leased(
    DDS_WaitSet waitset,
    zzdds_waitset_result **out);

uint32_t zzdds_waitset_result_length(const zzdds_waitset_result *result);

/** The condition's release_ctx, or NULL if it was attached without a release_fn. */
void *zzdds_waitset_result_release_ctx(const zzdds_waitset_result *result, uint32_t index);

/**
 * The handle of a condition attached without a release_fn, as DDS_WaitSet_wait
 * returns it; NULL for one with a release_ctx, whose binding uses that.
 */
DDS_Condition zzdds_waitset_result_condition(const zzdds_waitset_result *result, uint32_t index);

/** Releases the result's hold on each release_ctx, possibly running release_fns, and frees it. */
void zzdds_waitset_result_free(zzdds_waitset_result *result);

/**
 * Resolve `path` as a zzdds TOML config file and install the result as the
 * process-wide configuration, in one step -- entirely through `allocator`
 * (NULL for the default, libc malloc/free). Must be called before any
 * factory has been created in this process.
 *
 * This is the actual, C/C++-usable way to avoid zzdds_DomainParticipantFactory_create_with_allocator's
 * ambient lazy-default path resolving through libc malloc regardless of the
 * allocator you give it: call this first, with the SAME allocator you'll
 * pass to zzdds_DomainParticipantFactory_create_with_allocator, and the process-wide config's
 * own persistent storage will live in that allocator for the rest of the
 * process's lifetime instead.
 *
 * Its `[default_runtime]` table sets the implicit default runtime's hosted
 * workers and inline-turn budget, and `default_runtime_policy =
 * "DEFAULT_RUNTIME_DISABLED"` makes participant creation without a selected
 * runtime fail.
 *
 * Returns DDS_RETCODE_PRECONDITION_NOT_MET if a process-wide config is
 * already installed, DDS_RETCODE_BAD_PARAMETER if `[default_runtime]` asks
 * for a manual default runtime or no hosted workers, DDS_RETCODE_ERROR if
 * `path` doesn't exist or fails to parse.
 */
DDS_ReturnCode_t zzdds_process_configure_from_file(
    const char *path,
    const ZidlAllocator *allocator
);
/* The DDS_X_as_zzdds_X conversions return NULL for NULL, or for a handle
 * zzdds did not issue; zzdds_X_as_DDS_X and zzdds_topic_as_description
 * return NULL for NULL. */
DDS_DomainParticipantFactory zzdds_DomainParticipantFactory_as_DDS_DomainParticipantFactory(zzdds_DomainParticipantFactory factory);
zzdds_DomainParticipantFactory DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory(DDS_DomainParticipantFactory factory);
DDS_DomainParticipant zzdds_DomainParticipant_as_DDS_DomainParticipant(zzdds_DomainParticipant participant);
/** NOTE: only valid for handles created by a zzdds FactoryOwner (zzdds_DomainParticipantFactory_create).
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
DDS_Publisher zzdds_Publisher_as_DDS_Publisher(zzdds_Publisher publisher);
/** NOTE: only valid for publishers owned by a zzdds FactoryOwner participant.
 *  Reaches zzdds_Publisher_create_datawriter_ex. */
zzdds_Publisher DDS_Publisher_as_zzdds_Publisher(DDS_Publisher publisher);
DDS_Subscriber zzdds_Subscriber_as_DDS_Subscriber(zzdds_Subscriber subscriber);
/** NOTE: only valid for subscribers owned by a zzdds FactoryOwner participant.
 *  Reaches zzdds_Subscriber_create_datareader_ex. */
zzdds_Subscriber DDS_Subscriber_as_zzdds_Subscriber(DDS_Subscriber subscriber);
DDS_ContentFilteredTopic zzdds_ContentFilteredTopic_as_DDS_ContentFilteredTopic(zzdds_ContentFilteredTopic cft);
/** NOTE: only valid for content-filtered topics owned by a zzdds FactoryOwner
 *  participant. Reaches zzdds_ContentFilteredTopic_set_filter_expression. */
zzdds_ContentFilteredTopic DDS_ContentFilteredTopic_as_zzdds_ContentFilteredTopic(DDS_ContentFilteredTopic cft);
DDS_TopicDescription zzdds_topic_as_description(DDS_Topic topic);

/**
 * @param compute_key_hash_fn  Computes the key hash from a complete ALIVE
 *                       sample's raw CDR bytes -- generated as
 *                       `<Type>_compute_key_hash_from_cdr`. NULL for keyless
 *                       types.
 * @param compute_key_hash_key_only_fn
 *                       Computes the key hash from a genuine key-only CDR
 *                       payload (RTPS DISPOSE/UNREGISTER) -- generated as
 *                       `<Type>_compute_key_hash_from_cdr_key_only`. NULL for
 *                       keyless types, or to accept a safe zero-hash
 *                       fallback for that case (a peer that omits the inline
 *                       PID_KEY_HASH on a DISPOSE/UNREGISTER sample gets an
 *                       incomplete rather than a wrong instance handle).
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
    zzdds_compute_key_hash_fn compute_key_hash_key_only_fn,
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
 * Same as zzdds_register_type_support, but compute_key_hash_fn/
 * compute_key_hash_key_only_fn/get_field_fn additionally receive ctx on
 * every call (the SAME ctx for all three -- one shared per-registration
 * context, not several). ctx_deinit (may be NULL) is called exactly once
 * when this registration is replaced (a later call for the same type_name)
 * or when participant is destroyed — same reclaim path as the non-ctx
 * variant's internal adapter, just exposed to the caller's own ctx here.
 * compute_key_hash_key_only_fn and get_field_fn are each independently
 * optional (NULL is fine for either), same as zzdds_register_type_support's.
 */
int zzdds_register_type_support_ctx(
    DDS_DomainParticipant participant,
    const char *type_name,
    zzdds_compute_key_hash_ctx_fn compute_key_hash_fn,
    zzdds_compute_key_hash_ctx_fn compute_key_hash_key_only_fn,
    zzdds_get_field_from_cdr_ctx_fn get_field_fn,
    void *ctx,
    void (*ctx_deinit)(void *ctx)
);

/* Checked complete-sample admission, installed before creating topics. The
 * callback validates the complete ALIVE value (key_only=0) or genuine lifecycle
 * key value (key_only=1), returning 0 and publishing a hash only on success.
 * Failure is propagated before protocol/history admission even with inline QoS.
 * A valid all-zero key hash is accepted. Keyless values still require validation.
 * Processing callbacks are synchronous/reentrant and must not call DDS APIs
 * or retain payload buffers.
 * Registrations are immutable: identical callbacks/ctx are idempotent; conflicts,
 * late installs and attempts to replace with unchecked support fail.
 * These additive APIs do not strengthen the legacy registration contract. */
typedef int (*zzdds_process_sample_fn)(const uint8_t *, size_t, int key_only, uint8_t hash_out[16]);
typedef int (*zzdds_process_sample_ctx_fn)(void *, const uint8_t *, size_t, int key_only, uint8_t hash_out[16]);
int zzdds_register_type_support_checked(DDS_DomainParticipant, const char *, zzdds_process_sample_fn, int has_key, zzdds_get_field_from_cdr_fn);
/* ctx ownership transfers only on a new successful install. Equivalent repeat
 * registration with the same ctx does not transfer/release it a second time.
 * On failure the caller retains ctx. Cleanup waits for endpoint processor and field-getter pins. */
int zzdds_register_type_support_checked_ctx(DDS_DomainParticipant, const char *, zzdds_process_sample_ctx_fn, int has_key, zzdds_get_field_from_cdr_ctx_fn, void *ctx, void (*ctx_deinit)(void *));

/* register_instance: the handle of the key hash's instance, registering it if
 * it is not; 0 (DDS_HANDLE_NIL) if it cannot be. key_cdr[0..key_cdr_len], the
 * instance's key-only CDR with its encapsulation header, is its key for
 * get_key_value if it has none yet; NULL and 0 if the caller has none. */
DDS_InstanceHandle_t zzdds_register_instance_raw(DDS_DataWriter writer, const uint8_t key_hash[16], const uint8_t *key_cdr, size_t key_cdr_len);

/* A type's key projection: writes the key-only CDR of the complete sample
 * sample[0..sample_len] (both with their encapsulation header) to
 * out[0..out_size] and its size to *out_len. Returns DDS_RETCODE_OK;
 * PRECONDITION_NOT_MET when the key does not fit, with *out_len set to the
 * size needed; or any other code if it cannot project the sample. Pure: it
 * must not call DDS operations. */
typedef DDS_ReturnCode_t (*zzdds_project_key_fn)(void *ctx, const uint8_t *sample, size_t sample_len, uint8_t *out, size_t out_size, size_t *out_len);

/* Gives the type type_name, already registered on participant, a key
 * projection, so that an instance keeps the key-only CDR of its first alive
 * sample for get_key_value rather than the sample. Writers and readers created
 * afterwards use it. Returns DDS_RETCODE_OK, and ctx passes to the participant,
 * which releases it with ctx_deinit (if not NULL) as it is deleted, or at once
 * if the type already has a projection, which it keeps. BAD_PARAMETER for a
 * NULL participant or func, or an unregistered type, and OUT_OF_RESOURCES,
 * leave ctx with the caller. */
DDS_ReturnCode_t zzdds_set_key_projection(DDS_DomainParticipant participant, const char *type_name, zzdds_project_key_fn func, void *ctx, void (*ctx_deinit)(void *));

/* get_key_value's payload: the key an instance keeps, which a binding decodes
 * the key fields from. Copies it for the instance `handle` names into
 * buf[0..buf_size], sets *len_out to its size and, if key_only_out is not
 * NULL, *key_only_out to 1 for key-only CDR (the form a dispose carries) or 0
 * for a complete sample. An instance has a key once it is registered with
 * one, written, disposed or unregistered. Returns DDS_RETCODE_OK;
 * BAD_PARAMETER for a NULL writer or len_out, a NULL buf with a nonzero
 * buf_size, or a handle that names no instance of the writer with a key;
 * ALREADY_DELETED; NOT_ENABLED until the writer is enabled; or
 * PRECONDITION_NOT_MET when the payload is larger than buf_size, with
 * *len_out still set: pass buf NULL and buf_size 0 to learn the size. */
DDS_ReturnCode_t zzdds_get_key_value_writer(
    DDS_DataWriter writer,
    DDS_InstanceHandle_t handle,
    uint8_t *buf,
    size_t buf_size,
    size_t *len_out,
    int *key_only_out
);

DDS_InstanceHandle_t zzdds_lookup_instance_writer(DDS_DataWriter writer, const uint8_t key_hash[16]);

/* As zzdds_get_key_value_writer, for a reader's instance, which has a key once
 * a sample, a dispose or an unregister of it has arrived. */
DDS_ReturnCode_t zzdds_get_key_value_reader(
    DDS_DataReader reader,
    DDS_InstanceHandle_t handle,
    uint8_t *buf,
    size_t buf_size,
    size_t *len_out,
    int *key_only_out
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
