"""Pin recovery behavior observed during the service-only activation trial."""
import importlib.util
import pathlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('activation', pathlib.Path(__file__).with_name('activate-routing-only.py'))
activation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activation)

class DiscoveryHealthTest(unittest.TestCase):
    def test_discovery_gap_recovers_without_rollback(self):
        with patch.object(activation, 'run', side_effect=[subprocess.CalledProcessError(22, 'curl'), '204']) as request, patch.object(activation.time, 'sleep'):
            activation.verify_health()
            self.assertEqual(request.call_count, 2)

    def test_non_health_success_does_not_pass(self):
        with patch.object(activation, 'run', return_value='200'), patch.object(activation.time, 'monotonic', side_effect=[0, 61]):
            with self.assertRaises(RuntimeError):
                activation.verify_health()

    def test_failed_requests_are_bounded(self):
        with patch.object(activation, 'run', side_effect=subprocess.CalledProcessError(7, 'curl')), patch.object(activation.time, 'monotonic', side_effect=[0, 61]):
            with self.assertRaises(RuntimeError):
                activation.verify_health()

if __name__ == '__main__':
    unittest.main()
