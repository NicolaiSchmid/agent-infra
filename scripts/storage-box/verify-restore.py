"""Run on an isolated recovery host after borg extract; never on Black.
Checks archive bytes/config. Application record/blob assertions remain mandatory.
"""
import hashlib
import importlib.util
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
    # Every bundle the snapshot references is in the archive and matches its
    # digest, so an open run can continue on its own bundle without a rebuild.
    spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('backup.py'))
    backup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(backup)
    referenced = backup.referenced_digests(root / 'export.zip')
    if 'agent_artifacts' in manifest:
        assert manifest['agent_artifact_digests'] == referenced, 'bundle list differs from snapshot'
        for digest in referenced:
            name = digest[7:]
            member = t.extractfile(f'agent-artifacts/objects/sha256/{name[:2]}/{name}')
            assert member is not None, digest
            assert 'sha256:' + hashlib.sha256(member.read()).hexdigest() == digest, digest
        if referenced:
            listed = json.load(t.extractfile('agent-artifacts/referenced.json'))
            assert listed == referenced, 'referenced.json differs from snapshot'
    else:
        assert not referenced, 'snapshot references bundles the archive does not hold'
print('Archive integrity, recovery configuration and referenced bundles verified; application import/record/blob checks still required.')
