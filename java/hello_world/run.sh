#!/usr/bin/env bash
# Runs the zzdds Java hello_world example: Subscriber and Publisher as two
# separate JVM processes, communicating over real UDP DDS discovery
# (matching how the other three bindings' two binaries work). Run build.sh
# first. Usage: ./run.sh [-d domain_id]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$SCRIPT_DIR/../zzdds/zig-out"}"
CLASSES_DIR="$SCRIPT_DIR/build/classes"

if [ ! -d "$CLASSES_DIR" ]; then
    echo "FAIL: $CLASSES_DIR not found -- run build.sh first." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

echo "Starting subscriber..."
java --enable-native-access=ALL-UNNAMED -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$CLASSES_DIR" Subscriber "$@" &
SUB_PID=$!

sleep 1

echo "Starting publisher..."
java --enable-native-access=ALL-UNNAMED -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$CLASSES_DIR" Publisher "$@"
PUB_RC=$?

wait "$SUB_PID"
SUB_RC=$?

if [ "$PUB_RC" -ne 0 ] || [ "$SUB_RC" -ne 0 ]; then
    echo "FAIL: publisher rc=$PUB_RC subscriber rc=$SUB_RC" >&2
    exit 1
fi
echo "OK: publisher and subscriber both exited successfully."
