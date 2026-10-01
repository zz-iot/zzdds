#!/usr/bin/env python3
"""Check the broker wire-format fixtures independently of production unit tests.

Each broker_golden generator re-derives its committed .hex vectors from the
specification's byte rules (struct/hashlib only, no generated codec), and the
registry check keeps the schema and the contracts' identifier tables consistent.
"""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
checks = [
    'docs/design/probes/check_broker_registry.py',
    *['docs/design/probes/broker_golden/' + name + '.py' for name in (
        'reference', 'origin_version', 'service_introduction', 'registration',
        'aggregate_freshness', 'final_bodies')],
]
for check in checks:
    print(f'Checking {check}', flush=True)
    subprocess.run([sys.executable, str(root / check)], cwd=root, check=True, timeout=120)
print('Broker schema registry and independent wire vectors: PASS', flush=True)
