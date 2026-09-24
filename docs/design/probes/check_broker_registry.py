"""Mechanical checks for the draft registry; not semantic/wire conformance."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
schema = (root / 'schema/broker-control-draft.idl').read_text()
constants = dict((name, int(value, 0)) for name, value in re.findall(
    r'const\s+(?:unsigned short|unsigned long|octet)\s+(\w+)\s*=\s*(0x[0-9a-fA-F]+|\d+)\s*;', schema))
ops = {name.removeprefix('OP_'): value for name, value in constants.items() if name.startswith('OP_')}
reserved = {value for name, value in constants.items() if name.startswith('RESERVED_OP_')}
assert len(ops) == 27 and reserved == {1, 2, 3, 23, 24}
assert len(set(ops.values())) == len(ops) and not set(ops.values()) & reserved
registry = (root / 'broker-wire-registry.md').read_text()
rows = {name: int(code) for code, name in re.findall(r'^\| (\d+) \| ([A-Z_]+) \|', registry, re.M)}
assert rows == ops, (rows, ops)
admission = (root / 'broker-operation-validation.md').read_text()
for name, code in ops.items():
    assert re.search(rf'^\| {code} {name} \|', admission, re.M), name
count = 0
for name, body in re.findall(r'@mutable\s+struct\s+(\w+)\s*\{(.*?)\};', schema, re.S):
    ids = [int(i) for i in re.findall(r'@id\((\d+)\)', body)]
    assert len(ids) == len(set(ids)), name
    assert all(0 < i < 0x0fffffff for i in ids), name
    count += 1
# Values may repeat between namespaces, never within one discriminator namespace.
groups = [('OP_', 'RESERVED_OP_'), ('FEATURE_',), ('CHANNEL_', 'RESERVED_CHANNEL_'),
          ('METADATA_',), ('PROFILE_',), ('VIEW_',), ('REASON_',), ('STATUS_',),
          ('ERROR_',), ('RECOVERY_',), ('RECORD_',), ('CHANGE_',), ('DELTA_',),
          ('COMMIT_',), ('DOWNSTREAM_',), ('KEY_REPRESENTATION_',), ('PID_',)]
for prefixes in groups:
    selected = {k: v for k, v in constants.items() if k.startswith(prefixes)}
    assert len(set(selected.values())) == len(selected), selected
pids = {v for k, v in constants.items() if k.startswith('PID_')}
assert pids == {0x8003, 0x8004, 0x8005, 0x8006}
native = (root.parents[1] / 'src/rtps/pid.zig').read_text()
for value in pids:
    assert not re.search(rf'=\s*0x{value:04x}\s*;', native, re.I), hex(value)
assert constants['BOOTSTRAP_ENTITY_KEY'] == 0x7a0001
assert (constants['BROKER_WRITER_KIND'], constants['BROKER_READER_KIND']) == (0x43, 0x44)
print(f'27 opcode mappings; {count} mutable member-ID sets; {len(groups)} discriminator namespaces; draft PID and endpoint assignments: PASS')
