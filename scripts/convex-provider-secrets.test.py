#!/usr/bin/env python3
"""Behavioral tests; fake credentials only, no network."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("delivery", Path(__file__).with_name("convex-provider-secrets.py"))
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class SecretDeliveryTests(unittest.TestCase):
    def test_rejects_unknown_empty_and_nonstring_values(self):
        for value in ({}, {"OTHER": "fake"}, {"IONOS_API_KEY": ""}, {"IONOS_API_KEY": 1}, []):
            with self.subTest(value=value), self.assertRaises(ValueError):
                delivery.changes_from_text(json.dumps(value))

    def test_protected_file_and_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            filename = Path(directory) / "secret"
            filename.write_text("fake-secret")
            filename.chmod(0o600)
            self.assertEqual(delivery.protected_text(filename), "fake-secret")
            filename.chmod(0o644)
            with self.assertRaises(ValueError):
                delivery.protected_text(filename)
            filename.chmod(0o600)
            link = Path(directory) / "link"
            link.symlink_to(filename)
            with self.assertRaises(OSError):
                delivery.protected_text(link)

    def test_posts_only_selected_changes_to_fixed_target(self):
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): pass
        class Opener:
            def open(self, request, timeout):
                self.request = request
                return Response()
        opener = Opener()
        changes = delivery.changes_from_text('{"TSYSTEMS_API_KEY_SECONDARY":"fake-provider-key"}')
        delivery.deliver("dev", "fake-admin", changes, opener)
        self.assertEqual(opener.request.full_url, delivery.DEPLOYMENTS["dev"] + "/api/update_environment_variables")
        self.assertEqual(opener.request.get_header("Authorization"), "Convex fake-admin")
        self.assertEqual(json.loads(opener.request.data), {"changes": changes})

    def test_redirects_are_refused(self):
        self.assertIsNone(delivery.NoRedirect().redirect_request(None, None, 302, "", {}, "https://other.invalid"))

    def test_failure_does_not_echo_input_or_exception(self):
        with tempfile.TemporaryDirectory() as directory:
            secret = Path(directory) / "secret"
            admin = Path(directory) / "admin"
            secret.write_text('{"IONOS_API_KEY":"fake-provider-key"}')
            admin.write_text("fake-admin")
            secret.chmod(0o600)
            admin.chmod(0o600)
            output = io.StringIO()
            argv = ["delivery", "--deployment", "dev", "--secrets-file", str(secret), "--admin-key-file", str(admin)]
            with patch("sys.argv", argv), patch.object(delivery, "deliver", side_effect=ValueError("fake-provider-key fake-admin")), contextlib.redirect_stderr(output):
                self.assertEqual(delivery.main(), 1)
            self.assertNotIn("fake-provider-key", output.getvalue())
            self.assertNotIn("fake-admin", output.getvalue())

    def test_check_does_not_connect(self):
        with tempfile.TemporaryDirectory() as directory:
            secret = Path(directory) / "secret"
            admin = Path(directory) / "admin"
            secret.write_text('{"IONOS_API_KEY":"fake-provider-key"}')
            admin.write_text("fake-admin")
            secret.chmod(0o600)
            admin.chmod(0o600)
            argv = ["delivery", "--deployment", "dev", "--secrets-file", str(secret), "--admin-key-file", str(admin), "--check"]
            with patch("sys.argv", argv), patch.object(delivery, "deliver") as network, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(delivery.main(), 0)
                network.assert_not_called()


if __name__ == "__main__":
    unittest.main()
