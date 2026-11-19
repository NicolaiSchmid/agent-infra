"""Deliver a fixed infrastructure alert via Pushover.
Credentials are read from a root-only SOPS JSON file, never command arguments.
"""
import json
from pathlib import Path
import sys
import urllib.parse
import urllib.request


STALE = ('Product backup overdue',
         'Black product backups: one or more off-host Convex backups are missing or older than 36 hours. Check product-backup-health.service and recovery receipts.')
RETENTION = ('Product backup retention failed',
             'Forge product backup retention (prune/compact of the Storage Box repository) failed. Check /var/log/product-backup-retention.log on Forge before any manual prune or compact.')


def send(config, title=STALE[0], message=STALE[1]):
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
    # Optional second argument selects a fixed message; no free text from callers.
    title, message = RETENTION if sys.argv[2:] == ['retention'] else STALE
    send(json.loads(Path(sys.argv[1]).read_text()), title, message)
