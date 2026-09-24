#!/usr/bin/env bash
set -euo pipefail
probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
zzdds_root=$(cd -- "$probe_dir/../../.." && pwd)
zidl_root=${ZIDL_ROOT:-"$zzdds_root/../zidl"}
: "${ZIDL_EXE:?Set ZIDL_EXE to a built zidl executable}"
: "${ZIG_EXE:?Set ZIG_EXE to the Zig executable}"
probe_output=$(mktemp -d /tmp/zzdds-broker-wire.XXXXXX)
"$ZIDL_EXE" -b zig --no-typeobject-support -o "$probe_output" "$probe_dir/../schema/broker-control-draft.idl"
"$ZIG_EXE" test --cache-dir "$probe_output/cache" \
  --global-cache-dir "${ZIG_GLOBAL_CACHE_DIR:-/tmp/zidl-probe-global}" \
  --dep wire --dep zidl_rt -Mroot="$probe_dir/broker_wire_codec.zig" \
  --dep zidl_rt -Mwire="$probe_output/broker-control-draft.zig" \
  -Mzidl_rt="$zidl_root/packages/zidl-rt/src/root.zig"
printf 'Generated artifact: %s\n' "$probe_output"
