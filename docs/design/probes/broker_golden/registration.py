"""Independent XCDR2 registration/reply vectors; structural, not admission validation."""
import hashlib
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent

def h(label, *blobs):
    return hashlib.sha256(label.encode() + b'\0' + b''.join(struct.pack('<Q', len(b)) + b for b in blobs)).digest()

def mutable(fields):
    out = bytearray()
    for ident, fmt, value in fields:
        out += bytes((-len(out)) % 4)
        if fmt is None:
            out += struct.pack('<II', 0xc0000000 | ident, len(value)) + value
        else:
            lc = {'B': 0, 'H': 1, 'Q': 3}[fmt]
            out += struct.pack('<I', 0x80000000 | lc << 28 | ident) + struct.pack('<' + fmt, value)
    return struct.pack('<I', len(out)) + out

def frame(op, body):
    raw = b'ZZDBRK01' + struct.pack('<HHHHI', 1, 0, op, 1, len(body)) + body
    padding = (-len(raw)) % 4
    return b'\0\7\0' + bytes([padding]) + raw + bytes(padding)

intro, attempt, nonce = bytes([3])*16, bytes([1])*16, bytes([2])*16
scope = struct.pack('<I', 6) + b'realm\0' + bytes(2) + struct.pack('<I', 7)
limits = struct.pack('<IIQQIIQIIIQ', 4096, 2048, 65536, 65536, 32, 4, 8192, 2, 32, 4, 8192)
features = struct.pack('<I', 0)
pairs = struct.pack('<I', 2) + struct.pack('<H', 1) + bytes([8])*16 + bytes([9])*16 + struct.pack('<H', 2) + bytes([10])*16 + bytes([11])*16
register = mutable([(1,None,intro), (2,None,attempt), (3,None,nonce), (4,None,scope),
    (5,None,bytes([7])*16), (6,'H',1), (7,'H',1), (8,'H',0), (9,'H',1), (10,'H',1),
    (11,None,features), (12,None,limits), (13,'Q',10000000000), (14,'H',1), (15,None,pairs)])
binding = h('zzdds-broker/register/v1', intro, register)
rejected = hashlib.sha256(b'zzdds-broker/rejected-request/v1\0' + struct.pack('<HQ',32,len(register)) + register).digest()
accept = mutable([(1,None,attempt), (2,None,binding), (3,None,scope), (4,None,bytes([4])*16),
    (5,None,bytes([5])*16), (6,'Q',1), (7,'H',1), (8,'H',0), (9,'H',1), (10,None,features),
    (11,None,limits), (12,'Q',10000000000), (13,'Q',3000000000), (14,'Q',5000000000),
    (15,'Q',2000000000), (16,None,pairs), (17,'B',1), (18,'H',1), (21,'H',1), (22,'H',1), (23,None,intro)])
reject = mutable([(1,None,attempt), (2,None,nonce), (3,'H',32), (4,'H',7), (5,'Q',100000000), (6,None,rejected)])
vectors = {'register_body':register, 'register_frame':frame(32, register),
    'register_binding':binding, 'register_rejected_digest':rejected,
    'register_accept_body':accept, 'register_accept_frame':frame(4, accept),
    'register_reject_body':reject, 'register_reject_frame':frame(29, reject)}
for name, value in vectors.items():
    target = root / (name + '.hex')
    content = value.hex() + '\n'
    if '--write' in sys.argv:
        target.write_text(content)
    else:
        assert target.read_text() == content, name
print(f"{'Wrote' if '--write' in sys.argv else 'Verified'} {len(vectors)} registration vectors")
