"""Exit status bits: 1 a backup is missing or stale, 2 the latest receipt lacks
referenced hosted-workflow bundles (runbooks/black-agent-source.md)."""
import json
from pathlib import Path
import sys
import time

stale, incomplete = [], []
for name in sys.argv[2:]:
    try:
        receipt = json.loads((Path(sys.argv[1]) / (name + '.json')).read_text())
        age = time.time() - receipt['completed_at']
        if not 0 <= age < 36 * 3600:
            stale.append(name)
        if receipt.get('agent_artifact_missing'):
            incomplete.append(name)
    except (OSError, ValueError, KeyError):
        stale.append(name)
if stale:
    print('Missing/stale off-host backup: ' + ', '.join(stale), file=sys.stderr)
if incomplete:
    print('Backup lacks referenced hosted-workflow bundles: ' + ', '.join(incomplete), file=sys.stderr)
sys.exit((1 if stale else 0) | (2 if incomplete else 0))
