package io.zzdds.runtime;

/**
 * Hand-written native runtime backing zidl's `--generate-zzdds-wrappers`
 * Java output (`<Topic>TypeSupport`/`<Topic>DataWriter`/`<Topic>DataReader`).
 *
 * Unlike C/C++, Java's CDR is inlined into each generated type (no companion
 * runtime library — see zzdds/docs/language-bindings.md), so the generated
 * wrapper classes only need a small, fixed, non-generated native surface to
 * cross into zzdds: register a type, write raw bytes, take/read raw bytes,
 * and bootstrap the very first DomainParticipantFactory handle (which has no
 * IDL-level "get me the singleton" operation — see zzdds's C/C++ examples,
 * which bootstrap via `zzdds_create_factory()` the same way).
 *
 * Implemented by java_runtime/zzdds_java_runtime.c, built into
 * libzzdds_jni.so alongside the zidl-generated entity JNI bridge
 * (dcps_jni.c) — see zzdds/build.zig's `-Djava-binding=true` section.
 */
public final class ZzddsRuntime {
    private ZzddsRuntime() {}

    static { System.loadLibrary("zzdds_jni"); }

    /** Bootstraps the process-wide DomainParticipantFactory (a DDS_DomainParticipantFactory,
     * boxed the same way every other entity handle is). Returns null on failure. */
    public static native Object createFactory();

    /**
     * WaitSet and GuardCondition have no factory operation in dcps.idl (per OMG spec, both
     * are app-instantiated directly, not obtained from an existing entity/reader) — like
     * createFactory() above, these bootstrap through a hand-written zzdds_create_waitset()/
     * zzdds_create_guardcondition() call (see zzdds_c.h), the same way the C/C++ examples
     * do. Returns null on failure. Since neither has a factory delete operation either,
     * destroyWaitSet()/destroyGuardCondition() are the only way to release one — call
     * exactly once, after detaching from every WaitSet (for a GuardCondition) or after
     * detaching/deleting every attached condition (for a WaitSet).
     */
    public static native Object createWaitSet();
    public static native Object createGuardCondition();
    public static native void destroyWaitSet(Object waitset);
    public static native void destroyGuardCondition(Object guardcondition);

    /**
     * Registers `typeClass`'s TypeSupport with zzdds under `typeName`.
     * `typeClass` must declare a `static byte[] computeKeyHashFromCdr(byte[])`
     * method (zidl generates this on every topic struct, keyed or keyless).
     *
     * `typeClass` may additionally declare a
     * `static Object getFieldFromCdr(byte[] payload, String field)` method
     * (zidl generates this on every topic struct too) — when present, a
     * `DataReader` created against a `ContentFilteredTopic` for this type
     * filters automatically, at the reader layer, with no app-side
     * re-checking. Returns `null` for an unknown field, a boxed
     * `Long`/`Double` for an int-like/float-like field, or a `String` for a
     * string-like one. Optional: a `typeClass` without one still registers
     * fine, it just gets no automatic CFT filtering (every sample passes
     * through unfiltered, the same as any other binding's TypeSupport with
     * a NULL get_field callback).
     *
     * Backed by `zzdds_register_type_support_ctx` (see `zzdds_c.h`), which
     * forwards a per-registration native context to both callbacks —
     * unbounded (no fixed slot count) and reclaimed automatically when this
     * registration is replaced or `participant` is destroyed.
     */
    public static native int registerTypeSupport(Object participant, String typeName, Class<?> typeClass);

    /** kind: 0 = write (alive), 1 = dispose, 2 = unregister (matches zzdds_write_kind). */
    public static native int writeRaw(Object writer, int kind, byte[] keyHash, long handle, byte[] payload);

    /** Same as {@link #writeRaw}, plus an explicit source timestamp
     * (DDS_Time_t's sec/nanosec fields, passed separately since JNI can't
     * marshal a C struct by value). */
    public static native int writeRawWTimestamp(Object writer, int kind, byte[] keyHash, long handle, byte[] payload, int sec, int nanosec);

    /** Computes the deterministic instance handle for `keyHash` -- the raw
     * path to `register_instance`. zzdds's own instance registration has no
     * side effects beyond this computation (see zzdds_register_instance_raw). */
    public static native long registerInstanceRaw(Object writer, byte[] keyHash);

    /** Returns the stored key-only CDR payload for `handle`, or null if no
     * alive write has been made for that instance -- the raw path to the
     * writer-side `get_key_value`. */
    public static native byte[] getKeyValueWriterRaw(Object writer, long handle);

    /** Looks up the instance handle for `keyHash` -- the raw path to the
     * writer-side `lookup_instance`. Returns `DDS_HANDLE_NIL` (0) if no
     * alive write has been made for that key. */
    public static native long lookupInstanceWriterRaw(Object writer, byte[] keyHash);

    /**
     * Takes/reads one raw (still-encoded) sample. Returns null if none was
     * available. `handleOut`/`validOut`/`stateOut` must be pre-allocated
     * 1-element arrays; `maxSize` bounds the receive buffer (a sample larger
     * than this is dropped — size generously for your topic). `stateOut[0]`
     * is the sample's raw `SampleInfo.instance_state` bitmask value
     * (`Dcps.DDS.ALIVE_INSTANCE_STATE`/`NOT_ALIVE_DISPOSED_INSTANCE_STATE`/
     * `NOT_ALIVE_NO_WRITERS_INSTANCE_STATE`).
     */
    public static native byte[] takeRaw(Object reader, int maxSize, long[] handleOut, boolean[] validOut, int[] stateOut);

    public static native byte[] readRaw(Object reader, int maxSize, long[] handleOut, boolean[] validOut, int[] stateOut);

    /**
     * Takes/reads the next sample of the instance identified by `prev`
     * (`DDS_HANDLE_NIL`/`0` to start at the first instance), draining that
     * instance before moving to the next — same semantics as C/C++'s
     * `take_next_instance`/`read_next_instance`. Returns null if none was
     * available. `handleOut`/`validOut`/`stateOut` must be pre-allocated
     * 1-element arrays; `maxSize` bounds the receive buffer, same as
     * {@link #takeRaw}.
     */
    public static native byte[] takeNextInstanceRaw(Object reader, long prev, int maxSize, long[] handleOut, boolean[] validOut, int[] stateOut);

    public static native byte[] readNextInstanceRaw(Object reader, long prev, int maxSize, long[] handleOut, boolean[] validOut, int[] stateOut);

    /**
     * Batch take/read of up to `max` samples matching the given sample/view/
     * instance state masks (e.g. {@code Dcps.DDS.ANY_SAMPLE_STATE.value}) —
     * same semantics as C/C++'s `take_n`/`read_n`. `max` must be positive
     * (unlike the underlying C ABI, which also accepts <= 0 for "everything
     * currently available" — not exposed here, since `handlesOut`/
     * `validsOut` must be sized by the caller *before* the call, which is
     * only possible when `max` is a known, fixed bound).
     *
     * Returns a {@code byte[][]} of `N <= max` raw payloads (`N` is the true
     * count — may be less than `max` if fewer samples were available).
     * `handlesOut`/`validsOut` must be pre-allocated to length `max`; only
     * their first `N` entries are meaningful, parallel to the returned
     * array. Unlike {@link #takeRaw}, there is no per-sample buffer-size
     * bound to pass: each sample's buffer is allocated by zzdds core,
     * sized exactly to that sample's real length.
     */
    public static native byte[][] takeNRaw(Object reader, int max, int sampleStates, int viewStates, int instanceStates, long[] handlesOut, boolean[] validsOut);

    public static native byte[][] readNRaw(Object reader, int max, int sampleStates, int viewStates, int instanceStates, long[] handlesOut, boolean[] validsOut);

    /**
     * Batch take/read restricted to one instance -- the raw path to
     * `take_instance`/`read_instance`. Same masks/`handlesOut`/`validsOut`/
     * return shape as {@link #takeNRaw}, scoped to `instanceHandle` (a real
     * instance handle, not `DDS_HANDLE_NIL` -- there is no "no filter"
     * sentinel here, unlike {@link #takeNRaw}).
     */
    public static native byte[][] takeNInstanceRaw(Object reader, long instanceHandle, int max, int sampleStates, int viewStates, int instanceStates, long[] handlesOut, boolean[] validsOut);

    public static native byte[][] readNInstanceRaw(Object reader, long instanceHandle, int max, int sampleStates, int viewStates, int instanceStates, long[] handlesOut, boolean[] validsOut);

    /**
     * Batch take/read restricted to a `ReadCondition` (or a `QueryCondition`
     * upcast via its own generated `as_ReadCondition()`) -- the raw path to
     * `take_w_condition`/`read_w_condition`. State masks (and, for a
     * QueryCondition, the query filter) come from `condition` itself. Same
     * `handlesOut`/`validsOut`/return shape as {@link #takeNRaw}.
     */
    public static native byte[][] takeWConditionRaw(Object reader, Object condition, int max, long[] handlesOut, boolean[] validsOut);

    public static native byte[][] readWConditionRaw(Object reader, Object condition, int max, long[] handlesOut, boolean[] validsOut);

    /**
     * Batch take/read restricted to a `ReadCondition` AND scoped to the
     * "next instance" after `prev` -- the raw path to
     * `take_next_instance_w_condition`/`read_next_instance_w_condition`. Per
     * spec, instance *selection* itself is restricted to instances with a
     * matching sample, not just the next instance with any sample at all.
     */
    public static native byte[][] takeNextInstanceWConditionRaw(Object reader, Object condition, long prev, int max, long[] handlesOut, boolean[] validsOut);

    public static native byte[][] readNextInstanceWConditionRaw(Object reader, Object condition, long prev, int max, long[] handlesOut, boolean[] validsOut);

    /** Returns the stored CDR payload for `handle`, or null if no alive
     * sample has arrived for that instance -- the raw path to the
     * reader-side `get_key_value`. */
    public static native byte[] getKeyValueReaderRaw(Object reader, long handle);

    /** Looks up the instance handle for `keyHash` -- the raw path to the
     * reader-side `lookup_instance`. Returns `DDS_HANDLE_NIL` (0) if no
     * alive sample has arrived for that key. */
    public static native long lookupInstanceReaderRaw(Object reader, byte[] keyHash);

    /** Resolves a named field (e.g. "color", "x") on whatever sample the
     * caller currently has in hand, for {@link #cftMatchSample}. Return a
     * {@code String} or a boxed {@code Long}; {@code null} for an unknown
     * field (matches zzdds's own FieldAccessor.get returning null). */
    public interface FieldAccessor {
        Object get(String field);
    }

    /**
     * Evaluates {@code cft}'s filter expression against one sample via
     * {@code accessor}, using zzdds's own filter parser/evaluator.
     *
     * If the type's {@code getFieldFromCdr} static method is present (see
     * {@link #registerTypeSupport}), a {@code DataReader} created against a
     * {@code ContentFilteredTopic} already filters automatically at the
     * reader layer -- you don't need this. Use {@code cftMatchSample} when
     * a type has no {@code getFieldFromCdr} (e.g. a hand-written
     * TypeSupport class predating that contract), or to test an
     * already-deserialized sample against a filter outside the context of a
     * live {@code DataReader} (e.g. tooling/tests) -- mirrors {@code
     * zzdds_c.h}'s {@code zzdds_cft_match_sample}, the same fallback/
     * lower-level role for C/C++.
     *
     * Returns true if the sample passes the filter (should be delivered) --
     * also true for a null {@code cft} (no filter active).
     */
    public static native boolean cftMatchSample(Object cft, FieldAccessor accessor);

    /**
     * Narrows a plain {@code io.zzdds.dcps.Dcps.DDS.DataWriter} (as returned
     * by {@code Publisher.create_datawriter}) to zzdds's own
     * {@code io.zzdds.ext.Zzdds.zzdds.DataWriter} extension view — e.g. to
     * reach {@code set_listener_ex}/{@code on_reliable_reader_ready}. Same
     * underlying native entity, just a different generated interface view
     * (see {@code include/zzdds_c.h}'s {@code DDS_DataWriter_as_zzdds_DataWriter}).
     * Only valid for writers created through a zzdds
     * {@code DomainParticipantFactory} (true for every writer this binding
     * can produce). Returns an {@code io.zzdds.ext.DataWriterImpl}.
     */
    public static native Object asZzddsDataWriter(Object writer);
}
