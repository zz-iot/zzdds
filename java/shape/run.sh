#!/usr/bin/env bash
# Runs the zzdds Java shape example: a subscriber and a publisher as two
# separate JVM processes (java ShapeMain -S / -P), communicating over real
# loopback UDP DDS discovery -- same two-process model as
# java/listener-pubsub, using shape's -P/-S single-class CLI (see
# zig/shape, c/shape, cpp/shape) instead of separate Publisher/Subscriber
# classes. Run build.sh first.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZZDDS_ZIG_OUT="${ZZDDS_ZIG_OUT:-"$SCRIPT_DIR/../zzdds/zig-out"}"
CLASSES_DIR="$SCRIPT_DIR/build/classes"

if [ ! -d "$CLASSES_DIR" ]; then
    echo "FAIL: $CLASSES_DIR not found — run build.sh first." >&2
    exit 1
fi

export LD_LIBRARY_PATH="$ZZDDS_ZIG_OUT/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

SUB_LOG="$(mktemp)"
trap 'rm -f "$SUB_LOG"' EXIT

echo "Starting subscriber..."
java --enable-native-access=ALL-UNNAMED -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$CLASSES_DIR" \
    ShapeMain -S -i 10 --read-period 200 >"$SUB_LOG" 2>&1 &
SUB_PID=$!

sleep 1

echo "Starting publisher..."
java --enable-native-access=ALL-UNNAMED -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$CLASSES_DIR" \
    ShapeMain -P -i 10 -w --write-period 200
PUB_RC=$?

wait "$SUB_PID"
SUB_RC=$?

cat "$SUB_LOG"

if [ "$PUB_RC" -ne 0 ] || [ "$SUB_RC" -ne 0 ]; then
    echo "FAIL: publisher rc=$PUB_RC subscriber rc=$SUB_RC" >&2
    exit 1
fi

# Real end-to-end proof, not just "both processes exited 0" -- at least one
# actual sample line (e.g. "Square     BLUE       123 045 [20]") must have
# reached the subscriber.
if ! grep -qE '^Square +[A-Z]+ +[0-9]{3} [0-9]{3} \[[0-9]+\]' "$SUB_LOG"; then
    echo "FAIL: subscriber never printed a received sample line" >&2
    exit 1
fi

echo "OK: publisher and subscriber exchanged samples successfully."

# ── --config smoke test ─────────────────────────────────────────────────────
#
# Java's --config is the MVP copy-trick (see ShapeMain.java's main(), and
# this port's README): copy the chosen file to ./zzdds.toml before the first
# factory is created, relying on zzdds's own ambient lazy-resolve to pick it
# up. Acceptance criterion from docs/design/shape-reference-app.md: Java's
# --config support needs at least one real test case, not just an unverified
# implementation -- this is that test. Checks the same externally observable
# effect zig/shape's README verifies: config/custom-ports.toml binds port
# 20010 instead of the default 7410.

CONFIG_FILE="$SCRIPT_DIR/../../config/custom-ports.toml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "FAIL: $CONFIG_FILE not found." >&2
    exit 1
fi

echo
echo "Config-file smoke test (custom-ports.toml -> port 20010)..."
CFG_LOG="$(mktemp)"
trap 'rm -f "$SUB_LOG" "$CFG_LOG"' EXIT

# Deliberately does NOT rm ./zzdds.toml here: ShapeMain.java's own shutdown
# hook already restores a pre-existing zzdds.toml (or removes the staged one
# if there wasn't one) when the JVM exits below. An unconditional rm here
# would delete that restored original right back out from under it -- and
# for that restore-before-we-check to actually be visible below, $CFG_PID
# must be java's own PID, not a wrapper subshell's: without `exec`, "(cd DIR
# && java ...) &" backgrounds the *subshell*, so `kill "$CFG_PID"` below
# only kills that wrapper -- java is left running as an orphan, unsignaled,
# and `wait "$CFG_PID"` returns as soon as the wrapper exits, well before
# java's shutdown hook (and its zzdds.toml restore) has actually run.
#
# cd into SCRIPT_DIR so the staged ./zzdds.toml (relative to cwd) lands next
# to this run, not wherever run.sh was invoked from.
(cd "$SCRIPT_DIR" && exec java --enable-native-access=ALL-UNNAMED -Djava.library.path="$ZZDDS_ZIG_OUT/lib" -cp "$CLASSES_DIR" \
    ShapeMain -S --config "$CONFIG_FILE" -i 10 --read-period 500 >"$CFG_LOG" 2>&1) &
CFG_PID=$!

# JVM startup + participant/reader creation can take a moment; give it a few
# tries rather than one fixed sleep racing the process's own ~5s lifetime
# (-i 10 * --read-period 500ms).
BOUND=0
for _ in 1 2 3 4 5; do
    sleep 1
    if ss -uln 2>/dev/null | grep -q ':20010\b'; then
        BOUND=1
        break
    fi
done
kill "$CFG_PID" 2>/dev/null
wait "$CFG_PID" 2>/dev/null

if [ "$BOUND" -eq 0 ]; then
    echo "FAIL: no socket bound on port 20010 -- --config's custom-ports.toml wasn't applied." >&2
    cat "$CFG_LOG" >&2
    exit 1
fi

echo "OK: --config applied custom-ports.toml -- port 20010 was bound (default is 7410)."
