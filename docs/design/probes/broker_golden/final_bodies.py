"""Independent positional encodings for draft-3 final transaction/resume types."""
from pathlib import Path
import struct
import sys
root = Path(__file__).resolve().parent
vectors = {
 'final_inventory_end': struct.pack('<QQ', 3, 2),
 'final_snapshot_end': struct.pack('<QQQQ', 4, 12, 2, 27),
 'final_applied': struct.pack('<QQQ', 4, 12, 27),
 'final_resume_cursor': bytes([1])*16 + bytes([2])*16 + struct.pack('<QQQQB', 3, 4, 12, 27, 1),
}
for name, data in vectors.items():
 path = root / (name + '.hex')
 if '--write' in sys.argv: path.write_text(data.hex()+'\n')
 else: assert path.read_text() == data.hex()+'\n', name
print(f"{'Wrote' if '--write' in sys.argv else 'Verified'} {len(vectors)} final transaction/resume vectors")
