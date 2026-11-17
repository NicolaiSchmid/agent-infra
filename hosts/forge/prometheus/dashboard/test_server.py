import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('dashboard', Path(__file__).with_name('server.py'))
s = importlib.util.module_from_spec(spec)
spec.loader.exec_module(s)


class QuotaTests(unittest.TestCase):
    def test_provider_windows_remain_separate(self):
        windows = s.normalize('claude', {'five_hour': {'utilization': 35, 'resets_at': '2026-11-08T10:00:00Z'}, 'seven_day': {'utilization': 80}, 'seven_day_sonnet': {'utilization': 10}})
        self.assertEqual([w['remaining'] for w in windows], [65, 20, 90])
        self.assertEqual(windows[0]['reset'], 1794132000)

    def test_codex_classifies_by_duration_and_rejects_nan(self):
        windows = s.normalize('codex', {'rate_limit': {'primary_window': {'used_percent': 25, 'limit_window_seconds': 604800, 'reset_at': 100}, 'secondary_window': {'used_percent': float('nan')}}})
        self.assertEqual(windows, [{'name': 'seven_day', 'remaining': 75, 'reset': 100}])
        self.assertIsNone(s.window('x', None, None))

    def test_errors_preserve_last_good_data_without_new_samples(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(s, 'DATA', Path(directory)):
            s.init()
            good = {'id': 'a', 'provider': 'codex', 'label': 'account', 'disabled': False, 'windows': [{'name': 'seven_day', 'remaining': 72, 'reset': 100}], 'observed': 123, 'error': None}
            file = {'provider': 'codex'}
            with patch.object(s, 'api', return_value={'files': [file]}), patch.object(s, 'fetch_account', return_value=good):
                s.collect()
            bad = dict(good, windows=[], observed=None, error='Provider returned HTTP 401')
            with patch.object(s, 'api', return_value={'files': [file]}), patch.object(s, 'fetch_account', return_value=bad):
                s.collect()
            result = s.state()
            self.assertEqual(result['accounts'][0]['observed'], 123)
            self.assertEqual(result['accounts'][0]['windows'][0]['remaining'], 72)
            self.assertEqual(len(result['history']), 1)
            self.assertIn('401', result['accounts'][0]['error'])

    def test_provider_failure_does_not_leak_response_body(self):
        file = {'type': 'claude', 'auth_index': 'test', 'email': 'test@example.com'}
        with patch.object(s, 'api', return_value={'status_code': 401, 'body': 'SECRET_TOKEN'}):
            account = s.fetch_account(file)
        self.assertNotIn('SECRET_TOKEN', json.dumps(account))
        self.assertEqual(account['error'], 'Provider returned HTTP 401')

    def test_disabled_account_never_calls_upstream(self):
        with patch.object(s, 'api') as api:
            account = s.fetch_account({'type': 'codex', 'auth_index': '1', 'disabled': True})
        api.assert_not_called()
        self.assertTrue(account['disabled'])


if __name__ == '__main__':
    unittest.main()
