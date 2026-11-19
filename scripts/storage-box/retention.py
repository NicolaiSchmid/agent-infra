"""Scheduled retention for the off-host product Borg repository.

Runs on the retention host (Forge), never on Black: Black's writer key is
append-only. Nothing older than 30 days is kept (Borg `--keep-within 30d`;
AVV Anlage 2). A current deployment's series (`--current`) also always keeps its
newest archive (`--keep-last 1`), so a stalled backup never deletes its last good
copy. A retired deployment's series ages out completely.

Order, all fail-closed:
1. list the archives and compare with the previous run's survivors. An
   append-only writer can still mark archives deleted, and compaction would
   make that permanent, so an archive that vanished without this job pruning
   it stops the run before any prune or compact;
2. prune each series NAME-<export timestamp> (dry-run lists only);
3. record the survivors as the next baseline;
4. compact, unless dry-run or this run had no earlier baseline to check;
5. write the receipt `last-run.json`.

The BORG_* environment (repository, SSH, passphrase, cache) comes from the
caller. Exit status is non-zero on any failure; the caller alerts.
"""
import argparse
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

SERIES = re.compile(r'^(?P<series>.+)-(?P<ts>[0-9]+)$')


class UnexpectedDeletion(RuntimeError):
    pass


def borg(*args, capture=True, lock_wait=600):
    command = ['borg', '--lock-wait', str(lock_wait), *args, os.environ['BORG_REPO']]
    if capture:
        return subprocess.check_output(command, text=True)
    subprocess.run(command, check=True)
    return None


def list_archives():
    archives = json.loads(borg('list', '--json'))['archives']
    return {a['id']: {'name': a['archive'], 'time': a['start']} for a in archives}


def series_of(archives):
    """Archive series names; an archive outside NAME-<digits> fails the run."""
    names = set()
    for archive in archives.values():
        match = SERIES.match(archive['name'])
        if not match:
            raise ValueError('archive outside the NAME-<timestamp> scheme: ' + archive['name'])
        names.add(match['series'])
    return sorted(names)


def check_baseline(baseline, current):
    missing = sorted(baseline[i]['name'] for i in baseline.keys() - current.keys())
    if missing:
        raise UnexpectedDeletion(
            'archives present after the last retention run are gone without this job '
            'pruning them; investigate before any prune or compact: ' + ', '.join(missing))


def over_age(archives, max_age_days, now):
    limit = now - timedelta(days=max_age_days)
    # Borg 1.x reports naive client-local times.
    return sorted(a['name'] for a in archives.values()
                  if datetime.fromisoformat(a['time']).astimezone(timezone.utc) < limit)


def write_json(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    tmp.chmod(0o600)
    tmp.replace(path)


def main(argv=None):
    p = argparse.ArgumentParser()
    p.add_argument('--state', required=True, type=Path)
    p.add_argument('--keep-days', required=True, type=int)
    p.add_argument('--current', required=True, nargs='+',
                   help='deployments whose newest archive is always kept')
    p.add_argument('--dry-run', action='store_true')
    args = p.parse_args(argv)
    if args.keep_days < 1:
        raise ValueError('--keep-days must be at least 1')

    baseline_file = args.state / 'archives.json'
    baseline = json.loads(baseline_file.read_text()) if baseline_file.exists() else None
    before = list_archives()
    if baseline is not None:
        check_baseline(baseline, before)
    names = series_of(before)

    for name in names:
        print(f'## {name}', flush=True)
        keep_last = ['--keep-last', '1'] if name in args.current else []
        borg('prune', '--list', *(['--dry-run'] if args.dry_run else []),
             '--glob-archives', f'{name}-[0-9]*', '--keep-within', f'{args.keep_days}d',
             *keep_last, capture=False)

    after = before if args.dry_run else list_archives()
    pruned = sorted(before[i]['name'] for i in before.keys() - after.keys())
    write_json(baseline_file, after)

    compacted = False
    if not args.dry_run and baseline is not None:
        borg('compact', capture=False)
        compacted = True
    elif not args.dry_run:
        print('No earlier baseline: compaction deferred to the next run.', file=sys.stderr)

    now = datetime.now(timezone.utc)
    # Dry-run survivors, or a stalled deployment's last archive.
    old = over_age(after, args.keep_days, now)
    if old:
        print(f'Warning: {len(old)} surviving archives older than {args.keep_days} days: '
              + ', '.join(old), file=sys.stderr)
    write_json(args.state / 'last-run.json', {
        'completed_at': time.time(), 'dry_run': args.dry_run, 'keep_days': args.keep_days,
        'series': names, 'archives': len(after), 'pruned': pruned, 'compacted': compacted,
        'over_age': old})
    print(f'{"Would keep" if args.dry_run else "Kept"} {len(after)} archives; '
          f'pruned {len(pruned)}; compacted: {compacted}.')


if __name__ == '__main__':
    main()
