#!/usr/bin/env python3
"""Run maintained review models/fixtures independently of production unit tests."""
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
checks = [
    'test/design-models/review_revision_traces.py',
    'test/design-models/protocol_revision_model.py',
    'test/design-models/review_contract_traces.py',
    'test/design-models/broker_baseline_identity.py',
    'docs/design/probes/check_broker_registry.py',
    *['docs/design/probes/broker_golden/' + name + '.py' for name in (
        'reference', 'origin_version', 'service_introduction', 'registration',
        'aggregate_freshness', 'final_bodies')],
]
for check in checks:
    print(f'Checking {check}', flush=True)
    subprocess.run([sys.executable, str(root / check)], cwd=root, check=True, timeout=120)
print('Maintained specification models and independent vectors: PASS', flush=True)
