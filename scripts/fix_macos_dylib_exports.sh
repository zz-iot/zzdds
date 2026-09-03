#!/bin/sh
set -eu

input=$1
output=$2
exports="${output}.exports"

# Zig 0.16 exports its Mach-O linker-synthesized ___dso_handle from dylibs.
# Apple ld then binds a C++ consumer's __cxa_atexit registration to that
# export instead of synthesizing an image-local handle, and ld-prime fails
# with "target '___dso_handle' does not have address". Keep the dylib's
# existing public interface while removing only that implementation detail
# from its export trie. `strip -R` is insufficient: it edits LC_SYMTAB but
# leaves LC_DYLD_EXPORTS_TRIE unchanged.
if ! /usr/bin/nm -gjU "$input" | /usr/bin/grep -qx '___dso_handle'; then
    /bin/cp "$input" "$output"
    exit 0
fi

/usr/bin/nm -gjU "$input" | /usr/bin/grep -vx '___dso_handle' > "$exports"
/bin/cp "$input" "$output"
/usr/bin/strip -s "$exports" -u "$output"

if /usr/bin/nm -gjU "$output" | /usr/bin/grep -qx '___dso_handle'; then
    echo "error: failed to remove ___dso_handle from $output" >&2
    exit 1
fi
