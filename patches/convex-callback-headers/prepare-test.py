"""Replay the patch on hash-checked upstream inputs; never touch a live checkout."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import urllib.request

root = Path(__file__).resolve().parent
fixture = root / '.fixture'
if fixture.exists():
    shutil.rmtree(fixture)
fixture.mkdir()
for name, expected in json.loads((root / 'inputs.json').read_text()).items():
    url = 'https://raw.githubusercontent.com/convex/convex-backend/bb31399c8704ceb6c19003936f6e144375b2c3bc/' + name
    data = urllib.request.urlopen(url, timeout=30).read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError('upstream input hash mismatch: ' + name)
    target = fixture / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
subprocess.run(['git', 'apply', '--check', str(root / 'fix.patch')], cwd=fixture, check=True)
subprocess.run(['git', 'apply', str(root / 'fix.patch')], cwd=fixture, check=True)
