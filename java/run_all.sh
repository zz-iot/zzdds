#!/usr/bin/env bash
# Runs every Java example under this directory (build_all.sh first). Stops
# and reports at the first example whose run.sh exits non-zero, but still
# runs every example rather than aborting the whole script early, so a CI
# log shows every failure in one pass instead of just the first.
#
# Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./run_all.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAILED=()

for example_dir in "$SCRIPT_DIR"/*/; do
    run_script="$example_dir/run.sh"
    [ -x "$run_script" ] || continue
    name="$(basename "$example_dir")"
    echo "== Running $name =="
    if ! "$run_script"; then
        FAILED+=("$name")
    fi
done

if [ "${#FAILED[@]}" -ne 0 ]; then
    echo "FAIL: ${FAILED[*]}" >&2
    exit 1
fi
echo "OK: all Java examples passed."
