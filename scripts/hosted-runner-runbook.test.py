"""Execute the documented deployment block with fake external commands only."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RUNBOOK = Path(__file__).resolve().parents[1] / "runbooks/black-hosted-runner.md"


class DiskGateTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="e5-runbook-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands"
        self.log.touch()
        (self.root / "remote").mkdir()
        scripts = {
            "gh": '''#!/bin/sh
case "$*" in
  *merge_commit_sha*) echo synthetic-merge;;
  *.merged*) echo "${E5_MERGED:-true}";;
esac
''',
            "df": f'''#!{sys.executable}
import os
from pathlib import Path
import sys
if '--output=avail' in sys.argv:
    counter = Path(os.environ['E5_CASE']) / 'df-count'
    n = int(counter.read_text()) if counter.exists() else 0
    counter.write_text(str(n + 1))
    values = os.environ['E5_FREE_KIB'].split(',')
    print('Avail\\n' + values[min(n, len(values) - 1)])
else:
    print('synthetic disk fixture')
''',
            "ssh": f'''#!{sys.executable}
import os
import shlex
import subprocess
import sys
from pathlib import Path
assert sys.argv[1] == 'root@black'
command = shlex.join(sys.argv[2:]) if len(sys.argv) > 3 else sys.argv[2]
command = command.replace('/root/hosted-runner', os.environ['E5_CASE'] + '/remote')
if len(sys.argv) > 3:
    script = sys.stdin.read().replace('/root/hosted-runner', os.environ['E5_CASE'] + '/remote')
    result = subprocess.run(['sh', '-c', command], input=script, text=True)
else:
    result = subprocess.run(['sh', '-c', command])
sys.exit(result.returncode)
''',
            "nixos-rebuild": '''#!/bin/sh
echo "nixos-rebuild $*" >> "$E5_COMMAND_LOG"
test "${E5_FAIL:-}" != "$1"
''',
            "docker": '''#!/bin/sh
echo "docker $*" >> "$E5_COMMAND_LOG"
test "${E5_FAIL:-}" != "$1" || exit 1
case "$1" in ps) echo synthetic-june-container;; esac
''',
            "readlink": '''#!/bin/sh
test "${E5_FAIL:-}" != snapshot || exit 1
echo /nix/store/synthetic-previous-system
''',
            "jq": "#!/bin/sh\necho node@sha256:synthetic-digest\n",
            "systemctl": "#!/bin/sh\nexit 0\n",
            "journalctl": "#!/bin/sh\nexit 0\n",
        }
        # Restrict PATH to fixtures plus the handful of harmless shell utilities
        # the block needs. A missing mock must never invoke real SSH or Nix.
        for name in ["sh", "tail", "cat"]:
            (self.bin / name).symlink_to(shutil.which(name))
        for name, script in scripts.items():
            path = self.bin / name
            path.write_text(script)
            path.chmod(0o700)
        self.deployment = RUNBOOK.read_text().split("## Night deployment and rollback", 1)[1].split("```sh\n", 1)[1].split("```", 1)[0]

    def execute(self, free="26214400", fail="", merged="true", errexit=False):
        self.log.write_text("")
        (self.root / "df-count").unlink(missing_ok=True)
        result = subprocess.run(
            [shutil.which("sh"), *(["-e"] if errexit else []), "-c", self.deployment],
            env={**os.environ, "PATH": str(self.bin), "E5_CASE": str(self.root),
                 "E5_COMMAND_LOG": str(self.log), "E5_FREE_KIB": free,
                 "E5_FAIL": fail, "E5_MERGED": merged},
            capture_output=True, text=True, timeout=10,
        )
        return result, self.log.read_text()

    def test_low_disk_prevents_build_pull_and_switch_in_ordinary_shell(self):
        result, commands = self.execute(free="9564032")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("nixos-rebuild", commands)
        self.assertNotIn("docker pull", commands)

    def test_space_lost_before_switch_aborts_with_or_without_outer_errexit(self):
        for errexit in [False, True]:
            with self.subTest(errexit=errexit):
                result, commands = self.execute(free="30000000,30000000,9564032", errexit=errexit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("nixos-rebuild build", commands)
                self.assertIn("docker pull", commands)
                self.assertNotIn("nixos-rebuild switch", commands)

    def test_space_lost_during_build_prevents_pull_and_switch(self):
        result, commands = self.execute(free="30000000,9564032")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("nixos-rebuild build", commands)
        self.assertNotIn("docker pull", commands)
        self.assertNotIn("nixos-rebuild switch", commands)

    def test_merge_build_pull_and_snapshot_failures_prevent_switch(self):
        for failure in ["merge", "build", "pull", "snapshot"]:
            with self.subTest(failure=failure):
                result, commands = self.execute(fail=failure, merged="false" if failure == "merge" else "true")
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("nixos-rebuild switch", commands)

    def test_threshold_allows_exact_pinned_switch_after_snapshots(self):
        result, commands = self.execute()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("nixos-rebuild switch --flake github:NicolaiSchmid/agent-infra/synthetic-merge#black", commands)
        self.assertTrue((self.root / "remote/pre-e5-system").exists())
        self.assertTrue((self.root / "remote/pre-e5-containers").exists())


if __name__ == "__main__":
    unittest.main()
