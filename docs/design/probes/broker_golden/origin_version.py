"""Independent origin-version wire vectors; structural PL fixtures, not full SPDP."""
from pathlib import Path
import struct
import sys

PID = 0x8003  # Provisional zzdds assignment, not a production advertisement.
root = Path(__file__).resolve().parent
vectors = {}
for endian, suffix, encap in [('<', 'le', b'\x00\x03\x00\x00'), ('>', 'be', b'\x00\x02\x00\x00')]:
    def param(pid, value):
        return struct.pack(endian + 'HH', pid, len(value)) + value
    sentinel = struct.pack(endian + 'HH', 1, 0)
    value = bytes(range(1, 17)) + struct.pack(endian + 'Q', 0x0102030405060708)
    key = param(0x005A, bytes(range(16)))
    vectors[f'origin_version_value_{suffix}.hex'] = value
    vectors[f'origin_version_full_{suffix}.hex'] = encap + key + param(PID, value) + sentinel
    vectors[f'origin_version_key_{suffix}.hex'] = encap + key + sentinel
    vectors[f'origin_version_inline_{suffix}.hex'] = param(0x0071, b'\x00\x00\x00\x01') + param(PID, value) + sentinel
for name, value in vectors.items():
    target = root / name
    content = value.hex() + '\n'
    if '--write' in sys.argv:
        target.write_text(content)
    else:
        assert target.read_text() == content, name
print(f"{'Wrote' if '--write' in sys.argv else 'Verified'} {len(vectors)} origin-version vectors")
