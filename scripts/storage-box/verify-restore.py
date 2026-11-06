"""Run on an isolated recovery host after borg extract; never on Black.
Checks archive bytes/config. Application record/blob assertions remain mandatory.
"""
import hashlib
import json
from pathlib import Path
import sys
import tarfile
import zipfile

root = Path(sys.argv[1])
manifest = json.loads((root / 'manifest.json').read_text())
with (root / 'export.zip').open('rb') as source:
    assert hashlib.file_digest(source, 'sha256').hexdigest() == manifest['sha256']
with zipfile.ZipFile(root / 'export.zip') as z:
    assert z.testzip() is None
    assert any(n.endswith('/documents.jsonl') for n in z.namelist())
with tarfile.open(root / 'recovery.tar') as t:
    names = t.getnames()
    for required in ['agent-infra/flake.lock', 'agent-infra/hosts/black/convex/compose.yaml',
                     'agent-infra/hosts/black/convex/deployments.nix',
                     f"secrets/convex-{manifest['deployment']}.env",
                     f"secrets/convex-{manifest['deployment']}-admin-key"]:
        assert required in names, required
print('Archive integrity and recovery configuration verified; application import/record/blob checks still required.')
