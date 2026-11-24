"""Argument validation and request shape of scripts/june-alert.py; no network."""
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
import urllib.error


spec = importlib.util.spec_from_file_location('june_alert', Path(__file__).with_name('june-alert.py'))
june_alert = importlib.util.module_from_spec(spec)
spec.loader.exec_module(june_alert)

KEY = 'synthetic-runner-key'


def response(payload, status=200):
    mock = MagicMock()
    mock.__enter__.return_value = mock
    mock.status = status
    mock.read.return_value = json.dumps(payload).encode()
    return mock


class ValidateTest(unittest.TestCase):
    def test_accepts_the_fixed_checks(self):
        for args in (['june-dev', 'runner-unit', 'hosted-runner-june-dev.service', 'firing'],
                     ['june-prod', 'product-backup', '', 'resolved'],
                     ['june-prod', 'product-backup-bundles', '', 'firing'],
                     ['june-prod', 'executor-db', 'executor-db-june-dev-health.service', 'firing'],
                     ['june-prod', 'executor-db', 'executor-db-june-prod-backup.service', 'resolved']):
            with self.subTest(args=args):
                self.assertEqual(june_alert.validate(args), tuple(args))

    def test_rejects_everything_else(self):
        for args in ([],
                     ['june-dev', 'runner-unit', 'hosted-runner-june-dev.service'],
                     ['June_Dev', 'product-backup', '', 'firing'],
                     ['june-prod', 'product-backup', '', 'open'],
                     ['june-prod', 'product-backup', 'free text', 'firing'],
                     ['june-prod', 'retention', '', 'firing'],
                     ['june-prod', 'runner-unit', 'hosted-runner-june-dev.service', 'firing'],
                     ['june-dev', 'runner-unit', 'sshd.service', 'firing'],
                     ['june-prod', 'executor-db', 'executor-db-june-prod.service', 'firing'],
                     ['june-prod', 'executor-db', 'executor-db-x-health.service; rm', 'firing'],
                     ['june-prod', 'executor-db', 'hosted-runner-june-prod.service', 'firing']):
            with self.subTest(args=args):
                with self.assertRaises(SystemExit):
                    june_alert.validate(args)


class ReportTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.keys = Path(temporary.name)
        (self.keys / 'june-prod-runner.key').write_text(KEY + '\n')
        patcher = patch.object(june_alert, 'KEY_DIR', self.keys)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_posts_the_mutation_with_the_runner_key(self):
        with patch.object(june_alert.urllib.request, 'urlopen', return_value=response({'status': 'success', 'value': None})) as send:
            june_alert.report('june-prod', 'executor-db', 'executor-db-june-prod-health.service', 'firing')
        sent = send.call_args.args[0]
        self.assertEqual(send.call_args.kwargs['timeout'], 30)
        self.assertEqual(sent.full_url, 'https://june-prod.convex.modusservice.com/api/mutation')
        self.assertEqual(sent.get_method(), 'POST')
        self.assertEqual(sent.get_header('Content-type'), 'application/json')
        self.assertEqual(json.loads(sent.data), {
            'path': 'hostedRuns/alerts:report', 'format': 'json',
            'args': {'runnerKey': KEY, 'check': 'executor-db',
                     'subject': 'executor-db-june-prod-health.service', 'state': 'firing'}})

    def test_failures_exit_without_the_key(self):
        cases = {
            'error status': dict(return_value=response({'status': 'error', 'errorMessage': KEY})),
            'non-200': dict(return_value=response({'status': 'success'}, status=500)),
            'http error': dict(side_effect=urllib.error.HTTPError('u', 400, KEY, {}, io.BytesIO(KEY.encode()))),
            'network': dict(side_effect=OSError(KEY)),
        }
        for name, behaviour in cases.items():
            with self.subTest(name=name):
                with patch.object(june_alert.urllib.request, 'urlopen', **behaviour):
                    with self.assertRaises(SystemExit) as raised:
                        june_alert.report('june-prod', 'product-backup', '', 'resolved')
                self.assertNotIn(KEY, str(raised.exception.code))
                self.assertIsNone(raised.exception.__cause__)

    def test_missing_key_fails_before_any_request(self):
        with patch.object(june_alert.urllib.request, 'urlopen') as send:
            with self.assertRaises(SystemExit):
                june_alert.report('june-dev', 'runner-unit', 'hosted-runner-june-dev.service', 'firing')
        send.assert_not_called()


if __name__ == '__main__':
    unittest.main()
