import runpy
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

checked_step = runpy.run_path(str(Path(__file__).with_name('checked-routing-step.py')))['checked_step']


class CheckedStep(unittest.TestCase):
    def test_failed_readiness_never_runs_mutation(self):
        with tempfile.TemporaryDirectory(prefix='checked-routing-936258ad-') as directory:
            marker = Path(directory) / 'mutation'
            mutation = [sys.executable, '-c', 'from pathlib import Path; import sys; Path(sys.argv[1]).touch()', str(marker)]
            with self.assertRaises(subprocess.CalledProcessError):
                checked_step([[sys.executable, '-c', 'raise SystemExit(7)']], mutation)
            self.assertFalse(marker.exists())

    def test_all_checks_must_pass_in_order(self):
        with tempfile.TemporaryDirectory(prefix='checked-routing-936258ad-') as directory:
            marker = Path(directory) / 'steps'
            def append(value):
                return [sys.executable, '-c', 'from pathlib import Path; import sys; p=Path(sys.argv[1]); p.write_text((p.read_text() if p.exists() else "")+sys.argv[2])', str(marker), value]
            checked_step([append('1'), append('2')], append('3'))
            self.assertEqual(marker.read_text(), '123')


if __name__ == '__main__':
    unittest.main()
