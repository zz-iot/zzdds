#!/usr/bin/env bash
# Top-level orchestrator: builds/runs every example and smoke test in this
# repo against a single zzdds zig-out. By default, whatever that zig-out
# wasn't built to support (a missing binding, missing OpenCV) is SKIPPED,
# not failed -- e.g. a c-binding-only zzdds build just skips the cpp/java/
# interop sections. This is the end-user-friendly default: point this at
# whatever you happened to build and see what actually works.
#
# Pass --strict to turn every skip into a hard failure instead. That's what
# zzdds's own CI should use: if a change to zzdds's build flags accidentally
# drops a binding these examples need, --strict makes that a red CI run
# instead of a quietly-shrinking test surface.
#
# Real failures (something was available and the build/run actually failed)
# are always failures, in both modes -- --strict only changes how a missing
# prerequisite is treated.
#
# Usage:
#   ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run-all.sh [--strict]
#
# See ZZDDS_VERSION for the zzdds commit these examples are known to work
# against, if you need a baseline rather than testing your own local build.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$SCRIPT_DIR/../zzdds/zig-out"}"

STRICT=0
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) echo "Unknown argument: $arg (only --strict is supported)" >&2; exit 2 ;;
    esac
done

if [ ! -d "$ZZDDS_ZIG_OUT" ]; then
    echo "FAIL: ZZDDS_ZIG_OUT ($ZZDDS_ZIG_OUT) does not exist." >&2
    exit 1
fi

PASSED=()
SKIPPED=()
FAILED=()

# skip_or_fail <name> <reason> -- for a missing prerequisite specifically.
skip_or_fail() {
    local name="$1" reason="$2"
    if [ "$STRICT" -eq 1 ]; then
        echo "FAIL (strict, missing prerequisite): $name -- $reason" >&2
        FAILED+=("$name")
    else
        echo "SKIP: $name -- $reason"
        SKIPPED+=("$name")
    fi
}

# run_section <name> <command...> -- for something that was actually attempted.
run_section() {
    local name="$1"; shift
    echo "== $name =="
    if "$@"; then
        echo "OK: $name"
        PASSED+=("$name")
    else
        echo "FAIL: $name" >&2
        FAILED+=("$name")
    fi
    echo
}

# ── Detect what this zig-out actually supports ────────────────────────────
# Mirrors zzdds/build.zig exactly: -Dc-binding installs include/zzdds_c.h;
# -Dcpp-binding additionally installs src/dcps_impl.cpp; -Djava-binding
# installs java/ and (like every binding) needs the shared bin/zidl.

C_BINDING=0
[ -f "$ZZDDS_ZIG_OUT/include/zzdds_c.h" ] && C_BINDING=1

CPP_BINDING=0
[ -f "$ZZDDS_ZIG_OUT/src/dcps_impl.cpp" ] && CPP_BINDING=1

JAVA_BINDING=0
[ -d "$ZZDDS_ZIG_OUT/java" ] && [ -x "$ZZDDS_ZIG_OUT/bin/zidl" ] && JAVA_BINDING=1

has_opencv() {
    pkg-config --exists opencv4 2>/dev/null && return 0
    for inc in /usr/include/opencv4 /usr/local/include/opencv4 /usr/include /usr/local/include; do
        [ -f "$inc/opencv2/core.hpp" ] && return 0
    done
    return 1
}
OPENCV=0
has_opencv && OPENCV=1

echo "ZZDDS_ZIG_OUT=$ZZDDS_ZIG_OUT"
echo "Detected: c-binding=$C_BINDING cpp-binding=$CPP_BINDING java-binding=$JAVA_BINDING opencv=$OPENCV"
[ "$STRICT" -eq 1 ] && echo "Mode: --strict (missing prerequisites are failures)"
echo

# ── C ──────────────────────────────────────────────────────────────────────
if [ "$C_BINDING" -eq 1 ]; then
    run_section "c" bash -c '
        set -e
        rm -rf "'"$SCRIPT_DIR"'/c/build"
        cmake -DCMAKE_PREFIX_PATH="'"$ZZDDS_ZIG_OUT"'" -B "'"$SCRIPT_DIR"'/c/build" -S "'"$SCRIPT_DIR"'/c"
        cmake --build "'"$SCRIPT_DIR"'/c/build"
    '
else
    skip_or_fail "c" "zzdds not built with -Dc-binding=true (missing include/zzdds_c.h)"
fi

# ── C++ ────────────────────────────────────────────────────────────────────
if [ "$CPP_BINDING" -eq 1 ]; then
    run_section "cpp" bash -c '
        set -e
        rm -rf "'"$SCRIPT_DIR"'/cpp/build"
        cmake -DCMAKE_PREFIX_PATH="'"$ZZDDS_ZIG_OUT"'" -B "'"$SCRIPT_DIR"'/cpp/build" -S "'"$SCRIPT_DIR"'/cpp"
        cmake --build "'"$SCRIPT_DIR"'/cpp/build"
    '
else
    skip_or_fail "cpp" "zzdds not built with -Dcpp-binding=true (missing src/dcps_impl.cpp)"
fi

# ── Java ───────────────────────────────────────────────────────────────────
if [ "$JAVA_BINDING" -eq 1 ]; then
    run_section "java" bash -c '
        set -e
        cd "'"$SCRIPT_DIR"'/java"
        ZZDDS_ZIG_OUT="'"$ZZDDS_ZIG_OUT"'" ./build_all.sh
        ZZDDS_ZIG_OUT="'"$ZZDDS_ZIG_OUT"'" ./run_all.sh
    '
else
    skip_or_fail "java" "zzdds not built with -Djava-binding=true (missing java/ or bin/zidl)"
fi

# ── Cross-binding interop (needs both c and cpp) ──────────────────────────
if [ "$C_BINDING" -eq 1 ] && [ "$CPP_BINDING" -eq 1 ]; then
    run_section "interop/cross-binding" env ZZDDS_ZIG_OUT="$ZZDDS_ZIG_OUT" \
        "$SCRIPT_DIR/interop/cross-binding-smoke-test.sh"
else
    skip_or_fail "interop/cross-binding" "needs both c-binding and cpp-binding"
fi

# ── Shape cross-binding interop (needs c, cpp, and java; zig is native) ───
if [ "$C_BINDING" -eq 1 ] && [ "$CPP_BINDING" -eq 1 ] && [ "$JAVA_BINDING" -eq 1 ]; then
    run_section "interop/shape-cross-binding" env ZZDDS_ZIG_OUT="$ZZDDS_ZIG_OUT" \
        "$SCRIPT_DIR/interop/shape-cross-binding-smoke-test.sh"
else
    skip_or_fail "interop/shape-cross-binding" "needs c-binding, cpp-binding, and java-binding"
fi

# ── opencv_zzdds (needs cpp-binding and OpenCV) ────────────────────────────
if [ "$CPP_BINDING" -eq 1 ] && [ "$OPENCV" -eq 1 ]; then
    run_section "cpp/opencv_zzdds" env ZZDDS_ZIG_OUT="$ZZDDS_ZIG_OUT" \
        "$SCRIPT_DIR/cpp/opencv_zzdds/smoke-test.sh"
elif [ "$CPP_BINDING" -eq 1 ]; then
    skip_or_fail "cpp/opencv_zzdds" "OpenCV not found (install libopencv-dev)"
else
    skip_or_fail "cpp/opencv_zzdds" "needs cpp-binding"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo "======================================"
echo "Passed:  ${PASSED[*]:-(none)}"
echo "Skipped: ${SKIPPED[*]:-(none)}"
echo "Failed:  ${FAILED[*]:-(none)}"

if [ "${#FAILED[@]}" -ne 0 ]; then
    echo "RESULT: FAIL"
    exit 1
fi
echo "RESULT: OK"
