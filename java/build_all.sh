#!/usr/bin/env bash
# Builds every Java example under this directory (each is its own
# build.sh/run.sh pair, matching the c/ and cpp/ examples' one-per-example
# build unit — see this repo's top-level README for why).
#
# Usage: ZZDDS_ZIG_OUT=/path/to/zzdds/zig-out ./build_all.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for example_dir in "$SCRIPT_DIR"/*/; do
    build_script="$example_dir/build.sh"
    [ -x "$build_script" ] || continue
    echo "== Building $(basename "$example_dir") =="
    "$build_script"
done
