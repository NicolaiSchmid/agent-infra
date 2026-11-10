"""Archive completed exports; no raw live database or object-store reads."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import time
import zipfile
import urllib.request


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
    p.add_argument('--capture-runtime', action='store_true')
    p.add_argument('--age-recipient-file', type=Path)
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
        # Effective systemd overrides and container image/config are recovery
        # inputs too; repository source alone can lag scoped live deployments.
        runtime = work / 'runtime'
        if a.capture_runtime:
            runtime.mkdir()
            unit = subprocess.check_output(['systemctl', 'cat', f'convex-{a.deployment}.service'])
            (runtime / 'backend.service').write_bytes(unit)
            ids = subprocess.check_output(['docker', 'ps', '-q', '--filter',
                f'label=com.docker.compose.project=convex-{a.deployment}', '--filter',
                'label=com.docker.compose.service=backend']).decode().split()
            if len(ids) != 1:
                raise ValueError('expected one running backend')
            container = subprocess.check_output(['docker', 'inspect', ids[0]])
            (runtime / 'container.json').write_bytes(container)
            info = json.loads(container)[0]
            metrics['backend_image'] = info['Image']
            (runtime / 'host-version.json').write_bytes(subprocess.check_output(['/run/current-system/sw/bin/nixos-version', '--json']))
            bindings = info['NetworkSettings']['Ports']['3210/tcp']
            port = next(binding['HostPort'] for binding in bindings if binding['HostIp'] == '127.0.0.1')
            auth = required[1].read_text().strip()
            request = urllib.request.Request(f'http://127.0.0.1:{int(port)}/api/query',
                data=json.dumps({'path': '_system/cli/queryEnvironmentVariables', 'args': {}, 'format': 'json'}).encode(),
                headers={'Authorization': 'Convex ' + auth, 'Content-Type': 'application/json'})
            with urllib.request.urlopen(request, timeout=30) as response:
                environment = json.load(response)
            if environment.get('status') != 'success':
                raise ValueError('failed to capture application environment')
            (runtime / 'application-environment.json').write_text(json.dumps(environment['value']))
            references = set(re.findall(r"/(?:nix/store|var/lib/client-data)/[^\s;\"']+", unit.decode()))
        else:
            references = set()
        with tarfile.open(work / 'recovery.tar', 'w') as tar:
            # Each deployment's env already contains its scoped Garage key.
            # Shared host/admin secrets are outside product recovery authority.
            for secret in required:
                tar.add(secret, arcname='secrets/' + secret.name)
            tar.add(a.config, arcname='agent-infra')
            if a.capture_runtime:
                tar.add(runtime, arcname='runtime')
                # Only files named by the service, never state directories,
                # database mounts or the live object store.
                for name in sorted(references):
                    path = Path(name)
                    if path.is_file() and path.suffix in {'.env', '.json', '.yaml', '.yml', '.toml'}:
                        tar.add(path, arcname='runtime/files' + name)
        with a.zip.open('rb') as source:
            digest = hashlib.file_digest(source, 'sha256').hexdigest()
        metrics.update(deployment=a.deployment, export_ts=a.export_ts,
                       infrastructure_source_revision=os.environ.get('PRODUCT_BACKUP_SOURCE_REVISION', 'unknown'),
                       sha256=digest,
                       scope='Convex product export including storage, secrets and deployment source')
        (work / 'manifest.json').write_text(json.dumps(metrics))
        files = ['export.zip', 'recovery.tar', 'manifest.json']
        if a.age_recipient_file:
            # Only public recipient material is present on the writer. Fresh
            # randomized age ciphertext intentionally sacrifices deduplication.
            payload = work / 'payload.tar.age'
            with payload.open('wb') as output:
                process = subprocess.Popen(['age', '--encrypt', '--recipients-file',
                    str(a.age_recipient_file)], stdin=subprocess.PIPE, stdout=output)
                try:
                    with tarfile.open(fileobj=process.stdin, mode='w|') as tar:
                        for name in files:
                            tar.add(work / name, arcname=name)
                finally:
                    process.stdin.close()
                if process.wait() != 0:
                    raise RuntimeError('public-key payload encryption failed')
            files = ['payload.tar.age']
        archive = f'{a.deployment}-{time.time_ns()}'
        result = subprocess.run(['borg', 'create', '--remote-path=borg-1.4', '--stats', '--json',
                                 '--compression', 'none' if a.age_recipient_file else 'lz4', '::' + archive,
                                 *files],
                                cwd=work, check=True, capture_output=True)
        # Exit 1 (warning) also fails closed: no success timestamp.
        receipt = dict(metrics, archive=archive, completed_at=time.time(),
                       public_key_payload=bool(a.age_recipient_file),
                       borg=json.loads(result.stdout))
        target = a.state / (a.deployment + '.json')
        temporary = target.with_suffix('.tmp')
        temporary.write_text(json.dumps(receipt))
        temporary.replace(target)


if __name__ == '__main__':
    main()
