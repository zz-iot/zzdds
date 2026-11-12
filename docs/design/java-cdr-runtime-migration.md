# Java CDR runtime SDK migration

Java-enabled builds package the pure Java CDR runtime from the same zidl source
as the generator and native bindings. When present, it is installed as
`share/java/zidl-cdr-java.jar`; its embedded metadata retains the zidl version
and runtime API level. This JAR contains serialization helpers, not JNI code.
The existing zzdds JNI library still provides DDS operations.

The current zidl release pin predates the shared Java runtime. Such builds keep
using inline codecs and install no runtime JAR. To validate the new generator
and runtime together, build with `-Djava-binding=true -Dzidl-source=/path/to/zidl`.
After the zidl helper changes are merged and released, update the release pin;
this staging change deliberately does not substitute an unreleased commit.

The shared example harness adds the SDK JAR to both javac and JVM classpaths.
`ZIDL_CDR_JAR` can select an explicit JAR; otherwise multiple matching SDK JARs
are rejected. All Java example and integration builders compile the complete
SDK source tree, including implementation classes loaded by JNI.

Java binding smoke tests use the built JAR directly. Release bundles include
Java sources, the JNI library, and the JAR when required by their generator.
`verify_release_bundle.py --with-java` compiles and runs Java hello_world using
the relocated bundle. Applications need a JDK and the bundled generator, with
no Zig or C compiler required for Java consumers.

Before merging release-workflow changes, run the Release workflow with
`dry_run` on the branch and check test, self-interop, and all four package-libs
jobs, as required by the workflow's maintenance instructions. A dry run using
the old pin covers packaging compatibility; repeat it after advancing the pin
to exercise shared-runtime delivery on all release platforms.

Local validation with runtime API 2 covered normal and shared-native binding
smoke/install builds (50 steps each), all ten Java example and nine integration application builds, the relocated
hello_world consumer with a Java/Python-only PATH, raw-loan, and shared-native
presence. The unchanged release pin passed its 48-step smoke/install build.
The common harness has 19 passing tests, including platform classpath separators,
paths containing spaces, explicit overrides, and ambiguous/missing JAR handling.
