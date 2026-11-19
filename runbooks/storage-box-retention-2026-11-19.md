# Storage Box 30-day retention — 2026-11-19

Decision (Nicolai Schmid, 2026-11-19): the off-host Borg repository
`product-backup/repo` keeps the newest 30 daily archives per deployment series
(`--keep-daily 30`, no weekly or monthly), pruned and compacted automatically. This
matches MODUS's AVV Anlage 2 and the DSFA ("täglich verschlüsselt … gesichert und dort
30 Tage aufbewahrt"). The design is in the
[recovery runbook](storage-box-product-recovery.md#retention-30-days).

## Status

Implemented, **not yet active**. The Forge daemon is in the configuration with
`enable = false`, `dryRun = true`. No retention key exists on the Storage Box yet.
`secrets/product-backup-retention.yaml` is not yet created. No host switch was made,
and no archive was pruned or compacted.

## Dry run against the real repository

Read-only, 2026-11-19 ~18:00 CET, from Black through its append-only writer, under
Black's backup lock (`/var/lib/product-backup/lock`), Borg 1.4.4:
`borg prune --dry-run --list --glob-archives 'NAME-[0-9]*' --keep-daily 30` for every
series in the repository.

| Series | Archives | Oldest | Would prune |
| --- | --- | --- | --- |
| june-dev | 11 | 2026-11-04 (bootstrap) | none |
| june-prod | 9 | 2026-11-04 (bootstrap) | none |
| modus-gateway-dev | 11 | 2026-11-04 (bootstrap) | none |
| modus-gateway-prod | 11 | 2026-11-04 (bootstrap) | none |
| modus-dev (retired) | 2 | 2026-11-04 (bootstrap) | none |
| modus-prod (retired) | 2 | 2026-11-04 (bootstrap) | none |

Every series is below 30 daily archives, so nothing is due yet. The oldest archive
is 15 days old. Pruning starts once a series has more than 30 days with an archive
(around 2026-12-10 for the current deployments, later for june-prod).

Observed while doing this:

- june-prod has no archive for 2026-11-17 or 2026-11-19. The 2026-11-19 run failed
  at 03:38 CET because the backend did not accept connections on 127.0.0.1:13220.
  `product-backup-health` has reported `Missing/stale off-host backup: june-prod`
  since that afternoon. No push delivery exists, so only the journal shows it.
- The retired `modus-dev`/`modus-prod` series are never pruned by `--keep-daily`
  (each has no newer archives). They pass 30 days on 2026-12-04 and need an operator
  decision (see the runbook caveat).

## Other copies checked (Black Garage, 2026-11-19)

| Bucket | Objects | Oldest | Within 30 days? |
| --- | --- | --- | --- |
| june-dev-backups | 14 | 2026-11-07 | yes, newest 14 kept |
| june-prod-backups | 14 | 2026-11-05 | yes, newest 14 kept |
| modus-gateway-dev-backups / -prod-backups | 14 / 14 | 2026-11-07 | yes |
| june-dev-exports | 23 | 2026-10-30 | no pruning; over 30 days from 2026-11-29 |
| june-prod-exports | 31 | 2026-10-31 | no pruning; over 30 days from 2026-11-30 |
| modus-gateway-dev-exports / -prod-exports | 22 / 22 | 2026-11-01 | no pruning; over 30 days from 2026-12-01 |
| june-dev-snapshot-imports | 3 | 2026-10-30 | over 30 days from 2026-11-29 |
| june-prod-snapshot-imports | 1 | 2026-11-03 | over 30 days from 2026-12-03 |
| modus-gateway-*-snapshot-imports | 0 | — | — |

`/var/lib/product-backup/bootstrap` on Black is empty. Its Borg cache (112K) holds
no payload.

## Acceptance still to record

- Retention key authorized with the exact forced command, and the sibling-repository
  check rejected (exit code).
- First Forge dry-run log and `last-run.json`.
- First real run (prune list; compaction deferred), then the first compacting run.
