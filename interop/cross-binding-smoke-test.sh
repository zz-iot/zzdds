#!/usr/bin/env bash
# Cross-binding interoperability smoke test: builds c/custom-allocator and
# cpp/custom-allocator, then runs each one's publisher against the OTHER
# binding's subscriber (and vice versa) over real UDP DDS discovery. Both
# examples compile the same idl/sensor.idl to the same wire (CDR) layout and
# use the same domain ID (7) by construction -- this test is what actually
# proves that in both directions, rather than each binding only ever being
# exercised against itself.
#
# Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./cross-binding-smoke-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$REPO_ROOT/../zzdds/zig-out"}"

C_DIR="$REPO_ROOT/c/custom-allocator"
CPP_DIR="$REPO_ROOT/cpp/custom-allocator"

build_one() {
    local dir="$1"
    local build_dir="$dir/build"
    echo "== Building ${dir#"$REPO_ROOT/"} =="
    rm -rf "$build_dir"
    mkdir -p "$build_dir"
    if ! ( cd "$build_dir" && cmake -DCMAKE_PREFIX_PATH="$ZZDDS_ZIG_OUT" .. > cmake.log 2>&1 && make -j"$(nproc)" > make.log 2>&1 ); then
        echo "FAIL: build failed for $dir -- see $build_dir/{cmake,make}.log" >&2
        exit 1
    fi
}

run_pair() {
    local pub_dir="$1" sub_dir="$2" label="$3"
    echo "== $label =="
    ( cd "$sub_dir/build" && LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" ./subscriber > sub.log 2>&1 ) &
    local sub_pid=$!
    sleep 1
    ( cd "$pub_dir/build" && LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" ./publisher > pub.log 2>&1 )
    local pub_rc=$?
    wait "$sub_pid"
    local sub_rc=$?
    if [ "$pub_rc" -ne 0 ] || [ "$sub_rc" -ne 0 ]; then
        echo "FAIL: $label (pub_rc=$pub_rc sub_rc=$sub_rc)" >&2
        echo "-- publisher log --" >&2; cat "$pub_dir/build/pub.log" >&2
        echo "-- subscriber log --" >&2; cat "$sub_dir/build/sub.log" >&2
        return 1
    fi
    echo "OK: $label"
}

build_one "$C_DIR"
build_one "$CPP_DIR"

FAILED=0
run_pair "$C_DIR" "$CPP_DIR" "C publisher -> C++ subscriber" || FAILED=1
run_pair "$CPP_DIR" "$C_DIR" "C++ publisher -> C subscriber" || FAILED=1

if [ "$FAILED" -ne 0 ]; then
    echo "FAIL: cross-binding smoke test" >&2
    exit 1
fi
echo "OK: C and C++ custom-allocator examples interoperate in both directions."
