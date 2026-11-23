import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
import shutil
import io
import hashlib
import os
import tarfile
import json
import time
import zipfile

spec = importlib.util.spec_from_file_location('backup', Path(__file__).with_name('backup.py'))
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)

class ExportTest(unittest.TestCase):
    def test_records_and_blob(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'export.zip'
            with zipfile.ZipFile(path, 'w') as z:
                z.writestr('messages/documents.jsonl', '{"body":"recovery fixture"}\n')
                z.writestr('_storage/blob', b'recovery blob')
            self.assertEqual(backup.inspect_export(path)['entries'], 2)

    def test_rejects_non_export(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / 'bad.zip'
            path.write_bytes(b'truncated')
            with self.assertRaises(zipfile.BadZipFile):
                backup.inspect_export(path)
            with zipfile.ZipFile(path, 'w') as z:
                z.writestr('unrelated', 'data')
            with self.assertRaises(ValueError):
                backup.inspect_export(path)

class ArchiveTest(unittest.TestCase):
    def test_only_success_advances_receipt(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            secrets = root / 'secrets'
            secrets.mkdir()
            for name in ('convex-demo.env', 'convex-demo-admin-key'):
                (secrets / name).write_text('fixture')
            (secrets / 'e2b.env').write_text('unrelated host credential')
            export = root / 'export.zip'
            with zipfile.ZipFile(export, 'w') as z:
                z.writestr('table/documents.jsonl', '{}')
            args = ['backup', 'demo', str(export), '123', '--state', d,
                    '--secrets', str(secrets), '--config', str(secrets)]
            with patch.object(sys, 'argv', args), patch.object(subprocess, 'check_output', return_value=b'{"encryption":{"mode":"repokey-blake2"}}'):
                with patch.object(subprocess, 'run', side_effect=subprocess.CalledProcessError(1, 'borg')):
                    with self.assertRaises(subprocess.CalledProcessError):
                        backup.main()
                self.assertFalse((root / 'demo.json').exists())
                def verify_scoped_secrets(command, **kwargs):
                    with tarfile.open(Path(kwargs['cwd']) / 'recovery.tar') as archive:
                        names = {name for name in archive.getnames() if name.startswith('secrets/')}
                    self.assertEqual(names, {'secrets/convex-demo.env', 'secrets/convex-demo-admin-key'})
                    return subprocess.CompletedProcess(command, 0, stdout=b'{}')
                with patch.object(subprocess, 'run', side_effect=verify_scoped_secrets):
                    backup.main()
                self.assertTrue((root / 'demo.json').exists())
                self.assertTrue(export.exists())

class AgentSourceTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('git'), 'git required')
    def test_bundles_history_and_restores(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            repository = root / 'repo.git'
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
                       GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@example.invalid',
                       GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@example.invalid')
            self.assertEqual(backup.bundle_repository(repository, root / 'b'), {'agent_source': 'absent'})
            subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(repository)], check=True, env=env)
            self.assertEqual(backup.bundle_repository(repository, root / 'b'), {'agent_source': 'empty'})
            self.assertFalse((root / 'b').exists())
            clone = root / 'clone'
            subprocess.run(['git', 'init', '-q', '-b', 'main', str(clone)], check=True, env=env)
            (clone / 'agents').mkdir()
            (clone / 'agents' / 'README').write_text('fixture')
            subprocess.run(['git', '-C', str(clone), 'add', '.'], check=True, env=env)
            subprocess.run(['git', '-C', str(clone), 'commit', '-qm', 'fixture'], check=True, env=env)
            subprocess.run(['git', '-C', str(clone), 'push', '-q', str(repository), 'main'], check=True, env=env)
            result = backup.bundle_repository(repository, root / 'b')
            self.assertEqual(result['agent_source'], 'bundled')
            restored = root / 'restored.git'
            subprocess.run(['git', 'clone', '-q', '--mirror', str(root / 'b'), str(restored)], check=True, env=env)
            head = lambda r: subprocess.check_output(['git', '-C', str(r), 'rev-parse', 'main'], env=env)
            self.assertEqual(head(restored), head(repository))

def write_export(path, releases=(), runs=()):
    with zipfile.ZipFile(path, 'w') as z:
        z.writestr('hostedReleases/documents.jsonl', ''.join(json.dumps(r) + '\n' for r in releases))
        z.writestr('hostedRuns/documents.jsonl', ''.join(json.dumps(r) + '\n' for r in runs))


def put_bundle(store, data, agent='hello', commit='1' * 40, reported=True):
    """A store entry exactly as eve-deployments' artifact store writes it."""
    digest = 'sha256:' + hashlib.sha256(data).hexdigest()
    path = store / 'objects' / 'sha256' / digest[7:9] / digest[7:]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    builds = store / 'builds' / agent
    builds.mkdir(parents=True, exist_ok=True)
    (builds / (commit + '.json')).write_text(json.dumps({
        'agent': agent, 'commit': commit, 'agentTree': 'a' * 40, 'digest': digest,
        'toolchain': 'sha256:' + 'b' * 64, 'environment': 'sha256:' + 'c' * 64,
        'protocol': 2, 'bytes': len(data), 'builtAt': '2026-11-23T00:00:00.000Z'}))
    if reported:
        (builds / (commit + '.reported')).write_text(digest + '\n')
    return digest


class AgentArtifactsTest(unittest.TestCase):
    def test_referenced_digests_follow_june_rule(self):
        a, b, c = ('sha256:' + x * 64 for x in 'abc')
        with tempfile.TemporaryDirectory() as d:
            export = Path(d) / 'export.zip'
            write_export(export,
                         releases=[{'status': 'active', 'artifact': a}, {'status': 'retired', 'artifact': c}],
                         runs=[{'status': 'open', 'artifact': b}, {'status': 'open', 'artifact': a},
                               {'status': 'succeeded', 'artifact': c}])
            self.assertEqual(backup.referenced_digests(export), [a, b])
            write_export(export, runs=[{'status': 'open', 'artifact': '../x'}])
            with self.assertRaises(ValueError):
                backup.referenced_digests(export)
            with zipfile.ZipFile(export, 'w') as z:
                z.writestr('other/documents.jsonl', '{}\n')
            self.assertEqual(backup.referenced_digests(export), [])

    def test_collects_only_referenced_bundles_verified(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            store = root / 'store'
            kept = put_bundle(store, b'open run bundle')
            put_bundle(store, b'collected later', commit='2' * 40)
            target = root / 'out'
            target.mkdir()
            result = backup.collect_artifacts(store, [kept], target)
            self.assertEqual(result['agent_artifacts'], 'bundled')
            self.assertEqual(result['agent_artifact_digests'], [kept])
            files = sorted(str(p.relative_to(target)) for p in target.rglob('*') if p.is_file())
            self.assertEqual(files, [f'builds/hello/{"1" * 40}.json', f'builds/hello/{"1" * 40}.reported',
                                     f'objects/sha256/{kept[7:9]}/{kept[7:]}', 'referenced.json'])
            self.assertEqual(json.loads((target / 'referenced.json').read_text()), [kept])
            # An unrelated damaged record does not stop the collection.
            (store / 'builds' / 'hello' / ('4' * 40 + '.json')).write_text('{torn')
            (store / 'builds' / 'hello' / ('5' * 40 + '.json')).write_text('[]')
            again = root / 'again'
            again.mkdir()
            self.assertEqual(backup.collect_artifacts(store, [kept], again)['agent_artifact_digests'], [kept])
            self.assertTrue((again / 'builds' / 'hello' / ('1' * 40 + '.json')).is_file())
            # A parseable record that eve's restore would refuse stays out.
            record = store / 'builds' / 'hello' / ('1' * 40 + '.json')
            broken = dict(json.loads(record.read_text()), protocol=1)
            record.write_text(json.dumps(broken))
            third = root / 'third'
            third.mkdir()
            self.assertEqual(backup.collect_artifacts(store, [kept], third)['agent_artifact_digests'], [kept])
            self.assertFalse((third / 'builds').exists())
            self.assertEqual(backup.collect_artifacts(store, [], root / 'unused'),
                             {'agent_artifacts': 'none', 'agent_artifact_digests': []})

    def test_missing_or_damaged_referenced_bundle_is_recorded_not_fatal(self):
        """Decided 2026-11-23: the backup finishes without the bundle and the
        health check alerts on the receipt."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            store = root / 'store'
            digest = put_bundle(store, b'bundle')
            kept = put_bundle(store, b'other bundle', commit='2' * 40)
            absent = 'sha256:' + 'e' * 64
            (root / 'a').mkdir()
            result = backup.collect_artifacts(store, [absent, kept], root / 'a')
            self.assertEqual(result['agent_artifacts'], 'incomplete')
            self.assertEqual(result['agent_artifact_digests'], [kept])
            self.assertEqual(result['agent_artifact_missing'], [absent])
            self.assertEqual(json.loads((root / 'a' / 'referenced.json').read_text()), [kept])
            path = store / 'objects' / 'sha256' / digest[7:9] / digest[7:]
            path.write_bytes(b'torn')
            (root / 'b').mkdir()
            result = backup.collect_artifacts(store, [digest], root / 'b')
            self.assertEqual((result['agent_artifact_digests'], result['agent_artifact_missing']), ([], [digest]))
            self.assertFalse((root / 'b' / 'builds').exists())
            path.unlink()
            path.symlink_to(root / 'elsewhere')
            (root / 'elsewhere').write_bytes(b'bundle')
            (root / 'c').mkdir()
            result = backup.collect_artifacts(store, [digest], root / 'c')
            self.assertEqual(result['agent_artifact_missing'], [digest])

    def test_health_flags_a_receipt_without_its_bundles(self):
        health = Path(__file__).with_name('health.py')
        with tempfile.TemporaryDirectory() as d:
            now = __import__('time').time()
            (Path(d) / 'good.json').write_text(json.dumps({'completed_at': now, 'agent_artifact_missing': []}))
            (Path(d) / 'gap.json').write_text(json.dumps({'completed_at': now, 'agent_artifact_missing': ['sha256:' + 'e' * 64]}))
            run = lambda *names: subprocess.run([sys.executable, str(health), d, *names], capture_output=True).returncode
            self.assertEqual(run('good'), 0)
            self.assertEqual(run('good', 'gap'), 2)
            self.assertEqual(run('gap', 'absent'), 3)
            self.assertEqual(run('absent'), 1)

    def test_restore_drill_archive_holds_every_bundle_its_snapshot_needs(self):
        """Backup, extract, verify: the steps of the drill in
        runbooks/black-agent-source.md before eve-deployments' restore."""
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            store = root / 'store'
            digest = put_bundle(store, b'bundle of an open run')
            put_bundle(store, b'unreferenced', commit='3' * 40)
            secrets = root / 'secrets'
            secrets.mkdir()
            for name in ('convex-demo.env', 'convex-demo-admin-key'):
                (secrets / name).write_text('fixture')
            config = root / 'config'
            (config / 'hosts' / 'black' / 'convex').mkdir(parents=True)
            for name in ('flake.lock', 'hosts/black/convex/compose.yaml', 'hosts/black/convex/deployments.nix'):
                (config / name).write_text('fixture')
            export = root / 'export.zip'
            write_export(export, runs=[{'status': 'open', 'artifact': digest}])
            extracted = root / 'extracted'
            def borg(command, **kwargs):
                shutil.copytree(kwargs['cwd'], extracted)
                return subprocess.CompletedProcess(command, 0, stdout=b'{}')
            args = ['backup', 'demo', str(export), '123', '--state', d, '--secrets', str(secrets),
                    '--config', str(config), '--agent-artifacts', str(store)]
            with patch.object(sys, 'argv', args), patch.object(subprocess, 'check_output', return_value=b'{"encryption":{"mode":"repokey-blake2"}}'), patch.object(subprocess, 'run', side_effect=borg):
                backup.main()
            verify = [sys.executable, str(Path(__file__).with_name('verify-restore.py')), str(extracted)]
            result = subprocess.run(verify, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('referenced bundles verified', result.stdout)
            with tarfile.open(extracted / 'recovery.tar') as tar:
                bundles = [n for n in tar.getnames() if n.startswith('agent-artifacts/objects/') and tar.getmember(n).isfile()]
            self.assertEqual(bundles, [f'agent-artifacts/objects/sha256/{digest[7:9]}/{digest[7:]}'])
            # A tampered bundle in the archive fails the drill.
            work = root / 'tampered'
            with tarfile.open(extracted / 'recovery.tar') as tar:
                tar.extractall(work, filter='data')
            (work / bundles[0]).write_bytes(b'tampered')
            with tarfile.open(extracted / 'recovery.tar', 'w') as tar:
                for item in sorted(work.iterdir()):
                    tar.add(item, arcname=item.name)
            result = subprocess.run(verify, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def _archive(self, root, store_digests, referenced, agent_artifacts=True):
        store = root / 'store'
        for data in store_digests:
            put_bundle(store, data, commit=hashlib.sha1(data).hexdigest())
        secrets = root / 'secrets'
        secrets.mkdir()
        for name in ('convex-demo.env', 'convex-demo-admin-key'):
            (secrets / name).write_text('fixture')
        config = root / 'config'
        (config / 'hosts' / 'black' / 'convex').mkdir(parents=True)
        for name in ('flake.lock', 'hosts/black/convex/compose.yaml', 'hosts/black/convex/deployments.nix'):
            (config / name).write_text('fixture')
        export = root / 'export.zip'
        write_export(export, runs=[{'status': 'open', 'artifact': x} for x in referenced])
        extracted = root / 'extracted'
        def borg(command, **kwargs):
            shutil.copytree(kwargs['cwd'], extracted)
            return subprocess.CompletedProcess(command, 0, stdout=b'{}')
        args = ['backup', 'demo', str(export), '123', '--state', str(root), '--secrets', str(secrets),
                '--config', str(config)] + (['--agent-artifacts', str(store)] if agent_artifacts else [])
        with patch.object(sys, 'argv', args), patch.object(subprocess, 'check_output', return_value=b'{"encryption":{"mode":"repokey-blake2"}}'), patch.object(subprocess, 'run', side_effect=borg):
            backup.main()
        verify = [sys.executable, str(Path(__file__).with_name('verify-restore.py')), str(extracted)]
        return subprocess.run(verify, capture_output=True, text=True), json.loads((root / 'demo.json').read_text())

    def test_backup_with_a_missing_bundle_completes_and_verifies_with_a_warning(self):
        with tempfile.TemporaryDirectory() as d:
            present = 'sha256:' + hashlib.sha256(b'present').hexdigest()
            absent = 'sha256:' + 'e' * 64
            result, receipt = self._archive(Path(d), [b'present'], [present, absent])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('lacks: ' + absent, result.stdout)
            self.assertEqual(receipt['agent_artifacts'], 'incomplete')
            self.assertEqual(receipt['agent_artifact_missing'], [absent])

    def test_archive_from_before_the_bundle_backup_is_accepted(self):
        with tempfile.TemporaryDirectory() as d:
            result, receipt = self._archive(Path(d), [], ['sha256:' + 'e' * 64], agent_artifacts=False)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('predates the bundle backup', result.stdout)
            self.assertNotIn('agent_artifacts', receipt)


class PublicKeyTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('age') and shutil.which('age-keygen'), 'age integration tools required')
    def test_only_ciphertext_reaches_borg(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(['age-keygen', '-o', str(root / 'identity')], check=True, stderr=subprocess.DEVNULL)
            public = subprocess.check_output(['age-keygen', '-y', str(root / 'identity')])
            (root / 'recipient').write_bytes(public)
            secrets = root / 'secrets'
            secrets.mkdir()
            for name in ('convex-demo.env', 'convex-demo-admin-key'):
                (secrets / name).write_text('private recovery fixture')
            export = root / 'export.zip'
            with zipfile.ZipFile(export, 'w') as z:
                z.writestr('table/documents.jsonl', '{}')
            args = ['backup', 'demo', str(export), '123', '--state', d,
                    '--secrets', str(secrets), '--config', str(secrets),
                    '--age-recipient-file', str(root / 'recipient')]
            def record_borg(command, **kwargs):
                self.assertEqual(command[-1], 'payload.tar.age')
                self.assertNotIn('export.zip', command)
                shutil.copyfile(Path(kwargs['cwd']) / 'payload.tar.age', root / 'saved.age')
                return subprocess.CompletedProcess(command, 0, stdout=b'{}')
            with patch.object(sys, 'argv', args), patch.object(subprocess, 'check_output', return_value=b'{"encryption":{"mode":"repokey-blake2"}}'), patch.object(subprocess, 'run', side_effect=record_borg):
                backup.main()
            plaintext = subprocess.check_output(['age', '-d', '-i', str(root / 'identity'), str(root / 'saved.age')])
            with tarfile.open(fileobj=io.BytesIO(plaintext)) as tar:
                self.assertEqual(set(tar.getnames()), {'export.zip', 'recovery.tar', 'manifest.json'})
                self.assertEqual(tar.extractfile('export.zip').read(), export.read_bytes())

class AlertTest(unittest.TestCase):
    def test_pushover_delivery_and_rejection(self):
        spec = importlib.util.spec_from_file_location('alert', Path(__file__).with_name('alert.py'))
        alert = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(alert)
        from unittest.mock import MagicMock
        response = MagicMock()
        response.__enter__.return_value = io.BytesIO(b'{"status":1}')
        config = {'pushover': {'token': 'test-app-token', 'user': 'test-user-key'}}
        with patch.object(alert.urllib.request, 'urlopen', return_value=response) as send:
            alert.send(config)
            self.assertEqual(send.call_args.args[0], 'https://api.pushover.net/1/messages.json')
        with patch.object(alert.urllib.request, 'urlopen', side_effect=OSError('private value')):
            with self.assertRaisesRegex(RuntimeError, '^Backup alert delivery failed: Pushover$'):
                alert.send(config)

    def test_fixed_messages_accept_only_a_hosted_runner_unit(self):
        spec = importlib.util.spec_from_file_location('alert', Path(__file__).with_name('alert.py'))
        alert = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(alert)
        self.assertEqual(alert.fixed_message([]), alert.STALE)
        self.assertEqual(alert.fixed_message(['retention']), alert.RETENTION)
        title, message = alert.fixed_message(['hosted-runner', 'hosted-runner-june-prod.service'])
        self.assertEqual(title, 'Hosted runner failed')
        self.assertIn('hosted-runner-june-prod.service is failed', message)
        for args in (['hosted-runner', 'sshd.service'], ['hosted-runner', 'hosted-runner-x.service; rm'], ['hosted-runner'], ['other']):
            with self.assertRaises(SystemExit):
                alert.fixed_message(args)

class HealthTest(unittest.TestCase):
    def test_missing_fresh_stale_and_future_receipts(self):
        with tempfile.TemporaryDirectory() as d:
            command = [sys.executable, str(Path(__file__).with_name('health.py')), d, 'demo']
            def status():
                return subprocess.run(command, capture_output=True).returncode
            self.assertEqual(status(), 1)
            for age, expected in [(60, 0), (37 * 3600, 1), (-3600, 1)]:
                (Path(d) / 'demo.json').write_text(json.dumps({'completed_at': time.time() - age}))
                self.assertEqual(status(), expected)

if __name__ == '__main__':
    unittest.main()
