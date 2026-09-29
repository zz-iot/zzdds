"""Independent draft-3 aggregate marker vectors. No generated codec imports."""
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent

def query(view, nonce):
    return struct.pack('<Q', view) + nonce

def marker(exceptions):
    result = struct.pack('<Q', 8) + bytes([3])*16 + struct.pack('<QQI', 27, 500000, len(exceptions))
    for guid, incarnation, remaining in exceptions:
        result += guid + incarnation + struct.pack('<Q', remaining)
    return result

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
print('Body bytes: query=24; marker=44 + 40*exceptions (before Envelope/Frame)')
