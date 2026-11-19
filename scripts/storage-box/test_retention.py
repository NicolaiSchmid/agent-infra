import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('retention', Path(__file__).with_name('retention.py'))
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


def archive(name, start='2026-11-19T03:30:00.000000'):
    return {'id': 'id-' + name, 'archive': name, 'start': start}


class FakeBorg:
    """Repository double: prune drops the oldest of each series beyond one."""

    def __init__(self, archives):
        self.archives = list(archives)
        self.calls = []

    def __call__(self, *args, capture=True, lock_wait=600):
        self.calls.append(args)
        if args[0] == 'list':
            return json.dumps({'archives': self.archives})
        if args[0] == 'prune' and '--dry-run' not in args:
            prefix = args[args.index('--glob-archives') + 1].removesuffix('-[0-9]*') + '-'
            series = [a for a in self.archives if a['archive'].startswith(prefix)
                      and a['archive'][len(prefix):].isdigit()]
            for old in series[:-1]:
                self.archives.remove(old)
        return None

    def commands(self):
        return [call[0] for call in self.calls]


class RetentionTest(unittest.TestCase):
    def run_job(self, fake, state, *extra):
        with patch.dict(os.environ, {'BORG_REPO': 'fixture'}), patch.object(retention, 'borg', fake):
            retention.main(['--state', str(state), '--keep-daily', '30', *extra])
        return json.loads((Path(state) / 'last-run.json').read_text())

    def test_dry_run_prunes_nothing_and_records_baseline(self):
        fake = FakeBorg([archive('june-dev-1'), archive('june-dev-2'), archive('june-dev-extra-3')])
        with tempfile.TemporaryDirectory() as d:
            receipt = self.run_job(fake, d, '--dry-run')
            self.assertEqual(receipt['series'], ['june-dev', 'june-dev-extra'])
            self.assertEqual(receipt['pruned'], [])
            self.assertFalse(receipt['compacted'])
            self.assertNotIn('compact', fake.commands())
            prunes = [c for c in fake.calls if c[0] == 'prune']
            self.assertTrue(all('--dry-run' in c for c in prunes))
            # Series globs never match a longer series name.
            self.assertIn('june-dev-[0-9]*', prunes[0])
            self.assertEqual(len(json.loads((Path(d) / 'archives.json').read_text())), 3)

    def test_first_real_run_defers_compaction(self):
        fake = FakeBorg([archive('june-prod-1'), archive('june-prod-2')])
        with tempfile.TemporaryDirectory() as d:
            receipt = self.run_job(fake, d)
            self.assertEqual(receipt['pruned'], ['june-prod-1'])
            self.assertFalse(receipt['compacted'])
            fake.archives.append(archive('june-prod-3'))
            receipt = self.run_job(fake, d)
            self.assertEqual(receipt['pruned'], ['june-prod-2'])
            self.assertTrue(receipt['compacted'])

    def test_unexpected_deletion_stops_before_prune_and_compact(self):
        fake = FakeBorg([archive('modus-gateway-prod-1'), archive('modus-gateway-prod-2')])
        with tempfile.TemporaryDirectory() as d:
            self.run_job(fake, d, '--dry-run')
            receipt_before = (Path(d) / 'last-run.json').read_text()
            fake.archives = fake.archives[1:]  # a writer-side logical delete
            fake.calls.clear()
            with self.assertRaises(retention.UnexpectedDeletion):
                self.run_job(fake, d)
            self.assertEqual(fake.commands(), ['list'])
            self.assertEqual((Path(d) / 'last-run.json').read_text(), receipt_before)

    def test_rejects_unknown_archive_names(self):
        fake = FakeBorg([archive('june-dev-1'), archive('manual-copy')])
        with tempfile.TemporaryDirectory() as d, self.assertRaises(ValueError):
            self.run_job(fake, d, '--dry-run')
        self.assertNotIn('prune', fake.commands())

    def test_reports_over_age_survivors(self):
        fake = FakeBorg([archive('modus-dev-1', '2026-01-01T00:00:00.000000'), archive('june-dev-2', '2999-01-01T00:00:00.000000')])
        with tempfile.TemporaryDirectory() as d:
            receipt = self.run_job(fake, d, '--dry-run')
            self.assertEqual(receipt['over_age'], ['modus-dev-1'])

    def test_refuses_zero_keep(self):
        with tempfile.TemporaryDirectory() as d, self.assertRaises(ValueError):
            retention.main(['--state', d, '--keep-daily', '0'])


if __name__ == '__main__':
    unittest.main()
