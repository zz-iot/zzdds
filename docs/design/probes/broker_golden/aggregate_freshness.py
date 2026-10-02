"""Independent draft-3 aggregate marker vectors. No generated codec imports."""
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent

def query(view, nonce):
    return struct.pack('<Q', view) + nonce

def marker(exceptions):
    # FreshnessExceptions is an XCDR2 sequence of final structs: DHEADER, count, elements.
    # XCDR2 aligns 8-byte members to 4, so elements are 40 bytes with no padding.
    elements = b''.join(guid + incarnation + struct.pack('<Q', remaining)
                        for guid, incarnation, remaining in exceptions)
    listed = struct.pack('<I', len(exceptions)) + elements
    return (struct.pack('<Q', 8) + bytes([3])*16 + struct.pack('<QQ', 27, 500000)
            + struct.pack('<I', len(listed)) + listed)

vectors = {'freshness_query_body': query(8, bytes([3])*16),
           'freshness_empty_marker_body': marker([]),
           'freshness_marker_body': marker([(bytes([4])*16, bytes([5])*16, 123456),
                                            (bytes([6])*16, bytes([7])*16, 0)])}
for name, data in vectors.items():
    path = root / (name + '.hex')
    if '--write' in sys.argv:
        path.write_text(data.hex() + '\n')
    else:
        assert path.read_text() == data.hex() + '\n', name
print(f"{'Wrote' if '--write' in sys.argv else 'Verified'} {len(vectors)} aggregate freshness vectors")
print('Body bytes: query=24; marker=48 + 40*exceptions (before Envelope/Frame)')
