#!/usr/bin/env bash
# CI-friendly smoke test: builds video_capture/video_roi_display, then runs
# them against each other with no real camera and no display -- video_capture
# falls back to a synthetic mock frame source (OVIDDS_MOCK_CAMERA=1) and
# video_roi_display runs text-only (OVIDDS_HEADLESS=1), both bounded by
# OVIDDS_RUN_SECONDS instead of waiting on stdin/a keypress. Confirms the
# full DDS write/fragment/reassemble/read path works end to end without
# hardware, not just that the binaries compile.
#
# Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./smoke-test.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$SCRIPT_DIR/../../../zzdds/zig-out"}"
BUILD_DIR="$SCRIPT_DIR/build"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
if ! ( cd "$BUILD_DIR" && cmake -DCMAKE_PREFIX_PATH="$ZZDDS_ZIG_OUT" .. > cmake.log 2>&1 && make -j"$(nproc)" > make.log 2>&1 ); then
    echo "FAIL: build failed -- see $BUILD_DIR/{cmake,make}.log" >&2
    exit 1
fi

cd "$BUILD_DIR"
env -u DISPLAY LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" OVIDDS_HEADLESS=1 OVIDDS_RUN_SECONDS=10 \
    ./video_roi_display > sub.log 2>&1 &
SUB_PID=$!
sleep 1
env -u DISPLAY LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib" OVIDDS_MOCK_CAMERA=1 OVIDDS_RUN_SECONDS=8 \
    ./video_capture > pub.log 2>&1
PUB_RC=$?
wait "$SUB_PID"
SUB_RC=$?

FRAMES_RECEIVED="$(grep -o 'received [0-9]* frames total' sub.log | grep -o '[0-9]*' || echo 0)"

if [ "$PUB_RC" -ne 0 ] || [ "$SUB_RC" -ne 0 ] || [ "${FRAMES_RECEIVED:-0}" -eq 0 ]; then
    echo "FAIL: smoke test (pub_rc=$PUB_RC sub_rc=$SUB_RC frames_received=${FRAMES_RECEIVED:-0})" >&2
    echo "-- publisher log --" >&2; cat pub.log >&2
    echo "-- subscriber log --" >&2; cat sub.log >&2
    exit 1
fi

echo "OK: opencv_zzdds smoke test passed, $FRAMES_RECEIVED frames received headless with a mock camera."
