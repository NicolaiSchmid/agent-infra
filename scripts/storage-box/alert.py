"""Deliver Forge's fixed retention alert via Pushover.
Credentials are read from a root-only SOPS JSON file, never command arguments.
Forge only (hosts/forge/product-backup-retention.nix); black reports to June
through scripts/june-alert.py.
"""
import json
from pathlib import Path
import sys
import urllib.parse
import urllib.request


RETENTION = ('Product backup retention failed',
             'Forge product backup retention (prune/compact of the Storage Box repository) failed. Check /var/log/product-backup-retention.log on Forge before any manual prune or compact.')


def fixed_message(args):
    """Only the fixed retention text; no free text from callers."""
    if args == ['retention']:
        return RETENTION
    raise SystemExit('Unknown alert')


def send(config, title=RETENTION[0], message=RETENTION[1]):
    failures = []
    try:
        p = config['pushover']
        data = urllib.parse.urlencode(dict(token=p['token'], user=p['user'],
                                           title=title, message=message)).encode()
        with urllib.request.urlopen('https://api.pushover.net/1/messages.json', data=data, timeout=30) as response:
            if json.load(response)['status'] != 1:
                raise ValueError('delivery rejected')
    except Exception:
        failures.append('Pushover')
    if failures:
        raise RuntimeError('Backup alert delivery failed: ' + ', '.join(failures))


if __name__ == '__main__':
    title, message = fixed_message(sys.argv[2:])
    send(json.loads(Path(sys.argv[1]).read_text()), title, message)
