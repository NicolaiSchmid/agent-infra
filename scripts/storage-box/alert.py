"""Deliver a fixed infrastructure alert via Pushover.
Credentials are read from a root-only SOPS JSON file, never command arguments.
"""
import json
from pathlib import Path
import sys
import urllib.parse
import urllib.request


def send(config):
    message = 'Black product backups: one or more off-host Convex backups are missing or older than 36 hours. Check product-backup-health.service and recovery receipts.'
    failures = []
    try:
        p = config['pushover']
        data = urllib.parse.urlencode(dict(token=p['token'], user=p['user'],
                                           title='Product backup overdue', message=message)).encode()
        with urllib.request.urlopen('https://api.pushover.net/1/messages.json', data=data, timeout=30) as response:
            if json.load(response)['status'] != 1:
                raise ValueError('delivery rejected')
    except Exception:
        failures.append('Pushover')
    if failures:
        raise RuntimeError('Backup alert delivery failed: ' + ', '.join(failures))


if __name__ == '__main__':
    send(json.loads(Path(sys.argv[1]).read_text()))
