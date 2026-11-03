#!/usr/bin/env python3
"""Activate the reviewed route service without switching black's system profile."""
import argparse
import pathlib
import subprocess
import os
import time

BASE = '/nix/store/474sa8dmrkdsj4mrs0aynsjsy6zpv6x2-nixos-system-black-26.05.20260707.0ad6f47'
CANDIDATE = '/nix/store/8fdcb115q3sx69rfzc1mh4plisgnh58d-nixos-system-black-26.05.20260707.0ad6f47'
OVERRIDE = pathlib.Path('/etc/systemd/system.control/routes.service.d/90-routing-only-936258ad.conf')
FIELDS = ('ExecStartPre=', 'ExecStart=', 'ExecReload=', 'ExecStop=')

def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout

def verify_health():
    deadline = time.monotonic() + 60
    while True:
        try:
            result = run('curl', '--connect-timeout', '5', '--max-time', '10', '--fail', '--silent', '--output', '/dev/null', '--write-out', '%{http_code}', 'https://routes.modusservice.com/healthz')
            if result == '204':
                return
        except subprocess.CalledProcessError:
            pass
        if time.monotonic() >= deadline:
            raise RuntimeError('Routes health did not recover within the discovery window')
        time.sleep(2)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['dry-run', 'apply', 'rollback'])
    args = parser.parse_args()
    assert pathlib.Path('/run/current-system').resolve() == pathlib.Path(BASE), 'System baseline changed'
    old = pathlib.Path(BASE + '/etc/systemd/system/routes.service').read_text().splitlines()
    new = pathlib.Path(CANDIDATE + '/etc/systemd/system/routes.service').read_text().splitlines()
    assert [x for x in old if not x.startswith(FIELDS)] == [x for x in new if not x.startswith(FIELDS)], 'Non-command service changes'
    content = '# agent-infra ce6725d69d4fcc66fbb24d7aaf1d2e3680162d9a\n[Service]\n'
    content += ''.join(x + '\n' for x in FIELDS)
    content += ''.join(x + '\n' for x in new if x.startswith(FIELDS))
    if OVERRIDE.exists():
        assert OVERRIDE.read_text() == content, 'Foreign override at owned location'
    other = run('systemctl', 'show', 'routes', '--property=DropInPaths', '--value').split()
    assert all(x == str(OVERRIDE) for x in other), 'Other route overrides present'
    assert run('systemctl', 'is-active', 'routes').strip() == 'active'
    if args.action == 'dry-run':
        print('Only routes.service commands change; system profile, other units and route tables unchanged.')
        print(content, end='')
        return
    assert os.geteuid() == 0
    if args.action == 'rollback':
        OVERRIDE.unlink(missing_ok=True)
        run('systemctl', 'daemon-reload')
        run('systemctl', 'reload', 'routes')
        verify_health()
    else:
        assert not OVERRIDE.exists(), 'Already active; use rollback first'
        OVERRIDE.parent.mkdir(parents=True, exist_ok=True)
        temp = OVERRIDE.with_suffix('.tmp')
        temp.write_text(content)
        temp.chmod(0o644)
        temp.replace(OVERRIDE)
        try:
            run('systemctl', 'daemon-reload')
            run('systemctl', 'reload', 'routes')
            verify_health()
        except BaseException:
            OVERRIDE.unlink()
            run('systemctl', 'daemon-reload')
            run('systemctl', 'reload', 'routes')
            verify_health()
            raise
    print(args.action + ': routes.service only; system profile remains ' + BASE)

if __name__ == '__main__':
    main()
