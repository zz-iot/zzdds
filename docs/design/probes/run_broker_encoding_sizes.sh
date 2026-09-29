#!/usr/bin/env bash
set -euo pipefail
probe_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
zzdds_root=$(cd -- "$probe_dir/../../.." && pwd)
zidl_root=${ZIDL_ROOT:-"$zzdds_root/../zidl"}
: "${ZIDL_EXE:?Set ZIDL_EXE}"
: "${ZIG_EXE:?Set ZIG_EXE}"
probe_output=$(mktemp -d /tmp/zzdds-encoding-sizes.XXXXXX)
for shape in mutable appendable final; do
    mkdir "$probe_output/$shape"
    python3 - "$probe_dir/../schema/broker-control-draft.idl" "$probe_output/$shape/compare.idl" "$shape" <<'PY'
from pathlib import Path
import sys
import re
source, output, shape = sys.argv[1:]
names = 'ViewSync|InventoryBegin|ViewEnd|FreshnessQuery|FreshnessMarker|Envelope'
text = re.sub(r'@(mutable|appendable|final)(\s+struct\s+(?:'+names+r')\b)', lambda m: '@'+shape+m[2], Path(source).read_text())
Path(output).write_text(text)
PY
    "$ZIDL_EXE" -b zig --no-typeobject-support -o "$probe_output/$shape" "$probe_output/$shape/compare.idl"
    printf '%s\n' "$shape"
    "$ZIG_EXE" test --cache-dir "$probe_output/$shape/cache" --global-cache-dir /tmp/zidl-probe-global \
      --dep wire --dep zidl_rt -Mroot="$probe_dir/broker_encoding_sizes.zig" \
      --dep zidl_rt -Mwire="$probe_output/$shape/compare.zig" \
      -Mzidl_rt="$zidl_root/packages/zidl-rt/src/root.zig"
done
printf 'Comparison artifacts: %s\n' "$probe_output"
