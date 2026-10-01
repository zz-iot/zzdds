"""Independent struct/hashlib reference, not the generated codec.
Default checks committed draft vectors; --write explicitly regenerates them.
"""
from pathlib import Path
import struct
import sys

root = Path(__file__).resolve().parent
MAGIC = b"ZZDBRK03"
INV = b"zzdds-broker/inventory/v1\x00"
SNAP = b"zzdds-broker/snapshot/v1\x00"


def collection(count, elements):
    """XCDR2 sequence of non-primitive elements: DHEADER (byte length of what follows),
    element count, then the elements."""
    body = struct.pack("<I", count) + elements
    return struct.pack("<I", len(body)) + body


def frame(operation, body):
    payload = MAGIC + struct.pack("<HHHHI", 1, 0, operation, 1, len(body)) + body
    padding = (-len(payload)) % 4
    return b"\x00\x07\x00" + bytes([padding]) + payload + bytes(padding)


# ViewSync: final positional two uint64 fields.
sync = struct.pack("<QQ", 5, 23)

def member(member_id, payload):
    return struct.pack("<II", 0xC0000000 | member_id, len(payload)) + payload

envelope = bytes([0x33])*16 + struct.pack('<II', 0, len(sync)) + sync

# A structurally encoded OriginRecord, not a semantically complete SPDP sample.
guid = bytes(range(12)) + bytes.fromhex("000001c1")
record = bytearray(guid + bytes([0x11]) * 16 + struct.pack("<H", 1) + guid)
record += bytes((-len(record)) % 4)
record += struct.pack("<QHH", 1, 1, 1)  # revision, UPSERT, opaque SPDP PL_CDR profile
record += bytes.fromhex("02050300")  # protocol/vendor bytes: fixture values
record += bytes(16) + b"\x00"  # absent native writer/sequence
record += bytes((-len(record)) % 4)
record += struct.pack("<q", 0)
metadata = collection(0, b"")  # empty metadata is an encoded empty MetadataList
record += struct.pack("<I", len(metadata)) + metadata
payload = bytes.fromhex("0003000001000000")
record += struct.pack("<I", len(payload)) + payload
record = bytes(record)

# Metadata values have their own byte grammar; only the outer list is XCDR2.
def metadata_list(entries):
    # Element alignment is relative to the stream origin; the DHEADER and count
    # occupy offsets 0-7, so the first element starts 4-aligned at offset 8.
    out = bytearray(8)
    for tag, value in entries:
        out += bytes((-len(out)) % 2)
        out += struct.pack("<HB", tag, 1)
        out += bytes((-len(out)) % 4)
        out += struct.pack("<I", len(value)) + value
    return collection(len(entries), bytes(out[8:]))

inline_le = bytes.fromhex("01710004000000000101000000")
inline_be = bytes.fromhex("00007100040000000100010000")
metadata_le = metadata_list([(1, b"\x02\x00"), (2, b"\x00\x00\x00\x01"), (3, inline_le)])
metadata_be = metadata_list([(1, b"\x02\x00"), (2, b"\x00\x00\x00\x01"), (3, inline_be)])

# Structural rejection fixture; request digest is a fixed synthetic correlation value.
reject_members = member(1, bytes([0x11]) * 16) + member(2, bytes([0x22]) * 16)
reject_members += struct.pack("<IH", 0x90000003, 3) + bytes(2)
reject_members += struct.pack("<IH", 0x90000004, 4) + bytes(2)
reject_members += struct.pack("<IQ", 0xB0000005, 100000000)
reject_members += member(6, bytes([0x33]) * 32)
reject = struct.pack("<I", len(reject_members)) + reject_members

vectors = {
    "admission_reject_body.hex": reject.hex() + "\n",
    "admission_reject_frame.hex": frame(29, reject).hex() + "\n",
    "metadata_le.hex": metadata_le.hex() + "\n",
    "metadata_be.hex": metadata_be.hex() + "\n",
    "bootstrap_endpoints.hex": bytes.fromhex("7a0001437a000144").hex() + "\n",
    "view_sync_body.hex": sync.hex() + "\n",
    "view_sync_envelope.hex": envelope.hex() + "\n",
    "view_sync_frame.hex": frame(17, envelope).hex() + "\n",
    "padding_frame.hex": frame(27, b"\x10\x20\x30").hex() + "\n",
    "origin_record.hex": record.hex() + "\n",
}
for name, content in vectors.items():
    target = root / name
    if "--write" in sys.argv:
        target.write_text(content)
    else:
        assert target.read_text() == content, name
print(f"{'Wrote' if '--write' in sys.argv else 'Verified'} {len(vectors)} independent draft vectors")
