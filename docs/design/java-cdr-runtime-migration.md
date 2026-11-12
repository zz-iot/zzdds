# Java CDR runtime SDK migration

Java-enabled builds package the pure Java CDR runtime from the same zidl source
as the generator and native bindings. When present, it is installed as
`share/java/zidl-cdr-java.jar`; its embedded metadata retains the zidl version
and runtime API level. This JAR contains serialization helpers, not JNI code.
The existing zzdds JNI library still provides DDS operations.

The SDK pins zidl `v0.3.30-zig.0.17.0`, which includes the shared Java runtime
API 2. Generator, native binding support, and Java runtime come from that tagged
source archive. Older zidl sources remain supported: they generate inline
codecs and install no runtime JAR. Development builds can replace all zidl
components together with `-Dzidl-source=/path/to/zidl`.

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
jobs, as required by the workflow's maintenance instructions. The dry run must
use the release pin to exercise shared-runtime delivery on all release platforms.

Local validation with runtime API 2 covered normal and shared-native binding
smoke/install builds (50 steps each), all ten Java example and nine integration
application builds, the relocated hello_world consumer with a Java/Python-only PATH, raw-loan, and shared-native
presence. The previous release pin passed its 48-step smoke/install build.
The 0.3.30 pin passed all 50 smoke/install steps without a source override;
the installed JAR reports version 0.3.30 and runtime API level 2.
The common harness has 19 passing tests, including platform classpath separators,
paths containing spaces, explicit overrides, and ambiguous/missing JAR handling.
