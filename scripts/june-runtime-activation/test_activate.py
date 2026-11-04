import copy
import io
import tarfile
import hashlib
import importlib.util
import json
import unittest
import tempfile
from contextlib import ExitStack
from unittest.mock import patch
from pathlib import Path

spec = importlib.util.spec_from_file_location('activate', Path(__file__).with_name('activate.py'))
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)


class PreservationTests(unittest.TestCase):
    def setUp(self):
        self.container = {
            'Id': 'old', 'Image': 'old-image', 'Mounts': [{'Source': 'occupied'}],
            'HostConfig': {'Memory': 123, 'Binds': ['occupied:/convex/data:rw']},
            'Config': {'Image': 'old-ref', 'User': 'backend', 'WorkingDir': '/convex',
                       'Env': ['NODE_ACTION_USER_TIMEOUT_SECS=800', 'HTTP_SERVER_TIMEOUT_SECONDS=1800', 'PRIVATE=value'],
                       'Labels': {'base': 'old', 'custom': 'keep', 'com.docker.compose.image': 'old-image'}},
            'NetworkSettings': {'Networks': {'net': {'Aliases': ['backend'], 'IPAMConfig': None, 'Links': None, 'DriverOpts': None}}},
            'State': {'Running': True, 'Status': 'running', 'Health': {'Status': 'healthy'}, 'StartedAt': 'now'},
        }
        self.before = {'june': self.container, 'config': {'services': {'backend': {'image': 'old-ref', 'labels': {'custom': 'keep'}, 'environment': {'NODE_ACTION_USER_TIMEOUT_SECS': '800', 'HTTP_SERVER_TIMEOUT_SECONDS': '1800'}}}},
                       'others': {'other': ['id', 'started']}, 'routes': {'route': 'digest'}, 'cap': 'capacity', 'old_drop': 'drop', 'old_overlay': 'overlay'}

    def image_inspect(self, args):
        config = {'Labels': {'base': 'new', 'source': 'pinned'}} if args[-1] == a.TARGET else {'Labels': {'base': 'old'}}
        return json.dumps([{'Config': config}]).encode()

    def test_saved_image_requires_exact_manifest_and_config_bytes(self):
        config = b'{"runtime":"accepted"}'
        config_id = 'sha256:' + hashlib.sha256(config).hexdigest()
        manifest = json.dumps({'config': {'digest': config_id}}).encode()
        manifest_id = 'sha256:' + hashlib.sha256(manifest).hexdigest()
        for corrupt, missing in [(False, False), (True, False), (False, True)]:
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w') as archive:
                for digest, content in [(manifest_id, manifest), (config_id, config)]:
                    if missing and digest == config_id:
                        continue
                    payload = b'wrong' if corrupt and digest == config_id else content
                    member = tarfile.TarInfo('blobs/sha256/' + digest.split(':')[1])
                    member.size = len(payload)
                    archive.addfile(member, io.BytesIO(payload))
            stream.seek(0)
            with self.subTest(corrupt=corrupt, missing=missing), patch.object(a, 'TARGET_ID', manifest_id), patch.object(a, 'CONFIG_ID', config_id):
                if corrupt or missing:
                    with self.assertRaises(RuntimeError):
                        a.verify_saved_blobs(stream)
                else:
                    a.verify_saved_blobs(stream)

    def test_dropin_has_real_lines_and_only_scoped_commands(self):
        lines = a.dropin_text().splitlines()
        self.assertEqual(lines, ['[Service]', 'ExecStart=', 'ExecStart=' + ' '.join(a.NEW + a.UP),
                                 'ExecReload=', 'ExecReload=' + ' '.join(a.NEW + a.UP)])
        self.assertNotIn(chr(92) + 'n', a.dropin_text())
        self.assertTrue(a.dropin_text().endswith(chr(10)))

    def rollback_fixture(self, directory, current):
        root = Path(directory)
        self.before['unit'] = {'DropInPaths': 'baseline', 'User': 'root'}
        (root / 'before.json').write_text(json.dumps(self.before))
        files = {'CAP': 'capacity', 'OLD_DROP': 'drop', 'OLD_OVERLAY': 'overlay'}
        stack = ExitStack()
        stack.enter_context(patch.object(a, 'ROOT', root))
        stack.enter_context(patch.object(a, 'DROP', root / 'new-drop'))
        for key, value in files.items():
            path = root / key
            path.write_text(value)
            stack.enter_context(patch.object(a, key, path))
        stack.enter_context(patch.object(a, 'config', return_value=self.before['config']))
        stack.enter_context(patch.object(a, 'snapshot', return_value=current))
        stack.enter_context(patch.object(a, 'unit_state', return_value=self.before['unit']))
        return stack

    def test_rollback_unit_drift_causes_zero_mutations(self):
        current = copy.deepcopy(self.before)
        current.update(june=None, renamed=[self.container], unit={'DropInPaths': 'unknown'})
        with tempfile.TemporaryDirectory() as d, self.rollback_fixture(d, current), patch.object(a, 'run') as run, patch.object(a, 'stage') as stage:
            with self.assertRaisesRegex(RuntimeError, 'unit drift'):
                a.main('rollback')
            run.assert_not_called()
            stage.assert_not_called()

    def test_interrupted_compose_restores_only_saved_old_container(self):
        current = copy.deepcopy(self.before)
        current.update(june=None, renamed=[self.container], unit={'DropInPaths': 'baseline', 'User': 'root'})
        with tempfile.TemporaryDirectory() as d, self.rollback_fixture(d, current), patch.object(a, 'run') as run, patch.object(a, 'verify') as verify:
            a.main('rollback')
            self.assertEqual([call.args[0] for call in run.call_args_list],
                             [[a.D, 'rename', 'old', a.NAME], ['systemctl', 'daemon-reload']])
            verify.assert_called_once()
            self.assertEqual(verify.call_args.args[1], False)

    def test_only_reviewed_image_metadata_and_timeouts_change(self):
        saved = copy.deepcopy(self.before)
        with patch.object(a, 'run', self.image_inspect):
            runtime = a.expected_runtime(self.before, True)
        self.assertEqual(runtime['Image'], a.TARGET_ID)
        self.assertEqual(runtime['config']['Image'], a.TARGET)
        self.assertEqual(runtime['config']['Labels']['custom'], 'keep')
        self.assertEqual(runtime['HostConfig'], self.container['HostConfig'])
        self.assertEqual(runtime['Mounts'], self.container['Mounts'])
        self.assertEqual(a.expected_env(self.before, True), {'NODE_ACTION_USER_TIMEOUT_SECS': '1800', 'HTTP_SERVER_TIMEOUT_SECONDS': '2100', 'PRIVATE': 'value'})
        self.assertEqual(self.before, saved)

    def test_compose_proposal_rejects_unrelated_change(self):
        changed = copy.deepcopy(self.before['config'])
        changed['services']['backend']['image'] = a.TARGET
        changed['services']['backend']['environment'].update(NODE_ACTION_USER_TIMEOUT_SECS='1800', HTTP_SERVER_TIMEOUT_SECONDS='2100')
        with patch.object(a, 'config', return_value=changed):
            a.proposed(self.before)
        changed['services']['backend']['mem_limit'] = 999
        with patch.object(a, 'config', return_value=changed), self.assertRaisesRegex(RuntimeError, 'differs beyond'):
            a.proposed(self.before)

    def test_postcheck_rejects_route_other_container_and_secret_drift(self):
        for kind in ['routes', 'others', 'secret', 'mount']:
            after = copy.deepcopy(self.before)
            if kind in ['routes', 'others']:
                after[kind] = {'changed': 'value'}
            elif kind == 'secret':
                after['june']['Config']['Env'][-1] = 'PRIVATE=changed'
            else:
                after['june']['Mounts'][0]['Source'] = 'empty'
            with self.subTest(kind=kind), patch.object(a, 'snapshot', return_value=after), self.assertRaises(RuntimeError):
                a.verify(self.before, False)


if __name__ == '__main__':
    unittest.main()
