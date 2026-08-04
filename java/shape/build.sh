#!/usr/bin/env bash
# Builds the zzdds Java shape example.
#
# Prerequisites:
#   - A zzdds checkout built with `zig build -Djava-binding=true install`
#     (set ZZDDS_ZIG_OUT to its zig-out/ dir; defaults to ../zzdds/zig-out).
#   - JAVA_HOME set to a full JDK (needs jni.h — a JRE isn't enough for
#     zzdds's own build, though this script itself only needs javac/java).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$SCRIPT_DIR/../zzdds/zig-out"}"
BUILD_DIR="$SCRIPT_DIR/build"
GENERATED_DIR="$BUILD_DIR/generated"
CLASSES_DIR="$BUILD_DIR/classes"

if [ ! -x "$ZZDDS_ZIG_OUT/bin/zidl" ]; then
    echo "FAIL: $ZZDDS_ZIG_OUT/bin/zidl not found." >&2
    echo "  Build zzdds first: (cd zzdds && zig build -Djava-binding=true install)" >&2
    echo "  Or point ZZDDS_ZIG_OUT at a zzdds zig-out/ directory that has one." >&2
    exit 1
fi
if [ ! -d "$ZZDDS_ZIG_OUT/java" ]; then
    echo "FAIL: $ZZDDS_ZIG_OUT/java not found — rebuild zzdds with -Djava-binding=true." >&2
    exit 1
fi

echo "Generating ShapeType TypeSupport/DataWriter/DataReader from idl/shape.idl..."
rm -rf "$GENERATED_DIR"
mkdir -p "$GENERATED_DIR"
"$ZZDDS_ZIG_OUT/bin/zidl" -b java --generate-zzdds-wrappers --java-import-package "DDS=io.zzdds.dcps" -o "$GENERATED_DIR" "$SCRIPT_DIR/idl/shape.idl"

echo "Compiling..."
rm -rf "$CLASSES_DIR"
mkdir -p "$CLASSES_DIR"
javac -d "$CLASSES_DIR" \
    "$ZZDDS_ZIG_OUT"/java/io/zzdds/dcps/*.java \
    "$ZZDDS_ZIG_OUT"/java/io/zzdds/runtime/*.java \
    "$GENERATED_DIR"/*.java \
    "$SCRIPT_DIR"/ShapeMain.java

echo "Build OK: $CLASSES_DIR"
