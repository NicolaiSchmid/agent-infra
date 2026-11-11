import json
from pathlib import Path
import sys
import time

stale = []
for name in sys.argv[2:]:
    try:
        age = time.time() - json.loads((Path(sys.argv[1]) / (name + '.json')).read_text())['completed_at']
        if not 0 <= age < 36 * 3600:
            stale.append(name)
    except (OSError, ValueError, KeyError):
        stale.append(name)
if stale:
    print('Missing/stale off-host backup: ' + ', '.join(stale), file=sys.stderr)
    sys.exit(1)
