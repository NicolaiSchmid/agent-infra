"""Targeted checks for preserving updater-owned state across Nix starts."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "hosts/atlas/t3code-bootstrap.sh"


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.home = root / "home"
        self.runtime = root / "bootstrap"
        self.runtime.mkdir()
        (self.runtime / "t3").write_text("#!/bin/sh\nexit 0\n")
        (self.runtime / "t3").chmod(0o555)
        (self.runtime / ".install-complete").write_text("0.1.0\n")
        (self.runtime / "client").mkdir()
        (self.runtime / "client/index.html").write_text("bundled client")
        self.state = self.home / "runtime/service-state.json"

    def run_bootstrap(self, version="0.1.0"):
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.home), str(self.runtime), version],
            check=True, capture_output=True, text=True,
        )

    def test_fresh_home_gets_complete_writable_runtime_and_private_state(self):
        self.run_bootstrap()
        self.assertEqual(json.loads(self.state.read_text()), {
            "protocol": 3, "activeVersion": "0.1.0",
        })
        installed = self.home / "runtime/versions/0.1.0"
        self.assertEqual((installed / "client/index.html").read_text(), "bundled client")
        self.assertTrue((installed / "t3").stat().st_mode & 0o200)
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list((self.home / "runtime").glob(".bootstrap.*")), [])

    def test_restart_and_new_nix_pin_preserve_update_and_rollback_state(self):
        self.run_bootstrap()
        for status in ("pending", "committed", "rolled-back", "failed"):
            with self.subTest(status=status):
                state = json.dumps({
                    "protocol": 3, "activeVersion": "0.2.0",
                    "update": {"id": "update-1", "status": status},
                })
                self.state.write_text(state)
                self.run_bootstrap("0.3.0")
                self.assertEqual(self.state.read_text(), state)
                self.assertFalse((self.home / "runtime/versions/0.3.0").exists())

    def test_incomplete_runtime_fails_without_publishing_state(self):
        incomplete = self.home / "runtime/versions/0.1.0"
        incomplete.mkdir(parents=True)
        (incomplete / "t3").write_text("incomplete")
        with self.assertRaises(subprocess.CalledProcessError):
            self.run_bootstrap()
        self.assertFalse(self.state.exists())

    def test_completed_runtime_survives_interrupted_state_initialization(self):
        self.run_bootstrap()
        executable = self.home / "runtime/versions/0.1.0/t3"
        inode = executable.stat().st_ino
        self.state.unlink()
        self.run_bootstrap()
        self.assertEqual(executable.stat().st_ino, inode)
        self.assertEqual(json.loads(self.state.read_text())["activeVersion"], "0.1.0")


if __name__ == "__main__":
    unittest.main()
