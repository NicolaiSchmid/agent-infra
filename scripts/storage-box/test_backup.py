import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
import shutil
import io
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
