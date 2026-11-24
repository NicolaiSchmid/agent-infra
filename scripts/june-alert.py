"""Report a fixed black alert to June: `hostedRuns/alerts:report`.

Usage: june-alert.py <deployment> <check> <subject> <firing|resolved>

June writes every text and dedupes incidents; black sends only a fixed check
name, a validated unit name (or "") and the state. Authentication is the
deployment's hosted runner key, read from /root/hosted-runner/<deployment>-runner.key
(hosts/black/hosted-runner.nix). Neither the key nor the request body is ever
printed; a failure exits non-zero with a fixed message.
"""
import json
from pathlib import Path
import re
import sys
import urllib.request


KEY_DIR = Path('/root/hosted-runner')
DEPLOYMENT = re.compile(r'[a-z0-9-]{1,32}')
UNIT = {
    'runner-unit': re.compile(r'hosted-runner-[a-z0-9-]{1,32}\.service'),
    'executor-db': re.compile(r'executor-db-[a-z0-9-]{1,32}-(health|backup)\.service'),
}
NO_SUBJECT = {'product-backup', 'product-backup-bundles'}
STATES = {'firing', 'resolved'}


def validate(args):
    """Return (deployment, check, subject, state) or exit; no free text passes."""
    if len(args) != 4:
        raise SystemExit('usage: june-alert.py <deployment> <check> <subject> <firing|resolved>')
    deployment, check, subject, state = args
    if not DEPLOYMENT.fullmatch(deployment):
        raise SystemExit('Unknown deployment')
    if state not in STATES:
        raise SystemExit('Unknown state')
    if check in NO_SUBJECT:
        if subject != '':
            raise SystemExit('This check takes no subject')
    elif check in UNIT:
        if not UNIT[check].fullmatch(subject):
            raise SystemExit('Unknown unit')
        # A runner's alert goes to the deployment it polls, never another one.
        if check == 'runner-unit' and subject != f'hosted-runner-{deployment}.service':
            raise SystemExit('Runner unit does not belong to this deployment')
    else:
        raise SystemExit('Unknown check')
    return deployment, check, subject, state


def request(deployment, key, check, subject, state):
    body = json.dumps({
        'path': 'hostedRuns/alerts:report',
        'format': 'json',
        'args': {'runnerKey': key, 'check': check, 'subject': subject, 'state': state},
    }).encode()
    return urllib.request.Request(
        f'https://{deployment}.convex.modusservice.com/api/mutation',
        data=body, method='POST', headers={'Content-Type': 'application/json'})


def report(deployment, check, subject, state):
    try:
        key = (KEY_DIR / f'{deployment}-runner.key').read_text().strip()
    except OSError:
        raise SystemExit(f'June alert not sent: no runner key for {deployment}') from None
    if not key:
        raise SystemExit(f'June alert not sent: empty runner key for {deployment}')
    try:
        with urllib.request.urlopen(request(deployment, key, check, subject, state), timeout=30) as response:
            ok = response.status == 200 and json.load(response).get('status') == 'success'
    except Exception as error:
        # Only the error class: an HTTP error's body or a reason may echo the request.
        raise SystemExit(f'June alert delivery failed ({type(error).__name__})') from None
    if not ok:
        raise SystemExit('June alert delivery failed (rejected)')


if __name__ == '__main__':
    report(*validate(sys.argv[1:]))
    print(f'reported {sys.argv[2]} {sys.argv[4]} to {sys.argv[1]}')
