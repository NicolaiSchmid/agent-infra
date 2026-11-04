import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import subprocess
import sys
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

if __name__ == '__main__':
    unittest.main()
