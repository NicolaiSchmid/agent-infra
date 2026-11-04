"""Archive completed exports; no raw live database or object-store reads."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import zipfile


def inspect_export(path):
    with zipfile.ZipFile(path) as archive:
        if archive.testzip() is not None:
            raise ValueError('corrupt export')
        names = archive.namelist()
        if not any(n.endswith('/documents.jsonl') for n in names):
            raise ValueError('no Convex records in export')
        return {'entries': len(names), 'zip_bytes': Path(path).stat().st_size,
                'uncompressed_bytes': sum(i.file_size for i in archive.infolist())}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('deployment')
    p.add_argument('zip', type=Path)
    p.add_argument('export_ts')
    for name in ('state', 'secrets', 'config'):
        p.add_argument('--' + name, required=True, type=Path)
    a = p.parse_args()
    os.umask(0o077)
    repository = json.loads(subprocess.check_output(['borg', 'info', '--json']))
    if repository['encryption']['mode'] != 'repokey-blake2':
        raise ValueError('repository must use repokey-blake2 encryption')
    metrics = inspect_export(a.zip)
    # A stable filename permits dedup across exports; ZIP compression may still
    # defeat chunk reuse. Borg's actual statistics, not assumptions, size retention.
    with tempfile.TemporaryDirectory(dir=a.zip.parent) as directory:
        work = Path(directory)
        os.link(a.zip, work / 'export.zip')
        required = [a.secrets / f'convex-{a.deployment}.env',
                    a.secrets / f'convex-{a.deployment}-admin-key']
        for secret in required:
            if not secret.is_file() or not secret.stat().st_size:
                raise ValueError('missing recovery secret')
        with tarfile.open(work / 'recovery.tar', 'w') as tar:
            tar.add(a.secrets, arcname='secrets')
            tar.add(a.config, arcname='agent-infra')
        with a.zip.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        metrics.update(deployment=a.deployment, export_ts=a.export_ts,
                       sha256=digest,
                       scope='Convex product export including storage, secrets and deployment source')
        (work / 'manifest.json').write_text(json.dumps(metrics))
        archive = f'{a.deployment}-{time.time_ns()}'
        result = subprocess.run(['borg', 'create', '--remote-path=borg-1.4', '--stats', '--json',
                                 '--compression', 'lz4', '::' + archive,
                                 'export.zip', 'recovery.tar', 'manifest.json'],
                                cwd=work, check=True, capture_output=True)
        # Exit 1 (warning) also fails closed: no success timestamp.
        receipt = dict(metrics, archive=archive, completed_at=time.time(),
                       borg=json.loads(result.stdout))
        target = a.state / (a.deployment + '.json')
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(receipt))
        temporary.replace(target)


if __name__ == '__main__':
    main()
