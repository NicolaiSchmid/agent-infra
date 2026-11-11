"""Import one extracted archive into a capped, network-isolated local backend.
Requires the archived backend image locally and an installed Convex CLI main.js.
Never points at production: uses a fresh Docker internal network with no published ports. All customer data and logs remain in the private drill directory.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tarfile
import time
import urllib.request
import zipfile


def inventory(path):
    records, blobs = {}, {}
    with zipfile.ZipFile(path) as z:
        for name in z.namelist():
            if name.endswith('/documents.jsonl') and not name.startswith('_tables/'):
                rows = [json.loads(line) for line in z.read(name).splitlines() if line]
                if name == '_storage/documents.jsonl':
                    for row in rows:
                        row.pop('internalId', None)  # backend-local storage address
                records[name] = sorted(json.dumps(row, sort_keys=True) for row in rows)
            elif name.startswith('_storage/') and not name.endswith('/'):
                blobs[name] = hashlib.sha256(z.read(name)).hexdigest()
    return records, blobs


def main():
    p = argparse.ArgumentParser()
    p.add_argument('archive', type=Path)
    p.add_argument('--cli', required=True, type=Path)
    a = p.parse_args()
    root = a.archive.resolve()
    os.umask(0o077)
    manifest = json.loads((root / 'manifest.json').read_text())
    with tarfile.open(root / 'recovery.tar') as tar:
        info = json.load(tar.extractfile('runtime/container.json'))[0]
        key = tar.extractfile(f"secrets/convex-{manifest['deployment']}-admin-key").read().decode().strip()
        environment = dict(value.split('=', 1) for value in info['Config']['Env'])
        env_member = 'runtime/application-environment.json'
        app_env = json.load(tar.extractfile(env_member)) if env_member in tar.getnames() else None
    image = info['Image']
    subprocess.run(['docker', 'image', 'inspect', image], stdout=subprocess.DEVNULL, check=True)
    suffix = str(time.time_ns())
    name, network = 'product-restore-' + suffix, 'product-restore-net-' + suffix
    work = root / ('exercise-' + suffix)
    work.mkdir(mode=0o700)
    (work / 'data').mkdir(mode=0o700)
    (work / 'backend.env').write_text('\n'.join([
        'INSTANCE_NAME=' + environment['INSTANCE_NAME'],
        'INSTANCE_SECRET=' + environment['INSTANCE_SECRET'],
        'CONVEX_CLOUD_ORIGIN=http://127.0.0.1:3210',
        'CONVEX_SITE_ORIGIN=http://127.0.0.1:3211',
        'DISABLE_BEACON=true', 'DISABLE_METRICS_ENDPOINT=true', 'RUST_LOG=warn']) + '\n')
    subprocess.run(['docker', 'network', 'create', '--internal', network], stdout=subprocess.DEVNULL, check=True)
    started = time.monotonic()
    try:
        subprocess.run(['docker', 'run', '-d', '--name', name, '--network', network,
                        '--memory', '3072m', '--memory-swap', '3072m', '--cpus', '2',
                        '--pids-limit', '256', '--log-driver', 'json-file', '--log-opt', 'max-size=5m',
                        '--env-file', str(work / 'backend.env'),
                        '--mount', f'type=bind,source={work / "data"},target=/convex/data',
                        image], stdout=subprocess.DEVNULL, check=True)
        network_info = json.loads(subprocess.check_output(['docker', 'network', 'inspect', network]))[0]
        assert network_info['Internal'] is True
        inspect = json.loads(subprocess.check_output(['docker', 'inspect', name]))[0]
        address = inspect['NetworkSettings']['Networks'][network]['IPAddress']
        assert address and not inspect['HostConfig']['PortBindings']
        url = 'http://' + address + ':3210'

        def request(path, body=None):
            req = urllib.request.Request(url + path,
                data=json.dumps(body).encode() if body is not None else None,
                headers={'Authorization': 'Convex ' + key, 'Content-Type': 'application/json'})
            return urllib.request.urlopen(req, timeout=120)

        for _ in range(60):
            try:
                with request('/version') as response:
                    assert response.status == 200
                break
            except OSError:
                time.sleep(1)
        else:
            raise RuntimeError('isolated backend did not start')
        env = os.environ.copy()
        # Explicit isolated-address credentials prevent accidental production selection.
        for var in list(env):
            if var.startswith('CONVEX_'):
                env.pop(var)
        env.update(CONVEX_SELF_HOSTED_URL=url, CONVEX_SELF_HOSTED_ADMIN_KEY=key,
                   CONVEX_DISABLE_TELEMETRY='1')
        (work / 'package.json').write_text('{"name":"isolated-product-restore","private":true,"dependencies":{"convex":"*"}}')
        with (work / 'import.log').open('wb') as log:
            subprocess.run(['node', str(a.cli.resolve()), 'import', '--replace-all', '-y',
                            str(root / 'export.zip')], cwd=work, env=env, stdout=log,
                           stderr=subprocess.STDOUT, check=True, timeout=1800)
        if app_env is not None:
            changes = [{'name': row['name'], 'value': row['value']} for row in app_env]
            with request('/api/update_environment_variables', {'changes': changes}) as response:
                assert response.status == 200
            with request('/api/query', {'path': '_system/cli/queryEnvironmentVariables', 'args': {}, 'format': 'json'}) as response:
                restored_env = json.load(response)
            assert {row['name']: row['value'] for row in restored_env['value']} == {row['name']: row['value'] for row in app_env}
        with request('/api/export/request/zip?includeStorage=true', {}) as response:
            assert response.status == 200
        for _ in range(180):
            with request('/api/query', {'path': '_system/cli/exports:getLatest', 'args': {}, 'format': 'json'}) as response:
                export = json.load(response)['value']
            if export['state'] == 'completed':
                break
            if export['state'] == 'failed':
                raise RuntimeError('isolated re-export failed')
            time.sleep(1)
        else:
            raise RuntimeError('isolated export timed out')
        with request('/api/export/zip/' + str(export['start_ts'])) as response:
            (work / 'restored.zip').write_bytes(response.read())
        expected, expected_blobs = inventory(root / 'export.zip')
        actual, actual_blobs = inventory(work / 'restored.zip')
        assert expected == actual, 'restored records differ'
        assert expected_blobs == actual_blobs, 'restored blob SHA256s differ'
        receipt = dict(deployment=manifest['deployment'], archive=manifest,
                       verified_records=sum(len(rows) for table, rows in expected.items() if table != '_storage/documents.jsonl'),
                       verified_storage_records=len(expected.get('_storage/documents.jsonl', [])),
                       verified_tables=len(expected), verified_blobs=len(expected_blobs),
                       application_environment_verified=app_env is not None,
                       instance_secret_admin_access=True, isolated_network=True,
                       image=image, elapsed_seconds=round(time.monotonic() - started, 2))
        (root / 'drill-receipt.json').write_text(json.dumps(receipt, indent=2))
        print(f"{manifest['deployment']}: records, blob SHA256s, instance access and archived image verified in isolation")
    finally:
        # Only resources created by this invocation; never global prune.
        (work / 'container-state.json').write_bytes(subprocess.run(['docker', 'inspect', '--format', '{{json .State}}', name], capture_output=True).stdout)
        with (work / 'backend.log').open('wb') as log:
            subprocess.run(['docker', 'logs', name], stdout=log, stderr=subprocess.STDOUT)
        subprocess.run(['docker', 'rm', '-f', name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(['docker', 'network', 'rm', network], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (work / 'backend.env').unlink(missing_ok=True)


if __name__ == '__main__':
    main()
