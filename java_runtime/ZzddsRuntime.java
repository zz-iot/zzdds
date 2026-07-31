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
     * Registers `typeClass`'s TypeSupport with zzdds under `typeName`.
     * `typeClass` must declare a `static byte[] computeKeyHashFromCdr(byte[])`
     * method (zidl generates this on every `@key` topic struct).
     *
     * Backed by `zzdds_register_type_support_ctx_c` (see `zzdds_c.h`), which
     * forwards a per-registration native context to the key-hash callback —
     * unbounded (no fixed slot count) and reclaimed automatically when this
     * registration is replaced or `participant` is destroyed.
     */
    public static native int registerTypeSupport(Object participant, String typeName, Class<?> typeClass);

    /** kind: 0 = write (alive), 1 = dispose, 2 = unregister (matches zzdds_write_kind). */
    public static native int writeRaw(Object writer, int kind, byte[] keyHash, long handle, byte[] payload);

    /**
     * Takes/reads one raw (still-encoded) sample. Returns null if none was
     * available. `handleOut`/`validOut` must be pre-allocated 1-element
     * arrays; `maxSize` bounds the receive buffer (a sample larger than this
     * is dropped — size generously for your topic).
     */
    public static native byte[] takeRaw(Object reader, int maxSize, long[] handleOut, boolean[] validOut);

    public static native byte[] readRaw(Object reader, int maxSize, long[] handleOut, boolean[] validOut);

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
