"""Independent CDR1 service values and hash framing; SPDP samples are structural only."""
import hashlib
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent
vectors = {}

def h(label, *blobs):
    return hashlib.sha256(label.encode('ascii') + b'\0' + b''.join(
        struct.pack('<Q', len(b)) + b for b in blobs)).digest()

class Cdr:
    def __init__(self, endian):
        self.endian, self.data = endian, bytearray()
    def put(self, fmt, value):
        size = struct.calcsize(fmt)
        self.data += bytes((-len(self.data)) % size)
        self.data += struct.pack(self.endian + fmt, value)
    def raw(self, data):
        self.data += data

for endian, suffix, rep in [('<', 'le', b'\0\3'), ('>', 'be', b'\0\2')]:
    caps = Cdr(endian)
    for fmt, value in [('H', 1), ('I', 1), ('H', 1), ('H', 3),
                       ('I', 1), ('H', 1), ('H', 0), ('H', 0),
                       ('I', 1), ('H', 1), ('I', 2), ('I', 7), ('I', 9)]:
        caps.put(fmt, value)
    caps.raw(bytes.fromhex('7a0001437a000144'))
    request = Cdr(endian)
    request.put('H', 1)
    request.put('H', 1)
    request.raw(bytes([1]) * 16 + bytes([2]) * 16)
    def param(pid, body):
        padded = bytes(body) + bytes((-len(body)) % 4)
        return struct.pack(endian + 'HH', pid, len(padded)) + padded
    sentinel = struct.pack(endian + 'HH', 1, 0)
    domain = param(0x000f, struct.pack(endian + 'I', 7)) + param(0x4014, struct.pack(endian + 'I', 5) + b'prod\0')
    client = rep + b'\0\0' + param(0x0050, bytes(range(16))) + domain + param(0x8004, caps.data) + sentinel
    server = rep + b'\0\0' + param(0x0050, bytes(range(16, 32))) + domain + param(0x8004, caps.data) + sentinel
    client_hash = h('zzdds-broker/client-spdp/v1', client)
    server_hash = h('zzdds-broker/server-spdp/v1', server)
    offer = struct.pack(endian + 'HH', 1, 1) + bytes([1])*16 + bytes([2])*16 + bytes([3])*16 + bytes([4])*16 + client_hash + server_hash
    for name, value in [('capabilities', caps.data), ('request', request.data), ('offer', offer),
                        ('client_spdp', client), ('server_spdp', server),
                        ('request_inline', param(0x8005, request.data) + sentinel),
                        ('offer_inline', param(0x8006, offer) + sentinel),
                        ('client_digest', client_hash), ('server_digest', server_hash),
                        ('path_digest', h('zzdds-broker/service-path/v1', client, rep, bytes(request.data) + bytes((-len(request.data)) % 4)))]:
        vectors[f'service_{name}_{suffix}.hex'] = bytes(value)
for name, value in vectors.items():
    target = root / name
    content = value.hex() + '\n'
    if '--write' in sys.argv:
        target.write_text(content)
    else:
        assert target.read_text() == content, name
print(f"{'Wrote' if '--write' in sys.argv else 'Verified'} {len(vectors)} service-introduction vectors")
