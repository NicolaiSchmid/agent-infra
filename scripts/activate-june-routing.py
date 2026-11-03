#!/usr/bin/env python3
"""Replace only the running route unit's commands, preserving its earlier override."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

OVERRIDE = Path('/etc/systemd/system.control/routes.service.d/90-routing-only-936258ad.conf')
FIELDS = ('ExecStartPre=', 'ExecStart=', 'ExecReload=', 'ExecStop=')
BASE = Path('/nix/store/474sa8dmrkdsj4mrs0aynsjsy6zpv6x2-nixos-system-black-26.05.20260707.0ad6f47')


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def healthy():
    until = time.monotonic() + 60
    while time.monotonic() < until:
        try:
            if run('curl', '-fsS', '--connect-timeout', '3', '--max-time', '5', '-o', '/dev/null', '-w', '%{http_code}', 'https://routes.modusservice.com/healthz') == '204':
                return
        except subprocess.CalledProcessError:
            pass
        time.sleep(2)
    raise RuntimeError('Route discovery did not recover')


def digest(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('action', choices=['dry-run', 'apply', 'rollback'])
    p.add_argument('--unit', required=True, type=Path)
    p.add_argument('--backup', required=True, type=Path)
    a = p.parse_args()
    assert os.geteuid() == 0
    assert Path('/run/current-system').resolve() == BASE, 'Global baseline changed'
    assert a.unit.resolve().is_relative_to('/nix/store'), 'Unit must be immutable'
    old = (BASE / 'etc/systemd/system/routes.service').read_text().splitlines()
    new = a.unit.read_text().splitlines()
    assert [x for x in old if not x.startswith(FIELDS)] == [x for x in new if not x.startswith(FIELDS)], 'Non-command unit changes'
    assert run('systemctl', 'is-active', 'routes').strip() == 'active'
    assert run('systemctl', 'show', 'routes', '-p', 'DropInPaths', '--value').split() == [str(OVERRIDE)], 'Unexpected overrides'
    content = '[Service]\n' + ''.join(x + '\n' for x in FIELDS) + ''.join(x + '\n' for x in new if x.startswith(FIELDS))
    if a.action == 'dry-run':
        print('Validated immutable routing unit; only route command fields change.')
        return
    if a.action == 'apply':
        a.backup.mkdir(mode=0o700, parents=False, exist_ok=False)
        (a.backup / 'override-before').write_bytes(OVERRIDE.read_bytes())
        preserved = [Path('/var/lib/client-data/routes/state/modus-gateway.json'), Path('/var/lib/client-data/secrets/routes-modus-gateway-key')]
        (a.backup / 'preserved.json').write_text(json.dumps({str(x): digest(x) for x in preserved}))
        (a.backup / 'override-after').write_text(content)
        for f in a.backup.iterdir():
            f.chmod(0o600)
    else:
        assert OVERRIDE.read_bytes() == (a.backup / 'override-after').read_bytes(), 'Override changed since apply'
    def install(data):
        temp = OVERRIDE.with_suffix('.tmp')
        temp.write_bytes(data)
        temp.chmod(0o644)
        temp.replace(OVERRIDE)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'reload', 'routes')
        healthy()
    try:
        install((a.backup / ('override-after' if a.action == 'apply' else 'override-before')).read_bytes())
        for f, expected in json.loads((a.backup / 'preserved.json').read_text()).items():
            assert digest(Path(f)) == expected, 'Gateway state or key changed'
    except BaseException:
        if a.action == 'apply':
            install((a.backup / 'override-before').read_bytes())
        raise
    assert Path('/run/current-system').resolve() == BASE
    print(a.action + ': route commands only; gateway table/key and global system preserved')


if __name__ == '__main__':
    main()
