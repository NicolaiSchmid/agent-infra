#!/usr/bin/env python3
"""Verify fixed candidate bytes without unpacking or executing image content."""
import hashlib
import json
from pathlib import Path
import sys
import tarfile

root = Path(sys.argv[1])
archive = root / 'june-callback-candidate.tar'
assert hashlib.file_digest(archive.open('rb'), 'sha256').hexdigest() == '743341b759074a0b5ef0e6439afba3785e71163eb50983ce809c756420eeecb8'
assert (root / 'source-commit.txt').read_text().strip() == '46334ae29a556b3c492219ae0b1bb1a6888ed107'
assert (root / 'workflow-commit.txt').read_text().strip() == 'b9e7e9cbeac9bffc4fffc8408a73b3fabff83cc1'
with tarfile.open(archive) as image:
    def blob(digest):
        return image.extractfile('blobs/sha256/' + digest.removeprefix('sha256:'))
    for entry in image.getmembers():
        if entry.isfile() and entry.name.startswith('blobs/sha256/'):
            assert hashlib.file_digest(image.extractfile(entry), 'sha256').hexdigest() == entry.name.split('/')[-1]
    index = json.load(image.extractfile('index.json'))
    assert len(index['manifests']) == 1
    descriptor = index['manifests'][0]
    assert descriptor['digest'] == 'sha256:fc6f1b18d8e4ed81b9f77dffe131bc58c333c85557f51501324418fd6a2eb2bb'
    manifest = json.load(blob(descriptor['digest']))
    config = json.load(blob(manifest['config']['digest']))
    assert config['architecture'] == 'amd64' and config['os'] == 'linux'
    base_manifest = json.loads((root / 'base-amd64-manifest.json').read_text())
    assert manifest['layers'][:-1] == base_manifest['layers']
    base_config = json.loads((root / 'base-amd64-config.json').read_text())
    assert (config['config'] | {'Labels': {}}) == (base_config['config'] | {'Labels': {}})
    labels = config['config']['Labels']
    assert labels['io.convex.callback.patch.sha256'] == '53c1ce73973f413039090c7366c1ae59b6f67c952b04ce9f6ff4e942ce1b2529'
    assert labels['io.convex.upstream.revision'] == 'bb31399c8704ceb6c19003936f6e144375b2c3bc'
    assert config['rootfs']['diff_ids'][:-1] == base_config['rootfs']['diff_ids']
(root / 'candidate-verification.json').write_text(json.dumps({
    'manifest': descriptor['digest'], 'config': manifest['config']['digest'],
    'archive_sha256': '743341b759074a0b5ef0e6439afba3785e71163eb50983ce809c756420eeecb8',
    'base_layers_preserved': True, 'base_config_preserved_except_labels': True,
}, indent=2) + '\n')
print('PASS: archive, all blobs, source/workflow pins, base layers/config and patch labels')
