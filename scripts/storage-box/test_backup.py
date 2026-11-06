import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
import shutil
import io
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
                with patch.object(subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, stdout=b'{}')):
                    backup.main()
                self.assertTrue((root / 'demo.json').exists())
                self.assertTrue(export.exists())

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
