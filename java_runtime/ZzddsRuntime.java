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

    /**
     * Resolves {@code path} as a zzdds TOML config file and installs it as
     * the process-wide default participant config, entirely native-side —
     * the real API this binding previously lacked (see {@code shape}'s own
     * README history / {@code docs/design/shape-reference-app.md}'s MVP note
     * for the {@code ./zzdds.toml}-staging workaround this replaces). Must be
     * called before the first factory is created in this process. Mirrors
     * {@code zzdds_c.h}'s {@code zzdds_process_configure_from_file} — the
     * same function C/C++ call directly, just JNI-wrapped. Returns the
     * {@code DDS_ReturnCode_t} value as an {@code int}.
     */
    public static native int configureFromFile(String path);

    /**
     * Narrows the plain {@code io.zzdds.dcps.Dcps.DDS.DomainParticipantFactory}
     * returned by {@code createFactory()} to zzdds's own
     * {@code io.zzdds.ext.Zzdds.zzdds.DomainParticipantFactory} extension view
     * — e.g. to reach {@code create_participant_ex}/
     * {@code set_default_participant_config}/{@code get_default_participant_config}.
     * Same underlying native factory, just a different generated interface
     * view (see {@code include/zzdds_c.h}'s
     * {@code DDS_DomainParticipantFactory_as_zzdds_DomainParticipantFactory}).
     * {@code createFactory()} itself always boxes into the base
     * {@code io.zzdds.dcps.DomainParticipantFactoryImpl} view (see its own doc
     * comment in {@code zzdds_java_runtime.c}) since nothing needed the
     * extension view at bootstrap time before this; call this narrowing
     * function to get it. Returns an {@code io.zzdds.ext.DomainParticipantFactoryImpl}.
     */
    public static native Object asZzddsFactory(Object factory);
}
