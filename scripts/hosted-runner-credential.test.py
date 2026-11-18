"""Atlas-only focused check: real private bundle, real systemd, synthetic key.

Usage: python3 scripts/hosted-runner-credential.test.py --runner /path/runner.mjs
Requires non-root invocation and passwordless sudo for temporary systemd units.
No Docker daemon or June deployment is contacted. The bundle stays private;
public CI cannot fetch it. See the runbook for the pinned artifact download.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import pwd
import secrets
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runner", required=True, type=Path)
    args = parser.parse_args()
    assert os.getuid() != 0, "Run as a non-root service-account fixture"
    repo = Path(__file__).resolve().parents[1]
    module = (repo / "hosts/black/hosted-runner.nix").read_text()
    digest = module.split('sha256 = "', 1)[1].split('"', 1)[0]
    bundle = args.runner.read_bytes()
    assert hashlib.sha256(bundle).hexdigest() == digest, "Wrong private bundle"
    service = json.loads(subprocess.check_output([
        "nix", "eval", "--json",
        ".#nixosConfigurations.black.config.systemd.services.hosted-runner-june-dev",
        "--apply", "s: { inherit (s) preStart; }",
    ], cwd=repo, text=True))
    with tempfile.TemporaryDirectory(prefix="e5-credential-") as temporary:
        root = Path(temporary)
        unit = root.name
        runtime = Path("/run") / unit
        state = root / "state"
        state.mkdir()
        (root / "runner.mjs").write_bytes(bundle)
        (root / "checksum").write_text(f"{digest}  {root}/runner.mjs\n")
        synthetic_key = secrets.token_hex(32)
        (root / "key").write_text(synthetic_key)
        (root / "key").chmod(0o600)
        # This identity is computed by the pinned targetEnvironmentDigest for
        # node@sha256:111... and its fixed isolation policy (not an image pull).
        (root / "release.json").write_text(json.dumps({
            "artifact": {"digest": "sha256:" + "2" * 64, "entrypoint": "entry.mjs"},
            "environment": {
                "image": "node@sha256:" + "1" * 64,
                "digest": "sha256:b5c3b01160e63a9824d16487b7c6e9398e70c2a366c9ece0178985e4c885bdb8",
            },
        }))
        (root / "release.json").chmod(0o600)
        fake_bin = root / "bin"
        fake_bin.mkdir()
        (fake_bin / "docker").write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$E5_DOCKER_LOG\"\n"
            'case "$*" in "container ls "*) exit 0;; *) exit 99;; esac\n'
        )
        (fake_bin / "docker").chmod(0o700)
        script = service["preStart"].replace(
            "/var/lib/hosted-runner-june-dev", str(state)
        ).replace("/run/hosted-runner-june-dev", str(runtime))
        script = script.replace(script.splitlines()[0],
                                f"sha256sum --check --status {root}/checksum")
        # Record metadata only. Never print the synthetic key itself.
        script = (
            "#!/usr/bin/env bash\nset -eu\n"
            f'stat -c "%u %a" "$CREDENTIALS_DIRECTORY/runner-key" > {root}/credential-stat\n'
            + script
            + f'if test -e {runtime}/runner-key; then stat -c "%u %a" {runtime}/runner-key > {root}/private-stat; fi\n'
        )
        (root / "prestart").write_text(script)
        (root / "prestart").chmod(0o700)
        node = shutil.which("node")
        timeout = shutil.which("timeout")
        command = [
            "sudo", "-n", "systemd-run", "--quiet", "--wait", "--pipe", "--collect",
            f"--unit={unit}",
        ]
        for setting in [
            f"User={pwd.getpwuid(os.getuid()).pw_name}",
            "ProtectSystem=strict", "ProtectHome=true", "NoNewPrivileges=true",
            "PrivateDevices=true", "PrivateTmp=false", "CapabilityBoundingSet=",
            "MemoryMax=512M", "MemorySwapMax=0", "TasksMax=64", "UMask=0077",
            "KillMode=mixed", "RuntimeMaxSec=15", f"ReadWritePaths={root}",
            f"WorkingDirectory={state}", f"RuntimeDirectory={unit}",
            "RuntimeDirectoryMode=0700", f"LoadCredential=runner-key:{root}/key",
            f"LoadCredential=release.json:{root}/release.json",
            f"ExecStartPre={root}/prestart",
        ]:
            command += ["-p", setting]
        for value in [
            f"PATH={fake_bin}:{os.environ['PATH']}",
            f"E5_DOCKER_LOG={root}/docker.log", f"EVE_RUNNER_CONFIG={runtime}/runner.json",
            "EVE_JUNE_CONVEX_URL=http://127.0.0.1:1",
            "EVE_JUNE_HTTP_URL=http://127.0.0.1:1", f"TMPDIR={state}/tmp",
        ]:
            command += ["-E", value]
        command += [timeout, "--signal=TERM", "2s", node, str(root / "runner.mjs")]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=25)
            assert synthetic_key not in result.stdout + result.stderr
            assert (root / "credential-stat").read_text().strip() == "0 440"
            assert result.stdout == "Runner ready\n", (result.returncode, result.stdout, result.stderr)
            assert result.stderr == "", result.stderr
            assert result.returncode == 124, result.returncode  # deliberate timeout
            assert (root / "private-stat").read_text().strip() == f"{os.getuid()} 600"
            inventory = (root / "docker.log").read_text().splitlines()
            assert inventory and all(line.startswith("container ls ") for line in inventory)
            assert not list((state / "locks").glob("*.dirty")), "Idle shutdown did not clean up"
        finally:
            subprocess.run(["sudo", "-n", "systemctl", "stop", unit],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=20)
    print("PASS: real bundle reaches readiness with systemd 0440 credential and private 0600 copy")


if __name__ == "__main__":
    main()
