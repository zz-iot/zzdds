"""Independent positional encodings for draft-3 final transaction/resume types."""
from pathlib import Path
import struct
import sys
root = Path(__file__).resolve().parent
def error_body(present):
 data = bytearray(struct.pack('<HH', 1, 2) + bytes([3])*16)
 def align4():
  data.extend(bytes((-len(data)) % 4))
 data.append(int(present))
 if present:
  data.extend(bytes([4])*16 + bytes([5])*16)
  data.extend(bytes((-len(data)) % 2))
  data.extend(struct.pack('<H', 1) + bytes([6])*16)
 for value in (7, 8):
  data.append(int(present))
  if present:
   align4()
   data.extend(struct.pack('<Q', value))
 return bytes(data)

vectors = {
 'final_error_absent': error_body(False),
 'final_error_present': error_body(True),
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
