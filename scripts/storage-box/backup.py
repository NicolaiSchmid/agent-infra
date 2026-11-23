"""Archive completed exports; no raw live database or object-store reads."""
import argparse
import hashlib
import json
import os
import re
import stat
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


def bundle_repository(repository, target):
    """Bundle a bare git repository as its owner; root never runs git on it."""
    if not repository.is_dir():
        return {'agent_source': 'absent'}
    owner = repository.stat()
    git = ['git', '-c', 'core.hooksPath=/dev/null', '-C', str(repository)]
    if owner.st_uid != os.geteuid():
        git = ['setpriv', f'--reuid={owner.st_uid}', f'--regid={owner.st_gid}', '--clear-groups', *git]
    env = {'PATH': os.environ['PATH'], 'HOME': '/nonexistent',
           'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null'}
    if not subprocess.check_output([*git, 'for-each-ref'], env=env).strip():
        return {'agent_source': 'empty'}
    with target.open('wb') as output:
        subprocess.run([*git, 'bundle', 'create', '-', '--all'], env=env, stdout=output, check=True)
    # A full bundle lists its heads without a repository.
    subprocess.run(['git', 'bundle', 'list-heads', str(target)], env=env,
                   stdout=subprocess.DEVNULL, check=True)
    with target.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    return {'agent_source': 'bundled', 'agent_source_sha256': digest}


DIGEST = re.compile(r'sha256:[a-f0-9]{64}')
AGENT = re.compile(r'[a-z0-9][a-z0-9-]{0,62}')
COMMIT_RECORD = re.compile(r'[a-f0-9]{40}\.json')


def referenced_digests(export):
    """Bundles the snapshot can hand to a runner: active releases and open runs,
    the rule of June's apps/june/convex/hostedRuns/builds.ts `referenced`."""
    digests = set()
    with zipfile.ZipFile(export) as archive:
        names = set(archive.namelist())
        for table, status in (('hostedReleases', 'active'), ('hostedRuns', 'open')):
            if table + '/documents.jsonl' not in names:
                continue
            for line in archive.read(table + '/documents.jsonl').splitlines():
                row = json.loads(line) if line.strip() else {}
                if row.get('status') != status:
                    continue
                if not isinstance(row.get('artifact'), str) or not DIGEST.fullmatch(row['artifact']):
                    raise ValueError(f'invalid artifact digest in {table}')
                digests.add(row['artifact'])
    return sorted(digests)


def read_regular(path):
    """Reads a regular file without following a symlink."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('not a regular file')
        return source.read()


def collect_artifacts(store, digests, target):
    """Copies every referenced bundle, verified against its digest, and its build
    records into `target` in the store's layout (eve-deployments
    docs/agent-source.md, "Backup and restore"). A referenced bundle that is
    missing or damaged fails the backup: its archive could not resume that run."""
    if not digests:
        return {'agent_artifacts': 'none', 'agent_artifact_digests': []}
    total = 0
    for digest in digests:
        name = digest[7:]
        relative = Path('objects', 'sha256', name[:2], name)
        try:
            data = read_regular(store / relative)
        except (OSError, ValueError) as error:
            raise ValueError(f'referenced bundle {digest} is not in the store') from error
        if 'sha256:' + hashlib.sha256(data).hexdigest() != digest:
            raise ValueError(f'referenced bundle {digest} fails verification')
        (target / relative).parent.mkdir(parents=True, exist_ok=True)
        (target / relative).write_bytes(data)
        total += len(data)
    wanted = set(digests)
    builds = store / 'builds'
    for agent in sorted(os.listdir(builds)) if builds.is_dir() else []:
        if not AGENT.fullmatch(agent) or not (builds / agent).is_dir():
            continue
        for name in sorted(os.listdir(builds / agent)):
            if not COMMIT_RECORD.fullmatch(name):
                continue
            text = read_regular(builds / agent / name)
            if json.loads(text).get('digest') not in wanted:
                continue
            (target / 'builds' / agent).mkdir(parents=True, exist_ok=True)
            (target / 'builds' / agent / name).write_bytes(text)
            reported = builds / agent / (name[:-5] + '.reported')
            if reported.is_file() and not reported.is_symlink():
                (target / 'builds' / agent / reported.name).write_bytes(read_regular(reported))
    (target / 'referenced.json').write_text(json.dumps(digests))
    return {'agent_artifacts': 'bundled', 'agent_artifact_digests': digests,
            'agent_artifact_bytes': total}


def main():
    p = argparse.ArgumentParser()
    p.add_argument('deployment')
    p.add_argument('zip', type=Path)
    p.add_argument('export_ts')
    for name in ('state', 'secrets', 'config'):
        p.add_argument('--' + name, required=True, type=Path)
    p.add_argument('--capture-runtime', action='store_true')
    p.add_argument('--age-recipient-file', type=Path)
    # The deployment's agent source repository and artifact store
    # (hosts/black/agent-source.nix). Builds are not a recovery path: a commit
    # whose toolchain is gone cannot be rebuilt, so the bundles the snapshot
    # references ride along.
    p.add_argument('--agent-source', type=Path)
    p.add_argument('--agent-artifacts', type=Path)
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
        if a.agent_source:
            metrics.update(bundle_repository(a.agent_source, work / 'agent-source.bundle'))
        if a.agent_artifacts:
            (work / 'agent-artifacts').mkdir()
            metrics.update(collect_artifacts(a.agent_artifacts, referenced_digests(a.zip),
                                             work / 'agent-artifacts'))
        with tarfile.open(work / 'recovery.tar', 'w') as tar:
            # Each deployment's env already contains its scoped Garage key.
            # Shared host/admin secrets are outside product recovery authority.
            for secret in required:
                tar.add(secret, arcname='secrets/' + secret.name)
            tar.add(a.config, arcname='agent-infra')
            if metrics.get('agent_source') == 'bundled':
                tar.add(work / 'agent-source.bundle', arcname='agent-source/repo.bundle')
            if metrics.get('agent_artifacts') == 'bundled':
                tar.add(work / 'agent-artifacts', arcname='agent-artifacts')
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
